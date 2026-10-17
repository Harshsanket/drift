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

            TableColumn("Category", value: \TorrentSummary.category) { torrent in
                Text(torrent.category ?? "—")
                    .tableCell(.leading, model, torrent)
            }
            .width(100)
            .customizationID("category")

            TableColumn("Tags") { torrent in
                Text(torrent.tags.isEmpty ? "—" : torrent.tags.joined(separator: ", "))
                    .tableCell(.leading, model, torrent)
            }
            .width(100)
            .customizationID("tags")

            TableColumn("Ratio", value: \TorrentSummary.ratio) { torrent in
                Text(String(format: "%.2f", torrent.ratio))
                    .monospacedDigit()
                    .tableCell(.trailing, model, torrent)
            }
            .width(70)
            .customizationID("ratio")

            TableColumn("Added", value: \TorrentSummary.addedOn) { torrent in
                Text(torrent.addedOn > 0
                    ? Date(timeIntervalSince1970: torrent.addedOn).formatted(.abbreviatedDate)
                    : "—")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .tableCell(.trailing, model, torrent)
            }
            .width(110)
            .customizationID("addedOn")

            TableColumn("Seeds", value: \TorrentSummary.seeds) { torrent in
                Text("\(torrent.seeds)")
                    .monospacedDigit()
                    .foregroundStyle(torrent.seeds > 0 ? DesignSystem.Palette.seeding : .secondary)
                    .tableCell(.trailing, model, torrent)
            }
            .width(60)
            .customizationID("seeds")

            TableColumn("Peers", value: \TorrentSummary.peers) { torrent in
                Text("\(torrent.peers)")
                    .monospacedDigit()
                    .tableCell(.trailing, model, torrent)
            }
            .width(60)
            .customizationID("peers")

            TableColumn("Avail.", value: \TorrentSummary.availability) { torrent in
                Text(torrent.progress >= 1 ? "∞" : String(format: "%.2f", torrent.availability))
                    .monospacedDigit()
                    .tableCell(.trailing, model, torrent)
            }
            .width(70)
            .customizationID("availability")

            TableColumn("Downloaded", value: \TorrentSummary.downloaded) { torrent in
                Text(DesignSystem.Format.size(torrent.downloaded))
                    .monospacedDigit()
                    .tableCell(.trailing, model, torrent)
            }
            .width(100)
            .customizationID("downloaded")

            TableColumn("Uploaded", value: \TorrentSummary.uploaded) { torrent in
                Text(DesignSystem.Format.size(torrent.uploaded))
                    .monospacedDigit()
                    .tableCell(.trailing, model, torrent)
            }
            .width(100)
            .customizationID("uploaded")

            TableColumn("Save Path", value: \TorrentSummary.savePath) { torrent in
                Text(torrent.savePath.isEmpty ? "—" : torrent.savePath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .tableCell(.leading, model, torrent)
            }
            .width(140)
            .customizationID("savePath")
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
        .alert(
            dialogTitle,
            isPresented: Binding(
                get: { model.activeDialog != nil },
                set: { if !$0 { model.cancelDialog() } }
            )
        ) {
            switch model.activeDialog {
            case .createCategory, .editCategory:
                TextField("Category", text: $model.pendingText)
                TextField("Save path (optional)", text: $model.pendingText2)
            default:
                TextField(dialogPrompt, text: $model.pendingText)
            }
            Button("OK") {
                model.confirmDialog()
            }
            Button("Cancel", role: .cancel) {
                model.cancelDialog()
            }
        }
    }

    private var dialogTitle: String {
        switch model.activeDialog {
        case .rename: "Rename Torrent"
        case .setLocation: "Set Save Location"
        case .createCategory: "New Category"
        case .editCategory(let name): "Edit Category — \(name)"
        case .newTag: "New Tag"
        case .addTracker, .addWebSeed: "Add Tracker"
        case .editTracker, .editWebSeed: "Edit Tracker"
        case nil: ""
        }
    }

    private var dialogPrompt: String {
        switch model.activeDialog {
        case .rename: "Name"
        case .setLocation: "Location"
        case .createCategory: "Category"
        case .editCategory: "Save path (optional)"
        case .newTag: "Tag"
        case .addTracker, .addWebSeed: "URLs (separate multiple by spaces or lines)"
        case .editTracker, .editWebSeed: "URL"
        case nil: ""
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

    /// qBittorrent semantics: right-clicking a row that is part of the
    /// selection acts on the whole selection; otherwise on that row only.
    private var targets: [String] {
        model.selectedIDs.contains(torrent.id)
            ? Array(model.selectedIDs)
            : [torrent.id]
    }

    var body: some View {
        Button {
            model.startTorrents(targets)
        } label: {
            Label("Resume", systemImage: "play.fill")
        }
        .disabled(actionUnavailable(torrent.status != .stopped))

        Button {
            model.forceStartTorrents(targets)
        } label: {
            Label("Force Resume", systemImage: "play.circle.fill")
        }
        .disabled(actionUnavailable(torrent.status == .seeding))

        Button {
            model.stopTorrents(targets)
        } label: {
            Label("Stop", systemImage: "pause.fill")
        }
        .disabled(actionUnavailable(torrent.status == .stopped))

        Button {
            model.requestRemoval(targets)
        } label: {
            Label("Remove…", systemImage: "trash")
        }
        .disabled(!model.isConnected)

        Divider()

        Button {
            model.recheckTorrents(targets)
        } label: {
            Label("Recheck", systemImage: "arrow.triangle.2.circlepath")
        }
        .disabled(actionUnavailable(false))

        Button {
            if model.selectedIDs.contains(torrent.id) {
                model.requestSetLocation(targets)
            } else {
                model.requestSetLocation([torrent.id])
            }
        } label: {
            Label("Location…", systemImage: "folder")
        }
        .disabled(!model.isConnected)

        Button {
            model.requestRename(torrent.id)
        } label: {
            Label("Rename…", systemImage: "pencil")
        }
        .disabled(!model.isConnected)

        Button {
            let expanded = NSString(string: torrent.savePath).expandingTildeInPath
            guard FileManager.default.isReadableFile(atPath: expanded) else {
                writeProbeLog("[ui] open destination skipped (unreadable) \(expanded)")
                return
            }
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: expanded)
        } label: {
            Label("Open Destination Folder", systemImage: "arrow.up.right.folder")
        }
        .disabled(torrent.savePath.isEmpty)

        Menu {
            Button {
                model.queueTorrents(targets, move: .top)
            } label: {
                Label("Top", systemImage: "arrow.up.to.line")
            }
            .disabled(actionUnavailable(false))
            Button {
                model.queueTorrents(targets, move: .up)
            } label: {
                Label("Up", systemImage: "arrow.up")
            }
            .disabled(actionUnavailable(false))
            Button {
                model.queueTorrents(targets, move: .down)
            } label: {
                Label("Down", systemImage: "arrow.down")
            }
            .disabled(actionUnavailable(false))
            Button {
                model.queueTorrents(targets, move: .bottom)
            } label: {
                Label("Bottom", systemImage: "arrow.down.to.line")
            }
            .disabled(actionUnavailable(false))
        } label: {
            Label("Queue", systemImage: "list.number")
        }

        Divider()

        Toggle(isOn: Binding(
            get: { torrent.sequential },
            set: { _ in model.toggleSequentialDownload(targets) }
        )) {
            Label("Sequential Download", systemImage: "arrow.down.number")
        }

        Toggle(isOn: Binding(
            get: { torrent.firstLastPiecePriority },
            set: { _ in model.toggleFirstLastPiecePriority(targets) }
        )) {
            Label("First & Last Piece Priority", systemImage: "rectangle.split.2x1")
        }

        Toggle(isOn: Binding(
            get: { torrent.superSeeding },
            set: { model.setSuperSeeding(targets, enabled: $0) }
        )) {
            Label("Super Seeding", systemImage: "arrow.up.circle")
        }

        Divider()

        Toggle(isOn: Binding(
            get: { torrent.autoManaged },
            set: { model.setTorrentAutoManagement(targets, enabled: $0) }
        )) {
            Label("Automatic Torrent Management", systemImage: "automatic")
        }

        Divider()

        Menu {
            if model.categories.isEmpty {
                Text("No categories")
            }
            ForEach(model.categories) { category in
                Button {
                    model.setTorrentCategory(targets, category: category.name)
                } label: {
                    if torrent.category == category.name {
                        Label("\(category.name)", systemImage: "checkmark")
                    } else {
                        Text(category.name)
                    }
                }
            }
            Divider()
            Button(role: .destructive) {
                model.setTorrentCategory(targets, category: nil)
            } label: {
                Label("Uncategorized", systemImage: "minus.circle")
            }
            if torrent.category != nil {
                Button {
                    model.setTorrentCategory(targets, category: nil)
                } label: {
                    Label("Clear", systemImage: "xmark.circle")
                }
            }
            Divider()
            Button {
                model.createOrganizer(dialog: .createCategory)
            } label: {
                Label("New Category…", systemImage: "plus")
            }
            .disabled(!model.isConnected)
        } label: {
            Label(torrent.category ?? "Category", systemImage: "folder.badge.gearshape")
        }
        .disabled(!model.isConnected)

        Menu {
            if model.tags.isEmpty {
                Text("No tags")
            }
            ForEach(model.tags, id: \.self) { tag in
                Button {
                    model.assignTag(targets, tag: tag)
                } label: {
                    if torrent.tags.contains(tag) {
                        Label("\(tag)", systemImage: "checkmark")
                    } else {
                        Text(tag)
                    }
                }
            }
            Divider()
            Button {
                model.createOrganizer(dialog: .newTag)
            } label: {
                Label("New Tag…", systemImage: "plus")
            }
            .disabled(!model.isConnected)
        } label: {
            Label(torrent.tags.isEmpty ? "Tags" : torrent.tags.joined(separator: ", "), systemImage: "tag")
        }

        Divider()

        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(torrent.name, forType: .string)
        } label: {
            Label("Copy Name", systemImage: "doc.on.doc")
        }
    }

    private func actionUnavailable(_ specialCase: Bool) -> Bool {
        specialCase || !model.isConnected
    }
}
