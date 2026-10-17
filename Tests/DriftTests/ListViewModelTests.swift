import Foundation
import Testing
@testable import Drift

/// Minimal in-memory engine so the model can be exercised without a network.
private final class StubEngine: TorrentEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var store: [TorrentSummary]

    init(_ torrents: [TorrentSummary]) {
        store = torrents
    }

    func loadTorrents() -> [TorrentSummary] {
        lock.withLock { store }
    }

    func loadDetails(for id: String) -> TorrentDetails {
        let summary = lock.withLock { store.first { $0.id == id } }
            ?? TorrentSummary(
                id: id, name: id, status: .downloading, progress: 0, size: 0,
                downloadSpeed: 0, uploadSpeed: 0, eta: nil, category: nil, tags: []
            )
        return TorrentDetails(
            general: GeneralInfo(
                hash: summary.id,
                savePath: "/tmp",
                addedOn: Date(),
                completedOn: nil,
                comment: "",
                downloaded: 0,
                uploaded: 0,
                piecesTotal: 0,
                piecesHave: 0
            ),
            trackers: [],
            peers: [],
            webSeeds: [],
            files: [
                FileRow(
                    name: summary.name, size: summary.size,
                    progress: summary.progress, priority: .normal
                )
            ]
        )
    }

    func fetchDetails(for id: String) async -> TorrentDetails {
        loadDetails(for: id)
    }

    func setFilePriority(id: String, fileIndex: Int, priority: FilePriority) {}

    func addTorrent(source: AddSource, savePath: String) -> TorrentSummary {
        let summary = TorrentSummary(
            id: "stub-\(UUID().uuidString.prefix(8))", name: "Stub Added",
            status: .downloading, progress: 0, size: 0,
            downloadSpeed: 0, uploadSpeed: 0, eta: nil, category: nil, tags: []
        )
        lock.withLock { store.insert(summary, at: 0) }
        return summary
    }

    func start(ids: [String]) {
        lock.withLock {
            for index in store.indices
            where ids.contains(store[index].id) && store[index].status == .stopped {
                store[index].status = .downloading
                store[index].downloadSpeed = 1_000
            }
        }
    }

    func stop(ids: [String]) {
        lock.withLock {
            for index in store.indices
            where ids.contains(store[index].id) && store[index].status != .stopped {
                store[index].status = .stopped
                store[index].downloadSpeed = 0
            }
        }
    }

    func remove(ids: [String], deleteFiles: Bool) {
        lock.withLock { store.removeAll { ids.contains($0.id) } }
    }
}

private func summary(
    _ id: String,
    _ name: String,
    _ status: TorrentStatus,
    progress: Double = 0,
    size: Int64 = 1_000,
    downloadSpeed: Int64 = 0,
    uploadSpeed: Int64 = 0
) -> TorrentSummary {
    TorrentSummary(
        id: id, name: name, status: status, progress: progress, size: size,
        downloadSpeed: downloadSpeed, uploadSpeed: uploadSpeed, eta: nil,
        category: nil, tags: []
    )
}

private let stubTorrents: [TorrentSummary] = [
    summary("a", "ubuntu-26.04-desktop-amd64.iso", .downloading, progress: 0.42, downloadSpeed: 2_100_000, uploadSpeed: 120_000),
    summary("b", "fedora-workstation.iso", .downloading, progress: 0.67),
    summary("c", "opensuse-leap.iso", .downloading, progress: 0.90),
    summary("d", "linuxmint.iso", .seeding, progress: 1, uploadSpeed: 340_000),
    summary("e", "debian-netinst.iso", .seeding, progress: 1),
    summary("f", "archlinux.iso", .completed, progress: 1),
    summary("g", "gentoo-stage3.iso", .stopped, progress: 0.15),
    summary("h", "alpine-virt.iso", .stalled, progress: 0.33),
]

@MainActor
private func connectedModel() -> ListViewModel {
    ListViewModel(engine: StubEngine(stubTorrents), connectionState: .connected(version: "test"))
}

@MainActor
@Suite("ListViewModel")
struct ListViewModelTests {
    @Test func disconnectedModelHasNoTorrentsAndNoActions() {
        let model = ListViewModel(engine: nil, connectionState: .disconnected)
        #expect(model.torrents.isEmpty)
        #expect(!model.isConnected)
        #expect(!model.canPauseAll)
        #expect(!model.canResumeAll)
        model.pauseAll()
        #expect(model.torrents.isEmpty)
    }

    @Test func countsAndStatusFilters() {
        let model = connectedModel()
        let torrents = model.torrents
        #expect(torrents.count == stubTorrents.count)
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
        let model = connectedModel()
        #expect(model.canPauseAll)
        #expect(model.canResumeAll)
    }

    @Test func transferStatsMatch() {
        let model = connectedModel()
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
        let model = connectedModel()
        model.searchText = "ubuntu-26.04"
        #expect(model.filtered.count == 1)
        model.searchText = "zzz-not-present-zzz"
        #expect(model.filtered.isEmpty)
        model.searchText = ""
        #expect(model.filtered.count == model.torrents.count)
    }

    @Test func pauseAllAndResumeAllRoundTrip() {
        let model = connectedModel()
        model.pauseAll()
        #expect(model.torrents.allSatisfy { $0.status == .stopped })
        #expect(!model.canPauseAll)
        model.resumeAll()
        #expect(model.canPauseAll)
        #expect(!model.canResumeAll)
    }
}
