import SwiftUI

/// The content of the floating status bar: connection state on the left,
/// global transfer speeds on the right, in a single balanced row. The
/// surrounding Liquid Glass surface is supplied by the expanding footer in
/// `ContentView`.
struct StatusbarView: View {
    let model: ListViewModel

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.lg) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                connectionIndicator
                Text(model.connectionState.label)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if model.isConnected,
                   let stats = model.statistics,
                   stats.freeSpaceOnDisk > 0 {
                    Text(DesignSystem.Format.size(stats.freeSpaceOnDisk) + " free")
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                        .help("Free space on the server")
                }
            }

            Spacer(minLength: DesignSystem.Spacing.md)

            HStack(spacing: DesignSystem.Spacing.lg) {
                if model.altSpeedsActive {
                    Image(systemName: "gauge.with.needle")
                        .foregroundStyle(DesignSystem.Palette.stalled)
                        .help("Alternative speed limits are active")
                }
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

    @ViewBuilder
    private var connectionIndicator: some View {
        switch model.connectionState {
        case .connected:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(DesignSystem.Palette.seeding)
        case .connecting:
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
        case .disconnected, .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
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
