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

    /// Population parity with qBittorrent's torrent list columns.
    var ratio: Double = 0
    var seeds: Int = 0
    var peers: Int = 0
    var availability: Double = 0
    var downloaded: Int64 = 0
    var uploaded: Int64 = 0
    var savePath: String = ""
    var addedOn: TimeInterval = 0

    var etaSortKey: TimeInterval { eta ?? .infinity }
}

enum TorrentStatus: String, CaseIterable, Hashable, Comparable {
    case downloading
    case seeding
    case completed
    case stopped
    case stalled
    case checking
    case moving
    case queued
    case error

    var label: String {
        switch self {
        case .downloading: "Downloading"
        case .seeding: "Seeding"
        case .completed: "Completed"
        case .stopped: "Stopped"
        case .stalled: "Stalled"
        case .checking: "Checking"
        case .moving: "Moving"
        case .queued: "Queued"
        case .error: "Error"
        }
    }

    var systemImage: String {
        switch self {
        case .downloading: "arrow.down.circle.fill"
        case .seeding: "arrow.up.circle.fill"
        case .completed: "checkmark.circle.fill"
        case .stopped: "pause.circle.fill"
        case .stalled: "hourglass"
        case .checking: "arrow.triangle.2.circlepath"
        case .moving: "folder"
        case .queued: "pause.circle"
        case .error: "exclamationmark.octagon.fill"
        }
    }

    var tint: Color {
        switch self {
        case .downloading: DesignSystem.Palette.downloading
        case .seeding: DesignSystem.Palette.seeding
        case .completed: DesignSystem.Palette.completed
        case .stopped: DesignSystem.Palette.stopped
        case .stalled: DesignSystem.Palette.stalled
        case .checking: DesignSystem.Palette.checking
        case .moving: DesignSystem.Palette.moving
        case .queued: DesignSystem.Palette.queued
        case .error: DesignSystem.Palette.error
        }
    }

    static func < (lhs: TorrentStatus, rhs: TorrentStatus) -> Bool {
        guard let l = allCases.firstIndex(of: lhs),
              let r = allCases.firstIndex(of: rhs)
        else { return false }
        return l < r
    }
}
