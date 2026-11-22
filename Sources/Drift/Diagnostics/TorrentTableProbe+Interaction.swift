// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import AppKit
import QuartzCore

extension TorrentTableProbe {
    @objc func handleRowDoubleClicked() {
        log("doubleAction fired")
        model?.toggleDetails()
    }

    /// Verification-only: --test-click synthesizes a real click into the
    /// window's event pipeline so row-click side effects (selection and
    /// any scroll nudge) can be observed without physical input.
    /// `xFraction` picks where in the row the click lands (0.5 = name
    /// text, 0.9 = empty space right of the text).
    func simulateRowClick(row: Int, xFraction: CGFloat = 0.5) {
        guard let window,
              let scrollView = tableScrollView(),
              let table = scrollView.documentView as? NSTableView,
              row < table.numberOfRows
        else { return }
        let rowRect = table.rect(ofRow: row)
        let point = NSPoint(
            x: rowRect.minX + rowRect.width * xFraction,
            y: rowRect.midY
        )
        let windowPoint = table.convert(point, to: nil)
        // Menus anchor to the physical cursor, not the synthesized
        // event location: warp the cursor to the row point first.
        let screenPoint = window.convertToScreen(
            CGRect(origin: windowPoint, size: CGSize(width: 1, height: 1))).origin
        CGWarpMouseCursorPosition(screenPoint)
        log("simClick row=\(row) xFrac=\(xFraction) windowPoint=\(windowPoint)"
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
            NSApp.sendEvent(down)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self,
                  let sv = self.tableScrollView(),
                  let t = sv.documentView as? NSTableView
            else { return }
            self.log("simClickAfter row=\(row) xFrac=\(xFraction)"
                + " clipAfter=\(sv.contentView.bounds)"
                + " docAfter=\(t.frame)"
                + " selected=\(t.selectedRowIndexes.map { $0 })")
        }
    }

    func cancelRowMenuPop() {
        rowMenuPopWork?.cancel()
        rowMenuPopWork = nil
        rowMenuDownPoint = nil
        rowMenuDownRow = -1
    }

