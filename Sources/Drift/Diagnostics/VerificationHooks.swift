// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Foundation

/// Arg-gated verification hooks used by packaging/probe runs. Production
/// behaviour is unchanged: each hook runs only when its flag is passed.
@MainActor
enum VerificationHooks {
    private static var didRunShowDetails = false
    private static var didRunPeers = false

    static func runIfNeeded(model: ListViewModel, openWindow: @escaping (String) -> Void) {
        let arguments = ProcessInfo.processInfo.arguments
        showDetails(model: model, arguments: arguments)
        peers(model: model, arguments: arguments)
        windows(model: model, arguments: arguments, openWindow: openWindow)
        selection(model: model, arguments: arguments)
        addAndMutations(model: model, arguments: arguments)
        details(model: model, arguments: arguments)
        runtimeHooks(model: model, arguments: arguments)
    }

    // MARK: - Details / peers

    private static func showDetails(model: ListViewModel, arguments: [String]) {
        // `--test-show-details` is the original probe-gated spelling; keep
        // `--show-details` for existing capture scripts.
        if (arguments.contains("--test-show-details")
            || arguments.contains("--show-details")), !didRunShowDetails {
            didRunShowDetails = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                model.toggleDetails()
            }
        }
    }

    private static func peers(model: ListViewModel, arguments: [String]) {
        guard arguments.contains("--test-peers"), !didRunPeers else { return }
        writeProbeLog("[peers] hook v3 entered")
        didRunPeers = true
        Task { @MainActor in
            writeProbeLog("[peers] hook v3 task start")
            AppKit.NSApplication.shared.activate(ignoringOtherApps: true)
            writeProbeLog("[peers] hook v3 activated")
            AppKit.NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil)
            writeProbeLog("[peers] hook v3 fronted")
            model.setWindowVisible(true)
            for _ in 0..<240 {
                if model.isConnected, let first = model.torrents.first,
                   model.details(for: first.id) != nil { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            try? await Task.sleep(for: .seconds(3))
            model.selectedIDs = [model.torrents.first?.id ?? ""]
            model.startTorrents(Array(model.selectedIDs))
            model.toggleDetails()
            model.selectedTab = .peers
            writeProbeLog(
                "[peers] hook sel=\(model.selectedIDs.joined(separator: ","))"
                    + " torrents=\(model.torrents.count) connected=\(model.isConnected)"
                    + " vis=\(model.windowVisible)"
            )
            for step in 0..<10 {
                model.setWindowVisible(true)
                try? await Task.sleep(for: .seconds(2))
                if (model.selectedIDs.first?.isEmpty ?? true),
                   let first = model.torrents.first {
                    model.selectedIDs = [first.id]
                    model.toggleDetails()
                    model.selectedTab = .peers
                }
                let peers = model.selectedDetails?.peers
                writeProbeLog(
                    "[peers] hook step=\(step) rows=\(peers?.count ?? -1)"
                        + " sel=\(model.selectedIDs.joined(separator: ","))"
                        + " torrents=\(model.torrents.count) vis=\(model.windowVisible)"
                )
                if let peers, !peers.isEmpty { break }
            }
            let probeRow = PeerRow(
                ip: "192.0.2.7", port: 6881, client: "", flags: "", connection: "",
                progress: 0, downSpeed: 0, upSpeed: 0, country: "", countryCode: "",
                downloaded: 0, uploaded: 0
            )
            model.banPeers([probeRow])
            try? await Task.sleep(for: .seconds(2))
            let bans = await model.engineBannedIPs()
            writeProbeLog("[peers] hook engineBans=\(bans.joined(separator: ","))")
            try? await Task.sleep(for: .seconds(1))
            await model.removeBannedIPs(["192.0.2.7"])
        }
    }

    // MARK: - Windows / selection

    private static func windows(
        model: ListViewModel,
        arguments: [String],
        openWindow: (String) -> Void
    ) {
        if arguments.contains("--show-settings") {
            openWindow("settings")
        }
        if arguments.contains("--show-downloads") {
            openWindow("downloads")
        }
        if arguments.contains("--test-settings") {
            openWindow("settings")
            AppSettings.shared.appearance = .dark
            AppSettings.shared.defaultSavePath = "/tmp/drift-downloads"
            Task {
                try? await Task.sleep(for: .seconds(3))
                AppSettings.shared.appearance = .system
                AppSettings.shared.defaultSavePath = "~/Downloads"
                writeProbeLog("[settings] test sequence done")
            }
        }
        if arguments.contains("--show-add-sheet") {
            model.showAddSheet = true
        }
    }

    private static func selection(model: ListViewModel, arguments: [String]) {
        guard arguments.contains("--test-select") else { return }
        Task { @MainActor in
            for _ in 0..<40 {
                if model.isConnected, model.torrents.count > 6 { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            try? await Task.sleep(for: .seconds(4))
            writeProbeLog("[ui] test-select imminent row2")
            try? await Task.sleep(for: .seconds(1))
            model.selectedIDs = [model.torrents[2].id]
            writeProbeLog("[ui] test-select row2 done")
            try? await Task.sleep(for: .seconds(6))
            writeProbeLog("[ui] test-select imminent row5")
            try? await Task.sleep(for: .seconds(1))
            model.selectedIDs = [model.torrents[5].id]
            writeProbeLog("[ui] test-select row5 done")
        }
    }

    // MARK: - Add / mutations

    private static func addAndMutations(model: ListViewModel, arguments: [String]) {
        if arguments.contains("--test-add") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                model.confirmAdd(
                    source: .magnetOrURL("magnet:?xt=urn:btih:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa&dn=Test+Added+Torrent&xl=1234567890"),
                    options: AddOptions(savePath: "~/Downloads")
                )
            }
            // The test torrent is real state now; drop it again after
            // the probe has verified the add pipeline.
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                writeProbeLog("[sheet] test-add cleanup \(model.torrents.count) torrents")
                model.requestRemoval(["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"])
                model.confirmRemoval()
            }
        }

        guard arguments.contains("--test-mutations") else { return }
        Task { @MainActor in
            for _ in 0..<120 {
                if model.isConnected { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            // Let connectEngine finish assigning the engine before the first
            // mutation (isConnected flips on the same tick).
            try? await Task.sleep(for: .seconds(1))
            writeProbeLog(
                "[engine] mutations start connected=\(model.isConnected)"
                    + " count=\(model.torrents.count)"
            )
            model.confirmAdd(
                source: .magnetOrURL("magnet:?xt=urn:btih:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb&dn=drift-added-test"),
                options: AddOptions(savePath: "~/Downloads")
            )
            try? await Task.sleep(for: .seconds(2))
            let added = model.torrents.first { $0.id == String(repeating: "b", count: 40) }
            writeProbeLog("[engine] mutations added=\(added != nil)")
            if let added {
                model.stopTorrents([added.id])
                try? await Task.sleep(for: .seconds(2))
                writeProbeLog("[engine] mutations stopped=\(model.torrents.first { $0.id == added.id }?.status.rawValue ?? "gone")")
                model.startTorrents([added.id])
                try? await Task.sleep(for: .seconds(2))
                writeProbeLog("[engine] mutations restarted=\(model.torrents.first { $0.id == added.id }?.status.rawValue ?? "gone")")
                model.requestRemoval([added.id])
                model.confirmRemoval()
                try? await Task.sleep(for: .seconds(1))
                writeProbeLog("[engine] mutations removed=\(model.torrents.first { $0.id == added.id } == nil)")
            }
            if FileManager.default.fileExists(atPath: "/tmp/qbt-ubuntu.torrent") {
                model.confirmAdd(
                    source: .torrentFile(URL(fileURLWithPath: "/tmp/qbt-ubuntu.torrent")),
                    options: AddOptions(savePath: "/tmp/drift-e2e")
                )
                try? await Task.sleep(for: .seconds(3))
                if let fileTorrent = model.torrents.first(where: { $0.name.contains("ubuntu") }) {
                    writeProbeLog("[engine] mutations file-add ok name=\(fileTorrent.name) size=\(fileTorrent.size)")
                    model.requestRemoval([fileTorrent.id])
                    model.confirmRemoval()
                }
            }
            writeProbeLog("[engine] mutations sequence done")
        }
    }

    // MARK: - Details

    private static func details(model: ListViewModel, arguments: [String]) {
        guard arguments.contains("--test-details") else { return }
        Task { @MainActor in
            for _ in 0..<40 {
                if model.isConnected { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            @MainActor func snapshot() {
                guard let details = model.selectedDetails else {
                    writeProbeLog("[details] snapshot none")
                    return
                }
                let prios = details.files.map(\.priority.rawValue).joined(separator: ",")
                writeProbeLog(
                    "[details] snapshot trackers=\(details.trackers.count)"
                        + " peers=\(details.peers.count)"
                        + " webSeeds=\(details.webSeeds.count)"
                        + " files=\(details.files.count)"
                        + " status=\(details.trackers.first?.status ?? "-")"
                        + " prio=[\(prios)]"
                )
            }
            guard let first = model.torrents.first(where: { $0.name.contains("ubuntu") })
                ?? model.torrents.first
            else {
                writeProbeLog("[details] skipped (no torrents)")
                return
            }
            model.selectedIDs = [first.id]
            model.toggleDetails()
            try? await Task.sleep(for: .seconds(2.5))
            snapshot()
            if let file = model.selectedDetails?.files.first {
                model.setFilePriority(file: file, priority: .ignored)
                try? await Task.sleep(for: .seconds(2.5))
                snapshot()
                if let fileNow = model.selectedDetails?.files.first {
                    model.setFilePriority(file: fileNow, priority: .normal)
                    try? await Task.sleep(for: .seconds(2))
                    snapshot()
                }
            }
            writeProbeLog("[details] sequence done")
        }
    }
}
