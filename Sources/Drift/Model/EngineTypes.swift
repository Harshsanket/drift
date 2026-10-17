import Foundation

/// Queue reordering action, mirroring the qBittorrent API's four endpoints.
enum QueueMove: String {
    case top
    case up
    case down
    case bottom
}

enum ContentLayout: String, CaseIterable {
    case original = "Original"
    case subfolder = "Subfolder"
    case noSubfolder = "NoSubfolder"
}

struct TorrentCategory: Identifiable, Equatable {
    var name: String
    var savePath: String
    var id: String { name }
}

/// Snapshot of the server's transfer statistics, mirrored from
/// `sync/maindata` server_state fields.
struct ServerStatistics: Equatable {
    var received: Int64
    var sent: Int64
    var wasted: Int64
    var receivedAllTime: Int64
    var sentAllTime: Int64
    var globalRatio: Double
    var freeSpaceOnDisk: Int64
}

/// Options for adding a magnet/torrent, mapped 1:1 onto `torrents/add`
/// parameters. Pre-add defaults mirror qBittorrent's add dialog.
struct AddOptions: Equatable {
    var savePath: String = ""
    var category: String? = nil
    var tags: [String] = []
    var startAutomatically = true
    var skipChecking = false
    var sequentialDownload = false
    var firstLastPiecePriority = false
    var contentLayout: ContentLayout = .original
    var autoManaged = true
}

/// One article of an RSS feed, from `rss/items` (withData=true).
struct RSSArticle: Identifiable, Equatable, Hashable {
    var id: Int
    var title: String
    var torrentURL: String
    var date: String
    var isRead: Bool
    var torrentHash: String?
}

/// A flat RSS feed. The server organizes feeds in nested folders; Drift
/// presents the flat list of leaf feeds only (folders are ignored).
struct RSSFeed: Identifiable, Equatable, Hashable {
    var name: String
    var url: String
    var articles: [RSSArticle]
    var isLoading = false
    var hasError = false
    var id: String { name }
}

/// One row of a server-side search (`search/results`).
struct SearchResult: Identifiable, Equatable, Hashable {
    var fileName: String
    var fileURL: String
    var fileSize: Int64
    var seeders: Int64
    var leechers: Int64
    var siteURL: String
    var engineName: String
    var id: String { fileURL + siteURL }
}
