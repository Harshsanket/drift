import Foundation
import Darwin

/// Line-delimited JSON control socket. The app connects, sends one request
/// line, reads one response line. The socket is 0600 root-owned: only the
/// elevated helper can bind it; the app talks to it explicitly.

final class ControlDriver: @unchecked Sendable {
    struct Response: Codable {
        let ok: Bool
        let message: String
        let socksPort: Int
        let pid: Int
        let state: String
        let device: String?
        let error: String?
    }

    private let path: String
    private var listenFD: Int32 = -1
    private var acceptLoop: DispatchQueue
    private var serving = false

    /// Relay's port, reported in every response.
    var socksPort = 0

    init(path: String) {
        self.path = path
        acceptLoop = DispatchQueue(label: "drift-ctl", qos: .utility)
    }

    func start(onStart: @escaping (Data, RootKit.IPv4Setup?) throws -> Void, onStop: @escaping () -> Void) throws {
        unlink(path)
        // Socket inodes inherit the process umask at bind time; tighten it
        // so there is no window where the inode is group/world open.
        let oldMask = umask(0o077)
        defer { umask(oldMask) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HelperError.ioctlFailed(socket_errno, "ctl socket") }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8.prefix(103))
        for (index, byte) in pathBytes.enumerated() {
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                buffer[index] = byte
            }
        }
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw HelperError.ioctlFailed(0, "ctl bind")
        }
        // bind() already created the socket inode with default (world
        // readable) permissions; tighten it immediately. NOTE: never
        // FileManager.createFile over the socket afterwards — that would
        // replace the inode with a regular file and break path connects.
        _ = chmod(path, 0o600)
        guard listen(fd, 8) == 0 else {
            close(fd)
            throw HelperError.ioctlFailed(0, "ctl listen")
        }
        listenFD = fd
        serving = true

        acceptLoop.async { [weak self] in
            guard let self else { return }
            while self.serving {
                var clientLength = socklen_t(0)
                let client = accept(self.listenFD, nil, &clientLength)
                guard client >= 0 else { break }
                // Kernel-verified peer identity before any byte is read:
                // unknown uids are dropped without touching their payload.
                guard PeerGuard.accept(clientFD: client) else {
                    HelperLog.shared.write("ctl: rejected foreign peer (uid mismatch)")
                    close(client)
                    continue
                }
                self.serve(client: client, onStart: onStart, onStop: onStop)
            }
        }
    }

    private func serve(client: Int32, onStart: @escaping (Data, RootKit.IPv4Setup?) throws -> Void, onStop: @escaping () -> Void) {
        defer { close(client) }
        var buffer = [UInt8](repeating: 0, count: 64_000)
        guard let line = readLine(client: client, buffer: &buffer) else { return }
        guard
            let object = try? JSONSerialization.jsonObject(with: line),
            let fields = object as? [String: Any],
            let op = fields["op"] as? String
        else { return }
        var response: Response
        switch op {
        case "ping":
            response = .init(
                ok: true, message: "pong",
                socksPort: socksPort, pid: Int(getpid()),
                state: String(describing: TunnelDaemon.snapshot.state),
                device: TunnelDaemon.snapshot.device?.name,
                error: TunnelDaemon.snapshot.lastError
            )
        case "start":
            let payloadData = fields["profile"] as? String
            guard let payloadData, let data = payloadData.data(using: .utf8) else {
                response = .init(ok: false, message: "missing profile", socksPort: socksPort, pid: Int(getpid()), state: "idle", device: nil, error: nil)
                break
            }
            // Optional app-resolved static address (OpenVPN `ifconfig`).
            var directSetup: RootKit.IPv4Setup?
            if let tun = fields["tunAddress"] as? [String: Any],
               let address = tun["address"] as? String,
               let prefix = (tun["prefix"] as? NSNumber)?.uint8Value {
                directSetup = RootKit.IPv4Setup(address: address, prefix: prefix)
            }
            do {
                try onStart(data, directSetup)
                response = .init(
                    ok: true, message: "starting",
                    socksPort: socksPort, pid: Int(getpid()),
                    state: String(describing: TunnelDaemon.snapshot.state),
                    device: TunnelDaemon.snapshot.device?.name,
                    error: TunnelDaemon.snapshot.lastError
                )
            } catch {
                response = .init(ok: false, message: "\(error)", socksPort: socksPort, pid: Int(getpid()), state: "idle", device: nil, error: nil)
            }
        case "status":
            response = .init(
                ok: true, message: "ok",
                socksPort: socksPort, pid: Int(getpid()),
                state: String(describing: TunnelDaemon.snapshot.state),
                device: TunnelDaemon.snapshot.device?.name,
                error: TunnelDaemon.snapshot.lastError
            )
        case "stop":
            onStop()
            response = .init(
                ok: true, message: "stopped",
                socksPort: socksPort, pid: Int(getpid()),
                state: "idle", device: nil, error: nil
            )
        default:
            response = .init(ok: false, message: "unknown op", socksPort: socksPort, pid: Int(getpid()), state: "idle", device: nil, error: nil)
        }
        if
            let encoded = try? JSONEncoder().encode(response),
            var out = String(data: encoded, encoding: .utf8)?.appending("\n").data(using: .utf8)
        {
            _ = out.withUnsafeBytes { raw in
                send(client, raw.baseAddress, raw.count, 0)
            }
        }
    }

    private func readLine(client: Int32, buffer: inout [UInt8]) -> Data? {
        var line = Data()
        while line.count < 10_000_000 {
            let n = recv(client, &buffer, buffer.count, 0)
            guard n > 0 else { return nil }
            line.append(contentsOf: buffer[0..<n])
            if let index = line.firstIndex(of: UInt8(ascii: "\n")) {
                return line[0..<index]
            }
        }
        return nil
    }

    private var socket_errno: Int32 { errno }
}

let socket_errno = 0
