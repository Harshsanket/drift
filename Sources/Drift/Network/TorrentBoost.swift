import Foundation
import CryptoKit

// MARK: - Bencode

/// Minimal bencode value tree, enough to parse .torrent metadata.
enum Bencode: Equatable, Sendable {
    case int(Int64)
    case string(Data)
    case list([Bencode])
    case dict([String: Bencode])

    var stringData: Data? {
        if case .string(let data) = self { return data }
        return nil
    }

    var stringValue: String? {
        stringData.flatMap { String(data: $0, encoding: .isoLatin1) }
    }

    var intValue: Int64? {
        if case .int(let value) = self { return value }
        return nil
    }

    var listValue: [Bencode]? {
        if case .list(let list) = self { return list }
        return nil
    }

    var dictValue: [String: Bencode]? {
        if case .dict(let dict) = self { return dict }
        return nil
    }

    static func decode(_ data: Data) throws -> Bencode {
        var cursor = 0
        return try parse(data, &cursor)
    }

    private static func parse(_ data: Data, _ cursor: inout Int) throws -> Bencode {
        guard cursor < data.count else { throw BoostError.metaBad("truncated") }
        let byte = data[cursor]
        switch byte {
        case UInt8(ascii: "d"):
            cursor += 1
            var dict: [String: Bencode] = [:]
            while cursor < data.count, data[cursor] != UInt8(ascii: "e") {
                let key = try parseString(data, &cursor)
                let value = try parse(data, &cursor)
                let keyText = String(data: key, encoding: .isoLatin1) ?? ""
                dict[keyText] = value
            }
            guard cursor < data.count else { throw BoostError.metaBad("truncated dict") }
            cursor += 1
            return .dict(dict)
        case UInt8(ascii: "l"):
            cursor += 1
            var list: [Bencode] = []
            while cursor < data.count, data[cursor] != UInt8(ascii: "e") {
                list.append(try parse(data, &cursor))
            }
            guard cursor < data.count else { throw BoostError.metaBad("truncated list") }
            cursor += 1
            return .list(list)
        case UInt8(ascii: "i"):
            cursor += 1
            guard let end = BencodeUt.findByte(UInt8(ascii: "e"), from: cursor, in: data) else {
                throw BoostError.metaBad("unterminated int")
            }
            let text = String(data: data.subdata(in: cursor..<end), encoding: .utf8) ?? ""
            guard BencodeUt.isInteger(text), let value = Int64(text) else {
                throw BoostError.metaBad("bad int \(text)")
            }
            cursor = end + 1
            return .int(value)
        default:
            return .string(try parseString(data, &cursor))
        }
    }

    private static func parseString(_ data: Data, _ cursor: inout Int) throws -> Data {
        guard let colon = BencodeUt.findByte(UInt8(ascii: ":"), from: cursor, in: data) else {
            throw BoostError.metaBad("unterminated string length")
        }
        let lengthText = String(data: data.subdata(in: cursor..<colon), encoding: .utf8) ?? ""
        guard let length = Int(lengthText), length >= 0, String(length) == lengthText else {
            throw BoostError.metaBad("bad string length \(lengthText)")
        }
        let start = colon + 1
        guard data.count - start >= length else {
            throw BoostError.metaBad("string exceeds input")
        }
        cursor = start + length
        return data.subdata(in: start..<cursor)
    }
}

private enum BencodeUt {
    static func isInteger(_ text: String) -> Bool {
        let digits = text.hasPrefix("-") ? text.dropFirst() : text[...]
        return !digits.isEmpty && digits.allSatisfy { $0.isNumber }
    }

    static func findByte(_ byte: UInt8, from start: Int, in data: Data) -> Int? {
        let position = data.startIndex + start
        guard position < data.endIndex else { return nil }
        var index = position
        while index < data.endIndex {
            if data[index] == byte { return start + (index - position) }
            index = data.index(after: index)
        }
        return nil
    }
}

// MARK: - Errors

enum BoostError: LocalizedError {
    case metaBad(String)
    case noSources
    case torrentState(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .metaBad(let why): "Torrent metadata unreadable (\(why))"
        case .noSources: "No boost sources: this torrent has no HTTP web seeds (try a mirror URL)"
        case .torrentState(let why): why
        case .unsupported(let why): why
        }
    }
}

// MARK: - Torrent metadata

struct TorrentMeta: Sendable, Equatable {
    /// Files with their absolute byte offsets in the torrent payload space.
    struct FileInfo: Sendable, Equatable {
        var path: String
        var length: Int64
        var offset: Int64
    }

