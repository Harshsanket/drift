import Foundation
import SwiftUI
import Observation

enum StatusFilter: String, CaseIterable, Hashable, Identifiable {
    case all
    case downloading
    case seeding
    case completed
    case stopped
    case checking
    case moving
    case queued
    case stalled
    case error

    var id: String { rawValue }

    /// Rows the sidebar renders. Checking/moving are excluded: they are
    /// in-progress states no torrent rests in, so they surface as live chips
    /// in the status bar instead of permanently reserved filter rows.
    static var sidebarCases: [StatusFilter] {
        allCases.filter { $0 != .checking && $0 != .moving }
    }

    var label: String {
        switch self {
        case .all: "All"
        case .downloading: TorrentStatus.downloading.label
        case .seeding: TorrentStatus.seeding.label
        case .completed: TorrentStatus.completed.label
        case .stopped: TorrentStatus.stopped.label
        case .checking: TorrentStatus.checking.label
        case .moving: TorrentStatus.moving.label
        case .queued: TorrentStatus.queued.label
        case .stalled: TorrentStatus.stalled.label
        case .error: TorrentStatus.error.label
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

enum CategoryFilter: Hashable {
    case uncategorized
    case named(String)
}

/// The live connection state to the qBittorrent Web UI. Drift holds no torrent
/// data of its own: with no connection there is nothing to show and nothing to
/// act on.
enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected(version: String)
    case failed(message: String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var version: String? {
        if case .connected(let version) = self { return version }
        return nil
    }

    var errorMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }

    var label: String {
        switch self {
        case .disconnected: "Not connected"
        case .connecting: "Connecting…"
        case .connected(let version): "Connected — qBittorrent \(version)"
        case .failed: "Not connected"
        }
    }
}

@MainActor
@Observable
final class ListViewModel {
    private var engine: (any TorrentEngine)?
    private(set) var connectionState: ConnectionState = .disconnected
    private var reconnectTask: Task<Void, Never>?
    private var connectedKey: String?
    private var connectInFlight = false
    private var pendingConnect = false

    var isConnected: Bool { connectionState.isConnected }

    var torrents: [TorrentSummary] = []
    var selectedIDs: Set<String> = []
    var statusFilter: StatusFilter = .all
    private(set) var categories: [TorrentCategory] = []
    private(set) var tags: [String] = []
    private(set) var activeCategory: CategoryFilter?
    private(set) var activeTags: Set<String> = []
    private var lastOrganizersFetch = Date.distantPast
    var searchText = ""
    var detailsCollapsed = true
    /// 0 = details panel fully hidden, 1 = fully revealed. Driven frame by
    /// frame by `setDetailsExpanded` so the footer grows smoothly and the
    /// table viewport (and its stripes) retreat in lockstep with the glass.
    var detailsProgress: CGFloat = 0
    var footerHeight: CGFloat = 0
    private var detailsAnimation: Task<Void, Never>?
    var sortOrder: [KeyPathComparator<TorrentSummary>] = []
    var columnCustomization = TableColumnCustomization<TorrentSummary>()
    var selectedTab: DetailTab = .general
    var showCategories = false
    var showTags = false
    var showAddSheet = false
    /// Sources handed over from the OS (magnet URLs, dropped .torrent files)
    /// that the add sheet should present pre-filled.
    var pendingAddHandoff: AddSource?
    var showConnectionSheet = false
    var pendingRemoval: Set<String>?
    private var detailsCache: [String: TorrentDetails] = [:]
    private var detailsFetching = false
    /// Guard so verification hooks on `onAppear` run once even if capture
    /// tooling occludes the window and SwiftUI re-appears the view.
    var didRunShowDetailsHook = false
    private var lastAutoCollapse = Date.distantPast
    private(set) var windowVisible = true

    init(engine: (any TorrentEngine)? = nil, connectionState: ConnectionState = .disconnected) {
        self.engine = engine
        self.connectionState = connectionState
        AppLifecycle.shared.onSleep = { [weak self] in self?.handleSystemSleep() }
        AppLifecycle.shared.onWake = { [weak self] in self?.handleSystemWake() }
        AppLifecycle.shared.start()
        AppSettings.shared.onMenuBarItemChanged = { [weak self] in
            self?.recomputeSyncTier()
        }
        NotificationCenter.default.addObserver(
            forName: .driftConnectionSettingsSaved, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.connectionSettingsChanged() }
        }
        NotificationCenter.default.addObserver(
            forName: .driftSpeedSettingsRequested, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.loadSpeedSettings() }
        }
        NotificationCenter.default.addObserver(
            forName: .driftSpeedSettingsSaved, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applySpeedSettings() }
        }
        refresh()
        if engine == nil, !connectionState.isConnected {
            Task { await startConnection() }
        }
    }

    /// Launch flow: connect if a previous connection exists, otherwise ask for
    /// one. A failed attempt surfaces the sheet with the error instead of
    /// silently degrading — there is no offline mode.
    private func startConnection() async {
        // Verification-only: lets UI probes run without the sheet in the way.
        guard !ProcessInfo.processInfo.arguments.contains("--no-auto-connect") else {
            writeProbeLog("[sync] auto-connect suppressed")
            return
        }
        guard ConnectionSettings.shared.lastVersion != nil else {
            showConnectionSheet = true
            return
        }
        await connectRealBackend()
        if !isConnected {
            showConnectionSheet = true
            scheduleReconnect()
        }
    }

    /// After a Settings-window save: reconnect when not connected or when the
    /// endpoint actually changed; a redundant save against the live endpoint
    /// leaves the running engine alone.
    private func connectionSettingsChanged() {
        let settings = ConnectionSettings.shared
        let key = "\(settings.baseUrl)|\(settings.username)"
        guard !isConnected || key != connectedKey else { return }
        Task {
            await connectRealBackend()
            if !isConnected {
                showConnectionSheet = true
            }
        }
    }

    func connectRealBackend(passwordOverride: String? = nil) async {
        guard !connectInFlight else {
            pendingConnect = true
            return
        }
        connectInFlight = true
        defer { connectInFlight = false }
        repeat {
            pendingConnect = false
            await performConnect(passwordOverride: passwordOverride)
        } while pendingConnect
    }

    private func performConnect(passwordOverride: String?) async {
        let settings = ConnectionSettings.shared
        guard let url = WebAPIEngine.url(from: settings.baseUrl) else {
            connectionState = .failed(message: WebAPIError.invalidURL.message)
            writeProbeLog("[sync] invalid url \(settings.baseUrl)")
            return
        }
        let previousVersion = connectionState.version
        connectionState = .connecting
        let password: String
        if let passwordOverride {
            password = passwordOverride
        } else {
            // Off the main actor: a locked keychain (or a SecurityAgent prompt
            // on an ad-hoc build) must not freeze launch behind the dialog.
            password = await Task.detached(priority: .userInitiated) {
                Keychain.password(account: "password") ?? ""
            }.value
        }
        let real = WebAPIEngine(
            base: url,
            username: settings.username,
            password: password
        )
        do {
            let version = try await real.authenticate()
            real.onUpdate = { [weak self] in
                self?.refresh()
            }
            real.onConnectionLost = { [weak self] message in
                self?.handleConnectionLost(message)
            }
            (engine as? WebAPIEngine)?.stopSync()
            real.startSync()
            engine = real
            detailsCache.removeAll()
            recomputeSyncTier()
            if let passwordOverride {
                // A working password wins: keep the Keychain in sync so
                // launch-time auto-connect doesn't retry stale credentials.
                // Fire-and-forget: a keychain prompt must not hold back the
                // connected state.
                Task.detached(priority: .utility) {
                    Keychain.setPassword(passwordOverride, account: "password")
                }
            }
            settings.noteConnected(version: version)
            connectedKey = "\(settings.baseUrl)|\(settings.username)"
            connectionState = .connected(version: version)
            settings.testStatus = .success("Connected — qBittorrent \(version)")
            reconnectTask?.cancel()
            reconnectTask = nil
            refresh()
            writeProbeLog("[sync] connected \(version)")
        } catch {
            let message = (error as? WebAPIError)?.message ?? error.localizedDescription
            // A failed re-point keeps the previous, still-running backend so
            // the status bar reports the connection that actually exists.
            connectionState = previousVersion.map { .connected(version: $0) }
                ?? .failed(message: message)
            settings.testStatus = .error(message)
            writeProbeLog("[sync] connect failed: \(message)")
        }
    }

    private func handleConnectionLost(_ message: String) {
        guard !isConnected else { return }
        connectionState = .failed(message: message)
        writeProbeLog("[sync] connection lost: \(message)")
        scheduleReconnect()
    }

    /// qBittorrent may restart at any time; retry the saved endpoint until it
    /// is back (or the credentials/URL are changed).
    private func scheduleReconnect() {
        guard reconnectTask == nil else { return }
        reconnectTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self, !self.isConnected else { return }
                guard ConnectionSettings.shared.lastVersion != nil else { return }
                await self.connectRealBackend()
            }
            self?.reconnectTask = nil
        }
    }

    func toggleDetails() {
        guard Date().timeIntervalSince(lastAutoCollapse) > 0.3 else {
            writeProbeLog("[model] toggleDetails suppressed")
            return
        }
        setDetailsExpanded(detailsCollapsed)
        writeProbeLog("[model] toggleDetails -> collapsed=\(detailsCollapsed)")
    }

    func collapseDetailsFromOutsideClick() {
        guard !detailsCollapsed else { return }
        lastAutoCollapse = Date()
        setDetailsExpanded(false)
        writeProbeLog("[model] collapsed from outside click")
    }

    /// Tweens `detailsProgress` per frame instead of relying on a SwiftUI
    /// animation: `onGeometryChange` only reports endpoints, so a view-level
    /// animation would leave the scroll viewport (and the stripes under the
    /// glass) lagging behind the growing footer. Driving the model value at
    /// ~60fps makes every layout pass measure a new footer height, which the
    /// probe turns into the clip inset on the same frame.
    private func setDetailsExpanded(_ expanded: Bool) {
        detailsCollapsed = !expanded
        detailsAnimation?.cancel()
        let target: CGFloat = expanded ? 1 : 0
        let start = detailsProgress
        guard start != target else {
            detailsProgress = target
            return
        }
        let duration: TimeInterval = ProcessInfo.processInfo.arguments.contains("--slow-anim")
            ? 1.0
            : 0.22
        detailsAnimation = Task { @MainActor [weak self] in
            let begin = Date()
            while !Task.isCancelled {
                let t = min(1, Date().timeIntervalSince(begin) / duration)
                let eased = 1 - pow(1 - t, 3)
                self?.detailsProgress = start + (target - start) * CGFloat(eased)
                if t >= 1 { break }
                try? await Task.sleep(for: .milliseconds(16))
            }
            if !Task.isCancelled {
                self?.detailsProgress = target
            }
        }
    }

    var filtered: [TorrentSummary] {
        torrents
            .filter { torrent in
                statusFilter.matches(torrent)
                    && matchesCategory(torrent)
                    && matchesTags(torrent)
                    && (searchText.isEmpty
                        || torrent.name.localizedCaseInsensitiveContains(searchText))
            }
            .sorted(using: sortOrder)
    }

    private func matchesCategory(_ torrent: TorrentSummary) -> Bool {
        switch activeCategory {
        case nil: true
        case .uncategorized: torrent.category == nil
        case .named(let name): torrent.category == name
        }
    }

    private func matchesTags(_ torrent: TorrentSummary) -> Bool {
        activeTags.isEmpty || !Set(torrent.tags).isDisjoint(with: activeTags)
    }

    var selectedTorrent: TorrentSummary? {
        guard let id = selectedIDs.first else { return nil }
        return torrents.first { $0.id == id }
    }

    var selectedDetails: TorrentDetails? {
        guard let id = selectedIDs.first else { return nil }
        return details(for: id)
    }

    func details(for id: String) -> TorrentDetails? {
        guard torrents.contains(where: { $0.id == id }) else { return nil }
        if let cached = detailsCache[id] { return cached }
        guard let engine else { return nil }
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
        guard !detailsFetching, let engine else { return }
        detailsFetching = true
        Task {
            let fetched = await engine.fetchDetails(for: id)
            detailsFetching = false
            if selectedIDs.contains(id) || detailsCache[id] != nil {
                detailsCache[id] = fetched
            }
        }
    }

    func setFilePriority(file: FileRow, priority: FilePriority) {
        guard let engine,
              let id = selectedIDs.first,
              let position = detailsCache[id]?.files.firstIndex(where: { $0.id == file.id }),
              file.priority != priority
        else { return }
        engine.setFilePriority(id: id, fileIndex: position, priority: priority)
        detailsCache[id]?.files[position].priority = priority
        writeProbeLog("[details] set prio file=\(file.name) -> \(priority.rawValue)")
    }

    // MARK: - Per-torrent limits & toggles (A1/A6)

    func setTorrentDownloadLimit(_ ids: [String], bytesPerSecond: Int64) {
        guard !ids.isEmpty, let engine, isConnected else { return }
        engine.setDownloadLimit(ids: ids, bytesPerSecond: bytesPerSecond)
        refresh()
        writeProbeLog("[engine] setDownloadLimit ids=\(ids.count) limit=\(bytesPerSecond)")
    }

    func setTorrentUploadLimit(_ ids: [String], bytesPerSecond: Int64) {
        guard !ids.isEmpty, let engine, isConnected else { return }
        engine.setUploadLimit(ids: ids, bytesPerSecond: bytesPerSecond)
        refresh()
        writeProbeLog("[engine] setUploadLimit ids=\(ids.count) limit=\(bytesPerSecond)")
    }

    func toggleSequentialDownload(_ ids: [String]) {
        guard !ids.isEmpty, let engine, isConnected else { return }
        engine.toggleSequentialDownload(ids: ids)
        refresh()
        writeProbeLog("[engine] toggleSequential ids=\(ids.count)")
    }

    func toggleFirstLastPiecePriority(_ ids: [String]) {
        guard !ids.isEmpty, let engine, isConnected else { return }
        engine.toggleFirstLastPiecePriority(ids: ids)
        refresh()
        writeProbeLog("[engine] toggleFirstLast ids=\(ids.count)")
    }

    func setSuperSeeding(_ ids: [String], enabled: Bool) {
        guard !ids.isEmpty, let engine, isConnected else { return }
        engine.setSuperSeeding(ids: ids, enabled: enabled)
        refresh()
        writeProbeLog("[engine] superSeeding \(enabled) ids=\(ids.count)")
    }

    func setTorrentAutoManagement(_ ids: [String], enabled: Bool) {
        guard !ids.isEmpty, let engine, isConnected else { return }
        engine.setAutoManagement(ids: ids, enabled: enabled)
        refresh()
        writeProbeLog("[engine] autoManagement \(enabled) ids=\(ids.count)")
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

    /// Display name for a transient activity chip: the torrent currently in
    /// that state, collapsed with "+N" when several share the state at once.
    func leadingName(for status: TorrentStatus) -> String? {
        let names = torrents.filter { $0.status == status }.map(\.name)
        guard let first = names.first else { return nil }
        return names.count > 1 ? "\(first) +\(names.count - 1)" : first
    }

    func refresh() {
        torrents = engine?.loadTorrents() ?? []
        if let real = engine as? WebAPIEngine {
            PowerManagementManager.shared.noteObservation(active: real.transferActivity())
        }
        CompletionMonitor.shared.observe(torrents: torrents)
        reloadOrganizers()
        statistics = engine?.serverStatistics()
        NotificationCenter.default.post(name: .driftRefreshed, object: self)
        scheduleDetailsRefresh()
    }

    // MARK: - Categories & tags (A2)

    /// Categories/tags ride outside the sync delta: the engine caches them at
    /// connect and after mutations, and the model reads the cache when it has
    /// aged past 5 seconds.
    private func reloadOrganizers(force: Bool = false) {
        guard let engine, isConnected else { return }
        guard force || Date().timeIntervalSince(lastOrganizersFetch) > 5 else { return }
        lastOrganizersFetch = Date()
        Task {
            categories = engine.categories()
            tags = engine.tags()
        }
    }

    func toggleCategoryFilter(_ filter: CategoryFilter) {
        activeCategory = (activeCategory == filter) ? nil : filter
        writeProbeLog("[model] category filter -> \(String(describing: activeCategory))")
    }

    func toggleTagFilter(_ tag: String) {
        if activeTags.contains(tag) {
            activeTags.remove(tag)
        } else {
            activeTags.insert(tag)
        }
        writeProbeLog("[model] tag filter -> \(activeTags.sorted().joined(separator: "|"))")
    }

    func createOrganizer(dialog: ListDialog) {
        pendingText = ""
        pendingText2 = ""
        activeDialog = dialog
        writeProbeLog("[engine] organizer dialog \(String(describing: dialog))")
    }

    func setTorrentCategory(_ ids: [String], category: String?) {
        guard !ids.isEmpty, let engine, isConnected else { return }
        engine.setCategory(ids: ids, category: category)
        refresh()
        reloadOrganizers(force: true)
        writeProbeLog("[engine] setCategory ids=\(ids.count) category=\(category ?? "none")")
    }

    func assignTag(_ ids: [String], tag: String) {
        guard !ids.isEmpty, let engine, isConnected else { return }
        if let torrent = torrents.first(where: { $0.id == ids.first ?? "" }),
           torrent.tags.contains(tag) {
            engine.removeTags(ids: ids, tags: [tag])
            writeProbeLog("[engine] removeTag ids=\(ids.count) tag=\(tag)")
        } else {
            engine.addTags(ids: ids, tags: [tag])
            writeProbeLog("[engine] addTag ids=\(ids.count) tag=\(tag)")
        }
        refresh()
    }

    func removeOrganizers(categoriesNames: [String] = [], tagNames: [String] = []) {
        guard let engine, isConnected else { return }
        if !categoriesNames.isEmpty {
            engine.removeCategories(names: categoriesNames)
            if activeCategory == .named(categoriesNames[0]) {
                activeCategory = nil
            }
        }
        if !tagNames.isEmpty {
            engine.deleteTags(tagNames)
            activeTags.subtract(tagNames)
        }
        refresh()
        reloadOrganizers(force: true)
        writeProbeLog("[engine] removeOrganizers categories=\(categoriesNames.count) tags=\(tagNames.count)")
    }

    // MARK: - Details management (A4)

    private func detailsAction(_ label: String, run: (any TorrentEngine, String) -> Void) {
        guard let engine, isConnected, let id = selectedIDs.first else { return }
        run(engine, id)
        refresh()
        scheduleDetailsFetch(for: id)
        writeProbeLog("[details] \(label) id=\(id.prefix(12))")
    }

    func requestAddTracker() {
        pendingText = ""
        activeDialog = .addTracker
    }

    func requestEditTracker(_ url: String) {
        pendingText = url
        activeDialog = .editTracker(url: url)
    }

    func removeTrackers(_ urls: [String]) {
        detailsAction("removeTrackers") { engine, id in
            engine.removeTrackers(id: id, urls: urls)
        }
    }

    func reannounceTrackers() {
        detailsAction("reannounce") { engine, id in
            engine.reannounceTrackers(id: id)
        }
    }

    func requestAddWebSeed() {
        pendingText = ""
        activeDialog = .addWebSeed
    }

    func requestEditWebSeed(_ url: String) {
        pendingText = url
        activeDialog = .editWebSeed(url: url)
    }

    func removeWebSeeds(_ urls: [String]) {
        detailsAction("removeWebSeeds") { engine, id in
            engine.removeWebSeeds(id: id, urls: urls)
        }
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
                if let version = await real.resumeSync() {
                    connectionState = .connected(version: version)
                }
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
                if let version = await real.resumeSync() {
                    connectionState = .connected(version: version)
                    reconnectTask?.cancel()
                    reconnectTask = nil
                } else if !isConnected {
                    connectionState = .failed(message: "qBittorrent is not reachable")
                    scheduleReconnect()
                }
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

    func confirmAdd(source: AddSource, options: AddOptions) {
        guard let engine, isConnected else { return }
        let summary = engine.addTorrent(source: source, options: options)
        refresh()
        selectedIDs = [summary.id]
        showAddSheet = false
        pendingAddHandoff = nil
        writeProbeLog("[sheet] added \(summary.id) savePath=\(options.savePath)")
    }

    func handleOSHandoff(_ source: AddSource) {
        pendingAddHandoff = source
        showAddSheet = true
        writeProbeLog("[sheet] os handoff pending")
    }

    func startTorrents(_ ids: [String]) {
        guard !ids.isEmpty, let engine, isConnected else { return }
        engine.start(ids: ids)
        refresh()
        writeProbeLog("[engine] start ids=\(ids.sorted().joined(separator: ","))")
    }

    /// qB keyboard behavior: space on a selection pauses the active torrents,
    /// or resumes the stopped ones.
    func toggleSelectedPlayback() {
        let ids = Array(selectedIDs)
        guard !ids.isEmpty else { return }
        let selected = torrents.filter { selectedIDs.contains($0.id) }
        let anyActive = selected.contains { $0.status != .stopped && $0.status != .error }
        if anyActive {
            stopTorrents(ids)
        } else {
            startTorrents(ids)
        }
    }

    func stopTorrents(_ ids: [String]) {
        guard !ids.isEmpty, let engine, isConnected else { return }
        engine.stop(ids: ids)
        refresh()
        writeProbeLog("[engine] stop ids=\(ids.sorted().joined(separator: ","))")
    }

    func requestRemoval(_ ids: [String]) {
        guard !ids.isEmpty, isConnected else { return }
        pendingRemoval = Set(ids)
        writeProbeLog("[engine] removal requested ids=\(ids.sorted().joined(separator: ","))")
    }

    func cancelRemoval() {
        pendingRemoval = nil
        writeProbeLog("[engine] removal cancelled")
    }

    func confirmRemoval() {
        guard let ids = pendingRemoval, !ids.isEmpty, let engine, isConnected else { return }
        engine.remove(ids: Array(ids), deleteFiles: false)
        selectedIDs.subtract(ids)
        for id in ids { detailsCache.removeValue(forKey: id) }
        pendingRemoval = nil
        refresh()
        writeProbeLog("[engine] removed ids=\(ids.sorted().joined(separator: ","))")
    }

    // MARK: - Global transfer controls (A6)

    private(set) var statistics: ServerStatistics?
    private(set) var altSpeedsActive = false
    var showStatistics = false

    func toggleAltSpeeds() {
        guard let engine, isConnected else { return }
        engine.toggleSpeedLimitsMode()
        Task {
            if let alternate = await engine.speedLimitsMode() {
                altSpeedsActive = alternate
            }
        }
        writeProbeLog("[engine] toggleSpeedLimitsMode")
    }

    // MARK: - RSS and search panes (A8/A9)

    private(set) var rssFeeds: [RSSFeed] = []
    private(set) var selectedRSSFeed: RSSFeed?
    private(set) var rssContentLoaded = false
    var showRSSPane = false

    private(set) var searchResults: [SearchResult] = []
    private(set) var searchRunning = false
    private(set) var searchQuery = ""
    private var activeSearchID: Int64?
    private var searchPollTask: Task<Void, Never>?

    func toggleRSSPane(_ enabled: Bool) {
        showRSSPane = enabled
        selectedIDs.removeAll()
        if enabled { loadRSS() }
        writeProbeLog("[engine] rss pane \(enabled)")
    }

    func loadRSS() {
        Task {
            for _ in 0..<10 {
                guard let engine, isConnected else {
                    try? await Task.sleep(for: .milliseconds(300))
                    continue
                }
                var feeds = await engine.rssFeeds()
                if let feeds {
                    rssFeeds = feeds
                    if let current = selectedRSSFeed,
                       let fresh = feeds.first(where: { $0.id == current.id }) {
                        selectedRSSFeed = fresh
                    } else {
                        selectedRSSFeed = feeds.first
                    }
                    rssContentLoaded = true
                    writeProbeLog("[engine] rss feeds loaded n=\(feeds.count)")
                } else {
                    rssContentLoaded = true
                    writeProbeLog("[probe] rss ended nil")
                }
                return
            }
            writeProbeLog("[probe] rss never connected")
        }
    }

    func selectRSSFeed(_ feed: RSSFeed?) {
        selectedRSSFeed = feed
    }

    func addRSSFeed(url: String) {
        engine?.addRSSFeed(url: url, path: nil)
        Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            loadRSS()
        }
        writeProbeLog("[engine] rss add feed")
    }

    func removeRSSFeed(_ feed: RSSFeed) {
        engine?.removeRSSItem(path: feed.name)
        if selectedRSSFeed?.id == feed.id { selectedRSSFeed = nil }
        Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            loadRSS()
        }
        writeProbeLog("[engine] rss remove feed")
    }

    func refreshRSSFeed(_ feed: RSSFeed) {
        engine?.refreshRSSItem(path: feed.name)
        Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            loadRSS()
        }
        writeProbeLog("[engine] rss refresh feed")
    }

    func markRSSArticleRead(_ article: RSSArticle, in feed: RSSFeed) {
        engine?.markRSSRead(path: feed.name, articleId: article.id)
        loadRSS()
        writeProbeLog("[engine] rss mark read")
    }

    func markRSSFeedRead(_ feed: RSSFeed) {
        engine?.markRSSRead(path: feed.name, articleId: nil)
        loadRSS()
        writeProbeLog("[engine] rss mark feed read")
    }

    func downloadRSSTorrent(_ article: RSSArticle) {
        let url = article.torrentHash.map { "magnet:?xt=urn:btih:\($0)" } ?? article.torrentURL
        guard !url.isEmpty else { return }
        handleOSHandoff(.magnetOrURL(url))
        writeProbeLog("[engine] rss download article")
    }

    // MARK: - Search (A9)

    var showSearchPane = false

    func startSearch(pattern: String) {
        let trimmed = pattern.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let engine, isConnected else { return }
        searchResults = []
        searchRunning = true
        searchQuery = trimmed
        Task {
            let id = await engine.startSearch(pattern: trimmed, category: "all")
            activeSearchID = id
            guard id != nil else {
                searchRunning = false
                writeProbeLog("[search] start failed")
                return
            }
            writeProbeLog("[search] started id=\(id!) pattern=\(trimmed)")
            pollSearch()
        }
    }

    private func pollSearch() {
        searchPollTask?.cancel()
        guard let id = activeSearchID else { return }
        searchPollTask = Task { @MainActor in
            var lastStatus = "Running"
            for _ in 0..<120 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                guard let engine, isConnected else { return }
                guard let response = await engine.searchResults(id: id) else { continue }
                lastStatus = response.status
                searchResults = response.results
                if response.status == "Stopped" { break }
            }
            searchRunning = lastStatus == "Running"
            writeProbeLog("[search] ended status=\(lastStatus)")
        }
    }

    func stopSearch() {
        guard let id = activeSearchID else { return }
        searchPollTask?.cancel()
        engine?.stopSearch(id: id)
        searchRunning = false
        writeProbeLog("[search] stopped")
    }

    func clearSearchResults() {
        searchPollTask?.cancel()
        if let id = activeSearchID { engine?.deleteSearch(id: id) }
        searchResults = []
        activeSearchID = nil
        searchRunning = false
        searchQuery = ""
        writeProbeLog("[search] cleared")
    }

    func downloadSearchResult(_ result: SearchResult) {
        handleOSHandoff(.magnetOrURL(result.fileURL))
        writeProbeLog("[search] download \(result.fileName)")
    }

    // MARK: - Statistics dialog (A6)

    func requestStatistics() {
        showStatistics = true
        writeProbeLog("[engine] statistics requested")
    }

    func refreshStatistics() {
        statistics = engine?.serverStatistics()
        writeProbeLog("[engine] statistics refreshed")
    }

    func globalDownloadLimit() async -> Int64? {
        await engine?.globalDownloadLimit()
    }

    func globalUploadLimit() async -> Int64? {
        await engine?.globalUploadLimit()
    }

    func setGlobalDownloadLimit(_ bytesPerSecond: Int64) {
        guard let engine, isConnected else { return }
        engine.setGlobalDownloadLimit(bytesPerSecond)
        writeProbeLog("[engine] setGlobalDownloadLimit \(bytesPerSecond)")
    }

    func setGlobalUploadLimit(_ bytesPerSecond: Int64) {
        guard let engine, isConnected else { return }
        engine.setGlobalUploadLimit(bytesPerSecond)
        writeProbeLog("[engine] setGlobalUploadLimit \(bytesPerSecond)")
    }

    // MARK: - Server speed preferences (A7)

    /// The Settings window reaches the engine through these handlers:
    /// requested → snapshot of the server's speed limits; saved → patch.
    private func loadSpeedSettings() {
        guard let engine, isConnected else { return }
        Task {
            let dl = await engine.globalDownloadLimit()
            let up = await engine.globalUploadLimit()
            let altDl = await engine.alternativeDownloadLimit()
            let altUp = await engine.alternativeUploadLimit()
            let speed = SpeedSettings.shared
            if let dl { speed.downloadLimit = max(0, dl / 1024) }
            if let up { speed.uploadLimit = max(0, up / 1024) }
            if let altDl { speed.altDownloadLimit = max(0, altDl / 1024) }
            if let altUp { speed.altUploadLimit = max(0, altUp / 1024) }
            speed.loaded = true
            writeProbeLog(
                "[settings] speed prefs loaded dl=\(speed.downloadLimit)"
                    + " up=\(speed.uploadLimit)"
                    + " altDl=\(speed.altDownloadLimit)"
                    + " altUp=\(speed.altUploadLimit)"
            )
        }
    }

    private func applySpeedSettings() {
        guard let engine, isConnected else {
            writeProbeLog("[settings] speed prefs apply skipped (not connected)")
            return
        }
        let speed = SpeedSettings.shared
        engine.applyPreferences([
            "dl_limit": Int(max(0, speed.downloadLimit)),
            "up_limit": Int(max(0, speed.uploadLimit)),
            "alt_dl_limit": Int(max(0, speed.altDownloadLimit)),
            "alt_up_limit": Int(max(0, speed.altUploadLimit))
        ])
        writeProbeLog(
            "[settings] speed prefs applied dl=\(speed.downloadLimit)"
                + " up=\(speed.uploadLimit)"
        )
    }

    // MARK: - Lifecycle actions (A1)

    func forceStartTorrents(_ ids: [String]) {
        guard !ids.isEmpty, let engine, isConnected else { return }
        engine.forceStart(ids: ids)
        refresh()
        writeProbeLog("[engine] forceStart ids=\(ids.sorted().joined(separator: ","))")
    }

    func recheckTorrents(_ ids: [String]) {
        guard !ids.isEmpty, let engine, isConnected else { return }
        engine.recheck(ids: ids)
        refresh()
        writeProbeLog("[engine] recheck ids=\(ids.sorted().joined(separator: ","))")
    }

    func queueTorrents(_ ids: [String], move: QueueMove) {
        guard !ids.isEmpty, let engine, isConnected else { return }
        engine.queue(ids: ids, move: move)
        refresh()
        writeProbeLog("[engine] queue \(move.rawValue) ids=\(ids.sorted().joined(separator: ","))")
    }

    enum ListDialog: Equatable {
        case rename(id: String)
        case setLocation
        case createCategory
        case editCategory(name: String)
        case newTag
        case addTracker
        case editTracker(url: String)
        case addWebSeed
        case editWebSeed(url: String)
    }

    var activeDialog: ListDialog?
    var pendingText = ""
    var pendingText2 = ""

    func requestRename(_ id: String) {
        guard let torrent = torrents.first(where: { $0.id == id }) else { return }
        pendingText = torrent.name
        activeDialog = .rename(id: id)
        writeProbeLog("[engine] rename dialog id=\(id)")
    }

    func requestSetLocation(_ ids: [String]) {
        guard let torrent = torrents.first(where: { $0.id == ids.first ?? "" }) else { return }
        pendingText = torrent.savePath.isEmpty
            ? AppSettings.shared.defaultSavePath
            : torrent.savePath
        activeDialog = .setLocation
        writeProbeLog("[engine] setLocation dialog n=\(ids.count)")
    }

    func cancelDialog() {
        activeDialog = nil
        writeProbeLog("[engine] dialog cancelled")
    }

    func confirmDialog() {
        guard let dialog = activeDialog, let engine, isConnected else {
            cancelDialog()
            return
        }
        let text = pendingText.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = pendingText2.trimmingCharacters(in: .whitespacesAndNewlines)
        switch dialog {
        case .rename(let id):
            guard !text.isEmpty else { cancelDialog(); return }
            engine.rename(id: id, name: text)
            writeProbeLog("[engine] rename id=\(id) name=\(text)")
        case .setLocation:
            let ids = Array(selectedIDs)
            guard !text.isEmpty, !ids.isEmpty else { cancelDialog(); return }
            engine.setLocation(ids: ids, location: text)
            writeProbeLog("[engine] setLocation ids=\(ids.count) location=\(text)")
        case .createCategory:
            guard !text.isEmpty else { cancelDialog(); return }
            engine.createCategory(name: text, savePath: path.isEmpty ? nil : path)
            writeProbeLog("[engine] createCategory name=\(text) path=\(path)")
        case .editCategory(let name):
            engine.editCategory(name: name, savePath: path.isEmpty ? nil : path)
            writeProbeLog("[engine] editCategory name=\(name) path=\(path)")
        case .newTag:
            guard !text.isEmpty else { cancelDialog(); return }
            engine.createTags([text])
            writeProbeLog("[engine] createTag tag=\(text)")
        case .addTracker:
            let urls = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
            guard !urls.isEmpty else { cancelDialog(); return }
            engine.addTrackers(id: selectedIDs.first ?? "", urls: urls)
            writeProbeLog("[details] addTracker urls=\(urls.count)")
        case .editTracker(let original):
            guard !text.isEmpty, !selectedIDs.isEmpty else { cancelDialog(); return }
            engine.editTracker(id: selectedIDs.first ?? "", oldURL: original, newURL: text)
            writeProbeLog("[details] editTracker")
        case .addWebSeed:
            let urls = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
            guard !urls.isEmpty else { cancelDialog(); return }
            engine.addWebSeeds(id: selectedIDs.first ?? "", urls: urls)
            writeProbeLog("[details] addWebSeed urls=\(urls.count)")
        case .editWebSeed(let original):
            guard !text.isEmpty, !selectedIDs.isEmpty else { cancelDialog(); return }
            engine.editWebSeed(id: selectedIDs.first ?? "", oldURL: original, newURL: text)
            writeProbeLog("[details] editWebSeed")
        }
        activeDialog = nil
        reloadOrganizers(force: true)
        refresh()
        if selectedIDs.first != nil {
            scheduleDetailsFetch(for: selectedIDs.first!)
        }
    }

    var canPauseAll: Bool {
        isConnected && torrents.contains { $0.status != .stopped }
    }

    var canResumeAll: Bool {
        isConnected && torrents.contains { $0.status == .stopped }
    }

    func pauseAll() {
        stopTorrents(torrents.filter { $0.status != .stopped }.map(\.id))
    }

    func resumeAll() {
        startTorrents(torrents.filter { $0.status == .stopped }.map(\.id))
    }
}
