import Foundation
import Observation

@MainActor
@Observable
final class ConnectionSettings {
    static let shared = ConnectionSettings()

    enum TestStatus {
        case success(String)
        case error(String)

        var isSuccess: Bool {
            if case .success = self { return true }
            return false
        }

        var text: String {
            switch self {
            case .success(let value): value
            case .error(let value): value
            }
        }
    }

    var baseUrl: String
    var username: String
    var testStatus: TestStatus?
    var lastVersion: String?

    private init() {
        let defaults = UserDefaults.standard
        baseUrl = defaults.string(forKey: "connection.baseUrl") ?? "http://localhost:8080"
        username = defaults.string(forKey: "connection.username") ?? "admin"
        lastVersion = defaults.string(forKey: "connection.lastVersion")
    }

    func noteConnected(version: String) {
        guard version != lastVersion else { return }
        lastVersion = version
        UserDefaults.standard.set(version, forKey: "connection.lastVersion")
    }

    var password: String {
        Keychain.password(account: "password") ?? ""
    }

    func save(baseUrl: String, username: String, password: String) {
        let trimmedBase = baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        self.baseUrl = trimmedBase
        self.username = trimmedUser
        let defaults = UserDefaults.standard
        defaults.set(trimmedBase, forKey: "connection.baseUrl")
        defaults.set(trimmedUser, forKey: "connection.username")
        if !password.isEmpty {
            Keychain.setPassword(password, account: "password")
        }
        testStatus = nil
    }

    func test(baseUrl: String, username: String, password: String) async {
        guard let url = WebAPIEngine.url(from: baseUrl) else {
            testStatus = .error(WebAPIError.invalidURL.message)
            writeProbeLog("[conn] error invalid url")
            return
        }
        let engine = WebAPIEngine(base: url)
        do {
            let version = try await engine.authenticate(username: username, password: password)
            noteConnected(version: version)
            testStatus = .success("Connected — qBittorrent \(version)")
            writeProbeLog("[conn] ok \(version)")
        } catch let error as WebAPIError {
            testStatus = .error(error.message)
            writeProbeLog("[conn] error \(error.message)")
        } catch {
            testStatus = .error(error.localizedDescription)
            writeProbeLog("[conn] error \(error.localizedDescription)")
        }
    }
}
