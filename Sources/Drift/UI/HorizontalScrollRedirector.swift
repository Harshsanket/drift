import SwiftUI
import AppKit

/// Appends a line to the shared probe log; used by the table probe and the
/// view model to record interaction verification without console tooling.
func writeProbeLog(_ message: String) {
    let url = URL(fileURLWithPath: "/tmp/drift-probe.log")
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
        weak var model: ListViewModel?
        private var monitor: Any?
        private weak var observedTable: NSTableView?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil, monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                    self?.handle(event) ?? event
                }
            } else if window == nil, let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        override func layout() {
            super.layout()
            configureTable()
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
            if !table.usesAlternatingRowBackgroundColors {
                table.usesAlternatingRowBackgroundColors = true
                log("alternating -> true")
            }
            let rowHeight = DesignSystem.Metrics.tableRowHeight
            if abs(table.rowHeight - rowHeight) > 0.5 {
                log("rowHeight \(table.rowHeight) -> \(rowHeight)")
                table.rowHeight = rowHeight
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
            if observedTable !== table {
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(selectionChanged),
                    name: NSTableView.selectionDidChangeNotification,
                    object: table
                )
                observedTable = table
                log("selection observer attached")
            }
        }

        @objc private func selectionChanged() {
            let rows = (tableScrollView()?.documentView as? NSTableView)?
                .selectedRowIndexes
                .map { $0 } ?? []
            log("selection changed rows=\(rows)")
        }

        func log(_ message: String) {
            writeProbeLog("[probe] \(message)")
        }

        @objc private func handleRowDoubleClicked() {
            log("doubleAction fired")
            model?.toggleDetails()
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
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
