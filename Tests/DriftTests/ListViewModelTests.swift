import Testing
@testable import Drift

@MainActor
@Suite("ListViewModel (mock engine)")
struct ListViewModelTests {
    @Test func countsAndStatusFilters() {
        let model = ListViewModel(engine: MockTorrentEngine())
        let torrents = model.torrents
        #expect(torrents.count == TorrentFixture.torrents.count)
        #expect(model.count(for: .all) == torrents.count)
        #expect(model.count(for: .downloading) == 3)
        #expect(model.count(for: .seeding) == 2)
        #expect(model.count(for: .stopped) == 1)
        #expect(model.count(for: .stalled) == 1)
        #expect(model.count(for: .completed) == 1)

        model.statusFilter = .downloading
        #expect(model.filtered.allSatisfy { $0.status == .downloading })
        #expect(model.filtered.count == 3)
        model.statusFilter = .all
        #expect(model.filtered.count == torrents.count)
    }

    @Test func pauseResumeEligibility() {
        let model = ListViewModel(engine: MockTorrentEngine())
        #expect(model.canPauseAll)
        #expect(model.canResumeAll)
    }

    @Test func transferStatsMatchFixture() {
        let model = ListViewModel(engine: MockTorrentEngine())
        let stats = model.transferStats()
        let expectedDownloading = model.torrents.filter { $0.status == .downloading }.count
        let expectedSeeding = model.torrents.filter { $0.status == .seeding }.count
        let expectedProgress =
            model.torrents.reduce(0.0) { $0 + $1.progress } / Double(model.torrents.count)
        #expect(stats.downloading == expectedDownloading)
        #expect(stats.seeding == expectedSeeding)
        #expect(abs(stats.progress - expectedProgress) < 1e-9)
        #expect(model.globalDownloadSpeed == model.torrents.reduce(0) { $0 + $1.downloadSpeed })
        #expect(model.globalUploadSpeed == model.torrents.reduce(0) { $0 + $1.uploadSpeed })
    }

    @Test func searchNarrowsResults() {
        let model = ListViewModel(engine: MockTorrentEngine())
        model.searchText = "ubuntu-26.04"
        #expect(model.filtered.count == 1)
        model.searchText = "zzz-not-present-zzz"
        #expect(model.filtered.isEmpty)
        model.searchText = ""
        #expect(model.filtered.count == model.torrents.count)
    }

    @Test func pauseAllAndResumeAllRoundTrip() {
        let model = ListViewModel(engine: MockTorrentEngine())
        model.pauseAll()
        #expect(model.torrents.allSatisfy { $0.status == .stopped })
        #expect(!model.canPauseAll)
        model.resumeAll()
        #expect(model.canPauseAll)
        #expect(!model.canResumeAll)
    }
}
