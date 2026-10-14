import SwiftUI
import AppKit

struct TorrentListView: View {
    @Bindable var model: ListViewModel

    var body: some View {
        Table(
            model.filtered,
            selection: $model.selectedIDs,
            sortOrder: $model.sortOrder,
            columnCustomization: $model.columnCustomization
        ) {
            TableColumn("Name", value: \TorrentSummary.name) { torrent in
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Image(systemName: torrent.status.systemImage)
                        .foregroundStyle(torrent.status.tint)
                    Text(torrent.name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .tableCell(.leading, model, torrent)
            }
            .width(min: 220, ideal: 320)

            TableColumn("Status", value: \TorrentSummary.status) { torrent in
                Text(torrent.status.label)
                    .foregroundStyle(torrent.status.tint)
                    .tableCell(.leading, model, torrent)
            }
            .width(110)
            .customizationID("status")

            TableColumn("Progress", value: \TorrentSummary.progress) { torrent in
                HStack(spacing: DesignSystem.Spacing.sm) {
                    ProgressView(value: torrent.progress)
                        .progressViewStyle(.linear)
                        .tint(torrent.status.tint)
                    Text(DesignSystem.Format.percent(torrent.progress))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                .tableCell(.leading, model, torrent)
            }
            .width(150)
            .customizationID("progress")

            TableColumn("Size", value: \TorrentSummary.size) { torrent in
                Text(DesignSystem.Format.size(torrent.size))
                    .monospacedDigit()
                    .tableCell(.trailing, model, torrent)
            }
            .width(84)
            .customizationID("size")

            TableColumn("DL", value: \TorrentSummary.downloadSpeed) { torrent in
                Text(DesignSystem.Format.speed(torrent.downloadSpeed))
                    .monospacedDigit()
                    .foregroundStyle(torrent.downloadSpeed > 0 ? DesignSystem.Palette.downloading : .secondary)
                    .tableCell(.trailing, model, torrent)
            }
            .width(80)
            .customizationID("downloadSpeed")

            TableColumn("UP", value: \TorrentSummary.uploadSpeed) { torrent in
                Text(DesignSystem.Format.speed(torrent.uploadSpeed))
                    .monospacedDigit()
                    .foregroundStyle(torrent.uploadSpeed > 0 ? DesignSystem.Palette.seeding : .secondary)
                    .tableCell(.trailing, model, torrent)
            }
            .width(80)
            .customizationID("uploadSpeed")

            TableColumn("ETA", value: \TorrentSummary.etaSortKey) { torrent in
                Text(DesignSystem.Format.eta(torrent.eta))
                    .monospacedDigit()
                    .tableCell(.trailing, model, torrent)
            }
            .width(80)
            .customizationID("eta")

            TableColumn("Time", value: \TorrentSummary.timeActive) { torrent in
                Text(DesignSystem.Format.duration(torrent.timeActive))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .tableCell(.trailing, model, torrent)
            }
            .width(80)
            .customizationID("timeActive")
        }
        .tableStyle(.inset)
        .alternatingRowBackgrounds(.enabled)
        .simultaneousGesture(TapGesture().onEnded {
            model.collapseDetailsFromOutsideClick()
        })
        .background {
            HorizontalScrollRedirector(model: model)
        }
        .overlay {
            if model.filtered.isEmpty {
                ContentUnavailableView {
                    Label("No Torrents", systemImage: "tray")
                } description: {
                    Text(model.searchText.isEmpty
                         ? "Add a magnet link or .torrent file to get started"
                         : "No torrents match “\(model.searchText)”")
                }
            }
        }
    }
}

private extension View {
    /// Fixed 34pt table cell: 7 + 20 + 7, 10pt side insets, context menu.
    func tableCell(_ alignment: Alignment = .leading,
                   _ model: ListViewModel,
                   _ torrent: TorrentSummary) -> some View {
        self
            .padding(.horizontal, DesignSystem.Metrics.tableCellHPad)
            .frame(maxWidth: .infinity, alignment: alignment)
            .frame(height: DesignSystem.Metrics.tableCellHeight)
            .padding(.vertical, DesignSystem.Metrics.tableCellVPad)
            .contextMenu {
                TorrentRowMenu(model: model, torrent: torrent)
            }
    }
}

private struct TorrentRowMenu: View {
    let model: ListViewModel
    let torrent: TorrentSummary

    var body: some View {
        Button(action: {}) {
            Label("Start", systemImage: "play.fill")
        }
        .disabled(true)
        .help("Start — wired in Phase 5")

        Button(action: {}) {
            Label("Stop", systemImage: "pause.fill")
        }
        .disabled(true)
        .help("Stop — wired in Phase 5")

        Button(action: {}) {
            Label("Remove", systemImage: "trash")
        }
        .disabled(true)
        .help("Remove — wired in Phase 8")

        Divider()

        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(torrent.name, forType: .string)
        } label: {
            Label("Copy Name", systemImage: "doc.on.doc")
        }
    }
}
