import XCTest
@testable import Drift

final class EmbeddedEngineTests: XCTestCase {
    private var engine: EmbeddedEngine?
    private var stateDir: URL?

    override func tearDown() async throws {
        if let engine { await engine.stop() }
        if let stateDir { try? FileManager.default.removeItem(at: stateDir) }
        engine = nil
        stateDir = nil
        try await super.tearDown()
    }

    func testStartsListsAndRemovesTorrent() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let binary = root.appendingPathComponent("engine/build/drift-engine")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw XCTSkip("engine/build/drift-engine missing — run engine/build.sh first")
        }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("drift-embedded-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        stateDir = dir

        // Unix-domain socket paths are limited to ~104 bytes; the XCTest
        // temporary directory is too deep for that.
        let socket = "/tmp/drift-embedded-\(UUID().uuidString.prefix(8)).sock"
        let embedded = EmbeddedEngine(
            stateDir: dir,
            socketPath: socket,
            binaryURL: binary
        )
        engine = embedded

        let version = try await embedded.start()
        XCTAssertEqual(version, "embedded")
        XCTAssertTrue(embedded.isConnected)
        XCTAssertEqual(embedded.loadTorrents().count, 0)

        let hash = "0123456789abcdef0123456789abcdef01234567"
        let magnet = "magnet:?xt=urn:btih:\(hash)&dn=embedded-test"
        let placeholder = embedded.addTorrent(source: .magnetOrURL(magnet), options: AddOptions())
        XCTAssertEqual(placeholder.id, hash)

        let listed = try await waitUntil(timeout: 10) {
            embedded.loadTorrents().contains { $0.id == hash }
        }
        XCTAssertTrue(listed, "engine did not list the added magnet")

        embedded.stop(ids: [hash])
        try await Task.sleep(nanoseconds: 200_000_000)
        embedded.start(ids: [hash])
        try await Task.sleep(nanoseconds: 200_000_000)

        embedded.remove(ids: [hash], deleteFiles: false)
        let removed = try await waitUntil(timeout: 10) {
            embedded.loadTorrents().isEmpty
        }
        XCTAssertTrue(removed, "engine did not remove the torrent")
    }

    private func waitUntil(
        timeout: TimeInterval,
        condition: @escaping () -> Bool
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return condition()
    }
}
