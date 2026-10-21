import Foundation
import Observation

/// qBEE-inspired anti-leech rules. Decides which peers look leechy;
/// enforcement goes through the server's banned_IPs preference (stock qB
/// has no per-peer ban endpoint). Shadow mode logs decisions without
/// banning.
@MainActor
@Observable
final class LeechGuard {
    static let shared = LeechGuard()

    private static let storageKey = "drift.leechConfig"

    enum Mode: String, CaseIterable, Identifiable, Codable {
        case off
        case shadow
        case live

        var id: String { rawValue }

        var label: String {
            switch self {
            case .off: "Off"
            case .shadow: "Shadow (log only)"
            case .live: "Auto-ban"
            }
        }
    }

    struct Config: Sendable, Equatable, Codable {
        var mode: Mode = .shadow
        var banLeecherClients = true
        var leecherClients: [String] = Defaults.leecherClients
        var banIdleLeechers = true
        var idleMinutes = 15
        var banUnknownCountry = false
        var banMediaPlayers = false
        var playerClients: [String] = []
        var whitelistClients: [String] = []
        var whitelistIPs: [String] = []
    }

    enum Defaults {
        /// qBEE-style leecher families: Xunlei, QQ, Baidu, Xfplay, DLBT,
        /// and offline downloaders. Matching is case-insensitive
        /// contains-bookmark on the client name.
        static let leecherClients = [
            "xunlei", "thunder", "xl0012", "xl0016", "xl0019",
            "qqdownload", "qqpcmgr", "baidunetdisk", "baidu",
            "xfplay", "dlbt", "dl37", "offline downloader", "offline",
        ]
    }

    struct Violation: Equatable, Identifiable {
        var id: String { "\(time.timeIntervalSince1970)|\(ip)|\(reason)" }
        var ip: String
        var client: String
        var reason: String
        var matched: String
        var time: Date
    }

    var config = Config()

    private init() {
        config = Self.loadConfig()
    }

    /// Most-recent-first decisions log (shadow + live + manual), capped.
    private(set) var log: [Violation] = []

    /// Where bans get executed; wired to the connected engine by the app
    /// root so the guard stays engine-agnostic.
    var performBan: (([String]) async -> Void)?
    var serverBans: (() async -> [String])?
    var performUnban: (([String]) async -> Void)?

    /// Peer id -> first tick we saw it (drives the idle-leech timer).
    private var firstSeen: [String: Date] = [:]

    func review(details: TorrentDetails) {
        guard config.mode != .off else { return }
        let now = Date()
        let current = Set(details.peers.map(\.id))
        firstSeen = firstSeen.filter { current.contains($0.key) }

        var violations: [Violation] = []
        for row in details.peers {
            let since = firstSeen[row.id] ?? now
            firstSeen[row.id] = since
            if let violation = Self.violation(
                for: row, config: config, now: now, seenSince: since
            ) {
                violations.append(violation)
            }
        }
        guard !violations.isEmpty else { return }

        append(violations, reasonPrefix: config.mode == .live ? "auto-banned" : "shadow")

        if config.mode == .live {
            let ips = Array(Set(violations.map(\.ip)))
            ips.forEach { writeProbeLog("[leechguard] ban ip=\($0)") }
            Task { await performBan?(ips) }
        }
    }

    func recordBans(_ ips: [String], reason: String) {
        guard !ips.isEmpty else { return }
        let entries = ips.map {
            Violation(ip: $0, client: "", reason: reason, matched: "", time: Date())
        }
        append(entries, reasonPrefix: reason)
    }

    func clearLog() {
        log.removeAll()
        writeProbeLog("[leechguard] log cleared")
    }

    func save() {
        Self.persist(config)
        writeProbeLog("[leechguard] config saved mode=\(config.mode.rawValue)")
    }

    // MARK: - Log

