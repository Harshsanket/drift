import SwiftUI

struct TorrentListView: View {
    @Bindable var model: ListViewModel

    var body: some View {
        Table(model.filtered, selection: $model.selectedIDs) {
            TableColumn("Name") { torrent in
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Image(systemName: torrent.status.systemImage)
                        .foregroundStyle(torrent.status.tint)
                    Text(torrent.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .width(min: 240, ideal: 360)

            TableColumn("Status") { torrent in
                Text(torrent.status.label)
                    .foregroundStyle(torrent.status.tint)
            }
            .width(100)

            TableColumn("Progress") { torrent in
                HStack(spacing: DesignSystem.Spacing.sm) {
                    ProgressView(value: torrent.progress)
                        .progressViewStyle(.linear)
                        .tint(torrent.status.tint)
                    Text(DesignSystem.Format.percent(torrent.progress))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .width(min: 140, ideal: 180)

            TableColumn("Size") { torrent in
                Text(DesignSystem.Format.size(torrent.size))
                    .monospacedDigit()
            }
            .width(90)

            TableColumn("DL") { torrent in
                Text(DesignSystem.Format.speed(torrent.downloadSpeed))
                    .monospacedDigit()
                    .foregroundStyle(torrent.downloadSpeed > 0 ? DesignSystem.Palette.downloading : .secondary)
            }
            .width(90)

            TableColumn("UP") { torrent in
                Text(DesignSystem.Format.speed(torrent.uploadSpeed))
                    .monospacedDigit()
                    .foregroundStyle(torrent.uploadSpeed > 0 ? DesignSystem.Palette.seeding : .secondary)
            }
            .width(90)

            TableColumn("ETA") { torrent in
                Text(DesignSystem.Format.eta(torrent.eta))
                    .monospacedDigit()
            }
            .width(80)
        }
        .tableStyle(.inset)
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
