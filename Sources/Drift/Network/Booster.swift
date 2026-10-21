import Foundation
import Observation
import os

/// Plexo-style download accelerator for Drift's own (direct) downloads:
/// one logical file fetched through a pool of parallel ranged HTTP(S)
/// requests, each pool member picking the next unfinished chunk — faster
/// connections naturally absorb more work, the last slow chunks get raced
/// in the endgame, and a persisted chunk bitmap survives pause/relaunch.
/// Honest scope: this accelerates Drift-direct downloads from this Mac;
/// torrent traffic runs inside the remote qB daemon and is unaffected
/// (Stage B adds true multi-interface binding).
@MainActor
@Observable
final class DownloadCenter {
    static let shared = DownloadCenter()

    private(set) var downloads: [DirectDownload] = []
    /// Live torrent piece-boost tasks (Connection Booster's torrent mode).
    private(set) var boosts: [TorrentBoostTask] = []
    /// Eligibility of known downloading torrents, keyed by hash:
    /// count of HTTP web seeds the server reports.
    var boostable: [String: BoostEligibility] = [:]

    private init() {
        for record in DownloadSidecar.storedRecords() {
            downloads.append(DirectDownload(sidecar: record))
        }
    }

    /// Starts a piece boost for a torrent. Returns the task even when
    /// planning fails (it carries the error row).
    @MainActor
    @discardableResult
    func startBoost(
        id: String, name: String, savePath: String, extraMirror: String? = nil
    ) -> TorrentBoostTask? {
        guard BoosterSettings.shared.enabled else {
            writeProbeLog("[booster] boost ignored: booster disabled")
            return nil
        }
        guard let real = EngineHolder.shared.current as? WebAPIEngine else {
            writeProbeLog("[booster] boost needs a connected web engine")
            return nil
        }
        let existing = boosts.first { $0.hash == id && $0.status != .failed && $0.status != .done }
        if let existing { return existing }
        let task = TorrentBoostTask(
            engine: real, hash: id, torrentName: name, savePath: savePath,
            extraMirror: extraMirror
        )
        boosts.append(task)
        task.start()
        writeProbeLog("[booster] boost queued id=\(id) name=\(name.prefix(60))")
        return task
    }

    func cancelBoost(_ task: TorrentBoostTask) {
        task.cancel()
    }

    /// ListViewModel feeds downloading torrents here every refresh tick so
    /// the UI (row badge + context menu) can show which torrents are
    /// boostable. The map mirrors the active download set: entries are
    /// pruned when a torrent stops, and cleared while the booster is off.
    func noteDownloadingTorrents(_ torrents: [(hash: String, name: String, savePath: String)]) async {
        guard BoosterSettings.shared.enabled else {
            boostable = [:]
            return
        }
        let seen = Set(torrents.map(\.hash))
        boostable = boostable.filter { seen.contains($0.key) }
        guard !torrents.isEmpty else { return }
        guard let real = EngineHolder.shared.current as? WebAPIEngine else { return }
        for torrent in torrents {
            let current = boostable[torrent.hash]
            if let current, Date().timeIntervalSince(current.fresh) < 3600 { continue }
            let seeds = await real.webSeedURLs(id: torrent.hash)
            let usable = seeds.filter { url in
                url.lowercased().hasPrefix("http")
            }
            boostable[torrent.hash] = BoostEligibility(
                webSeedCount: usable.count, seeds: Array(usable.prefix(6)), fresh: Date()
            )
        }
    }

    func eligibility(for hash: String) -> BoostEligibility? {
        boostable[hash]
    }

    func remove(_ download: DirectDownload) {
        download.deleteEverything()
        downloads.removeAll { $0 === download }
        writeProbeLog("[booster] removed id=\(download.id)")
    }

