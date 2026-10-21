import Foundation

/// Filesystem choke point for the booster and UI open affordances.
///
/// Everything reaching the local disk from untrusted sources (qB metadata),
/// or leaving toward system openers (NSWorkspace), passes through verdict
/// gates here. The gateway is display/policy only — no network, no logging
/// beyond opt-in probe lines.
enum FileGateway {
    enum Verdict: Equatable {
        case allowed
        case rejected(String)
    }

    static let maxPathLength = 4096

    /// Absolute, symlink-resolved form of a path string.
    static func canonicalized(_ raw: String) -> URL {
        let expanded = NSString(string: raw).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// Root-level sanity checks shared by all gates.
    static func rootCheck(_ canonical: URL) -> Verdict? {
        guard !canonical.path.isEmpty else { return .rejected("empty path") }
        guard canonical.path.count <= maxPathLength else { return .rejected("path too long") }
        guard !canonical.path.contains("\0") else { return .rejected("embedded NUL") }
        return nil
    }

    /// Can this directory be shown to the user via an opener? Read-only
    /// verdict: path must exist, be readable, and stay within the home
    /// volume's user-writable roots (gvfs/proc-style roots are rejected).
    static func canOpenDirectory(forDisplay raw: String) -> Bool {
        verdictForOpeningDirectory(raw) == .allowed
    }

    static func verdictForOpeningDirectory(_ raw: String) -> Verdict {
        let canonical = canonicalized(raw)
        if let block = rootCheck(canonical) { return block }
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: canonical.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return .rejected("not an existing directory") }
        guard manager.isReadableFile(atPath: canonical.path) else {
            return .rejected("directory unreadable")
        }
        // Forbidden roots: unix internals that should never be revealed
        // through the app even if a hostile save_path points there. Both
        // symlinked and canonical forms are listed (/var → /private/var).
        let blockedPrefixes = [
            "/proc", "/private/proc", "/sys", "/private/sys",
            "/dev", "/private/var/db", "/var/db"
        ]
        if blockedPrefixes.contains(where: { canonical.path == $0 || canonical.path.hasPrefix($0 + "/") }) {
            return .rejected("system-protected root")
        }
        return .allowed
    }

    /// Can the booster write piece bytes into this file? The file must sit
    /// under the same save root qB reported for the torrent, must already
    /// exist, and must be writable.
    static func verdictForPieceWrite(candidate: URL, saveRoot: URL) -> Verdict {
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
        if let block = rootCheck(resolved) { return block }
        let root = saveRoot.standardizedFileURL.resolvingSymlinksInPath()
        // Canonical containment: resolved file path must start with resolved
        // root + separator (so "/root-evil" does not match "/root").
        let rootPath = root.path.hasSuffix("/") ? String(root.path.dropLast()) : root.path
        guard resolved.path == rootPath || resolved.path.hasPrefix(rootPath + "/") else {
            return .rejected("outside save root")
        }
        let manager = FileManager.default
        guard manager.fileExists(atPath: resolved.path) else {
            return .rejected("target file missing")
        }
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else { return .rejected("target is a directory") }
        guard manager.isWritableFile(atPath: resolved.path) else {
            return .rejected("target not writable")
        }
        return .allowed
    }
}
