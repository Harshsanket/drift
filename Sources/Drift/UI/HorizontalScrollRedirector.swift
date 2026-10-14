import SwiftUI
import AppKit

struct HorizontalScrollRedirector: NSViewRepresentable {
    let model: ListViewModel

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.model = model
        return probe
    }

    func updateNSView(_ nsView: Probe, context: Context) {
        nsView.model = model
        nsView.publishMetrics()
    }

    final class Probe: NSView {
        weak var model: ListViewModel?
        private var monitor: Any?
        private var lastPublishedWidths: [CGFloat] = []
        private var lastPublishedRowHeight: CGFloat = 0

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
            publishMetrics()
        }

        func publishMetrics() {
            guard let model, let scrollView = tableScrollView(),
                  let table = scrollView.documentView as? NSTableView
            else { return }
            let widths = table.tableColumns.map(\.width)
            let rowHeight = table.rowHeight
            if widths != lastPublishedWidths {
                lastPublishedWidths = widths
                model.columnWidths = widths
            }
            if rowHeight > 0, abs(rowHeight - lastPublishedRowHeight) > 0.5 {
                lastPublishedRowHeight = rowHeight
                model.tableRowHeight = rowHeight
            }
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
