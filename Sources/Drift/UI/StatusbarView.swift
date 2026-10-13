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
                    .foregroundStyle(model.globalDownloadSpeed > 0
                                     ? DesignSystem.Palette.downloading
                                     : Color.secondary)
            } icon: {
                Image(systemName: "arrow.down")
                    .foregroundStyle(model.globalDownloadSpeed > 0
                                     ? DesignSystem.Palette.downloading
                                     : Color.secondary)
            }

            Label {
                Text(DesignSystem.Format.speed(model.globalUploadSpeed))
                    .monospacedDigit()
                    .foregroundStyle(model.globalUploadSpeed > 0
                                     ? DesignSystem.Palette.seeding
                                     : Color.secondary)
            } icon: {
                Image(systemName: "arrow.up")
                    .foregroundStyle(model.globalUploadSpeed > 0
                                     ? DesignSystem.Palette.seeding
                                     : Color.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, DesignSystem.Spacing.lg)
        .padding(.vertical, DesignSystem.Spacing.xs)
        .frame(maxWidth: .infinity)
    }
}
