import Foundation
import UserNotifications
import AppKit

/// A10 polish: dock badge with the active-download count and completion
/// notifications when a torrent flips into a done state while the app runs.
@MainActor
final class CompletionMonitor {
    static let shared = CompletionMonitor()

    private var lastStatuses: [String: TorrentStatus] = [:]
    private var lastBadge = -1

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { granted, _ in
            Task { @MainActor in
                writeProbeLog("[polish] notification permission granted=\(granted)")
            }
        }
    }

    func observe(torrents: [TorrentSummary]) {
        // Test hosts crash on NSApp/UNUserNotificationCenter access.
        guard !isTestHost else {
            lastStatuses = [String: TorrentStatus](
                uniqueKeysWithValues: torrents.map { ($0.id, $0.status) }
            )
            return
        }
        updateBadge(torrents)
        notifyCompletions(torrents)
    }

    private var isTestHost: Bool {
        Bundle.main.bundlePath.contains(".xctest")
            || Bundle.main.bundlePath.contains("swiftpm")
            || Bundle.main.bundlePath.contains("swift/pm")
            || ProcessInfo.processInfo.arguments.contains("- XCTestConfigurationFilePath")
    }

    private func updateBadge(_ torrents: [TorrentSummary]) {
        let active = torrents.count { $0.status == .downloading }
        guard active != lastBadge else { return }
        lastBadge = active
        let app = NSApplication.shared
        guard app != nil, let dockTile = app.dockTile as NSDockTile? else { return }
        dockTile.badgeLabel = active > 0 ? String(active) : nil
        writeProbeLog("[polish] dock badge -> \(active)")
    }

    private func notifyCompletions(_ torrents: [TorrentSummary]) {
        guard AppSettings.shared.completionNotifications else {
            lastStatuses = [String: TorrentStatus](
                uniqueKeysWithValues: torrents.map { ($0.id, $0.status) }
            )
            return
        }
        for torrent in torrents {
            let previous = lastStatuses[torrent.id]
            lastStatuses[torrent.id] = torrent.status
            let wasIncomplete = previous.map { !$0.isDone } ?? false
            let nowComplete = torrent.status.isDone && torrent.progress >= 1
            guard wasIncomplete, nowComplete else { continue }
            sendCompletion(torrent)
        }
        // Drop entries for removed torrents.
        if lastStatuses.count > torrents.count + 32 {
            let ids = Set(torrents.map(\.id))
            lastStatuses = lastStatuses.filter { ids.contains($0.key) }
        }
    }

    private func sendCompletion(_ torrent: TorrentSummary) {
        // UNUserNotificationCenter.current() throws in test/bundle-less hosts.
        guard !isTestHost else { return }
        let content = UNMutableNotificationContent()
        content.title = "Download complete"
        content.body = torrent.name
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "drift.completion.\(torrent.id)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                writeProbeLog("[polish] notification failed \(error.localizedDescription)")
            }
        }
        writeProbeLog("[polish] completion notify \(torrent.name)")
    }
}
