import SwiftUI
import AppKit
import QuartzCore

/// Verification-only diagnostics sink. Disabled unless the process is started
/// with a `--test-*` verification hook or an explicit `--probe-log` opt-in, so
/// a normal launch never writes torrent metadata to disk. The log lives in the
/// per-user temporary directory (world-readable `/tmp` is off limits) with
/// `0600` permissions and is capped at 2 MB between runs.
enum ProbeLog {
    static let isEnabled: Bool = {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--probe-log")
            || arguments.contains(where: { $0.hasPrefix("--test-") })
    }()

    static let fileURL: URL? = {
        guard isEnabled else { return nil }
        let manager = FileManager.default
        let url = manager.temporaryDirectory.appendingPathComponent("drift-probe.log")
        let path = url.path
        if let attributes = try? manager.attributesOfItem(atPath: path),
           let size = attributes[.size] as? NSNumber,
           size.intValue > 2_000_000 {
            try? manager.removeItem(atPath: path)
        }
        if !manager.fileExists(atPath: path) {
            manager.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        return url
    }()
}

/// Appends a line to the shared probe log; used by the table probe and the
/// view model to record interaction verification without console tooling.
func writeProbeLog(_ message: String) {
    guard let url = ProbeLog.fileURL else { return }
    let data = Data("\(message)\n".utf8)
    if let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    } else {
        try? data.write(to: url)
    }
}

struct HorizontalScrollRedirector: NSViewRepresentable {
    let model: ListViewModel

