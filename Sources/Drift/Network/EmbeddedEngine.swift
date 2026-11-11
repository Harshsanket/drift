import Foundation
import Network
import os

/// Embedded engine integration (EMBEDDED-ENGINE.md §4, E2).
///
/// Owns the `drift-engine` child process, the Unix-domain-socket connection
/// (length-prefixed JSON-lines, protocol v1), and a lock-protected snapshot of
/// the engine state that the synchronous `TorrentEngine` API can read.

enum EmbeddedEngineError: LocalizedError {
    case binaryMissing
    case launchFailed(String)
    case notRunning
    case timeout
    case protocolError(String)
    case shortRead
    case connectionClosed

    var errorDescription: String? {
        switch self {
        case .binaryMissing:
            "The embedded engine binary is missing from the app bundle."
        case .launchFailed(let message):
            "Could not start the embedded engine: \(message)"
        case .notRunning:
            "The embedded engine is not running."
        case .timeout:
            "Timed out connecting to the embedded engine."
        case .protocolError(let message):
            "Embedded engine protocol error: \(message)"
        case .shortRead:
            "The embedded engine sent a truncated response."
        case .connectionClosed:
            "The embedded engine connection closed."
        }
    }
}

/// JSON payload wrapper: `[String: Any]` is not Sendable, but protocol
/// messages are immutable after decode and cross one actor boundary.
struct EngineMessage: @unchecked Sendable {
    let raw: [String: Any]
}

// MARK: - Snapshot store

/// Synchronous read side of the engine state. The network side merges events
/// here; `TorrentEngine.loadTorrents()` is called on the main actor and must
/// not hop threads.
final class EmbeddedStore: @unchecked Sendable {
    private let lock = NSLock()
    private var torrentMap: [String: TorrentSummary] = [:]
    private var detailMap: [String: TorrentDetails] = [:]
    private var categoryMap: [String: TorrentCategory] = [:]
    private var tagList: [String] = []
    private var statsValue: ServerStatistics?

    func replaceAll(
        _ raw: [String: Any],
        categories: [[String: Any]]? = nil,
        tags: [String]? = nil,
        stats: [String: Any]? = nil
    ) {
        var next: [String: TorrentSummary] = [:]
        for (id, value) in raw {
            guard let object = value as? [String: Any] else { continue }
            next[id] = Self.summary(id: id, object)
        }
        var nextCategories: [String: TorrentCategory] = [:]
        for row in categories ?? [] {
            guard let name = row["name"] as? String else { continue }
            nextCategories[name] = TorrentCategory(
                name: name,
                savePath: row["savePath"] as? String ?? ""
            )
        }
        lock.lock()
        torrentMap = next
        if let categories { categoryMap = nextCategories }
        if let tags { tagList = tags }
        if let stats { statsValue = Self.statistics(stats) }
        lock.unlock()
    }

    func apply(torrents raw: [String: Any], removed: [String], stats: [String: Any]? = nil) {
        lock.lock()
        for (id, value) in raw {
            guard let object = value as? [String: Any] else { continue }
            torrentMap[id] = Self.summary(id: id, object)
        }
        for id in removed {
            torrentMap.removeValue(forKey: id)
            detailMap.removeValue(forKey: id)
        }
        if let stats { statsValue = Self.statistics(stats) }
        lock.unlock()
    }

    func categories() -> [TorrentCategory] {
        lock.lock()
        defer { lock.unlock() }
        return categoryMap.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func tags() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return tagList.sorted()
    }

    func statistics() -> ServerStatistics? {
        lock.lock()
        defer { lock.unlock() }
        return statsValue
    }

