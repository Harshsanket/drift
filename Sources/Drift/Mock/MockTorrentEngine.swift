import Foundation

final class MockTorrentEngine: TorrentEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var store: [TorrentSummary]

    init() {
        store = TorrentFixture.torrents
    }

    func loadTorrents() -> [TorrentSummary] {
        lock.lock()
        defer { lock.unlock() }
        return store
    }

    func loadDetails(for id: String) -> TorrentDetails {
        lock.lock()
        let torrent = store.first(where: { $0.id == id })
            ?? store.first
            ?? TorrentFixture.torrents[0]
        lock.unlock()
        return TorrentFixture.details(for: torrent)
    }

    func addTorrent(source: AddSource, savePath: String) -> TorrentSummary {
        let id = "add-" + UUID().uuidString.prefix(8)
        var name = "New torrent"
        var declaredSize: Int64?
        switch source {
        case .magnetOrURL(let string):
            let components = URLComponents(string: string)
            if let dn = components?.queryItems?.first(where: { $0.name == "dn" })?.value, !dn.isEmpty {
                let plusDecoded = dn.replacingOccurrences(of: "+", with: " ")
                name = plusDecoded.removingPercentEncoding ?? plusDecoded
            } else if let path = components?.path, !path.isEmpty, path != "/" {
                name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            } else if let host = components?.host, !host.isEmpty {
                name = host
            }
            if let xl = components?.queryItems?.first(where: { $0.name == "xl" })?.value,
               let bytes = Int64(xl) {
                declaredSize = bytes
            }
        case .torrentFile(let url):
            name = url.deletingPathExtension().lastPathComponent
        }
        let torrent = TorrentSummary(
            id: String(id),
            name: name,
            status: .downloading,
            progress: 0,
            size: declaredSize ?? Self.seededSize(for: String(id)),
            downloadSpeed: 0,
            uploadSpeed: 0,
            eta: nil,
            tags: []
        )
        lock.lock()
        store.insert(torrent, at: 0)
        lock.unlock()
        return torrent
    }

    func start(ids: [String]) {
        lock.lock()
        defer { lock.unlock() }
        for id in ids {
            guard let index = store.firstIndex(where: { $0.id == id }),
                  store[index].status == .stopped
            else { continue }
            if store[index].progress >= 1 {
                store[index].status = .seeding
                store[index].downloadSpeed = 0
                store[index].uploadSpeed = Self.seededUpload(for: id)
                store[index].eta = nil
            } else {
                let downloadSpeed = Self.seededDownload(for: id)
                store[index].status = .downloading
                store[index].downloadSpeed = downloadSpeed
                store[index].uploadSpeed = Self.seededUpload(for: id)
                let remaining = Double(store[index].size) * (1 - store[index].progress)
                store[index].eta = remaining / Double(downloadSpeed)
            }
        }
    }

    func stop(ids: [String]) {
        lock.lock()
        defer { lock.unlock() }
        for id in ids {
            guard let index = store.firstIndex(where: { $0.id == id }),
                  store[index].status != .stopped
            else { continue }
            store[index].status = .stopped
            store[index].downloadSpeed = 0
            store[index].uploadSpeed = 0
            store[index].eta = nil
        }
    }

    func remove(ids: [String], deleteFiles: Bool) {
        lock.lock()
        defer { lock.unlock() }
        store.removeAll { ids.contains($0.id) }
    }

    /// Deterministic per id (stable across refreshes within a run).
    private static func seededSize(for id: String) -> Int64 {
        500_000_000 + Int64(id.hashValue.magnitude % 3_500_000_000)
    }

    private static func seededDownload(for id: String) -> Int64 {
        1_000_000 + Int64(id.hashValue.magnitude % 4_000_000)
    }

    private static func seededUpload(for id: String) -> Int64 {
        100_000 + Int64(id.hashValue.magnitude % 800_000)
    }
}
