// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import AppKit
import QuartzCore

/// Installs `TorrentTableProbe` behind the SwiftUI table.
struct TorrentTableProbeView: NSViewRepresentable {
    let model: ListViewModel

    func makeNSView(context: Context) -> TorrentTableProbe {
        let probe = TorrentTableProbe()
        probe.model = model
        probe.log("makeNSView")
        return probe
    }

    func updateNSView(_ nsView: TorrentTableProbe, context: Context) {
        nsView.model = model
        nsView.configureTable()
    }
}

final class TorrentTableProbe: NSView {
    static weak var active: TorrentTableProbe?

    /// Re-runs the table configuration immediately (footer height changes).
    static func configureNow() { active?.configureTable() }
    weak var model: ListViewModel?
    var monitor: Any?
    weak var observedTable: NSTableView?
    var lastLoggedBottomInset = ""
    var loggedScrollerConfig = false
    var startedTestScroll = false
    var testScrollTimer: Timer?
    var loggedDelayedState = false
    var configTimer: Timer?
    weak var observedWindow: NSWindow?
    nonisolated(unsafe) var occlusionObserver: NSObjectProtocol?
    var loggedRowHeightFix = false
    var startedClickTest = false
    weak var zebraView: TableZebraView?
    var rowHeightObservation: NSKeyValueObservation?
    var autoHeightsObservation: NSKeyValueObservation?
    var styleObservation: NSKeyValueObservation?
    var intercellObservation: NSKeyValueObservation?
    var gridStyleObservation: NSKeyValueObservation?
    var alternatingObservation: NSKeyValueObservation?
    var isReapplyingTableGeometry = false
    var loggedRowHeightRepin = false
    /// Row-click menu pop state (see scheduleRowMenuPop).
    var rowMenuPopWork: DispatchWorkItem?
    var rowMenuDownPoint: NSPoint?
    var rowMenuDownRow = -1
    var lastRowMenuPopAt = Date.distantPast

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            if let occlusionObserver {
                NotificationCenter.default.removeObserver(occlusionObserver)
                self.occlusionObserver = nil
            }
            observedWindow = nil
            configTimer?.invalidate()
            configTimer = nil
            return
        }
        Self.active = self
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .leftMouseUp]) { [weak self] event in
                self?.handle(event) ?? event
            }
        }
        observeOcclusion(of: window)
        updateConfigTimer()
    }

    override func layout() {
        super.layout()
        configureTable()
    }

    private func observeOcclusion(of window: NSWindow) {
        guard observedWindow !== window else { return }
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
        }
        observedWindow = window
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updateConfigTimer() }
        }
    }

    /// SwiftUI resizes the backing table (and resets `rowHeight`) without
    /// any layout callback we can observe, so re-apply the design geometry
    /// periodically — but only while the window is actually on screen.
    /// The timer is purely a fallback: SwiftUI updates and the KVO re-pin
    /// observers still configure the table while it is parked.
    private func updateConfigTimer() {
        guard let window, window.occlusionState.contains(.visible) else {
            configTimer?.invalidate()
            configTimer = nil
            return
        }
        guard configTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            self?.configureTable()
        }
        RunLoop.main.add(timer, forMode: .common)
        configTimer = timer
    }

    func log(_ message: String) {
        writeProbeLog("[probe] \(message)")
    }
}
