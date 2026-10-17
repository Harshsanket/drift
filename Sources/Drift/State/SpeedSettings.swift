import Foundation
import Observation

extension Notification.Name {
    static let driftSpeedSettingsSaved = Notification.Name("drift.speedSettingsSaved")
    static let driftSpeedSettingsRequested = Notification.Name("drift.speedSettingsRequested")
}

/// The qBittorrent transfer-speed limits the Settings window edits.
/// Units mirror the server surface: KiB/s, 0 = unlimited.
@MainActor
@Observable
final class SpeedSettings {
    static let shared = SpeedSettings()

    var downloadLimit: Int64 = 0
    var uploadLimit: Int64 = 0
    var altDownloadLimit: Int64 = 0
    var altUploadLimit: Int64 = 0
    var loaded = false
}
