import Foundation

/// Privacy-first leak detection surface.
///
/// Hard rules (enforced here, pinned by SecurityTests):
///   1. No plain, non-tunneled request is ever made to DISCOVER the public
///      IP. The canary connection is a refusal test against a non-routable
///      documentation address (TEST-NET-2), not an IP echo.
///   2. The exit echo is requested ONLY through the currently selected
///      tunneled session. There is no "direct" baseline trade at all: if no
///      safe baseline exists, detection reports `detectionUnavailable`.
///   3. Public IPs are never persisted: no UserDefaults, no keychain, no
///      files. Echo values live inside this object and are dropped when the
///      tunnel phase changes. Log lines are redacted.
///   4. The app never claims "leak-free" from IP comparison alone; DNS leaks
///      are treated as not verifiable on-device and never turned into a
///      UI claim.
@MainActor
@Observable
final class IPLeakProbe {
    static let shared = IPLeakProbe()

    enum PrivacyState: Equatable, Sendable {
        case verifiedProtected
        case tunnelActiveExitUnconfirmed
        case detectionUnavailable
        case refusingAllTraffic
        case unusualRoute

        var shortLabel: String {
            switch self {
            case .verifiedProtected: "Protected"
            case .tunnelActiveExitUnconfirmed: "Tunnel active"
            case .detectionUnavailable: "Tunnel not connected"
            case .refusingAllTraffic: "Traffic refused"
            case .unusualRoute: "Unusual route"
            }
        }

        var detail: String {
            switch self {
            case .verifiedProtected:
                "Kill-switch verified and exit point confirmed through the tunnel"
            case .tunnelActiveExitUnconfirmed:
                "Tunnel is up, but the exit point could not be confirmed yet"
            case .detectionUnavailable:
                "No tunnel is running, so there is nothing to verify yet"
            case .refusingAllTraffic:
                "Tunnel is down and the relay is refusing all traffic"
            case .unusualRoute:
                "Traffic reacted outside the tunnel path — check your setup"
            }
        }

        var systemImage: String {
            switch self {
            case .verifiedProtected: "checkmark.shield.fill"
            case .tunnelActiveExitUnconfirmed: "questionmark.shield"
            case .detectionUnavailable: "exclamationmark.shield.fill"
            case .refusingAllTraffic: "stop.shield.fill"
            case .unusualRoute: "exclamationmark.triangle.fill"
            }
        }
    }

    private(set) var state: PrivacyState = .detectionUnavailable

    /// In-memory only; never persisted anywhere.
    private var lastExitAddress: String?

    // MARK: - Pure mapping (unit-tested)

    nonisolated static func evaluate(
        phase: TunnelService.Phase,
        canaryRefused: Bool?,
        exitConfirmed: Bool?
    ) -> PrivacyState {
        switch phase {
        case .up:
            return evaluateUp(canaryRefused: canaryRefused, exitConfirmed: exitConfirmed)
        case .down:
            return .refusingAllTraffic
        case .disabled, .needsElevation, .starting:
            return .detectionUnavailable
        }
    }

    nonisolated private static func evaluateUp(canaryRefused: Bool?, exitConfirmed: Bool?) -> PrivacyState {
        if canaryRefused == false { return .unusualRoute }
        if canaryRefused == true, exitConfirmed == true { return .verifiedProtected }
        if canaryRefused == true, exitConfirmed == false { return .tunnelActiveExitUnconfirmed }
        return .tunnelActiveExitUnconfirmed
    }

    /// Called whenever the tunnel phase changes. Resets in-memory probe data
    /// (rule 3) and re-evaluates the coarse state.
    func observePhase(_ phase: TunnelService.Phase) {
        lastExitAddress = nil
        state = Self.evaluate(phase: phase, canaryRefused: nil, exitConfirmed: nil)
        writeProbeLog("[probe] phase change → state=\(state.shortLabel)")
    }

    // MARK: - Live probes

    struct Outcome {
        let canaryRefused: Bool?
        let exitConfirmed: Bool?
        /// Diagnostic text without any addresses.
        let diagnostic: String
    }

    /// Runs the two in-session checksteps and updates state. Exit echo runs
    /// through the tunnel session only; the canary hits TEST-NET-2 without
    /// any proxy.
    func runLiveCheck(phase: TunnelService.Phase) async {
        let outcome = await Self.measure(phase: phase)
        apply(outcome: outcome, phase: phase)
    }

    private func apply(outcome: Outcome, phase: TunnelService.Phase) {
        switch phase {
        case .up:
            if let confirmed = outcome.exitConfirmed, confirmed, outcome.canaryRefused == true {
                state = .verifiedProtected
            } else {
                state = Self.evaluate(
                    phase: phase,
                    canaryRefused: outcome.canaryRefused,
                    exitConfirmed: outcome.exitConfirmed
                )
            }
            writeProbeLog("[probe] live check → \(outcome.diagnostic)")
        case .down:
            state = .refusingAllTraffic
            writeProbeLog("[probe] live check skipped (tunnel down)")
        case .disabled, .needsElevation, .starting:
            state = .detectionUnavailable
            writeProbeLog("[probe] live check skipped (no tunnel)")
        }
    }

