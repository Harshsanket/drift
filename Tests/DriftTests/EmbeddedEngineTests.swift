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


    func testParityFlagsOrganizersAndBans() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let binary = root.appendingPathComponent("engine/build/drift-engine")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw XCTSkip("engine/build/drift-engine missing — run engine/build.sh first")
        }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("drift-embedded-parity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        stateDir = dir
        let socket = "/tmp/drift-embedded-\(UUID().uuidString.prefix(8)).sock"
        let embedded = EmbeddedEngine(
            stateDir: dir,
            socketPath: socket,
            binaryURL: binary
        )
        engine = embedded
        _ = try await embedded.start()

        let hash = "89abcdef0123456789abcdef0123456789abcdef"
        embedded.addTorrent(
            source: .magnetOrURL("magnet:?xt=urn:btih:\(hash)&dn=parity-test"),
            options: AddOptions()
        )
        let listed = try await waitUntil(timeout: 10) {
            embedded.loadTorrents().contains { $0.id == hash }
        }
        XCTAssertTrue(listed)

        embedded.createCategory(name: "DriftParity", savePath: "/tmp/drift-parity")
        embedded.createTags(["alpha", "beta"])
        embedded.setCategory(ids: [hash], category: "DriftParity")
        embedded.addTags(ids: [hash], tags: ["alpha"])

        let organized = try await waitUntil(timeout: 10) {
            guard let summary = embedded.loadTorrents().first(where: { $0.id == hash }) else { return false }
            return summary.category == "DriftParity" && summary.tags.contains("alpha")
        }
        XCTAssertTrue(organized, "category/tags did not reach the summary")
        XCTAssertTrue(embedded.categories().contains { $0.name == "DriftParity" })
        XCTAssertTrue(embedded.tags().contains("alpha"))

        embedded.toggleSequentialDownload(ids: [hash])
        embedded.setSuperSeeding(ids: [hash], enabled: true)
        embedded.setAutoManagement(ids: [hash], enabled: false)
        embedded.toggleFirstLastPiecePriority(ids: [hash])
        let flags = try await waitUntil(timeout: 10) {
            guard let summary = embedded.loadTorrents().first(where: { $0.id == hash }) else { return false }
            return summary.sequential
                && summary.superSeeding
                && !summary.autoManaged
                && summary.firstLastPiecePriority
        }
        XCTAssertTrue(flags, "engine flags did not round-trip")

        await embedded.banIPs(["203.0.113.9"])
        let banned = await embedded.bannedIPs()
        XCTAssertTrue(banned.contains("203.0.113.9"))
        await embedded.unbanIPs(["203.0.113.9"])
        let unbanned = await embedded.bannedIPs()
        XCTAssertFalse(unbanned.contains("203.0.113.9"))

        embedded.removeCategories(names: ["DriftParity"])
        embedded.deleteTags(["alpha", "beta"])
        let cleared = try await waitUntil(timeout: 10) {
            guard let summary = embedded.loadTorrents().first(where: { $0.id == hash }) else { return false }
            return summary.category == nil && summary.tags.isEmpty
        }
        XCTAssertTrue(cleared, "organizers did not clear")

        embedded.remove(ids: [hash], deleteFiles: false)
        let removed = try await waitUntil(timeout: 10) {
            embedded.loadTorrents().isEmpty
        }
        XCTAssertTrue(removed)
    }


    func testOrganizersAndBansSurviveRestart() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let binary = root.appendingPathComponent("engine/build/drift-engine")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw XCTSkip("engine/build/drift-engine missing — run engine/build.sh first")
        }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("drift-embedded-restart-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        stateDir = dir
        let socket = "/tmp/drift-embedded-\(UUID().uuidString.prefix(8)).sock"
        let hash = "fedcba9876543210fedcba9876543210fedcba98"

        var embedded = EmbeddedEngine(stateDir: dir, socketPath: socket, binaryURL: binary)
        engine = embedded
        _ = try await embedded.start()
        embedded.addTorrent(
            source: .magnetOrURL("magnet:?xt=urn:btih:\(hash)&dn=restart-test"),
            options: AddOptions()
        )
        _ = try await waitUntil(timeout: 10) { embedded.loadTorrents().contains { $0.id == hash } }

        embedded.createCategory(name: "Persisted", savePath: "/tmp/persisted")
        embedded.createTags(["keep-me"])
        embedded.setCategory(ids: [hash], category: "Persisted")
        embedded.addTags(ids: [hash], tags: ["keep-me"])
        await embedded.banIPs(["198.51.100.7"])
        _ = try await waitUntil(timeout: 10) {
            guard let summary = embedded.loadTorrents().first(where: { $0.id == hash }) else { return false }
            return summary.category == "Persisted" && summary.tags.contains("keep-me")
        }

        await embedded.stop()
        embedded = EmbeddedEngine(stateDir: dir, socketPath: socket, binaryURL: binary)
        engine = embedded
        _ = try await embedded.start()
        let restored = try await waitUntil(timeout: 10) {
            guard let summary = embedded.loadTorrents().first(where: { $0.id == hash }) else { return false }
            return summary.category == "Persisted" && summary.tags.contains("keep-me")
        }
        XCTAssertTrue(restored, "engine-owned category/tags did not survive restart")
        XCTAssertTrue(embedded.categories().contains { $0.name == "Persisted" })
        let bans = await embedded.bannedIPs()
        XCTAssertTrue(bans.contains("198.51.100.7"), "ban list did not survive restart")

        embedded.remove(ids: [hash], deleteFiles: false)
        _ = try await waitUntil(timeout: 10) { embedded.loadTorrents().isEmpty }
    }


    func testTorrentFileDetailsTrackersWebSeedsAndPriorities() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let binary = root.appendingPathComponent("engine/build/drift-engine")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw XCTSkip("engine/build/drift-engine missing — run engine/build.sh first")
        }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("drift-embedded-file-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        stateDir = dir
        let socket = "/tmp/drift-embedded-\(UUID().uuidString.prefix(8)).sock"
        let embedded = EmbeddedEngine(stateDir: dir, socketPath: socket, binaryURL: binary)
        engine = embedded
        _ = try await embedded.start()

        // Single-file fixture with one tracker and one url-list web seed.
        let torrentBase64 = "ZDg6YW5ub3VuY2UyNzpodHRwOi8vMTI3LjAuMC4xOjEvYW5ub3VuY2U0OmluZm9kNjpsZW5ndGhpMTAyNGU0Om5hbWU4OnRlc3QuYmluMTI6cGllY2UgbGVuZ3RoaTE2Mzg0ZTY6cGllY2VzMjA6AAAAAAAAAAAAAAAAAAAAAAAAAABlODp1cmwtbGlzdDIzOmh0dHA6Ly8xMjcuMC4wLjE6MS9maWxlZQ=="
        let torrentData = try XCTUnwrap(Data(base64Encoded: torrentBase64))
        let torrentURL = dir.appendingPathComponent("fixture.torrent")
        try torrentData.write(to: torrentURL)

        embedded.addTorrent(source: .torrentFile(torrentURL), options: AddOptions())
        let listed = try await waitUntil(timeout: 10) {
            embedded.loadTorrents().contains { $0.id.count == 40 }
        }
        XCTAssertTrue(listed)
        let hash = try XCTUnwrap(embedded.loadTorrents().first { $0.id.count == 40 }?.id)

        var details = await embedded.fetchDetails(for: hash)
        for _ in 0..<50 where details.files.isEmpty {
            try await Task.sleep(nanoseconds: 100_000_000)
            details = await embedded.fetchDetails(for: hash)
        }
        XCTAssertEqual(details.files.count, 1)
        XCTAssertEqual(details.files.first?.name, "test.bin")
        XCTAssertTrue(details.trackers.contains { $0.url.contains("127.0.0.1:1/announce") })
        XCTAssertTrue(details.webSeeds.contains { $0.url.contains("127.0.0.1:1/file") })

        embedded.setFilePriority(id: hash, fileIndex: 0, priority: .maximum)
        let priorityApplied = try await waitUntil(timeout: 10) {
            await embedded.fetchDetails(for: hash).files.first?.priority == .maximum
        }
        XCTAssertTrue(priorityApplied)

        embedded.recheck(ids: [hash])
        embedded.forceStart(ids: [hash])
        embedded.queue(ids: [hash], move: .top)
        embedded.setLocation(ids: [hash], location: dir.path)

        embedded.addTrackers(id: hash, urls: ["http://127.0.0.1:2/announce"])
        let trackerAdded = try await waitUntil(timeout: 10) {
            await embedded.fetchDetails(for: hash).trackers.contains { $0.url.contains("127.0.0.1:2/announce") }
        }
        XCTAssertTrue(trackerAdded)
        embedded.editTracker(
            id: hash,
            oldURL: "http://127.0.0.1:2/announce",
            newURL: "http://127.0.0.1:3/announce"
        )
        let trackerEdited = try await waitUntil(timeout: 10) {
            await embedded.fetchDetails(for: hash).trackers.contains { $0.url.contains("127.0.0.1:3/announce") }
        }
        XCTAssertTrue(trackerEdited)
        embedded.removeTrackers(id: hash, urls: ["http://127.0.0.1:3/announce"])
        let trackerRemoved = try await waitUntil(timeout: 10) {
            await !embedded.fetchDetails(for: hash).trackers.contains { $0.url.contains("127.0.0.1:3/announce") }
        }
        XCTAssertTrue(trackerRemoved)

        embedded.addWebSeeds(id: hash, urls: ["http://127.0.0.1:4/file"])
        let seedAdded = try await waitUntil(timeout: 10) {
            await embedded.fetchDetails(for: hash).webSeeds.contains { $0.url.contains("127.0.0.1:4/file") }
        }
        XCTAssertTrue(seedAdded)
        embedded.editWebSeed(
            id: hash,
            oldURL: "http://127.0.0.1:4/file",
            newURL: "http://127.0.0.1:5/file"
        )
        let seedEdited = try await waitUntil(timeout: 10) {
            await embedded.fetchDetails(for: hash).webSeeds.contains { $0.url.contains("127.0.0.1:5/file") }
        }
        XCTAssertTrue(seedEdited)
        embedded.removeWebSeeds(id: hash, urls: ["http://127.0.0.1:5/file"])
        let seedRemoved = try await waitUntil(timeout: 10) {
            await !embedded.fetchDetails(for: hash).webSeeds.contains { $0.url.contains("127.0.0.1:5/file") }
        }
        XCTAssertTrue(seedRemoved)

        embedded.rename(id: hash, name: "renamed.bin")
        let renamed = try await waitUntil(timeout: 10) {
            embedded.loadTorrents().first { $0.id == hash }?.name == "renamed.bin"
        }
        XCTAssertTrue(renamed)

        embedded.remove(ids: [hash], deleteFiles: false)
        _ = try await waitUntil(timeout: 10) { embedded.loadTorrents().isEmpty }
    }


    func testExternalSearchResultsFeedAdd() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let binary = root.appendingPathComponent("engine/build/drift-engine")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw XCTSkip("engine/build/drift-engine missing — run engine/build.sh first")
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("drift-embedded-search-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        stateDir = dir
        let socket = "/tmp/drift-embedded-\(UUID().uuidString.prefix(8)).sock"

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let hash = "cafebabe0123456789abcdef0123456789abcdef"
        StubURLProtocol.handler = { request in
            guard request.url?.path.contains("results") == true else { return (404, Data()) }
            let body = """
            {"Results":[{"Title":"Search Fixture","MagnetUri":"magnet:?xt=urn:btih:\(hash)","Size":42,"Seeders":7,"Peers":1,"Tracker":"Fixture"}]}
            """
            return (200, Data(body.utf8))
        }
        defer { StubURLProtocol.handler = nil }

        let embedded = EmbeddedEngine(
            stateDir: dir,
            socketPath: socket,
            binaryURL: binary,
            searchConfiguration: ExternalSearchConfiguration(
                baseURL: "http://127.0.0.1:9117",
                apiKey: "K"
            ),
            urlSession: session
        )
        engine = embedded
        _ = try await embedded.start()

        let searchID = await embedded.startSearch(pattern: "fixture", category: "all")
        let id = try XCTUnwrap(searchID)
        let finished = try await waitUntil(timeout: 10) {
            await embedded.searchResults(id: id)?.status == "Stopped"
        }
        XCTAssertTrue(finished)
        let searchResponse = await embedded.searchResults(id: id)
        let response = try XCTUnwrap(searchResponse)
        XCTAssertEqual(response.results.count, 1)
        let result = try XCTUnwrap(response.results.first)
        XCTAssertEqual(result.fileName, "Search Fixture")
        XCTAssertEqual(result.seeders, 7)

        embedded.addTorrent(source: .magnetOrURL(result.fileURL), options: AddOptions())
        let added = try await waitUntil(timeout: 10) {
            embedded.loadTorrents().contains { $0.id == hash }
        }
        XCTAssertTrue(added)
        embedded.remove(ids: [hash], deleteFiles: false)
        _ = try await waitUntil(timeout: 10) { embedded.loadTorrents().isEmpty }
    }

    func testTorrentURLAddFetchesBytes() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let binary = root.appendingPathComponent("engine/build/drift-engine")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw XCTSkip("engine/build/drift-engine missing — run engine/build.sh first")
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("drift-embedded-url-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        stateDir = dir
        let socket = "/tmp/drift-embedded-\(UUID().uuidString.prefix(8)).sock"

        let fixture = "ZDg6YW5ub3VuY2UyNzpodHRwOi8vMTI3LjAuMC4xOjEvYW5ub3VuY2U0OmluZm9kNjpsZW5ndGhpMTAyNGU0Om5hbWU4OnRlc3QuYmluMTI6cGllY2UgbGVuZ3RoaTE2Mzg0ZTY6cGllY2VzMjA6AAAAAAAAAAAAAAAAAAAAAAAAAABlODp1cmwtbGlzdDIzOmh0dHA6Ly8xMjcuMC4wLjE6MS9maWxlZQ=="
        let fixtureData = try XCTUnwrap(Data(base64Encoded: fixture))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        StubURLProtocol.handler = { _ in (200, fixtureData) }
        defer { StubURLProtocol.handler = nil }

        let embedded = EmbeddedEngine(
            stateDir: dir,
            socketPath: socket,
            binaryURL: binary,
            urlSession: session
        )
        engine = embedded
        _ = try await embedded.start()
        embedded.addTorrent(
            source: .magnetOrURL("http://127.0.0.1:9117/fixture.torrent"),
            options: AddOptions()
        )
        let added = try await waitUntil(timeout: 10) {
            embedded.loadTorrents().contains { $0.id.count == 40 }
        }
        XCTAssertTrue(added)
        let hash = try XCTUnwrap(embedded.loadTorrents().first { $0.id.count == 40 }?.id)
        XCTAssertEqual(embedded.loadTorrents().first { $0.id == hash }?.name, "test.bin")
        embedded.remove(ids: [hash], deleteFiles: false)
        _ = try await waitUntil(timeout: 10) { embedded.loadTorrents().isEmpty }
    }

    private func waitUntil(
        timeout: TimeInterval,
        condition: @escaping () async -> Bool
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return await condition()
    }
}
