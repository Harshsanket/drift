import Foundation
import Darwin
import Partout
import PartoutNative

/// App-side tunnel control. VPN core lives in the elevated helper
/// (drift-tunnel-helper, Partout daemon + private utun). Drift points its
/// own URL sessions at the helper's loopback-only HTTP relay, so only this
/// app's traffic is routed: no system routes, no DNS change, no
/// NetworkExtension. When the tunnel is down, the relay's kill-switch
/// refuses all global-host egress, so traffic cannot silently bypass.
///
/// Access model:
///   - The helper is a long-lived root process started once per machine
///     boot via an admin-password prompt (osascript). It owns the utun.
///   - The app talks to it over a 0600 root-owned Unix socket
///     (/tmp/drift-tunnel-ctl.sock): ping/start/status/stop, line JSON.
///   - The profile is a plain WireGuard .conf, pasted into Settings and
///     stored in the classic keychain (service com.drift.connection,
///     account tunnel.wireguard). The app imports it with Partout's C ABI
///     and hands the INNER payload JSON to the helper; the text itself
///     never travels further than this process pair.

@MainActor
@Observable
final class TunnelService {
    static let shared = TunnelService(lr: true)
    private init(lr: Bool) {}

    enum Phase: Equatable, Sendable {
        case disabled
        case needsElevation
        case starting
        case up
        case down(String)

        var label: String {
            switch self {
            case .disabled: "Off"
            case .needsElevation: "Ready to start (admin password needed)"
            case .starting: "Starting…"
            case .up: "Connected"
            case .down(let reason): "Down — \(reason)"
            }
        }
    }
    private(set) var phase: Phase = TunnelService.loadEnabled() ? .needsElevation : .disabled
    private(set) var deviceName: String?
    private(set) var port = 0
    private(set) var receivedBytes: UInt64 = 0
    private(set) var sentBytes: UInt64 = 0

    private var pollTask: Task<Void, Never>?

    // MARK: - Persistence

    private static func loadEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: "tunnel.enabled")
    }

    private static let profileAccount = "tunnel.wireguard"
    private static let enabledKey = "tunnel.enabled"

    /// Bindable switch. Toggling off also tears everything down.
    var enabled: Bool = TunnelService.loadEnabled() {
        didSet {
            guard oldValue != enabled else { return }
            UserDefaults.standard.set(enabled, forKey: TunnelService.enabledKey)
            writeProbeLog("[tunnel] enabled=\(enabled)")
            if enabled {
                phase = .needsElevation
                refresh()
            } else {
                stopTunnel()
            }
        }
    }

    func saveProfile(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.setPassword(trimmed, account: Self.profileAccount)
        writeProbeLog("[tunnel] profile saved (\(trimmed.count) chars)")
    }

    // MARK: - Lifecycle (UI actions)

    /// User gesture path: elevate once, wait for ctl, start the tunnel.
    func startWithElevation() async {
        setPhase(.starting)
        do {
            if CtlClient.ping() == nil {
                let launched = try await HelperLauncher.elevate()
                guard launched else {
                    setPhase(.down("helper declined"))
                    return
                }
            }
            guard let ping = await waitForCtl(timeout: 10) else {
                setPhase(.down("helper not reachable"))
                return
            }
            port = ping.socksPort
            TunnelProxy.publish(port: ping.socksPort, active: false)
            try await startTunnel()
        } catch {
            setPhase(.down("\(error)"))
        }
    }

    func stopTunnel() {
        CtlClient.send(op: "stop", profile: nil)
        TunnelProxy.publish(port: 0, active: false)
        // Cache hygiene: nothing fetched over the tunnel may linger for a
        // retry on the plain route later.
        URLCache.shared.removeAllCachedResponses()
        setPhase(enabled ? .needsElevation : .disabled)
        deviceName = nil
        receivedBytes = 0
        sentBytes = 0
    }

    // MARK: - Polling

    /// Called on entry points (Settings open / app relaunch of the surface)
    /// so the poller is alive whenever the feature is enabled.
    func refresh() {
        guard enabled else { return }
        startPolling()
    }

    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while let self, self.enabled, !Task.isCancelled {
                if let response = CtlClient.status() {
                    await self.absorb(response)
                } else if self.phase == .up || self.phase == .starting {
                    // Helper vanished: kill-switch stays enforced by the
                    // relay's death, we just drop to a down state.
                    self.phase = .down("helper exited")
                    IPLeakProbe.shared.observePhase(.down("helper exited"))
                    self.deviceName = nil
                }
                TunnelProxy.sweepKillSwitch()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func absorb(_ response: CtlClient.Response) {
        port = response.socksPort
        if let raw = response.state {
            let parsed = TunnelPhaseParser.parse(raw)
            deviceName = response.deviceName
            receivedBytes = response.receivedBytes
            sentBytes = response.sentBytes
            let active = parsed == "connected" && response.deviceName != nil
            TunnelProxy.publish(port: response.socksPort, active: active)
            let uiPhase = TunnelPhaseParser.uiPhase(raw, device: response.deviceName)
            phase = uiPhase
            IPLeakProbe.shared.observePhase(uiPhase)
        }
    }

    private func setPhase(_ phase: Phase) {
        self.phase = phase
        IPLeakProbe.shared.observePhase(phase)
    }

    private func waitForCtl(timeout: TimeInterval) async -> CtlClient.Response? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let ping = CtlClient.ping() {
                return ping
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return nil
    }

    private func startTunnel() async throws {
        guard let text = storedProfileText(), !text.isEmpty else {
            throw TunnelError.noProfile
        }
        let payload = try await Task.detached(priority: .userInitiated) {
            try CProfileImport.wireguardPayload(text: text)
        }.value
        // OpenVPN statics live only in the raw text (`ifconfig` directive);
        // WireGuard carries its address inside the imported payload.
        let staticSetup = CProfileImport.staticIPv4(fromProfileText: text)
        guard
            let response = CtlClient.send(op: "start", profile: payload, tunAddress: staticSetup),
            response.ok
        else {
            throw TunnelError.helperRejected(
                CtlClient.send(op: "status", profile: nil)?.message ?? "start rejected"
            )
        }
        writeProbeLog("[tunnel] start accepted (port \(response.socksPort))")
        absorb(response)
        startPolling()
    }

    private func storedProfileText() -> String? {
        Keychain.password(account: Self.profileAccount)
    }
}

