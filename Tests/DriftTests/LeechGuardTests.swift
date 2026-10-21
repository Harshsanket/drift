import Foundation
import Testing
@testable import Drift

@Suite("Banned IP preference shaping")
struct BannedIPsShapingTests {
    @Test("split trims whitespace and drops empties")
    func split() {
        #expect(
            WebAPIEngine.splitBannedIPs(" 1.1.1.1 \n\n9.9.9.9\n") == ["1.1.1.1", "9.9.9.9"]
        )
    }

    @Test("merge keeps server order, appends new, dedupes")
    func merge() {
        #expect(
            WebAPIEngine.mergeBannedIPs(
                existing: ["1.1.1.1", " 2.2.2.2 "], new: ["2.2.2.2", "3.3.3.3", ""]
            )
                == ["1.1.1.1", "2.2.2.2", "3.3.3.3"]
        )
    }

    @Test("remove clears matching entries and keeps others")
    func remove() {
        #expect(
            WebAPIEngine.removeBannedIPs(
                existing: ["1.1.1.1", "2.2.2.2", "3.3.3.3"],
                remove: [" 2.2.2.2 ", "5.5.5.5"]
            )
                == ["1.1.1.1", "3.3.3.3"]
        )
    }
}

@Suite("LeechGuard policy")
struct LeechGuardPolicyTests {
    private var config: LeechGuard.Config {
        var config = LeechGuard.Config()
        config.leecherClients = ["xunlei", "baidu", "xfplay"]
        config.idleMinutes = 15
        return config
    }

    private func makeRow(
        ip: String = "9.9.9.9",
        client: String = "qBittorrent 5.2",
        countryCode: String = "zz",
        downloaded: Int64 = 0,
        uploaded: Int64 = 0,
        downSpeed: Int64 = 0
    ) -> PeerRow {
        PeerRow(
            ip: ip, port: 6881, client: client, flags: "", connection: "",
            progress: 0, downSpeed: downSpeed, upSpeed: 0,
            country: "", countryCode: countryCode,
            downloaded: downloaded, uploaded: uploaded
        )
    }

    private var baseDate: Date { Date(timeIntervalSince1970: 1_000_000) }

    @Test("known leecher client is flagged with matched pattern")
    func leecherClient() {
        let violation = LeechGuard.violation(
            for: makeRow(client: "Xunlei everyone"), config: config,
            now: baseDate, seenSince: baseDate
        )
        #expect(violation?.reason == "leecher client")
        #expect(violation?.matched == "xunlei")
    }

    @Test("whitelisted client beats leecher pattern")
    func whitelistBeatsBan() {
        var config = config
        config.whitelistClients = ["thunderfox"]
        let violation = LeechGuard.violation(
            for: makeRow(client: "ThunderFox", countryCode: "cn"),
            config: config, now: baseDate, seenSince: baseDate
        )
        #expect(violation == nil)
    }

    @Test("empty client is never matched by contains patterns")
    func emptyClientSafe() {
        #expect(
            LeechGuard.violation(
                for: makeRow(client: ""), config: config,
                now: baseDate, seenSince: baseDate
            ) == nil
        )
    }

    @Test("idle rule requires observation window and zero traffic")
    func idleAfterObservation() {
        let row = makeRow()
        #expect(
            LeechGuard.violation(
                for: row, config: config,
                now: baseDate.addingTimeInterval(14 * 60), seenSince: baseDate
            ) == nil
        )
        let violation = LeechGuard.violation(
            for: row, config: config,
            now: baseDate.addingTimeInterval(15 * 60 + 1), seenSince: baseDate
        )
        #expect(violation?.reason.contains("no transfer") == true)
    }

    @Test("active transfers never trigger the idle rule")
    func activePeerNotIdle() {
        let row = makeRow(downloaded: 1, uploaded: 1, downSpeed: 100)
        #expect(
            LeechGuard.violation(
                for: row, config: config,
                now: baseDate.addingTimeInterval(60 * 60), seenSince: baseDate
            ) == nil
        )
    }

    @Test("China unknown-client rule fires only when enabled")
    func chinaUnknown() {
        var config = config
        config.banUnknownCountry = true
        let violation = LeechGuard.violation(
            for: makeRow(client: "", countryCode: "cn"),
            config: config, now: baseDate, seenSince: baseDate
        )
        #expect(violation?.reason == "unknown client from CN")

        config.banUnknownCountry = false
        #expect(
            LeechGuard.violation(
                for: makeRow(client: "", countryCode: "cn"),
                config: config, now: baseDate, seenSince: baseDate
            ) == nil
        )
    }

    @Test("CIDR whitelist matches ranges and rejects non-members")
    func cidrWhitelist() {
        #expect(LeechGuard.ip("192.168.1.55", matchesEntry: "192.168.1.0/24"))
        #expect(LeechGuard.ip("10.0.0.1", matchesEntry: "10.0.0.0/8"))
        #expect(!LeechGuard.ip("192.168.2.55", matchesEntry: "192.168.1.0/24"))
        #expect(LeechGuard.ip("1.2.3.4", matchesEntry: "1.2.3.4"))
        #expect(LeechGuard.ip("1.2.3.4", matchesEntry: " 1.2.3.4 "))
        #expect(!LeechGuard.ip("::1", matchesEntry: "1.2.3.0/24"))
    }

    @Test("media-player rule needs an explicit pattern list")
    func mediaPlayers() {
        var config = config
        config.banMediaPlayers = true
        #expect(
            LeechGuard.violation(
                for: makeRow(client: "Popcorn Time"), config: config,
                now: baseDate, seenSince: baseDate
            ) == nil
        )
        config.playerClients = ["popcorn"]
        let violation = LeechGuard.violation(
            for: makeRow(client: "Popcorn Time"), config: config,
            now: baseDate, seenSince: baseDate
        )
        #expect(violation?.reason == "media player")
    }
}
