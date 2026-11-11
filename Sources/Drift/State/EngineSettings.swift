import Foundation
import Observation

enum EngineMode: String, CaseIterable, Identifiable {
    case embedded
    case server

    var id: String { rawValue }

    var label: String {
        switch self {
        case .embedded: "Embedded engine"
        case .server: "qBittorrent server"
        }
    }

    var detail: String {
        switch self {
        case .embedded:
            "Drift runs its own libtorrent engine — no Docker or separate install."
        case .server:
            "Drift drives a qBittorrent Web API instance (local or remote)."
        }
    }
}

extension Notification.Name {
    static let driftEngineModeChanged = Notification.Name("drift.engineModeChanged")
}

/// Engine selection (EMBEDDED-ENGINE.md §4/§10): embedded is the DMG default
/// for fresh installs; a pre-existing server connection keeps server mode so
/// upgrades do not silently point at a different engine.
@MainActor
@Observable
final class EngineSettings {
    static let shared = EngineSettings()

    var mode: EngineMode {
        didSet {
            guard oldValue != mode else { return }
            UserDefaults.standard.set(mode.rawValue, forKey: Self.key)
            writeProbeLog("[settings] engine mode=\(mode.rawValue)")
            NotificationCenter.default.post(name: .driftEngineModeChanged, object: self)
        }
    }

    private static let key = "engine.mode"

    private init() {
        if let raw = UserDefaults.standard.string(forKey: Self.key),
           let saved = EngineMode(rawValue: raw) {
            mode = saved
        } else if UserDefaults.standard.string(forKey: "connection.lastVersion") != nil {
            mode = .server
        } else {
            mode = .embedded
        }
    }
}
