import VelaLocalization
import Foundation
import IOKit.pwr_mgt
import LidServiceShared

func verifyDutyEngine() {
    precondition(LidPmsetOutput.sleepDisabled("System-wide power settings:\n SleepDisabled 1\n") == true)
    precondition(LidPmsetOutput.sleepDisabled("System-wide power settings:\n SleepDisabled 0\n") == false)
    precondition(LidPmsetOutput.sleepDisabled("System-wide power settings:\n sleep 1\n") == false)
    precondition(LidPmsetOutput.sleepDisabled("invalid") == nil)
    func observation(_ seconds: TimeInterval, busy: String = "", battery: DutyBattery? = nil,
                     heat: DutyHeat = .nominal, held: Bool = false, mode: KeepAwakeMode? = nil,
                     lid: Bool = false, lidReady: Bool = true) -> DutyObservation {
        DutyObservation(now: 1_000 + seconds, busyAgents: busy,
                        battery: battery, heat: heat, assertionHeld: held,
                        assertionMode: mode, lidHeld: lid, lidAvailable: lidReady)
    }

    var engine = DutyEngine()
    precondition(engine.select(.agent, mode: .system, observation: observation(0)).isEmpty)
    precondition(engine.phase == .agentStandby)
    precondition(engine.tick(observation(5, busy: "Codex")) == [.acquire(.system)])
    precondition(engine.phase == .agentActive)
    precondition(engine.tick(observation(10, held: true, mode: .system)).isEmpty)
    precondition(engine.phase == .grace)
    precondition(engine.tick(observation(250, held: true, mode: .system)).isEmpty)
    precondition(engine.tick(observation(300, busy: "Codex", held: true, mode: .system)).isEmpty)
    precondition(engine.phase == .agentActive)
    precondition(engine.tick(observation(305, held: true, mode: .system)).isEmpty)
    precondition(engine.tick(observation(606, held: true, mode: .system)) == [.release])
    precondition(engine.phase == .agentStandby)

    precondition(engine.select(.manual, mode: .display, observation: observation(700)) == [.acquire(.display)])
    let low = DutyBattery(percent: 20, onBattery: true)
    let effects = engine.tick(observation(705, battery: low, held: true, mode: .display))
    precondition(effects.first == .release && engine.phase == .lowBatteryStopped)
    precondition(engine.tick(observation(710)).isEmpty && engine.source == .off)

    _ = engine.select(.manual, mode: .system, observation: observation(800))
    let overheated = engine.tick(observation(801, heat: .critical, held: true, mode: .system))
    precondition(overheated.first == .release && engine.phase == .thermalPaused)
    precondition(engine.tick(observation(820, heat: .fair)).isEmpty)
    let cool = engine.tick(observation(941, heat: .fair))
    precondition(cool.contains(.acquire(.system)) && engine.phase == .manual)

    _ = engine.tick(observation(950, heat: .critical, held: true, mode: .system))
    precondition(engine.phase == .thermalPaused)
    precondition(engine.tick(observation(960, heat: .fair)).isEmpty)
    precondition(engine.tick(observation(1_050, heat: .serious)).isEmpty)
    precondition(engine.tick(observation(1_060, heat: .fair)).isEmpty)
    precondition(engine.tick(observation(1_179, heat: .fair)).isEmpty)
    precondition(engine.phase == .thermalPaused)
    precondition(engine.tick(observation(1_180, heat: .fair)).contains(.acquire(.system)))

    let lidStart = engine.select(.manual, mode: .lid, observation: observation(1_000))
    precondition(lidStart == [.enableLid])
    precondition(engine.tick(observation(1_001, lid: true)) == [.acquire(.lid)])
    let stopped = engine.select(.off, mode: .lid, observation: observation(1_002, held: true, mode: .lid, lid: true))
    precondition(stopped == [.release, .restoreLid])

    let switchMode = engine.select(.manual, mode: .display,
                                   observation: observation(1_005, held: true, mode: .lid, lid: true))
    precondition(switchMode == [.restoreLid, .release, .acquire(.display)])
    precondition(engine.tick(observation(1_006, held: true, mode: .lid)) == [.release, .acquire(.display)])

    precondition(engine.select(.manual, mode: .lid, observation: observation(1_010)) == [.enableLid])
    precondition(engine.tick(observation(1_011, lid: true)) == [.acquire(.lid)])
    let disconnected = engine.fail(L("Closed-lid recovery monitor failed"), observation: observation(1_012, held: true, mode: .lid))
    precondition(disconnected.first == .release && engine.phase == .fault)
    precondition(engine.tick(observation(1_013, lidReady: true)).isEmpty)

    _ = engine.select(.manual, mode: .lid, observation: observation(1_020))
    let simultaneous = engine.tick(observation(1_021, battery: low, heat: .critical,
                                               held: true, mode: .lid, lid: true))
    precondition(simultaneous.prefix(2) == [.release, .restoreLid])
    precondition(engine.phase == .lowBatteryStopped && engine.source == .off)

    _ = engine.select(.manual, mode: .lid, observation: observation(1_030))
    let heatStop = engine.tick(observation(1_031, heat: .critical, held: true, mode: .lid, lid: true))
    precondition(heatStop.prefix(2) == [.release, .restoreLid] && engine.phase == .thermalPaused)
    precondition(engine.tick(observation(1_032, heat: .fair)).isEmpty)
    let safeResume = engine.tick(observation(1_153, heat: .fair))
    precondition(safeResume.contains(.acquire(.system)) && !safeResume.contains(.enableLid))
    precondition(engine.effectiveMode == .system)

    precondition(engine.select(.agent, mode: .lid, observation: observation(1_200)).isEmpty)
    precondition(engine.tick(observation(1_201, busy: "Codex")) == [.enableLid])
    precondition(engine.tick(observation(1_202, busy: "Codex", lid: true)) == [.acquire(.lid)])
    precondition(engine.tick(observation(1_203, held: true, mode: .lid, lid: true)).isEmpty)
    let standby = engine.tick(observation(1_504, held: true, mode: .lid, lid: true))
    precondition(standby == [.release, .restoreLid] && engine.phase == .agentStandby)
    engine.finishLidSession()
    precondition(engine.tick(observation(1_505, busy: "Codex")) == [.acquire(.system)])

    _ = engine.select(.manual, mode: .display, observation: observation(1_100))
    _ = engine.tick(observation(1_101, held: true, mode: .display))
    precondition(engine.tick(observation(1_102)) == [.acquire(.display)])
    let failed = engine.tick(observation(1_103))
    precondition(engine.phase == .fault && failed.contains(.record("Fault: Unable to maintain the wake assertion")))
    print("PASS: DutyEngine agent grace, low battery, heat pause, lid ordering, assertion fault")
}

