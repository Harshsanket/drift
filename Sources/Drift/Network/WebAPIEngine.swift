import Foundation
import Observation
import os

enum WebAPIError: Error {
    case invalidURL
    case invalidSource
    case fileTooLarge
    case badStatus(Int)
    case authFailed
    case notQBitTorrent
    case network(String)

    var message: String {
        switch self {
        case .invalidURL: "Invalid Web UI URL"
        case .invalidSource: "Unsupported torrent source"
        case .fileTooLarge: "Torrent file is larger than 100 MB"
        case .badStatus(let code): "Server returned HTTP \(code)"
        case .authFailed: "Authentication failed"
        case .notQBitTorrent: "Not a qBittorrent Web UI"
        case .network(let text): text
        }
    }
}

/// Holds the live URLSession so tunnel flips can atomically swap it while
/// in-flight requests keep completing on the previous instance.
final class SessionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: URLSession

    init(configuration: URLSessionConfiguration) {
        value = URLSession(configuration: configuration)
    }

    var current: URLSession {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func replace(_ session: URLSession) {
        lock.lock()
        defer { lock.unlock() }
        value = session
    }
}

final class WebAPIEngine: TorrentEngine, @unchecked Sendable {
    let base: URL
    private let username: String
    private let password: String
    private var sessionBox: SessionBox!
    private let lock = NSLock()

    private var rawTorrents: [String: [String: Any]] = [:]
    private var serverState: [String: Any] = [:]
    private var cachedCategories: [TorrentCategory] = []
    private var cachedTags: [String] = []
    private var organizerTask: Task<Void, Never>?
    private var lastRid = 0
    private var syncTask: Task<Void, Never>?
    private var consecutiveFailures = 0
    private var didLogFirstTick = false
    private var lastLoggedCount = -1
    private var isFetching = false

    var onUpdate: (@MainActor () -> Void)?
    var onConnectionLost: (@MainActor (String) -> Void)?

    init(base: URL, username: String = "", password: String = "") {
        self.base = base
        self.username = username
        self.password = password
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        TunnelProxy.apply(to: configuration)
        sessionBox = SessionBox(configuration: configuration)
        // Route every future request through a rebuilt session whenever the
        // tunnel's relay port or activity flips (start/stop/kill-switch).
        TunnelProxy.onRebuild = { [weak self] in
            Task { @MainActor in
                self?.rebuildSession()
            }
        }
    }

    /// Rebuilds the URL session so its proxy settings reflect the current
    /// tunnel state. Run only on the main actor (onRebuild also fires from
    /// poll tasks; hopping keeps this race-free).
    @MainActor private func rebuildSession() {
        // Whatever route we were on, cached pages must never survive a
        // tunnel flip: an uncached body fetched pre-flip must not be
        // replayed on the new route.
        URLCache.shared.removeAllCachedResponses()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        configuration.urlCache = nil
        TunnelProxy.apply(to: configuration)
        sessionBox.replace(URLSession(configuration: configuration))
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
    /// Sleep-loop state gets its own tiny unfair lock: the wake/cancel path
    /// runs inside the concurrency runtime's task-cancellation machinery,
    /// where touching the shared engine NSLock can deadlock against tasks
    /// parked on that same lock (observed as a main-thread hang).
    private struct SleepState {
        var wakeRequested = false
        var continuation: CheckedContinuation<Void, Never>?
    }
    private let sleepState = OSAllocatedUnfairLock<SleepState>(initialState: SleepState())
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
        prefetchOrganizers()
    }

    func stopSync() {
        lock.withLock { syncTask?.cancel() }
        lock.withLock { syncTask = nil }
    }