    /// Re-runs the table configuration immediately. Called when the footer
    /// height changes so the scroll viewport tracks the animated glass
    /// frame-by-frame instead of waiting for the background timer.
    static func configureNow() {
        Probe.active?.configureTable()
    }

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.model = model
        probe.log("makeNSView")
        return probe
    }

    func updateNSView(_ nsView: Probe, context: Context) {
        nsView.model = model
        nsView.configureTable()
    }

    final class Probe: NSView {
        static weak var active: Probe?
        weak var model: ListViewModel?
        private var monitor: Any?
        private weak var observedTable: NSTableView?
        private var lastLoggedBottomInset = ""
        private var loggedScrollerConfig = false
        private var startedTestScroll = false
        private var testScrollTimer: Timer?
        private var loggedDelayedState = false
        private var configTimer: Timer?
        private weak var observedWindow: NSWindow?
        nonisolated(unsafe) private var occlusionObserver: NSObjectProtocol?
        private var loggedRowHeightFix = false
        private var startedClickTest = false
        private weak var zebraView: TableZebraView?
        private var rowHeightObservation: NSKeyValueObservation?
        private var autoHeightsObservation: NSKeyValueObservation?
        private var styleObservation: NSKeyValueObservation?
        private var intercellObservation: NSKeyValueObservation?
        private var gridStyleObservation: NSKeyValueObservation?
        private var alternatingObservation: NSKeyValueObservation?
        private var isReapplyingTableGeometry = false
        private var loggedRowHeightRepin = false

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
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown]) { [weak self] event in
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

        /// Pins the NSTableView backing the SwiftUI Table to the design row
        /// geometry (34pt flat full-width alternating rows) and hooks its
        /// native double-click action to the details toggle (SwiftUI exposes
        /// no double-click API for `Table`).
        func configureTable() {
            guard let scrollView = tableScrollView(),
                  let table = scrollView.documentView as? NSTableView
            else {
                log("no scroll view found")
                return
            }
            if table.style != .fullWidth {
                log("style \(table.style.rawValue) -> fullWidth")
                table.style = .fullWidth
            }
            let rowHeight = DesignSystem.Metrics.tableRowHeight
            if table.usesAutomaticRowHeights {
                table.usesAutomaticRowHeights = false
                log("usesAutomaticRowHeights -> false")
            }
            let rowHeightChanged = abs(table.rowHeight - rowHeight) > 0.5
            if rowHeightChanged {
                if !loggedRowHeightFix {
                    loggedRowHeightFix = true
                    log("rowHeight \(table.rowHeight) -> \(rowHeight)")
                }
                table.rowHeight = rowHeight
            }
            if table.usesAlternatingRowBackgroundColors {
                table.usesAlternatingRowBackgroundColors = false
                log("alternating -> false")
            }
            // AppKit's alternating painter fills the table at the
            // SwiftUI-pinned 24pt `rowHeight`, which never matches the 34pt
            // rows, so its bands look broken wherever they leak. Paint the
            // zebra ourselves instead: one opaque view covering the whole
            // table, beneath the row views, so the rows and the empty area
            // below them come from a single drawing pass and match exactly.
            let zebra: TableZebraView
            if let existing = zebraView, existing.superview === table {
                zebra = existing
            } else {
                let fresh = TableZebraView()
                fresh.debugLog = { [weak self] message in self?.log(message) }
                table.addSubview(fresh, positioned: .below, relativeTo: nil)
                zebraView = fresh
                zebra = fresh
            }
            if table.subviews.first !== zebra {
                table.addSubview(zebra, positioned: .below, relativeTo: nil)
            }
            if zebra.frame != table.bounds {
                zebra.frame = table.bounds
                zebra.needsDisplay = true
            }
            if table.intercellSpacing.height != 0 {
                table.intercellSpacing = NSSize(width: table.intercellSpacing.width, height: 0)
                log("intercellSpacing.height -> 0")
            }
            if table.doubleAction != #selector(handleRowDoubleClicked) {
                table.target = self
                table.doubleAction = #selector(handleRowDoubleClicked)
                log("doubleAction installed")
            }
            if !startedClickTest,
               ProcessInfo.processInfo.arguments.contains("--test-click"),
               table.numberOfRows > 2 {
                startedClickTest = true
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    self?.simulateRowClick(row: 1)
                    try? await Task.sleep(for: .seconds(2))
                    self?.simulateRowClick(row: 3)
                }
            }
            // Keep the scrollable rows clear of the floating footer by
            // tracking its height as a bottom inset on the clip view. The
            // cover must NOT live on the scroll view: overlay scrollers
            // ride the scroll view's bottom content inset, which would
            // strand the horizontal scrollbar above the floating footer.
            let cover = model?.footerHeight ?? 0
            let clip = scrollView.contentView
            let current = scrollView.contentInsets
            if abs(current.bottom) > 0.5 {
                scrollView.contentInsets = NSEdgeInsets(
                    top: current.top,
                    left: current.left,
                    bottom: 0,
                    right: current.right
                )
                log("sv.contentInsets.bottom -> 0")
            }
            let clipCurrent = clip.contentInsets
            if abs(clipCurrent.bottom - cover) > 0.5 {
                clip.contentInsets = NSEdgeInsets(
                    top: clipCurrent.top,
                    left: clipCurrent.left,
                    bottom: cover,
                    right: clipCurrent.right
                )
                log("clip.contentInsets.bottom -> \(cover)")
            }
            let insetKey = "\(scrollView.contentInsets.bottom)/\(clip.contentInsets.bottom)"
            if insetKey != lastLoggedBottomInset {
                lastLoggedBottomInset = insetKey
                if let h = scrollView.horizontalScroller {
                    let f = h.convert(h.bounds, to: nil)
                    log("hScroller winY=\(f.minY)...\(f.maxY)"
                        + " svInset=\(scrollView.contentInsets.bottom)"
                        + " clipInset=\(clip.contentInsets.bottom)")
                }
            }
            if !loggedScrollerConfig {
                loggedScrollerConfig = true
                log("table rows=\(table.numberOfRows)"
                    + " bg=\(table.backgroundColor.description)"
                    + " frame=\(table.frame)"
                    + " altEnabled=\(table.usesAlternatingRowBackgroundColors)")
                let docWidth = scrollView.documentView?.frame.width ?? -1
                let probeInWindow = convert(bounds, to: nil)
                let svInWindow = scrollView.convert(scrollView.bounds, to: nil)
                log("scrollers hasH=\(scrollView.hasHorizontalScroller)"
                    + " style=\(scrollView.scrollerStyle.rawValue)"
                    + " autohide=\(scrollView.autohidesScrollers)"
                    + " docW=\(docWidth) clipW=\(scrollView.contentView.bounds.width)"
                    + " probeWinY=\(probeInWindow.minY)...\(probeInWindow.maxY)"
                    + " svWinY=\(svInWindow.minY)...\(svInWindow.maxY)"
                    + " insets=\(scrollView.contentInsets.top)/\(scrollView.contentInsets.left)"
                    + "/\(scrollView.contentInsets.bottom)/\(scrollView.contentInsets.right)")
                if let h = scrollView.horizontalScroller {
                    let f = h.convert(h.bounds, to: nil)
                    log("hScroller winY=\(f.minY)...\(f.maxY) hidden=\(h.isHidden)"
                        + " clipViewInset=\(scrollView.contentView.contentInsets.bottom)")
                }
                if let v = scrollView.verticalScroller {
                    let f = v.convert(v.bounds, to: nil)
                    log("vScroller winX=\(f.minX)...\(f.maxX) hidden=\(v.isHidden)")
                }
            }
            if !loggedDelayedState {
                loggedDelayedState = true
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    guard let self,
                          let scrollView = tableScrollView(),
                          let t = scrollView.documentView as? NSTableView
                    else { return }
                    self.log("state@3s rows=\(t.numberOfRows)"
                        + " rh=\(t.rowHeight)"
                        + " style=\(t.style.rawValue)"
                        + " alt=\(t.usesAlternatingRowBackgroundColors)"
                        + " frame=\(t.frame)"
                        + " lastRowRect=\(t.numberOfRows > 0 ? t.rect(ofRow: t.numberOfRows - 1) : .zero)"
                        + " bg=\(t.backgroundColor.description)")
                    self.log("state@3s clipFrame=\(scrollView.contentView.frame)"
                        + " clipBounds=\(scrollView.contentView.bounds)"
                        + " clipBg=\(String(describing: scrollView.contentView.backgroundColor))"
                        + " drawsBg=\(scrollView.drawsBackground)"
                        + " svBg=\(String(describing: scrollView.backgroundColor))")
                    let winBounds = self.window?.contentView?.bounds ?? .zero
                    let zebraFrame = self.zebraView.map { $0.convert($0.bounds, to: nil) }
                    self.log("state@3s winBounds=\(winBounds)"
                        + " footer=\(self.model?.footerHeight ?? 0)"
                        + " zebra=\(String(describing: zebraFrame))")
                }
            }
            if ProcessInfo.processInfo.arguments.contains("--test-scroll"),
               !startedTestScroll {
                startedTestScroll = true
                startTestScroll()
            }
            if observedTable !== table {
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(selectionChanged),
                    name: NSTableView.selectionDidChangeNotification,
                    object: table
                )
                observedTable = table
                log("selection observer attached")
                // SwiftUI re-applies its own table metrics (rowHeight 24,
                // automatic row heights) every time it re-renders — e.g. on
                // each selection change — and the 0.35s config timer used to
                // snap the geometry back hundreds of milliseconds later,
                // which read as the list "moving" on every click. Re-pin
                // synchronously from the property's own KVO so the wrong
                // geometry is never rendered for a frame.
                rowHeightObservation?.invalidate()
                autoHeightsObservation?.invalidate()
                rowHeightObservation = table.observe(\.rowHeight, options: [.new]) { [weak self] table, _ in
                    guard let self, !self.isReapplyingTableGeometry else { return }
                    let target = DesignSystem.Metrics.tableRowHeight
                    guard abs(table.rowHeight - target) > 0.5 else { return }
                    self.isReapplyingTableGeometry = true
                    self.reapplyRowHeight(table, target)
                    self.isReapplyingTableGeometry = false
                    if !self.loggedRowHeightRepin {
                        self.loggedRowHeightRepin = true
                        self.log("rowHeight KVO re-pin \(table.rowHeight) (SwiftUI reset it)")
                    }
                }
                autoHeightsObservation = table.observe(\.usesAutomaticRowHeights, options: [.new]) { [weak self] table, _ in
                    guard let self, !self.isReapplyingTableGeometry else { return }
                    guard table.usesAutomaticRowHeights else { return }
                    self.isReapplyingTableGeometry = true
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    table.usesAutomaticRowHeights = false
                    CATransaction.commit()
                    self.isReapplyingTableGeometry = false
                    self.log("autoH KVO re-pin (SwiftUI reset it)")
                }
                styleObservation?.invalidate()
                intercellObservation?.invalidate()
                gridStyleObservation?.invalidate()
                alternatingObservation?.invalidate()
                styleObservation = table.observe(\.style, options: [.new]) { [weak self] table, _ in
                    guard let self, !self.isReapplyingTableGeometry else { return }
                    let reset = table.style.rawValue
                    guard table.style != .fullWidth else { return }
                    self.isReapplyingTableGeometry = true
                    self.withoutAnimations { table.style = .fullWidth }
                    self.isReapplyingTableGeometry = false
                    self.log("style KVO re-pin fullWidth (SwiftUI reset \(reset))")
                }
                intercellObservation = table.observe(\.intercellSpacing, options: [.new]) { [weak self] table, _ in
                    guard let self, !self.isReapplyingTableGeometry else { return }
                    guard table.intercellSpacing.height != 0 else { return }
                    self.isReapplyingTableGeometry = true
                    self.withoutAnimations {
                        table.intercellSpacing = NSSize(width: table.intercellSpacing.width, height: 0)
                    }
                    self.isReapplyingTableGeometry = false
                    self.log("intercell KVO re-pin (SwiftUI reset it)")
                }
                gridStyleObservation = table.observe(\.gridStyleMask, options: [.new]) { [weak self] table, _ in
                    guard let self, !self.isReapplyingTableGeometry else { return }
                    guard table.gridStyleMask != [] else { return }
                    self.isReapplyingTableGeometry = true
                    self.withoutAnimations { table.gridStyleMask = [] }
                    self.isReapplyingTableGeometry = false
                    self.log("gridStyle KVO re-pin (SwiftUI reset it)")
                }
                alternatingObservation = table.observe(\.usesAlternatingRowBackgroundColors, options: [.new]) { [weak self] table, _ in
                    guard let self, !self.isReapplyingTableGeometry else { return }
                    guard table.usesAlternatingRowBackgroundColors else { return }
                    self.isReapplyingTableGeometry = true
                    self.withoutAnimations { table.usesAlternatingRowBackgroundColors = false }
                    self.isReapplyingTableGeometry = false
                    self.log("alternating KVO re-pin (SwiftUI reset it)")
                }
            }
        }

        /// Verification-only: --test-scroll scrolls the table horizontally
        /// back and forth so the overlay scrollers stay visible for capture,
        /// exercising the scrollbar-past-the-footer geometry.
        private func startTestScroll() {
            log("test-scroll start")
            Task { @MainActor [weak self] in
                for step in 0..<16 {
                    guard let self, window != nil,
                          let scrollView = tableScrollView(),
                          let clip = scrollView.contentView as NSClipView?
                    else { break }
                    let maxX = max(0, (scrollView.documentView?.frame.width ?? 0) - clip.bounds.width)
                    let x = step % 2 == 0 ? min(80, maxX) : 0
                    clip.scroll(to: NSPoint(x: x, y: clip.bounds.origin.y))
                    scrollView.reflectScrolledClipView(clip)
                    log("test-scroll x=\(x) maxX=\(maxX)")
                    try? await Task.sleep(for: .milliseconds(600))
                }
            }
        }

        @objc private func selectionChanged() {
            let rows = (tableScrollView()?.documentView as? NSTableView)?
                .selectedRowIndexes
                .map { $0 } ?? []
            let clip = tableScrollView()?.contentView as? NSClipView
            log("selection changed rows=\(rows) clipOrigin=\(clip?.bounds.origin ?? .zero)")
        }

        func log(_ message: String) {
            writeProbeLog("[probe] \(message)")
        }

        /// Re-applies the design row height with implicit animations fully
        /// disabled: SwiftUI resets `rowHeight` in the middle of its own
        /// render pass, so a plain set would let Core Animation ease the
        /// rows/cells from their mid-render geometry to the pinned one —
        /// a visible ~5pt/10pt shift for a few hundred milliseconds after
        /// every click. Zeroing the animation context applies it in place.
        private func reapplyRowHeight(_ table: NSTableView, _ height: CGFloat) {
            withoutAnimations { table.rowHeight = height }
        }

        /// Runs a geometry change with Core Animation's implicit actions and
        /// the AppKit animation context fully disabled, so re-pinning design
        /// geometry inside SwiftUI's render pass lands in place instead of
        /// easing from the mid-render values.
        private func withoutAnimations(_ body: () -> Void) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0
            body()
            NSAnimationContext.endGrouping()
            CATransaction.commit()
        }

        @objc private func handleRowDoubleClicked() {
            log("doubleAction fired")
            model?.toggleDetails()
        }

        /// Verification-only: --test-click synthesizes a real click into the
        /// window's event pipeline so row-click side effects (selection and
        /// any scroll nudge) can be observed without physical input.
        private func simulateRowClick(row: Int) {
            guard let window,
                  let scrollView = tableScrollView(),
                  let table = scrollView.documentView as? NSTableView,
                  row < table.numberOfRows
            else { return }
            let rowRect = table.rect(ofRow: row)
            let windowPoint = table.convert(NSPoint(x: rowRect.midX, y: rowRect.midY), to: nil)
            log("simClick row=\(row) windowPoint=\(windowPoint)"
                + " clipBefore=\(scrollView.contentView.bounds)"
                + " docBefore=\(table.frame)"
                + " selected=\(table.selectedRowIndexes.map { $0 })")
            let now = ProcessInfo.processInfo.systemUptime
            if let down = NSEvent.mouseEvent(
                with: .leftMouseDown, location: windowPoint, modifierFlags: [],
                timestamp: now, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1
            ) {
                if let up = NSEvent.mouseEvent(
                    with: .leftMouseUp, location: windowPoint, modifierFlags: [],
                    timestamp: now + 0.05, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 1, clickCount: 1, pressure: 0
                ) {
                    NSApp.postEvent(up, atStart: false)
                }
                window.sendEvent(down)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self,
                      let sv = self.tableScrollView(),
                      let t = sv.documentView as? NSTableView
                else { return }
                self.log("simClickAfter row=\(row)"
                    + " clipAfter=\(sv.contentView.bounds)"
                    + " docAfter=\(t.frame)"
                    + " selected=\(t.selectedRowIndexes.map { $0 })")
            }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            // Clicks must pass through instantly: any synchronous work here
            // (logging I/O, view-tree walks) delays the mouseDown delivered
            // to SwiftUI and its row-click gestures stop recognizing. All
            // diagnostics therefore run on the next main-loop turn instead.
            if event.type == .leftMouseDown {
                let location = event.locationInWindow
                DispatchQueue.main.async { [weak self] in
                    guard let self, let sv = self.tableScrollView(),
                          let t = sv.documentView as? NSTableView else { return }
                    let clip = sv.contentView
                    let tablePoint = t.convert(location, from: nil)
                    let row = t.row(at: tablePoint)
                    self.log("mouseDown row=\(row) clipBefore=\(clip.bounds.origin)"
                        + " rh=\(t.rowHeight) autoH=\(t.usesAutomaticRowHeights)"
                        + " enabled=\(t.isEnabled) shs=\(t.selectionHighlightStyle.rawValue)"
                        + " row0=\(t.rect(ofRow: 0)) rowRect=\(row >= 0 ? t.rect(ofRow: row) : .zero)")
                    for delay in [0.05, 0.15, 0.3, 0.5, 0.8, 1.2, 2.0] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                            guard let self,
                                  let sv2 = self.tableScrollView(),
                                  let t2 = sv2.documentView as? NSTableView
                            else { return }
                            let r0 = t2.numberOfRows > 0 ? t2.rect(ofRow: 0) : .zero
                            let rr = row >= 0 && row < t2.numberOfRows ? t2.rect(ofRow: row) : .zero
                            var rvInfo = "-"
                            if row >= 0, row < t2.numberOfRows,
                               let rv = t2.rowView(atRow: row, makeIfNecessary: false) {
                                let subs = rv.subviews.map { NSStringFromRect($0.frame) }.joined(separator: "|")
                                rvInfo = "rv=\(NSStringFromRect(rv.frame)) subs=\(subs)"
                            }
                            self.log("mouseAfter +\(delay) clip=\(sv2.contentView.bounds.origin)"
                                + " rh=\(t2.rowHeight) sel=\(t2.selectedRowIndexes.map { $0 })"
                                + " row0=\(r0) rowRect=\(rr) \(rvInfo)")
                        }
                    }
                }
                return event
            }
            guard !event.hasPreciseScrollingDeltas else { return event }
            guard abs(event.scrollingDeltaY) > 0.01 else { return event }
            guard let window else { return event }

            let probeFrameInWindow = convert(bounds, to: nil)
            guard let hit = window.contentView?.hitTest(event.locationInWindow),
                  let target = enclosingScrollView(of: hit),
                  target.convert(target.bounds, to: nil).contains(probeFrameInWindow)
            else { return event }

            let clip = target.contentView
            var origin = clip.bounds.origin
            origin.x -= event.scrollingDeltaY * 10
            origin.x = max(0, min(origin.x, clip.documentRect.width - clip.bounds.width))
            clip.scroll(to: origin)
            target.reflectScrolledClipView(clip)
            return nil
        }

        private func enclosingScrollView(of view: NSView) -> NSScrollView? {
            var candidate: NSView? = view
            while let current = candidate {
                if let scrollView = current as? NSScrollView { return scrollView }
                candidate = current.superview
            }
            return nil
        }

        private func tableScrollView() -> NSScrollView? {
            guard let contentView = window?.contentView else { return nil }
            let probeFrameInWindow = convert(bounds, to: nil)
            var match: NSScrollView?
            func walk(_ view: NSView) {
                if let scrollView = view as? NSScrollView,
                   scrollView.convert(scrollView.bounds, to: nil).contains(probeFrameInWindow) {
                    match = scrollView
                    return
                }
                for subview in view.subviews where match == nil {
                    walk(subview)
                }
            }
            walk(contentView)
            return match
        }
    }
}

