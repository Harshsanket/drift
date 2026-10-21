import Foundation
import Darwin

/// App-side mirror of the helper's `PeerGuard` policy (DriftTunnelHelper/
/// PeerGuard.swift). The two must stay in sync: the helper decides which
/// connecting uids to serve, the app decides which peer uids to trust.
public enum PeerGuardPolicy {
    /// Root and the helper's own uid are always trusted; the console user
    /// is trusted so the unprivileged app can talk to its elevated helper.
    public static func trusts(peerUID: uid_t, helperUID: uid_t, consoleOwner: uid_t?) -> Bool {
        if peerUID == 0 { return true }
        if peerUID == helperUID { return true }
        if let consoleOwner, peerUID == consoleOwner { return true }
        return false
    }

    /// uid owning the console session (i.e. the desktop user), or nil in
    /// headless contexts.
    public static var consoleOwnerUID: uid_t? {
        var info = stat()
        guard stat("/dev/console", &info) == 0, info.st_uid != 0 else { return nil }
        return info.st_uid
    }
}
