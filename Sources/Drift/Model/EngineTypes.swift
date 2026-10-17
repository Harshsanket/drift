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
