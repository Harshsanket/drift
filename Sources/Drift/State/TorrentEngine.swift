import Foundation

protocol TorrentEngine: Sendable {
    func loadTorrents() -> [TorrentSummary]
    func loadDetails(for id: String) -> TorrentDetails
    func fetchDetails(for id: String) async -> TorrentDetails
    func setFilePriority(id: String, fileIndex: Int, priority: FilePriority)
    func addTorrent(source: AddSource, options: AddOptions) -> TorrentSummary
    func start(ids: [String])
    func stop(ids: [String])
    func remove(ids: [String], deleteFiles: Bool)
}

extension TorrentEngine {
    /// Defaults so engines implement only what they support; unsupported
    /// actions are silent no-ops (the UI logs at the call site). WebAPIEngine
    /// implements the qBittorrent-parity surface; Stage B's LibtorrentEngine
    /// implements what libtorrent covers natively.

    // Lifecycle
    func forceStart(ids: [String]) {}
    func recheck(ids: [String]) {}
    func queue(ids: [String], move: QueueMove) {}
    func setLocation(ids: [String], location: String) {}
    func rename(id: String, name: String) {}
    func renameFile(id: String, fileIndex: Int, name: String) {}
    func setDownloadLimit(ids: [String], bytesPerSecond: Int64) {}
    func setUploadLimit(ids: [String], bytesPerSecond: Int64) {}
    func setShareLimits(ids: [String], ratio: Double?, minutes: Int?) {}
    func toggleSequentialDownload(ids: [String]) {}
    func toggleFirstLastPiecePriority(ids: [String]) {}
    func setSuperSeeding(ids: [String], enabled: Bool) {}
    func setAutoManagement(ids: [String], enabled: Bool) {}

    // Categories & tags
    func categories() -> [TorrentCategory] { [] }
    func createCategory(name: String, savePath: String?) {}
    func editCategory(name: String, savePath: String?) {}
    func removeCategories(names: [String]) {}
    func setCategory(ids: [String], category: String?) {}

    func tags() -> [String] { [] }
    func createTags(_ names: [String]) {}
    func deleteTags(_ names: [String]) {}
    func addTags(ids: [String], tags: [String]) {}
    func removeTags(ids: [String], tags: [String]) {}

    // Details management
    func addTrackers(id: String, urls: [String]) {}
    func editTracker(id: String, oldURL: String, newURL: String) {}
    func removeTrackers(id: String, urls: [String]) {}
    func reannounceTrackers(id: String) {}
    func addWebSeeds(id: String, urls: [String]) {}
    func editWebSeed(id: String, oldURL: String, newURL: String) {}
    func removeWebSeeds(id: String, urls: [String]) {}

    // Global transfer controls (A6)
    func globalDownloadLimit() async -> Int64? { nil }
    func globalUploadLimit() async -> Int64? { nil }
    func setGlobalDownloadLimit(_ bytesPerSecond: Int64) {}
    func setGlobalUploadLimit(_ bytesPerSecond: Int64) {}
    func toggleSpeedLimitsMode() {}
    func speedLimitsMode() async -> Bool? { nil }
    func serverStatistics() -> ServerStatistics? { nil }
    func alternativeDownloadLimit() async -> Int64? { nil }
    func alternativeUploadLimit() async -> Int64? { nil }
    func applyPreferences(_ values: [String: Any]) {}
}

enum AddSource: Sendable {
    case magnetOrURL(String)
    case torrentFile(URL)
}