    /// Model-level direct-download add; no UI entry anymore (booster URL
    /// mode was removed), but the test harness and this accessor remain.
    func add(urlString: String) -> DirectDownload? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        let settings = BoosterSettings.shared
        let saveDestination = replaceSaveDestination()
        let download = DirectDownload(
            url: url,
            destination: saveDestination,
            streams: settings.streamCount,
            allowCellular: settings.allowCellular,
            slowModeMbps: settings.slowModeMbps == 0 ? nil : settings.slowModeMbps
        )
        downloads.append(download)
        writeProbeLog("[booster] added id=\(download.id) streams=\(download.streams) url=\(urlString.prefix(80))")
        return download
    }

    private func replaceSaveDestination() -> String {
        let raw = AppSettings.shared.defaultSavePath
        return ((raw.isEmpty ? "~/Downloads" : raw) as NSString).expandingTildeInPath
    }

    /// UI escape hatch for "Open Destination Folder": verdict gate only —
    /// the UI never decides by itself whether an arbitrary path may be
    /// fed into an NSWorkspace open call.
    func openDestinationFolder(_ expanded: String) -> Bool {
        FileGateway.canOpenDirectory(forDisplay: expanded)
    }

    /// Test-hook support: removes a probe seed file (state layer is the only
    /// place the app is allowed to touch FileManager directly).
    func deleteProbeSeed(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Elongated web-seed availability snapshot for one torrent.
struct BoostEligibility {
    var webSeedCount: Int
    var seeds: [String]
    var fresh: Date

    var boostable: Bool { webSeedCount > 0 }
}

/// Shared access to the connected engine for booster-adjacent surfaces
/// (lives alongside ListViewModel, which owns the engine lifecycle).
@MainActor
final class EngineHolder {
    static let shared = EngineHolder()
    var current: (any TorrentEngine)?
}

/// Booster settings for the Connection Booster (Drift-direct downloads).
@MainActor
@Observable
final class BoosterSettings {
    static let shared = BoosterSettings()

    private static let storageKey = "drift.boosterConfig"

    enum StreamMode: String, CaseIterable, Identifiable, Codable {
        case auto
        case fixed

        var id: String { rawValue }

        var label: String {
            switch self {
            case .auto: "Auto"
            case .fixed: "Fixed"
            }
        }
    }

    var mode: StreamMode
    var fixedStreams: Int
    /// 0 = no cap.
    var slowModeMbps: Double
    var allowCellular: Bool
    /// Master switch for the Connection Booster (piece boosting + direct
    /// downloads); disabled inbound torrents are never touched.
    var enabled: Bool

    var streamCount: Int {
        mode == .auto ? 6 : max(2, min(16, fixedStreams))
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(Backup.self, from: data) {
            mode = decoded.mode
            fixedStreams = decoded.fixedStreams
            slowModeMbps = decoded.slowModeMbps
            allowCellular = decoded.allowCellular
            enabled = decoded.enabled
        } else {
            mode = .auto
            fixedStreams = 6
            slowModeMbps = 0
            allowCellular = false
            enabled = true
        }
    }

    func save() {
        let backup = Backup(
            mode: mode,
            fixedStreams: fixedStreams,
            slowModeMbps: slowModeMbps,
            allowCellular: allowCellular,
            enabled: enabled
        )
        if let data = try? JSONEncoder().encode(backup) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
        writeProbeLog(
            "[booster] settings saved mode=\(mode.rawValue)"
                + " streams=\(streamCount) slow=\(slowModeMbps) enabled=\(enabled)"
        )
    }

    private struct Backup: Codable {
        var mode: StreamMode
        var fixedStreams: Int
        var slowModeMbps: Double
        var allowCellular: Bool
        var enabled: Bool
    }
}

/// Chunk state persisted per download so pause + relaunch resume where the
/// file left off. Encoded/decoded as one JSON blob in UserDefaults.
struct DownloadSidecar: Codable {
    struct Chunk: Codable {
        var index: Int
        var offset: Int64
        var length: Int64
        var written: Int64
    }

    static func storedRecords() -> [DownloadSidecar] {
        let defaults = UserDefaults.standard
        let ids = defaults.stringArray(forKey: "drift.download.ids") ?? []
        var records: [DownloadSidecar] = []
        for id in ids {
            if let data = defaults.data(forKey: "drift.download.\(id)"),
               let record = try? JSONDecoder().decode(DownloadSidecar.self, from: data) {
                records.append(record)
            }
        }
        return records
    }

    static func persist(_ record: DownloadSidecar) {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(record) {
            defaults.set(data, forKey: "drift.download.\(record.id)")
            var ids = defaults.stringArray(forKey: "drift.download.ids") ?? []
            if !ids.contains(record.id) { ids.append(record.id) }
            defaults.set(ids, forKey: "drift.download.ids")
        }
    }

    static func forget(id: String) {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "drift.download.\(id)")
        var ids = defaults.stringArray(forKey: "drift.download.ids") ?? []
        ids.removeAll { $0 == id }
        defaults.set(ids, forKey: "drift.download.ids")
    }

    var id: String
    var url: URL
    var destination: String
    var fileName: String
    var etag: String?
    var total: Int64
    var chunks: [Chunk]
    var streams: Int
    var allowCellular: Bool
    var slowModeMbps: Double

    var writtenTotal: Int64 { chunks.reduce(0) { $0 + $1.written } }

    var isComplete: Bool {
        !chunks.isEmpty && !chunks.contains { $0.written < $0.length }
    }
}

