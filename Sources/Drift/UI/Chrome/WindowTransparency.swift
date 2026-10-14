import SwiftUI
import AppKit

// MARK: - Window transparency

/// Makes the main window non-opaque so behind-the-window materials (the
/// sidebar) can show the desktop through it. Everything that must stay solid
/// draws its own opaque background on top of the clear window.
struct TransparentWindowAttachment: NSViewRepresentable {
    final class Probe: NSView {
        private static var didApplyTestSize = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        func apply() {
            guard let window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            if !window.styleMask.contains(.fullSizeContentView) {
                window.styleMask.insert(.fullSizeContentView)
            }
            Self.applyTestSize(window)
        }

        /// Verification-only: --test-size=1200x800 or --test-size=fullscreen
        /// (or env DRIFT_TEST_SIZE) resizes the window for multi-size screenshots.
        private static func applyTestSize(_ window: NSWindow) {
            guard !didApplyTestSize else { return }
            var spec = ProcessInfo.processInfo.environment["DRIFT_TEST_SIZE"]
            if spec == nil {
                for arg in ProcessInfo.processInfo.arguments where arg.hasPrefix("--test-size=") {
                    spec = String(arg.dropFirst("--test-size=".count))
                }
            }
            guard let spec else { return }
            didApplyTestSize = true
            // Re-apply after the window finishes restoring its saved frame.
            for delay in [0.0, 1.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    resize(window, to: spec)
                }
            }
        }

        private static func resize(_ window: NSWindow, to spec: String) {
            if spec == "fullscreen" {
                if !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
            } else {
                let parts = spec.split(separator: "x")
                if parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]) {
                    var frame = window.frame
                    frame.size = NSSize(width: w, height: h)
                    window.setFrame(frame, display: true)
                }
            }
        }
    }

    func makeNSView(context: Context) -> Probe { Probe() }

    func updateNSView(_ nsView: Probe, context: Context) {
        nsView.apply()
    }
}

// MARK: - Behind-window sidebar material

/// Finder-style sidebar frost: blurs whatever is *behind the window*
/// (desktop / other windows), unlike a SwiftUI `Material` which only samples
/// opaque in-window content.
struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.material = .sidebar
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
