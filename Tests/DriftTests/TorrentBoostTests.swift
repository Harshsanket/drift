import Foundation
import CryptoKit
import Testing
@testable import Drift

@Suite("Bencode parser")
struct BencodeTests {
    @Test func decodePrimitives() throws {
        #expect(try Bencode.decode(Data("i7e".utf8)).intValue == 7)
        #expect(try Bencode.decode(Data("5:hello".utf8)).stringValue == "hello")
        #expect(try Bencode.decode(Data("i-3e".utf8)).intValue == -3)
        #expect(try Bencode.decode(Data("i0e".utf8)).intValue == 0)
    }

    @Test func decodeListAndDict() throws {
        let list = try Bencode.decode(Data("l1:a2:bei2ee".utf8)).listValue
        #expect(list?.count == 3)
        #expect(list?.first?.stringValue == "a")
        #expect(list?.last?.intValue == 2)

        let dict = try Bencode.decode(Data("d2:aai1e3:bbb4:texle".utf8)).dictValue
        #expect(dict?["aa"]?.intValue == 1)
        #expect(dict?["bbb"]?.stringValue == "texl")
    }

    @Test func decodeNested() throws {
        let outer = try Bencode.decode(Data("ld1:ad2:xxi5eeee".utf8)).listValue
        let inner = outer?.first?.dictValue?["a"]?.dictValue
        #expect(inner?["xx"]?.intValue == 5)
    }

    @Test func rejectsMalformed() {
        #expect(throws: (any Error).self) { _ = try Bencode.decode(Data("i3xe".utf8)) }
        #expect(throws: (any Error).self) { _ = try Bencode.decode(Data("3:ab".utf8)) }
        #expect(throws: (any Error).self) { _ = try Bencode.decode(Data("i-e".utf8)) }
        #expect(throws: (any Error).self) {
            _ = try Bencode.decode(Data("i999999999999999999999e".utf8))
        }
    }
}

@Suite("Torrent meta + piece graph")
struct TorrentMetaTests {
    // MARK: mini bencode encoder (test-only)

    private static func enc(_ text: String) -> Data {
        Data("\(text.utf8.count):\(text)".utf8)
    }

    private static func enc(_ int: Int64) -> Data { Data("i\(int)e".utf8) }

    private static func encList(_ items: [Data]) -> Data {
        var out = Data("l".utf8)
        for item in items { out.append(item) }
        out.append(Data("e".utf8))
        return out
    }

    private static func encDict(_ entries: [(key: String, value: Data)]) -> Data {
        var out = Data("d".utf8)
        for entry in entries.sorted(by: { $0.key < $1.key }) {
            out.append(enc(entry.key))
            out.append(entry.value)
        }
        out.append(Data("e".utf8))
        return out
    }

    /// Deterministic payload byte for a global offset.
    private static func payloadByte(_ offset: Int64) -> UInt8 {
        UInt8(truncatingIfNeeded: offset &* 37 + 11)
    }

    private static func makeTorrent(
        pieceLength: Int64, fileLengths: [Int64],
        topLevel: Bool, urlList: [String] = []
    ) -> Data {
        let total = fileLengths.reduce(0, +)
        let pieceCount = Int((total + pieceLength - 1) / pieceLength)
        var pieces = Data()
        for piece in 0..<pieceCount {
            let start = Int64(piece) * pieceLength
            let end = min(total, start + pieceLength)
            var chunk = Data()
            for offset in start..<end { chunk.append(Self.payloadByte(offset)) }
            pieces.append(contentsOf: Insecure.SHA1.hash(data: chunk))
        }
        var infoEntries: [(key: String, value: Data)] = [
            ("name", enc("boosted.bin")),
            ("piece length", enc(pieceLength)),
            ("pieces", Data("\(pieces.count):".utf8) + pieces)
        ]
        if topLevel {
            infoEntries.append(("length", enc(total)))
        } else {
            var fileDicts: [Data] = []
            var cursor: Int64 = 0
            for (index, length) in fileLengths.enumerated() {
                let fileDict = encDict([
                    ("length", enc(length)),
                    ("path", encList([enc("part\(index).bin")]))
                ])
                fileDicts.append(fileDict)
                cursor += length
            }
            infoEntries.append(("files", encList(fileDicts)))
        }
        let info = encDict(infoEntries)
        var rootEntries: [(key: String, value: Data)] = [
            ("announce", enc("http://tracker.example/announce")),
            ("info", info)
        ]
        if !urlList.isEmpty {
            rootEntries.append(("url-list", encList(urlList.map(enc))))
        }
        return encDict(rootEntries)
    }