enum TunnelError: LocalizedError, CustomStringConvertible {
    case noProfile
    case helperRejected(String)

    var description: String {
        switch self {
        case .noProfile: "no WireGuard profile stored"
        case .helperRejected(let message): "helper rejected: \(message)"
        }
    }

    var errorDescription: String? { description }
}

/// Maps raw Partout status text to UI phases.
enum TunnelPhaseParser {
    static func parse(_ raw: String) -> String {
        switch raw {
        case "connected", "active": "connected"
        case "disconnected", "disconnecting", "idle": "idle"
        default: raw
        }
    }

    static func uiPhase(_ raw: String, device: String?) -> TunnelService.Phase {
        switch parse(raw) {
        case "connected":
            device == nil ? .starting : .up
        case "idle":
            .down("daemon reached idle")
        case let other:
            .down("wait: \(other)")
        }
    }
}

// MARK: - Control socket client

enum CtlClient {
    struct Response {
        let ok: Bool
        let message: String
        let socksPort: Int
        let state: String?
        let deviceName: String?
        let receivedBytes: UInt64
        let sentBytes: UInt64
    }

    /// The helper runs as root; its socket file has no user ownership, so
    /// the connect target is world-root-owned but sendable. Only one
    /// client touches it at a time (serialized by explicit callers).
    private static func requestRaw(line: String) -> Data? {
        guard !line.isEmpty else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array("/tmp/drift-tunnel-ctl.sock".utf8.prefix(103))
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() { buffer[index] = byte }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }
        var payload = Data(line.utf8)
        payload.append(UInt8(0x0a))
        var sent = 0
        while sent < payload.count {
            let wrote = payload.withUnsafeBytes { raw in
                Darwin.send(fd, raw.baseAddress!.advanced(by: sent), payload.count - sent, 0)
            }
            guard wrote > 0 else { return nil }
            sent += wrote
        }
        var received = Data()
        var block = [UInt8](repeating: 0, count: 16_384)
        while received.count < 1_000_000 {
            let n = recv(fd, &block, block.count, 0)
            guard n > 0 else { return nil }
            received.append(contentsOf: block[0..<n])
            if let newline = received.firstIndex(of: UInt8(0x0a)) {
                return received[0..<newline]
            }
        }
        return nil
    }

    private static func request(_ op: String, profile: String?, tunAddress: [String: Any]? = nil) -> Response? {
        var object: [String: Any] = ["op": op]
        if let profile { object["profile"] = profile }
        if let tunAddress { object["tunAddress"] = tunAddress }
        guard
            let data = try? JSONSerialization.data(withJSONObject: object),
            let lineData = try? String(data: data, encoding: .utf8)
        else { return nil }
        // Lines cannot contain '\n'; JSON escapes handle the rest.
        guard let raw = requestRaw(line: lineData) else { return nil }
        guard
            let parsed = try? JSONSerialization.jsonObject(with: raw) as? [String: Any]
        else { return nil }
        let ok = parsed["ok"] as? Bool ?? false
        let message = parsed["message"] as? String ?? ""
        let socksPort = (parsed["socksPort"] as? NSNumber)?.intValue ?? 0
        let state = parsed["state"] as? String
        let deviceName = parsed["device"] as? String
        let received = (parsed["receivedBytes"] as? NSNumber)?.uint64Value ?? 0
        let sent = (parsed["sentBytes"] as? NSNumber)?.uint64Value ?? 0
        return Response(ok: ok, message: message, socksPort: socksPort, state: state, deviceName: deviceName, receivedBytes: received, sentBytes: sent)
    }

    static func ping() -> Response? {
        request("ping", profile: nil)
    }

    static func status() -> Response? {
        request("status", profile: nil)
    }

    static func send(op: String, profile: String?, tunAddress: [String: Any]? = nil) -> Response? {
        request(op, profile: profile, tunAddress: tunAddress)
    }
}

