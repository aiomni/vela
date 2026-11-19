import RemoteCore

/// Discovery and offer are separate authenticated requests. Once either sees
/// a private connection requirement, display changes cannot downgrade it.
struct RemotePrivacyIntent {
    private var required: Set<String> = []
    private var physicalOverride: String?

    mutating func requiresIsolation(token: String, mode: RemotePrivacyMode,
                                    locked: Bool, physicalDisplaysAsleep: Bool) -> Bool {
        if physicalOverride == token { return false }
        if required.contains(token) { return true }
        guard mode.requiresIsolation(locked: locked, physicalDisplaysAsleep: physicalDisplaysAsleep) else { return false }
        required.insert(token)
        return true
    }

    mutating func allowPhysicalDisplays(for token: String) {
        required.remove(token)
        physicalOverride = token
    }

    mutating func endConnection() { physicalOverride = nil }
    mutating func expire(where isValid: (String) -> Bool) { required = required.filter(isValid) }
}