    /// One contiguous run of piece bytes mapped into a specific file.
    struct PieceSpan: Sendable, Equatable {
        var fileIndex: Int
        var fileOffset: Int64
        var pieceOffset: Int64
        var length: Int64
    }

    let name: String
    let pieceLength: Int64
    let pieceCount: Int
    let pieceData: Data
    let totalLength: Int64
    let files: [FileInfo]
    /// BEP-19 url-list entries. May be empty even when qB-level webseeds
    /// exist; sources union both at boost time.
    let urlList: [String]
    /// v2 `file tree` layouts can't be piece-boosted (per-file root hashes).
    let isV2: Bool

    static func decode(_ data: Data) throws -> TorrentMeta {
        guard let root = try? Bencode.decode(data).dictValue else {
            throw BoostError.metaBad("not a torrent dict")
        }
        guard let info = root["info"]?.dictValue else {
            throw BoostError.metaBad("missing info")
        }
        guard let pieceLength = info["piece length"]?.intValue, pieceLength > 0 else {
            throw BoostError.metaBad("missing piece length")
        }
        guard let rawPieces = info["pieces"]?.stringData else {
            if info["file tree"]?.dictValue != nil {
                throw BoostError.unsupported("BitTorrent v2 torrents can't be piece-boosted yet")
            }
            throw BoostError.metaBad("missing piece hashes")
        }
        guard rawPieces.count % 20 == 0, rawPieces.count >= 20 else {
            throw BoostError.metaBad("pieces not multiple of 20")
        }
        let pieceCount = rawPieces.count / 20
        let name = info["name.utf-8"]?.stringValue ?? info["name"]?.stringValue ?? ""
        var files: [FileInfo] = []
        var total: Int64 = 0
        if let topLevel = info["length"]?.intValue {
            files = [FileInfo(path: name, length: topLevel, offset: 0)]
            total = topLevel
        } else if let entries = info["files"]?.listValue {
            for entry in entries {
                guard let dict = entry.dictValue, let length = dict["length"]?.intValue else { continue }
                let pathParts = (dict["path.utf-8"] ?? dict["path"])?.listValue ?? []
                let relative = pathParts.compactMap { $0.stringValue }.joined(separator: "/")
                files.append(FileInfo(path: relative, length: length, offset: total))
                total += length
            }
        } else {
            throw BoostError.metaBad("unknown info layout")
        }
        guard total > 0, !files.isEmpty else {
            throw BoostError.metaBad("no files")
        }
        var urlList: [String] = []
        if let seeds = root["url-list"] {
            if let single = seeds.stringValue {
                urlList = [single]
            } else if let entries = seeds.listValue {
                urlList = entries.compactMap { $0.stringValue }
            }
        }
        let isV2 = info["file tree"]?.dictValue != nil
        return TorrentMeta(
            name: name,
            pieceLength: pieceLength,
            pieceCount: pieceCount,
            pieceData: rawPieces,
            totalLength: total,
            files: files,
            urlList: urlList,
            isV2: isV2
        )
    }

    func pieceHash(_ index: Int) -> Data {
        let start = index * 20
        guard start >= 0, start + 20 <= pieceData.count else { return Data() }
        return pieceData.subdata(in: start..<start + 20)
    }

    /// Piece payload length (last piece may be short).
    func pieceLengthFor(_ index: Int) -> Int64 {
        let start = Int64(index) * pieceLength
        return min(pieceLength, max(0, totalLength - start))
    }

    /// Contiguous runs of piece bytes mapped into the file table.
    func spans(forPiece index: Int) -> [PieceSpan] {
        let pieceStart = Int64(index) * pieceLength
        let pieceEnd = pieceStart + pieceLengthFor(index)
        guard pieceEnd > pieceStart else { return [] }
        var out: [PieceSpan] = []
        for (slot, file) in files.enumerated() {
            let fileEnd = file.offset + file.length
            let lower = max(pieceStart, file.offset)
            let upper = min(pieceEnd, fileEnd)
            guard lower < upper else { continue }
            out.append(PieceSpan(
                fileIndex: slot,
                fileOffset: lower - file.offset,
                pieceOffset: lower - pieceStart,
                length: upper - lower
            ))
        }
        return out
    }
}

// MARK: - Boost task

