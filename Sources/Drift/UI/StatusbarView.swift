import SwiftUI

struct StatusbarView: View {
    let model: ListViewModel

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.lg) {
            HStack(spacing: DesignSystem.Spacing.xs) {
                Circle()
                    .fill(model.isConnected
                          ? DesignSystem.Palette.connectionOK
                          : DesignSystem.Palette.connectionDown)
                    .frame(width: 8, height: 8)
                Text(model.isConnected ? "Connected" : "Disconnected")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Label {
                Text(DesignSystem.Format.speed(model.globalDownloadSpeed))
                    .monospacedDigit()
            } icon: {
                Image(systemName: "arrow.down")
                    .foregroundStyle(DesignSystem.Palette.downloading)
            }

            Label {
                Text(DesignSystem.Format.speed(model.globalUploadSpeed))
                    .monospacedDigit()
            } icon: {
                Image(systemName: "arrow.up")
                    .foregroundStyle(DesignSystem.Palette.seeding)
            }
        }
        .font(.callout)
        .padding(.horizontal, DesignSystem.Spacing.lg)
        .padding(.vertical, DesignSystem.Spacing.sm)
        .background(.bar)
    }
}
