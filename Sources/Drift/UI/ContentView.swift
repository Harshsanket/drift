import SwiftUI

struct ContentView: View {
    @Bindable var model: ListViewModel
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all
    @FocusState private var filterFocused: Bool

    private var isSidebarVisible: Bool { sidebarVisibility != .detailOnly }

    private var footerRadius: CGFloat {
        model.detailsCollapsed ? DesignSystem.Metrics.statusBarHeight / 2 : 16
    }

    /// How far the padded header extends past the band the system already keeps
    /// clear for the hidden titlebar. The split view insets its columns from the
    /// real safe area, so the overflow has to be added on top of it or the
    /// header would cover the table's first row.
    private var headerOverflow: CGFloat {
        max(0, DesignSystem.Metrics.headerHeight - DesignSystem.Metrics.titlebarBand)
    }

    var body: some View {
        ZStack(alignment: .top) {
            NavigationSplitView(columnVisibility: $sidebarVisibility) {
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
                    .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
            } detail: {
                TorrentListView(model: model)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        Color.clear
                            .frame(height: headerOverflow)
                            .allowsHitTesting(false)
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        footer
                    }
            }
            .tint(DesignSystem.Palette.accent)

            header.ignoresSafeArea(.container, edges: .top)
        }
        .navigationTitle("Drift")
        .onChange(of: sidebarVisibility) { _, _ in
            filterFocused = false
        }
        .onChange(of: filterFocused) { _, focused in
            if focused, sidebarVisibility == .detailOnly {
                filterFocused = false
            }
        }
    }

    /// One continuous titlebar row: traffic lights, sidebar toggle and title on
    /// the left, independently separated capsule controls on the right.
    private var header: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                HeaderLeadingControls(sidebarVisibility: $sidebarVisibility)
                Spacer(minLength: DesignSystem.Metrics.controlGap)
                HeaderTrailingControls(
                    model: model,
                    availableWidth: proxy.size.width
                        - (isSidebarVisible ? DesignSystem.Metrics.sidebarReserve : 0),
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
