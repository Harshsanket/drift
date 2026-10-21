import Foundation
import Testing
@testable import Drift

@Suite("Security: remote value scrub (untrusted server JSON)")
struct RemoteSanitizerTests {
    @Test func controlCharactersAndLengthCapped() {
        let dirty = "le\u{07}gacy\u{1F}na\u{7F}me" + String(repeating: "x", count: 400)
        let clean = WebAPIEngine.RemoteSanitizer.text(dirty)
        #expect(!clean.contains("\u{07}"))
        #expect(!clean.contains("\u{1F}"))
        #expect(!clean.contains("\u{7F}"))
        #expect(clean.count == WebAPIEngine.RemoteSanitizer.maxDisplayLength)
    }

    @Test func pathsKeepMoreRoom() {
        let dirty = String(repeating: "a\u{00}b", count: 100)
        let clean = WebAPIEngine.RemoteSanitizer.path(dirty)
        #expect(!clean.isEmpty)
        #expect(clean.count <= WebAPIEngine.RemoteSanitizer.maxPathLength)
    }

    @Test func numbersAreClampedUnderZeroAndInfinityAttacks() {
        #expect(WebAPIEngine.RemoteSanitizer.int(-5 as NSNumber, inRange: 0...(1 << 62)) == 0)
        #expect(WebAPIEngine.RemoteSanitizer.int(Int64.max as NSNumber, inRange: 0...(1 << 62)) == (1 << 62))
        #expect(WebAPIEngine.RemoteSanitizer.int("NaN" as NSString, inRange: 0...(1 << 62)) == 0)
        #expect(WebAPIEngine.RemoteSanitizer.int(NSNumber(value: Double.nan), inRange: 0...(1 << 62)) == 0)
        #expect(WebAPIEngine.RemoteSanitizer.double(NSNumber(value: Double.infinity), inRange: 0...1) == 1)
        #expect(WebAPIEngine.RemoteSanitizer.double(NSNumber(value: -Double.infinity), inRange: 0...1) == 0)
        #expect(WebAPIEngine.RemoteSanitizer.double(1.7 as NSNumber, inRange: 0...1) == 1)
        #expect(WebAPIEngine.RemoteSanitizer.double(-0.2 as NSNumber, inRange: 0...1) == 0)
    }

    @Test func summarySanitizesHostilePayload() {
        let fields: [String: Any] = [
            "name": "evil\u{1B}name\u{08}" + String(repeating: "9", count: 500),
            "progress": 1.9 as NSNumber,
            "dlspeed": -(1 << 30) as NSNumber,
            "upspeed": (1 << 40) as NSNumber,
            "size": NSNumber(value: Double.greatestFiniteMagnitude),
            "downloaded": -1 as NSNumber,
            "save_path": "/hostile\u{0}/path/…"
        ]
        let summary = WebAPIEngine.summary(id: "aabb", fields: fields)
        #expect(summary.progress == 1)
        #expect(summary.downloadSpeed == 0)
        #expect(summary.uploadSpeed == (1 << 40))
        #expect(summary.size == (1 << 62))
        #expect(summary.downloaded == 0)
        #expect(!summary.name.contains("\u{1B}"))
        #expect(summary.name.count <= WebAPIEngine.RemoteSanitizer.maxDisplayLength)
        #expect(summary.savePath.contains("\u{0}") == false)
        #expect(summary.savePath.count <= WebAPIEngine.RemoteSanitizer.maxPathLength)
    }
}