    @Test func singleFilePieceMap() throws {
        let data = Self.makeTorrent(pieceLength: 4, fileLengths: [12], topLevel: true)
        let meta = try TorrentMeta.decode(data)
        #expect(meta.name == "boosted.bin")
        #expect(meta.pieceCount == 3)
        #expect(meta.totalLength == 12)
        #expect(meta.files.count == 1)
        #expect(meta.files[0].path == "boosted.bin")
        #expect(!meta.isV2)

        let middle = meta.spans(forPiece: 1)
        #expect(middle.count == 1)
        #expect(middle[0].fileIndex == 0)
        #expect(middle[0].fileOffset == 4)
        #expect(middle[0].pieceOffset == 0)
        #expect(middle[0].length == 4)

        // Piece hash matches SHA-1 of the deterministic payload run.
        var chunk = Data()
        for offset in 8..<12 { chunk.append(Self.payloadByte(Int64(offset))) }
        #expect(meta.pieceHash(2) == Data(Insecure.SHA1.hash(data: chunk)))
        #expect(meta.pieceLengthFor(2) == 4)
    }

    @Test func multiFileSpanSplitsAcrossFiles() throws {
        let data = Self.makeTorrent(pieceLength: 4, fileLengths: [6, 6], topLevel: false)
        let meta = try TorrentMeta.decode(data)
        #expect(meta.files.count == 2)
        #expect(meta.files[1].offset == 6)

        let spans = meta.spans(forPiece: 1)
        #expect(spans.count == 2)
        #expect(spans[0].fileIndex == 0)
        #expect(spans[0].fileOffset == 4)
        #expect(spans[0].length == 2)
        #expect(spans[0].pieceOffset == 0)
        #expect(spans[1].fileIndex == 1)
        #expect(spans[1].fileOffset == 0)
        #expect(spans[1].length == 2)
        #expect(spans[1].pieceOffset == 2)
    }

    @Test func lastPieceIsShorter() throws {
        let data = Self.makeTorrent(pieceLength: 4, fileLengths: [10], topLevel: true)
        let meta = try TorrentMeta.decode(data)
        #expect(meta.pieceCount == 3)
        #expect(meta.pieceLengthFor(2) == 2)
        let spans = meta.spans(forPiece: 2)
        #expect(spans[0].length == 2)
        #expect(spans[0].pieceOffset == 0)
    }

    @Test func urlListFlattens() throws {
        let data = Self.makeTorrent(pieceLength: 4, fileLengths: [12], topLevel: true, urlList: [
            "http://a.example/boosted.bin",
            "https://b.example/other.bin"
        ])
        let meta = try TorrentMeta.decode(data)
        #expect(meta.urlList.count == 2)
        #expect(meta.urlList[1] == "https://b.example/other.bin")
    }

    @Test func v2LayoutIsFlagged() throws {
        let v2 = TorrentMetaTests.makeV2()
        var thrown: (any Error)?
        do { _ = try TorrentMeta.decode(v2) } catch { thrown = error }
        let unsupported = (thrown as? BoostError)?.errorDescription ?? ""
        #expect(unsupported.contains("v2 torrents can't be piece-boosted"))
    }

    private static func makeV2() -> Data {
        let fileTree = encDict([
            ("boosted.bin", encDict([
                ("length", enc(12)),
                ("pieces root", enc("01234567890123456789a"))
            ]))
        ])
        let info = encDict([
            ("file tree", fileTree),
            ("name", enc("boosted.bin")),
            ("piece length", enc(4))
        ])
        return encDict([
            ("announce", enc("http://tracker.example/announce")),
            ("info", info)
        ])
    }

    @Test func malformedMetadataThrows() {
        #expect(throws: (any Error).self) { _ = try TorrentMeta.decode(Data("de".utf8)) }
        #expect(throws: (any Error).self) {
            _ = try TorrentMeta.decode(Data("d1:ai1ee".utf8))
        }
    }
}

@Suite("Boost eligibility")
struct BoostEligibilityTests {
    @Test func eligibilityNeedsSeeds() {
        let none = BoostEligibility(webSeedCount: 0, seeds: [], fresh: Date())
        #expect(!none.boostable)
        let some = BoostEligibility(webSeedCount: 2, seeds: ["http://a"], fresh: Date())
        #expect(some.boostable)
    }
}
