import AppKit
import SwiftUI

/// Stashes SwiftUI `openWindow` actions for use from AppKit menu targets.
/// Both actions are captured as soon as their window's view mounts; the
/// windows are auto-presented/restored at launch, so the actions are set
/// before the menu is ever used.
@MainActor
enum WindowOpener {
    static var openMain: (() -> Void)?
    static var openSettings: (() -> Void)?
    static var openDownloads: (() -> Void)?
}

extension Notification.Name {
    /// Posted by `ListViewModel.refresh()` with the model as `object`.
    static let driftRefreshed = Notification.Name("drift.refreshed")
    /// Posted by `AppSettings.showMenuBarItem.didSet`.
    static let driftMenuBarSettingChanged = Notification.Name("drift.menuBarSettingChanged")
}

/// AppKit `NSStatusItem` replacement for `MenuBarExtra`.
///
/// Why AppKit: SwiftUI's `MenuBarExtra` label does not re-evaluate on
/// `@Observable` changes (label is painted once), scene-level conditionals
/// are unavailable in `SceneBuilder`, and a self-updating label
/// (`TimelineView`) prevented the item from rendering at all. An
/// `NSStatusItem` gives deterministic visibility control (`isVisible`
/// respects both the app setting and the system "Allow in Menu Bar"
/// toggle) at negligible cost.
@MainActor
final class StatusItemController: NSObject {
    static let shared = StatusItemController()

    private var statusItem: NSStatusItem?
    private var statsItem: NSMenuItem?
    private var countsItem: NSMenuItem?
    private var connectionItem: NSMenuItem?
    private var pauseItem: NSMenuItem?
    private var resumeItem: NSMenuItem?
    private weak var model: ListViewModel?
    private var installed = false
    private var hiddenLogged = false

    /// Actual menu-bar visibility: app setting AND system toggle.
    var isItemVisible: Bool { statusItem?.isVisible ?? false }

    func install(model: ListViewModel) {
        guard !installed else { return }
        installed = true
        self.model = model

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "arrow.down.arrow.up",
                accessibilityDescription: "Drift transfer speeds"
            )
            button.imagePosition = .imageLeading
            button.title = DesignSystem.Format.speed(0)
        }

        let menu = NSMenu()
        menu.autoenablesItems = false

        let stats = NSMenuItem(title: "↓ 0 B/s   ↑ 0 B/s", action: nil, keyEquivalent: "")
        stats.isEnabled = false
        let counts = NSMenuItem(title: "No torrents", action: nil, keyEquivalent: "")
        counts.isEnabled = false
        let open = NSMenuItem(title: "Open Drift", action: #selector(openMainAction), keyEquivalent: "o")
        open.target = self
        let connection = NSMenuItem(title: "Connection…", action: #selector(openConnectionAction), keyEquivalent: "")
        connection.target = self
        let pause = NSMenuItem(title: "Pause All", action: #selector(pauseAllAction), keyEquivalent: "")
        pause.target = self
        let resume = NSMenuItem(title: "Resume All", action: #selector(resumeAllAction), keyEquivalent: "")
        resume.target = self
        let downloads = NSMenuItem(title: "Direct Downloads…", action: #selector(openDownloadsAction), keyEquivalent: "d")
        downloads.target = self
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettingsAction), keyEquivalent: ",")
        settings.target = self
        let quit = NSMenuItem(title: "Quit Drift", action: #selector(quitAction), keyEquivalent: "q")
        quit.target = self

        menu.addItem(stats)
        menu.addItem(counts)
        menu.addItem(.separator())
        menu.addItem(open)
        menu.addItem(connection)
        menu.addItem(pause)
        menu.addItem(resume)
        menu.addItem(downloads)
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(quit)
        item.menu = menu

        statusItem = item
        statsItem = stats
        countsItem = counts
        connectionItem = connection
        pauseItem = pause
        resumeItem = resume

        NotificationCenter.default.addObserver(
            forName: .driftRefreshed, object: nil, queue: .main
        ) { [weak self] note in
            let refreshedModel = note.object as? ListViewModel
            Task { @MainActor in
                guard let self else { return }
                if let refreshedModel {
                    self.model = refreshedModel
                }
                self.update()
            }
        }
        NotificationCenter.default.addObserver(
            forName: .driftMenuBarSettingChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applyVisibility() }
        }

        applyVisibility()
        update()
    }

    private func applyVisibility() {
        guard let statusItem else { return }
        let shouldShow = AppSettings.shared.showMenuBarItem
        guard statusItem.isVisible != shouldShow else { return }
        statusItem.isVisible = shouldShow
        if !hiddenLogged && !shouldShow {
            hiddenLogged = true
            writeProbeLog("[menubar] item hidden")
        } else if shouldShow {
            hiddenLogged = false
            writeProbeLog("[menubar] item shown")
        }
    }

    private func update() {
        guard let statusItem, let model else { return }
        let down = model.globalDownloadSpeed
        let up = model.globalUploadSpeed
        let stats = model.transferStats()

        let downText = DesignSystem.Format.speed(down)
        if statusItem.button?.title != downText {
            statusItem.button?.title = downText
        }
        let statsText = "↓ \(downText)   ↑ \(DesignSystem.Format.speed(up))"
        if statsItem?.title != statsText {
            statsItem?.title = statsText
        }
        let percent = Int((stats.progress * 100).rounded())
        let countsText: String
        if stats.downloading == 0 && stats.seeding == 0 {
            countsText = model.torrents.isEmpty
                ? "No torrents"
                : "\(model.torrents.count) torrents · \(percent)% complete"
        } else {
            countsText =
                "\(stats.downloading) downloading · \(stats.seeding) seeding · \(percent)% complete"
        }
        if countsItem?.title != countsText {
            countsItem?.title = countsText
        }
        pauseItem?.isEnabled = model.canPauseAll
        resumeItem?.isEnabled = model.canResumeAll
        let connectionText = model.isConnected
            ? "Connected — qBittorrent \(model.connectionState.version ?? "")"
            : "Connection…"
        if connectionItem?.title != connectionText {
            connectionItem?.title = connectionText
        }
        // macOS 26 can hide the item at the system level ("Allow in Menu
        // Bar" toggle) while the app setting stays on — pick that up on
        // the next tick so polling cadence follows actual visibility.
        if AppSettings.shared.showMenuBarItem, !statusItem.isVisible {
            model.recomputeSyncTier()
        }
    }

    @objc private func openMainAction() {
        NSApp.activate()
        if let action = WindowOpener.openMain {
            action()
        } else {
            writeProbeLog("[menubar] main action unavailable")
        }
    }

    @objc private func openConnectionAction() {
        NSApp.activate()
        model?.showConnectionSheet = true
    }

    @objc private func openSettingsAction() {
        NSApp.activate()
        if let action = WindowOpener.openSettings {
            action()
        } else if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            writeProbeLog("[menubar] settings action unavailable")
        }
    }

    @objc private func openDownloadsAction() {
        NSApp.activate()
        if let action = WindowOpener.openDownloads {
            action()
        } else {
            writeProbeLog("[menubar] downloads action unavailable")
        }
    }

    @objc private func pauseAllAction() {
        NSApp.activate()
        model?.pauseAll()
    }

    @objc private func resumeAllAction() {
        NSApp.activate()
        model?.resumeAll()
    }

    @objc private func quitAction() {
        NSApp.terminate(nil)
    }
}
