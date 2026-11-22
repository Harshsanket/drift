// SPDX-License-Identifier: GPL-3.0-only
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

/// Snapshot of the embedded engine's session and all-time transfer stats.
struct EngineStatistics: Equatable {
    var received: Int64
    var sent: Int64
    var wasted: Int64
    var receivedAllTime: Int64
    var sentAllTime: Int64
    var globalRatio: Double
    var freeSpaceOnDisk: Int64
    var downloadSpeed: Int64 = 0
    var uploadSpeed: Int64 = 0
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

/// One row of an embedded Jackett/Prowlarr search.
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
