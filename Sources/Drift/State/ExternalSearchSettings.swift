// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Observation

/// Configuration shared by the external search client and Settings.
struct ExternalSearchConfiguration: Sendable, Equatable {
    var baseURL: String
    var apiKey: String

    var isConfigured: Bool {
        !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !apiKey.isEmpty
    }

    var normalizedBaseURL: String {
        var value = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    /// Heuristic only: the client falls back to the other provider on a 404.
    var providerHint: String {
        let lower = normalizedBaseURL.lowercased()
        if lower.contains("prowlarr") || lower.contains(":9696") { return "Prowlarr" }
        return "Jackett"
    }
}

@MainActor
@Observable
final class ExternalSearchSettings {
    static let shared = ExternalSearchSettings()

    var baseURL: String {
        didSet {
            UserDefaults.standard.set(baseURL, forKey: Self.baseKey)
            writeProbeLog("[settings] external search URL set=\(!baseURL.isEmpty)")
        }
    }

    private(set) var apiKey: String

    private static let baseKey = "externalSearch.baseURL"
    private static let keychainAccount = "externalSearch.apiKey"

    private init() {
        baseURL = UserDefaults.standard.string(forKey: Self.baseKey) ?? ""
        apiKey = Keychain.password(account: Self.keychainAccount) ?? ""
    }

    var configuration: ExternalSearchConfiguration {
        ExternalSearchConfiguration(baseURL: baseURL, apiKey: apiKey)
    }

    var isConfigured: Bool { configuration.isConfigured }

    func save(baseURL: String, apiKey: String) {
        self.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            self.apiKey = trimmedKey
            Keychain.setPassword(trimmedKey, account: Self.keychainAccount)
        }
    }
}