/// Accelerates one downloading torrent: pauses it in qBittorrent, fetches
/// missing pieces by byte range from HTTP sources (web seeds and/or an
/// optional mirror URL), verifies every piece against the .torrent SHA-1,
/// writes verified bytes into place, then rechecks and resumes.
@MainActor
@Observable
final class TorrentBoostTask: Identifiable {
    enum Status: String {
        case planning
        case boosting
        case finishing
        case done
        case failed
    }

    let id = UUID()
    let hash: String
    let torrentName: String

    private(set) var status: Status = .planning
    private(set) var totalMissing = 0
    private(set) var boostedPieces = 0
    private(set) var boostedBytes: Int64 = 0
    private(set) var liveSpeedBps = 0.0
    private(set) var message = ""
    private(set) var sourceCount = 0

    private let engine: WebAPIEngine
    private let savePath: String
    private let extraMirror: String?
    private var meta: TorrentMeta?
    private var stopped = false
    private var handleCache: [Int: FileHandle] = [:]
    private var speedMarkDate = Date()
    private var speedMarkBytes: Int64 = 0
    private var runTask: Task<Void, Never>?

    init(
        engine: WebAPIEngine,
        hash: String,
        torrentName: String,
        savePath: String,
        extraMirror: String? = nil
    ) {
        self.engine = engine
        self.hash = hash
        self.torrentName = torrentName
        self.savePath = savePath
        self.extraMirror = extraMirror
    }

    func start() {
        guard status == .planning else { return }
        runTask = Task { await run() }
    }

    func cancel() {
        stopped = true
        runTask?.cancel()
        status = .failed
        message = "Boost cancelled; torrent resumed"
        Task { await unwind(abort: true) }
    }

    // MARK: Orchestrator

    private func run() async {
        do {
            let export = try await engine.torrentExportData(id: hash)
            let decoded = try TorrentMeta.decode(export)
            var sources: [String] = []
            if let extraMirror { sources.append(extraMirror) }
            sources.append(contentsOf: decoded.urlList)
            for seed in await engine.webSeedURLs(id: hash) where !sources.contains(seed) {
                sources.append(seed)
            }
            sources = sources.filter { url in
                guard let parsed = URL(string: url),
                      let scheme = parsed.scheme?.lowercased()
                else { return false }
                return scheme == "http" || scheme == "https"
            }
            guard !sources.isEmpty else { throw BoostError.noSources }
            sourceCount = sources.count
            meta = decoded

            status = .boosting
            engine.stop(ids: [hash])
            writeProbeLog("[boost] paused \(hash) sources=\(sources.count)")
            try await waitForPause()

            var stalledBatches = 0
            while !stopped {
                let missing = try await collectMissing()
                totalMissing = missing.count
                if missing.isEmpty {
                    if boostedPieces == 0 { message = "Nothing to boost — fully downloaded" }
                    break
                }
                let batch = Array(missing.prefix(8))
                let pieceResults = await fetchBatch(pieces: batch, sources: sources)
                var landed = 0
                for (piece, data) in pieceResults {
                    if let data {
                        writeVerifiedPiece(piece: piece, data: data)
                        landed += 1
                    }
                }
                if landed == 0 {
                    stalledBatches += 1
                    if stalledBatches >= 2 {
                        message = "Sources kept failing — resuming the torrent normally"
                        break
                    }
                    try? await Task.sleep(for: .seconds(1))
                } else {
                    stalledBatches = 0
                }
            }
            guard !stopped else { return }
            await unwind(abort: false)
        } catch {
            if !stopped {
                message = error.localizedDescription
                status = .failed
            }
            await unwind(abort: true)
        }
    }

    private func fetchBatch(
        pieces: [Int], sources: [String]
    ) async -> [(piece: Int, data: Data?)] {
        guard let meta else { return [] }
        return await withTaskGroup(
            of: (piece: Int, data: Data?).self,
            returning: [(piece: Int, data: Data?)].self
        ) { group in
            for piece in pieces {
                group.addTask { () -> (piece: Int, data: Data?) in
                    let data = await TorrentBoostTask.fetchPieceVerified(
                        meta: meta, index: piece, sources: sources
                    )
                    return (piece, data)
                }
            }
            var results: [(piece: Int, data: Data?)] = []
            for await result in group { results.append(result) }
            return results
        }
    }

