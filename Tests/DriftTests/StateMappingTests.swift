import Foundation
import Testing
@testable import Drift

@Suite("WebAPI state mapping")
struct StateMappingTests {
    @Test(arguments: [
        ("downloading", TorrentStatus.downloading),
        ("forcedDL", TorrentStatus.downloading),
        ("metaDL", TorrentStatus.downloading),
        ("forcedMetaDL", TorrentStatus.downloading),
        ("allocating", TorrentStatus.downloading),
        ("stalledDL", TorrentStatus.stalled),
        ("uploading", TorrentStatus.seeding),
        ("forcedUP", TorrentStatus.seeding),
        ("stalledUP", TorrentStatus.seeding),
        ("stoppedDL", TorrentStatus.stopped),
        ("stoppedUP", TorrentStatus.stopped),
        ("pausedDL", TorrentStatus.stopped),
        ("pausedUP", TorrentStatus.stopped),
        ("queuedDL", TorrentStatus.queued),
        ("queuedUP", TorrentStatus.queued),
        ("checkingDL", TorrentStatus.checking),
        ("checkingUP", TorrentStatus.checking),
        ("checkingResumeData", TorrentStatus.checking),
        ("moving", TorrentStatus.moving),
        ("error", TorrentStatus.error),
        ("missingFiles", TorrentStatus.error),
    ])
    func qBStateMapsToDriftStatus(_ state: String, _ expected: TorrentStatus) {
        #expect(WebAPIEngine.status(state: state, progress: 0) == expected)
    }

    @Test func fallbackUsesProgress() {
        #expect(WebAPIEngine.status(state: "", progress: 1) == .seeding)
        #expect(WebAPIEngine.status(state: "garbage", progress: 0.5) == .downloading)
    }

    @Test func summaryFieldsPopulateFromSyncData() {
        let fields: [String: Any] = [
            "name": "ubuntu.iso",
            "state": "uploading",
            "progress": 1.0,
            "ratio": 2.4,
            "num_complete": 7,
            "num_incomplete": 3,
            "availability": 1.5,
            "downloaded": 1_000_000,
            "uploaded": 2_400_000,
            "save_path": "/srv/torrents",
            "added_on": 1_700_000_000.0,
            "category": "linux",
            "tags": "iso cloud",
        ]
        let summary = WebAPIEngine.summary(id: "abc", fields: fields)
        #expect(summary.status == .seeding)
        #expect(summary.ratio == 2.4)
        #expect(summary.seeds == 7)
        #expect(summary.peers == 3)
        #expect(summary.availability == 1.5)
        #expect(summary.downloaded == 1_000_000)
        #expect(summary.uploaded == 2_400_000)
        #expect(summary.savePath == "/srv/torrents")
        #expect(summary.addedOn == 1_700_000_000)
        #expect(summary.category == "linux")
        #expect(summary.tags == ["iso", "cloud"])
    }
}
