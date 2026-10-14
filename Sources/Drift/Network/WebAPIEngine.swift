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

    func startSync() {
        lock.lock()
        syncTask?.cancel()
        lock.unlock()
        syncTask = Task { await self.syncLoop() }
    }

    func stopSync() {
        lock.lock()
        syncTask?.cancel()
        syncTask = nil
        lock.unlock()
    }

    private func syncLoop() async {
        while !Task.isCancelled {
            do {
                try await syncOnce()
                consecutiveFailures = 0
                let interval = refreshIntervalMilliseconds()
                try await Task.sleep(nanoseconds: UInt64(max(500, interval)) * 1_000_000)
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

    private func syncOnce() async throws {
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
        defer { lock.unlock() }
        return (serverState["refresh_interval"] as? NSNumber)?.intValue ?? 1500
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

    func loadDetails(for id: String) -> TorrentDetails {
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
        let files = [
            FileRow(name: summary.name, size: summary.size, progress: summary.progress, priority: .normal)
        ]
        return TorrentDetails(general: general, trackers: [], peers: [], webSeeds: [], files: files)
    }

    // MARK: - TorrentEngine mutations (deferred to Phase 8)

    func addTorrent(source: AddSource, savePath: String) -> TorrentSummary {
        writeProbeLog("[engine] real add deferred to Phase 8")
        return TorrentSummary(
            id: "real-" + UUID().uuidString.prefix(8),
            name: "New torrent",
            status: .downloading,
            progress: 0,
            size: 0,
            downloadSpeed: 0,
            uploadSpeed: 0,
            eta: nil,
            tags: []
        )
    }

    func start(ids: [String]) {
        writeProbeLog("[engine] real start deferred to Phase 8")
    }

    func stop(ids: [String]) {
        writeProbeLog("[engine] real stop deferred to Phase 8")
    }

    func remove(ids: [String], deleteFiles: Bool) {
        writeProbeLog("[engine] real remove deferred to Phase 8")
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
