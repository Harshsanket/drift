// SPDX-License-Identifier: GPL-3.0-only
import Foundation

enum ExternalSearchError: LocalizedError {
    case invalidConfiguration
    case invalidURL
    case badStatus(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "Jackett/Prowlarr is not configured."
        case .invalidURL: "The external search URL is invalid."
        case .badStatus(let code): "External search returned HTTP \(code)."
        case .invalidResponse: "External search returned an unexpected response."
        }
    }
}

/// Native Jackett/Prowlarr search (EMBEDDED-ENGINE.md §7). No GPL Python
/// search plugins are executed or bundled; results are normalized into the
/// app's existing `SearchResult` model and handed back to the embedded engine.
final class ExternalSearchClient {
    private let session: URLSession

    init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    /// Strip `apikey` values from a URL before it can reach a log or probe.
    static func redactAPIKey(_ url: String) -> String {
        guard var components = URLComponents(string: url) else { return url }
        if let items = components.queryItems,
           items.contains(where: { $0.name.lowercased() == "apikey" }) {
            components.queryItems = items.map { item in
                item.name.lowercased() == "apikey"
                    ? URLQueryItem(name: item.name, value: "REDACTED")
                    : item
            }
        }
        return components.url?.absoluteString ?? url
    }

    func search(
        configuration: ExternalSearchConfiguration,
        query: String,
        category: String
    ) async throws -> [SearchResult] {
        guard configuration.isConfigured else { throw ExternalSearchError.invalidConfiguration }
        guard let base = URL(string: configuration.normalizedBaseURL),
              let scheme = base.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { throw ExternalSearchError.invalidURL }

        let preferred = configuration.providerHint
        do {
            return try await search(provider: preferred, base: base, configuration: configuration,
                                    query: query, category: category)
        } catch ExternalSearchError.badStatus(404) where preferred == "Jackett" {
            return try await search(provider: "Prowlarr", base: base, configuration: configuration,
                                    query: query, category: category)
        } catch ExternalSearchError.badStatus(404) where preferred == "Prowlarr" {
            return try await search(provider: "Jackett", base: base, configuration: configuration,
                                    query: query, category: category)
        }
    }

