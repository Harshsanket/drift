import SwiftUI

struct TorrentSummary: Identifiable, Equatable {
    let id: String
    var name: String
    var status: TorrentStatus
    var progress: Double
    var size: Int64
    var downloadSpeed: Int64
    var uploadSpeed: Int64
    var eta: TimeInterval?
    /// Total time the torrent has been active, mirroring qBittorrent's `time_active`.
    var timeActive: TimeInterval = 0
    var category: String?
    var tags: [String]

    var etaSortKey: TimeInterval { eta ?? .infinity }
}

enum TorrentStatus: String, CaseIterable, Hashable, Comparable {
    case downloading
    case seeding
    case completed
    case stopped
    case stalled

    var label: String {
        switch self {
        case .downloading: "Downloading"
        case .seeding: "Seeding"
        case .completed: "Completed"
        case .stopped: "Stopped"
        case .stalled: "Stalled"
        }
    }

    var systemImage: String {
        switch self {
        case .downloading: "arrow.down.circle.fill"
        case .seeding: "arrow.up.circle.fill"
        case .completed: "checkmark.circle.fill"
        case .stopped: "pause.circle.fill"
        case .stalled: "hourglass"
        }
    }

    var tint: Color {
        switch self {
        case .downloading: DesignSystem.Palette.downloading
        case .seeding: DesignSystem.Palette.seeding
        case .completed: DesignSystem.Palette.completed
        case .stopped: DesignSystem.Palette.stopped
        case .stalled: DesignSystem.Palette.stalled
        }
    }

    static func < (lhs: TorrentStatus, rhs: TorrentStatus) -> Bool {
        guard let l = allCases.firstIndex(of: lhs),
              let r = allCases.firstIndex(of: rhs)
        else { return false }
        return l < r
    }
}
