import XCTest
@testable import Drift

final class ExternalSearchTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDown() {
        StubURLProtocol.handler = nil
        session.invalidateAndCancel()
        session = nil
        super.tearDown()
    }

    func testJackettParsingAndRequestShape() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v2.0/indexers/all/results")
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertTrue(items.contains { $0.name == "apikey" && $0.value == "SENTINEL" })
            XCTAssertTrue(items.contains { $0.name == "Query" && $0.value == "ubuntu" })
            let body = """
            {"Results":[
              {"Title":"Ubuntu ISO","MagnetUri":"magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567","Size":123456,"Seeders":12,"Peers":3,"Tracker":"Example","Details":"https://example.test/details/1"},
              {"Title":"Smaller","Link":"https://example.test/file.torrent","Size":12,"Seeders":1,"Peers":0,"Tracker":"Other"}
            ]}
            """
            return (200, Data(body.utf8))
        }
        let client = ExternalSearchClient(session: session)
        let results = try await client.search(
            configuration: ExternalSearchConfiguration(
                baseURL: "http://127.0.0.1:9117",
                apiKey: "SENTINEL"
            ),
            query: "ubuntu",
            category: "all"
        )
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results.first?.fileName, "Ubuntu ISO")
        XCTAssertEqual(results.first?.seeders, 12)
        XCTAssertEqual(results.first?.fileSize, 123456)
        XCTAssertEqual(results.first?.engineName, "Example")
        XCTAssertEqual(results.first?.siteURL, "https://example.test/details/1")
        XCTAssertEqual(results.last?.seeders, 1)
    }

    func testProwlarrParsingAndAPIKeyOnSameHostDownload() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/search")
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertTrue(items.contains { $0.name == "apikey" && $0.value == "SENTINEL" })
            XCTAssertTrue(items.contains { $0.name == "query" && $0.value == "debian" })
            XCTAssertTrue(items.contains { $0.name == "type" && $0.value == "search" })
            let body = """
            [{"title":"Debian Netinst","size":654321,"seeders":9,"leechers":2,
              "downloadUrl":"http://127.0.0.1:9696/download/1",
              "infoUrl":"https://example.test/debian",
              "indexer":"ExampleIndexer",
              "categories":[{"name":"Linux"}]}]
            """
            return (200, Data(body.utf8))
        }
        let client = ExternalSearchClient(session: session)
        let results = try await client.search(
            configuration: ExternalSearchConfiguration(
                baseURL: "http://127.0.0.1:9696/",
                apiKey: "SENTINEL"
            ),
            query: "debian",
            category: "all"
        )
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.fileName, "Debian Netinst")
        XCTAssertEqual(results.first?.seeders, 9)
        XCTAssertEqual(results.first?.engineName, "ExampleIndexer · Linux")
        XCTAssertTrue(results.first?.fileURL.contains("apikey=SENTINEL") == true)
    }

    func testHTTPErrorSurfaces() async throws {
        StubURLProtocol.handler = { _ in (500, Data()) }
        let client = ExternalSearchClient(session: session)
        do {
            _ = try await client.search(
                configuration: ExternalSearchConfiguration(
                    baseURL: "http://127.0.0.1:9117",
                    apiKey: "SENTINEL"
                ),
                query: "x",
                category: "all"
            )
            XCTFail("expected error")
        } catch ExternalSearchError.badStatus(500) {
            // expected
        }
    }
}

/// URLSession stub for deterministic external-search tests.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
