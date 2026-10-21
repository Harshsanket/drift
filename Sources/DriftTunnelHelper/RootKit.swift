import Foundation

/// Root operations for the private utun device. The daemon creates the
/// device itself (its C fallback path succeeds in an elevated helper);
/// this file discovers the interface, assigns the profile's IPv4 address,
/// and lets the relay bind egress through it. Nothing else touches the
/// system: no routes, no DNS override, no NetworkExtension.

enum HelperError: Error, CustomStringConvertible, LocalizedError {
    case ioctlFailed(Int32, String)
    case daemonStart(Int32)
    case noTunnel
    case profileBad(String)
    case notRoot

    var description: String {
        switch self {
        case .ioctlFailed(let code, let call): "ioctl[\(call)] failed \(code)"
        case .daemonStart(let code): "daemon start failed \(code)"
        case .noTunnel: "tunnel device did not appear"
        case .profileBad(let detail): "profile parse failed: \(detail)"
        case .notRoot: "helper must run as root"
        }
    }

    var errorDescription: String? { description }
}

struct TunnelDevice: Hashable, Sendable {
    let name: String
    let interfaceIndex: UInt32
}

enum RootKit {
    struct IPv4Setup: Sendable {
        let address: String
        let prefix: UInt8
    }

    enum RouteClass: Sendable {
        case loopback
        case privateLAN
        case global
    }

    static func bypassClass(host: String) -> RouteClass {
        if host == "localhost" || host == "::1" || host.hasPrefix("127.") { return .loopback }
        if let bytes = numericBytes(host) {
            if bytes[0] == 10 { return .privateLAN }
            if bytes[0] == 172 && (bytes[1] & 0xf0) == 16 { return .privateLAN }
            if bytes[0] == 192 && bytes[1] == 168 { return .privateLAN }
            if bytes[0] == 169 && bytes[1] == 254 { return .privateLAN }
        }
        return .global
    }

    static func numericBytes(_ host: String) -> [UInt8]? {
        var addr = in_addr()
        guard inet_pton(AF_INET, host, &addr) == 1 else { return nil }
        return withUnsafeBytes(of: &addr) { Array($0.prefix(4)) }
    }

    static func currentUTunInterfaces() -> Set<String> {
        var names: Set<String> = []
        var ifap: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ifap) == 0, let head = ifap else { return names }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        while let node = cursor {
            if let name = node.pointee.ifa_name {
                let text = String(cString: name)
                if text.hasPrefix("utun") { names.insert(text) }
            }
            cursor = node.pointee.ifa_next
        }
        return names
    }

    static func discoverNewUTun(known: Set<String>, timeout: TimeInterval) async throws -> TunnelDevice {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let current = currentUTunInterfaces()
            if let added = current.subtracting(known).max() {
                return TunnelDevice(name: added, interfaceIndex: if_nametoindex(added))
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw HelperError.noTunnel
    }

    /// Extracts the first IPv4 address+prefix from a serialized profile
    /// payload. WireGuard modules always carry interface addresses;
    /// OpenVPN modules generally don't (addr comes from the server push),
    /// in which case supplying a static `ifconfig` directive client-side
    /// or falling back to the placeholder below is required.
    static func extractIPv4(fromProfilePayload data: Data) throws -> IPv4Setup {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let modules = object["modules"] as? [[String: Any]]
        else {
            throw HelperError.profileBad("modules missing")
        }
        for module in modules {
            guard module["type"] as? String == "WireGuard" else { continue }
            guard
                let value = module["value"] as? [String: Any],
                let configuration = value["configuration"] as? [String: Any],
                let interface = configuration["interface"] as? [String: Any],
                let addresses = interface["addresses"] as? [String]
            else { continue }
            for address in addresses {
                let parts = address.split(separator: "/")
                guard parts.count >= 1 else { continue }
                var prefix: UInt8 = 32
                if parts.count >= 2, let parsed = UInt8(parts[1]) { prefix = parsed }
                if numericBytes(String(parts[0])) != nil {
                    return IPv4Setup(address: String(parts[0]), prefix: prefix)
                }
            }
        }
        throw HelperError.profileBad("no IPv4 address in WireGuard profile")
    }

    /// Placeholder address for OpenVPN profiles whose tunnel IP is pushed
    /// by the server (no static `ifconfig` directive). Egress binds to the
    /// utun interface regardless of source address; the placeholder only
    /// gives the kernel something to emit from.
    static let placeholderSetup = IPv4Setup(address: "10.222.58.2", prefix: 32)

    /// `_IOWR('i', 12, struct ifaliasreq)`; Swift cannot import the macro,
    /// and the prebuilt constant equals 0xC040690C (size 64, group 0x69).
    private static let siocaifaddr: u_long = 0xc0_40_69_0c

    static func assignIPv4(device: TunnelDevice, setup: IPv4Setup) throws {
        guard getuid() == 0 else { throw HelperError.notRoot }
        guard let addressBytes = numericBytes(setup.address) else {
            throw HelperError.profileBad("bad IPv4 address \(setup.address)")
        }
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw HelperError.ioctlFailed(errno, "open") }
        defer { close(fd) }

        var maskBytes: [UInt8] = []
        var remaining = setup.prefix
        for _ in 0..<4 {
            if remaining >= 8 {
                maskBytes.append(0xff)
                remaining -= 8
            } else if remaining > 0 {
                maskBytes.append(UInt8(0xff << (8 - remaining)))
                remaining = 0
            } else {
                maskBytes.append(0)
            }
        }

        var nameBytes = [CChar](repeating: 0, count: Int(IFNAMSIZ))
        let utf8 = Array(device.name.utf8.prefix(Int(IFNAMSIZ) - 1))
        for (index, byte) in utf8.enumerated() { nameBytes[index] = CChar(bitPattern: byte) }

        var request = ifaliasreq()
        withUnsafeMutableBytes(of: &request) { requestBuffer in
            withUnsafeMutableBytes(of: &nameBytes) { nameBuffer in
                memcpy(requestBuffer.baseAddress, nameBuffer.baseAddress, Int(IFNAMSIZ))
            }
            var sa = sockaddr_in()
            sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            sa.sin_family = UInt8(AF_INET)
            sa.sin_port = 0
            withUnsafeMutableBytes(of: &sa.sin_addr) { buffer in
                buffer.copyBytes(from: addressBytes)
            }
            withUnsafeMutableBytes(of: &sa) { saBuffer in
                memcpy(requestBuffer.baseAddress!.advanced(by: Int(IFNAMSIZ)), saBuffer.baseAddress, MemoryLayout<sockaddr_in>.size)
            }
            var zero = sockaddr_in()
            zero.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            zero.sin_family = UInt8(AF_INET)
            zero.sin_port = 0
            withUnsafeMutableBytes(of: &zero.sin_addr) { buffer in
                buffer.copyBytes(from: maskBytes)
            }
            withUnsafeMutableBytes(of: &zero) { maskBuffer in
                memcpy(requestBuffer.baseAddress!.advanced(by: Int(IFNAMSIZ) + MemoryLayout<sockaddr_in>.size * 2), maskBuffer.baseAddress, MemoryLayout<sockaddr_in>.size)
            }
        }

        let result = withUnsafeMutablePointer(to: &request) { pointer in
            ioctl(
                fd,
                siocaifaddr,
                pointer
            )
        }
        guard result == 0 else {
            throw HelperError.ioctlFailed(errno, "SIOCAIFADDR")
        }
    }
}
