import SwiftUI
import AppKit

// MARK: - Window transparency

/// Makes the main window non-opaque so behind-the-window materials (the
/// sidebar) can show the desktop through it. Everything that must stay solid
/// draws its own opaque background on top of the clear window.
struct TransparentWindowAttachment: NSViewRepresentable {
    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        func apply() {
            guard let window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
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