    func summaries() -> [TorrentSummary] {
        lock.lock()
        defer { lock.unlock() }
        return torrentMap.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func summary(_ id: String) -> TorrentSummary? {
        lock.lock()
        defer { lock.unlock() }
        return torrentMap[id]
    }

    func setStatus(_ ids: [String], _ status: TorrentStatus) {
        lock.lock()
        for id in ids {
            torrentMap[id]?.status = status
        }
        lock.unlock()
    }

    func remove(_ ids: [String]) {
        lock.lock()
        for id in ids {
            torrentMap.removeValue(forKey: id)
            detailMap.removeValue(forKey: id)
        }
        lock.unlock()
    }

    func upsert(_ summary: TorrentSummary) {
        lock.lock()
        torrentMap[summary.id] = summary
        lock.unlock()
    }

    func setDetails(_ details: TorrentDetails, for id: String) {
        lock.lock()
        detailMap[id] = details
        lock.unlock()
    }

    func details(for id: String) -> TorrentDetails? {
        lock.lock()
        defer { lock.unlock() }
        return detailMap[id]
    }

    // MARK: JSON mapping

    private static func string(_ value: Any?) -> String? { value as? String }
    private static func int(_ value: Any?) -> Int64 {
        if let number = value as? NSNumber { return number.int64Value }
        return 0
    }
    private static func double(_ value: Any?) -> Double {
        if let number = value as? NSNumber { return number.doubleValue }
        return 0
    }
    private static func bool(_ value: Any?) -> Bool {
        if let number = value as? NSNumber { return number.boolValue }
        return (value as? Bool) ?? false
    }

    static func statistics(_ json: [String: Any]) -> ServerStatistics {
        ServerStatistics(
            received: int(json["received"]),
            sent: int(json["sent"]),
            wasted: int(json["wasted"]),
            receivedAllTime: int(json["receivedAllTime"]),
            sentAllTime: int(json["sentAllTime"]),
            globalRatio: double(json["globalRatio"]),
            freeSpaceOnDisk: int(json["freeSpaceOnDisk"]),
            downloadSpeed: int(json["downloadSpeed"]),
            uploadSpeed: int(json["uploadSpeed"])
        )
    }

    static func summary(id: String, _ json: [String: Any]) -> TorrentSummary {
        let eta: TimeInterval? = json["eta"] is NSNull ? nil : (json["eta"] as? NSNumber)?.doubleValue
        return TorrentSummary(
            id: id,
            name: string(json["name"]) ?? "Untitled",
            status: TorrentStatus(rawValue: string(json["status"]) ?? "") ?? .downloading,
            progress: double(json["progress"]),
            size: int(json["size"]),
            downloadSpeed: int(json["downloadSpeed"]),
            uploadSpeed: int(json["uploadSpeed"]),
            eta: eta,
            timeActive: double(json["timeActive"]),
            category: string(json["category"]),
            tags: (json["tags"] as? [String]) ?? [],
            ratio: double(json["ratio"]),
            seeds: Int(int(json["seeds"])),
            peers: Int(int(json["peers"])),
            availability: double(json["availability"]),
            downloaded: int(json["downloaded"]),
            uploaded: int(json["uploaded"]),
            savePath: string(json["savePath"]) ?? "",
            addedOn: double(json["addedOn"]),
            sequential: bool(json["sequential"]),
            firstLastPiecePriority: bool(json["firstLastPiecePriority"]),
            superSeeding: bool(json["superSeeding"]),
            autoManaged: bool(json["autoManaged"])
        )
    }

    static func details(_ raw: [String: Any], fallback: TorrentSummary?) -> TorrentDetails {
        let generalJSON = raw["general"] as? [String: Any] ?? [:]
        let completed = double(generalJSON["completedOn"])
        let created = double(generalJSON["createdOn"])
        let general = GeneralInfo(
            hash: string(generalJSON["hash"]) ?? fallback?.id ?? "",
            savePath: string(generalJSON["savePath"]) ?? fallback?.savePath ?? "",
            addedOn: Date(timeIntervalSince1970: double(generalJSON["addedOn"])),
            completedOn: completed > 0 ? Date(timeIntervalSince1970: completed) : nil,
            comment: string(generalJSON["comment"]) ?? "",
            downloaded: int(generalJSON["downloaded"]),
            uploaded: int(generalJSON["uploaded"]),
            piecesTotal: Int(int(generalJSON["piecesTotal"])),
            piecesHave: Int(int(generalJSON["piecesHave"])),
            wasted: int(generalJSON["wasted"]),
            connections: Int(int(generalJSON["connections"])),
            createdBy: string(generalJSON["createdBy"]) ?? "",
            createdOn: created > 0 ? Date(timeIntervalSince1970: created) : nil
        )

        let trackers = (raw["trackers"] as? [[String: Any]] ?? []).map { row in
            TrackerRow(
                url: string(row["url"]) ?? "",
                status: string(row["status"]) ?? "Unknown",
                peers: Int(int(row["peers"])),
                seeds: Int(int(row["seeds"])),
                leeches: Int(int(row["leeches"])),
                downloaded: int(row["downloaded"])
            )
        }
        let peers = (raw["peers"] as? [[String: Any]] ?? []).map { row in
            PeerRow(
                ip: string(row["ip"]) ?? "?",
                port: Int(int(row["port"])),
                client: string(row["client"]) ?? "",
                flags: string(row["flags"]) ?? "",
                connection: string(row["connection"]) ?? "",
                progress: double(row["progress"]),
                downSpeed: int(row["downSpeed"]),
                upSpeed: int(row["upSpeed"]),
                country: string(row["country"]) ?? "",
                countryCode: string(row["countryCode"]) ?? "",
                downloaded: int(row["downloaded"]),
                uploaded: int(row["uploaded"])
            )
        }
        let webSeeds = (raw["webSeeds"] as? [[String: Any]] ?? []).compactMap { row -> WebSeedRow? in
            guard let url = string(row["url"]), !url.isEmpty else { return nil }
            return WebSeedRow(url: url)
        }
        let files = (raw["files"] as? [[String: Any]] ?? []).map { row in
            FileRow(
                name: string(row["name"]) ?? "",
                size: int(row["size"]),
                progress: double(row["progress"]),
                priority: FilePriority(apiValue: Int(int(row["priority"])))
            )
        }
        return TorrentDetails(
            general: general,
            trackers: trackers,
            peers: peers,
            webSeeds: webSeeds,
            files: files
        )
    }
}

// MARK: - UDS connection

private final class ReadyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?

    func wait(timeout: TimeInterval) async throws {
        let timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(timeout, 0.1) * 1_000_000_000))
            self?.resolve(.failure(EmbeddedEngineError.timeout))
        }
        defer { timer.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func resolve(_ value: Result<Void, Error>) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = value
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: value)
    }
}

