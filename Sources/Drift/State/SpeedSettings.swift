// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Observation

extension Notification.Name {
    static let driftSpeedSettingsSaved = Notification.Name("drift.speedSettingsSaved")
    static let driftSpeedSettingsRequested = Notification.Name("drift.speedSettingsRequested")
}

/// The embedded engine's global transfer-speed limits, edited in Settings.
/// Units are KiB/s; 0 = unlimited.
@MainActor
@Observable
final class SpeedSettings {
    static let shared = SpeedSettings()

    var downloadLimit: Int64 = 0
    var uploadLimit: Int64 = 0
    var loaded = false
}
