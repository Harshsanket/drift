import SwiftUI
import AppKit

struct TorrentListView: View {
    @Bindable var model: ListViewModel

    var body: some View {
        Table(
            model.filtered,
            sortOrder: $model.sortOrder,
            columnCustomization: $model.columnCustomization
        ) {
            TableColumn("Name", value: \TorrentSummary.name) { torrent in
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Image(systemName: torrent.status.systemImage)
                        .foregroundStyle(torrent.status.tint)
                    Text(torrent.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .torrentCellBehavior(model, torrent, column: 0)
            }
            .width(min: 200, ideal: 300)

            TableColumn("Status", value: \TorrentSummary.status) { torrent in
                Text(torrent.status.label)
                    .foregroundStyle(torrent.status.tint)
                    .torrentCellBehavior(model, torrent, column: 1)
            }
            .width(100)
            .customizationID("status")

            TableColumn("Progress", value: \TorrentSummary.progress) { torrent in
                HStack(spacing: DesignSystem.Spacing.sm) {
                    ProgressView(value: torrent.progress)
                        .progressViewStyle(.linear)
                        .tint(torrent.status.tint)
                    Text(DesignSystem.Format.percent(torrent.progress))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .torrentCellBehavior(model, torrent, column: 2)
            }
            .width(min: 120, ideal: 160)
            .customizationID("progress")

            TableColumn("Size", value: \TorrentSummary.size) { torrent in
                Text(DesignSystem.Format.size(torrent.size))
                    .monospacedDigit()
                    .torrentCellBehavior(model, torrent, column: 3)
            }
            .width(84)
            .customizationID("size")

            TableColumn("DL", value: \TorrentSummary.downloadSpeed) { torrent in
                Text(DesignSystem.Format.speed(torrent.downloadSpeed))
                    .monospacedDigit()
                    .foregroundStyle(torrent.downloadSpeed > 0 ? DesignSystem.Palette.downloading : .secondary)
                    .torrentCellBehavior(model, torrent, column: 4)
            }
            .width(84)
            .customizationID("downloadSpeed")

            TableColumn("UP", value: \TorrentSummary.uploadSpeed) { torrent in
                Text(DesignSystem.Format.speed(torrent.uploadSpeed))
                    .monospacedDigit()
                    .foregroundStyle(torrent.uploadSpeed > 0 ? DesignSystem.Palette.seeding : .secondary)
                    .torrentCellBehavior(model, torrent, column: 5)
            }
            .width(84)
            .customizationID("uploadSpeed")

            TableColumn("ETA", value: \TorrentSummary.etaSortKey) { torrent in
                Text(DesignSystem.Format.eta(torrent.eta))
                    .monospacedDigit()
                    .torrentCellBehavior(model, torrent, column: 6)
            }
            .width(80)
            .customizationID("eta")

            TableColumn("Time", value: \TorrentSummary.timeActive) { torrent in
                Text(DesignSystem.Format.duration(torrent.timeActive))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .torrentCellBehavior(model, torrent, column: 7)
            }
            .width(80)
            .customizationID("timeActive")
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
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
    func torrentCellBehavior(_ model: ListViewModel, _ torrent: TorrentSummary, column index: Int) -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                CellBackdrop(model: model, torrent: torrent, index: index)
            }
            .contextMenu {
                TorrentRowMenu(model: model, torrent: torrent)
            }
            .simultaneousGesture(TapGesture(count: 1).onEnded {
                model.cellClicked(torrent.id)
            })
    }
}

/// One horizontal slice of the row's full-width capsule: zebra tone when
/// unselected, accent when selected. The first and last visible columns round
/// their outer ends, so together the slices read as a single pill row with
/// padding on every side. Gaps between cells are filled exactly by measuring
/// each column's width against its stretched content width.
private struct CellBackdrop: View {
    let model: ListViewModel
    let torrent: TorrentSummary
    let index: Int

    var body: some View {
        GeometryReader { geo in
            let columnWidth = index < model.columnWidths.count
                ? model.columnWidths[index]
                : geo.size.width
            let sideGap = max(0, (columnWidth - geo.size.width) / 2)
            let rowHeight = max(model.tableRowHeight, geo.size.height + 6)
            let verticalGap = max(0, (rowHeight - geo.size.height) / 2)
            let height = max(12, rowHeight - 6)
            let isFirst = index == 0
            let isLast = model.isLastVisibleColumn(index)
            let leadingInset: CGFloat = isFirst ? 2 : 0
            let trailingInset: CGFloat = isLast ? 2 : 0
            let rowIndex = model.filtered.firstIndex(where: { $0.id == torrent.id }) ?? 0
            let selected = model.selectedIDs.contains(torrent.id)
            let radius = height / 2

            UnevenRoundedRectangle(
                cornerRadii: .init(
                    topLeading: radius,
                    bottomLeading: radius,
                    bottomTrailing: isLast ? radius : 0,
                    topTrailing: isLast ? radius : 0
                ),
                style: .continuous
            )
            .fill(selected
                  ? AnyShapeStyle(.selection)
                  : AnyShapeStyle(Color.primary.opacity(rowIndex.isMultiple(of: 2) ? 0.05 : 0.15)))
            .frame(
                width: max(0, columnWidth - leadingInset - trailingInset),
                height: height
            )
            .offset(
                x: -sideGap + leadingInset,
                y: 3 - verticalGap
            )
        }
        .allowsHitTesting(false)
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
