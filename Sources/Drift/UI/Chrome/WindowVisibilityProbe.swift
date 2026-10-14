import SwiftUI
import AppKit

/// Observes its own window's occlusion (covers close, minimize, hide, Spaces)
/// and reports the latest visibility. Attached only to the main window.
struct WindowVisibilityProbe: NSViewRepresentable {
    var onChange: (Bool) -> Void

    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: Probe, context: Context) {
        nsView.onChange = onChange
    }

    final class Probe: NSView {
        var onChange: ((Bool) -> Void)?
        nonisolated(unsafe) private var token: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let token {
                NotificationCenter.default.removeObserver(token)
                self.token = nil
            }
            guard let window else {
                onChange?(false)
                return
            }
            token = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window,
                queue: .main
            ) { [weak self] note in
                guard let self, let changed = note.object as? NSWindow else { return }
                let visible = changed.occlusionState.contains(.visible)
                Task { @MainActor in self.onChange?(visible) }
            }
            onChange?(window.occlusionState.contains(.visible))
        }

        deinit {
            if let token { NotificationCenter.default.removeObserver(token) }
        }
    }
}
