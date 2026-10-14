import Foundation
import SwiftUI
import AppKit
import Observation

protocol TorrentProviding: Sendable {
    func loadTorrents() -> [TorrentSummary]
    func loadDetails(for id: String) -> TorrentDetails
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
    var sortOrder: [KeyPathComparator<TorrentSummary>] = []
    var columnCustomization = TableColumnCustomization<TorrentSummary>()
    var selectedTab: DetailTab = .general
    var columnWidths: [CGFloat] = [200, 100, 160, 84, 84, 84, 80, 80]
    var tableRowHeight: CGFloat = 26
    var showCategories = false
    var showTags = false
    private var detailsCache: [String: TorrentDetails] = [:]
    private var selectionAnchor: String?
    private var lastAutoCollapse = Date.distantPast
    private var lastClickID: String?
    private var lastClickAt = Date.distantPast

    init(provider: TorrentProviding = MockTorrentProvider()) {
        self.provider = provider
        refresh()
    }

    func toggleDetails() {
        guard Date().timeIntervalSince(lastAutoCollapse) > 0.3 else { return }
        withAnimation(.spring(duration: 0.35)) {
            detailsCollapsed.toggle()
        }
    }

    func collapseDetailsFromOutsideClick() {
        guard !detailsCollapsed else { return }
        lastAutoCollapse = Date()
        withAnimation(.spring(duration: 0.35)) {
            detailsCollapsed = true
        }
    }

    /// A single table-cell click. Two taps on the same row within the
    /// double-click window toggle the details panel; each standalone tap
    /// selects and collapses like a click anywhere else.
    func cellClicked(_ id: String) {
        let now = Date()
        if lastClickID == id, now.timeIntervalSince(lastClickAt) < 0.3 {
            lastClickID = nil
            lastClickAt = .distantPast
            toggleDetails()
            return
        }
        lastClickID = id
        lastClickAt = now
        rowClicked(id)
        collapseDetailsFromOutsideClick()
    }

    private static let columnVisibilityIDs = [
        "", "status", "progress", "size", "downloadSpeed", "uploadSpeed", "eta", "timeActive"
    ]

    /// Canonical index of the last visible column, so its row-backdrop slice
    /// can round the capsule's trailing end.
    func isLastVisibleColumn(_ index: Int) -> Bool {
        let ids = Self.columnVisibilityIDs
        for i in stride(from: ids.count - 1, through: 0, by: -1) {
            if ids[i].isEmpty || columnCustomization[visibility: ids[i]] != .hidden {
                return i == index
            }
        }
        return index == 0
    }

    func rowClicked(_ id: String) {
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.shift), let anchor = selectionAnchor {
            let ids = filtered.map(\.id)
            if let from = ids.firstIndex(of: anchor), let to = ids.firstIndex(of: id) {
                selectedIDs = Set(ids[min(from, to)...max(from, to)])
                return
            }
        }
        if modifiers.contains(.command) {
            if selectedIDs.contains(id) {
                selectedIDs.remove(id)
            } else {
                selectedIDs.insert(id)
            }
        } else {
            selectedIDs = [id]
        }
        selectionAnchor = id
    }

    var filtered: [TorrentSummary] {
        torrents
            .filter { torrent in
                statusFilter.matches(torrent)
                    && (searchText.isEmpty || torrent.name.localizedCaseInsensitiveContains(searchText))
            }
            .sorted(using: sortOrder)
    }

    var selectedTorrent: TorrentSummary? {
        guard let id = selectedIDs.first else { return nil }
        return torrents.first { $0.id == id }
    }

    var selectedDetails: TorrentDetails? {
        guard let id = selectedIDs.first else { return nil }
        return details(for: id)
    }

    func details(for id: String) -> TorrentDetails {
        if let cached = detailsCache[id] { return cached }
        let details = provider.loadDetails(for: id)
        detailsCache[id] = details
        return details
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