@MainActor
func verifyPowerModes() throws {
    let power = PowerController()
    for mode in [KeepAwakeMode.display, .system, .lid] {
        try power.enable(mode)
        guard let id = power.assertion else { preconditionFailure(L("Assertion not created")) }
        precondition(power.isActuallyHeld() && power.mode == mode)
        let values = IOPMAssertionCopyProperties(id)!.takeRetainedValue() as! [String: Any]
        precondition(values[kIOPMAssertionTypeKey as String] as? String == mode.assertionType as String)
        let displayID = power.displayAssertion
        if mode == .lid {
            guard let displayID else { preconditionFailure(L("Closed-lid mode did not create a display assertion")) }
            let displayValues = IOPMAssertionCopyProperties(displayID)!.takeRetainedValue() as! [String: Any]
            precondition(displayValues[kIOPMAssertionTypeKey as String] as? String ==
                         kIOPMAssertionTypePreventUserIdleDisplaySleep as String)
            try power.enable(mode)
            precondition(power.assertion == id && power.displayAssertion == displayID)
        } else { precondition(displayID == nil) }
        power.disable()
        precondition(IOPMAssertionCopyProperties(id) == nil)
        if let displayID { precondition(IOPMAssertionCopyProperties(displayID) == nil) }
    }
    try power.enable(.lid)
    let oldDisplayID = power.displayAssertion!
    try power.enable(.system)
    precondition(power.isActuallyHeld() && power.displayAssertion == nil)
    precondition(IOPMAssertionCopyProperties(oldDisplayID) == nil)
    power.disable()
    print("PASS: display/system assertions and both lid assertions exist, remain idempotent and release cleanly")
}
