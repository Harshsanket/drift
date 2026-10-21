import Foundation
import Testing
@testable import Drift

@Suite("Booster chunk split")
struct BoosterPlanTests {
    @Test func splitsEvenlyWithRemainderOnLastLane() {
        let chunks = DirectDownload.plan(total: 1000, streams: 4)
        #expect(chunks.count == 4)
        #expect(chunks.map(\.offset) == [0, 250, 500, 750])
        #expect(chunks[3].length == 250)
        #expect(chunks.map(\.length).reduce(0, +) == 1000)
        #expect(chunks.map(\.index) == [0, 1, 2, 3])
    }

    @Test func oddTotalGivesRemainderToLastLane() {
        let chunks = DirectDownload.plan(total: 7, streams: 3)
        #expect(chunks.map(\.length) == [2, 2, 3])
        #expect(chunks.map(\.offset) == [0, 2, 4])
        #expect(chunks.reduce(Int64(0)) { $0 + $1.length } == 7)
    }

    @Test func nonPositiveTotalYieldsNoChunks() {
        #expect(DirectDownload.plan(total: 0, streams: 4).isEmpty)
        #expect(DirectDownload.plan(total: -5, streams: 8).isEmpty)
    }

    @Test func atLeastOneLaneAndStreamsCappedByTotalNotByLanes() {
        // streams below one is clamped to one lane.
        let single = DirectDownload.plan(total: 500, streams: 0)
        #expect(single.count == 1)
        #expect(single.first?.length == 500)
        // More lanes than bytes: each lane still gets a chunk (some tiny).
        let many = DirectDownload.plan(total: 10, streams: 16)
        #expect(many.count == 16)
        #expect(many.allSatisfy { $0.length >= 0 })
    }

    @Test func offsetsAreContiguousAcrossLanes() {
        let chunks = DirectDownload.plan(total: 9_999, streams: 6)
        var expected: Int64 = 0
        for chunk in chunks {
            #expect(chunk.offset == expected)
            expected += chunk.length
        }
        #expect(expected == 9_999)
    }
}

@Suite("Booster sidecar state", .serialized)
struct DownloadSidecarTests {
    private func makeRecord(
        id: String = "test-\(UUID().uuidString)",
        total: Int64 = 1000,
        chunks: [DownloadSidecar.Chunk]
    ) -> DownloadSidecar {
        DownloadSidecar(
            id: id,
            url: URL(string: "https://example.com/file.iso")!,
            destination: "/tmp",
            fileName: "file.iso",
            etag: "\"abc\"",
            total: total,
            chunks: chunks,
            streams: 4,
            allowCellular: false,
            slowModeMbps: 4
        )
    }

    @Test func writtenTotalSumsChunks() {
        let record = makeRecord(chunks: [
            .init(index: 0, offset: 0, length: 400, written: 400),
            .init(index: 1, offset: 400, length: 400, written: 100),
            .init(index: 2, offset: 800, length: 200, written: 0),
        ])
        #expect(record.writtenTotal == 500)
        #expect(!record.isComplete)
    }

    @Test func fullBitmapCountsCompleteButEmptyBitmapDoesNot() {
        let empty = makeRecord(chunks: [])
        #expect(!empty.isComplete)

        let full = makeRecord(chunks: [
            .init(index: 0, offset: 0, length: 400, written: 400),
            .init(index: 1, offset: 400, length: 600, written: 600),
        ])
        #expect(full.isComplete)
    }

    @Test func persistRoundTripAndForget() throws {
        let record = makeRecord(chunks: [
            .init(index: 0, offset: 0, length: 100, written: 64),
            .init(index: 1, offset: 100, length: 900, written: 12),
        ])
        DownloadSidecar.persist(record)
        let restored = DownloadSidecar.storedRecords().first { $0.id == record.id }
        #expect(restored?.writtenTotal == 76)
        #expect(restored?.etag == "\"abc\"")
        #expect(restored?.chunks.count == 2)

        DownloadSidecar.forget(id: record.id)
        #expect(
            DownloadSidecar.storedRecords().first { $0.id == record.id } == nil,
            "forget must drop the record from store and id list"
        )
    }

    @Test func forgetUnknownIdIsHarmless() {
        DownloadSidecar.forget(id: "nope-\(UUID().uuidString)")
        #expect(true)
    }
}
