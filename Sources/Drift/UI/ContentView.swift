import SwiftUI
import AppKit

struct ContentView: View {
    @Bindable var model: ListViewModel
    @Environment(\.openWindow) private var openWindow
    @FocusState private var filterFocused: Bool
    @State private var sidebarWidth: CGFloat = SidebarWidthPreference.defaultValue
    @State private var detailTopInset: CGFloat = DesignSystem.Metrics.titlebarBand

    private var footerRadius: CGFloat {
        model.detailsCollapsed ? DesignSystem.Metrics.statusBarHeight / 2 : 16
    }

    /// How far the padded header extends past whatever top safe-area inset the
    /// detail column actually has (the titlebar strip in a normal window, 0 in
    /// fullscreen). Measured, not assumed, so the header never overlaps the
    /// table's column-header row.
    private var headerOverflow: CGFloat {
        max(0, DesignSystem.Metrics.headerHeight - detailTopInset)
    }

    var body: some View {
        ZStack(alignment: .top) {
            NavigationSplitView(columnVisibility: .constant(.all)) {
                SidebarView(model: model)
                    // NavigationSplitView installs its own sidebar toggle in the
                    // window toolbar, which would duplicate the one drawn in the
                    // titlebar row. Removing it also drops the empty toolbar, so
                    // the titlebar collapses to the compact header strip.
                    //
                    // Keep this modifier ABOVE `navigationSplitViewColumnWidth`:
                    // the other order discards the width preference and the
                    // sidebar silently collapses to 144pt, truncating its labels.
                    .toolbar(removing: .sidebarToggle)
                    // Fixed width (min = max): the split divider is not draggable.
                    .navigationSplitViewColumnWidth(210)
            } detail: {
                TorrentListView(model: model)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        Color.clear
                            .frame(height: headerOverflow)
                            .allowsHitTesting(false)
                    }
                    // Outside the safeAreaInset so it measures only the system
                    // inset, not our own overflow padding.
                    .background {
                        GeometryReader { proxy in
                            Color.clear
                                .onAppear { detailTopInset = proxy.safeAreaInsets.top }
                                .onChange(of: proxy.safeAreaInsets.top) { _, newInset in
                                    detailTopInset = newInset
                                }
                        }
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        footer
                    }
                    // The window itself is transparent so the sidebar can show
                    // the desktop; the detail column must stay solid.
                    .background(Color(nsColor: .windowBackgroundColor))
            }
            .tint(DesignSystem.Palette.accent)
            .onPreferenceChange(SidebarWidthPreference.self) { width in
                sidebarWidth = width
            }

            header.ignoresSafeArea(.container, edges: .top)
        }
        .navigationTitle("Drift")
        .background(TransparentWindowAttachment())
        .background(WindowVisibilityProbe { model.setWindowVisible($0) })
        .sheet(isPresented: $model.showAddSheet) {
            AddTorrentSheet(model: model)
        }
        .sheet(isPresented: $model.showConnectionSheet) {
            ConnectionSheet()
        }
        .preferredColorScheme(AppSettings.shared.appearance.colorScheme)
        .onAppear {
            writeProbeLog("[nav] content appear")
            WindowOpener.openMain = { openWindow(id: "main") }
            // Verification-only: --show-settings opens the settings window.
            if ProcessInfo.processInfo.arguments.contains("--show-settings") {
                openWindow(id: "settings")
            }
            // Verification-only: --test-settings opens the window, flips
            // appearance + destination (persisted), then restores defaults.
            if ProcessInfo.processInfo.arguments.contains("--test-settings") {
                openWindow(id: "settings")
                AppSettings.shared.appearance = .dark
                AppSettings.shared.defaultSavePath = "/tmp/drift-downloads"
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    AppSettings.shared.appearance = .system
                    AppSettings.shared.defaultSavePath = "~/Downloads"
                    writeProbeLog("[settings] test sequence done")
                }
            }
            // Verification-only: --show-add-sheet opens the sheet at launch;
            // --test-add runs the add pipeline directly (logic check without typing).
            if ProcessInfo.processInfo.arguments.contains("--show-add-sheet") {
                model.showAddSheet = true
            }
            if ProcessInfo.processInfo.arguments.contains("--test-add") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    model.confirmAdd(
                        source: .magnetOrURL("magnet:?xt=urn:btih:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa&dn=Test+Added+Torrent&xl=1234567890"),
                        savePath: "~/Downloads"
                    )
                }
            }
            // Verification-only: --test-actions runs the mutation pipeline
            // (stop, start, remove), then opens the removal confirmation.
            if ProcessInfo.processInfo.arguments.contains("--test-actions") {
                let torrents = model.torrents
                guard torrents.count >= 8 else { return }
                let stopID = torrents[0].id
                let startID = torrents[3].id
                let removeID = torrents[4].id
                let alertID = torrents[6].id
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    model.stopTorrents([stopID])
                    model.startTorrents([startID])
                    model.requestRemoval([removeID])
                    model.confirmRemoval()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                    model.requestRemoval([alertID])
                }
            }
            // Verification-only: --test-mutations drives start/stop/remove/add
            // against the real backend once --test-sync has connected.
            if ProcessInfo.processInfo.arguments.contains("--test-mutations") {
                Task { @MainActor in
                    for _ in 0..<40 {
                        if model.isRealBackend { break }
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                    guard model.isRealBackend else {
                        writeProbeLog("[engine] mutations skipped (mock backend)")
                        return
                    }
                    var stoppedTarget: String?
                    if let running = model.torrents.first(where: { $0.status != .stopped }) {
                        stoppedTarget = running.id
                        model.stopTorrents([running.id])
                    }
                    try? await Task.sleep(for: .seconds(2))
                    if let stopped = model.torrents.first(where: {
                        $0.status == .stopped && $0.id != stoppedTarget
                    }) {
                        model.startTorrents([stopped.id])
                    }
                    try? await Task.sleep(for: .seconds(2))
                    model.confirmAdd(
                        source: .magnetOrURL("magnet:?xt=urn:btih:cccccccccccccccccccccccccccccccccccccccc&dn=drift-added-test"),
                        savePath: "~/Downloads"
                    )
                    try? await Task.sleep(for: .seconds(2.5))
                    if model.torrents.contains(where: { $0.id == "cccccccccccccccccccccccccccccccccccccccc" }) {
                        model.requestRemoval(["cccccccccccccccccccccccccccccccccccccccc"])
                        model.confirmRemoval()
                    }
                    try? await Task.sleep(for: .seconds(2))
                    if let ubuntu = model.torrents.first(where: { $0.name.contains("ubuntu-24.04") }) {
                        model.requestRemoval([ubuntu.id])
                        model.confirmRemoval()
                    }
                    try? await Task.sleep(for: .seconds(2))
                    model.confirmAdd(
                        source: .torrentFile(URL(fileURLWithPath: "/tmp/qbt-ubuntu.torrent")),
                        savePath: "~/Downloads"
                    )
                    try? await Task.sleep(for: .seconds(2.5))
                    writeProbeLog("[engine] mutations sequence done")
                }
            }
            // Verification-only: --test-details selects the first torrent,
            // waits for the async details fetch, logs section counts, then
            // flips the first file's priority (ignored → normal).
            if ProcessInfo.processInfo.arguments.contains("--test-details") {
                Task { @MainActor in
                    for _ in 0..<40 {
                        if model.isRealBackend { break }
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                    @MainActor func snapshot() {
                        guard let details = model.selectedDetails else {
                            writeProbeLog("[details] snapshot none")
                            return
                        }
                        let prios = details.files.map(\.priority.rawValue).joined(separator: ",")
                        writeProbeLog(
                            "[details] snapshot trackers=\(details.trackers.count)"
                                + " peers=\(details.peers.count)"
                                + " webSeeds=\(details.webSeeds.count)"
                                + " files=\(details.files.count)"
                                + " status=\(details.trackers.first?.status ?? "-")"
                                + " prio=[\(prios)]"
                        )
                    }
                    guard let first = model.torrents.first(where: { $0.name.contains("ubuntu") })
                        ?? model.torrents.first
                    else {
                        writeProbeLog("[details] skipped (no torrents)")
                        return
                    }
                    model.selectedIDs = [first.id]
                    model.detailsCollapsed = false
                    try? await Task.sleep(for: .seconds(2.5))
                    snapshot()
                    if let file = model.selectedDetails?.files.first {
                        model.setFilePriority(file: file, priority: .ignored)
                        try? await Task.sleep(for: .seconds(2.5))
                        snapshot()
                        if let fileNow = model.selectedDetails?.files.first {
                            model.setFilePriority(file: fileNow, priority: .normal)
                            try? await Task.sleep(for: .seconds(2))
                            snapshot()
                        }
                    }
                    writeProbeLog("[details] sequence done")
                }
            }
            // Verification-only: --test-lifecycle drives the tier + sleep/wake
            // handlers against the real backend (log-verifiable sequence).
            if ProcessInfo.processInfo.arguments.contains("--test-lifecycle") {
                Task { @MainActor in
                    await model.connectRealBackend(
                        force: true,
                        passwordOverride: ProcessInfo.processInfo.environment["DRIFT_TEST_PASSWORD"]
                    )
                    guard model.isRealBackend else {
                        writeProbeLog("[lifecycle] skipped (connect failed)")
                        return
                    }
                    AppSettings.shared.showMenuBarItem = true
                    model.setWindowVisible(false)
                    try? await Task.sleep(for: .seconds(8))
                    model.handleSystemSleep()
                    try? await Task.sleep(for: .seconds(1))
                    model.handleSystemWake()
                    try? await Task.sleep(for: .seconds(4))
                    model.setWindowVisible(true)
                    try? await Task.sleep(for: .seconds(2))
                    writeProbeLog("[lifecycle] sequence done")
                }
            }
            // Verification-only: --test-menu drives the menu bar slice —
            // snapshot, pause/resume all, summary tier, item-off suspension,
            // re-enable resume (log-countable sequence).
            if ProcessInfo.processInfo.arguments.contains("--test-menu") {
                Task { @MainActor in
                    writeProbeLog("[menubar] hook start")
                    await model.connectRealBackend(
                        force: true,
                        passwordOverride: ProcessInfo.processInfo.environment["DRIFT_TEST_PASSWORD"]
                    )
                    guard model.isRealBackend else {
                        writeProbeLog("[menubar] skipped (connect failed)")
                        return
                    }
                    AppSettings.shared.showMenuBarItem = true
                    func sleepLineCount() -> Int {
                        let text = (try? String(contentsOfFile: "/tmp/drift-probe.log")) ?? ""
                        return text.components(separatedBy: "sleep ").count - 1
                    }
                    let stats = model.transferStats()
                    writeProbeLog(
                        "[menubar] snapshot down=\(model.globalDownloadSpeed)"
                            + " up=\(model.globalUploadSpeed)"
                            + " dl=\(stats.downloading) seed=\(stats.seeding)"
                            + " prog=\(Int((stats.progress * 100).rounded()))"
                    )
                    model.pauseAll()
                    try? await Task.sleep(for: .seconds(3))
                    writeProbeLog(
                        "[menubar] after pause "
                            + model.torrents.map(\.status.rawValue).sorted()
                                .joined(separator: ",")
                    )
                    model.resumeAll()
                    try? await Task.sleep(for: .seconds(3))
                    writeProbeLog(
                        "[menubar] after resume "
                            + model.torrents.map(\.status.rawValue).sorted()
                                .joined(separator: ",")
                    )

                    model.setWindowVisible(false)
                    try? await Task.sleep(for: .seconds(8))
                    writeProbeLog("[menubar] phase=summary")

                    AppSettings.shared.showMenuBarItem = false
                    let sleepBefore = sleepLineCount()
                    try? await Task.sleep(for: .seconds(7))
                    let sleepAfter = sleepLineCount()
                    writeProbeLog(
                        "[menubar] phase=suspended sleeps \(sleepBefore)->\(sleepAfter)"
                    )

                    AppSettings.shared.showMenuBarItem = true
                    try? await Task.sleep(for: .seconds(5))
                    writeProbeLog("[menubar] phase=re-enabled")

                    model.setWindowVisible(true)
                    try? await Task.sleep(for: .seconds(2))
                    writeProbeLog("[menubar] sequence done")
                }
            }
            // Verification-only: --test-power drives the sleep-prevention
            // manager through default → arm → assert → immediate-off →
            // re-arm → 30s inactivity release (log + pmset verifiable).
            if ProcessInfo.processInfo.arguments.contains("--test-power") {
                Task { @MainActor in
                    let settings = AppSettings.shared
                    let power = PowerManagementManager.shared
                    writeProbeLog("[power] sequence start enabled=\(settings.preventIdleSleep ? "on" : "off")")
                    try? await Task.sleep(for: .seconds(1))

                    settings.preventIdleSleep = true
                    try? await Task.sleep(for: .seconds(1))
                    power.noteObservation(active: true)
                    try? await Task.sleep(for: .seconds(1))
                    power.noteObservation(active: true)
                    writeProbeLog("[power] phase=held pmset-check-now")
                    try? await Task.sleep(for: .seconds(4))

                    settings.preventIdleSleep = false
                    writeProbeLog("[power] phase=immediate-off done")
                    try? await Task.sleep(for: .seconds(1))

                    settings.preventIdleSleep = true
                    try? await Task.sleep(for: .seconds(1))
                    power.noteObservation(active: true)
                    try? await Task.sleep(for: .seconds(1))
                    power.noteObservation(active: true)
                    power.noteObservation(active: false)
                    writeProbeLog("[power] phase=waiting-inactivity-release")
                    try? await Task.sleep(for: .seconds(40))
                    writeProbeLog("[power] phase=inactivity-check pmset-check-now")

                    settings.preventIdleSleep = false
                    try? await Task.sleep(for: .seconds(1))
                    writeProbeLog("[power] sequence done")
                }
            }
            // Verification-only: --bench <mode> parks the app in a stable
            // tier for benchmarks/measure.sh (Phase 14):
            //   active    — window visible, item on  (.active tier)
            //   summary   — window hidden, item on   (.summary tier)
            //   suspended — window hidden, item off  (sync suspended)
            //   power     — summary + sleep-prevention ON (assertion held)
            if let idx = ProcessInfo.processInfo.arguments.firstIndex(of: "--bench"),
                idx + 1 < ProcessInfo.processInfo.arguments.count
            {
                let mode = ProcessInfo.processInfo.arguments[idx + 1]
                Task { @MainActor in
                    writeProbeLog("[bench] mode=\(mode) start")
                    await model.connectRealBackend(
                        force: true,
                        passwordOverride: ProcessInfo.processInfo.environment["DRIFT_TEST_PASSWORD"]
                    )
                    guard model.isRealBackend else {
                        writeProbeLog("[bench] skipped (connect failed)")
                        return
                    }
                    switch mode {
                    case "active":
                        AppSettings.shared.showMenuBarItem = true
                        model.setWindowVisible(true)
                    case "summary", "suspended", "power":
                        AppSettings.shared.showMenuBarItem = mode != "suspended"
                        if mode == "power" {
                            AppSettings.shared.preventIdleSleep = true
                        }
                        model.setWindowVisible(false)
                        // Physically leave the screen too — otherwise the
                        // occlusion probe sees the window and flips the
                        // tier back to active.
                        for window in NSApp.windows {
                            window.orderOut(nil)
                        }
                    default:
                        writeProbeLog("[bench] unknown mode \(mode)")
                        return
                    }
                    writeProbeLog("[bench] mode=\(mode) ready")
                }
            }
            // Verification-only: --show-connection-sheet opens the connection
            // sheet; --test-connection pings the stored endpoint (or
            // DRIFT_TEST_PASSWORD override) so the result is log-verifiable.
            if ProcessInfo.processInfo.arguments.contains("--show-connection-sheet") {
                model.showConnectionSheet = true
            }
            if ProcessInfo.processInfo.arguments.contains("--test-connection") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    let settings = ConnectionSettings.shared
                    let envPassword = ProcessInfo.processInfo.environment["DRIFT_TEST_PASSWORD"]
                    let keychainPassword = Keychain.password(account: "password")
                    let source = envPassword != nil
                        ? "env(\(envPassword!.count))"
                        : keychainPassword.map { "keychain(\($0.count))" } ?? "none"
                    writeProbeLog("[conn] test password source=\(source)")
                    let password = envPassword ?? keychainPassword ?? ""
                    Task {
                        await settings.test(
                            baseUrl: settings.baseUrl,
                            username: settings.username,
                            password: password
                        )
                    }
                }
            }
            // Verification-only: --test-sync forces a real backend connection
            // (bypasses the prior-success opt-in) using DRIFT_TEST_PASSWORD.
            if ProcessInfo.processInfo.arguments.contains("--test-sync") {
                Task {
                    await model.connectRealBackend(
                        force: true,
                        passwordOverride: ProcessInfo.processInfo.environment["DRIFT_TEST_PASSWORD"]
                    )
                    var last = ""
                    for _ in 0..<20 {
                        try? await Task.sleep(for: .seconds(1.5))
                        let row = model.filtered.first
                        let snap = row.map {
                            "\($0.name)|s=\($0.status.rawValue)|p=\($0.progress)|d=\($0.downloadSpeed)"
                        } ?? "empty(\(model.filtered.count))"
                        if snap != last {
                            last = snap
                            writeProbeLog("[sync] sample \(snap)")
                        }
                    }
                }
            }
        }
    }

    /// One continuous titlebar row: traffic lights alone on the left (the app
    /// title sits above the table's Name/Status columns), independently
    /// separated capsule controls on the right.
    private var header: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                HStack(spacing: 0) {
                    HeaderLeadingControls()

                    Text("Drift")
                        .font(.system(size: DesignSystem.Metrics.titleSize, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.leading, max(
                            0,
                            sidebarWidth
                                - DesignSystem.Metrics.trafficLightInset
                                + DesignSystem.Metrics.titleLeading
                        ))
                }
                .frame(height: DesignSystem.Metrics.headerHeight)
                .simultaneousGesture(TapGesture().onEnded {
                    model.collapseDetailsFromOutsideClick()
                })

                Spacer(minLength: DesignSystem.Metrics.controlGap)
                HeaderTrailingControls(
                    model: model,
                    availableWidth: proxy.size.width
                        - DesignSystem.Metrics.sidebarReserve,
                    filterFocused: $filterFocused
                )
            }
            .frame(height: DesignSystem.Metrics.headerHeight)
        }
        .frame(height: DesignSystem.Metrics.headerHeight)
    }

    /// Floating footer. It is anchored to the detail column's safe area, so the
    /// bar follows the torrent table's boundaries instead of the window's and
    /// never runs underneath the sidebar. Double-clicking it grows the same
    /// surface into the details panel rather than stacking a second bar.
    private var footer: some View {
        VStack(spacing: 0) {
            if !model.detailsCollapsed {
                DetailsPanelView(model: model)
                    .transition(.opacity)
            }

            StatusbarView(model: model)
        }
        .glassEffect(
            .regular,
            in: RoundedRectangle(cornerRadius: footerRadius, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: footerRadius, style: .continuous))
        .onTapGesture(count: 2) {
            model.toggleDetails()
        }
        .help(model.detailsCollapsed ? "Double-click to show details" : "Double-click to hide details")
        .padding(.horizontal, DesignSystem.Metrics.statusBarSideMargin)
        .padding(.bottom, DesignSystem.Metrics.statusBarBottomMargin)
    }
}