@Suite("Security: UI least-privilege boundary")
struct UIBoundaryTests {
    /// Absolute path of the package source root, resolved from this test
    /// file's own location (`Tests/DriftTests/…`). Lives under `Sources/Drift`.
    private static var sourceRoot: URL? {
        // #filePath: <root>/Tests/DriftTests/SecurityTests.swift
        let parents = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent()          // <root>/Tests
            .deletingLastPathComponent()          // <root>
        let drift = parents.appendingPathComponent("Sources/Drift")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: drift.path, isDirectory: &isDirectory) else {
            return nil
        }
        _ = isDirectory
        return drift
    }

    private static func files(relative directory: String) -> [URL] {
        let dirs = sourceRoot?.appendingPathComponent(directory)
        guard let dirs, FileManager.default.fileExists(atPath: dirs.path) else { return [] }
        var found: [URL] = []
        if let walker = FileManager.default.enumerator(at: dirs, includingPropertiesForKeys: nil) {
            for case let url as URL in walker where url.pathExtension == "swift" {
                found.append(url)
            }
        }
        return found
    }

    /// Forbidden constructs in the frontend: raw networking, raw sockets,
    /// file-descriptor plumbing, and any third-party/C-ABI surface. Views
    /// consume value snapshots and view models only.
    private static let forbiddenInUI: [String] = [
        "URLSession",
        "malloc(",
        "sockaddr",
        "getaddrinfo",
        "inet_pton",
        "socket(",
        "connect(",
        "bind(",
        "Partout",
        "PartoutNative",
        "import Darwin",
    ]

    @Test func uiBoundariesHold() throws {
        // ProbeLog moved out of UI on purpose; if this list is non-empty the
        // frontend has grown privileged capabilities again.
        var violations: [String] = []
        let uiFiles = Self.files(relative: "UI")
        #expect(!uiFiles.isEmpty, "UI directory must exist for the scan")
        for file in uiFiles {
            guard let text = try? String(contentsOfFile: file.path, encoding: .utf8) else {
                continue
            }
            for token in Self.forbiddenInUI where text.contains(token) {
                // "connect(" / "bind(" show up innocently in names; only
                // real calls or declarations count.
                if token == "connect(" || token == "bind(" || token == "socket(" {
                    let isRealCall = text.contains("Darwin.\(token)")
                        || text.contains(" \(token)")
                        || text.contains("=\(token)")
                    guard isRealCall else { continue }
                }
                if token.hasSuffix("(") == false, token == "import Darwin" {
                    guard text.contains("import Darwin") else { continue }
                }
                violations.append("\(file.lastPathComponent): contains \"\(token)\"")
            }
            // Views must never persist directly to UserDefaults either; all
            // persistence goes through the state layer's typed stores.
            let persistenceTokens = ["UserDefaults.standard.", "createFile(", "removeItem("]
            let viewOnlyFile = file.path
            for token in persistenceTokens where try String(contentsOfFile: viewOnlyFile, encoding: .utf8).contains(token) {
                violations.append("\(file.lastPathComponent): persistence bypass \"\(token)\"")
            }
        }
        #expect(violations.isEmpty, "UI boundary violations: \(violations.joined(separator: "; "))")
    }
}

