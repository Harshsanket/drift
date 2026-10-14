import SwiftUI

struct ContentView: View {
    @Bindable var model: ListViewModel
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
        .sheet(isPresented: $model.showAddSheet) {
            AddTorrentSheet(model: model)
        }
        .sheet(isPresented: $model.showConnectionSheet) {
            ConnectionSheet()
        }
        .onAppear {
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
                    for _ in 0..<10 {
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
