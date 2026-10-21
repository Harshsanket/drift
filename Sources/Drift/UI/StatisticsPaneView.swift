import SwiftUI

/// Full-page statistics dashboard: Drift's own lifetime record plus the
/// connected server's transfer statistics, presented instead of the torrent
/// table while open.
struct StatisticsPaneView: View {
    var model: ListViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                appStatsCard
                serverStatsCard
            }
            .padding(.horizontal, 20)
            .padding(.bottom, model.footerHeight + 16)
            .frame(maxWidth: 760, alignment: .center)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .top, spacing: 0) { paneHeader }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) {
            EmptyView()
        }
    }

    // MARK: - Header

    private var paneHeader: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Statistics")
                    .font(.title3.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.refreshStatistics()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(!model.isConnected)

            Button("Clear app stats", role: .destructive) {
                AppStats.shared.resetAll()
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(
            Rectangle()
                .fill(.regularMaterial)
                .overlay(alignment: .bottom) {
                    Divider().opacity(0.6)
                }
                .ignoresSafeArea(edges: .top)
        )
    }

    private var subtitle: String {
        if let version = model.connectionState.version {
            return "Drift lifetime · qBittorrent \(version)"
        }
        return model.isConnected ? "Drift lifetime · server" : "Not connected"
    }

    // MARK: - Cards

    private var appStatsCard: some View {
        statsCard("Drift lifetime", icon: "calendar.badge.clock") {
            let stats = AppStats.shared
            valueRow("Fastest download speed") {
                HStack(spacing: 6) {
                    Text(DesignSystem.Format.speed(stats.peakDownloadBps))
                        .foregroundStyle(Color.accentColor)
                    if let at = stats.peakDownloadAt {
                        Text(at, format: .dateTime.month(.abbreviated).day().hour().minute())
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            valueRow("Fastest upload speed") {
                HStack(spacing: 6) {
                    Text(DesignSystem.Format.speed(stats.peakUploadBps))
                        .foregroundStyle(Color.accentColor)
                    if let at = stats.peakUploadAt {
                        Text(at, format: .dateTime.month(.abbreviated).day().hour().minute())
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            valueRow("Downloaded") {
                Text(DesignSystem.Format.size(stats.totalReceivedBytes))
            }
            valueRow("Uploaded") {
                Text(DesignSystem.Format.size(stats.totalSentBytes))
            }
            if stats.boosterReceivedBytes > 0 {
                valueRow("Via Booster downloads") {
                    Text(DesignSystem.Format.size(stats.boosterReceivedBytes))
                }
            }
            valueRow("Active transfer time") {
                Text(Self.durationText(stats.transferSeconds))
            }
            if let first = stats.firstConnectedAt {
                valueRow("Tracking since") {
                    Text(first, format: .dateTime.year().month(.abbreviated).day())
                }
            }
        }
    }

    @ViewBuilder
    private var serverStatsCard: some View {
        statsCard("This server (qBittorrent)", icon: "server.rack") {
            if let stats = model.statistics {
                valueRow("Downloaded this session") {
                    Text(DesignSystem.Format.size(stats.received))
                }
                valueRow("Uploaded this session") {
                    Text(DesignSystem.Format.size(stats.sent))
                }
                valueRow("Wasted this session") {
                    Text(DesignSystem.Format.size(stats.wasted))
                }
                valueRow("Downloaded (all time)") {
                    Text(DesignSystem.Format.size(stats.receivedAllTime))
                }
                valueRow("Uploaded (all time)") {
                    Text(DesignSystem.Format.size(stats.sentAllTime))
                }
                valueRow("Global share ratio") {
                    Text(String(format: "%.2f", stats.globalRatio))
                }
                valueRow("Free space on server") {
                    Text(DesignSystem.Format.size(max(0, stats.freeSpaceOnDisk)))
                }
            } else {
                ContentUnavailableView(
                    "No server statistics yet",
                    systemImage: "chart.bar.doc.horizontal",
                    description: Text(
                        model.isConnected
                            ? "Transfer data appears once the server reports activity."
                            : "Connect to a qBittorrent server to collect transfer statistics.")
                )
                .frame(minHeight: 140, alignment: .center)
                .gridCellColumns(1)
            }
        }
    }

    private func statsCard(
        _ title: String,
        icon: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon)
                .font(.headline)
                .padding(.bottom, 6)
            Grid(
                alignment: .leading,
                horizontalSpacing: DesignSystem.Spacing.lg,
                verticalSpacing: 8
            ) {
                content()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.quaternary.opacity(0.5))
        )
    }

    private func valueRow(
        _ label: String,
        @ViewBuilder value: () -> some View
    ) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            value()
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private static func durationText(_ seconds: TimeInterval) -> String {
        var remaining = Int(seconds)
        var parts: [String] = []
        for (size, unit) in [(86400, "d"), (3600, "h"), (60, "m"), (1, "s")] {
            let value = remaining / size
            remaining %= size
            if value > 0 || !parts.isEmpty { parts.append("\(value)\(unit)") }
        }
        return parts.isEmpty ? "0s" : parts.joined(separator: " ")
    }
}