enum DownloadError: Error, LocalizedError {
    case rangeRejected

    var errorDescription: String? {
        switch self {
        case .rangeRejected:
            "The server refused ranged fetches and no Content-Length was provided."
        }
    }
}

/// One direct download: planning, parallel ranged agents, progress, resume.
@MainActor
@Observable
final class DirectDownload {
    enum Status: String, Sendable {
        case idle
        case probing
        case running
        case paused
        case done
        case failed
    }

    private struct State {
        var sidecar: DownloadSidecar
        var claimed: Set<Int> = []
        var runTask: Task<Void, Never>?
        var speedMarkDate = Date()
        var speedMarkBytes: Int64 = 0
    }

    let id: String
    let url: URL
    let destination: String
    let fileName: String
    let streams: Int
    let allowCellular: Bool
    let slowMbps: Double?

    private(set) var status: Status = .idle
    private(set) var phase: String = ""
    private(set) var writtenBytes: Int64 = 0
    private(set) var totalBytes: Int64 = 0
    private(set) var liveSpeedBps: Double = 0
    private(set) var errorMessage: String = ""
    /// Number of successful ranged agent pulls (parallelism evidence).
    private(set) var completedFetches = 0

    private var writeHandle: FileHandle?

    private let state = OSAllocatedUnfairLock<State>(initialState: State(sidecar: DownloadSidecar(
        id: "", url: URL(string: "about:blank")!, destination: "", fileName: "",
        etag: nil, total: 0, chunks: [], streams: 1, allowCellular: false, slowModeMbps: 0
    )))