@Suite("Security: privacy leak-state mapping (no false 'safe' claims)")
struct IPLeakProbeTests {
    @Test func desiredStatesMatchSpecConservatively() {
        // Full confirmation = protected.
        #expect(
            IPLeakProbe.evaluate(phase: .up, canaryRefused: true, exitConfirmed: true)
                == .verifiedProtected)
        // Tunnel up but unconfirmed exit → unconfirmed, never "protected".
        #expect(
            IPLeakProbe.evaluate(phase: .up, canaryRefused: true, exitConfirmed: false)
                == .tunnelActiveExitUnconfirmed)
        #expect(
            IPLeakProbe.evaluate(phase: .up, canaryRefused: true, exitConfirmed: nil)
                == .tunnelActiveExitUnconfirmed)
        #expect(IPLeakProbe.evaluate(phase: .up, canaryRefused: nil, exitConfirmed: nil)
            == .tunnelActiveExitUnconfirmed)
        // Canary answered → unusual route wins over everything.
        #expect(
            IPLeakProbe.evaluate(phase: .up, canaryRefused: false, exitConfirmed: true)
                == .unusualRoute)
        // Tunnel down → relay refuses traffic.
        #expect(IPLeakProbe.evaluate(phase: .down(":("), canaryRefused: true, exitConfirmed: true)
            == .refusingAllTraffic)
        // Off / not yet running → no claims at all.
        for phase in [TunnelService.Phase.disabled, .needsElevation, .starting] {
            #expect(IPLeakProbe.evaluate(phase: phase, canaryRefused: nil, exitConfirmed: nil)
                == .detectionUnavailable)
        }
    }

    @Test func wordingNeverClaimsSafetyOrProtectionWithoutProof() {
        let labels: [String] = [
            IPLeakProbe.PrivacyState.verifiedProtected.shortLabel,
            IPLeakProbe.PrivacyState.tunnelActiveExitUnconfirmed.shortLabel,
            IPLeakProbe.PrivacyState.detectionUnavailable.shortLabel,
            IPLeakProbe.PrivacyState.refusingAllTraffic.shortLabel,
            IPLeakProbe.PrivacyState.unusualRoute.shortLabel
        ]
        for label in labels {
            let lowered = label.lowercased()
            #expect(!lowered.contains("safe"))
            #expect(!lowered.contains("leak-free"))
            #expect(!lowered.contains("leak free"))
            #expect(!lowered.contains("no leaks"))
        }
        // Protection is only claimed in the verified state.
        #expect(IPLeakProbe.PrivacyState.verifiedProtected.detail.contains("verified"))
        for state in labels where state != IPLeakProbe.PrivacyState.verifiedProtected.shortLabel {
            #expect(!state.lowercased().contains("protected"))
        }
    }

    @Test func redactionRemovesV4V6AndPortShapes() {
        let dirty = "happy path from 203.0.113.44:8080 and dead 2001:DB8::badfe via 8.8.8.8"
        let clean = IPLeakProbe.redactAddresses(dirty)
        #expect(clean.contains("filtered"))
        #expect(!clean.contains("203.0.113"))
        #expect(!clean.contains("8.8.8.8"))
        #expect(!clean.contains("2001:DB8"))
    }

    @Test func canaryFailureClassification() {
        // Fast failures read as refusal.
        #expect(
            IPLeakProbe.classifyCanaryFailure(URLError(.cannotConnectToHost), elapsed: 0.05) == true)
        #expect(
            IPLeakProbe.classifyCanaryFailure(URLError(.networkConnectionLost), elapsed: 0.5) == true)
        #expect(
            IPLeakProbe.classifyCanaryFailure(URLError(.notConnectedToInternet), elapsed: 2.9) == true)
        // Long hangs are honest "unknown" (TEST-NET drop discipline).
        #expect(IPLeakProbe.classifyCanaryFailure(URLError(.timedOut), elapsed: 3.5) == nil)
        #expect(
            IPLeakProbe.classifyCanaryFailure(URLError(.networkConnectionLost), elapsed: 2.4) == nil)
    }
}

@Suite("Security: FileGateway verdicts")
struct FileGatewayTests {

    private func tempDir(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("drift-gw-\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func pieceWriteInsideRootAllowed() throws {
        let root = tempDir("inside")
        let fileURL = root.appendingPathComponent("Sub/file.bin")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Sub"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: fileURL)
        #expect(FileGateway.verdictForPieceWrite(candidate: fileURL, saveRoot: root) == .allowed)
        try? FileManager.default.removeItem(at: root)
    }

    @Test func pieceWriteOutsideRootRejected() throws {
        let root = tempDir("outside")
        let sibling = tempDir("notinroot")
        let fileURL = sibling.appendingPathComponent("f.bin")
        try Data("x".utf8).write(to: fileURL)
        let verdict = FileGateway.verdictForPieceWrite(candidate: fileURL, saveRoot: root)
        guard case .rejected = verdict else {
            Issue.record("expected rejection, got \(verdict)")
            return
        }
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: sibling)
    }

