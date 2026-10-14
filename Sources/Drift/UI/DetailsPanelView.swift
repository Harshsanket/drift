import SwiftUI

struct DetailsPanelView: View {
    @Bindable var model: ListViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Text(model.selectedTorrent?.name ?? "No selection")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(model.selectedTorrent == nil ? .tertiary : .primary)

                if model.selectedIDs.count > 1 {
                    Text("· \(model.selectedIDs.count) selected")
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(.bottom, DesignSystem.Spacing.sm)

            HStack(spacing: DesignSystem.Spacing.sm) {
                ForEach(DetailTab.allCases) { tab in
                    pill(tab)
                }
                Spacer()
            }
            .padding(.bottom, DesignSystem.Spacing.sm)

            content
        }
        .padding(.horizontal, DesignSystem.Spacing.lg)
        .padding(.top, DesignSystem.Spacing.md)
        .padding(.bottom, DesignSystem.Spacing.sm)
    }

    private func pill(_ tab: DetailTab) -> some View {
        let active = model.selectedTab == tab
        let enabled = model.selectedDetails != nil

        return Button {
            model.selectedTab = tab
        } label: {
            Text(tab.label)
                .font(.callout)
                .padding(.horizontal, DesignSystem.Spacing.md)
                .padding(.vertical, DesignSystem.Spacing.xs)
                .background {
                    if active {
                        Capsule(style: .continuous)
                            .fill(Color.accentColor.opacity(0.16))
                    } else {
                        Capsule(style: .continuous)
                            .fill(.quaternary)
                    }
                }
                .foregroundStyle(
                    active ? AnyShapeStyle(DesignSystem.Palette.accent) : AnyShapeStyle(.secondary)
                )
                .modifier(ActiveGlass(active: active))
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .help(tab.label)
        .accessibilityLabel(tab.label)
    }

    @ViewBuilder
    private var content: some View {
        Group {
            if let details = model.selectedDetails {
                tabContent(details)
            } else {
                DetailsEmptyState(title: "No torrent selected", systemImage: "cursor.arrow")
            }
        }
        .frame(height: 190)
    }

    @ViewBuilder
    private func tabContent(_ details: TorrentDetails) -> some View {
        switch model.selectedTab {
        case .general:
            if let torrent = model.selectedTorrent {
                GeneralTabView(torrent: torrent, general: details.general)
            } else {
                DetailsEmptyState(title: "No torrent selected", systemImage: "cursor.arrow")
            }
        case .trackers:
            TrackersTabView(rows: details.trackers)
        case .peers:
            PeersTabView(rows: details.peers)
        case .sources:
            SourcesTabView(rows: details.webSeeds)
        case .files:
            FilesTabView(rows: details.files)
        }
    }
}

private struct ActiveGlass: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            content.glassEffect(.regular, in: Capsule(style: .continuous))
        } else {
            content
        }
    }
}
