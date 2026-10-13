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
    var category: String?
    var tags: [String]
}

enum TorrentStatus: String, CaseIterable, Hashable {
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
}
