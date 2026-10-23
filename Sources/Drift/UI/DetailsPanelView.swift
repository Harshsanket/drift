import AppKit
import SwiftUI

struct DetailsPanelView: View {
    @Bindable var model: ListViewModel
    @Bindable private var downloads = DownloadCenter.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Text(model.selectedTorrent?.name ?? "No selection")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(model.selectedTorrent == nil ? .tertiary : .primary)

                if model.selectedIDs.count > 1 {
                    Text("· \(model.selectedIDs.count) selected")
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: DesignSystem.Spacing.xs) {
                    actionButton(
                        "Boost",
                        systemImage: "bolt.horizontal.fill",
                        help: boostHelp,
                        disabled: !canBoost
                    ) {
                        boost()
                    }
                    actionButton(
                        "Remove",
                        systemImage: "trash",
                        help: "Remove Torrent…",
                        disabled: !canModify
                    ) {
                        requestRemoval(deleteFiles: false)
                    }
                    actionButton(
                        "Delete Files",
                        systemImage: "trash.slash",
                        help: "Remove Torrent and Delete Files…",
                        disabled: !canModify
                    ) {
                        requestRemoval(deleteFiles: true)
                    }
                    actionButton(
                        "Finder",
                        systemImage: "folder",
                        help: "Open in Finder",
                        disabled: model.selectedTorrent?.savePath.isEmpty ?? true
                    ) {
                        openInFinder()
                    }
                }
            }
            .padding(.bottom, DesignSystem.Spacing.sm)

            HStack(spacing: DesignSystem.Spacing.sm) {
                ForEach(DetailTab.allCases) { tab in
                    pill(tab)
                }
                Spacer()
            }
            .padding(.bottom, DesignSystem.Spacing.sm)

            content
        }
        .padding(.horizontal, DesignSystem.Spacing.lg)
        .padding(.top, DesignSystem.Spacing.md)
        .padding(.bottom, DesignSystem.Spacing.sm)
    }

    private func pill(_ tab: DetailTab) -> some View {
        let active = model.selectedTab == tab
        let enabled = model.selectedDetails != nil

        return Button {
            model.selectedTab = tab
        } label: {
            Text(tab.label)
                .font(.callout)
                .padding(.horizontal, DesignSystem.Spacing.md)
                .padding(.vertical, DesignSystem.Spacing.xs)
                .background {
                    if active {
                        Capsule(style: .continuous)
                            .fill(Color.accentColor.opacity(0.16))
                    } else {
                        Capsule(style: .continuous)
                            .fill(.quaternary)
                    }
                }
                .foregroundStyle(
                    active ? AnyShapeStyle(DesignSystem.Palette.accent) : AnyShapeStyle(.secondary)
                )
                .modifier(ActiveGlass(active: active))
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .help(tab.label)
        .accessibilityLabel(tab.label)
    }

    private var canModify: Bool {
        model.selectedTorrent != nil && model.isConnected
    }

    private var boostTask: TorrentBoostTask? {
        guard let id = model.selectedTorrent?.id else { return nil }
        return downloads.boosts.first {
            $0.hash == id && $0.status != .failed && $0.status != .done
        }
    }

    private var canBoost: Bool {
        guard let torrent = model.selectedTorrent,
              BoosterSettings.shared.enabled,
              model.isConnected,
              boostTask == nil
        else { return false }
        return downloads.eligibility(for: torrent.id)?.boostable ?? false
    }

    private var boostHelp: String {
        if !BoosterSettings.shared.enabled {
            return "Connection Booster is off in Settings"
        }
        guard let torrent = model.selectedTorrent else {
            return "Select a torrent to boost"
        }
        if !model.isConnected { return "Not connected" }
        if boostTask != nil { return "Boosting…" }
        guard let info = downloads.eligibility(for: torrent.id), info.boostable else {
            return "Boost with Connection Booster (needs HTTP web seeds)"
        }
        return "Boost with Connection Booster (\(info.webSeedCount) web seeds)"
    }

    private func actionButton(
        _ title: String,
        systemImage: String,
        help: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 11, weight: .medium))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(disabled)
        .help(help)
        .accessibilityLabel(help)
    }

    private func boost() {
        guard let torrent = model.selectedTorrent else { return }
        _ = downloads.startBoost(
            id: torrent.id,
            name: torrent.name,
            savePath: NSString(string: torrent.savePath).expandingTildeInPath
        )
        WindowOpener.openDownloads?()
    }

    private func requestRemoval(deleteFiles: Bool) {
        guard let torrent = model.selectedTorrent else { return }
        let targets = model.selectedIDs.contains(torrent.id)
            ? Array(model.selectedIDs)
            : [torrent.id]
        model.requestRemoval(targets, deleteFiles: deleteFiles)
    }

    private func openInFinder() {
        guard let torrent = model.selectedTorrent else { return }
        let expanded = NSString(string: torrent.savePath).expandingTildeInPath
        guard FileManager.default.isReadableFile(atPath: expanded) else {
            writeProbeLog("[ui] open destination skipped (unreadable) \(expanded)")
            return
        }
        if downloads.openDestinationFolder(expanded) {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: expanded)
        }
    }

    @ViewBuilder
    private var content: some View {
        Group {
            if let details = model.selectedDetails {
                tabContent(details)
            } else {
                DetailsEmptyState(title: "No torrent selected", systemImage: "cursor.arrow")
            }
        }
        .frame(height: 190)
    }

    @ViewBuilder
    private func tabContent(_ details: TorrentDetails) -> some View {
        switch model.selectedTab {
        case .general:
            if let torrent = model.selectedTorrent {
                GeneralTabView(torrent: torrent, general: details.general)
            } else {
                DetailsEmptyState(title: "No torrent selected", systemImage: "cursor.arrow")
            }
        case .trackers:
            TrackersTabView(model: model, torrentID: model.selectedIDs.first ?? "", rows: details.trackers)
        case .peers:
            PeersTabView(rows: details.peers) { rows in
                model.banPeers(rows)
            }
        case .sources:
            SourcesTabView(model: model, torrentID: model.selectedIDs.first ?? "", rows: details.webSeeds)
        case .files:
            FilesTabView(rows: details.files) { row, priority in
                model.setFilePriority(file: row, priority: priority)
            }
        }
    }
}

private struct ActiveGlass: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            content.glassEffect(.regular, in: Capsule(style: .continuous))
        } else {
            content
        }
    }
}
