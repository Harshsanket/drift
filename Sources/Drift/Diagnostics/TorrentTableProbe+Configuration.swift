// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import AppKit
import QuartzCore

extension TorrentTableProbe {
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
           table.numberOfRows > 0 {
            startedClickTest = true
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                self?.simulateRowClick(row: 0, xFraction: 0.5)
                try? await Task.sleep(for: .seconds(2))
                self?.simulateRowClick(row: 0, xFraction: 0.9)
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
    func startTestScroll() {
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

    @objc func selectionChanged() {
        let rows = (tableScrollView()?.documentView as? NSTableView)?
            .selectedRowIndexes
            .map { $0 } ?? []
        let clip = tableScrollView()?.contentView as? NSClipView
        log("selection changed rows=\(rows) clipOrigin=\(clip?.bounds.origin ?? .zero)")
    }


    /// Re-applies the design row height with implicit animations fully
    /// disabled: SwiftUI resets `rowHeight` in the middle of its own
    /// render pass, so a plain set would let Core Animation ease the
    /// rows/cells from their mid-render geometry to the pinned one —
    /// a visible ~5pt/10pt shift for a few hundred milliseconds after
    /// every click. Zeroing the animation context applies it in place.
    func reapplyRowHeight(_ table: NSTableView, _ height: CGFloat) {
        withoutAnimations { table.rowHeight = height }
    }

    /// Runs a geometry change with Core Animation's implicit actions and
    /// the AppKit animation context fully disabled, so re-pinning design
    /// geometry inside SwiftUI's render pass lands in place instead of
    /// easing from the mid-render values.
    func withoutAnimations(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        body()
        NSAnimationContext.endGrouping()
        CATransaction.commit()
    }
}
