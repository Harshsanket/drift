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

                HStack(spacing: DesignSystem.Spacing.lg) {
                    ForEach(["General", "Trackers", "Peers", "Sources", "Files"], id: \.self) { tab in
                        Text(tab)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .font(.callout)
                .padding(.horizontal, DesignSystem.Spacing.lg)
                .padding(.vertical, DesignSystem.Spacing.sm)

                Divider()

                Text("Details coming soon")
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: 160)
        }
    }
}
