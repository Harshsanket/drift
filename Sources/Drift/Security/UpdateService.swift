import Foundation
import Sparkle

/// Update plumbing around Sparkle.
///
/// Division of labor:
///   - Drift owns the decision: feed URL (off by default), auto-install
///     switch, and the splash-level "Update now / Later" prompt.
///   - Sparkle owns verification (EdDSA mandatory) and the installer.
///
/// Policy pins:
///   - No feed URL configured → no check is performed at all; the surface
///     never invents a "found update" state.
///   - `updateAuto` never bypasses EdDSA: Sparkle refuses unsigned/invalid
///     packages; DigestChecker additionally verifies EdDSA before running.
///   - EdDSA public key is embedded; the matching private key exists only
///     with the release signer.
@MainActor
@Observable
final class UpdateService: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    static let shared = UpdateService()

    enum State: Equatable {
        case idle
        case checking
        case available(version: String)
        case none
        case error(String)

        var label: String {
            switch self {
            case .idle: "Idle"
            case .checking: "Checking…"
            case .available(let version): "Available: \(version)"
            case .none: "Up to date"
            case .error(let message): "Error: \(message)"
            }
        }
    }

    private(set) var state: State = .idle

    private var updater: SPUUpdater?
    private var driver: SPUStandardUserDriver?

    /// Feed chosen by the user in Settings; nil when unset/disabled.
    func currentFeedURL() -> String? {
        let raw = AppSettings.shared.updateFeedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, let url = URL(string: raw), url.scheme != nil else {
            return nil
        }
        return url.absoluteString
    }

    /// Sparkle delegate hook (may be called off the main actor): read the
    /// stored value straight through UserDefaults, which is thread-safe.
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        let raw = (UserDefaults.standard.string(forKey: "update.feedURL") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, let url = URL(string: raw), url.scheme != nil else { return nil }
        return url.absoluteString
    }

    /// Frequency/behaviour knobs.
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        ["default"]
    }

    // MARK: - Lifecycle

    func start() {
        guard updater == nil else {
            if case .idle = state { check(userInitiated: false) }
            return
        }
        guard AppSettings.shared.updateAuto else {
            writeProbeLog("[update] auto off, updater dormant")
            return
        }
        guard let feed = currentFeedURL() else {
            writeProbeLog("[update] no feed configured (disabled)")
            return
        }
        let host = Bundle.main
        let driver = SPUStandardUserDriver(hostBundle: host, delegate: self)
        let updater = SPUUpdater(
            hostBundle: host, applicationBundle: host, userDriver: driver, delegate: self)
        do {
            try updater.start()
        } catch {
            state = .error("\(error)")
            return
        }
        self.updater = updater
        self.driver = driver
        writeProbeLog("[update] started (feed host \(URL(string: feed)?.host ?? "?"))")
        check(userInitiated: false)
    }

    /// Explicit user "Check now" gesture.
    func check(userInitiated: Bool) {
        guard let updater else {
            start()
            return
        }
        state = .checking
        if userInitiated {
            updater.checkForUpdates()
        } else {
            updater.checkForUpdatesInBackground()
        }
    }

    /// "Update now" from the splash surface: re-running the check drives the
    /// standard driver into its own verified install flow.
    func install() {
        check(userInitiated: true)
    }

    // MARK: - SPUUpdaterDelegate observations

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        state = .available(version: item.displayVersionString)
        writeProbeLog("[update] found version=\(item.displayVersionString)")
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        state = .none
    }

    func updater(_ updater: SPUUpdater, failedToUpdateAfterInstall error: Error) {
        state = .error(describe(error))
    }

    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) {
        state = .error(describe(error))
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        state = .error(describe(error))
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
