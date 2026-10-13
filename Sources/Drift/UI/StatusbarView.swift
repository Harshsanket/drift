import SwiftUI

/// The content of the floating status bar: connection state on the left,
/// transfer speeds on the right, in a single balanced row. The surrounding
/// Liquid Glass surface is supplied by the expanding footer in `ContentView`.
struct StatusbarView: View {
    let model: ListViewModel

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.lg) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Circle()
                    .fill(model.isConnected
                          ? DesignSystem.Palette.connectionOK
                          : DesignSystem.Palette.connectionDown)
                    .frame(width: 8, height: 8)
                Text(model.isConnected ? "Connected" : "Disconnected")
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: DesignSystem.Spacing.md)

            HStack(spacing: DesignSystem.Spacing.lg) {
                speed(
                    systemImage: "arrow.down",
                    value: model.globalDownloadSpeed,
                    tint: DesignSystem.Palette.downloading
                )
                speed(
                    systemImage: "arrow.up",
                    value: model.globalUploadSpeed,
                    tint: DesignSystem.Palette.seeding
                )
            }
        }
        .font(.system(size: 12))
        .lineLimit(1)
        .padding(.horizontal, DesignSystem.Spacing.lg)
        .frame(maxWidth: .infinity, minHeight: DesignSystem.Metrics.statusBarHeight)
    }

    private func speed(systemImage: String, value: Int64, tint: Color) -> some View {
        let style: AnyShapeStyle = value > 0 ? AnyShapeStyle(tint) : AnyShapeStyle(.secondary)
        return HStack(spacing: DesignSystem.Spacing.xs) {
            Image(systemName: systemImage)
                .foregroundStyle(style)
            Text(DesignSystem.Format.speed(value))
                .monospacedDigit()
                .foregroundStyle(style)
        }
        .accessibilityElement(children: .combine)
    }
}
