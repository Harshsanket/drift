import Foundation
import Observation

/// App-wide lifetime transfer statistics, recorded client-side (independent
/// of the qBittorrent server) and persisted across launches. Sources:
/// qBittorrent session counters (deltas per refresh tick) plus Booster
/// direct-download bytes.
@MainActor
@Observable
final class AppStats {
    static let shared = AppStats()

    private enum Keys {
        static let peakDownload = "drift.APPStats.peakDownloadBps"
        static let peakDownloadAt = "drift.APPStats.peakDownloadAt"
        static let peakUpload = "drift.APPStats.peakUploadBps"
        static let peakUploadAt = "drift.APPStats.peakUploadAt"
        static let received = "drift.APPStats.totalReceivedBytes"
        static let sent = "drift.APPStats.totalSentBytes"
        static let transferSeconds = "drift.APPStats.transferSeconds"
        static let firstConnected = "drift.APPStats.firstConnectedAt"
        static let boosterBytes = "drift.APPStats.boosterBytesSeen"
    }

    private(set) var peakDownloadBps: Int64
    private(set) var peakDownloadAt: Date?
    private(set) var peakUploadBps: Int64
    private(set) var peakUploadAt: Date?
    private(set) var totalReceivedBytes: Int64
    private(set) var totalSentBytes: Int64
    private(set) var transferSeconds: TimeInterval
    private(set) var firstConnectedAt: Date?
    private(set) var boosterReceivedBytes: Int64

    private var lastReceived: Int64?
    private var lastSent: Int64?
    private var lastTickAt: Date?
    private var lastBoosterBytes: Int64?
    private var defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        peakDownloadBps = Int64(defaults.integer(forKey: Keys.peakDownload))
        peakUploadBps = Int64(defaults.integer(forKey: Keys.peakUpload))
        totalReceivedBytes = defaults.dictionaryRepresentation()[Keys.received] as? Int64 ?? 0
        totalSentBytes = defaults.dictionaryRepresentation()[Keys.sent] as? Int64 ?? 0
        transferSeconds = defaults.double(forKey: Keys.transferSeconds)
        boosterReceivedBytes = defaults.dictionaryRepresentation()[Keys.boosterBytes] as? Int64 ?? 0
        peakDownloadAt = defaults.object(forKey: Keys.peakDownloadAt) as? Date
        peakUploadAt = defaults.object(forKey: Keys.peakUploadAt) as? Date
        firstConnectedAt = defaults.object(forKey: Keys.firstConnected) as? Date
    }

    /// Called roughly every refresh tick while a server is connected.
    /// `receivedSession`/`sentSession` are session counters that reset when
    /// the server restarts; deltas regress safely back to zero then.
    func recordServerTick(receivedSession: Int64, sentSession: Int64, downloadSpeed: Int64, uploadSpeed: Int64) {
        let now = Date()
        if firstConnectedAt == nil {
            firstConnectedAt = now
            defaults.set(now.timeIntervalSince1970, forKey: Keys.firstConnected)
        }
        if let last = lastReceived, receivedSession >= last {
            totalReceivedBytes += receivedSession - last
        }
        lastReceived = receivedSession
        if let last = lastSent, sentSession >= last {
            totalSentBytes += sentSession - last
        }
        lastSent = sentSession
        assertPeak(speed: downloadSpeed, at: now, isDownload: true)
        assertPeak(speed: uploadSpeed, at: now, isDownload: false)
        if downloadSpeed > 0 || uploadSpeed > 0 {
            if let tick = lastTickAt, now.timeIntervalSince(tick) > 0, now.timeIntervalSince(tick) < 30 {
                transferSeconds += now.timeIntervalSince(tick)
            }
            lastTickAt = now
        } else {
            lastTickAt = now
        }
        persistCore()
    }

    /// Called on Booster download poll ticks — credits aggregate growth of
    /// summed transfer counters. A drop (entry removed/restarted) just
    /// re-baselines without crediting changes.
    func recordBoosterBytes(total: Int64) {
        guard let last = lastBoosterBytes else {
            lastBoosterBytes = total
            return
        }
        if let delta = Int64(exactly: total - last), delta > 0 {
            boosterReceivedBytes += delta
            totalReceivedBytes += delta
        }
        lastBoosterBytes = total
        persistCore()
    }

    private func assertPeak(speed: Int64, at date: Date, isDownload: Bool) {
        guard speed > 0 else { return }
        if isDownload, speed > peakDownloadBps {
            peakDownloadBps = speed
            peakDownloadAt = date
            defaults.set(speed, forKey: Keys.peakDownload)
            defaults.set(date.timeIntervalSince1970, forKey: Keys.peakDownloadAt)
        } else if !isDownload, speed > peakUploadBps {
            peakUploadBps = speed
            peakUploadAt = date
            defaults.set(speed, forKey: Keys.peakUpload)
            defaults.set(date.timeIntervalSince1970, forKey: Keys.peakUploadAt)
        }
    }

    private func persistCore() {
        defaults.set(peakDownloadBps, forKey: Keys.peakDownload)
        defaults.set(peakUploadBps, forKey: Keys.peakUpload)
        defaults.set(totalReceivedBytes, forKey: Keys.received)
        defaults.set(totalSentBytes, forKey: Keys.sent)
        defaults.set(boosterReceivedBytes, forKey: Keys.boosterBytes)
        defaults.set(transferSeconds, forKey: Keys.transferSeconds)
    }

    func resetAll() {
        peakDownloadBps = 0
        peakDownloadAt = nil
        peakUploadBps = 0
        peakUploadAt = nil
        totalReceivedBytes = 0
        totalSentBytes = 0
        transferSeconds = 0
        firstConnectedAt = nil
        boosterReceivedBytes = 0
        lastReceived = nil
        lastSent = nil
        lastTickAt = nil
        lastBoosterBytes = nil
        for key in [Keys.peakDownload, Keys.peakDownloadAt, Keys.peakUpload, Keys.peakUploadAt, Keys.received, Keys.sent, Keys.transferSeconds, Keys.firstConnected, Keys.boosterBytes] {
            defaults.removeObject(forKey: key)
        }
    }
}
