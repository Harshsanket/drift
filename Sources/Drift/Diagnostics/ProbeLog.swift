import Foundation

/// Verification-only diagnostics sink. Disabled unless the process is started
/// with a `--test-*` verification hook or an explicit `--probe-log` opt-in, so
/// a normal launch never writes torrent metadata to disk. The log lives in the
/// per-user temporary directory (world-readable `/tmp` is off limits) with
/// `0600` permissions and is capped at 2 MB between runs.
///
/// Lives outside the UI directory intentionally: the frontend must stay free
/// of file I/O and socket primitives (see SecurityTests.uiBoundariesHold).
enum ProbeLog {
    static let isEnabled: Bool = {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--probe-log")
            || arguments.contains(where: { $0.hasPrefix("--test-") })
    }()

    static let fileURL: URL? = {
        guard isEnabled else { return nil }
        let manager = FileManager.default
        let url = manager.temporaryDirectory.appendingPathComponent("drift-probe.log")
        let path = url.path
        if let attributes = try? manager.attributesOfItem(atPath: path),
           let size = attributes[.size] as? NSNumber,
           size.intValue > 2_000_000 {
            try? manager.removeItem(atPath: path)
        }
        if !manager.fileExists(atPath: path) {
            manager.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        return url
    }()
}

/// Appends a line to the shared probe log; used by the engine, state layer
/// and the UI probe to record verification traces without console tooling.
func writeProbeLog(_ message: String) {
    guard let url = ProbeLog.fileURL else { return }
    let data = Data("\(message)\n".utf8)
    if let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    } else {
        try? data.write(to: url)
    }
}
