import Foundation
import Darwin

/// Control-socket peer identity checks.
///
/// The helper is root and the control socket is the only app→helper
/// channel, so every accepted connection must prove it comes from either
/// root itself or the desktop user who elevated the helper. Peer identity
/// is taken from the kernel (`getpeereid`) — never from payloads on the
/// socket — on both directions:
///   - helper side: reject connections from unknown uids;
///   - app side: the peer must be root or the response is discarded.
enum PeerGuard {
    /// uid owning the console session (i.e. the desktop user). Falls back
    /// to nil when unavailable (headless/self-test contexts).
    static var consoleOwnerUID: uid_t? {
        var info = stat()
        guard stat("/dev/console", &info) == 0, info.st_uid != 0 else { return nil }
        return info.st_uid
    }

    /// Policy: root and the helper's own uid are always trusted; the
    /// console user is trusted so the unprivileged app can talk to its
    /// elevated helper. Anything else is rejected no matter what it sends.
    static func peerAllowed(peerUID: uid_t, helperUID: uid_t, consoleOwner: uid_t?) -> Bool {
        if peerUID == 0 { return true }
        if peerUID == helperUID { return true }
        if let consoleOwner, peerUID == consoleOwner { return true }
        return false
    }

    /// Full per-connection check: kernel peer identity + policy. Intended
    /// for accepted control-socket fds.
    static func accept(clientFD: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(clientFD, &uid, &gid) == 0 else { return false }
        return peerAllowed(
            peerUID: uid,
            helperUID: getuid(),
            consoleOwner: consoleOwnerUID
        )
    }
}
