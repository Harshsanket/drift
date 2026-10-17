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
                // In-progress states (checking/moving) appear as live chips
                // only while they exist — no one rests in them, so they don't
                // merit permanent sidebar rows.
                if model.isConnected, model.count(for: .checking) > 0 {
                    statusChip(.checking)
                }
                if model.isConnected, model.count(for: .moving) > 0 {
                    statusChip(.moving)
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

    @ViewBuilder
    private func statusChip(_ status: TorrentStatus) -> some View {
        HStack(spacing: 4) {
            Image(systemName: status.systemImage)
            Text("\(status.label) \(model.count(for: StatusFilter(rawValue: status.rawValue) ?? .all))")
        }
        .foregroundStyle(status.tint)
        .monospacedDigit()
        .help("\(status.label) torrents on the server — informational only")
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
