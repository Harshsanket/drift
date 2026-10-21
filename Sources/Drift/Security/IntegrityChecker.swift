import CryptoKit
import Foundation

/// Self-verification of the running bundle + detached EdDSA verification
/// of update parts.
///
/// The release pipeline (Scripts/package-release.sh) produces:
///   Contents/Resources/IntegrityManifest.json     { version, entries }
///   Contents/Resources/IntegrityManifest.json.sig Ed25519(EdDSA) sig
///
/// The manifest covers every file inside Contents (except the manifest and
/// its signature), keyed by path relative to Contents. On launch — when the
/// manifest is present, which excludes dev `swift run` builds — the app
/// re-hashes its files and validates them against the embedded public key.
///
/// Verification is advisory for the UI (state observable, surfaced in probe
/// logs and Settings), never a silent "trusted" claim: a missing manifest
/// reports `unavailable`, never `verified`.
enum IntegrityChecker {
    // Generated once; the PRIVATE half lives with the release signer only
    // (~/drift-signing/drift-eddsa.private). This app embeds just the
    // public key, as required for verification-only code.
    static let edDSAPublicKeyBase64 = "xYqeTNKL36lOZTYmMc/rblo81WuGvpjLNpXE2MK1CTY="

    static let manifestResource = "IntegrityManifest.json"
    static let signatureResource = "IntegrityManifest.json.sig"

    enum Result: Equatable {
        /// Embedded manifest found, all hashes matched, signature valid.
        case verified
        /// No manifest (dev build / swift run): verification not possible,
        /// which is an honest distinct state, not a pass.
        case manifestMissing
        /// Manifest present but detached signature file missing.
        case signatureMissing
        /// Signature invalid, or one or more files do not match.
        case tampered(detail: String)
        /// Manifest unreadable/malformed or public key invalid.
        case unavailable(reason: String)

        var shortLabel: String {
            switch self {
            case .verified: "Verified"
            case .manifestMissing: "Unverified (dev build)"
            case .signatureMissing: "Signature missing"
            case .tampered: "Verification failed"
            case .unavailable: "Verification unavailable"
            }
        }
    }

    struct Manifest: Codable {
        let version: Int
        let entries: [String: String]
    }

    // MARK: - Launch verification

    @MainActor
    static func verifyRunningBundle() -> Result {
        guard let root = Bundle.main.resourceURL else {
            return .unavailable(reason: "no bundle resources")
        }
        let contentsRoot = root.deletingLastPathComponent()
        return verify(contentsRoot: contentsRoot)
    }

    /// Verifies manifest → signature → hashes inside a Contents/ root.
    /// `keyOverride` swaps the embedded public key for a throwaway test
    /// key; production callers never pass it.
    static func verify(contentsRoot rawRoot: URL, keyOverride: String? = nil) -> Result {
        // /var and /private/var resolve through each other on macOS; the
        // manifest was built against one of them, verification must agree.
        let contentsRoot = URL(fileURLWithPath: FileInventory.canonicalPath(rawRoot.path))
        let manifestURL = contentsRoot
            .appendingPathComponent("Resources")
            .appendingPathComponent(manifestResource)
        guard let manifestData = try? Data(contentsOf: manifestURL) else {
            return .manifestMissing
        }
        let signatureURL = manifestURL.appendingPathExtension("sig")
        guard let signatureData = try? Data(contentsOf: signatureURL) else {
            return .signatureMissing
        }
        // 1) Signer check: manifest bytes against the pinned EdDSA key.
        let keyBase64 = keyOverride ?? edDSAPublicKeyBase64
        guard verifyRawBytes(manifest: manifestData, signatureData: signatureData, publicKeyBase64: keyBase64) else {
            return .tampered(detail: "manifest signature invalid")
        }
        // 2) Content check: every recorded entry re-hashed and compared.
        guard let decoded = try? JSONDecoder().decode(Manifest.self, from: manifestData) else {
            return .unavailable(reason: "manifest unreadable")
        }
        var mismatches: [String] = []
        for (relative, expected) in decoded.entries {
            let fileURL = contentsRoot.appendingPathComponent(relative)
            guard let data = try? Data(contentsOf: fileURL) else {
                mismatches.append("\(relative): unreadable")
                continue
            }
            let digest = SHA256.hash(data: data)
            let hex = digest.compactMap { String(format: "%02x", $0) }.joined()
            if hex != expected { mismatches.append(relative) }
        }
        // Covered files that vanished from the bundle entirely would still
        // be caught above ("unreadable"), but NEW unexpected files cannot
        // be detected by hash comparison alone — record coverage explicitly.
        let actual = FileInventory.inventory(contentsRoot: contentsRoot)
        for (relative, _) in actual where decoded.entries[relative] == nil {
            mismatches.append("\(relative): not in manifest")
        }
        if mismatches.isEmpty { return .verified }
        return .tampered(detail: mismatches.prefix(8).joined(separator: "; "))
    }

