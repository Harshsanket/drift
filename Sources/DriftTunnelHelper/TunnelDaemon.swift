import Foundation
import Partout
import PartoutNative

/// Bridges this elevated helper into the Partout C daemon ABI. The whole
/// protocol engine lives HERE (no NetworkExtension involvement).

enum HelperState: CustomStringConvertible {
    case idle, starting, connecting, connected, dropped(String)

    var description: String {
        switch self {
        case .idle: "idle"
        case .starting: "starting"
        case .connecting: "connecting"
        case .connected: "connected"
        case .dropped(let reason): "dropped(\(reason))"
        }
    }

    static func parse(_ raw: String) -> HelperState {
        switch raw {
        case "connecting", "connecting_wait", "connecting_wait_reply":
            .connecting
        case "connected", "active":
            .connected
        case "disconnected", "disconnecting":
            .idle
        default:
            (raw.isEmpty || raw == "(none)") ? .idle : .dropped(raw)
        }
    }
}

struct TunnelSnapshot: Sendable {
    var state: HelperState = .idle
    var receivedBytes: UInt64 = 0
    var sentBytes: UInt64 = 0
    var device: TunnelDevice? = nil
    var lastError: String? = nil
}

// MARK: - C ABI trampolines (must not capture context)

private func driftLibLogger(_ ctx: UnsafeMutableRawPointer?, _ level: Int32, _ message: UnsafePointer<CChar>?) -> Void {
    guard let message else { return }
    HelperLog.shared.write("[lib-\(level)] \(String(cString: message))")
}

private func driftStatus(_ ctx: UnsafeMutableRawPointer?, _ status: UnsafePointer<CChar>?) -> Void {
    guard let status else { return }
    let text = String(cString: status)
    HelperLog.shared.write("daemon status: \(text)")
    TunnelDaemon.snapshot.state = HelperState.parse(text)
    TunnelDaemon.onUpdate?()
}

private func driftDataCount(_ ctx: UnsafeMutableRawPointer?, _ received: UInt64, _ sent: UInt64) -> Void {
    TunnelDaemon.snapshot.receivedBytes = received
    TunnelDaemon.snapshot.sentBytes = sent
}

private func driftLastError(_ ctx: UnsafeMutableRawPointer?, _ code: UnsafePointer<CChar>?) -> Void {
    guard let code else { return }
    TunnelDaemon.snapshot.lastError = String(cString: code)
    TunnelDaemon.onUpdate?()
}

private func driftRemove(_ ctx: UnsafeMutableRawPointer?, _ code: UnsafePointer<CChar>?) -> Void {}

private func driftRelease(_ bindings: UnsafeMutablePointer<partout_daemon_bindings>?) -> Void {}

enum TunnelDaemon {
    nonisolated(unsafe) static var snapshot = TunnelSnapshot()
    nonisolated(unsafe) static var onUpdate: (@Sendable () -> Void)? = nil

    private static let logger = HelperLog.shared

    // MARK: - Runtime bootstrap

    nonisolated(unsafe) private static var ready = false

    static func initRuntime() {
        guard !ready else { return }
        var initArgs = partout_init_args(
            logs_private_data: false,
            logger_fn: driftLibLogger,
            logger_ctx: nil
        )
        partout_init(&initArgs)
        ready = true
        logger.write("partout initialized (version \(String(cString: partout_version())))")
    }

    // MARK: - Daemon lifecycle

    static func start(profilePayload: Data, staticSetup: RootKit.IPv4Setup?) throws {
        guard case .idle = snapshot.state else {
            throw HelperError.daemonStart(-997)
        }
        initRuntime()

        let previous = RootKit.currentUTunInterfaces()
        snapshot = TunnelSnapshot(state: .connecting)
        onUpdate?()
        logger.write("daemon starting; known utun set: \(previous.sorted().joined(separator: ","))")

        let events = partout_daemon_events(
            ctx: nil,
            set_connection_status: driftStatus,
            set_data_count: driftDataCount,
            set_last_error_code: driftLastError,
            remove: driftRemove
        )
        let bindings = partout_daemon_bindings(controller: nil, events: events, release: driftRelease)

        let profileJSON = String(data: profilePayload, encoding: .utf8) ?? ""
        var rc: Int32 = -1
        let flags: UInt64 = (1 << 0) | (1 << 1) | (1 << 2)
        let cacheRoot = "/tmp/drift-tunnel-cache"
        do {
            try? FileManager.default.createDirectory(atPath: cacheRoot, withIntermediateDirectories: true)
        }

        cacheRoot.withCString { cachePtr in
            profileJSON.withCString { profilePtr in
                let options = partout_daemon_options(
                    is_daemon: true,
                    starts_immediately: true,
                    cancels_unrecoverable: true,
                    cache_dir: cachePtr,
                    min_data_count_delta: 1024,
                    crypto: PartoutCryptoNative,
                    feature_flags: flags
                )
                rc = withUnsafePointer(to: bindings) { bindingsPtr in
                    var startArgs = partout_daemon_start_args(
                        profile: profilePtr,
                        options: options,
                        bindings: bindingsPtr
                    )
                    return partout_daemon_start(&startArgs)
                }
            }
        }
        guard rc == 0 else {
            logger.write("daemon start rc=\(rc)")
            snapshot.state = .dropped("daemon start failed rc=\(rc)")
            onUpdate?()
            throw HelperError.daemonStart(rc)
        }

        // The daemon created its own utun via the C fallback path. Discover
        // it and assign an IPv4 for bound egress: app-provided static
        // address (OpenVPN `ifconfig`) > profile-embedded (WireGuard) >
        // placeholder.
        Task {
            await finishSetup(previousInterfaces: previous, payload: profilePayload, staticSetup: staticSetup)
        }
        onUpdate?()
    }

    private static func finishSetup(previousInterfaces: Set<String>, payload: Data, staticSetup: RootKit.IPv4Setup?) async {
        do {
            let setup = staticSetup
                ?? (try? RootKit.extractIPv4(fromProfilePayload: payload))
                ?? RootKit.placeholderSetup
            let device = try await RootKit.discoverNewUTun(known: previousInterfaces, timeout: 15)
            try RootKit.assignIPv4(device: device, setup: setup)
            snapshot.device = device
            logger.write("tunnel device \(device.name) is ready at \(setup.address)/\(setup.prefix)")
        } catch {
            snapshot.lastError = "\(error)"
            snapshot.state = .dropped("\(error)")
            logger.write("tunnel setup failed: \(error)")
        }
        onUpdate?()
    }

    static func stop() {
        logger.write("daemon stop requested")
        partout_daemon_stop()
        snapshot = TunnelSnapshot()
        onUpdate?()
    }
}
