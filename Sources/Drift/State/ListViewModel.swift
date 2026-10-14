import Foundation
import SwiftUI
import Observation

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
    private let engine: TorrentEngine

    var torrents: [TorrentSummary] = []
    var selectedIDs: Set<String> = []
    var statusFilter: StatusFilter = .all
    var searchText = ""
    var detailsCollapsed = true
    var isConnected = true
    var sortOrder: [KeyPathComparator<TorrentSummary>] = []
    var columnCustomization = TableColumnCustomization<TorrentSummary>()
    var selectedTab: DetailTab = .general
    var showCategories = false
    var showTags = false
    var showAddSheet = false
    var showConnectionSheet = false
    var pendingRemoval: Set<String>?
    private var detailsCache: [String: TorrentDetails] = [:]
    private var lastAutoCollapse = Date.distantPast

    init(engine: TorrentEngine = MockTorrentEngine()) {
        self.engine = engine
        refresh()
    }

    func toggleDetails() {
        guard Date().timeIntervalSince(lastAutoCollapse) > 0.3 else {
            writeProbeLog("[model] toggleDetails suppressed")
            return
        }
        withAnimation(.spring(duration: 0.35)) {
            detailsCollapsed.toggle()
        }
        writeProbeLog("[model] toggleDetails -> collapsed=\(detailsCollapsed)")
    }

    func collapseDetailsFromOutsideClick() {
        guard !detailsCollapsed else { return }
        lastAutoCollapse = Date()
        withAnimation(.spring(duration: 0.35)) {
            detailsCollapsed = true
        }
        writeProbeLog("[model] collapsed from outside click")
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
        let details = engine.loadDetails(for: id)
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
        detailsCache.removeAll()
        torrents = engine.loadTorrents()
    }

    func confirmAdd(source: AddSource, savePath: String) {
        let summary = engine.addTorrent(source: source, savePath: savePath)
        refresh()
        selectedIDs = [summary.id]
        showAddSheet = false
        writeProbeLog("[sheet] added \(summary.id) savePath=\(savePath)")
    }

    func startTorrents(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        engine.start(ids: ids)
        refresh()
        writeProbeLog("[engine] start ids=\(ids.sorted().joined(separator: ","))")
    }

    func stopTorrents(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        engine.stop(ids: ids)
        refresh()
        writeProbeLog("[engine] stop ids=\(ids.sorted().joined(separator: ","))")
    }

    func requestRemoval(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        pendingRemoval = Set(ids)
        writeProbeLog("[engine] removal requested ids=\(ids.sorted().joined(separator: ","))")
    }

    func cancelRemoval() {
        pendingRemoval = nil
        writeProbeLog("[engine] removal cancelled")
    }

    func confirmRemoval() {
        guard let ids = pendingRemoval, !ids.isEmpty else { return }
        engine.remove(ids: Array(ids), deleteFiles: false)
        selectedIDs.subtract(ids)
        pendingRemoval = nil
        refresh()
        writeProbeLog("[engine] removed ids=\(ids.sorted().joined(separator: ","))")
    }

    var canPauseAll: Bool {
        torrents.contains { $0.status != .stopped }
    }

    var canResumeAll: Bool {
        torrents.contains { $0.status == .stopped }
    }

    func pauseAll() {
        stopTorrents(torrents.filter { $0.status != .stopped }.map(\.id))
    }

    func resumeAll() {
        startTorrents(torrents.filter { $0.status == .stopped }.map(\.id))
    }
}
