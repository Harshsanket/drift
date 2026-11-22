// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import AppKit

struct ContentView: View {
    @Bindable var model: ListViewModel
    @Environment(\.openWindow) private var openWindow
    @FocusState private var filterFocused: Bool
    @State private var sidebarWidth: CGFloat = SidebarWidthPreference.defaultValue
    @State private var detailTopInset: CGFloat = DesignSystem.Metrics.titlebarBand
    @State private var updateChecker = UpdateChecker.shared

    private var footerRadius: CGFloat {
        model.detailsCollapsed ? DesignSystem.Metrics.statusBarHeight / 2 : 16
    }

    /// Maps anything the OS hands us (magnet: URL callback, opening a .torrent
    /// document, dragging one in) to an add-flow source.
    static func handoff(for url: URL) -> AddSource? {
        if url.isFileURL {
            return url.pathExtension.lowercased() == "torrent" ? .torrentFile(url) : nil
        }
        if let scheme = url.scheme?.lowercased(),
           scheme == "magnet" || scheme == "http" || scheme == "https" {
            return .magnetOrURL(url.absoluteString)
        }
        return nil
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
                if model.showSearchPane {
                    SearchPaneView(model: model)
                        .safeAreaInset(edge: .top, spacing: 0) {
                            Color.clear
                                .frame(height: headerOverflow)
                                .allowsHitTesting(false)
                        }
                        .background(DetailInsetProbe { detailTopInset = $0 })
                        .background(Color(nsColor: .windowBackgroundColor))
                        .overlay(alignment: .bottom) { footer }
                } else if model.showStatsPane {
                    StatisticsPaneView(model: model)
                        .safeAreaInset(edge: .top, spacing: 0) {
                            Color.clear
                                .frame(height: headerOverflow)
                                .allowsHitTesting(false)
                        }
                        .background(DetailInsetProbe { detailTopInset = $0 })
                        .background(Color(nsColor: .windowBackgroundColor))
                        .overlay(alignment: .bottom) { footer }
                } else {
                    TorrentListView(model: model)
                        .safeAreaInset(edge: .top, spacing: 0) {
                            Color.clear
                                .frame(height: headerOverflow)
                                .allowsHitTesting(false)
                        }
                        // Outside the safeAreaInset so it measures only the
                        // system inset, not our own overflow padding.
                        .background(DetailInsetProbe { detailTopInset = $0 })
                        // The window is transparent so the sidebar can show
                        // the desktop; the detail column must stay solid.
                        .background(Color(nsColor: .windowBackgroundColor))
                        .overlay(alignment: .bottom) {
                            footer
                        }
                }
            }
            .tint(DesignSystem.Palette.accent)
            .onPreferenceChange(SidebarWidthPreference.self) { width in
                sidebarWidth = width
            }
            .onChange(of: model.selectedIDs) { _, ids in
                writeProbeLog("[model] selection count=\(ids.count) first=\(ids.first?.prefix(8) ?? "-")")
            }

            header.ignoresSafeArea(.container, edges: .top)
        }
        .navigationTitle("Drift")
        .background(TransparentWindowAttachment())
        .background(WindowVisibilityProbe { model.setWindowVisible($0) })
        .sheet(isPresented: $model.showAddSheet) {
            AddTorrentSheet(model: model)
        }
        .sheet(isPresented: $model.showBoostSheet) {
            BoostSourceSheet(model: model)
        }
        .sheet(isPresented: $model.showUpdateSheet) {
            UpdatePromptSheet()
        }
        .sheet(isPresented: $updateChecker.promptVisible) {
            GitHubUpdatePrompt()
        }
        .onOpenURL { url in
            if let handoff = Self.handoff(for: url) {
                model.handleOSHandoff(handoff)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            for url in urls {
                if let handoff = Self.handoff(for: url) {
                    model.handleOSHandoff(handoff)
                    return true
                }
            }
            return false
        }
        .preferredColorScheme(AppSettings.shared.appearance.colorScheme)
        .onAppear {
            writeProbeLog("[nav] content appear")
            CompletionMonitor.shared.requestPermission()
            WindowOpener.openMain = { openWindow(id: "main") }
            WindowOpener.openSettings = { openWindow(id: "settings") }
            VerificationHooks.runIfNeeded(model: model) { openWindow(id: $0) }
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

    /// Reports the detail column's system top safe-area inset (titlebar band
    /// in-window, 0 fullscreen) so the padded header can overflow past it.
    private struct DetailInsetProbe: View {
        let report: (CGFloat) -> Void
        var body: some View {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { report(proxy.safeAreaInsets.top) }
                    .onChange(of: proxy.safeAreaInsets.top) { _, newInset in
                        report(newInset)
                    }
            }
        }
    }

    /// Floating footer. It is anchored to the detail column's safe area, so the
    /// bar follows the torrent table's boundaries instead of the window's and
    /// never runs underneath the sidebar. Double-clicking it grows the same
    /// surface into the details panel rather than stacking a second bar.
    private var footer: some View {
        VStack(spacing: 0) {
            // Always present, revealed top-down by the animated progress so
            // the glass grows smoothly and the table retreats per frame.
            DetailsPanelView(model: model)
                .frame(
                    height: DesignSystem.Metrics.detailsPanelHeight * model.detailsProgress,
                    alignment: .top
                )
                .clipped()
                .opacity(model.detailsProgress)

            StatusbarView(model: model)
        }
        .glassEffect(
            .regular,
            in: RoundedRectangle(cornerRadius: footerRadius, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: footerRadius, style: .continuous))
        .onTapGesture(count: 2) {
            writeProbeLog("[ui] footer double tap")
            model.toggleDetails()
        }
        .help(model.detailsCollapsed ? "Double-click to show details" : "Double-click to hide details")
        .padding(.horizontal, DesignSystem.Metrics.statusBarSideMargin)
        .padding(.bottom, DesignSystem.Metrics.statusBarBottomMargin)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            if abs(height - model.footerHeight) > 0.5 {
                model.footerHeight = height
                writeProbeLog("[footer] height=\(height)")
            }
        }
    }
}
