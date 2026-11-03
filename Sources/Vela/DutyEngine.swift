import VelaLocalization
import Foundation

enum DutySource: String, Equatable {
    case off, manual, agent
}

enum DutyPhase: Equatable {
    case off, manual, agentStandby, agentActive, grace
    case thermalPaused, lowBatteryStopped, fault

    var holdsAssertion: Bool {
        switch self {
        case .manual, .agentActive, .grace: true
        default: false
        }
    }
}

enum DutyHeat: Int, Comparable {
    case nominal, fair, serious, critical
    static func < (lhs: DutyHeat, rhs: DutyHeat) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct DutyBattery: Equatable {
    let percent: Int
    let onBattery: Bool
}

struct DutyObservation {
    let now: TimeInterval
    let busyAgents: String
    let battery: DutyBattery?
    let heat: DutyHeat
    let assertionHeld: Bool
    let assertionMode: KeepAwakeMode?
    let lidHeld: Bool
    let lidAvailable: Bool
}

enum DutyEffect: Equatable {
    case acquire(KeepAwakeMode)
    case release
    case enableLid
    case restoreLid
    case record(String)
}

/// Pure policy engine. System calls are performed by AppDelegate after these effects are returned.
struct DutyEngine {
    private(set) var source: DutySource = .off
    private(set) var phase: DutyPhase = .off
    private(set) var requestedMode: KeepAwakeMode = .display
    private(set) var effectiveMode: KeepAwakeMode = .display
    private(set) var lastBusyAgents = ""
    private(set) var graceStartedAt: TimeInterval?
    private(set) var faultReason: String?
    var batteryFloor = 20
    var graceSeconds: TimeInterval = 300
    private var coolSince: TimeInterval?
    private var warnedHeat = false
    private var reacquireAttempts = 0

    mutating func select(_ newSource: DutySource, mode: KeepAwakeMode, observation: DutyObservation) -> [DutyEffect] {
        source = newSource
        requestedMode = mode
        effectiveMode = mode
        phase = newSource == .off ? .off : newSource == .manual ? .manual : .agentStandby
        lastBusyAgents = ""
        graceStartedAt = nil
        coolSince = nil
        warnedHeat = false
        reacquireAttempts = 0
        faultReason = nil
        return tick(observation)
    }

    mutating func fail(_ reason: String, observation: DutyObservation) -> [DutyEffect] {
        faultReason = Localization.text(reason, language: .english)
        phase = .fault
        return stopEffects(observation) + [.record("Fault: \(faultReason ?? reason)")]
    }

    mutating func finishLidSession() {
        if effectiveMode == .lid { effectiveMode = .system }
    }

    mutating func tick(_ observation: DutyObservation) -> [DutyEffect] {
        if phase == .fault || phase == .lowBatteryStopped { return stopEffects(observation) }
        if source == .off {
            phase = .off
            reacquireAttempts = 0
            return stopEffects(observation)
        }
        if let battery = observation.battery, battery.onBattery,
           battery.percent <= batteryFloor {
            source = .off
            phase = .lowBatteryStopped
            reacquireAttempts = 0
            return stopEffects(observation) + [.record("Low battery. Watch ended")]
        }
        if observation.heat == .critical {
            if phase != .thermalPaused {
                phase = .thermalPaused
                coolSince = nil
                reacquireAttempts = 0
                return stopEffects(observation) + [.record("Device overheating. Watch paused")]
            }
            coolSince = nil
            return stopEffects(observation)
        }
        if phase == .thermalPaused {
            if observation.heat <= .fair {
                if coolSince == nil { coolSince = observation.now }
                if observation.now - coolSince! >= 120 {
                    phase = source == .manual ? .manual : .agentStandby
                    if effectiveMode == .lid { effectiveMode = .system }
                    coolSince = nil
                    return [.record("Device cooled. Resuming normal watch")] + tick(observation)
                }
            } else { coolSince = nil }
            return stopEffects(observation)
        }

        var effects: [DutyEffect] = []
        if observation.heat == .serious && !warnedHeat {
            warnedHeat = true
            effects.append(.record("Device temperature is high"))
        } else if observation.heat <= .fair { warnedHeat = false }

        switch source {
        case .off: phase = .off
        case .manual: phase = .manual
        case .agent:
            if !observation.busyAgents.isEmpty {
                lastBusyAgents = observation.busyAgents
                graceStartedAt = nil
                phase = .agentActive
            } else if phase == .agentActive || phase == .grace {
                if graceStartedAt == nil { graceStartedAt = observation.now }
                if observation.now - graceStartedAt! >= graceSeconds {
                    phase = .agentStandby
                    graceStartedAt = nil
                } else { phase = .grace }
            } else { phase = .agentStandby }
        }
        if !phase.holdsAssertion {
            reacquireAttempts = 0
            return effects + stopEffects(observation)
        }
        if effectiveMode == .lid {
            guard observation.lidAvailable else {
                return effects + fail("Closed-lid settings unavailable", observation: observation)
            }
            if !observation.lidHeld {
                effects.append(.enableLid)
                return effects
            }
        } else if observation.lidHeld { effects.append(.restoreLid) }

        if !observation.assertionHeld || observation.assertionMode != effectiveMode {
            if observation.assertionHeld && observation.assertionMode != effectiveMode {
                effects.append(.release)
            } else if reacquireAttempts > 0 {
                return effects + fail("Unable to maintain the wake assertion", observation: observation)
            }
            effects.append(.acquire(effectiveMode))
            reacquireAttempts += 1
        } else { reacquireAttempts = 0 }
        return effects
    }

    private func stopEffects(_ observation: DutyObservation) -> [DutyEffect] {
        var effects: [DutyEffect] = []
        if observation.assertionHeld { effects.append(.release) }
        if observation.lidHeld { effects.append(.restoreLid) }
        return effects
    }

    func graceRemaining(at now: TimeInterval) -> TimeInterval? {
        guard phase == .grace, let graceStartedAt else { return nil }
        return max(0, graceSeconds - (now - graceStartedAt))
    }
}
