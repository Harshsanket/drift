import SwiftUI

struct ContentView: View {
    @Bindable var model: ListViewModel
    @FocusState private var filterFocused: Bool
    @State private var sidebarWidth: CGFloat = SidebarWidthPreference.defaultValue

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
                    .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
            } detail: {
                TorrentListView(model: model)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        Color.clear
                            .frame(height: headerOverflow)
                            .allowsHitTesting(false)
                    }
                    .overlay(alignment: .bottom) {
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
