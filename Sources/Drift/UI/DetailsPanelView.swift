import SwiftUI

struct DetailsPanelView: View {
    @Bindable var model: ListViewModel

    var body: some View {
        if !model.detailsCollapsed {
            VStack(spacing: 0) {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                    Text(model.selectedTorrent?.name ?? "No selection")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(model.selectedTorrent == nil ? .tertiary : .primary)
                    if let torrent = model.selectedTorrent, model.selectedIDs.count > 1 {
                        Text("· \(model.selectedIDs.count) selected")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        model.detailsCollapsed = true
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Collapse details")
                }
                .padding(.horizontal, DesignSystem.Spacing.lg)
                .padding(.vertical, DesignSystem.Spacing.sm)

                Divider()

                HStack(spacing: DesignSystem.Spacing.sm) {
                    ForEach(["General", "Trackers", "Peers", "Sources", "Files"], id: \.self) { tab in
                        Text(tab)
                            .font(.callout)
                            .padding(.horizontal, DesignSystem.Spacing.md)
                            .padding(.vertical, DesignSystem.Spacing.xs)
                            .background(Capsule().fill(.quaternary))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .padding(.horizontal, DesignSystem.Spacing.lg)
                .padding(.vertical, DesignSystem.Spacing.sm)

                Divider()

                Text("Details coming soon")
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: 160)
            .background(.ultraThinMaterial)
        }
    }
}
