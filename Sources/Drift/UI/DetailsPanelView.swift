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
            .padding(.bottom, DesignSystem.Spacing.sm)

            Text("Details coming soon")
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .frame(height: 80)
        }
        .padding(.horizontal, DesignSystem.Spacing.lg)
        .padding(.top, DesignSystem.Spacing.md)
        .padding(.bottom, DesignSystem.Spacing.sm)
    }
}
