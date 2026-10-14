import Foundation
import Observation
import SwiftUI

enum Appearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    private init() {}

    /// Shared key with the Add sheet's last-used destination — Settings seeds it.
    var defaultSavePath: String =
        UserDefaults.standard.string(forKey: "addTorrent.destination") ?? "~/Downloads" {
        didSet {
            UserDefaults.standard.set(defaultSavePath, forKey: "addTorrent.destination")
            writeProbeLog("[settings] defaultSavePath=\(defaultSavePath)")
        }
    }

    var appearance: Appearance =
        Appearance(
            rawValue: UserDefaults.standard.string(forKey: "settings.appearance") ?? "system"
        ) ?? .system {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: "settings.appearance")
            writeProbeLog("[settings] appearance=\(appearance.rawValue)")
        }
    }

    var preventIdleSleep: Bool =
        UserDefaults.standard.bool(forKey: "sleepPrevention.enabled") {
        didSet {
            UserDefaults.standard.set(preventIdleSleep, forKey: "sleepPrevention.enabled")
            PowerManagementManager.shared.settingsChanged()
        }
    }
}
