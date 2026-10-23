import Foundation
import SwiftUI

@MainActor
@Observable
final class UpdateChecker {
    static let shared = UpdateChecker()

    enum Status {
        case idle
        case upToDate
        case available(version: String, url: URL)
        case noReleases
        case failed(String)
    }

    private(set) var checking = false
    private(set) var status: Status = .idle
    /// Set when a launch-time check finds a newer release; the main window
    /// presents its update prompt from this.
    var promptVisible = false

    /// Opt-outable launch check. Defaults on: the About card exposes the
    /// toggle, and turning it off stops all launch-time calls to GitHub.
    var checkOnLaunchEnabled: Bool {
        didSet {
            UserDefaults.standard.set(checkOnLaunchEnabled, forKey: "updates.autoCheckOnLaunch")
        }
    }

    private var launchCheckRan = false

    var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? "1.1.0"
    }

    private static let latestReleaseURL =
        URL(string: "https://api.github.com/repos/Harshsanket/drift/releases/latest")!

    init() {
        checkOnLaunchEnabled = UserDefaults.standard.object(
            forKey: "updates.autoCheckOnLaunch") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "updates.autoCheckOnLaunch")
    }

    /// Once per session: when the launch-check toggle is on, ask GitHub for
    /// the latest release and surface the prompt if a newer one exists.
    func checkOnLaunch() async {
        guard !launchCheckRan else { return }
        launchCheckRan = true
        guard checkOnLaunchEnabled else {
            writeProbeLog("[update] launch check disabled")
            return
        }
        await check()
        if case .available = status {
            promptVisible = true
        }
    }

    /// Manual-only: update checks never run automatically. The only
    /// sanctioned launch-time updater is `UpdateService` (Sparkle), which
    /// stays silent unless a feed is configured and auto-updates are on.
    func check() async {
        guard !checking else { return }
        checking = true
        status = .idle
        writeProbeLog("[update] checking")
        defer { checking = false }
        var request = URLRequest(
            url: Self.latestReleaseURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15
        )
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Drift/\(appVersion)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                status = .failed("Could not check for updates.")
                return
            }
            if http.statusCode == 404 {
                status = .noReleases
                writeProbeLog("[update] no releases")
                return
            }
            guard http.statusCode == 200 else {
                status = .failed("Update check failed (HTTP \(http.statusCode)).")
                writeProbeLog("[update] HTTP \(http.statusCode)")
                return
            }
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            guard let url = URL(string: release.htmlURL) else {
                status = .failed("Could not read the release page.")
                return
            }
            if Self.isVersion(release.tagName, newerThan: appVersion) {
                status = .available(version: release.tagName, url: url)
                writeProbeLog("[update] available \(release.tagName)")
            } else {
                status = .upToDate
                writeProbeLog("[update] up to date \(release.tagName)")
            }
        } catch {
            status = .failed("Could not check for updates.")
            writeProbeLog("[update] failed \(error.localizedDescription)")
        }
    }

    private static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        func components(_ version: String) -> [Int] {
            version
                .drop(while: { $0 == "v" || $0 == "V" })
                .split(separator: ".")
                .map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let latest = components(candidate)
        let installed = components(current)
        for index in 0..<max(latest.count, installed.count) {
            let lhs = index < latest.count ? latest[index] : 0
            let rhs = index < installed.count ? installed[index] : 0
            if lhs != rhs { return lhs > rhs }
        }
        return false
    }
}

struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: String

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }
}
