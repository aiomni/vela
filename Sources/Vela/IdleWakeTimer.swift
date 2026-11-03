import Foundation

struct IdleThreshold: Equatable {
    static let preferenceKey = "idleThresholdMinutes"
    static let defaultValue = IdleThreshold(minutes: 4)
    let minutes: Int

    init(minutes: Int) { self.minutes = min(1440, max(0, minutes)) }

    static func load(from defaults: UserDefaults) -> IdleThreshold {
        guard let saved = defaults.object(forKey: preferenceKey) as? Int,
              (0...1440).contains(saved) else { return .defaultValue }
        return IdleThreshold(minutes: saved)
    }

    func save(to defaults: UserDefaults) {
        if self == .defaultValue { defaults.removeObject(forKey: Self.preferenceKey) }
        else { defaults.set(minutes, forKey: Self.preferenceKey) }
    }

    var interval: TimeInterval { TimeInterval(minutes) * 60 }
}

/// The selected duration measures a continuous spell of physical inactivity.
/// Uptime keeps a wall-clock adjustment from changing the countdown.
struct IdleWakeTimer {
    enum Phase { case off, waiting, counting, unlimited }

    var duration: WakeDuration
    var threshold: IdleThreshold
    private(set) var armedAt: TimeInterval?
    private(set) var lastPhysicalInputAt: TimeInterval?
    private(set) var countdownStartedAt: TimeInterval?

    var phase: Phase {
        guard armedAt != nil else { return .off }
        if duration.interval == nil { return .unlimited }
        return countdownStartedAt == nil ? .waiting : .counting
    }

    mutating func arm(at uptime: TimeInterval) {
        armedAt = uptime
        lastPhysicalInputAt = uptime
        countdownStartedAt = nil
    }

    mutating func disarm() {
        armedAt = nil
        lastPhysicalInputAt = nil
        countdownStartedAt = nil
    }

    /// Returns true when physical input cancels an active countdown.
    @discardableResult mutating func recordPhysicalInput(at uptime: TimeInterval) -> Bool {
        guard let armedAt, uptime >= armedAt,
              uptime >= (lastPhysicalInputAt ?? armedAt) else { return false }
        let wasCounting = countdownStartedAt != nil
        lastPhysicalInputAt = uptime
        countdownStartedAt = nil
        return wasCounting
    }

    /// Returns true once the selected duration has elapsed since the idle threshold.
    mutating func tick(at uptime: TimeInterval) -> Bool {
        guard let armedAt, let duration = duration.interval else { return false }
        if countdownStartedAt == nil {
            let lastInput = max(armedAt, lastPhysicalInputAt ?? armedAt)
            guard uptime - lastInput >= threshold.interval else { return false }
            countdownStartedAt = lastInput + threshold.interval
        }
        return uptime - countdownStartedAt! >= duration
    }

    mutating func setDuration(_ value: WakeDuration, at uptime: TimeInterval) {
        duration = value
        if countdownStartedAt != nil { countdownStartedAt = value.interval == nil ? nil : uptime }
    }

    mutating func setThreshold(_ value: IdleThreshold) { threshold = value }

    mutating func resumeCountdown(remaining: TimeInterval, at uptime: TimeInterval) {
        guard armedAt != nil, let duration = duration.interval else { return }
        countdownStartedAt = uptime - max(0, duration - max(0, remaining))
    }

    func remaining(at uptime: TimeInterval) -> TimeInterval? {
        guard let duration = duration.interval, let countdownStartedAt else { return nil }
        return max(0, duration - (uptime - countdownStartedAt))
    }
}
