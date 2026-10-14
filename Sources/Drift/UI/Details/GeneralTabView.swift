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
                    row("Time active") {
                        Text(DesignSystem.Format.duration(torrent.timeActive))
                            .monospacedDigit()
                    }
                    if !general.comment.isEmpty {
                        row("Comment") {
                            value(general.comment)
                        }
                    }
                }

                piecesSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 190)
    }

    private var piecesSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            HStack {
                Text("Pieces")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(general.piecesHave) / \(general.piecesTotal)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.callout)

            Canvas { context, size in
                context.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .color(.primary.opacity(0.08))
                )
                let haveWidth = size.width * CGFloat(general.piecesHave)
                    / CGFloat(max(general.piecesTotal, 1))
                if haveWidth > 0 {
                    context.fill(
                        Path(CGRect(x: 0, y: 0, width: haveWidth, height: size.height)),
                        with: .color(DesignSystem.Palette.accent)
                    )
                }
            }
            .frame(height: 8)
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.sm))
            .overlay {
                RoundedRectangle(cornerRadius: DesignSystem.Radius.sm)
                    .strokeBorder(.quaternary, lineWidth: 1)
            }
        }
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
