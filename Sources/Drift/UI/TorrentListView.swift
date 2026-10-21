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
            baseColumns(model)

            midColumns(model)
            tailColumns(model)
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
        // Keyboard parity with qB: space toggles stop/resume for the
        // selection, delete removes it. Hidden buttons keep the shortcuts
        // available from the window's key state without visual noise.
        .background {
            VStack(spacing: 0) {
                Button("Toggle Selected") { model.toggleSelectedPlayback() }
                    .keyboardShortcut(.space, modifiers: [])
                Button("Remove Selected") {
                    model.requestRemoval(Array(model.selectedIDs))
                }
                .keyboardShortcut(.delete, modifiers: [])
            }
            .frame(width: 0, height: 0)
            .opacity(0)
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

@TableColumnBuilder<TorrentSummary, KeyPathComparator<TorrentSummary>>
@MainActor private func midColumns(_ model: ListViewModel)
    -> some TableColumnContent<TorrentSummary, KeyPathComparator<TorrentSummary>> {
    timeColumn(model)
    categoryColumn(model)
    tagsColumn(model)
    ratioColumn(model)
    addedColumn(model)
    seedsColumn(model)
}

@TableColumnBuilder<TorrentSummary, KeyPathComparator<TorrentSummary>>
@MainActor private func tailColumns(_ model: ListViewModel)
    -> some TableColumnContent<TorrentSummary, KeyPathComparator<TorrentSummary>> {
    peersColumn(model)
    availabilityColumn(model)
    downloadedColumn(model)
    uploadedColumn(model)
    savePathColumn(model)
}

// Extraction keeps the Table's column closure small enough to type-check.
@TableColumnBuilder<TorrentSummary, KeyPathComparator<TorrentSummary>>
@MainActor private func baseColumns(_ model: ListViewModel)
    -> some TableColumnContent<TorrentSummary, KeyPathComparator<TorrentSummary>> {
    TableColumn("Name", sortUsing: KeyPathComparator(\TorrentSummary.name)) { torrent in
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

    TableColumn("Status", sortUsing: KeyPathComparator(\TorrentSummary.status)) { torrent in
        Text(torrent.status.label)
            .foregroundStyle(torrent.status.tint)
            .tableCell(.leading, model, torrent)
    }
    .width(110)
    .customizationID("status")

    TableColumn("Progress", sortUsing: KeyPathComparator(\TorrentSummary.progress)) { torrent in
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

    TableColumn("Size", sortUsing: KeyPathComparator(\TorrentSummary.size)) { torrent in
        Text(DesignSystem.Format.size(torrent.size))
            .monospacedDigit()
            .tableCell(.trailing, model, torrent)
    }
    .width(84)
    .customizationID("size")

    TableColumn("DL", sortUsing: KeyPathComparator(\TorrentSummary.downloadSpeed)) { torrent in
        Text(DesignSystem.Format.speed(torrent.downloadSpeed))
            .monospacedDigit()
            .foregroundStyle(torrent.downloadSpeed > 0 ? DesignSystem.Palette.downloading : .secondary)
            .tableCell(.trailing, model, torrent)
    }
    .width(80)
    .customizationID("downloadSpeed")

    TableColumn("UP", sortUsing: KeyPathComparator(\TorrentSummary.uploadSpeed)) { torrent in
        Text(DesignSystem.Format.speed(torrent.uploadSpeed))
            .monospacedDigit()
            .foregroundStyle(torrent.uploadSpeed > 0 ? DesignSystem.Palette.seeding : .secondary)
            .tableCell(.trailing, model, torrent)
    }
    .width(80)
    .customizationID("uploadSpeed")

    TableColumn("ETA", sortUsing: KeyPathComparator(\TorrentSummary.etaSortKey)) { torrent in
        Text(DesignSystem.Format.eta(torrent.eta))
            .monospacedDigit()
            .tableCell(.trailing, model, torrent)
    }
    .width(80)
    .customizationID("eta")
}

// Extraction keeps the Table's column closure small enough to type-check.
// Secondary columns share one concrete cell view so the helper functions can
// name TableColumn's four generics directly.
private struct TorrentCellView: View {
    let torrent: TorrentSummary
    let model: ListViewModel
    let alignment: HorizontalAlignment
    let text: Text
    var truncates = false
    var tint: Color?

    var body: some View {
        text
            .monospacedDigit()
            .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.primary))
            .lineLimit(1)
            .truncationMode(truncates ? .middle : .tail)
            .padding(.horizontal, DesignSystem.Metrics.tableCellHPad)
            .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
            .frame(height: DesignSystem.Metrics.tableCellHeight)
            .padding(.vertical, DesignSystem.Metrics.tableCellVPad)
            .contextMenu {
                TorrentRowMenu(model: model, torrent: torrent)
            }
    }
}

@MainActor private func timeColumn(_ model: ListViewModel)
    -> some TableColumnContent<TorrentSummary, KeyPathComparator<TorrentSummary>> {
    TableColumn(
        "Time",
        sortUsing: KeyPathComparator(\TorrentSummary.timeActive)
    ) { torrent in
        TorrentCellView(
            torrent: torrent, model: model, alignment: .trailing,
            text: Text(DesignSystem.Format.duration(torrent.timeActive)),
            tint: .secondary
        )
    }
    .width(80)
    .customizationID("timeActive")
}

@MainActor private func categoryColumn(_ model: ListViewModel)
    -> some TableColumnContent<TorrentSummary, KeyPathComparator<TorrentSummary>> {
    TableColumn(
        "Category",
        sortUsing: KeyPathComparator(\TorrentSummary.categorySortKey)
    ) { torrent in
        TorrentCellView(
            torrent: torrent, model: model, alignment: .leading,
            text: Text(torrent.category ?? "—")
        )
    }
    .width(100)
    .customizationID("category")
}

@MainActor private func tagsColumn(_ model: ListViewModel)
    -> some TableColumnContent<TorrentSummary, KeyPathComparator<TorrentSummary>> {
    TableColumn(
        "Tags",
        sortUsing: KeyPathComparator(\TorrentSummary.tagsSortKey)
    ) { torrent in
        TorrentCellView(
            torrent: torrent, model: model, alignment: .leading,
            text: Text(torrent.tags.isEmpty ? "—" : torrent.tags.joined(separator: ", "))
        )
    }
    .width(100)
    .customizationID("tags")
}

@MainActor private func ratioColumn(_ model: ListViewModel)
    -> some TableColumnContent<TorrentSummary, KeyPathComparator<TorrentSummary>> {
    TableColumn(
        "Ratio",
        sortUsing: KeyPathComparator(\TorrentSummary.ratio)
    ) { torrent in
        TorrentCellView(
            torrent: torrent, model: model, alignment: .trailing,
            text: Text(String(format: "%.2f", torrent.ratio))
        )
    }
    .width(70)
    .customizationID("ratio")
}

@MainActor private func addedColumn(_ model: ListViewModel)
    -> some TableColumnContent<TorrentSummary, KeyPathComparator<TorrentSummary>> {
    TableColumn(
        "Added",
        sortUsing: KeyPathComparator(\TorrentSummary.addedOn)
    ) { torrent in
        TorrentCellView(
            torrent: torrent, model: model, alignment: .trailing,
            text: Text(addedDisplay(torrent)),
            tint: .secondary
        )
    }
    .width(110)
    .customizationID("addedOn")
}

@MainActor private func addedDisplay(_ torrent: TorrentSummary) -> String {
    guard torrent.addedOn > 0 else { return "—" }
    return Date(timeIntervalSince1970: torrent.addedOn).formatted(
        date: .abbreviated, time: .omitted
    )
}

@MainActor private func seedsColumn(_ model: ListViewModel)
    -> some TableColumnContent<TorrentSummary, KeyPathComparator<TorrentSummary>> {
    TableColumn(
        "Seeds",
        sortUsing: KeyPathComparator(\TorrentSummary.seeds)
    ) { torrent in
        TorrentCellView(
            torrent: torrent, model: model, alignment: .trailing,
            text: Text("\(torrent.seeds)"),
            tint: torrent.seeds > 0 ? DesignSystem.Palette.seeding : .secondary
        )
    }
    .width(60)
    .customizationID("seeds")
}

@MainActor private func peersColumn(_ model: ListViewModel)
    -> some TableColumnContent<TorrentSummary, KeyPathComparator<TorrentSummary>> {
    TableColumn(
        "Peers",
        sortUsing: KeyPathComparator(\TorrentSummary.peers)
    ) { torrent in
        TorrentCellView(
            torrent: torrent, model: model, alignment: .trailing,
            text: Text("\(torrent.peers)")
        )
    }
    .width(60)
    .customizationID("peers")
}

@MainActor private func availabilityColumn(_ model: ListViewModel)
    -> some TableColumnContent<TorrentSummary, KeyPathComparator<TorrentSummary>> {
    TableColumn(
        "Avail.",
        sortUsing: KeyPathComparator(\TorrentSummary.availability)
    ) { torrent in
        TorrentCellView(
            torrent: torrent, model: model, alignment: .trailing,
            text: Text(torrent.progress >= 1 ? "∞" : String(format: "%.2f", torrent.availability))
        )
    }
    .width(70)
    .customizationID("availability")
}

@MainActor private func downloadedColumn(_ model: ListViewModel)
    -> some TableColumnContent<TorrentSummary, KeyPathComparator<TorrentSummary>> {
    TableColumn(
        "Downloaded",
        sortUsing: KeyPathComparator(\TorrentSummary.downloaded)
    ) { torrent in
        TorrentCellView(
            torrent: torrent, model: model, alignment: .trailing,
            text: Text(DesignSystem.Format.size(torrent.downloaded))
        )
    }
    .width(100)
    .customizationID("downloaded")
}

@MainActor private func uploadedColumn(_ model: ListViewModel)
    -> some TableColumnContent<TorrentSummary, KeyPathComparator<TorrentSummary>> {
    TableColumn(
        "Uploaded",
        sortUsing: KeyPathComparator(\TorrentSummary.uploaded)
    ) { torrent in
        TorrentCellView(
            torrent: torrent, model: model, alignment: .trailing,
            text: Text(DesignSystem.Format.size(torrent.uploaded))
        )
    }
    .width(100)
    .customizationID("uploaded")
}

@MainActor private func savePathColumn(_ model: ListViewModel)
    -> some TableColumnContent<TorrentSummary, KeyPathComparator<TorrentSummary>> {
    TableColumn(
        "Save Path",
        sortUsing: KeyPathComparator(\TorrentSummary.savePath)
    ) { torrent in
        TorrentCellView(
            torrent: torrent, model: model, alignment: .leading,
            text: Text(torrent.savePath.isEmpty ? "—" : torrent.savePath),
            truncates: true
        )
    }
    .width(140)
    .customizationID("savePath")
}

/// Boost section of the torrent row context menu. Shows eligibility
/// (qB-reported HTTP web seeds) and hands off to the Connection Booster.
private struct TorrentBoostMenu: View {
    let model: ListViewModel
    let torrent: TorrentSummary

    private var eligibility: BoostEligibility? {
        DownloadCenter.shared.eligibility(for: torrent.id)
    }

    private var menuLabel: String {
        if !BoosterSettings.shared.enabled { return "Boost with Connection Booster (off in settings)" }
        if !model.isConnected { return "Boost with Connection Booster (no connection)" }
        let status = DownloadCenter.shared.boosts
            .first { $0.hash == torrent.id && $0.status != .failed && $0.status != .done }?
            .status
        if status != nil { return "Boosting…" }
        switch eligibility {
        case .some(let info) where info.boostable:
            return "Boost with Connection Booster (\(info.webSeedCount) web seeds)"
        default:
            return "Boost with Connection Booster (not boostable)"
        }
    }

    var body: some View {
        Button {
            let task = DownloadCenter.shared.startBoost(
                id: torrent.id,
                name: torrent.name,
                savePath: NSString(string: torrent.savePath).expandingTildeInPath
            )
            WindowOpener.openDownloads?()
            _ = task
        } label: {
            Label(menuLabel, systemImage: "bolt.horizontal")
        }
        .disabled(
            !model.isConnected
                || !BoosterSettings.shared.enabled
                || !(eligibility?.boostable ?? false)
        )
        if let info = eligibility, info.boostable {
            Text(info.seeds.prefix(2).joined(separator: "\n"))
                .font(.caption)
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
            let root = DownloadCenter.shared.openDestinationFolder(expanded)
            if root { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: expanded) }
        } label: {
            Label("Open Destination Folder", systemImage: "arrow.up.right.folder")
        }
        .disabled(torrent.savePath.isEmpty)

        Divider()

        TorrentBoostMenu(model: model, torrent: torrent)

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