    static func verifyManifestSignature(manifest: Data, signature: Data) -> Bool {
        verifyRawBytes(
            manifest: manifest, signatureData: signature,
            publicKeyBase64: edDSAPublicKeyBase64)
    }

    private static func verifyRawBytes(
        manifest: Data, signatureData: Data, publicKeyBase64: String
    ) -> Bool {
        guard let raw = Data(base64Encoded: publicKeyBase64) else { return false }
        guard
            let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
        else { return false }
        let sig = Data(base64Encoded: String(decoding: signatureData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? signatureData
        return (try? key.isValidSignature(sig, for: manifest)) ?? false
    }

    // MARK: - Update payload check

    enum UpdatePayloadVerdict: Equatable {
        case accepted
        case rejected(String)
    }

    /// Detached-EdDSA verification of an update archive against the same
    /// embedded key. The signature file contains base64 Ed25519, exactly
    /// like Sparkle's EdDSA flow (key-compatible: Curve25519/Ed25519).
    static func verifyUpdatePayload(payload: Data, signatureFile: URL) -> UpdatePayloadVerdict {
        guard !payload.isEmpty else { return .rejected("empty payload") }
        guard let fileData = try? Data(contentsOf: signatureFile) else {
            return .rejected("signature file missing")
        }
        let text = String(decoding: fileData, as: UTF8.self)
        return eddsaVerdict(payload: payload, signatureBase64: text)
    }

    static func eddsaVerdict(payload: Data, signatureBase64: String) -> UpdatePayloadVerdict {
        if verifyManifestSignature(manifest: payload, signature: Data(base64Encoded: signatureBase64) ?? Data()) {
            return .accepted
        }
        return .rejected("payload signature invalid")
    }

    // MARK: - Build support (used by release script / tests)

    static func buildManifest(contentsRoot rawRoot: URL) throws -> Data {
        let entries = FileInventory.inventory(
            contentsRoot: rawRoot.standardizedFileURL.resolvingSymlinksInPath())
        let manifest = Manifest(version: 1, entries: entries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(manifest)
    }

    /// Signs manifest bytes with a raw private key; release-time only, and
    /// here for unit tests with throwaway keys.
    static func sign(data: Data, privateKeyRaw: Data) throws -> Data {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyRaw)
        return try key.signature(for: data)
    }
}

/// Path → SHA256 map for everything under Contents, skipping the two
/// integrity artifacts themselves and non-content noise that changes on
/// every replica (thumb stores, dsym caches).
enum FileInventory {
    /// True POSIX canonical path (/var's symlink resolving must match what
    /// FileManager enumerators produce; URL utilities disagree here).
    static func canonicalPath(_ raw: String) -> String {
        guard raw.count < Int(PATH_MAX) else { return raw }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let resolved = raw.withCString { source in
            realpath(source, &buffer)
        }
        guard resolved == &buffer else { return raw }
        return String(cString: buffer)
    }

    static func inventory(contentsRoot rawRoot: URL) -> [String: String] {
        var result: [String: String] = [:]
        let base = canonicalPath(rawRoot.path)
        guard
            let enumerator = FileManager.default.enumerator(
                at: rawRoot.resolvingSymlinksInPath(),
                includingPropertiesForKeys: [.isRegularFileKey])
        else { return result }
        for case let url as URL in enumerator {
            guard url.isFileURL else { continue }
            let relatives = url.path.dropFirst(base.count + 1)
            guard !relatives.isEmpty else { continue }
            let relative = String(relatives)
            if relative == "Resources/IntegrityManifest.json" { continue }
            if relative.hasSuffix("IntegrityManifest.json.sig") { continue }
            if relative.hasPrefix("_CodeSignature/") || relative.contains("/_CodeSignature/") { continue }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true
            else { continue }
            guard let data = try? Data(contentsOf: url) else { continue }
            let digest = SHA256.hash(data: data)
            let hex = digest.compactMap { String(format: "%02x", $0) }.joined()
            result[relative] = hex
        }
        return result
    }
}
