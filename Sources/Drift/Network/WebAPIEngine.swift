import Foundation

enum WebAPIError: Error {
    case invalidURL
    case badStatus(Int)
    case authFailed
    case notQBitTorrent
    case network(String)

    var message: String {
        switch self {
        case .invalidURL: "Invalid Web UI URL"
        case .badStatus(let code): "Server returned HTTP \(code)"
        case .authFailed: "Authentication failed"
        case .notQBitTorrent: "Not a qBittorrent Web UI"
        case .network(let text): text
        }
    }
}

final class WebAPIEngine: TorrentEngine, @unchecked Sendable {
    let base: URL
    private let username: String
    private let password: String
    private let session: URLSession
    private let lock = NSLock()

    private var rawTorrents: [String: [String: Any]] = [:]
    private var serverState: [String: Any] = [:]
    private var lastRid = 0
    private var syncTask: Task<Void, Never>?
    private var consecutiveFailures = 0
    private var didLogFirstTick = false
    private var lastLoggedCount = -1
    private var isFetching = false

    var onUpdate: (@MainActor () -> Void)?

    init(base: URL, username: String = "", password: String = "") {
        self.base = base
        self.username = username
        self.password = password
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        session = URLSession(configuration: configuration)
    }

    static func url(from string: String) -> URL? {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "http://" + text }
        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil
        else { return nil }
        return url
    }

    // MARK: - Auth

    func authenticate() async throws -> String {
        try await authenticate(username: username, password: password)
    }

    func authenticate(username: String, password: String) async throws -> String {
        var login = URLRequest(url: base.appendingPathComponent("api/v2/auth/login"))
        login.httpMethod = "POST"
        login.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        login.httpBody = Data(Self.form([
            ("username", username),
            ("password", password)
        ]).utf8)

        let (loginData, loginResponse) = try await send(login)
        guard let http = loginResponse as? HTTPURLResponse else {
            throw WebAPIError.network("No HTTP response")
        }
        let loginText = String(data: loginData, encoding: .utf8) ?? ""
        if loginText.localizedCaseInsensitiveContains("fails")
            || loginText.localizedCaseInsensitiveContains("unauthorized") {
            throw WebAPIError.authFailed
        }
        // qBittorrent ≤5.1 answers 200 "Ok."; 5.2+ answers 204 with an empty
        // body and uses 401 "Unauthorized" for bad credentials.
        guard http.statusCode == 200 || http.statusCode == 204 else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw WebAPIError.authFailed
            }
            throw WebAPIError.badStatus(http.statusCode)
        }

        let (versionData, versionResponse) = try await send(
            URLRequest(url: base.appendingPathComponent("api/v2/app/version"))
        )
        guard let versionHTTP = versionResponse as? HTTPURLResponse, versionHTTP.statusCode == 200 else {
            throw WebAPIError.notQBitTorrent
        }
        guard let version = String(data: versionData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !version.isEmpty
        else { throw WebAPIError.notQBitTorrent }
        return version
    }

    // MARK: - Sync loop

    enum SyncTier: String {
        case active
        case summary
    }

    private var tier: SyncTier = .active
    private var wakeRequested = false
    private var loopAlive = false
    private var suspended = false
    private var syncGeneration = 0

    func startSync() {
        let generation = lock.withLock { () -> Int in
            suspended = false
            syncTask?.cancel()
            syncTask = nil
            syncGeneration += 1
            loopAlive = true
            return syncGeneration
        }
        let task = Task {
            await self.syncLoop()
            self.lock.withLock {
                if self.syncGeneration == generation {
                    self.loopAlive = false
                    self.syncTask = nil
                }
            }
        }
        lock.withLock {
            if syncGeneration == generation { syncTask = task }
        }
    }

    func stopSync() {
        lock.lock()
        syncTask?.cancel()
        syncTask = nil
        lock.unlock()
    }

    func setSyncTier(_ newTier: SyncTier) {
        let changed = lock.withLock { () -> Bool in
            guard tier != newTier else { return false }
            tier = newTier
            wakeRequested = true
            return true
        }
        if changed {
            writeProbeLog("[sync] tier -> \(newTier.rawValue)")
            ensureSyncLoop()
        }
    }

    func suspendSync() {
        let wasSuspended = lock.withLock { () -> Bool in
            let previous = suspended
            suspended = true
            return previous
        }
        stopSync()
        if !wasSuspended {
            writeProbeLog("[sync] suspended")
        }
    }

    var isSuspended: Bool { lock.withLock { suspended } }

    func resumeSync() async {
        do {
            let version = try await authenticate()
            lock.withLock {
                lastRid = 0
                consecutiveFailures = 0
            }
            startSync()
            writeProbeLog("[sync] resumed \(version)")
        } catch {
            writeProbeLog("[sync] resume failed: \(describe(error))")
        }
    }

    /// Revives a loop that gave up (daemon restart etc.) unless suspended.
    func ensureSyncLoop() {
        let needed = lock.withLock { () -> Bool in
            !suspended && !loopAlive
        }
        guard needed else { return }
        writeProbeLog("[sync] loop revived")
        startSync()
    }

    private func syncLoop() async {
        while !Task.isCancelled {
            do {
                try await syncOnce()
                consecutiveFailures = 0
                let interval = refreshIntervalMilliseconds()
                let tierNow = lock.withLock { tier }
                if tierNow != .active {
                    writeProbeLog("[sync] sleep \(interval)ms (\(tierNow.rawValue))")
                }
                try await sleepInterruptibly(milliseconds: interval)
            } catch is CancellationError {
                break
            } catch {
                consecutiveFailures += 1
                if case WebAPIError.authFailed = error, consecutiveFailures <= 2 {
                    do {
                        _ = try await authenticate()
                        lock.withLock { lastRid = 0 }
                        consecutiveFailures = 0
                        continue
                    } catch {
                        writeProbeLog("[sync] re-auth failed")
                    }
                }
                if consecutiveFailures == 1 {
                    writeProbeLog("[sync] error: \(describe(error))")
                }
                if consecutiveFailures >= 10 {
                    writeProbeLog("[sync] giving up after \(consecutiveFailures) failures")
                    break
                }
                lock.withLock { lastRid = 0 }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    private func sleepInterruptibly(milliseconds: Int) async throws {
        var remaining = max(500, milliseconds)
        while remaining > 0 {
            let shouldWake = lock.withLock { () -> Bool in
                guard wakeRequested else { return false }
                wakeRequested = false
                return true
            }
            if shouldWake { return }
            let step = min(250, remaining)
            try await Task.sleep(nanoseconds: UInt64(step) * 1_000_000)
            remaining -= step
        }
    }

    private func syncOnce() async throws {
        ensureSyncLoop()
        let acquired = lock.withLock { () -> Bool in
            if isFetching { return false }
            isFetching = true
            return true
        }
        guard acquired else { return }
        defer { lock.withLock { isFetching = false } }
        let rid = lock.withLock { lastRid }

        var components = URLComponents(
            url: base.appendingPathComponent("api/v2/sync/maindata"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "rid", value: String(rid))]
        guard let url = components?.url else { throw WebAPIError.invalidURL }

        let (data, response) = try await send(URLRequest(url: url))
        guard let http = response as? HTTPURLResponse else {
            throw WebAPIError.network("No HTTP response")
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw WebAPIError.authFailed
            }
            throw WebAPIError.badStatus(http.statusCode)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WebAPIError.notQBitTorrent
        }

        let (count, nextRid) = apply(json: json)
        if !didLogFirstTick || count != lastLoggedCount {
            didLogFirstTick = true
            lastLoggedCount = count
            writeProbeLog("[sync] tick n=\(count) rid=\(nextRid)")
        }
        if let onUpdate {
            Task { @MainActor in onUpdate() }
        }
    }

    private func apply(json: [String: Any]) -> (count: Int, rid: Int) {
        lock.lock()
        defer { lock.unlock() }

        let isFull = (json["full_update"] as? Bool) ?? false
        if isFull {
            rawTorrents = [:]
            serverState = [:]
        }
        if let torrents = json["torrents"] as? [String: [String: Any]] {
            for (hash, fields) in torrents {
                rawTorrents[hash, default: [:]].merge(fields) { _, new in new }
            }
        }
        if let removed = json["torrents_removed"] as? [String] {
            for hash in removed {
                rawTorrents.removeValue(forKey: hash)
            }
        }
        if let state = json["server_state"] as? [String: Any] {
            serverState.merge(state) { _, new in new }
        }
        if let rid = (json["rid"] as? NSNumber)?.intValue {
            lastRid = rid
        }
        return (rawTorrents.count, lastRid)
    }

    private func refreshIntervalMilliseconds() -> Int {
        lock.lock()
        let base = (serverState["refresh_interval"] as? NSNumber)?.intValue ?? 1500
        let currentTier = tier
        lock.unlock()
        switch currentTier {
        case .active: return base
        case .summary: return max(base, 3_000)
        }
    }

    private func describe(_ error: Error) -> String {
        if let error = error as? WebAPIError { return error.message }
        return String(describing: error)
    }

    // MARK: - TorrentEngine reads

    func loadTorrents() -> [TorrentSummary] {
        lock.lock()
        let snapshot = rawTorrents
        lock.unlock()
        return snapshot
            .map { Self.summary(id: $0.key, fields: $0.value) }
            .sorted { $0.name < $1.name }
    }

    func transferActivity() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let down = (serverState["dl_info_speed"] as? NSNumber)?.doubleValue ?? 0
        let up = (serverState["up_info_speed"] as? NSNumber)?.doubleValue ?? 0
        let states = rawTorrents.values.compactMap { $0["state"] as? String }
        return Self.transferActivity(dl: down, up: up, states: states)
    }

    static func transferActivity(dl: Double, up: Double, states: [String]) -> Bool {
        if dl > 0 || up > 0 { return true }
        let activeStates: Set<String> = [
            "downloading", "forcedDL", "metaDL", "uploading", "forcedUP",
        ]
        return states.contains { activeStates.contains($0) }
    }

    func loadDetails(for id: String) -> TorrentDetails {
        let (general, summary) = detailsBase(for: id)
        let files = [
            FileRow(name: summary.name, size: summary.size, progress: summary.progress, priority: .normal)
        ]
        return TorrentDetails(general: general, trackers: [], peers: [], webSeeds: [], files: files)
    }

    func fetchDetails(for id: String) async -> TorrentDetails {
        let (general, summary) = detailsBase(for: id)
        async let trackers = trackerRows(hash: id)
        async let peers = peerRows(hash: id)
        async let webSeeds = webSeedRows(hash: id)
        async let fetchedFiles = fileRows(hash: id)
        var files = await fetchedFiles
        if files.isEmpty {
            files = [FileRow(name: summary.name, size: summary.size, progress: summary.progress, priority: .normal)]
        }
        return TorrentDetails(
            general: general,
            trackers: await trackers,
            peers: await peers,
            webSeeds: await webSeeds,
            files: files
        )
    }

    func setFilePriority(id: String, fileIndex: Int, priority: FilePriority) {
        writeProbeLog("[engine] real filePrio id=\(id.prefix(12)) file=\(fileIndex) -> \(priority.rawValue)")
        Task {
            do {
                try await postForm(path: "torrents/filePrio", items: [
                    ("hash", id),
                    ("id", String(fileIndex)),
                    ("priority", String(priority.apiValue))
                ])
            } catch {
                writeProbeLog("[engine] real filePrio failed: \(describe(error))")
            }
        }
    }

    private func detailsBase(for id: String) -> (GeneralInfo, TorrentSummary) {
        lock.lock()
        let fields = rawTorrents[id] ?? [:]
        lock.unlock()
        let summary = Self.summary(id: id, fields: fields)
        let addedOn = (fields["added_on"] as? NSNumber)?.doubleValue ?? 0
        let completionOn = (fields["completion_on"] as? NSNumber)?.doubleValue ?? -1
        let general = GeneralInfo(
            hash: id,
            savePath: (fields["save_path"] as? String) ?? "",
            addedOn: addedOn > 0 ? Date(timeIntervalSince1970: addedOn) : Date(),
            completedOn: (completionOn > 0) ? Date(timeIntervalSince1970: completionOn) : nil,
            comment: (fields["comment"] as? String) ?? "",
            downloaded: (fields["downloaded"] as? NSNumber)?.int64Value ?? 0,
            uploaded: (fields["uploaded"] as? NSNumber)?.int64Value ?? 0,
            piecesTotal: (fields["pieces_num"] as? NSNumber)?.intValue ?? 0,
            piecesHave: (fields["pieces_have"] as? NSNumber)?.intValue ?? 0
        )
        return (general, summary)
    }

    private func trackerRows(hash: String) async -> [TrackerRow] {
        do {
            let rows = try await fetchArray(path: "torrents/trackers", hash: hash)
            return rows.map { row in
                TrackerRow(
                    url: (row["url"] as? String) ?? "",
                    status: Self.trackerStatus((row["status"] as? NSNumber)?.intValue ?? -1),
                    peers: max(0, (row["num_peers"] as? NSNumber)?.intValue ?? 0),
                    seeds: max(0, (row["num_seeds"] as? NSNumber)?.intValue ?? 0),
                    leeches: max(0, (row["num_leeches"] as? NSNumber)?.intValue ?? 0),
                    downloaded: max(0, (row["num_downloaded"] as? NSNumber)?.int64Value ?? 0)
                )
            }
        } catch {
            writeProbeLog("[details] trackers failed: \(describe(error))")
            return []
        }
    }

    private static func trackerStatus(_ code: Int) -> String {
        switch code {
        case 0: "Disabled"
        case 1: "Not contacted"
        case 2: "Working"
        case 4: "Not working"
        case 5: "Tracker error"
        case 6: "Unreachable"
        default: "Unknown"
        }
    }

    private func peerRows(hash: String) async -> [PeerRow] {
        do {
            let data = try await fetchData(
                path: "sync/torrentPeers",
                query: [URLQueryItem(name: "hash", value: hash)]
            )
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let peers = json["peers"] as? [String: [String: Any]]
            else { throw WebAPIError.notQBitTorrent }
            return peers.values
                .map { peer in
                    let client = ((peer["client"] as? String).flatMap { $0.isEmpty ? nil : $0 })
                        ?? (peer["peer_id_client"] as? String) ?? ""
                    return PeerRow(
                        ip: (peer["ip"] as? String) ?? "?",
                        client: client,
                        flags: (peer["flags"] as? String) ?? "",
                        connection: (peer["connection"] as? String) ?? "",
                        progress: (peer["progress"] as? NSNumber)?.doubleValue ?? 0,
                        downSpeed: (peer["dl_speed"] as? NSNumber)?.int64Value ?? 0,
                        upSpeed: (peer["up_speed"] as? NSNumber)?.int64Value ?? 0
                    )
                }
                .sorted { $0.ip < $1.ip }
        } catch {
            writeProbeLog("[details] peers failed: \(describe(error))")
            return []
        }
    }

    private func webSeedRows(hash: String) async -> [WebSeedRow] {
        do {
            let rows = try await fetchArray(path: "torrents/webseeds", hash: hash)
            return rows.compactMap { row in
                (row["url"] as? String).map { WebSeedRow(url: $0) }
            }
        } catch {
            writeProbeLog("[details] webseeds failed: \(describe(error))")
            return []
        }
    }

    private func fileRows(hash: String) async -> [FileRow] {
        do {
            let rows = try await fetchArray(path: "torrents/files", hash: hash)
            return rows.map { row in
                FileRow(
                    name: (row["name"] as? String) ?? "",
                    size: (row["size"] as? NSNumber)?.int64Value ?? 0,
                    progress: (row["progress"] as? NSNumber)?.doubleValue ?? 0,
                    priority: FilePriority(apiValue: (row["priority"] as? NSNumber)?.intValue ?? 1)
                )
            }
        } catch {
            writeProbeLog("[details] files failed: \(describe(error))")
            return []
        }
    }

    private func fetchArray(path: String, hash: String) async throws -> [[String: Any]] {
        let data = try await fetchData(path: path, query: [URLQueryItem(name: "hash", value: hash)])
        guard let array = try JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw WebAPIError.notQBitTorrent
        }
        return array.compactMap { $0 as? [String: Any] }
    }

    private func fetchData(path: String, query: [URLQueryItem]) async throws -> Data {
        var components = URLComponents(
            url: base.appendingPathComponent("api/v2/\(path)"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = query
        guard let url = components?.url else { throw WebAPIError.invalidURL }
        let (data, response) = try await send(URLRequest(url: url))
        try Self.requireOK(response)
        return data
    }

    // MARK: - TorrentEngine mutations

    func addTorrent(source: AddSource, savePath: String) -> TorrentSummary {
        let summary = Self.placeholderSummary(for: source)
        writeProbeLog("[engine] real add id=\(summary.id) name=\(summary.name) savePath=\(savePath)")
        Task {
            do {
                try await postAdd(source: source, savePath: savePath)
                try? await syncOnce()
            } catch {
                writeProbeLog("[engine] real add failed: \(describe(error))")
            }
        }
        return summary
    }

    func start(ids: [String]) {
        guard !ids.isEmpty else { return }
        writeProbeLog("[engine] real start ids=\(ids.sorted().joined(separator: ","))")
        Task {
            do {
                try await postForm(path: "torrents/start", items: [("hashes", Self.hashParam(ids))])
                try? await syncOnce()
            } catch {
                writeProbeLog("[engine] real start failed: \(describe(error))")
            }
        }
    }

    func stop(ids: [String]) {
        guard !ids.isEmpty else { return }
        writeProbeLog("[engine] real stop ids=\(ids.sorted().joined(separator: ","))")
        Task {
            do {
                try await postForm(path: "torrents/stop", items: [("hashes", Self.hashParam(ids))])
                try? await syncOnce()
            } catch {
                writeProbeLog("[engine] real stop failed: \(describe(error))")
            }
        }
    }

    func remove(ids: [String], deleteFiles: Bool) {
        guard !ids.isEmpty else { return }
        writeProbeLog("[engine] real remove ids=\(ids.sorted().joined(separator: ",")) deleteFiles=\(deleteFiles)")
        Task {
            do {
                try await postForm(path: "torrents/delete", items: [
                    ("hashes", Self.hashParam(ids)),
                    ("deleteFiles", deleteFiles ? "true" : "false")
                ])
                try? await syncOnce()
            } catch {
                writeProbeLog("[engine] real remove failed: \(describe(error))")
            }
        }
    }

    private static func hashParam(_ ids: [String]) -> String {
        ids.sorted().joined(separator: "|")
    }

    private static func placeholderSummary(for source: AddSource) -> TorrentSummary {
        switch source {
        case .magnetOrURL(let text):
            if let hash = magnetHash(in: text) {
                let name = magnetName(in: text) ?? "Magnet link"
                return TorrentSummary(
                    id: hash, name: name, status: .downloading, progress: 0, size: 0,
                    downloadSpeed: 0, uploadSpeed: 0, eta: nil, tags: []
                )
            }
            return TorrentSummary(
                id: "adding-" + String(UUID().uuidString.prefix(8)),
                name: magnetName(in: text) ?? "New torrent",
                status: .downloading, progress: 0, size: 0,
                downloadSpeed: 0, uploadSpeed: 0, eta: nil, tags: []
            )
        case .torrentFile(let url):
            return TorrentSummary(
                id: "adding-" + String(UUID().uuidString.prefix(8)),
                name: url.deletingPathExtension().lastPathComponent,
                status: .downloading, progress: 0, size: 0,
                downloadSpeed: 0, uploadSpeed: 0, eta: nil, tags: []
            )
        }
    }

    private static func magnetHash(in text: String) -> String? {
        guard let xtRange = text.range(of: "xt=urn:btih:", options: .caseInsensitive) else { return nil }
        let hash = text[xtRange.upperBound...].prefix { $0.isHexDigit }
        return hash.count == 40 ? String(hash).lowercased() : nil
    }

    private static func magnetName(in text: String) -> String? {
        guard let dnRange = text.range(of: "dn=", options: .caseInsensitive) else { return nil }
        let raw = text[dnRange.upperBound...].prefix { $0 != "&" && $0 != "#" }
        guard !raw.isEmpty else { return nil }
        return raw.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(raw)
    }

    private func postForm(path: String, items: [(String, String)]) async throws {
        var request = URLRequest(url: base.appendingPathComponent("api/v2/\(path)"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.form(items).utf8)
        let (_, response) = try await send(request)
        try Self.requireOK(response)
    }

    private func postAdd(source: AddSource, savePath: String) async throws {
        var request = URLRequest(url: base.appendingPathComponent("api/v2/torrents/add"))
        request.httpMethod = "POST"
        switch source {
        case .magnetOrURL(let text):
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(Self.form([("urls", text), ("savepath", savePath)]).utf8)
        case .torrentFile(let url):
            let data = try Data(contentsOf: url)
            let boundary = "DriftBoundary-\(UUID().uuidString)"
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            var body = Data()
            let field = { (name: String, value: String) in
                body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
            }
            field("savepath", savePath)
            body.append(Data(
                "--\(boundary)\r\nContent-Disposition: form-data; name=\"torrents\"; filename=\"\(url.lastPathComponent)\"\r\n\r\n"
                    .utf8
            ))
            body.append(data)
            body.append(Data("\r\n--\(boundary)--\r\n".utf8))
            request.httpBody = body
        }
        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else {
            throw WebAPIError.network("No HTTP response")
        }
        if http.statusCode == 409 {
            throw WebAPIError.network("Torrent already exists")
        }
        if http.statusCode == 400 || http.statusCode == 415 {
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw WebAPIError.network(
                (message?.isEmpty == false) ? message! : "Could not read torrent data"
            )
        }
        try Self.requireOK(response)
    }

    private static func requireOK(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw WebAPIError.network("No HTTP response")
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw WebAPIError.authFailed
            }
            throw WebAPIError.badStatus(http.statusCode)
        }
    }

    // MARK: - Mapping

    static func summary(id: String, fields: [String: Any]) -> TorrentSummary {
        let name = (fields["name"] as? String) ?? id
        let progress = (fields["progress"] as? NSNumber)?.doubleValue ?? 0
        let size = (fields["size"] as? NSNumber)?.int64Value ?? 0
        let downloadSpeed = (fields["dlspeed"] as? NSNumber)?.int64Value ?? 0
        let uploadSpeed = (fields["upspeed"] as? NSNumber)?.int64Value ?? 0
        let etaRaw = (fields["eta"] as? NSNumber)?.doubleValue ?? -1
        let eta: TimeInterval? = (etaRaw < 0 || etaRaw >= 8_640_000) ? nil : etaRaw
        let timeActive = (fields["time_active"] as? NSNumber)?.doubleValue ?? 0
        let category = (fields["category"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let tags = ((fields["tags"] as? String) ?? "")
            .split(separator: " ")
            .map(String.init)
        let state = (fields["state"] as? String) ?? ""
        return TorrentSummary(
            id: id,
            name: name,
            status: status(state: state, progress: progress),
            progress: progress,
            size: size,
            downloadSpeed: downloadSpeed,
            uploadSpeed: uploadSpeed,
            eta: eta,
            timeActive: timeActive,
            category: category,
            tags: tags
        )
    }

    static func status(state: String, progress: Double) -> TorrentStatus {
        let s = state.lowercased()
        if s.contains("stopped") || s.contains("paused") { return .stopped }
        if s.contains("stalled") || s.contains("error") || s.contains("missing")
            || s.contains("unknown") { return .stalled }
        if s.contains("up") || s.contains("upload") { return .seeding }
        if s.contains("down") || s.contains("dl") || s.contains("meta")
            || s.contains("checking") || s.contains("allocating") || s.contains("moving")
            || s.contains("queued") { return .downloading }
        return progress >= 1 ? .seeding : .downloading
    }

    // MARK: - Transport

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let error as URLError {
            throw WebAPIError.network(error.localizedDescription)
        } catch {
            throw WebAPIError.network(String(describing: error))
        }
    }

    private static func form(_ items: [(String, String)]) -> String {
        var components = URLComponents()
        components.queryItems = items.map { URLQueryItem(name: $0.0, value: $0.1) }
        return components.percentEncodedQuery ?? ""
    }
}
