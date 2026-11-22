// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

enum HelperLog {
    static let shared = FileLogger()
}

final class FileLogger: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: FileHandle?

    init() {
        // Root daemon writes only to root-owned paths. O_NOFOLLOW prevents a
        // planted symlink from redirecting the log; if the open fails we
        // silently drop lines rather than crash the daemon or fall back to a
        // shared directory.
        let directory = "/var/log/drift"
        try? FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        let path = directory + "/drift-tunnel-helper.log"
        let fd = Darwin.open(
            path,
            O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW,
            0o600
        )
        guard fd >= 0 else { return }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    func write(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return }
        let stamp = String(format: "%.3f", Date().timeIntervalSince1970)
        let data = Data("[\(stamp)] \(line)\n".utf8)
        try? handle.write(contentsOf: data)
    }
}
