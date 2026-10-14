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
    private var engine: TorrentEngine
    var isRealBackend: Bool { engine is WebAPIEngine }

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
    private var detailsFetching = false
    private var lastAutoCollapse = Date.distantPast
    private(set) var windowVisible = true

    init(engine: TorrentEngine? = nil) {
        self.engine = engine ?? MockTorrentEngine()
        AppLifecycle.shared.onSleep = { [weak self] in self?.handleSystemSleep() }
        AppLifecycle.shared.onWake = { [weak self] in self?.handleSystemWake() }
        AppLifecycle.shared.start()
        AppSettings.shared.onMenuBarItemChanged = { [weak self] in
            self?.recomputeSyncTier()
        }
        refresh()
        Task { await connectRealBackend() }
    }

    func connectRealBackend(force: Bool = false, passwordOverride: String? = nil) async {
        guard !(engine is WebAPIEngine) else { return }
        let settings = ConnectionSettings.shared
        guard force || settings.lastVersion != nil else {
            writeProbeLog("[sync] skipped (no prior successful connection)")
            return
        }
        guard let url = WebAPIEngine.url(from: settings.baseUrl) else {
            writeProbeLog("[sync] invalid url \(settings.baseUrl)")
            return
        }
        let real = WebAPIEngine(
            base: url,
            username: settings.username,
            password: passwordOverride ?? settings.password
        )
        do {
            let version = try await real.authenticate()
            real.onUpdate = { [weak self] in
                self?.refresh()
            }
            real.startSync()
            engine = real
            detailsCache.removeAll()
            recomputeSyncTier()
            if let passwordOverride {
                // A working password wins: keep the Keychain in sync so
                // launch-time auto-connect doesn't retry stale credentials.
                Keychain.setPassword(passwordOverride, account: "password")
            }
            settings.noteConnected(version: version)
            refresh()
            writeProbeLog("[sync] connected \(version)")
        } catch let error as WebAPIError {
            writeProbeLog("[sync] connect failed: \(error.message)")
        } catch {
            writeProbeLog("[sync] connect failed: \(error)")
        }
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
        scheduleDetailsFetch(for: id)
        let details = engine.loadDetails(for: id)
        detailsCache[id] = details
        return details
    }

    private func scheduleDetailsRefresh() {
        guard windowVisible, !detailsCollapsed, let id = selectedIDs.first else { return }
        scheduleDetailsFetch(for: id)
    }

    private func scheduleDetailsFetch(for id: String) {
        guard !detailsFetching else { return }
        detailsFetching = true
        let engine = self.engine
        Task {
            let fetched = await engine.fetchDetails(for: id)
            detailsFetching = false
            if selectedIDs.contains(id) || detailsCache[id] != nil {
                detailsCache[id] = fetched
            }
        }
    }

    func setFilePriority(file: FileRow, priority: FilePriority) {
        guard let id = selectedIDs.first,
              let position = detailsCache[id]?.files.firstIndex(where: { $0.id == file.id }),
              file.priority != priority
        else { return }
        engine.setFilePriority(id: id, fileIndex: position, priority: priority)
        detailsCache[id]?.files[position].priority = priority
        writeProbeLog("[details] set prio file=\(file.name) -> \(priority.rawValue)")
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
        torrents = engine.loadTorrents()
        if let real = engine as? WebAPIEngine {
            PowerManagementManager.shared.noteObservation(active: real.transferActivity())
        }
        NotificationCenter.default.post(name: .driftRefreshed, object: self)
        scheduleDetailsRefresh()
    }

    func setWindowVisible(_ visible: Bool) {
        guard visible != windowVisible else { return }
        windowVisible = visible
        writeProbeLog("[lifecycle] window \(visible ? "visible" : "hidden")")
        recomputeSyncTier()
    }

    func recomputeSyncTier() {
        guard let real = engine as? WebAPIEngine else { return }
        let itemPresent = AppSettings.shared.showMenuBarItem
            && StatusItemController.shared.isItemVisible
        let targetActive = windowVisible
        let targetSummary = !windowVisible && itemPresent
        if !targetActive && !targetSummary {
            real.suspendSync()
            return
        }
        let tier: WebAPIEngine.SyncTier = targetActive ? .active : .summary
        if real.isSuspended {
            Task {
                await real.resumeSync()
                real.setSyncTier(tier)
            }
        } else {
            real.setSyncTier(tier)
        }
    }

    func handleSystemSleep() {
        writeProbeLog("[lifecycle] system sleep — sync suspended")
        (engine as? WebAPIEngine)?.suspendSync()
    }

    func handleSystemWake() {
        writeProbeLog("[lifecycle] system wake — sync resuming")
        Task {
            if let real = engine as? WebAPIEngine {
                await real.resumeSync()
            }
            refresh()
            recomputeSyncTier()
        }
    }

    func transferStats() -> (downloading: Int, seeding: Int, progress: Double) {
        let active = torrents.filter { $0.status == .downloading }.count
        let seeding = torrents.filter { $0.status == .seeding }.count
        let progress = torrents.isEmpty
            ? 0
            : torrents.reduce(0) { $0 + $1.progress } / Double(torrents.count)
        return (active, seeding, progress)
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
        for id in ids { detailsCache.removeValue(forKey: id) }
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
