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

    func refresh() {
        torrents = engine?.loadTorrents() ?? []
        if let real = engine as? WebAPIEngine {
            PowerManagementManager.shared.noteObservation(active: real.transferActivity())
        }
        reloadOrganizers()
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

    func confirmAdd(source: AddSource, savePath: String) {
        guard let engine, isConnected else { return }
        let summary = engine.addTorrent(source: source, savePath: savePath)
        refresh()
        selectedIDs = [summary.id]
        showAddSheet = false
        writeProbeLog("[sheet] added \(summary.id) savePath=\(savePath)")
    }

    func startTorrents(_ ids: [String]) {
        guard !ids.isEmpty, let engine, isConnected else { return }
        engine.start(ids: ids)
        refresh()
        writeProbeLog("[engine] start ids=\(ids.sorted().joined(separator: ","))")
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
        }
        activeDialog = nil
        reloadOrganizers(force: true)
        refresh()
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