    /// Networking part, isolated for testability. Never logs or stores
    /// addresses; the diagnostic strings are built redacted.
    nonisolated static func measure(phase: TunnelService.Phase) async -> Outcome {
        var canaryRefused: Bool?
        var exitConfirmed: Bool?
        var diagnostic = "no tunnel session"

        if phase == .up {
            canaryRefused = await canaryRefusal()
            let exit = await tunnelExitEcho()
            exitConfirmed = exit.confirmed
            diagnostic = Self.describe(
                canaryRefused: canaryRefused, exitConfirmed: exit.confirmed)
        }

        return Outcome(
            canaryRefused: canaryRefused, exitConfirmed: exitConfirmed, diagnostic: diagnostic)
    }

    // MARK: Canary (refusal test, never an IP echo)

    /// TEST-NET-2 (RFC 5737). Must never answer anything under any routing;
    /// if we get a byte back, something let traffic travel outside the
    /// intended path.
    nonisolated static let canaryHost = "198.51.100.1"
    private nonisolated static let canaryBudget = 3.5
    private nonisolated static let fastFailureBudget = 2.2

    nonisolated static func canaryRefusal() async -> Bool? {
        var config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = canaryBudget
        config.waitsForConnectivity = false
        guard let url = URL(string: "https://\(canaryHost)/probe") else { return nil }
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        let started = Date()
        do {
            let (_, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse {
                // A documented HTTP status from a documentation address
                // means some middlebox responded for us: unacceptable.
                return false
            }
            return false
        } catch let error as URLError {
            let elapsed = Date().timeIntervalSince(started)
            return classifyCanaryFailure(error, elapsed: elapsed)
        } catch {
            return nil
        }
    }

    nonisolated static func classifyCanaryFailure(_ error: URLError, elapsed: TimeInterval) -> Bool? {
        switch error.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
            .cannotParseResponse:
            // Sub-2s failures = active refusal (route rejected right away).
            // Long hangs = normal TEST-NET drop discipline: cannot judge,
            // and claiming either way would be a lie.
            return elapsed < fastFailureBudget ? true : nil
        case .notConnectedToInternet:
            return true
        default:
            return nil
        }
    }

    // MARK: Exit echo (tunneled session only)

    /// Two independent echo hosts through the tunnel-only session. Equal,
    /// plausible answers from both = exit confirmed.
    nonisolated static func tunnelExitEcho() async -> (confirmed: Bool, comparison: String?) {
        let hosts = ["https://api.ipify.org", "https://ifconfig.me/ip"]
        var answers: [String] = []
        for host in hosts {
            if let answer = await oneEcho(host: host) { answers.append(answer) }
        }
        if answers.count == 2, answers[0] == answers[1], answers[0].count >= 3 {
            return (true, Self.redactAddresses(answers[0]))
        }
        if answers.isEmpty {
            return (false, nil)
        }
        // Only one honest answer or disagreement: cannot confirm.
        return (false, Self.redactAddresses(answers[0]))
    }

    nonisolated private static func oneEcho(host: String) async -> String? {
        // Tunnel-only rule: the configuration must have the relay attached.
        // A nil proxy dictionary would make this a direct request (banned).
        let config = URLSessionConfiguration.ephemeral
        TunnelProxy.apply(to: config)
        guard config.connectionProxyDictionary != nil else { return nil }
        config.timeoutIntervalForRequest = 8
        config.waitsForConnectivity = true
        guard let url = URL(string: host) else { return nil }
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, _) = try await session.data(from: url)
            let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // Only accept plausible echo replies.
            guard text.count >= 3, text.count <= 64 else { return nil }
            return text
        } catch {
            return nil
        }
    }

    // MARK: - Redaction

    /// Strips IPv4/IPv6-shaped tokens so diagnostics can be logged safely.
    nonisolated static func redactAddresses(_ text: String) -> String {
        var out = text
        // IPv4 with optional port; IPv6 full and compressed forms.
        for pattern in [
            "\\b(?:\\d{1,3}\\.){3}\\d{1,3}(?::\\d{1,5})?\\b",
            "\\b(?:[0-9A-Fa-f]{1,4}:){2,7}[0-9A-Fa-f]{1,4}\\b",
            "(?<![0-9A-Fa-f])(?:[0-9A-Fa-f]{1,4}:){1,6}:[0-9A-Fa-f]{0,4}",
            "\\b(?:::ffff:(?:\\d{1,3}\\.){3}\\d{1,3})\\b"
        ] {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                for range in regex.matches(in: out, range: NSRange(out.startIndex..., in: out))
                    .map({ Range($0.range, in: out)! }).reversed() {
                    out.replaceSubrange(range, with: "[filtered]")
                }
            }
        }
        return out
    }

    private nonisolated static func describe(canaryRefused: Bool?, exitConfirmed: Bool?) -> String {
        let canaryPart: String
        switch canaryRefused {
        case .some(true): canaryPart = "canary refused"
        case .some(false): canaryPart = "canary answered"
        case nil: canaryPart = "canary unchecked"
        }
        let exitPart: String
        switch exitConfirmed {
        case .some(true): exitPart = "exit confirmed"
        case .some(false): exitPart = "exit unconfirmed"
        case nil: exitPart = "exit unavailable"
        }
        return "\(canaryPart), \(exitPart), dns check unavailable on-device"
    }
}
