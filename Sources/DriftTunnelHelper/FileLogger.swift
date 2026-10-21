import Foundation

enum HelperLog {
    static let shared = FileLogger()
}

final class FileLogger: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: FileHandle?

    init() {
        let path = "/tmp/drift-tunnel-helper.log"
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        handle = FileHandle(forWritingAtPath: path)
        try? handle?.seekToEnd()
    }

    func write(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        let stamp = String(format: "%.3f", Date().timeIntervalSince1970)
        let data = Data("[\(stamp)] \(line)\n".utf8)
        try? handle?.write(contentsOf: data)
    }
}