    private func search(
        provider: String,
        base: URL,
        configuration: ExternalSearchConfiguration,
        query: String,
        category: String
    ) async throws -> [SearchResult] {
        if provider == "Prowlarr" {
            var components = URLComponents(
                url: base.appendingPathComponent("api/v1/search"),
                resolvingAgainstBaseURL: false
            )
            components?.queryItems = [
                URLQueryItem(name: "query", value: query),
                URLQueryItem(name: "type", value: "search"),
            ]
            guard let url = components?.url else { throw ExternalSearchError.invalidURL }
            let data = try await fetch(url, apiKey: configuration.apiKey)
            return try parseProwlarr(data, configuration: configuration)
        }

        // Jackett's documented "all indexers" route. The shorter route is
        // accepted by some versions and used as a fallback.
        let paths = ["api/v2.0/indexers/all/results", "api/v2.0/all/results"]
        var lastError: Error = ExternalSearchError.invalidResponse
        for path in paths {
            var components = URLComponents(
                url: base.appendingPathComponent(path),
                resolvingAgainstBaseURL: false
            )
            var items = [
                URLQueryItem(name: "Query", value: query),
            ]
            if category != "all", !category.isEmpty {
                items.append(URLQueryItem(name: "Category", value: category))
            }
            components?.queryItems = items
            guard let url = components?.url else { throw ExternalSearchError.invalidURL }
            do {
                let data = try await fetch(url, apiKey: configuration.apiKey)
                return try parseJackett(data, configuration: configuration)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func fetch(_ url: URL, apiKey: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        // Both Jackett and Prowlarr accept the key as a header, keeping it
        // out of URLs (and therefore out of proxy/access logs).
        request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ExternalSearchError.invalidResponse
        }
        guard http.statusCode == 200 else {
            throw ExternalSearchError.badStatus(http.statusCode)
        }
        return data
    }

    private func parseJackett(
        _ data: Data,
        configuration: ExternalSearchConfiguration
    ) throws -> [SearchResult] {
        let root = try JSONSerialization.jsonObject(with: data)
        let rows: [[String: Any]]
        if let object = root as? [String: Any], let results = object["Results"] as? [[String: Any]] {
            rows = results
        } else if let results = root as? [[String: Any]] {
            rows = results
        } else {
            throw ExternalSearchError.invalidResponse
        }

        return rows.compactMap { row in
            let title = string(row["Title"]) ?? string(row["title"]) ?? ""
            let magnet = string(row["MagnetUri"]) ?? string(row["magnetUri"])
            let link = string(row["Link"]) ?? string(row["link"])
            guard let rawURL = magnet ?? link,
                  let fileURL = authorized(rawURL, configuration: configuration)
            else { return nil }
            let details = string(row["Details"]) ?? string(row["details"])
            let tracker = string(row["Tracker"]) ?? string(row["tracker"])
            let guid = string(row["Guid"]) ?? string(row["guid"])
            let site = [details, tracker, guid]
                .compactMap { $0 }
                .first { $0.hasPrefix("http://") || $0.hasPrefix("https://") }
                ?? configuration.normalizedBaseURL
            return SearchResult(
                fileName: title.isEmpty ? fileURL : title,
                fileURL: fileURL,
                fileSize: int64(row["Size"]) ?? int64(row["size"]) ?? 0,
                seeders: int64(row["Seeders"]) ?? int64(row["seeders"]) ?? 0,
                leechers: int64(row["Peers"]) ?? int64(row["leechers"]) ?? 0,
                siteURL: site,
                engineName: tracker ?? "Jackett"
            )
        }
        .sorted { lhs, rhs in
            lhs.seeders == rhs.seeders
                ? lhs.fileName.localizedCaseInsensitiveCompare(rhs.fileName) == .orderedAscending
                : lhs.seeders > rhs.seeders
        }
    }

    private func parseProwlarr(
        _ data: Data,
        configuration: ExternalSearchConfiguration
    ) throws -> [SearchResult] {
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ExternalSearchError.invalidResponse
        }
        return rows.compactMap { row in
            let title = string(row["title"]) ?? string(row["Title"]) ?? ""
            let magnet = string(row["magnetUrl"]) ?? string(row["magnetUri"])
            let download = string(row["downloadUrl"]) ?? string(row["guid"])
            guard let rawURL = magnet ?? download,
                  let fileURL = authorized(rawURL, configuration: configuration)
            else { return nil }
            let siteCandidate = string(row["infoUrl"]) ?? string(row["guid"])
            let info = (siteCandidate?.hasPrefix("http://") == true
                        || siteCandidate?.hasPrefix("https://") == true)
                ? siteCandidate!
                : configuration.normalizedBaseURL
            let indexer = string(row["indexer"]) ?? string(row["indexerId"]) ?? "Prowlarr"
            let categoryName = (row["categories"] as? [[String: Any]])?
                .compactMap { string($0["name"]) }
                .first
            return SearchResult(
                fileName: title.isEmpty ? fileURL : title,
                fileURL: fileURL,
                fileSize: int64(row["size"]) ?? 0,
                seeders: int64(row["seeders"]) ?? 0,
                leechers: int64(row["leechers"]) ?? 0,
                siteURL: info,
                engineName: categoryName.map { "\(indexer) · \($0)" } ?? indexer
            )
        }
        .sorted { lhs, rhs in
            lhs.seeders == rhs.seeders
                ? lhs.fileName.localizedCaseInsensitiveCompare(rhs.fileName) == .orderedAscending
                : lhs.seeders > rhs.seeders
        }
    }

    /// Prowlarr/Jackett download URLs usually carry the API key already; add
    /// it for same-host URLs that do not.
    private func authorized(
        _ raw: String,
        configuration: ExternalSearchConfiguration
    ) -> String? {
        guard let url = URL(string: raw) else { return nil }
        if url.scheme?.lowercased() == "magnet" { return raw }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return raw }
        let baseHost = URL(string: configuration.normalizedBaseURL)?.host
        if components.host == baseHost,
           !(components.queryItems ?? []).contains(where: { $0.name == "apikey" }) {
            var items = components.queryItems ?? []
            items.append(URLQueryItem(name: "apikey", value: configuration.apiKey))
            components.queryItems = items
        }
        return components.url?.absoluteString ?? raw
    }

    private func string(_ value: Any?) -> String? {
        if let text = value as? String, !text.isEmpty { return text }
        return nil
    }

    private func int64(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let text = value as? String, let parsed = Int64(text) { return parsed }
        return nil
    }
}