/// Paints the table's zebra across the entire table — row area and the
/// empty area below the last row alike — from one drawing pass, so the two
/// always match. Lives beneath the row views; the rows are transparent
/// where they show background.
///
/// The colors are tuned because the window's vibrancy wash is applied at
/// composite time, outside every in-app bitmap API (`cacheDisplay`,
/// `CALayer.render(in:)`), so the rendered row colors cannot be sampled:
/// filling this view with the known rendered values (even #363533, odd
/// #424140) came out a uniform ~ +16 lum too bright, so the fills sit 16
/// lower. Measured stable across runs.
final class TableZebraView: NSView {
    var debugLog: ((String) -> Void)?
    private var loggedFirstDraw = false
    var evenColor = NSColor(srgbRed: 41 / 255, green: 40 / 255, blue: 38 / 255, alpha: 1)
    var oddColor = NSColor(srgbRed: 50 / 255, green: 49 / 255, blue: 48 / 255, alpha: 1)

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        autoresizingMask = [.width, .height]
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if !loggedFirstDraw {
            loggedFirstDraw = true
            debugLog?("zebra draw bounds=\(bounds)")
        }
        let bandHeight = DesignSystem.Metrics.tableRowHeight
        var y: CGFloat = 0
        var index = 0
        while y < bounds.height {
            let band = NSRect(
                x: 0,
                y: y,
                width: bounds.width,
                height: min(bandHeight, bounds.height - y)
            )
            (index % 2 == 0 ? evenColor : oddColor).setFill()
            band.intersection(dirtyRect).fill()
            y += bandHeight
            index += 1
        }
    }
}
