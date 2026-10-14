import AppKit
import Foundation

/// App-wide lifecycle notifications (system sleep/wake), delivered on the main
/// actor to the single `ListViewModel` owner.
@MainActor
final class AppLifecycle {
    static let shared = AppLifecycle()

    private init() {}

    var onSleep: (() -> Void)?
    var onWake: (() -> Void)?
    private var tokens: [NSObjectProtocol] = []

    func start() {
        guard tokens.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        tokens = [
            center.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in AppLifecycle.shared.onSleep?() }
            },
            center.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in AppLifecycle.shared.onWake?() }
            }
        ]
    }

    func stop() {
        for token in tokens {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        tokens.removeAll()
    }
}
