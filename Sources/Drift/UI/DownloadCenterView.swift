import SwiftUI

/// Downloads window: torrent piece-boost tasks plus any legacy direct-download
/// rows carried over from earlier sessions. Connection Booster configuration
/// lives entirely on the Settings page; this window only shows progress.
struct DownloadCenterView: View {
    @Bindable private var center = DownloadCenter.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "tray.and.arrow.down")
                    .foregroundStyle(.orange)
                Text("Downloads")
                    .font(.headline)
                Spacer()
            }
            .padding([.horizontal, .top], 14)
            .padding(.bottom, 2)

            if center.boosts.isEmpty && center.downloads.isEmpty {
                Text("No boosts or downloads right now.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.top, 6)
            } else {
                boostSection
                legacySection
            }

            Spacer(minLength: 0)
        }
        .frame(width: 470, height: 400)
        .onAppear {
            WindowOpener.openDownloads = { openWindow(id: "downloads") }
        }
    }

    @ViewBuilder
    private var boostSection: some View {
        if !center.boosts.isEmpty {
            VStack(spacing: 8) {
                ForEach(center.boosts) { task in
                    BoostRow(task: task)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
        }
    }

    @ViewBuilder
    private var legacySection: some View {
        if !center.downloads.isEmpty {
            Divider().padding(.horizontal, 14).padding(.top, 8)
            VStack(spacing: 8) {
                Text("Earlier direct downloads")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(center.downloads, id: \.id) { download in
                    DownloadRow(download: download)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
        }
    }
}
private struct BoostRow: View {
    @Bindable var task: TorrentBoostTask

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: statusIcon)
                .foregroundStyle(statusTint)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.torrentName)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if task.totalMissing > 0 {
                        Text("\(task.boostedPieces)/\(task.totalMissing) pieces")
                            .font(.caption)
                            .monospacedDigit()
                    }
                    if task.status == .boosting, task.liveSpeedBps > 0 {
                        Text(DesignSystem.Format.speed(Int64(task.liveSpeedBps)))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.orange)
                    }
                    if !task.message.isEmpty, task.status == .failed || task.status == .planning || task.status == .done {
                        Text(task.message)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer()
            if task.status == .boosting || task.status == .planning || task.status == .finishing {
                Button {
                    task.cancel()
                } label: {
                    Image(systemName: "stop.circle")
                }
                .buttonStyle(.plain)
                .help("Cancel boost (resumes the torrent)")
            }
        }
        .padding(.vertical, 4)
    }

    private var statusIcon: String {
        switch task.status {
        case .done: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .boosting: "bolt.circle.fill"
        case .finishing: "arrow.triangle.2.circlepath"
        case .planning: "hourglass"
        }
    }

    private var statusTint: Color {
        switch task.status {
        case .done: .green
        case .failed: .red
        case .boosting: .orange
        case .finishing: .yellow
        case .planning: .secondary
        }
    }

    private var statusText: String {
        switch task.status {
        case .planning: "Planning…"
        case .boosting: "Boosting"
        case .finishing: "Rechecking + resuming…"
        case .done: "Done"
        case .failed: "Stopped"
        }
    }
}

private struct DownloadRow: View {
    let download: DirectDownload

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: statusIcon)
                .foregroundStyle(statusTint)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(download.fileName)
                    .lineLimit(1)
                Text(rowStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            rowButton
        }
        .padding(.vertical, 4)
    }

    private var progressText: String {
        "\(Self.sizeText(download.writtenBytes))/\(download.totalBytes > 0 ? Self.sizeText(download.totalBytes) : "…")"
    }

    private static func sizeText(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private var rowStatusText: String {
        var parts = [progressText]
        if download.status == .running {
            parts.append(DesignSystem.Format.speed(Int64(download.liveSpeedBps)))
        }
        switch download.status {
        case .failed: parts.append(download.errorMessage)
        default:
            if !download.phase.isEmpty { parts.append(download.phase) }
        }
        return parts.joined(separator: "  ·  ")
    }

    private var statusIcon: String {
        switch download.status {
        case .done: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .running, .probing: "arrow.down.circle"
        case .paused: "pause.circle"
        case .idle: "circle"
        }
    }

    private var statusTint: Color {
        switch download.status {
        case .done: .green
        case .failed: .red
        case .paused: .white
        default: .orange
        }
    }

    @ViewBuilder
    private var rowButton: some View {
        switch download.status {
        case .running, .probing, .idle:
            Button {
                download.pause()
            } label: {
                Image(systemName: "pause")
            }
            .buttonStyle(.plain)
            .help("Pause")
        case .done, .failed:
            Button {
                download.start()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Restart")
        case .paused:
            Button {
                download.start()
            } label: {
                Image(systemName: "play")
            }
            .buttonStyle(.plain)
            .help("Resume")
        }
    }
}