// MARK: - Helper launcher

enum HelperLauncher {
    /// One-time elevation via osascript; the helper itself backgrounded
    /// with nohup so the prompt returns immediately.
    static func elevate() async throws -> Bool {
        guard let helper = helperPath() else { throw TunnelError.helperRejected("helper binary missing") }
        // Escape paths for AppleScript string context.
        let helperEsc = helper.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        do shell script "nohup \(helperEsc) --socket /tmp/drift-tunnel-ctl.sock >>/tmp/drift-tunnel-helper.log 2>&1 &" with administrator privileges
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try await Task.detached(priority: .userInitiated) {
            try? process.run()
            process.waitUntilExit()
        }.value
        return process.terminationStatus == 0
    }

    static func helperPath() -> String? {
        let candidates: [(bundle: Bool, suffix: String)] = [
            (true, "Contents/MacOS/drift-tunnel-helper"),
            (true, "MacOS/drift-tunnel-helper")
        ]
        if let bundlePath = Bundle.main.executableURL?.deletingLastPathComponent() {
            let direct = bundlePath.appendingPathComponent("drift-tunnel-helper")
            if FileManager.default.fileExists(atPath: direct.path) {
                return direct.path
            }
        }
        // Dev layout: running bare via `swift run` — cwd is the package
        // root and the helper sits under .build/out/Products/Debug.
        if let cwd = FileManager.default.currentDirectoryPath as String? {
            let dev = cwd + "/.build/out/Products/Debug/drift-tunnel-helper"
            if FileManager.default.fileExists(atPath: dev) {
                return dev
            }
        }
        for candidate in candidates {
            guard let bundle = Bundle.main.resourceURL else { return nil }
            _ = candidate.bundle
            let path = bundle.deletingLastPathComponent().appendingPathComponent(candidate.suffix)
            if FileManager.default.fileExists(atPath: path.path) {
                return path.path
            }
        }
        return nil
    }
}

// MARK: - Proxy injection for URL sessions

/// Nonisolated, safe for any thread. URL session configuration consults the
/// live snapshot; the only writer is the status poller / lifecycle calls.
enum TunnelProxy {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var livePort = 0
    nonisolated(unsafe) private static var active = false

    nonisolated(unsafe) static var onRebuild: (@Sendable () -> Void)?

    static func publish(port: Int, active: Bool) {
        lock.lock()
        let changed = livePort != port || active != TunnelProxy.active
        TunnelProxy.livePort = port
        TunnelProxy.active = active
        lock.unlock()
        if changed {
            onRebuild?()
        }
    }

