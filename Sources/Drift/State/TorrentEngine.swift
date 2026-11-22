// SPDX-License-Identifier: GPL-3.0-only
import Foundation

protocol TorrentEngine: Sendable {
    // Core
    func loadTorrents() -> [TorrentSummary]
    func loadDetails(for id: String) -> TorrentDetails
    func fetchDetails(for id: String) async -> TorrentDetails
    func setFilePriority(id: String, fileIndex: Int, priority: FilePriority)
    func addTorrent(source: AddSource, options: AddOptions) -> TorrentSummary
    func start(ids: [String])
    func stop(ids: [String])
    func remove(ids: [String], deleteFiles: Bool)

    // Lifecycle (A1)
    func forceStart(ids: [String])
    func recheck(ids: [String])
    func queue(ids: [String], move: QueueMove)
    func setLocation(ids: [String], location: String)
    func rename(id: String, name: String)
    func toggleSequentialDownload(ids: [String])
    func toggleFirstLastPiecePriority(ids: [String])
    func setSuperSeeding(ids: [String], enabled: Bool)
    func setAutoManagement(ids: [String], enabled: Bool)

    // Categories & tags (A2)
    func categories() -> [TorrentCategory]
    func createCategory(name: String, savePath: String?)
    func editCategory(name: String, savePath: String?)
    func removeCategories(names: [String])
    func setCategory(ids: [String], category: String?)

    func tags() -> [String]
    func createTags(_ names: [String])
    func deleteTags(_ names: [String])
    func addTags(ids: [String], tags: [String])
    func removeTags(ids: [String], tags: [String])

    // Details management (A4)
    func addTrackers(id: String, urls: [String])
    func editTracker(id: String, oldURL: String, newURL: String)
    func removeTrackers(id: String, urls: [String])
    func reannounceTrackers(id: String)
    func addWebSeeds(id: String, urls: [String])
    func editWebSeed(id: String, oldURL: String, newURL: String)
    func removeWebSeeds(id: String, urls: [String])

    // Peer management: bans persist in the embedded engine session.
    func bannedIPs() async -> [String]
    func banIPs(_ ips: [String]) async
    func unbanIPs(_ ips: [String]) async

    // Global transfer controls (A6)
    func globalDownloadLimit() async -> Int64?
    func globalUploadLimit() async -> Int64?
    func setGlobalDownloadLimit(_ bytesPerSecond: Int64)
    func setGlobalUploadLimit(_ bytesPerSecond: Int64)
    func engineStatistics() -> EngineStatistics?

    // Booster support (embedded engine)
    func torrentExportData(id: String) async throws -> Data
    func webSeedURLs(id: String) async -> [String]
    func pieceStates(id: String) async throws -> [Int]

    // Search (embedded Jackett/Prowlarr)
    func startSearch(pattern: String, category: String) async -> Int64?
    func stopSearch(id: Int64)
    func deleteSearch(id: Int64)
    func searchResults(id: Int64) async -> (status: String, results: [SearchResult])?
}

extension TorrentEngine {
    /// Default bodies so engines implement only what they support; the
    /// unsupported surface stays a silent no-op (the UI logs at call sites).
    /// These are requirement defaults — all methods above are protocol
    /// requirements, so `any TorrentEngine` dispatch stays dynamic.

    // Lifecycle
    func forceStart(ids: [String]) {}
    func recheck(ids: [String]) {}
    func queue(ids: [String], move: QueueMove) {}
    func setLocation(ids: [String], location: String) {}
    func rename(id: String, name: String) {}
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

    // Peer management (banned_IPs)
    func bannedIPs() async -> [String] { [] }
    func banIPs(_ ips: [String]) async {}
    func unbanIPs(_ ips: [String]) async {}

    // Global transfer controls (A6)
    func globalDownloadLimit() async -> Int64? { nil }
    func globalUploadLimit() async -> Int64? { nil }
    func setGlobalDownloadLimit(_ bytesPerSecond: Int64) {}
    func setGlobalUploadLimit(_ bytesPerSecond: Int64) {}
    func engineStatistics() -> EngineStatistics? { nil }
    func torrentExportData(id: String) async throws -> Data {
        throw BoostError.metaBad("engine does not export torrent metadata")
    }
    func webSeedURLs(id: String) async -> [String] { [] }
    func pieceStates(id: String) async throws -> [Int] { [] }
    func startSearch(pattern: String, category: String) async -> Int64? { nil }
    func stopSearch(id: Int64) {}
    func deleteSearch(id: Int64) {}
    func searchResults(id: Int64) async -> (status: String, results: [SearchResult])? {
        nil
    }
}

enum AddSource: Sendable {
    case magnetOrURL(String)
    case torrentFile(URL)
}
