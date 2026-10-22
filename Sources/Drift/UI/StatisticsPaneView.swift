import Charts
import SwiftUI

/// Full-page statistics dashboard: a live transfer-speed graph, Drift's own
/// lifetime record, and the connected server's transfer statistics — with
/// bar comparisons instead of bare value lists.
struct StatisticsPaneView: View {
    var model: ListViewModel

    private var downloadColor: Color { DesignSystem.Palette.accent }
    private var uploadColor: Color { DesignSystem.Palette.connectionOK }
    private var wastedColor: Color { Color.orange }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                speedCard
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
            return "Live transfer graph · qBittorrent \(version)"
        }
        return model.isConnected ? "Live transfer graph · server" : "Not connected"
    }

    // MARK: - Speed graph

    private var speedCard: some View {
        let samples = AppStats.shared.speedHistory
        let latest = samples.last
        let peak = max(
            samples.map(\.down).max() ?? 0,
            samples.map(\.up).max() ?? 0
        )
        return statsCard("Live speed", icon: "waveform.path.ecg") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 18) {
                    liveMetric(
                        "Download",
                        value: DesignSystem.Format.speed(latest?.down ?? 0),
                        color: downloadColor,
                        symbol: "arrow.down"
                    )
                    liveMetric(
                        "Upload",
                        value: DesignSystem.Format.speed(latest?.up ?? 0),
                        color: uploadColor,
                        symbol: "arrow.up"
                    )
                    Spacer()
                    if let peakAt = AppStats.shared.peakDownloadAt {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("Peak \(DesignSystem.Format.speed(AppStats.shared.peakDownloadBps))")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(downloadColor)
                            Text(peakAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                ZStack {
                    Chart {
                        ForEach(samples) { sample in
                            AreaMark(
                                x: .value("Time", sample.at),
                                y: .value("Speed", sample.down),
                                series: .value("Series", "Download")
                            )
                            .interpolationMethod(.monotone)
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [downloadColor.opacity(0.32), downloadColor.opacity(0.02)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            LineMark(
                                x: .value("Time", sample.at),
                                y: .value("Speed", sample.down),
                                series: .value("Series", "Download")
                            )
                            .interpolationMethod(.monotone)
                            .foregroundStyle(downloadColor)
                            .lineStyle(StrokeStyle(lineWidth: 1.6))

                            LineMark(
                                x: .value("Time", sample.at),
                                y: .value("Speed", sample.up),
                                series: .value("Series", "Upload")
                            )
                            .interpolationMethod(.monotone)
                            .foregroundStyle(uploadColor)
                            .lineStyle(StrokeStyle(lineWidth: 1.4))
                        }

                        if AppStats.shared.peakDownloadBps > 0 {
                            RuleMark(y: .value("Peak", AppStats.shared.peakDownloadBps))
                                .foregroundStyle(downloadColor.opacity(0.35))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                            AxisGridLine().foregroundStyle(.quaternary)
                            AxisValueLabel(format: .dateTime.hour().minute().second())
                                .font(.caption2)
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                            AxisGridLine().foregroundStyle(.quaternary)
                            AxisValueLabel {
                                if let bytes = value.as(Int64.self) {
                                    Text(axisSpeed(bytes))
                                        .font(.caption2)
                                }
                            }
                        }
                    }
                    .chartYScale(domain: 0...max(Double(peak) * 1.15, 1024))
                    .frame(height: 150)

                    if samples.count < 2 {
                        VStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(model.isConnected
                                 ? "Collecting transfer samples…"
                                 : "Connect to a server to graph live speed.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.background.opacity(0.6))
                    }
                }

                HStack(spacing: 14) {
                    legendDot(downloadColor, "Download")
                    legendDot(uploadColor, "Upload")
                    Spacer()
                    if samples.count >= 2, let first = samples.first, let last = samples.last {
                        Text("\(Self.durationText(last.at.timeIntervalSince(first.at))) window")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private func liveMetric(
        _ title: String,
        value: String,
        color: Color,
        symbol: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(color)
        }
    }

    private func legendDot(_ color: Color, _ title: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func axisSpeed(_ bytes: Int64) -> String {
        if bytes == 0 { return "0" }
        return bytes.formatted(.byteCount(style: .memory)) + "/s"
    }

    // MARK: - Drift lifetime

    private var appStatsCard: some View {
        let stats = AppStats.shared
        let maxTotal = max(stats.totalReceivedBytes, stats.totalSentBytes, 1)
        return statsCard("Drift lifetime", icon: "calendar.badge.clock") {
            VStack(alignment: .leading, spacing: 14) {
                Chart {
                    BarMark(
                        x: .value("Bytes", stats.totalReceivedBytes),
                        y: .value("Kind", "Downloaded")
                    )
                    .foregroundStyle(downloadColor)
                    .cornerRadius(4)
                    .annotation(position: .trailing, alignment: .leading) {
                        Text(DesignSystem.Format.size(stats.totalReceivedBytes))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    BarMark(
                        x: .value("Bytes", stats.totalSentBytes),
                        y: .value("Kind", "Uploaded")
                    )
                    .foregroundStyle(uploadColor)
                    .cornerRadius(4)
                    .annotation(position: .trailing, alignment: .leading) {
                        Text(DesignSystem.Format.size(stats.totalSentBytes))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .leading) { _ in
                        AxisValueLabel()
                            .font(.caption)
                    }
                }
                .chartXScale(domain: 0...Double(maxTotal) * 1.35)
                .chartYScale(domain: ["Downloaded", "Uploaded"])
                .frame(height: 74)

                if stats.boosterReceivedBytes > 0 {
                    boosterShareBar(stats)
                }

                Grid(
                    alignment: .leading,
                    horizontalSpacing: DesignSystem.Spacing.lg,
                    verticalSpacing: 8
                ) {
                    valueRow("Fastest download speed") {
                        HStack(spacing: 6) {
                            Text(DesignSystem.Format.speed(stats.peakDownloadBps))
                                .foregroundStyle(downloadColor)
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
                                .foregroundStyle(uploadColor)
                            if let at = stats.peakUploadAt {
                                Text(at, format: .dateTime.month(.abbreviated).day().hour().minute())
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
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
        }
    }

    /// Thin two-segment bar: direct downloads vs Booster-fetched bytes.
    private func boosterShareBar(_ stats: AppStats) -> some View {
        let total = max(stats.totalReceivedBytes, 1)
        let booster = stats.boosterReceivedBytes
        let direct = max(total - booster, 0)
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Booster share of downloads")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int((Double(booster) / Double(total) * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    if direct > 0 {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(downloadColor.opacity(0.35))
                            .frame(width: max(0, proxy.size.width * CGFloat(direct) / CGFloat(total) - 1))
                    }
                    if booster > 0 {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.orange)
                            .frame(width: max(0, proxy.size.width * CGFloat(booster) / CGFloat(total) - 1))
                    }
                }
            }
            .frame(height: 8)
            HStack {
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(downloadColor.opacity(0.35)).frame(width: 8, height: 8)
                    Text("Direct \(DesignSystem.Format.size(direct))")
                }
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.orange).frame(width: 8, height: 8)
                    Text("Booster \(DesignSystem.Format.size(booster))")
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Server

    @ViewBuilder
    private var serverStatsCard: some View {
        statsCard("This server (qBittorrent)", icon: "server.rack") {
            if let stats = model.statistics {
                sessionBar(stats)
                Divider().opacity(0.5)
                allTimeBars(stats)
                Grid(
                    alignment: .leading,
                    horizontalSpacing: DesignSystem.Spacing.lg,
                    verticalSpacing: 8
                ) {
                    valueRow("Global share ratio") {
                        Text(String(format: "%.2f", stats.globalRatio))
                    }
                    valueRow("Free space on server") {
                        Text(DesignSystem.Format.size(max(0, stats.freeSpaceOnDisk)))
                    }
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
            }
        }
    }

    /// Stacked session bar: downloaded, uploaded, wasted.
    private func sessionBar(_ stats: ServerStatistics) -> some View {
        let total = stats.received + stats.sent + stats.wasted
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("This session")
                    .font(.subheadline.weight(.medium))
                Spacer()
                if total == 0 {
                    Text("No transfer this session")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if total > 0 {
                Chart {
                    BarMark(x: .value("Bytes", stats.received), y: .value("Session", "Session"))
                        .foregroundStyle(by: .value("Kind", "Downloaded"))
                    BarMark(x: .value("Bytes", stats.sent), y: .value("Session", "Session"))
                        .foregroundStyle(by: .value("Kind", "Uploaded"))
                    BarMark(x: .value("Bytes", stats.wasted), y: .value("Session", "Session"))
                        .foregroundStyle(by: .value("Kind", "Wasted"))
                }
                .chartForegroundStyleScale([
                    "Downloaded": downloadColor,
                    "Uploaded": uploadColor,
                    "Wasted": wastedColor
                ])
                .chartLegend(.hidden)
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 22)
            }
            HStack(spacing: 16) {
                sessionLegend(downloadColor, "Downloaded", stats.received)
                sessionLegend(uploadColor, "Uploaded", stats.sent)
                sessionLegend(wastedColor, "Wasted", stats.wasted)
            }
        }
    }

    private func sessionLegend(_ color: Color, _ title: String, _ bytes: Int64) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text("\(title) \(DesignSystem.Format.size(bytes))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// All-time downloaded vs uploaded bars, same style as Drift lifetime.
    private func allTimeBars(_ stats: ServerStatistics) -> some View {
        let maxTotal = max(stats.receivedAllTime, stats.sentAllTime, 1)
        return VStack(alignment: .leading, spacing: 8) {
            Text("All time")
                .font(.subheadline.weight(.medium))
            Chart {
                BarMark(
                    x: .value("Bytes", stats.receivedAllTime),
                    y: .value("Kind", "Downloaded")
                )
                .foregroundStyle(downloadColor)
                .cornerRadius(4)
                .annotation(position: .trailing, alignment: .leading) {
                    Text(DesignSystem.Format.size(stats.receivedAllTime))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                BarMark(
                    x: .value("Bytes", stats.sentAllTime),
                    y: .value("Kind", "Uploaded")
                )
                .foregroundStyle(uploadColor)
                .cornerRadius(4)
                .annotation(position: .trailing, alignment: .leading) {
                    Text(DesignSystem.Format.size(stats.sentAllTime))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisValueLabel()
                        .font(.caption)
                }
            }
            .chartXScale(domain: 0...Double(maxTotal) * 1.35)
            .chartYScale(domain: ["Downloaded", "Uploaded"])
            .frame(height: 74)
        }
    }

    // MARK: - Shared chrome

    private func statsCard(
        _ title: String,
        icon: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.headline)
            content()
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
