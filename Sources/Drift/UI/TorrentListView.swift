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
        // Selection clicks trigger a SwiftUI re-render of the table whose
        // implicit animation eased every row/cell from its un-padded
        // mid-render geometry to the final one — a visible ~5pt/10pt shift
        // for a few hundred ms after every click. Table updates never need
        // animation, so strip it from the whole update transaction.
        .transaction { $0.animation = nil }
        // SwiftUI draws its own alternating background at the default 24pt row
        // metric behind the AppKit table; the probe stripes the real 34pt rows,
        // but SwiftUI's pattern used to leak into the empty area below the last
        // row at the wrong pitch. Disable it and let the probe own striping.
        .alternatingRowBackgrounds(.disabled)
        .simultaneousGesture(TapGesture().onEnded {
            model.collapseDetailsFromOutsideClick()
        })
        .background {
            HorizontalScrollRedirector(model: model)
        }
        .onChange(of: model.footerHeight) { _, _ in
            // Track the animated footer per frame so the scroll viewport
            // (and the stripes) retreats with the growing glass panel
            // instead of being caught underneath it.
            HorizontalScrollRedirector.configureNow()
        }
        .overlay {
            if model.filtered.isEmpty {
                Group {
                    if model.isConnected {
                        ContentUnavailableView {
                            Label("No Torrents", systemImage: "tray")
                        } description: {
                            Text(model.searchText.isEmpty
                                 ? "Add a magnet link or .torrent file to get started"
                                 : "No torrents match “\(model.searchText)”")
                        }
                    } else {
                        ContentUnavailableView {
                            Label("Not Connected", systemImage: "bolt.horizontal.circle")
                        } description: {
                            Text(model.connectionState.label)
                        } actions: {
                            Button("Connection Settings…") {
                                model.showConnectionSheet = true
                            }
                        }
                    }
                }
                // Keep the empty state clear of the floating footer. This pads
                // only the overlay — padding the Table itself would shrink the
                // backing scroll view and strand the horizontal scrollbar above
                // the footer instead of letting it ride the window's bottom
                // edge, below the info bar.
                .padding(.bottom, model.footerHeight)
            }
        }
        .alert(
            "Remove Torrent?",
            isPresented: Binding(
                get: { model.pendingRemoval != nil },
                set: { if !$0 { model.cancelRemoval() } }
            )
        ) {
            Button("Remove", role: .destructive) {
                model.confirmRemoval()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(removalMessage)
        }
    }

    private var removalMessage: String {
        guard let ids = model.pendingRemoval else { return "" }
        if ids.count == 1, let id = ids.first,
           let torrent = model.torrents.first(where: { $0.id == id }) {
            return "“\(torrent.name)” will be removed."
        }
        return "\(ids.count) torrents will be removed."
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
        Button {
            model.startTorrents([torrent.id])
        } label: {
            Label("Start", systemImage: "play.fill")
        }
        .disabled(!model.isConnected || torrent.status != .stopped)
        .help("Start")

        Button {
            model.stopTorrents([torrent.id])
        } label: {
            Label("Stop", systemImage: "pause.fill")
        }
        .disabled(!model.isConnected || torrent.status == .stopped)
        .help("Stop")

        Button {
            model.requestRemoval([torrent.id])
        } label: {
            Label("Remove", systemImage: "trash")
        }
        .disabled(!model.isConnected)
        .help("Remove")

        Divider()

        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(torrent.name, forType: .string)
        } label: {
            Label("Copy Name", systemImage: "doc.on.doc")
        }
    }
}
