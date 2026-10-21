import SwiftUI

struct StatisticsSheet: View {
    @Bindable var model: ListViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Statistics")
                .font(.headline)

            appStatsSection

            Divider()

            Text("This server (qBittorrent)")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let stats = model.statistics {
                Grid(
                    alignment: .leading,
                    horizontalSpacing: DesignSystem.Spacing.lg,
                    verticalSpacing: DesignSystem.Spacing.xs
                ) {
                    row("Downloaded this session") {
                        Text(DesignSystem.Format.size(stats.received))
                    }
                    row("Uploaded this session") {
                        Text(DesignSystem.Format.size(stats.sent))
                    }
                    row("Wasted this session") {
                        Text(DesignSystem.Format.size(stats.wasted))
                    }
                    row("Downloaded (all time)") {
                        Text(DesignSystem.Format.size(stats.receivedAllTime))
                    }
                    row("Uploaded (all time)") {
                        Text(DesignSystem.Format.size(stats.sentAllTime))
                    }
                    row("Global share ratio") {
                        Text(String(format: "%.2f", stats.globalRatio))
                    }
                    row("Free space on server") {
                        Text(DesignSystem.Format.size(max(0, stats.freeSpaceOnDisk)))
                    }
                }
            } else {
                Text("Start a connection to collect transfer statistics.")
                    .foregroundStyle(.secondary)
            }

    HStack {
        Button("Refresh") {
            model.refreshStatistics()
        }
        .disabled(!model.isConnected)
                Spacer()
                Button("Clear app stats") {
                    AppStats.shared.resetAll()
                }
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    /// Drift's own lifetime record: everything that moved through this app
    /// (qBittorrent sessions + Booster direct downloads), independent of any
    /// one server.
    @ViewBuilder
    private var appStatsSection: some View {
        let stats = AppStats.shared
        Grid(
            alignment: .leading,
            horizontalSpacing: DesignSystem.Spacing.lg,
            verticalSpacing: DesignSystem.Spacing.xs
        ) {
            row("Fastest download speed") {
                HStack(spacing: 6) {
                    Text(DesignSystem.Format.speed(stats.peakDownloadBps))
                    if let at = stats.peakDownloadAt {
                        Text(at, format: .dateTime.month(.abbreviated).day().hour().minute())
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            row("Fastest upload speed") {
                HStack(spacing: 6) {
                    Text(DesignSystem.Format.speed(stats.peakUploadBps))
                    if let at = stats.peakUploadAt {
                        Text(at, format: .dateTime.month(.abbreviated).day().hour().minute())
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            row("Downloaded (Drift lifetime)") {
                Text(DesignSystem.Format.size(stats.totalReceivedBytes))
            }
            row("Uploaded (Drift lifetime)") {
                Text(DesignSystem.Format.size(stats.totalSentBytes))
            }
            if stats.boosterReceivedBytes > 0 {
                row("Via Booster downloads") {
                    Text(DesignSystem.Format.size(stats.boosterReceivedBytes))
                }
            }
            row("Active transfer time") {
                Text(Self.durationText(stats.transferSeconds))
            }
            if let first = stats.firstConnectedAt {
                row("Tracking since") {
                    Text(first, format: .dateTime.year().month(.abbreviated).day())
                }
            }
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

    @ViewBuilder
    private func row(_ label: String, @ViewBuilder value: () -> some View) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            value()
                .monospacedDigit()
        }
    }
}