actor EmbeddedConnection {
    private let connection: NWConnection
    private var pending: CheckedContinuation<EngineMessage, Error>?
    private var busy = false
    private var closed = false
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private var eventHandler: (@Sendable (EngineMessage) -> Void)?
    private var receiveTask: Task<Void, Never>?

    init(connection: NWConnection) {
        self.connection = connection
    }

    static func connect(path: String, timeout: TimeInterval = 10) async throws -> EmbeddedConnection {
        guard path.utf8.count < 100 else {
            throw EmbeddedEngineError.protocolError("socket path is too long")
        }
        let connection = NWConnection(to: .unix(path: path), using: .tcp)
        let gate = ReadyGate()
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                gate.resolve(.success(()))
            case .failed(let error):
                gate.resolve(.failure(error))
            case .cancelled:
                gate.resolve(.failure(EmbeddedEngineError.connectionClosed))
            default:
                break
            }
        }
        connection.start(queue: DispatchQueue(label: "drift.embedded.socket"))
        do {
            try await gate.wait(timeout: timeout)
        } catch {
            connection.cancel()
            throw error
        }
        return EmbeddedConnection(connection: connection)
    }

    func start(eventHandler: @escaping @Sendable (EngineMessage) -> Void) {
        self.eventHandler = eventHandler
        receiveTask = Task { [weak self] in
            await self?.pump()
        }
    }

    func request(_ object: EngineMessage) async throws -> EngineMessage {
        while busy && !closed {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard !closed else { throw EmbeddedEngineError.connectionClosed }
        busy = true
        defer { busy = false }
        let frame = try Self.makeFrame(object.raw)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<EngineMessage, Error>) in
            pending = continuation
            Task { [weak self] in
                do {
                    try await self?.sendFrame(frame)
                } catch {
                    await self?.failPending(error)
                }
            }
        }
    }

    func heartbeat() async {
        guard !closed, !busy else { return }
        guard let frame = try? Self.makeFrame(["op": "ping"]) else { return }
        do {
            try await sendFrame(frame)
        } catch {
            close(error: error)
        }
    }

    func waitForClose() async {
        if closed { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            closeWaiters.append(continuation)
        }
    }

    func close() {
        close(error: nil)
    }

    private func close(error: Error?) {
        guard !closed else { return }
        closed = true
        connection.cancel()
        if let pending {
            self.pending = nil
            pending.resume(throwing: error ?? EmbeddedEngineError.connectionClosed)
        }
        let waiters = closeWaiters
        closeWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func failPending(_ error: Error) {
        pending?.resume(throwing: error)
        pending = nil
    }

    private func pump() async {
        do {
            while !closed {
                let header = try await receiveExactly(4)
                let bytes = [UInt8](header)
                let length = Int(bytes[0])
                    | (Int(bytes[1]) << 8)
                    | (Int(bytes[2]) << 16)
                    | (Int(bytes[3]) << 24)
                guard length > 0, length <= 32 * 1024 * 1024 else {
                    throw EmbeddedEngineError.protocolError("invalid frame length \(length)")
                }
                let payload = try await receiveExactly(length)
                guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
                    throw EmbeddedEngineError.protocolError("frame is not a JSON object")
                }
                handle(EngineMessage(raw: object))
            }
        } catch {
            close(error: error)
        }
    }

    private func handle(_ message: EngineMessage) {
        let op = message.raw["op"] as? String ?? ""
        if op == "state" || op == "alert" || op == "log" || op == "pong" {
            eventHandler?(message)
            return
        }
        guard let pending else { return }
        self.pending = nil
        pending.resume(returning: message)
    }

    private func receiveExactly(_ count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let data, data.count == count {
                    continuation.resume(returning: data)
                    return
                }
                if isComplete {
                    continuation.resume(throwing: EmbeddedEngineError.connectionClosed)
                    return
                }
                continuation.resume(throwing: EmbeddedEngineError.shortRead)
            }
        }
    }

    private func sendFrame(_ frame: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private static func makeFrame(_ object: [String: Any]) throws -> Data {
        let payload = try JSONSerialization.data(withJSONObject: object)
        var frame = Data(capacity: payload.count + 4)
        var length = UInt32(payload.count).littleEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }
}

// MARK: - Engine

final class EmbeddedEngine: TorrentEngine, @unchecked Sendable {
    static let shared = EmbeddedEngine()

    var onUpdate: (@MainActor @Sendable () -> Void)?
    var onConnectionLost: (@MainActor @Sendable (String) -> Void)?

    private let stateDir: URL
    private let socketPath: String
    private let binaryURL: URL?
    private let searchConfigurationOverride: ExternalSearchConfiguration?
    private let urlSession: URLSession
    private let store = EmbeddedStore()
    private let stateLock = NSLock()
    private let searchLock = NSLock()
    private var searchStates: [Int64: (status: String, results: [SearchResult])] = [:]
    private var searchTasks: [Int64: Task<Void, Never>] = [:]
    private var nextSearchID: Int64 = 1
    private var supervisorTask: Task<Void, Never>?
    private var connection: EmbeddedConnection?
    private var process: Process?
    private var stopping = false
    private var connected = false
    private var version = "embedded"
    private var readyWaiters: [CheckedContinuation<String, Error>] = []
    private var startError: Error?