    var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(writtenBytes) / Double(totalBytes)
    }

    var completedChunkCount: Int {
        state.withLock { $0.sidecar.chunks.filter { $0.written >= $0.length }.count }
    }

    var chunkCount: Int {
        state.withLock { $0.sidecar.chunks.count }
    }

    var agentCount: Int { streams }

    // MARK: - Inits

    init(url: URL, destination: String, streams: Int, allowCellular: Bool, slowModeMbps: Double?) {
        self.id = UUID().uuidString
        self.url = url
        self.destination = destination
        self.fileName = url.lastPathComponent.isEmpty ? "download" : url.lastPathComponent
        self.streams = max(2, min(16, streams))
        self.allowCellular = allowCellular
        self.slowMbps = slowModeMbps
        state.withLock {
            $0.sidecar = DownloadSidecar(
                id: id, url: url, destination: destination,
                fileName: self.fileName, etag: nil, total: 0,
                chunks: [], streams: self.streams,
                allowCellular: allowCellular, slowModeMbps: slowModeMbps ?? 0
            )
        }
    }

    init(sidecar: DownloadSidecar) {
        id = sidecar.id
        url = sidecar.url
        destination = sidecar.destination
        fileName = sidecar.fileName
        streams = sidecar.streams
        allowCellular = sidecar.allowCellular
        slowMbps = sidecar.slowModeMbps == 0 ? nil : sidecar.slowModeMbps
        totalBytes = sidecar.total
        writtenBytes = sidecar.writtenTotal
        state.withLock { $0.sidecar = sidecar }
        status = sidecar.isComplete ? .done : .paused
        phase = sidecar.isComplete ? "complete" : "resumable"
    }

    // MARK: - Sidecar

    private func persist() {
        let sidecar = state.withLock { $0.sidecar }
        DownloadSidecar.persist(sidecar)
    }

    // MARK: - Start/pause

    func start() {
        guard status != .running, status != .probing else { return }
        status = .probing
        phase = "probing"
        let runTask = Task { await run() }
        state.withLock { $0.runTask = runTask }
    }

    func pause() {
        state.withLock { $0.runTask?.cancel() }
        try? writeHandle?.close()
        writeHandle = nil
        status = .paused
        phase = "paused"
        persist()
    }

    /// UI cancel: removes the record wholly (partial file deleted too).
    func deleteEverything() {
        pause()
        forgetSidecar()
        deletePartialFile()
    }

    private func forgetSidecar() {
        let sidecar = state.withLock { state -> DownloadSidecar? in
            state.runTask = nil
            return state.sidecar
        }
        guard let sidecar else { return }
        DownloadSidecar.forget(id: sidecar.id)
    }

    private func deletePartialFile() {
        try? FileManager.default.removeItem(at: partialFileURL())
    }

    private func partialFileURL() -> URL {
        URL(fileURLWithPath: destination)
            .appendingPathComponent(fileName)
    }

    // MARK: - Coordination

    private func run() async {
        if totalBytes <= 0 {
            do {
                totalBytes = try await probe()
            } catch {
                errorMessage = error.localizedDescription
                status = .failed
                writeProbeLog("[booster] probe failed id=\(id) \(error.localizedDescription)")
                return
            }
        }
        // The partial file on disk is the only byte store; counters may
        // outlive it (e.g. user deleted it) — reset progress then.
        let fileURL = partialFileURL()
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            state.withLock { state in
                var total: Int64 = 0
                for index in state.sidecar.chunks.indices {
                    total += state.sidecar.chunks[index].written
                    state.sidecar.chunks[index].written = 0
                }
                if total > 0 {
                    state.sidecar.etag = nil
                    state.sidecar.chunks.shuffle()
                }
            }
            writeProbeLog("[booster] partial missing; progress reset id=\(id)")
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else {
            errorMessage = "could not open partial file for writing"
            status = .failed
            writeProbeLog("[booster] write-open failed \(fileURL.path)")
            return
        }
        writeHandle = handle
        status = .running
        phase = "streams \(streams)"
        await withTaskGroup(of: Void.self) { group in
            for agent in 0..<streams {
                group.addTask { [weak self] in
                    await self?.agentLoop(agent: agent)
                }
            }
            await group.waitForAll()
        }
        state.withLock { $0.runTask = nil }
        try? handle.close()
        writeHandle = nil
        if Task.isCancelled {
            if status == .running { status = .paused }
            return
        }
        let complete = state.withLock { $0.sidecar.isComplete }
        if complete {
            status = .done
            phase = "complete"
            let sidecar = state.withLock { $0.sidecar }
            DownloadSidecar.forget(id: sidecar.id)
            writeProbeLog("[booster] done id=\(id) bytes=\(totalBytes)")
        } else {
            errorMessage = errorMessage.isEmpty ? "chunk pool dropped out" : errorMessage
            status = .failed
        }
        liveSpeedBps = 0
    }

    private func agentLoop(agent: Int) async {
        let session = Self.agentSession(allowCellular: allowCellular)
        var consecutive = 0
        while !Task.isCancelled {
            let chunk: DownloadSidecar.Chunk? = takeNext()
            let unfinished = state.withLock {
                $0.sidecar.chunks.contains { $0.written < $0.length }
            }
            guard let chunk else {
                // Every unfinished chunk is in flight somewhere: wait for
                // the pool instead of bailing while work remains.
                if unfinished {
                    try? await Task.sleep(for: .milliseconds(300))
                    continue
                }
                return
            }
            do {
                let data = try await fetchRange(session: session, chunk: chunk)
                consumeWrite(chunk: chunk, data: data)
                consecutive = 0
                if let slowMbps, slowMbps > 0 {
                    // Pace the whole pool down to slowMbps by sharing the
                    // budget evenly across this download's agents.
                    let cap = slowMbps * 125_000 / Double(max(1, streams))
                    let pause = Double(data.count) / cap
                    if pause > 0 {
                        try? await Task.sleep(for: .seconds(pause))
                    }
                }
            } catch {
                consecutive += 1
                state.withLock { $0.claimed.remove(chunk.index) }
                if consecutive >= 3 {
                    errorMessage = error.localizedDescription
                    status = .failed
                    writeProbeLog("[booster] agent failed id=\(id) \(error.localizedDescription)")
                    return
                }
                try? await Task.sleep(for: .milliseconds(500 * UInt64(consecutive)))
            }
        }
    }

    private func takeNext() -> DownloadSidecar.Chunk? {
        state.withLock { state -> DownloadSidecar.Chunk? in
            guard let chunk = state.sidecar.chunks.first(where: {
                $0.written < $0.length && !state.claimed.contains($0.index)
            })
            else { return nil }
            state.claimed.insert(chunk.index)
            return chunk
        }
    }

    private nonisolated static func agentSession(allowCellular: Bool) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.allowsCellularAccess = allowCellular
        TunnelProxy.apply(to: configuration)
        return URLSession(configuration: configuration)
    }

    private func fetchRange(
        session: URLSession, chunk: DownloadSidecar.Chunk
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        let from = chunk.offset + chunk.written
        request.setValue(
            "bytes=\(from)-\(chunk.offset + chunk.length - 1)",
            forHTTPHeaderField: "Range"
        )
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode < 400 else {
            throw DownloadError.rangeRejected
        }
        completedFetches += 1
        if http.statusCode == 200 {
            // The server ignored the range: trim to our chunk's bounds.
            let want = Int(chunk.length - chunk.written)
            if data.count > want { return data.prefix(want) }
        }
        return data
    }

    private func consumeWrite(chunk: DownloadSidecar.Chunk, data: Data) {
        // Write to disk first; counters only advance if the bytes landed.
        var wrote = 0
        if let handle = writeHandle {
            do {
                try handle.seek(toOffset: UInt64(chunk.offset + chunk.written))
                try handle.write(contentsOf: data)
                wrote = data.count
            } catch {
                writeProbeLog("[booster] write failed id=\(id) \(error.localizedDescription)")
                errorMessage = error.localizedDescription
                wrote = 0
            }
        }
        let landed = wrote
        guard landed > 0 else { return }
        let now = Date()
        let (total, speed) = state.withLock { state -> (Int64, Double) in
            guard let index = state.sidecar.chunks.firstIndex(where: { $0.index == chunk.index })
            else { return (state.sidecar.writtenTotal, 0) }
            state.sidecar.chunks[index].written = min(
                chunk.length,
                state.sidecar.chunks[index].written + Int64(landed)
            )
            state.claimed.remove(chunk.index)
            state.speedMarkBytes += Int64(landed)
            let interval = now.timeIntervalSince(state.speedMarkDate)
            let speed: Double
            if interval > 0.4 {
                speed = Double(state.speedMarkBytes) / interval
                state.speedMarkBytes = 0
                state.speedMarkDate = now
            } else {
                speed = 0
            }
            return (state.sidecar.writtenTotal, speed)
        }
        writtenBytes = total
        if speed > 0 { liveSpeedBps = speed }
        persist()
    }

    // MARK: - Probe + plan

    private func probe() async throws -> Int64 {
        let session = Self.agentSession(allowCellular: allowCellular)
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 15
        var etag: String?
        var size: Int64 = -1
        var ranges = false
        if let http = (try? await session.data(for: request))?.1 as? HTTPURLResponse,
           http.statusCode == 200 {
            etag = http.value(forHTTPHeaderField: "ETag")
            size = Int64(http.value(forHTTPHeaderField: "Content-Length") ?? "-1") ?? -1
            ranges = (http.value(forHTTPHeaderField: "Accept-Ranges") ?? "").lowercased() == "bytes"
                 || ranges
        }
        if !(ranges && size > -1) {
            var ranged = URLRequest(url: url)
            ranged.setValue("bytes=0-0", forHTTPHeaderField: "Range")
            let (_, rangedResponse) = try await session.data(for: ranged)
            if let http = rangedResponse as? HTTPURLResponse, http.statusCode == 206 {
                ranges = true
                let contentRange = http.value(forHTTPHeaderField: "Content-Range") ?? ""
                let sizePart = contentRange.split(separator: "/").last ?? ""
                size = Int64(sizePart) ?? size
                etag = etag ?? http.value(forHTTPHeaderField: "ETag")
            }
        }
        let frozenSize = size
        let frozenEtag = etag
        state.withLock { $0.sidecar.etag = frozenEtag }
        let planned: [DownloadSidecar.Chunk]
        if ranges && frozenSize > 0 {
            planned = Self.plan(total: frozenSize, streams: streams)
        } else {
            planned = Self.plan(total: max(frozenSize, 0), streams: 1)
        }
        // Merge prior progress by matching offsets (same etag = same layout).
        state.withLock { state in
            let previous = state.sidecar.chunks
            state.sidecar.chunks = planned
            state.sidecar.total = frozenSize
            if !previous.isEmpty, state.sidecar.etag != nil {
                let offsets = Dictionary(
                    uniqueKeysWithValues: previous.map { (Int($0.offset), $0.written) }
                )
                for index in state.sidecar.chunks.indices {
                    if let prior = offsets[Int(state.sidecar.chunks[index].offset)] {
                        state.sidecar.chunks[index].written = min(
                            prior, state.sidecar.chunks[index].length
                        )
                    }
                }
            }
        }
        persist()
        return max(0, frozenSize)
    }

    /// Splits the file evenly across `streams` lanes.
    nonisolated static func plan(total: Int64, streams: Int) -> [DownloadSidecar.Chunk] {
        guard total > 0 else { return [] }
        let lanes = max(1, streams)
        let base = total / Int64(lanes)
        var chunks: [DownloadSidecar.Chunk] = []
        var offset: Int64 = 0
        for lane in 0..<lanes {
            let isLast = lane == lanes - 1
            let length = isLast ? total - offset : base
            chunks.append(
                .init(index: lane, offset: offset, length: length, written: 0)
            )
            offset += length
        }
        return chunks
    }

    // MARK: - Status helpers (UI)

    var speedLabel: String { DesignSystem.Format.speed(Int64(liveSpeedBps)) }
    var sizeLabel: String { DesignSystem.Format.size(totalBytes) }
}
