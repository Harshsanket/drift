import Foundation
import Darwin

/// Loopback-only HTTP CONNECT relay. The app points its URL sessions at
/// localhost:<port>; global targets egress through the private utun via
/// IP_BOUND_IF, loopback/LAN targets connect straight out. Kill-switch:
/// refusing global egress while the tunnel is down.

final class RelayServer: @unchecked Sendable {
    private var listenFD: Int32 = -1
    private(set) var port = 0
    private let acceptLoop: DispatchQueue
    private let pumpLoop: DispatchQueue

    init() {
        acceptLoop = DispatchQueue(label: "drift-relay-accept", qos: .userInitiated)
        pumpLoop = DispatchQueue(label: "drift-relay-pump", qos: .userInitiated, attributes: .concurrent)
    }

    func start() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HelperError.ioctlFailed(errno, "relay socket") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var relayAddress = sockaddr_in()
        relayAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        relayAddress.sin_family = UInt8(AF_INET)
        relayAddress.sin_port = 0
        relayAddress.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindResult = withUnsafePointer(to: &relayAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw HelperError.ioctlFailed(errno, "relay bind")
        }
        guard listen(fd, 16) == 0 else {
            close(fd)
            throw HelperError.ioctlFailed(errno, "relay listen")
        }
        var address = sockaddr()
        var length = socklen_t(MemoryLayout<sockaddr>.size)
        getsockname(fd, &address, &length)
        withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sockaddrPtr in
                port = Int(sockaddrPtr.pointee.sin_port.bigEndian)
            }
        }
        listenFD = fd
        HelperLog.shared.write("relay listening on 127.0.0.1:\(port)")

        acceptLoop.async { [weak self] in
            guard let self else { return }
            while true {
                let client = accept(self.listenFD, nil, nil)
                guard client >= 0 else { break }
                self.pumpLoop.async {
                    self.serve(client: client)
                }
            }
        }
    }

    struct Request {
        let isConnect: Bool
        let host: String
        let port: UInt16
        /// All bytes received so far, INCLUDING the request head and any
        /// early body bytes. Forwarded verbatim for non-CONNECT proxying.
        let received: Data
    }

    private func serve(client: Int32) {
        defer { close(client) }
        guard let request = readRequest(client: client) else {
            sendReply(client: client, status: 400, phrase: "Bad Request")
            return
        }
        let connectRemote: () -> Int32?
        switch RootKit.bypassClass(host: request.host) {
        case .loopback, .privateLAN:
            connectRemote = { [weak self] in self?.directConnect(host: request.host, port: request.port) }
        case .global:
            guard
                case .connected = TunnelDaemon.snapshot.state,
                let device = TunnelDaemon.snapshot.device
            else {
                // Kill-switch: refuse egress while the tunnel is down.
                sendReply(client: client, status: 502, phrase: "Tunnel Unavailable")
                return
            }
            connectRemote = { [weak self] in self?.tunnelConnect(host: request.host, port: request.port, device: device) }
        }
        guard let remote = connectRemote() else {
            sendReply(client: client, status: 502, phrase: "Bad Gateway")
            return
        }
        if request.isConnect {
            // Tunnel modes expect the preamble, then raw payload bytes.
            sendReply(client: client, status: 200, phrase: "Connection established")
        } else {
            // Absolute-form proxying: forward the original request
            // verbatim, stream the origin's reply back. No preamble.
            sendAll(to: remote, request.received)
        }
        pump(client: client, remote: remote)
    }

    /// Reads the request head. Accepts both CONNECT (curl's https:// form)
    /// and absolute-form forwarding (curl's http://url --proxy form):
    ///   CONNECT host[:port] HTTP/1.1
    ///   GET http://host[:port]/path HTTP/1.1
    private func readRequest(client: Int32) -> Request? {
        var buffer = [UInt8](repeating: 0, count: 8_192)
        var line = Data()
        while true {
            let n = recv(client, &buffer, buffer.count, 0)
            guard n > 0 else { return nil }
            line.append(contentsOf: buffer[0..<n])
            guard let range = line.range(of: Data([0x0d, 0x0a, 0x0d, 0x0a])) else { continue }
            guard let text = String(data: line[0..<range.lowerBound], encoding: .utf8) else { return nil }
            guard
                let firstLine = text.split(separator: "\r\n", omittingEmptySubsequences: false).first.map(String.init)
            else { return nil }
            let upper = firstLine.uppercased()
            let isConnect = upper.hasPrefix("CONNECT ")
            let isAbsolute = upper.hasPrefix("GET HTTP://") || upper.hasPrefix("HEAD HTTP://") ||
                upper.hasPrefix("POST HTTP://") || upper.hasPrefix("PUT HTTP://") ||
                upper.hasPrefix("DELETE HTTP://") || upper.hasPrefix("PATCH HTTP://")
            guard isConnect || isAbsolute else {
                HelperLog.shared.write("relay request rejected: unsupported method line '\(firstLine)'")
                return nil
            }
            let authority: String
            var port: UInt16 = isConnect ? 443 : 80
            if isConnect {
                let parts = firstLine.split(separator: " ")
                guard parts.count >= 2 else { return nil }
                authority = String(parts[1])
            } else {
                let scheme = "http://"
                guard let schemeEnd = firstLine.range(of: scheme, options: .caseInsensitive) else { return nil }
                let restAfterScheme = firstLine[schemeEnd.upperBound...]
                authority = String(restAfterScheme.split(separator: "/").first ?? "")
            }
            guard !authority.isEmpty else { return nil }
            var host = authority
            if authority.hasPrefix("["), let close = authority.firstIndex(of: "]") {
                host = String(authority[authority.index(authority.startIndex, offsetBy: 1)..<close])
                let afterClose = authority[authority.index(after: close)...]
                if afterClose.hasPrefix(":"), let parsed = UInt16(afterClose.dropFirst()) { port = parsed }
            } else if let colon = authority.lastIndex(of: ":") {
                if let parsed = UInt16(authority[authority.index(after: colon)...]) {
                    port = parsed
                    host = String(authority[..<colon])
                }
            }
            HelperLog.shared.write("relay request \(isConnect ? "CONNECT" : "FWD") \(host):\(port)")
            return Request(isConnect: isConnect, host: host, port: port, received: line)
        }
    }

    private func sendReply(client: Int32, status: Int, phrase: String) {
        let reply = "HTTP/1.1 \(status) \(phrase)\r\n\r\n"
        let data = Data(reply.utf8)
        _ = data.withUnsafeBytes { raw in
            send(client, raw.baseAddress, raw.count, 0)
        }
    }

    private func sendAll(to fd: Int32, _ data: Data) {
        guard !data.isEmpty else { return }
        var offset = 0
        var failed = false
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            while offset < data.count {
                let sent = send(fd, base.advanced(by: offset), data.count - offset, 0)
                if sent <= 0 {
                    HelperLog.shared.write("sendAll failed errno=\(errno) written=\(offset)/\(data.count)")
                    failed = true
                    return
                }
                offset += sent
            }
        }
        if failed {
            HelperLog.shared.write("sendAll abort (see errno above)")
        }
    }

    private func socketFor(device: TunnelDevice?, addressFamily: Int32) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        if let device {
            var index = device.interfaceIndex
            setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size))
        }
        return fd
    }

    /// Loopback / LAN egress through the default route.
    private func directConnect(host: String, port: UInt16) -> Int32? {
        connectIPv4(host: host, port: port, device: nil)
    }

    /// Global egress through the tunnel interface.
    private func tunnelConnect(host: String, port: UInt16, device: TunnelDevice) -> Int32? {
        connectIPv4(host: host, port: port, device: device)
    }

    private func connectIPv4(host: String, port: UInt16, device: TunnelDevice?) -> Int32? {
        // Resolve to IPv4 only. IPv6-only hosts are refused rather than
        // leaked: a v6 connect would bypass the v4-only tunnel.
        var addresses: [UInt8]? = RootKit.numericBytes(host)
        if addresses == nil {
            addresses = resolveHost(host)
        }
        guard let bytes = addresses else {
            HelperLog.shared.write("no IPv4 for host \(host); refusing (kill-switch)")
            return nil
        }
        let fd = socketFor(device: device, addressFamily: AF_INET)
        guard fd >= 0 else { return nil }
        var target = sockaddr_in()
        target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        target.sin_family = UInt8(AF_INET)
        target.sin_port = port.bigEndian
        withUnsafeMutableBytes(of: &target.sin_addr) { buffer in
            buffer.copyBytes(from: bytes)
        }
        let connected = withUnsafePointer(to: &target) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            HelperLog.shared.write("connect \(host):\(port) (iface \(device?.interfaceIndex ?? 0)) errno=\(errno)")
            close(fd)
            return nil
        }
        return fd
    }

    /// Plain A-record resolution via getaddrinfo. Current known limitation:
    /// hostname resolution uses the system resolver (flagged caveat).
    private func resolveHost(_ host: String) -> [UInt8]? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>? = nil
        guard getaddrinfo(host.cString(using: .utf8)!, nil, &hints, &result) == 0, result != nil else {
            return nil
        }
        defer { freeaddrinfo(result) }
        var cursor: UnsafeMutablePointer<addrinfo>? = result
        while let node = cursor {
            if Int32(node.pointee.ai_family) == AF_INET {
                var sinAddr = sockaddr_in()
                node.pointee.ai_addr!.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                    sinAddr = pointer.pointee
                }
                return withUnsafeBytes(of: sinAddr.sin_addr) { Array($0.prefix(4)) }
            }
            cursor = node.pointee.ai_next
        }
        return nil
    }

    private func pump(client: Int32, remote: Int32) {
        let group = DispatchGroup()
        group.enter(); group.enter()

        func pumpDirection(_ source: Int32, destination: Int32) {
            pumpLoop.async {
                defer { group.leave() }
                var buffer = [UInt8](repeating: 0, count: 16_384)
                while true {
                    let n = recv(source, &buffer, buffer.count, 0)
                    if n == 0 { break }
                    if n < 0 { break }
                    var written = 0
                    while written < n {
                        let sent = buffer.withUnsafeBytes { raw -> Int in
                            Int(send(destination, raw.baseAddress!.advanced(by: written), n - written, 0))
                        }
                        if sent <= 0 { break }
                        written += sent
                    }
                    if written < n { break }
                }
                shutdown(source, Int32(SHUT_RD))
                shutdown(destination, Int32(SHUT_WR))
            }
        }

        pumpDirection(client, destination: remote)
        pumpDirection(remote, destination: client)
        group.wait()
    }
}