    init(
        stateDir: URL? = nil,
        socketPath: String? = nil,
        binaryURL: URL? = nil,
        searchConfiguration: ExternalSearchConfiguration? = nil,
        urlSession: URLSession = .shared
    ) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let defaultDir = support.appendingPathComponent("Drift/engine", isDirectory: true)
        self.stateDir = stateDir ?? defaultDir
        self.socketPath = socketPath ?? defaultDir.appendingPathComponent("engine.sock").path
        self.binaryURL = binaryURL
        self.searchConfigurationOverride = searchConfiguration
        self.urlSession = urlSession
    }

    var isConnected: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return connected
    }

    func currentConnection() -> EmbeddedConnection? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return connection
    }

    // MARK: Lifecycle

    func start() async throws -> String {
        let current: (connected: Bool, version: String, error: Error?) = stateLock.withLock {
            (connected, version, startError)
        }
        if current.connected { return current.version }
        if let error = current.error { throw error }
        _ = ensureSupervisor()

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let outcome: (version: String?, error: Error?) = stateLock.withLock {
                if connected { return (version, nil) }
                if let startError { return (nil, startError) }
                readyWaiters.append(continuation)
                return (nil, nil)
            }
            if let version = outcome.version {
                continuation.resume(returning: version)
            } else if let error = outcome.error {
                continuation.resume(throwing: error)
            }
        }
    }

    func stop() async {
        let current = stateLock.withLock {
            stopping = true
            let task = supervisorTask
            let connection = connection
            let process = process
            supervisorTask = nil
            self.connection = nil
            connected = false
            self.process = nil
            return (task, connection, process)
        }
        let (task, connection, process) = current

        task?.cancel()
        if let connection { await connection.close() }
        if let process, process.isRunning {
            process.terminate()
            for _ in 0..<50 {
                if !process.isRunning { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }

    /// Process-exit path: terminate without awaiting (the engine's own
    /// watchdog also reaps it if the app dies before this runs).
    func terminateNow() {
        stateLock.lock()
        stopping = true
        let task = supervisorTask
        let connection = connection
        let process = process
        supervisorTask = nil
        self.connection = nil
        connected = false
        self.process = nil
        stateLock.unlock()
        task?.cancel()
        if let connection { Task { await connection.close() } }
        process?.terminate()
    }

    private func ensureSupervisor() -> Task<Void, Never> {
        stateLock.lock()
        defer { stateLock.unlock() }
        if let supervisorTask { return supervisorTask }
        stopping = false
        startError = nil
        let task = Task { [weak self] in
            guard let self else { return }
            await self.supervise()
        }
        supervisorTask = task
        return task
    }

    private func isStopping() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopping
    }

    private func supervise() async {
        var backoff: UInt64 = 1
        while !isStopping() {
            do {
                try ensureProcess()
                let connection = try await connectWithRetry()
                await connection.start { [weak self] event in
                    self?.handle(event)
                }
                let hello = try await connection.request(EngineMessage(raw: ["op": "hello", "v": 1]))
                guard (hello.raw["v"] as? Int) == 1 else {
                    throw EmbeddedEngineError.protocolError("unsupported protocol version")
                }
                let libtorrent = hello.raw["libtorrent"] as? String ?? "unknown"
                backoff = 1
                markConnected(connection, libtorrent: libtorrent)
                try await refresh(using: connection)

                let heartbeat = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                        guard let self, let connection = self.currentConnection() else { return }
                        await connection.heartbeat()
                    }
                }
                await connection.waitForClose()
                heartbeat.cancel()
                markDisconnected(nil)
            } catch {
                markDisconnected(error)
                if isStopping() { break }
                try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
                backoff = min(backoff * 2, 30)
            }
        }
        stateLock.withLock {
            supervisorTask = nil
        }
    }

    private func markConnected(_ connection: EmbeddedConnection, libtorrent: String) {
        stateLock.lock()
        self.connection = connection
        connected = true
        startError = nil
        let waiters = readyWaiters
        readyWaiters.removeAll()
        stateLock.unlock()
        writeProbeLog("[embedded] connected libtorrent=\(libtorrent)")
        for waiter in waiters { waiter.resume(returning: version) }
        notifyUpdate()
    }

    private func markDisconnected(_ error: Error?) {
        stateLock.lock()
        let wasConnected = connected
        connection = nil
        connected = false
        let waiters = readyWaiters
        readyWaiters.removeAll()
        if !wasConnected, let error {
            startError = error
        }
        stateLock.unlock()
        if !wasConnected {
            if let error {
                for waiter in waiters { waiter.resume(throwing: error) }
            }
        } else if let error {
            writeProbeLog("[embedded] disconnected: \(error.localizedDescription)")
            notifyConnectionLost(error.localizedDescription)
        }
    }

    private func notifyUpdate() {
        guard let onUpdate else { return }
        Task { @MainActor in onUpdate() }
    }

    private func notifyConnectionLost(_ message: String) {
        guard let onConnectionLost else { return }
        Task { @MainActor in onConnectionLost(message) }
    }

    private func handle(_ event: EngineMessage) {
        let event = event.raw
        guard let op = event["op"] as? String else { return }
        switch op {
        case "state":
            let torrents = event["torrents"] as? [String: Any] ?? [:]
            let removed = event["torrents_removed"] as? [String] ?? []
            store.apply(
                torrents: torrents,
                removed: removed,
                stats: event["stats"] as? [String: Any]
            )
            notifyUpdate()
        case "alert":
            if (event["level"] as? String) == "error", let message = event["message"] as? String {
                writeProbeLog("[embedded] alert \(message)")
            }
        case "log":
            if let message = event["message"] as? String {
                writeProbeLog("[engine] \(message)")
            }
        default:
            break
        }
    }

    private func refresh(using connection: EmbeddedConnection) async throws {
        let response = try await connection.request(EngineMessage(raw: ["op": "list"]))
        guard let torrents = response.raw["torrents"] as? [String: Any] else { return }
        store.replaceAll(
            torrents,
            categories: response.raw["categories"] as? [[String: Any]],
            tags: response.raw["tags"] as? [String],
            stats: response.raw["stats"] as? [String: Any]
        )
        notifyUpdate()
    }

    /// Fire-and-forget list refresh after a mutation whose visible result is
    /// engine-owned (categories, tags, names, locations).
    private func refreshSoon() {
        Task { [weak self] in
            guard let self, let connection = self.currentConnection() else { return }
            try? await self.refresh(using: connection)
        }
    }

    private func request(_ message: EngineMessage) async throws -> [String: Any] {
        guard let connection = currentConnection() else {
            throw EmbeddedEngineError.notRunning
        }
        return try await connection.request(message).raw
    }

    private func request(_ object: [String: Any]) async throws -> [String: Any] {
        try await request(EngineMessage(raw: object))
    }

    // MARK: Process + socket

    private func connectWithRetry() async throws -> EmbeddedConnection {
        var lastError: Error = EmbeddedEngineError.timeout
        for _ in 0..<30 {
            if isStopping() { throw EmbeddedEngineError.notRunning }
            do {
                return try await EmbeddedConnection.connect(path: socketPath, timeout: 1)
            } catch {
                lastError = error
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        throw lastError
    }

    private func ensureProcess() throws {
        stateLock.lock()
        let existing = process
        let isStopping = stopping
        stateLock.unlock()
        if let existing, existing.isRunning { return }
        if isStopping { throw EmbeddedEngineError.notRunning }

        guard let binary = binaryURL ?? Self.locateBinary() else {
            throw EmbeddedEngineError.binaryMissing
        }
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw EmbeddedEngineError.binaryMissing
        }
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)

        let child = Process()
        child.executableURL = binary
        child.arguments = ["--state-dir", stateDir.path, "--socket", socketPath]
        child.currentDirectoryURL = stateDir
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice

        stateLock.lock()
        if stopping {
            stateLock.unlock()
            throw EmbeddedEngineError.notRunning
        }
        process = child
        stateLock.unlock()

        do {
            try child.run()
            writeProbeLog("[embedded] engine pid=\(child.processIdentifier) path=\(binary.path)")
        } catch {
            stateLock.lock()
            process = nil
            stateLock.unlock()
            throw EmbeddedEngineError.launchFailed(error.localizedDescription)
        }
    }

    private static func locateBinary() -> URL? {
        let manager = FileManager.default
        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment["DRIFT_ENGINE_BINARY"] {
            candidates.append(URL(fileURLWithPath: override))
        }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/drift-engine"))
        if let executable = Bundle.main.executableURL {
            candidates.append(executable.deletingLastPathComponent().appendingPathComponent("drift-engine"))
        }
        let cwd = URL(fileURLWithPath: manager.currentDirectoryPath)
        candidates.append(cwd.appendingPathComponent("engine/build/drift-engine"))
        candidates.append(cwd.appendingPathComponent(".build/Drift.app/Contents/MacOS/drift-engine"))
        return candidates.first { manager.isExecutableFile(atPath: $0.path) }
    }

    // MARK: TorrentEngine — reads

    func loadTorrents() -> [TorrentSummary] {
        store.summaries()
    }

    func loadDetails(for id: String) -> TorrentDetails {
        store.details(for: id) ?? placeholderDetails(for: id)
    }

    func fetchDetails(for id: String) async -> TorrentDetails {
        guard let connection = currentConnection() else { return loadDetails(for: id) }
        do {
            let response = try await connection.request(EngineMessage(raw: ["op": "details", "id": id]))
            guard let raw = response.raw["torrent"] as? [String: Any] else {
                return loadDetails(for: id)
            }
            let details = EmbeddedStore.details(raw, fallback: store.summary(id))
            store.setDetails(details, for: id)
            return details
        } catch {
            writeProbeLog("[embedded] details failed: \(error.localizedDescription)")
            return loadDetails(for: id)
        }
    }

    func transferActivity() -> Bool {
        store.summaries().contains { summary in
            summary.downloadSpeed > 0
                || summary.uploadSpeed > 0
                || summary.status == .downloading
        }
    }

    func serverStatistics() -> ServerStatistics? {
        store.statistics()
    }

    func categories() -> [TorrentCategory] {
        store.categories()
    }

    func tags() -> [String] {
        store.tags()
    }

    private func placeholderDetails(for id: String) -> TorrentDetails {
        let summary = store.summary(id)
        let general = GeneralInfo(
            hash: id,
            savePath: summary?.savePath ?? "",
            addedOn: Date(timeIntervalSince1970: summary?.addedOn ?? 0),
            completedOn: nil,
            comment: "",
            downloaded: summary?.downloaded ?? 0,
            uploaded: summary?.uploaded ?? 0,
            piecesTotal: 0,
            piecesHave: 0
        )
        let files = summary.map {
            [FileRow(name: $0.name, size: $0.size, progress: $0.progress, priority: .normal)]
        } ?? []
        return TorrentDetails(
            general: general,
            trackers: [],
            peers: [],
            webSeeds: [],
            files: files
        )
    }

    // MARK: TorrentEngine — mutations

    func addTorrent(source: AddSource, options: AddOptions) -> TorrentSummary {
        let placeholder = Self.placeholder(for: source)
        let optionsDictionary = Self.optionsDictionary(options)

        switch source {
        case .magnetOrURL(let text):
            let lower = text.lowercased()
            if lower.hasPrefix("magnet:") || lower.contains("xt=urn:btih") {
                submitAdd([
                    "op": "add",
                    "magnet": text,
                    "options": optionsDictionary,
                ], placeholder: placeholder)
            } else if let url = URL(string: text),
                      let scheme = url.scheme?.lowercased(),
                      scheme == "http" || scheme == "https" {
                store.upsert(placeholder)
                notifyUpdate()
                downloadAndAdd(url, options: optionsDictionary, placeholder: placeholder)
            } else {
                writeProbeLog("[embedded] add rejected source=\(text.prefix(40))")
            }
        case .torrentFile(let url):
            guard let data = try? Data(contentsOf: url), data.count <= 100 * 1024 * 1024 else {
                writeProbeLog("[embedded] add rejected file=\(url.lastPathComponent)")
                return placeholder
            }
            submitAdd([
                "op": "add",
                "torrent": data.base64EncodedString(),
                "options": optionsDictionary,
            ], placeholder: placeholder)
        }
        return placeholder
    }

    private func submitAdd(_ request: [String: Any], placeholder: TorrentSummary) {
        store.upsert(placeholder)
        notifyUpdate()
        writeProbeLog("[embedded] add id=\(placeholder.id) name=\(placeholder.name)")
        let message = EngineMessage(raw: request)
        Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await self.request(message)
                if let id = response["id"] as? String {
                    writeProbeLog("[embedded] add accepted id=\(id)")
                }
                if let connection = self.currentConnection() {
                    try? await self.refresh(using: connection)
                }
            } catch {
                writeProbeLog("[embedded] add failed: \(error.localizedDescription)")
                self.store.remove([placeholder.id])
                self.notifyUpdate()
            }
        }
    }

    /// Search results may point at a .torrent URL rather than a magnet. Fetch
    /// it with the same HTTP stack and add it as a torrent file.
    private func downloadAndAdd(
        _ url: URL,
        options: [String: Any],
        placeholder: TorrentSummary
    ) {
        let session = urlSession
        let optionsMessage = EngineMessage(raw: options)
        Task { [weak self] in
            guard let self else { return }
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 30
                request.cachePolicy = .reloadIgnoringLocalCacheData
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      data.count <= 100 * 1024 * 1024
                else {
                    throw EmbeddedEngineError.protocolError("torrent download rejected")
                }
                let message = EngineMessage(raw: [
                    "op": "add",
                    "torrent": data.base64EncodedString(),
                    "options": optionsMessage.raw,
                ])
                _ = try await self.request(message)
                if let connection = self.currentConnection() {
                    try? await self.refresh(using: connection)
                }
            } catch {
                writeProbeLog("[embedded] torrent URL add failed: \(error.localizedDescription)")
                self.store.remove([placeholder.id])
                self.notifyUpdate()
            }
        }
    }

    func start(ids: [String]) {
        guard !ids.isEmpty else { return }
        Task { [weak self] in
            _ = try? await self?.request(["op": "start", "ids": ids])
        }
    }

    func stop(ids: [String]) {
        guard !ids.isEmpty else { return }
        store.setStatus(ids, .stopped)
        notifyUpdate()
        Task { [weak self] in
            _ = try? await self?.request(["op": "stop", "ids": ids])
        }
    }

    func remove(ids: [String], deleteFiles: Bool) {
        guard !ids.isEmpty else { return }
        store.remove(ids)
        notifyUpdate()
        Task { [weak self] in
            _ = try? await self?.request([
                "op": "remove",
                "ids": ids,
                "deleteFiles": deleteFiles,
            ])
        }
    }

    private func mutate(_ request: [String: Any], refresh: Bool = false) {
        let message = EngineMessage(raw: request)
        Task { [weak self] in
            guard let self else { return }
            _ = try? await self.request(message)
            if refresh { self.refreshSoon() }
        }
    }

    // MARK: E3 parity wave

    func forceStart(ids: [String]) {
        guard !ids.isEmpty else { return }
        mutate(["op": "force_start", "ids": ids])
    }

    func recheck(ids: [String]) {
        guard !ids.isEmpty else { return }
        mutate(["op": "recheck", "ids": ids])
    }

    func queue(ids: [String], move: QueueMove) {
        guard !ids.isEmpty else { return }
        mutate(["op": "queue", "ids": ids, "move": move.rawValue])
    }

    func setLocation(ids: [String], location: String) {
        guard !ids.isEmpty else { return }
        mutate(["op": "set_location", "ids": ids, "location": location])
    }

    func rename(id: String, name: String) {
        mutate(["op": "rename", "id": id, "name": name], refresh: true)
    }

    func toggleSequentialDownload(ids: [String]) {
        guard let first = ids.first, let summary = store.summary(first) else { return }
        mutate(["op": "set_flags", "ids": ids, "sequential": !summary.sequential])
    }

    func toggleFirstLastPiecePriority(ids: [String]) {
        guard let first = ids.first, let summary = store.summary(first) else { return }
        mutate([
            "op": "set_flags",
            "ids": ids,
            "firstLastPiecePriority": !summary.firstLastPiecePriority,
        ])
    }

    func setSuperSeeding(ids: [String], enabled: Bool) {
        guard !ids.isEmpty else { return }
        mutate(["op": "set_flags", "ids": ids, "superSeeding": enabled])
    }

    func setAutoManagement(ids: [String], enabled: Bool) {
        guard !ids.isEmpty else { return }
        mutate(["op": "set_flags", "ids": ids, "autoManaged": enabled])
    }

    func setFilePriority(id: String, fileIndex: Int, priority: FilePriority) {
        mutate([
            "op": "file_priority",
            "id": id,
            "fileIndex": fileIndex,
            "priority": priority.apiValue,
        ])
    }

    func createCategory(name: String, savePath: String?) {
        mutate([
            "op": "create_category",
            "name": name,
            "savePath": savePath ?? "",
        ], refresh: true)
    }

    func editCategory(name: String, savePath: String?) {
        mutate([
            "op": "edit_category",
            "name": name,
            "savePath": savePath ?? "",
        ], refresh: true)
    }

    func removeCategories(names: [String]) {
        guard !names.isEmpty else { return }
        mutate(["op": "remove_categories", "names": names], refresh: true)
    }

    func setCategory(ids: [String], category: String?) {
        guard !ids.isEmpty else { return }
        mutate([
            "op": "set_category",
            "ids": ids,
            "category": category ?? "",
        ])
    }

    func createTags(_ names: [String]) {
        guard !names.isEmpty else { return }
        mutate(["op": "create_tags", "names": names], refresh: true)
    }

    func deleteTags(_ names: [String]) {
        guard !names.isEmpty else { return }
        mutate(["op": "delete_tags", "names": names], refresh: true)
    }

    func addTags(ids: [String], tags: [String]) {
        guard !ids.isEmpty, !tags.isEmpty else { return }
        mutate(["op": "add_tags", "ids": ids, "tags": tags])
    }

    func removeTags(ids: [String], tags: [String]) {
        guard !ids.isEmpty, !tags.isEmpty else { return }
        mutate(["op": "remove_tags", "ids": ids, "tags": tags])
    }

    func addTrackers(id: String, urls: [String]) {
        guard !urls.isEmpty else { return }
        mutate(["op": "add_trackers", "id": id, "urls": urls])
    }

    func editTracker(id: String, oldURL: String, newURL: String) {
        mutate(["op": "edit_tracker", "id": id, "oldURL": oldURL, "newURL": newURL])
    }

    func removeTrackers(id: String, urls: [String]) {
        guard !urls.isEmpty else { return }
        mutate(["op": "remove_trackers", "id": id, "urls": urls])
    }

    func reannounceTrackers(id: String) {
        mutate(["op": "reannounce", "id": id])
    }

    func addWebSeeds(id: String, urls: [String]) {
        guard !urls.isEmpty else { return }
        mutate(["op": "add_web_seeds", "id": id, "urls": urls])
    }

    func editWebSeed(id: String, oldURL: String, newURL: String) {
        mutate(["op": "edit_web_seed", "id": id, "oldURL": oldURL, "newURL": newURL])
    }

    func removeWebSeeds(id: String, urls: [String]) {
        guard !urls.isEmpty else { return }
        mutate(["op": "remove_web_seeds", "id": id, "urls": urls])
    }

    func bannedIPs() async -> [String] {
        guard let response = try? await request(["op": "banned_ips"]) else { return [] }
        return (response["ips"] as? [String]) ?? []
    }

    func banIPs(_ ips: [String]) async {
        guard !ips.isEmpty else { return }
        _ = try? await request(["op": "ban_ips", "ips": ips])
    }

    func unbanIPs(_ ips: [String]) async {
        guard !ips.isEmpty else { return }
        _ = try? await request(["op": "unban_ips", "ips": ips])
    }

    func setGlobalDownloadLimit(_ bytesPerSecond: Int64) {
        Task { [weak self] in
            _ = try? await self?.request([
                "op": "set_limits",
                "download": max(0, bytesPerSecond),
            ])
        }
    }

    func setGlobalUploadLimit(_ bytesPerSecond: Int64) {
        Task { [weak self] in
            _ = try? await self?.request([
                "op": "set_limits",
                "upload": max(0, bytesPerSecond),
            ])
        }
    }

    func globalDownloadLimit() async -> Int64? {
        guard let response = try? await request(["op": "limits"]) else { return nil }
        return (response["download"] as? NSNumber)?.int64Value
    }

    func globalUploadLimit() async -> Int64? {
        guard let response = try? await request(["op": "limits"]) else { return nil }
        return (response["upload"] as? NSNumber)?.int64Value
    }

    // MARK: External search (E4)

    func startSearch(pattern: String, category: String) async -> Int64? {
        let configuration: ExternalSearchConfiguration?
        if let override = searchConfigurationOverride {
            configuration = override
        } else {
            configuration = await MainActor.run { ExternalSearchSettings.shared.configuration }
        }
        guard let configuration, configuration.isConfigured else { return nil }

        let id: Int64 = searchLock.withLock {
            let value = nextSearchID
            nextSearchID += 1
            searchStates[value] = (status: "Running", results: [])
            return value
        }

        let session = urlSession
        let task = Task { [weak self] in
            do {
                let results = try await ExternalSearchClient(session: session).search(
                    configuration: configuration,
                    query: pattern,
                    category: category
                )
                self?.finishSearch(id, results: results)
            } catch {
                writeProbeLog("[search] external failed: \(error.localizedDescription)")
                self?.finishSearch(id, results: [])
            }
        }
        searchLock.withLock {
            searchTasks[id] = task
        }
        writeProbeLog("[search] external started id=\(id)")
        return id
    }

    func searchResults(id: Int64) async -> (status: String, results: [SearchResult])? {
        searchLock.withLock {
            searchStates[id]
        }
    }

    func stopSearch(id: Int64) {
        searchLock.lock()
        let task = searchTasks[id]
        if var state = searchStates[id] {
            state.status = "Stopped"
            searchStates[id] = state
        }
        searchLock.unlock()
        task?.cancel()
        writeProbeLog("[search] external stopped id=\(id)")
    }

    func deleteSearch(id: Int64) {
        searchLock.lock()
        let task = searchTasks.removeValue(forKey: id)
        searchStates.removeValue(forKey: id)
        searchLock.unlock()
        task?.cancel()
    }

    private func finishSearch(_ id: Int64, results: [SearchResult]) {
        searchLock.lock()
        searchStates[id] = (status: "Stopped", results: results)
        searchTasks[id] = nil
        searchLock.unlock()
        writeProbeLog("[search] external finished id=\(id) results=\(results.count)")
    }

    func applyPreferences(_ values: [String: Any]) {
        // Only the global speed limits map onto the embedded session in E3;
        // alternative limits are a qBittorrent scheduling feature.
        if let download = values["dl_limit"] as? Int {
            setGlobalDownloadLimit(Int64(download) * 1024)
        }
        if let upload = values["up_limit"] as? Int {
            setGlobalUploadLimit(Int64(upload) * 1024)
        }
    }

    // MARK: Placeholders

    private static func optionsDictionary(_ options: AddOptions) -> [String: Any] {
        var values: [String: Any] = [
            "savePath": options.savePath,
            "stopped": !options.startAutomatically,
            "sequential": options.sequentialDownload,
            "firstLastPiecePriority": options.firstLastPiecePriority,
            "autoManaged": options.autoManaged,
        ]
        if let category = options.category, !category.isEmpty {
            values["category"] = category
        }
        if !options.tags.isEmpty {
            values["tags"] = options.tags
        }
        return values
    }

    private static func placeholder(for source: AddSource) -> TorrentSummary {
        switch source {
        case .magnetOrURL(let text):
            let httpName = URL(string: text).flatMap { url -> String? in
                let scheme = url.scheme?.lowercased() ?? ""
                guard scheme == "http" || scheme == "https" else { return nil }
                let name = url.deletingPathExtension().lastPathComponent
                return name.isEmpty ? url.host : name
            }
            let hash = magnetHash(in: text) ?? "adding-" + String(UUID().uuidString.prefix(8))
            return TorrentSummary(
                id: hash,
                name: magnetName(in: text) ?? httpName ?? "Torrent link",
                status: .downloading,
                progress: 0,
                size: 0,
                downloadSpeed: 0,
                uploadSpeed: 0,
                eta: nil,
                tags: []
            )
        case .torrentFile(let url):
            return TorrentSummary(
                id: "adding-" + String(UUID().uuidString.prefix(8)),
                name: url.deletingPathExtension().lastPathComponent,
                status: .downloading,
                progress: 0,
                size: 0,
                downloadSpeed: 0,
                uploadSpeed: 0,
                eta: nil,
                tags: []
            )
        }
    }

    private static func magnetHash(in text: String) -> String? {
        guard let range = text.range(of: "urn:btih:") else { return nil }
        let tail = text[range.upperBound...]
        let hash = tail.prefix { $0 != "&" && $0 != "?" }
        let value = String(hash)
        return value.count == 40 ? value.lowercased() : nil
    }

    private static func magnetName(in text: String) -> String? {
        guard let range = text.range(of: "dn=") else { return nil }
        let tail = text[range.upperBound...]
        let value = String(tail.prefix { $0 != "&" })
        return value.removingPercentEncoding?.replacingOccurrences(of: "+", with: " ")
    }
}
