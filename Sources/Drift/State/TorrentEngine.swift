import Foundation

protocol TorrentEngine: Sendable {
    func loadTorrents() -> [TorrentSummary]
    func loadDetails(for id: String) -> TorrentDetails
    func addTorrent(source: AddSource, savePath: String) -> TorrentSummary
    func start(ids: [String])
    func stop(ids: [String])
    func remove(ids: [String], deleteFiles: Bool)
}

enum AddSource: Sendable {
    case magnetOrURL(String)
    case torrentFile(URL)
}