    @Test func pieceWritePrefixConfusionRejected() throws {
        // root=/tmp/inside, file=/tmp/inside-evil/f.bin — prefix match must fail.
        let root = tempDir("p")
        let evil = tempDir("p")
        let evilPath = evil.path + "-evil"
        let fileURL = URL(fileURLWithPath: evilPath).appendingPathComponent("f.bin")
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: fileURL)
        guard case .rejected = FileGateway.verdictForPieceWrite(candidate: fileURL, saveRoot: root) else {
            Issue.record("prefix-adjacent path must not pass containment")
            return
        }
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: evilPath))
    }

    @Test func symbolicLinkEscapeRejected() throws {
        let root = tempDir("link")
        let sibling = tempDir("linktarget")
        let fileURL = sibling.appendingPathComponent("f.bin")
        try Data("x".utf8).write(to: fileURL)
        let inside = root.appendingPathComponent("duck.bin")
        try? FileManager.default.removeItem(at: inside)
        try FileManager.default.createSymbolicLink(at: inside, withDestinationURL: fileURL)
        let verdict = FileGateway.verdictForPieceWrite(candidate: inside, saveRoot: root)
        guard case .rejected = verdict else {
            Issue.record("symlink resolving outside root must be rejected")
            return
        }
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: sibling)
    }

    @Test func missingTargetRejected() throws {
        let root = tempDir("missing")
        let verdict = FileGateway.verdictForPieceWrite(
            candidate: root.appendingPathComponent("nope.bin"), saveRoot: root)
        guard case .rejected = verdict else {
            Issue.record("missing file must be rejected")
            return
        }
        try? FileManager.default.removeItem(at: root)
    }

    @Test func directoryAsTargetRejected() throws {
        let root = tempDir("dirtarget")
        let sub = root.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        guard case .rejected = FileGateway.verdictForPieceWrite(candidate: sub, saveRoot: root) else {
            Issue.record("directory must not be accepted as write target")
            return
        }
        try? FileManager.default.removeItem(at: root)
    }

    @Test func openVerifierBlocksSystemRootsAndMissingPaths() {
        // macOS has no /proc; verify both the rejection memo for a missing
        // path and the system-root block for a path that does exist.
        #expect(
            FileGateway.verdictForOpeningDirectory("/proc/7/dotnet")
                == .rejected("not an existing directory"))
        #expect(
            FileGateway.verdictForOpeningDirectory("/private/var/db")
                == .rejected("system-protected root"))
        #expect(
            FileGateway.verdictForOpeningDirectory("/definitely/not/here/\(UUID().uuidString)")
                == .rejected("not an existing directory"))
        let existing = tempDir("open")
        #expect(FileGateway.verdictForOpeningDirectory(existing.path) == .allowed)
        try? FileManager.default.removeItem(at: existing)
    }

    @Test func traversalSegmentsNeutralizedByCanonicalization() throws {
        let root = tempDir("traverse")
        let kid = root.appendingPathComponent("kid")
        try FileManager.default.createDirectory(at: kid, withIntermediateDirectories: true)
        // Two ".." steps: algebra bounces the target out of `root` entirely
        // (one up through `root`, one through `kid`'s parent). Canonicalization
        // must expose that BEFORE any containment gate can run.
        let sneaky = root.appendingPathComponent("kid/../escape.bin")
        let canonical = FileGateway.canonicalized(sneaky.path)
        // `kid/../` collapses back to `root` itself, so the escape lands at
        // root/escape.bin — canonicalization must resolve both steps.
        #expect(canonical.deletingLastPathComponent().path
            == root.resolvingSymlinksInPath().path)
        #expect(canonical.lastPathComponent == "escape.bin")
        // And a deeper hop that leaves the root must be rejected outright.
        let deeper = FileGateway.canonicalized(
            root.appendingPathComponent("kid/../../escape.bin").path)
        guard case .rejected = FileGateway.verdictForPieceWrite(
            candidate: deeper, saveRoot: root) else {
            Issue.record("a '..' path resolving outside the root must be rejected")
            return
        }
        try? FileManager.default.removeItem(at: root)
    }
}

