import Foundation

enum DetailTab: String, CaseIterable, Identifiable {
    case general
    case trackers
    case peers
    case sources
    case files

    var id: String { rawValue }

    var label: String {
        switch self {
        case .general: "General"
        case .trackers: "Trackers"
        case .peers: "Peers"
        case .sources: "Sources"
        case .files: "Files"
        }
    }
}

struct TorrentDetails: Equatable {
    var general: GeneralInfo
    var trackers: [TrackerRow]
    var peers: [PeerRow]
    var webSeeds: [WebSeedRow]
    var files: [FileRow]
}

struct GeneralInfo: Equatable {
    var hash: String
    var savePath: String
    var addedOn: Date
    var completedOn: Date?
    var comment: String
    var downloaded: Int64
    var uploaded: Int64
    var piecesTotal: Int
    var piecesHave: Int

    var shareRatio: Double {
        guard downloaded > 0 else { return 0 }
        return Double(uploaded) / Double(downloaded)
    }
}

struct TrackerRow: Equatable, Identifiable {
    var id: String { url }
    var url: String
    var status: String
    var peers: Int
    var seeds: Int
    var leeches: Int
    var downloaded: Int64
}

struct PeerRow: Equatable, Identifiable {
    var id: String { "\(ip)|\(client)" }
    var ip: String
    var client: String
    var flags: String
    var connection: String
    var progress: Double
    var downSpeed: Int64
    var upSpeed: Int64
}

struct WebSeedRow: Equatable, Identifiable {
    var id: String { url }
    var url: String
}

struct FileRow: Equatable, Identifiable {
    var id: String { name }
    var name: String
    var size: Int64
    var progress: Double
    var priority: FilePriority
}

enum FilePriority: String, CaseIterable {
    case maximum = "Maximum"
    case high = "High"
    case normal = "Normal"
    case low = "Low"
    case ignored = "Ignored"
}