    private func append(_ entries: [Violation], reasonPrefix: String) {
        var entries = entries
        if config.mode == .shadow && reasonPrefix != "manual" && reasonPrefix != "unbanned" {
            entries = entries.map { violation in
                var copy = violation
                copy.reason = "\(violation.reason) (shadow)"
                return copy
            }
        }
        log.insert(contentsOf: entries, at: 0)
        if log.count > 200 {
            log.removeFirst(log.count - 200)
        }
    }

    // MARK: - Pure rule evaluation

    nonisolated static func violation(
        for row: PeerRow,
        config: Config,
        now: Date,
        seenSince: Date?
    ) -> Violation? {
        guard !whitelisted(row: row, config: config) else { return nil }

        if config.banLeecherClients,
           let matched = clientMatch(row: row, patterns: config.leecherClients) {
            return Violation(
                ip: row.ip, client: row.client,
                reason: "leecher client", matched: matched, time: now
            )
        }

        if config.banMediaPlayers, !config.playerClients.isEmpty,
           let matched = clientMatch(row: row, patterns: config.playerClients) {
            return Violation(
                ip: row.ip, client: row.client,
                reason: "media player", matched: matched, time: now
            )
        }

        if config.banUnknownCountry,
           row.client.isEmpty,
           row.countryCode.lowercased() == "cn" {
            return Violation(
                ip: row.ip, client: row.client,
                reason: "unknown client from CN", matched: "", time: now
            )
        }

        let idle = max(1, config.idleMinutes) * 60
        if config.banIdleLeechers,
           let since = seenSince,
           now.timeIntervalSince(since) >= Double(idle),
           row.downloaded == 0, row.uploaded == 0,
           row.downSpeed == 0, row.upSpeed == 0 {
            return Violation(
                ip: row.ip, client: row.client,
                reason: "no transfer for \(config.idleMinutes) min",
                matched: "", time: now
            )
        }

        return nil
    }

    nonisolated static func whitelisted(row: PeerRow, config: Config) -> Bool {
        let client = row.client.lowercased()
        if config.whitelistClients.contains(where: { pattern in
            let trimmed = pattern.lowercased().trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && client.contains(trimmed)
        }) {
            return true
        }
        return config.whitelistIPs.contains { ip(row.ip, matchesEntry: $0) }
    }

    nonisolated static func clientMatch(row: PeerRow, patterns: [String]) -> String? {
        let hay = row.client.lowercased()
        guard !hay.isEmpty else { return nil }
        return patterns.first { pattern in
            let trimmed = pattern.lowercased().trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && hay.contains(trimmed)
        }
    }

    /// IP whitelist entry: exact "a.b.c.d" or CIDR "a.b.c.d/bits" (IPv4).
    nonisolated static func ip(_ candidate: String, matchesEntry entry: String) -> Bool {
        let entry = entry.trimmingCharacters(in: .whitespaces)
        guard !entry.isEmpty else { return false }
        if !entry.contains("/") {
            return candidate == entry
        }
        let parts = entry.split(separator: "/", maxSplits: 1)
        guard parts.count == 2,
              let bits = Int(parts[1]), (0...32).contains(bits),
              let candidateNet = Self.ipv4(candidate),
              let entryNet = Self.ipv4(String(parts[0]))
        else { return false }
        let mask = bits == 0 ? 0 : ~UInt32(0) << (32 - bits)
        return (candidateNet & mask) == (entryNet & mask)
    }

    private nonisolated static func ipv4(_ text: String) -> UInt32? {
        let octets = text.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return nil }
        var value: UInt32 = 0
        for octet in octets {
            guard let Byte = UInt8(octet) else { return nil }
            value = value << 8 | UInt32(Byte)
        }
        return value
    }

    // MARK: - Persistence

    private static func loadConfig() -> Config {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            return Config()
        }
        do {
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            writeProbeLog("[leechguard] config decode failed, using defaults")
            return Config()
        }
    }

    private static func persist(_ config: Config) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