    func setSyncTier(_ newTier: SyncTier) {
        let changed = lock.withLock { () -> Bool in
            guard tier != newTier else { return false }
            tier = newTier
            return true
        }
        if changed {
            writeProbeLog("[sync] tier -> \(newTier.rawValue)")
            sleepState.withLock { $0.wakeRequested = true }
            wakeSleepLoop()
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

    @discardableResult
    func resumeSync() async -> String? {
        do {
            let version = try await authenticate()
            lock.withLock {
                lastRid = 0
                consecutiveFailures = 0
            }
            startSync()
            writeProbeLog("[sync] resumed \(version)")
            return version
        } catch {
            writeProbeLog("[sync] resume failed: \(describe(error))")
            return nil
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
                    if let onConnectionLost {
                        let message = describe(error)
                        Task { @MainActor in onConnectionLost(message) }
                    }
                    break
                }
                lock.withLock { lastRid = 0 }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    private func sleepInterruptibly(milliseconds: Int) async throws {
        let duration = max(500, milliseconds)
        let alreadyWoken = sleepState.withLock { state -> Bool in
            guard state.wakeRequested else { return false }
            state.wakeRequested = false
            return true
        }
        if alreadyWoken { return }

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                try? await Task.sleep(for: .milliseconds(duration))
            }
            group.addTask {
                await self.waitForWake()
            }
            await group.next()
            group.cancelAll()
        }
        try Task.checkCancellation()
    }

    /// Parks the sync loop until `wakeSleepLoop()` or cancellation resumes it,
    /// instead of polling a flag every 250 ms.
    private func waitForWake() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let immediate = sleepState.withLock { state -> Bool in
                    guard !Task.isCancelled else { return true }
                    if state.wakeRequested {
                        state.wakeRequested = false
                        return true
                    }
                    state.continuation = continuation
                    return false
                }
                if immediate { continuation.resume() }
            }
        } onCancel: {
            let continuation = sleepState.withLock { state -> CheckedContinuation<Void, Never>? in
                let current = state.continuation
                state.continuation = nil
                return current
            }
            continuation?.resume()
        }
    }

    private func wakeSleepLoop() {
        let continuation = sleepState.withLock { state -> CheckedContinuation<Void, Never>? in
            state.wakeRequested = true
            let current = state.continuation
            state.continuation = nil
            return current
        }
        continuation?.resume()
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
        // qB long-polls return only the next rid when nothing changed; skip the
        // whole model/UI refresh in that case.
        let changed = json.keys.contains { $0 != "rid" }
        if changed, let onUpdate {
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
        async let enrichedGeneral = enrichedGeneral(general, hash: id)
        var files = await fetchedFiles
        if files.isEmpty {
            files = [FileRow(name: summary.name, size: summary.size, progress: summary.progress, priority: .normal)]
        }
        return TorrentDetails(
            general: await enrichedGeneral,
            trackers: await trackers,
            peers: await peers,
            webSeeds: await webSeeds,
            files: files
        )
    }

    /// Overlays /torrents/properties fields onto the sync-derived general info.
    private func enrichedGeneral(_ general: GeneralInfo, hash: String) async -> GeneralInfo {
        var general = general
        do {
            let data = try await fetchData(
                path: "torrents/properties",
                query: [URLQueryItem(name: "hash", value: hash)]
            )
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return general
            }
            general.wasted = (json["total_wasted"] as? NSNumber)?.int64Value ?? general.wasted
            general.connections = (json["connections"] as? NSNumber)?.intValue ?? general.connections
            general.createdBy = (json["created_by"] as? String) ?? general.createdBy
            let createdOn = (json["creation_date"] as? NSNumber)?.doubleValue ?? 0
            general.createdOn = createdOn > 0 ? Date(timeIntervalSince1970: createdOn) : general.createdOn
        } catch {
            writeProbeLog("[details] properties failed: \(describe(error))")
        }
        return general
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
                        port: (peer["port"] as? NSNumber)?.intValue ?? 0,
                        client: client,
                        flags: (peer["flags"] as? String) ?? "",
                        connection: (peer["connection"] as? String) ?? "",
                        progress: (peer["progress"] as? NSNumber)?.doubleValue ?? 0,
                        downSpeed: (peer["dl_speed"] as? NSNumber)?.int64Value ?? 0,
                        upSpeed: (peer["up_speed"] as? NSNumber)?.int64Value ?? 0,
                        country: (peer["country"] as? String) ?? "",
                        countryCode: (peer["country_code"] as? String) ?? "",
                        downloaded: (peer["downloaded"] as? NSNumber)?.int64Value ?? 0,
                        uploaded: (peer["uploaded"] as? NSNumber)?.int64Value ?? 0
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
    // MARK: Torrent boost (piece-aligned acceleration)

    /// Raw .torrent export for live torrents (metadata incl. piece hashes).
    func torrentExportData(id: String) async throws -> Data {
        try await fetchData(
            path: "torrents/export",
            query: [URLQueryItem(name: "hash", value: id)]
        )
    }

    func webSeedURLs(id: String) async -> [String] {
        await webSeedRows(hash: id).map(\.url)
    }

    /// 0/1/2 piece bitmap (include_pieces full snapshot; heavy call).
    func pieceStates(id: String) async throws -> [Int] {
        var components = URLComponents(
            url: base.appendingPathComponent("api/v2/sync/maindata"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "rid", value: "0"),
            URLQueryItem(name: "include_pieces", value: "true")
        ]
        guard let url = components?.url else { throw WebAPIError.invalidURL }
        let data = try await send(URLRequest(url: url)).0
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let torrents = root["torrents"] as? [String: [String: Any]],
              let mine = torrents[id] ?? torrents[id.uppercased()]
        else {
            writeProbeLog("[boost] pieceStates missing torrent \(id.prefix(8))")
            return []
        }
        let raw = mine["pieces"] as? [NSNumber]
        return raw?.map { $0.intValue } ?? []
    }

    // MARK - TorrentEngine mutations

    func addTorrent(source: AddSource, options: AddOptions) -> TorrentSummary {
        let summary = Self.placeholderSummary(for: source)
        writeProbeLog("[engine] real add id=\(summary.id) name=\(summary.name) savePath=\(options.savePath)")
        Task {
            do {
                try await postAdd(source: source, options: options)
                try? await syncOnce()
                prefetchOrganizers()
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

    // MARK: A4 details management

    func addTrackers(id: String, urls: [String]) {
        postAction("torrents/addTrackers", [("hash", id), ("urls", urls.joined(separator: "\n"))])
    }

    func editTracker(id: String, oldURL: String, newURL: String) {
        postAction("torrents/editTracker", [("hash", id), ("origUrl", oldURL), ("newUrl", newURL)])
    }

    func removeTrackers(id: String, urls: [String]) {
        postAction("torrents/removeTrackers", [("hash", id), ("urls", urls.joined(separator: "\n"))])
    }

    func reannounceTrackers(id: String) {
        postAction("torrents/reannounce", [("hash", id)])
    }

    func addWebSeeds(id: String, urls: [String]) {
        postAction("torrents/addWebSeeds", [("hash", id), ("urls", urls.joined(separator: "\n"))])
    }

    func editWebSeed(id: String, oldURL: String, newURL: String) {
        postAction("torrents/editWebSeed", [("hash", id), ("origUrl", oldURL), ("newUrl", newURL)])
    }

    func removeWebSeeds(id: String, urls: [String]) {
        postAction("torrents/removeWebSeeds", [("hash", id), ("urls", urls.joined(separator: "\n"))])
    }

    // MARK: A6 global transfer controls

    /// Preferences store limits in KiB/s; the UI surface is bytes/s.
    func globalDownloadLimit() async -> Int64? {
        await preferenceLimit("dl_limit")
    }

    func globalUploadLimit() async -> Int64? {
        await preferenceLimit("up_limit")
    }

    func setGlobalDownloadLimit(_ bytesPerSecond: Int64) {
        postAction("transfer/setDownloadLimit", [("limit", String(max(0, bytesPerSecond / 1024)))])
    }

    func setGlobalUploadLimit(_ bytesPerSecond: Int64) {
        postAction("transfer/setUploadLimit", [("limit", String(max(0, bytesPerSecond / 1024)))])
    }

    func toggleSpeedLimitsMode() {
        postAction("transfer/toggleSpeedLimitsMode", [])
    }

    func speedLimitsMode() async -> Bool? {
        do {
            let data = try await fetchData(path: "transfer/speedLimitsMode", query: [])
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "1"
        } catch {
            writeProbeLog("[engine] speedLimitsMode failed: \(describe(error))")
            return nil
        }
    }

    func alternativeDownloadLimit() async -> Int64? {
        await preferenceLimit("alt_dl_limit")
    }

    func alternativeUploadLimit() async -> Int64? {
        await preferenceLimit("alt_up_limit")
    }

    func applyPreferences(_ values: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: values),
              let json = String(data: data, encoding: .utf8)
        else { return }
        postAction("app/setPreferences", [("json", json)])
    }

    // MARK: Peer management (banned_IPs preference: newline-separated string)

    func bannedIPs() async -> [String] {
        do {
            let data = try await fetchData(path: "app/preferences", query: [])
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let raw = json["banned_IPs"] as? String
            else {
                writeProbeLog("[engine] banned_IPs missing from preferences shape")
                return []
            }
            return Self.splitBannedIPs(raw)
        } catch {
            writeProbeLog("[engine] bannedIPs read failed: \(describe(error))")
            return []
        }
    }

    func banIPs(_ ips: [String]) async {
        guard ips.contains(where: { !Self.trimmedIP($0).isEmpty }) else { return }
        let merged = Self.mergeBannedIPs(existing: await bannedIPs(), new: ips)
        await writeBannedIPs(merged)
    }

    func unbanIPs(_ ips: [String]) async {
        let remaining = Self.removeBannedIPs(existing: await bannedIPs(), remove: ips)
        await writeBannedIPs(remaining)
    }

    private func writeBannedIPs(_ ips: [String]) async {
        applyPreferences(["banned_IPs": ips.joined(separator: "\n")])
        let verb = ips.isEmpty ? "cleared" : "\(ips.count) entr\(ips.count == 1 ? "y" : "ies")"
        writeProbeLog("[engine] banned_IPs \(verb)")
    }

    static func trimmedIP(_ ip: String) -> String {
        ip.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func splitBannedIPs(_ raw: String) -> [String] {
        raw.split(separator: "\n", omittingEmptySubsequences: true)
            .map { trimmedIP(String($0)) }
            .filter { !$0.isEmpty }
    }

    /// Union preserving server order first, then new entries; deduped.
    static func mergeBannedIPs(existing: [String], new: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for ip in existing + new {
            let trimmed = trimmedIP(ip)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            out.append(trimmed)
        }
        return out
    }

    static func removeBannedIPs(existing: [String], remove: [String]) -> [String] {
        let cut = Set(remove.map(trimmedIP).filter { !$0.isEmpty })
        return existing.map(trimmedIP).filter { !$0.isEmpty && !cut.contains($0) }
    }

    func serverStatistics() -> ServerStatistics? {
        lock.lock()
        let state = serverState
        lock.unlock()
        guard !state.isEmpty else { return nil }
        let number = { (key: String) -> Int64 in
            (state[key] as? NSNumber)?.int64Value ?? 0
        }
        let ratioText = (state["global_ratio"] as? String) ?? "0.00"
        return ServerStatistics(
            received: number("dl_info_data"),
            sent: number("up_info_data"),
            wasted: number("total_wasted_session"),
            receivedAllTime: number("alltime_dl"),
            sentAllTime: number("alltime_ul"),
            globalRatio: Double(ratioText) ?? 0,
            freeSpaceOnDisk: number("free_space_on_disk"),
            downloadSpeed: number("dl_info_speed"),
            uploadSpeed: number("up_info_speed")
        )
    }

    // MARK: RSS

    func rssFeeds() async -> [RSSFeed]? {
        do {
            let data = try await fetchData(
                path: "rss/items",
                query: [URLQueryItem(name: "withData", value: "true")]
            )
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            var feeds: [RSSFeed] = []
            if let wrapped = root["feeds"] as? [[String: Any]] {
                for node in wrapped { collectFeeds(node, into: &feeds) }
            } else {
                collectFeeds(root, into: &feeds)
            }
            return feeds
        } catch {
            writeProbeLog("[engine] rssFeeds failed: \(describe(error))")
            return nil
        }
    }

    func addRSSFeed(url: String, path: String?) {
        var items = [("url", url)]
        if let path, !path.isEmpty { items.append(("path", path)) }
        postAction("rss/addFeed", items)
    }

    func removeRSSItem(path: String) {
        postAction("rss/removeItem", [("itemPath", path)])
    }

    func markRSSRead(path: String, articleId: Int?) {
        var items = [("itemPath", path)]
        if let articleId { items.append(("articleId", String(articleId))) }
        postAction("rss/markAsRead", items)
    }

    func refreshRSSItem(path: String) {
        postAction("rss/refreshItem", [("itemPath", path)])
    }

    // MARK: Search

    /// Names of the server's enabled search plugins. An empty array means
    /// qBittorrent can start search jobs but they will finish instantly
    /// with zero results.
    func searchPlugins() async -> [String]? {
        do {
            let data = try await fetchData(path: "search/plugins", query: [])
            guard let json = try JSONSerialization.jsonObject(with: data) as? [Any]
            else { return nil }
            var enabled: [String] = []
            for entry in json {
                if let name = entry as? String {
                    enabled.append(name)
                } else if let row = entry as? [String: Any],
                          (row["enabled"] as? Bool) ?? true,
                          let name = row["name"] as? String {
                    enabled.append(name)
                }
            }
            return enabled
        } catch {
            writeProbeLog("[engine] searchPlugins failed: \(describe(error))")
            return nil
        }
    }

    func startSearch(pattern: String, category: String) async -> Int64? {
        do {
            let data = try await postForData(
                path: "search/start",
                items: [("pattern", pattern), ("plugins", "enabled"), ("category", category)]
            )
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = (json["id"] as? NSNumber)?.int64Value
            else { return nil }
            return id
        } catch {
            writeProbeLog("[engine] startSearch failed: \(describe(error))")
            return nil
        }
    }

    func stopSearch(id: Int64) {
        postAction("search/stop", [("id", String(id))])
    }

    func deleteSearch(id: Int64) {
        postAction("search/delete", [("id", String(id))])
    }

    func searchResults(id: Int64) async -> (status: String, results: [SearchResult])? {
        do {
            let data = try await fetchData(
                path: "search/results",
                query: [URLQueryItem(name: "id", value: String(id))]
            )
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            let status = (json["status"] as? String) ?? "Running"
            guard let rows = json["results"] as? [[String: Any]] else {
                return (status, [])
            }
            let results = rows.map { row -> SearchResult in
                let number = { (key: String) -> Int64 in
                    (row[key] as? NSNumber)?.int64Value ?? 0
                }
                return SearchResult(
                    fileName: (row["fileName"] as? String) ?? "",
                    fileURL: (row["fileUrl"] as? String) ?? "",
                    fileSize: number("fileSize"),
                    seeders: number("nbSeeders"),
                    leechers: number("nbLeechers"),
                    siteURL: (row["siteUrl"] as? String) ?? "",
                    engineName: (row["engineName"] as? String) ?? ""
                )
            }
            return (status, results)
        } catch {
            writeProbeLog("[engine] searchResults failed: \(describe(error))")
            return nil
        }
    }

    private func preferenceLimit(_ key: String) async -> Int64? {
        do {
            let data = try await fetchData(path: "app/preferences", query: [])
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let kib = (json[key] as? NSNumber)?.int64Value
            else { return nil }
            return kib * 1024
        } catch {
            writeProbeLog("[engine] \(key) failed: \(describe(error))")
            return nil
        }
    }

    private static func hashParam(_ ids: [String]) -> String {
        ids.sorted().joined(separator: "|")
    }

    // MARK: A1 lifecycle parity

    func forceStart(ids: [String]) {
        postAction("torrents/forceStart", [("hashes", Self.hashParam(ids))])
    }

    func recheck(ids: [String]) {
        postAction("torrents/recheck", [("hashes", Self.hashParam(ids))])
    }

    func queue(ids: [String], move: QueueMove) {
        let path: String
        switch move {
        case .top: path = "torrents/topPrio"
        case .up: path = "torrents/increasePrio"
        case .down: path = "torrents/decreasePrio"
        case .bottom: path = "torrents/bottomPrio"
        }
        postAction(path, [("hashes", Self.hashParam(ids))])
    }

    func setLocation(ids: [String], location: String) {
        postAction("torrents/setLocation", [
            ("hashes", Self.hashParam(ids)),
            ("location", location)
        ])
    }

    func rename(id: String, name: String) {
        postAction("torrents/rename", [("hash", id), ("name", name)])
    }

    func toggleSequentialDownload(ids: [String]) {
        postAction("torrents/toggleSequentialDownload", [("hashes", Self.hashParam(ids))])
    }

    func toggleFirstLastPiecePriority(ids: [String]) {
        postAction("torrents/toggleFirstLastPiecePrio", [("hashes", Self.hashParam(ids))])
    }

    func setSuperSeeding(ids: [String], enabled: Bool) {
        postAction("torrents/setSuperSeeding", [
            ("hashes", Self.hashParam(ids)),
            ("value", enabled ? "true" : "false")
        ])
    }

    func setAutoManagement(ids: [String], enabled: Bool) {
        postAction("torrents/setAutoManagement", [
            ("hashes", Self.hashParam(ids)),
            ("enable", enabled ? "true" : "false")
        ])
    }

    private func postAction(_ path: String, _ items: [(String, String)]) {
        writeProbeLog("[engine] \(path) \(Self.form(items))")
        Task {
            do {
                try await postForm(path: path, items: items)
                try? await syncOnce()
                prefetchOrganizers()
            } catch {
                writeProbeLog("[engine] \(path) failed: \(describe(error))")
            }
        }
    }

    // MARK: A2 categories & tags

    func categories() -> [TorrentCategory] {
        lock.withLock { cachedCategories }
    }

    func tags() -> [String] {
        lock.withLock { cachedTags }
    }

    func createCategory(name: String, savePath: String?) {
        var items = [("name", name)]
        if let savePath, !savePath.isEmpty { items.append(("savePath", savePath)) }
        postAction("torrents/createCategory", items)
    }

    func editCategory(name: String, savePath: String?) {
        var items = [("name", name)]
        if let savePath, !savePath.isEmpty { items.append(("savePath", savePath)) }
        postAction("torrents/editCategory", items)
    }

    func removeCategories(names: [String]) {
        postAction("torrents/removeCategories", [("categories", names.joined(separator: "\n"))])
    }

    func setCategory(ids: [String], category: String?) {
        postAction("torrents/setCategory", [
            ("hashes", Self.hashParam(ids)),
            ("category", category ?? "")
        ])
    }

    func createTags(_ names: [String]) {
        postAction("torrents/createTags", [("tags", names.joined(separator: ","))])
    }

    func deleteTags(_ names: [String]) {
        postAction("torrents/deleteTags", [("tags", names.joined(separator: ","))])
    }

    func addTags(ids: [String], tags: [String]) {
        postAction("torrents/addTags", [("hashes", Self.hashParam(ids)), ("tags", tags.joined(separator: ","))])
    }

    func removeTags(ids: [String], tags: [String]) {
        postAction("torrents/removeTags", [("hashes", Self.hashParam(ids)), ("tags", tags.joined(separator: ","))])
    }

    /// Categories/tags are not part of the sync delta, so they are fetched
    /// (at connect and after every mutation) into a small cache the sync
    /// surface reads.
    private func prefetchOrganizers() {
        organizerTask?.cancel()
        organizerTask = Task {
            do {
                let categoriesData = try await fetchData(path: "torrents/categories", query: [])
                let tagsData = try await fetchData(path: "torrents/tags", query: [])
                let categoryMap = (try? JSONSerialization.jsonObject(with: categoriesData))
                    as? [String: [String: Any]] ?? [:]
                let categories = categoryMap
                    .map { name, fields in
                        TorrentCategory(name: name, savePath: (fields["savePath"] as? String) ?? "")
                    }
                    .sorted { $0.name < $1.name }
                let tags = ((try? JSONSerialization.jsonObject(with: tagsData)) as? [String])?
                    .sorted() ?? []
                guard !Task.isCancelled else { return }
                lock.withLock {
                    cachedCategories = categories
                    cachedTags = tags
                }
                if let onUpdate {
                    Task { @MainActor in onUpdate() }
                }
            } catch {
                writeProbeLog("[engine] organizers fetch failed: \(describe(error))")
            }
        }
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

    private func postForData(path: String, items: [(String, String)]) async throws -> Data {
        var request = URLRequest(url: base.appendingPathComponent("api/v2/\(path)"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.form(items).utf8)
        let (data, response) = try await send(request)
        try Self.requireOK(response)
        return data
    }

    /// `rss/items` returns a tree of folders, feeds and URL leaves; Drift keeps
    /// the flat list of feeds that carry `articles`. Node names arrive as
    /// "name" (current qB 5.x) or "title" (older builds).
    private func collectFeeds(_ node: [String: Any], into feeds: inout [RSSFeed]) {
        guard let name = (node["name"] as? String) ?? (node["title"] as? String)
        else { return }
        if let children = node["children"] as? [[String: Any]] {
            for child in children { collectFeeds(child, into: &feeds) }
            return
        }
        let articlesAny = node["articles"] as? [[String: Any]] ?? []
        let flag = { (key: String) -> Bool in
            (node[key] as? NSNumber)?.boolValue ?? false
        }
        let articles = articlesAny.map { article -> RSSArticle in
            RSSArticle(
                id: Int((article["id"] as? NSNumber)?.int64Value ?? 0),
                title: (article["title"] as? String) ?? "",
                torrentURL: (article["torrentURL"] as? String) ?? "",
                date: (article["date"] as? String) ?? "",
                isRead: (article["isRead"] as? NSNumber)?.boolValue ?? false,
                torrentHash: (article["torrentHash"] as? String)
            )
        }
        feeds.append(RSSFeed(
            name: name,
            url: (node["url"] as? String) ?? "",
            articles: articles,
            isLoading: flag("isLoading"),
            hasError: flag("hasError")
        ))
    }

    /// Only magnet links and http(s) URLs are handed to qBittorrent; search
    /// results and RSS articles come from remote feeds, so anything else
    /// (file://, custom schemes) must not reach `torrents/add`.
    private static func isSupportedSource(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else {
            return false
        }
        if scheme == "magnet" { return true }
        return (scheme == "http" || scheme == "https") && url.host != nil
    }

    private static func addParameters(options: AddOptions) -> [(String, String)] {
        [
            ("savepath", options.savePath),
            ("category", options.category ?? ""),
            ("tags", options.tags.joined(separator: ",")),
            ("skip_checking", options.skipChecking ? "true" : "false"),
            ("paused", options.startAutomatically ? "false" : "true"),
            ("contentLayout", options.contentLayout.rawValue),
            ("sequentialDownload", options.sequentialDownload ? "true" : "false"),
            ("firstLastPiecePrio", options.firstLastPiecePriority ? "true" : "false"),
            ("autoTMM", options.autoManaged ? "true" : "false")
        ]
    }

    private func postAdd(source: AddSource, options: AddOptions) async throws {
        var request = URLRequest(url: base.appendingPathComponent("api/v2/torrents/add"))
        request.httpMethod = "POST"
        switch source {
        case .magnetOrURL(let text):
            guard Self.isSupportedSource(text) else {
                throw WebAPIError.invalidSource
            }
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(Self.form([("urls", text)] + Self.addParameters(options: options)).utf8)
        case .torrentFile(let url):
            if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               size > Self.maxTorrentFileSize {
                throw WebAPIError.fileTooLarge
            }
            let data = try Data(contentsOf: url)
            guard data.count <= Self.maxTorrentFileSize else {
                throw WebAPIError.fileTooLarge
            }
            let boundary = "DriftBoundary-\(UUID().uuidString)"
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            var body = Data()
            let field = { (name: String, value: String) in
                body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
            }
            for (name, value) in Self.addParameters(options: options) {
                field(name, value)
            }
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

    /// Remote-facing value scrub. Server JSON is untrusted input: display
    /// strings are stripped of control characters and length-capped; numbers
    /// are coerced into sane ranges so a malformed or hostile payload can
    /// never push garbage, NaN-scale speeds or negative sizes into the UI
    /// (or, through the booster, into file writes).
    enum RemoteSanitizer {
        static let maxDisplayLength = 300
        static let maxPathLength = 2048

        static func text(_ raw: String, maxLength: Int = maxDisplayLength) -> String {
            var out = String.UnicodeScalarView()
            for scalar in raw.unicodeScalars {
                if scalar.value < 32 || scalar.value == 0x7f { continue }
                out.append(scalar)
            }
            return String(String(out).prefix(maxLength))
        }

        static func path(_ raw: String) -> String {
            text(raw, maxLength: maxPathLength)
        }

        static func int(_ raw: Any?, inRange: ClosedRange<Int64>) -> Int64 {
            guard let number = raw as? NSNumber else { return inRange.lowerBound }
            let value = number.int64Value
            return min(inRange.upperBound, max(inRange.lowerBound, value))
        }

        static func double(_ raw: Any?, inRange: ClosedRange<Double>) -> Double {
            guard let number = raw as? NSNumber else { return inRange.lowerBound }
            let value = number.doubleValue
            if value.isNaN { return inRange.lowerBound }
            // Non-finite magnitudes (±inf) still clamp into the range.
            return min(inRange.upperBound, max(inRange.lowerBound, value))
        }

        static func identifier(_ raw: String) -> String {
            let cleaned = text(raw, maxLength: 64).lowercased()
            // Torrent ids are hex hashes (40 or 64 chars); anything else is
            // displayed, not used for storage keys.
            let hex = cleaned.filter { $0.isHexDigit }
            return hex == cleaned ? cleaned : cleaned
        }
    }

    static func summary(id: String, fields: [String: Any]) -> TorrentSummary {
        let name = (fields["name"] as? String).map { RemoteSanitizer.text($0) } ?? id
        let progress = RemoteSanitizer.double(fields["progress"], inRange: 0...1)
        let size = RemoteSanitizer.int(fields["size"], inRange: 0...(1 << 62))
        let downloadSpeed = RemoteSanitizer.int(fields["dlspeed"], inRange: 0...(1 << 62))
        let uploadSpeed = RemoteSanitizer.int(fields["upspeed"], inRange: 0...(1 << 62))
        let etaRaw = RemoteSanitizer.double(fields["eta"], inRange: -1...Double(1 << 24))
        let eta: TimeInterval? = (etaRaw < 0 || etaRaw >= 8_640_000) ? nil : etaRaw
        let timeActive = RemoteSanitizer.double(fields["time_active"], inRange: 0...Double(1 << 24))
        let category = (fields["category"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let tags = ((fields["tags"] as? String) ?? "")
            .split(separator: " ")
            .map(String.init)
        let state = (fields["state"] as? String) ?? ""
        let ratio = RemoteSanitizer.double(fields["ratio"], inRange: -1...Double(1 << 12))
        let availability = RemoteSanitizer.double(fields["availability"], inRange: -1...Double(1 << 16))
        let addedOn = RemoteSanitizer.double(fields["added_on"], inRange: 0...Double(1 << 54))
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
            tags: tags,
            ratio: ratio,
            seeds: (fields["num_complete"] as? NSNumber)?.intValue ?? 0,
            peers: (fields["num_incomplete"] as? NSNumber)?.intValue ?? 0,
            availability: availability,
            downloaded: RemoteSanitizer.int(fields["downloaded"], inRange: 0...(1 << 62)),
            uploaded: RemoteSanitizer.int(fields["uploaded"], inRange: 0...(1 << 62)),
            savePath: RemoteSanitizer.path((fields["save_path"] as? String) ?? ""),
            addedOn: addedOn,
            sequential: (fields["seq_dl"] as? Bool) ?? false,
            firstLastPiecePriority: (fields["f_l_piece_prio"] as? Bool) ?? false,
            superSeeding: (fields["super_seeding"] as? Bool) ?? false,
            autoManaged: (fields["auto_tmm"] as? Bool) ?? true
        )
    }

    static func status(state: String, progress: Double) -> TorrentStatus {
        let s = state.lowercased()
        if s.hasPrefix("error") || s == "missingfiles" { return .error }
        if s.hasPrefix("checking") { return .checking }
        if s == "moving" { return .moving }
        if s == "queueddl" || s == "queuedup" { return .queued }
        if s == "stoppeddl" || s == "stoppedup"
            || s == "pauseddl" || s == "pausedup" { return .stopped }
        if s == "uploading" || s == "forcedup" || s == "stalledup" { return .seeding }
        if s == "stalleddl" { return .stalled }
        if s.contains("down") || s.contains("dl") || s.contains("meta")
            || s.contains("allocat") { return .downloading }
        return progress >= 1 ? .seeding : .downloading
    }

    // MARK: - Transport

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        // Snapshot the session; rebuildSession swaps it whenever the tunnel
        // flips (start/stop/kill-switch). In-flight tasks keep using the
        // session they were handed.
        let live = sessionBox.current
        do {
            return try await live.data(for: request)
        } catch let error as URLError {
            throw WebAPIError.network(error.localizedDescription)
        } catch {
            throw WebAPIError.network(String(describing: error))
        }
    }

    private static let maxTorrentFileSize = 100 * 1024 * 1024

    /// `application/x-www-form-urlencoded` encoding. `URLComponents` leaves
    /// `+` unescaped, but qB decodes form bodies with `+` → space, so values
    /// like `C++` or magnet `dn=name+plus` would be corrupted.
    static func form(_ items: [(String, String)]) -> String {
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        return items.map { name, value in
            let encodedName = name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(encodedName)=\(encodedValue)"
        }
        .joined(separator: "&")
    }
}