    /// This fires only if the click stays a plain single click: any
    /// second press (a double-click), drag, or scroll cancels it first.
    /// The pop itself synthesizes a secondary click at the row point so
    /// SwiftUI shows exactly the menu a right-click would.
    func scheduleRowMenuPop() {
        // Cancel only the previous pending pop: the fresh down-point
        // (set by the click handler just before this call) must stay.
        rowMenuPopWork?.cancel()
        rowMenuPopWork = nil
        guard let downPoint = rowMenuDownPoint else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else {
                writeProbeLog("[probe] row menu pop died (probe gone)")
                return
            }
            self.log("row menu pop firing"
                + (self.rowMenuDownPoint == nil ? " (state gone)" : ""))
            guard let point = self.rowMenuDownPoint else {
                self.log("row menu pop died (state gone)")
                return
            }
            self.rowMenuPopWork = nil
            self.rowMenuDownPoint = nil
            self.rowMenuDownRow = -1
            self.popRowMenuIfClear(at: point)
        }
        rowMenuPopWork = work
        // Full double-click interval: a genuine double-click always
        // cancels this before it can fire.
        DispatchQueue.main.asyncAfter(
            deadline: .now() + NSEvent.doubleClickInterval + 0.05,
            execute: work
        )
    }

    /// Pops the row's context menu by synthesizing a secondary click at
    /// the row point.
    ///
    /// Guards keep this from fighting its own menu:
    /// - never while a popUpMenu-level window (the menu itself) exists;
    /// - never within a short grace window after the last pop, so the
    ///   click that *dismisses* the menu does not immediately reopen it.
    func popRowMenuIfClear(at locationInWindow: NSPoint) {
        // Context menus surface as NSMenuWindowManagerWindow at
        // .popUpMenu level. Other windows (SPRoundedWindow glass
        // backing) share the level, so they are filtered by class.
        let menuWindows = NSApp.windows
            .filter {
                $0.level == .popUpMenu
                    && String(describing: type(of: $0)).contains("Menu")
            }
            .map { "\($0.className)#\($0.windowNumber)" }
        let menuSession = !menuWindows.isEmpty
        let withinGrace = Date().timeIntervalSince(lastRowMenuPopAt) < 0.6
        if menuSession || withinGrace {
            log("row menu pop suppressed"
                + (menuSession ? " (menu session active)" : " (grace window)")
                + (menuSession ? " windows=[\(menuWindows.joined(separator: ", "))]" : ""))
            return
        }
        guard let window else {
            log("row menu pop skipped (probe window nil)")
            return
        }
        let windowNumber = window.windowNumber
        let now = ProcessInfo.processInfo.systemUptime
        let down = NSEvent.mouseEvent(
            with: .rightMouseDown, location: locationInWindow,
            modifierFlags: [], timestamp: now, windowNumber: windowNumber,
            context: nil, eventNumber: Int(now), clickCount: 1, pressure: 0
        )
        let up = NSEvent.mouseEvent(
            with: .rightMouseUp, location: locationInWindow,
            modifierFlags: [], timestamp: now + 0.05, windowNumber: windowNumber,
            context: nil, eventNumber: Int(now) + 1, clickCount: 1, pressure: 0
        )
        lastRowMenuPopAt = Date()
        log("row menu pop left->right")
        guard let down, let up else {
            log("row menu pop event creation failed")
            return
        }
        // Back-to-back synchronous delivery: SwiftUI materializes the
        // context menu on this down/up pair only when they land in the
        // same run-loop turn (a delayed up yields menu windows=0).
        NSApp.sendEvent(down)
        NSApp.sendEvent(up)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.logMenuWindowState()
        }
    }

    /// Verification-only: logs whether a menu-owning window materialized
    /// after the synthesized secondary click.
    func logMenuWindowState() {
        let menuWindows = NSApp.windows.filter {
            $0.level == .popUpMenu
                && String(describing: type(of: $0)).contains("Menu")
        }
        log("menu windows=\(menuWindows.count)")
    }

    func handle(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .leftMouseDown:
            // Any other press cancels a pending pop (second click of a
            // double-click, click elsewhere, multi-select clicks …).
            cancelRowMenuPop()
            if event.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty,
               event.clickCount == 1,
               event.windowNumber == window?.windowNumber,
               let table = tableScrollView()?.documentView as? NSTableView {
                let point = table.convert(event.locationInWindow, from: nil)
                let row = table.row(at: point)
                if row >= 0 {
                    rowMenuDownPoint = event.locationInWindow
                    rowMenuDownRow = row
                    scheduleRowMenuPop()
                    log("row menu scheduled row=\(row)"
                        + " dci=\(NSEvent.doubleClickInterval)")
                }
            }
        case .leftMouseUp:
            // A drag (pointer moved well past the down point) cancels.
            if let downPoint = rowMenuDownPoint,
               hypot(downPoint.x - event.locationInWindow.x,
                     downPoint.y - event.locationInWindow.y) > 12 {
                cancelRowMenuPop()
            }
        case .scrollWheel:
            cancelRowMenuPop()
        default:
            break
        }
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
                // Blank table area (below the rows / header/hover zone):
                // original outside-click collapse behavior, relocated
                // from the table's TapGesture so row clicks can carry
                // their own menu without collapsing the details glass.
                // The floating footer overlays the table's bottom edge, so
                // presses on its tabs/buttons must not count as blank-area
                // clicks — ignore the strip it covers.
                let footerTop = sv.convert(sv.bounds, to: nil).minY
                    + (self.model?.footerHeight ?? 0)
                let inFooter = location.y < footerTop
                if row < 0, !inFooter {
                    self.model?.collapseDetailsFromOutsideClick()
                }
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
        guard event.type == .scrollWheel else { return event }
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

    func enclosingScrollView(of view: NSView) -> NSScrollView? {
        var candidate: NSView? = view
        while let current = candidate {
            if let scrollView = current as? NSScrollView { return scrollView }
            candidate = current.superview
        }
        return nil
    }

    func tableScrollView() -> NSScrollView? {
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
