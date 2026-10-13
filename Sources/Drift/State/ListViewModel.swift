import SwiftUI
import Observation

protocol TorrentProviding: Sendable {
    func loadTorrents() -> [TorrentSummary]
}

enum StatusFilter: String, CaseIterable, Hashable, Identifiable {
    case all
    case downloading
    case seeding
    case completed
    case stopped
    case stalled

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: "All"
        case .downloading: TorrentStatus.downloading.label
        case .seeding: TorrentStatus.seeding.label
        case .completed: TorrentStatus.completed.label
        case .stopped: TorrentStatus.stopped.label
        case .stalled: TorrentStatus.stalled.label
        }
    }

    var systemImage: String {
        switch self {
        case .all: "tray.full"
        default: TorrentStatus(rawValue: rawValue)?.systemImage ?? "circle"
        }
    }

    var tint: Color {
        TorrentStatus(rawValue: rawValue)?.tint ?? DesignSystem.Palette.accent
    }

    func matches(_ torrent: TorrentSummary) -> Bool {
        switch self {
        case .all: true
        default: torrent.status.rawValue == rawValue
        }
    }
}

@MainActor
@Observable
final class ListViewModel {
    private let provider: TorrentProviding

    var torrents: [TorrentSummary] = []
    var selectedIDs: Set<String> = []
    var statusFilter: StatusFilter = .all
    var searchText = ""
    var detailsCollapsed = true
    var isConnected = true

    init(provider: TorrentProviding = MockTorrentProvider()) {
        self.provider = provider
        refresh()
    }

    var filtered: [TorrentSummary] {
        torrents.filter { torrent in
            statusFilter.matches(torrent)
                && (searchText.isEmpty || torrent.name.localizedCaseInsensitiveContains(searchText))
        }
    }

    var selectedTorrent: TorrentSummary? {
        guard let id = selectedIDs.first else { return nil }
        return torrents.first { $0.id == id }
    }

    var globalDownloadSpeed: Int64 {
        torrents.reduce(0) { $0 + $1.downloadSpeed }
    }

    var globalUploadSpeed: Int64 {
        torrents.reduce(0) { $0 + $1.uploadSpeed }
    }

    func count(for filter: StatusFilter) -> Int {
        torrents.filter { filter.matches($0) }.count
    }

    func refresh() {
        torrents = provider.loadTorrents()
    }
}
