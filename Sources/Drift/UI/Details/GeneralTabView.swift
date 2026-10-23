import SwiftUI

struct GeneralTabView: View {
    let torrent: TorrentSummary
    let general: GeneralInfo

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                Grid(
                    alignment: .leading,
                    horizontalSpacing: DesignSystem.Spacing.lg,
                    verticalSpacing: DesignSystem.Spacing.xs
                ) {
                    row("Status") {
                        Text(torrent.status.label)
                            .foregroundStyle(torrent.status.tint)
                    }
                    row("Size") {
                        Text(DesignSystem.Format.size(torrent.size))
                            .monospacedDigit()
                    }
                    row("Progress") {
                        Text(DesignSystem.Format.percent(torrent.progress))
                            .monospacedDigit()
                    }
                    row("Save path") {
                        value(general.savePath)
                    }
                    row("Hash") {
                        value(general.hash)
                            .monospacedDigit()
                    }
                    row("Added on") {
                        Text(general.addedOn.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let completedOn = general.completedOn {
                        row("Completed on") {
                            Text(completedOn.formatted(date: .abbreviated, time: .shortened))
                        }
                    }
                    row("Downloaded") {
                        Text(DesignSystem.Format.size(general.downloaded))
                            .monospacedDigit()
                    }
                    row("Uploaded") {
                        Text(DesignSystem.Format.size(general.uploaded))
                            .monospacedDigit()
                    }
                    row("Share ratio") {
                        Text(String(format: "%.2f", general.shareRatio))
                            .monospacedDigit()
                    }
                    row("Wasted") {
                        Text(DesignSystem.Format.size(general.wasted))
                            .monospacedDigit()
                    }
                    row("Connections") {
                        Text("\(general.connections)")
                            .monospacedDigit()
                    }
                    row("Time active") {
                        Text(DesignSystem.Format.duration(torrent.timeActive))
                            .monospacedDigit()
                    }
                    if let createdOn = general.createdOn {
                        row("Created on") {
                            Text(createdOn.formatted(date: .abbreviated, time: .shortened))
                        }
                    }
                    if !general.createdBy.isEmpty {
                        row("Created by") {
                            value(general.createdBy)
                        }
                    }
                    if !general.comment.isEmpty {
                        row("Comment") {
                            value(general.comment)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 190)
    }

    private func row(_ label: String, @ViewBuilder value: () -> some View) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            value()
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func value(_ text: String) -> some View {
        Text(text)
    }
}