    private func waitForPause() async throws {
        for _ in 0..<20 {
            if stopped { return }
            if let summary = engine.loadTorrents().first(where: { $0.id == hash }),
               summary.status == .stopped || summary.status == .completed {
                try? await Task.sleep(for: .milliseconds(300))
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        throw BoostError.torrentState("Could not pause the torrent in qBittorrent")
    }

    private func collectMissing() async throws -> [Int] {
        guard let meta else { return [] }
        let states = try await engine.pieceStates(id: hash)
        guard states.count == meta.pieceCount else {
            throw BoostError.torrentState("piece bitmap size mismatch (\(states.count) vs \(meta.pieceCount))")
        }
        var missing: [Int] = []
        for (index, state) in states.enumerated() where state == 0 {
            missing.append(index)
        }
        return missing
    }

    private func writeVerifiedPiece(piece: Int, data: Data) {
        guard let meta else { return }
        let expected = Int(meta.pieceLengthFor(piece))
        guard data.count == expected else {
            message = "piece \(piece) had \(data.count)/\(expected) bytes; discarded"
            return
        }
        for span in meta.spans(forPiece: piece) {
            guard let handle = handleFor(fileIndex: span.fileIndex) else { return }
            let sliceStart = Int(span.pieceOffset)
            let slice = data.subdata(in: sliceStart..<sliceStart + Int(span.length))
            do {
                try handle.seek(toOffset: UInt64(span.fileOffset))
                try handle.write(contentsOf: slice)
            } catch {
                message = "write failed: \(error.localizedDescription)"
                return
            }
        }
        boostedPieces += 1
        boostedBytes += Int64(data.count)
        let now = Date()
        let interval = now.timeIntervalSince(speedMarkDate)
        if interval > 0.4 {
            liveSpeedBps = Double(speedMarkBytes) / interval
            speedMarkBytes = 0
            speedMarkDate = now
        }
        speedMarkBytes += Int64(data.count)
    }

    private func handleFor(fileIndex: Int) -> FileHandle? {
        if let cached = handleCache[fileIndex] { return cached }
        guard let meta, fileIndex < meta.files.count else { return nil }
        let file = meta.files[fileIndex]
        let base = canonicalSaveRoot
        var candidates = [base.appendingPathComponent(file.path)]
        if !meta.name.isEmpty, !file.path.hasPrefix("\(meta.name)/") {
            candidates.append(base.appendingPathComponent(meta.name).appendingPathComponent(file.path))
        }
        for candidate in candidates {
            guard FileGateway.verdictForPieceWrite(
                candidate: candidate, saveRoot: base
            ) == .allowed else { continue }
            guard let handle = try? FileHandle(forUpdating: candidate) else { continue }
            handleCache[fileIndex] = handle
            return handle
        }
        message = "target file missing: \(file.path)"
        return nil
    }

    /// Canonicalized root every piece write is pinned against.
    private var canonicalSaveRoot: URL {
        FileGateway.canonicalized(savePath.isEmpty ? "." : savePath)
    }

    private func unwind(abort: Bool) async {
        for (_, handle) in handleCache { try? handle.close() }
        handleCache.removeAll()
        guard !unwound else { return }
        unwound = true
        if abort {
            engine.start(ids: [hash])
            if status != .done { status = .failed }
        } else {
            status = .finishing
            engine.recheck(ids: [hash])
            try? await Task.sleep(for: .milliseconds(800))
            engine.start(ids: [hash])
            status = .done
            if message.isEmpty { message = "Boosted \(boostedPieces) pieces" }
        }
    }

    private var unwound = false

    // MARK: Piece fetcher

    private nonisolated static func fetchPieceVerified(
        meta: TorrentMeta, index: Int, sources: [String]
    ) async -> Data? {
        let expected = meta.pieceHash(index)
        guard !expected.isEmpty else { return nil }
        let start = Int64(index) * meta.pieceLength
        let end = start + meta.pieceLengthFor(index) - 1
        expectLoop: for source in sources {
            if Task.isCancelled { return nil }
            guard let url = URL(string: source) else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 45
            request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
            do {
                let session = agentSession()
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse,
                      http.statusCode == 200 || http.statusCode == 206
                else { continue }
                let wanted = Int(end - start + 1)
                let payload = data.count > wanted ? data.prefix(wanted) : data
                if Data(payload).count != wanted { continue }
                let digest = Data(Insecure.SHA1.hash(data: payload))
                if digest == expected {
                    return Data(payload)
                }
                writeProbeLog("[boost] piece \(index) hash mismatch at \(source.prefix(80))")
            } catch {
                continue
            }
        }
        return nil
    }

    private nonisolated static func agentSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 180
        TunnelProxy.apply(to: configuration)
        return URLSession(configuration: configuration)
    }
}
