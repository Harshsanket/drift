// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Helper entry point.
///
///   drift-tunnel-helper --socket PATH [--self-test]
///
/// Expected to run as root (elevated one-time via osascript). Serves the
/// app's control socket plus a loopback-only HTTP CONNECT relay. With
/// --self-test the daemon is skipped: useful for exercising the DIRECT
/// relay branch without privileges.

let SOCKET_FLAG = "--socket"
let SELF_TEST_FLAG = "--self-test"

func parseArguments() -> (socketPath: String, selfTest: Bool)? {
    var iterator = Array(CommandLine.arguments.dropFirst()).makeIterator()
    var socketPath: String? = nil
    var selfTest = false
    while let argument = iterator.next() {
        switch argument {
        case SOCKET_FLAG: socketPath = iterator.next()
        case SELF_TEST_FLAG: selfTest = true
        default: break
        }
    }
    guard let path = socketPath, !path.isEmpty else { return nil }
    return (path, selfTest)
}

func main() {
    guard let parsed = parseArguments() else {
        FileHandle.standardError.write(Data("usage: drift-tunnel-helper --socket PATH [--self-test]\n".utf8))
        exit(2)
    }
    let socketPath = parsed.socketPath
    let selfTest = parsed.selfTest

    HelperLog.shared.write("helper started (uid=\(getuid())) selfTest=\(selfTest) socket=\(socketPath)")

    let ctl = ControlDriver(path: socketPath)
    let relay = RelayServer()

    do {
        try relay.start()
        ctl.socksPort = relay.port
    } catch {
        HelperLog.shared.write("relay start failed: \(error)")
        exit(3)
    }

    do {
        try ctl.start(onStart: { payload, staticSetup in
            if selfTest {
                HelperLog.shared.write("self-test: ignoring start")
                return
            }
            try TunnelDaemon.start(profilePayload: payload, staticSetup: staticSetup)
        }, onStop: {
            TunnelDaemon.stop()
        })
    } catch {
        HelperLog.shared.write("ctl start failed: \(error)")
        exit(4)
    }

    if selfTest {
        // The socket bind above exercises parent-directory creation and the
        // path outside shared /tmp. Also pin the peer-credential policy.
        let socketBound = FileManager.default.fileExists(atPath: socketPath)
        let policyOK = PeerGuard.peerAllowed(
            peerUID: 0, helperUID: getuid(), consoleOwner: getuid()
        ) && PeerGuard.peerAllowed(
            peerUID: getuid(), helperUID: 0, consoleOwner: getuid()
        ) && !PeerGuard.peerAllowed(
            peerUID: getuid() &+ 1, helperUID: 0, consoleOwner: getuid()
        )
        HelperLog.shared.write(
            "self-test: socket-bound=\(socketBound) peer-policy=\(policyOK)"
        )
        exit(socketBound && policyOK ? 0 : 5)
    } else {
        while true {
            Thread.sleep(forTimeInterval: 3600)
        }
    }
}

main()