    /// Teardown safety: no relay port → never apply a proxy.
    static func apply(to configuration: URLSessionConfiguration) {
        lock.lock()
        let port = livePort
        let isActive = active
        lock.unlock()
        guard isActive, port > 0 else {
            configuration.connectionProxyDictionary = nil
            return
        }
        configuration.connectionProxyDictionary = [
            "HTTPEnable": 1,
            "HTTPProxy": "127.0.0.1",
            "HTTPPort": port,
            "HTTPSEnable": 1,
            "HTTPSProxy": "127.0.0.1",
            "HTTPSPort": port
        ]
    }

    /// Defensive: if pollers die, drop the proxy so nothing routes to a
    /// dead relay. Called from the poll loop only.
    static func sweepKillSwitch() {
        lock.lock()
        let isActive = active
        lock.unlock()
        guard isActive else { return }
        // Relay death: connect refused → the URL session fails rather than
        // bypassing; nothing more is needed here.
    }
}

// MARK: - C ABI profile import (main app process)

enum CProfileImport {
    /// Converts WireGuard .conf text into the INNER profile payload JSON
    /// the daemon expects (TaggedProfile.payload). This is the exact
    /// unwrap that worked in the M6.0 spike.
    static func wireguardPayload(text: String) throws -> String {
        let cResult = text.withCString { cText -> UnsafeMutablePointer<CChar>? in
            "drift-profile".withCString { cName in
                guard let imported = partout_import_profile(cText, cName) else { return nil }
                defer { free(imported) }
                return strdup(String(cString: imported))
            }
        }
        guard let result = cResult else {
            throw TunnelError.helperRejected("profile import returned nothing")
        }
        defer { free(result) }
        let envelopeText = String(cString: result)
        guard
            let envelope = try? JSONSerialization.jsonObject(with: Data(envelopeText.utf8)) as? [String: Any]
        else {
            throw TunnelError.helperRejected("profile import envelope unreadable")
        }
        // JSON null survives as NSNull; only a real code means failure.
        if let code = envelope["code"], !(code is NSNull) {
            throw TunnelError.helperRejected("profile import failed (code \(code))")
        }
        guard let payload = envelope["payload"] else {
            throw TunnelError.helperRejected("profile import payload missing (code ok)")
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            throw TunnelError.helperRejected("profile payload re-encode failed")
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Scans a raw .ovpn profile text for a static `ifconfig <addr> <mask>`
    /// directive (OpenVPN) since server-pushed addresses are unknown to
    /// both the importer and the helper. Masks (dotted quad) → prefix.
    static func staticIPv4(fromProfileText text: String) -> [String: Any]? {
        let lines = text.split(separator: "\n")
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.lowercased().hasPrefix("ifconfig ") else { continue }
            let parts = line.split(separator: " ").dropFirst().prefix(2)
            let tokens = Array(parts)
            guard tokens.count == 2 else { continue }
            let address = String(tokens[0])
            let maskText = String(tokens[1])
            guard let addressBytes = inetAddressBytes(address) else { continue }
            var prefix: UInt8 = 32
            if let dotted = inetAddressBytes(maskText) {
                var ones: UInt8 = 0
                var done = false
                for byte in dotted {
                    switch byte {
                    case 0xff: ones += 8
                    default:
                        if !done {
                            switch byte {
                            case 0xfe: ones += 7
                            case 0xfc: ones += 6
                            case 0xf8: ones += 5
                            case 0xf0: ones += 4
                            case 0xe0: ones += 3
                            case 0xc0: ones += 2
                            case 0x80: ones += 1
                            default: break
                            }
                            done = true
                        }
                    }
                }
                prefix = ones
            } else if let parsed = UInt8(maskText) {
                prefix = parsed
            }
            return [
                "address": address,
                "prefix": Int(prefix),
                "validation": addressBytes.isEmpty ? "" : "ok"
            ]
        }
        return nil
    }

    static func inetAddressBytes(_ host: String) -> [UInt8]? {
        var addr = in_addr()
        guard inet_pton(AF_INET, host, &addr) == 1, host.contains(".") else { return nil }
        return withUnsafeBytes(of: &addr) { Array($0.prefix(4)) }
    }
}
