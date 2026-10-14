import Foundation

enum WebAPIError: Error {
    case invalidURL
    case badStatus(Int)
    case authFailed
    case notQBitTorrent
    case network(String)

    var message: String {
        switch self {
        case .invalidURL: "Invalid Web UI URL"
        case .badStatus(let code): "Server returned HTTP \(code)"
        case .authFailed: "Authentication failed"
        case .notQBitTorrent: "Not a qBittorrent Web UI"
        case .network(let text): text
        }
    }
}

final class WebAPIEngine: Sendable {
    let base: URL
    private let session: URLSession

    init(base: URL) {
        self.base = base
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        session = URLSession(configuration: configuration)
    }

    static func url(from string: String) -> URL? {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "http://" + text }
        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil
        else { return nil }
        return url
    }

    func authenticate(username: String, password: String) async throws -> String {
        var login = URLRequest(url: base.appendingPathComponent("api/v2/auth/login"))
        login.httpMethod = "POST"
        login.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        login.httpBody = Data(Self.form([
            ("username", username),
            ("password", password)
        ]).utf8)

        let (loginData, loginResponse) = try await send(login)
        guard let http = loginResponse as? HTTPURLResponse else {
            throw WebAPIError.network("No HTTP response")
        }
        let loginText = String(data: loginData, encoding: .utf8) ?? ""
        if loginText.localizedCaseInsensitiveContains("fails")
            || loginText.localizedCaseInsensitiveContains("unauthorized") {
            throw WebAPIError.authFailed
        }
        // qBittorrent ≤5.1 answers 200 "Ok."; 5.2+ answers 204 with an empty
        // body and uses 401 "Unauthorized" for bad credentials.
        guard http.statusCode == 200 || http.statusCode == 204 else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw WebAPIError.authFailed
            }
            throw WebAPIError.badStatus(http.statusCode)
        }

        let (versionData, versionResponse) = try await send(
            URLRequest(url: base.appendingPathComponent("api/v2/app/version"))
        )
        guard let versionHTTP = versionResponse as? HTTPURLResponse, versionHTTP.statusCode == 200 else {
            throw WebAPIError.notQBitTorrent
        }
        guard let version = String(data: versionData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !version.isEmpty
        else { throw WebAPIError.notQBitTorrent }
        return version
    }

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let error as URLError {
            throw WebAPIError.network(error.localizedDescription)
        } catch {
            throw WebAPIError.network(String(describing: error))
        }
    }

    private static func form(_ items: [(String, String)]) -> String {
        var components = URLComponents()
        components.queryItems = items.map { URLQueryItem(name: $0.0, value: $0.1) }
        return components.percentEncodedQuery ?? ""
    }
}
