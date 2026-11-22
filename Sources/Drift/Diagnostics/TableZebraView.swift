// SPDX-License-Identifier: GPL-3.0-only
import AppKit

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
