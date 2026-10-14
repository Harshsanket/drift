import Testing
@testable import Drift

@Suite("DesignSystem.Format")
struct FormatTests {
    @Test func zeroSpeedIsStable() {
        #expect(DesignSystem.Format.speed(0) == "0 B/s")
    }

    @Test func positiveSpeedsArePerSecond() {
        let text = DesignSystem.Format.speed(2_100_000)
        #expect(text.hasSuffix("/s"))
        #expect(text != "0 B/s")
    }

    @Test func etaFallbacks() {
        #expect(DesignSystem.Format.eta(nil) == "∞")
        #expect(DesignSystem.Format.eta(-1) == "∞")
        #expect(DesignSystem.Format.eta(400_000) == "∞")
        #expect(DesignSystem.Format.eta(90) == "1m 30s")
        #expect(DesignSystem.Format.eta(3_725) == "1h 02m")
    }

    @Test func durationFormatting() {
        #expect(DesignSystem.Format.duration(0) == "—")
        #expect(DesignSystem.Format.duration(42) == "42s")
        #expect(DesignSystem.Format.duration(90) == "1m 30s")
        #expect(DesignSystem.Format.duration(3_725) == "1h 02m")
        #expect(DesignSystem.Format.duration(90_061) == "1d 1h")
    }

    @Test func percentFormatting() {
        #expect(DesignSystem.Format.percent(0.42) == "42%")
        #expect(DesignSystem.Format.percent(1) == "100%")
    }
}

@Suite("StatusFilter")
struct StatusFilterTests {
    private func torrent(_ status: TorrentStatus) -> TorrentSummary {
        TorrentSummary(
            id: "id-\(status.rawValue)", name: "t-\(status.rawValue)",
            status: status, progress: 0.5, size: 1, downloadSpeed: 0,
            uploadSpeed: 0, eta: nil, timeActive: 0, category: nil, tags: []
        )
    }

    @Test func allMatchesEverything() {
        #expect(StatusFilter.all.matches(torrent(.downloading)))
        #expect(StatusFilter.all.matches(torrent(.seeding)))
        #expect(StatusFilter.all.matches(torrent(.completed)))
        #expect(StatusFilter.all.matches(torrent(.stopped)))
        #expect(StatusFilter.all.matches(torrent(.stalled)))
    }

    @Test func exactStatusMatch() {
        #expect(StatusFilter.downloading.matches(torrent(.downloading)))
        #expect(!StatusFilter.downloading.matches(torrent(.stalled)))
        #expect(StatusFilter.seeding.matches(torrent(.seeding)))
        #expect(StatusFilter.stopped.matches(torrent(.stopped)))
        #expect(StatusFilter.stalled.matches(torrent(.stalled)))
        #expect(StatusFilter.completed.matches(torrent(.completed)))
    }
}
