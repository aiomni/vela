import Foundation

/// A temporary loss of interfaces must not revoke a remote session or rotate
/// its certificate. Rebind only after a new nonempty address set is stable and
/// no media peer is using the existing listener.
struct RemoteAddressChangeTracker {
    private var pending: [String]?
    private var pendingSince: TimeInterval = 0

    mutating func shouldRebind(current: [String], observed: [String],
                               now: TimeInterval, hasPeer: Bool) -> Bool {
        guard !observed.isEmpty, observed != current else {
            pending = nil
            return false
        }
        if pending != observed {
            pending = observed
            pendingSince = now
            return false
        }
        return !hasPeer && now - pendingSince >= 15
    }

    mutating func reset() { pending = nil }
}
