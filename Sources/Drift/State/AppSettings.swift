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

    var showMenuBarItem: Bool =
        UserDefaults.standard.object(forKey: "menuBar.enabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(showMenuBarItem, forKey: "menuBar.enabled")
            writeProbeLog("[settings] menuBar=\(showMenuBarItem ? "on" : "off")")
            NotificationCenter.default.post(name: .driftMenuBarSettingChanged, object: nil)
            onMenuBarItemChanged?()
        }
    }

    var completionNotifications: Bool =
        UserDefaults.standard.object(forKey: "notifications.completion") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(completionNotifications, forKey: "notifications.completion")
            writeProbeLog("[settings] completionNotifications=\(completionNotifications ? "on" : "off")")
        }
    }

    /// Update feed (appcast.xml root URL). Empty = updates disabled: Sparkle
    /// is never pointed anywhere until a signed feed exists.
    var updateFeedURL: String =
        UserDefaults.standard.string(forKey: "update.feedURL") ?? "" {
        didSet {
            UserDefaults.standard.set(updateFeedURL, forKey: "update.feedURL")
            writeProbeLog("[settings] updateFeedURL set=\(!updateFeedURL.isEmpty)")
        }
    }

    /// Auto-update behind the user's decision surface. Default ON per plan;
    /// Sparkle still requires a valid EdDSA signature before anything runs.
    var updateAuto: Bool =
        UserDefaults.standard.object(forKey: "update.auto") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(updateAuto, forKey: "update.auto")
            writeProbeLog("[settings] updateAuto=\(updateAuto ? "on" : "off")")
        }
    }

    var onMenuBarItemChanged: (@MainActor () -> Void)?
}
