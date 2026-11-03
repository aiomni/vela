import VelaLocalization
import AppKit
import RemoteRTC

let app = NSApplication.shared
if let index = CommandLine.arguments.firstIndex(of: "--remote-display-watchdog"), CommandLine.arguments.count > index + 1 {
    app.setActivationPolicy(.prohibited)
    Task { @MainActor in exit(await PhysicalDisplayWatchdog.run(directory: URL(fileURLWithPath: CommandLine.arguments[index+1]))) }
    app.run()
} else if let index = CommandLine.arguments.firstIndex(of: "--physical-blackout-probe"), CommandLine.arguments.count > index + 1 {
    app.setActivationPolicy(.accessory)
    Task { @MainActor in exit(await runPhysicalBlackoutProbe(directory: URL(fileURLWithPath: CommandLine.arguments[index+1]))) }
    app.run()
} else if let index = CommandLine.arguments.firstIndex(of: "--remote-web-probe"), CommandLine.arguments.count > index + 1 {
    app.setActivationPolicy(.accessory)
    Task { @MainActor in exit(await runRemoteWebProbe(directory: URL(fileURLWithPath: CommandLine.arguments[index+1]))) }
    app.run()
} else if let index = CommandLine.arguments.firstIndex(of: "--remote-session-probe"), CommandLine.arguments.count > index + 1 {
    app.setActivationPolicy(.accessory)
    Task { @MainActor in
        let result = await runRemoteSessionProbe(directory: URL(fileURLWithPath: CommandLine.arguments[index+1]),
                                                detach: CommandLine.arguments.contains("--probe-detach"),
                                                lockFirst: CommandLine.arguments.contains("--probe-lock-first"),
                                                sleepPhysical: CommandLine.arguments.contains("--probe-display-sleep"))
        exit(result)
    }
    app.run()
} else if CommandLine.arguments.contains("--settings-review") {
    let delegate = SettingsReview()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    withExtendedLifetime(delegate) { app.run() }
} else if CommandLine.arguments.contains("--remote-settings-review") {
    let delegate = RemoteSettingsReview()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    withExtendedLifetime(delegate) { app.run() }
} else if CommandLine.arguments.contains("--occlusion-cover") {
    let delegate = OcclusionCover()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
} else if CommandLine.arguments.contains("--live-star-ring-review") || CommandLine.arguments.contains("--live-effect-review") {
    let delegate = StarRingLiveReview()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    let menu = NSMenu()
    let application = NSMenuItem()
    let submenu = NSMenu()
    submenu.addItem(withTitle: L("Quit visual review"),action: #selector(NSApplication.terminate(_:)),keyEquivalent: "q")
    application.submenu = submenu
    menu.addItem(application)
    app.mainMenu = menu
    withExtendedLifetime(delegate) { app.run() }
} else if let index = CommandLine.arguments.firstIndex(of:"--generate-material-review"),CommandLine.arguments.count > index+1 {
    app.setActivationPolicy(.prohibited)
    var selected: PetPalette?
    if let paletteIndex = CommandLine.arguments.firstIndex(of:"--review-palette"),CommandLine.arguments.count > paletteIndex+1 {
        selected = PetPalette(rawValue:CommandLine.arguments[paletteIndex+1])
    }
    do { try generateMaterialReview(at:URL(fileURLWithPath:CommandLine.arguments[index+1]),palette:selected,
        animated:CommandLine.arguments.contains("--review-animate")) }
    catch { fputs("Material review failed: \(error.localizedDescription)\n",stderr);exit(1) }
} else if let index = CommandLine.arguments.firstIndex(of: "--generate-star-ring-quality-review"), CommandLine.arguments.count > index + 1 {
    app.setActivationPolicy(.prohibited)
    do { try generateStarRingQualityReview(at: URL(fileURLWithPath:CommandLine.arguments[index+1])) }
    catch { fputs("Quality review failed: \(error.localizedDescription)\n",stderr);exit(1) }
} else if let index = CommandLine.arguments.firstIndex(of: "--generate-star-ring-review"), CommandLine.arguments.count > index + 1 {
    app.setActivationPolicy(.prohibited)
    do { try generateStarRingReview(at: URL(fileURLWithPath: CommandLine.arguments[index + 1])) }
    catch { fputs("Review generation failed: \(error.localizedDescription)\n", stderr); exit(1) }
} else if let index = CommandLine.arguments.firstIndex(of: "--generate-effect-previews"), CommandLine.arguments.count > index + 1 {
    app.setActivationPolicy(.prohibited)
    do { try generateEffectPreviews(at: URL(fileURLWithPath: CommandLine.arguments[index + 1])) }
    catch { fputs("Preview generation failed: \(error.localizedDescription)\n", stderr); exit(1) }
} else if let index = CommandLine.arguments.firstIndex(of: "--generate-iconset"), CommandLine.arguments.count > index + 1 {
    app.setActivationPolicy(.prohibited)
    do { try generateAppIconSet(at: URL(fileURLWithPath: CommandLine.arguments[index + 1])) }
    catch { fputs("Icon generation failed: \(error.localizedDescription)\n", stderr); exit(1) }
} else if CommandLine.arguments.contains("--export-material-temporal-sampling") {
    app.setActivationPolicy(.prohibited)
    do {
        guard let index = CommandLine.arguments.firstIndex(of: "--review-palette"),
              index + 1 < CommandLine.arguments.count,
              let palette = PetPalette(rawValue: CommandLine.arguments[index + 1]) else {
            throw NSError(domain: "MaterialSampling", code: 5)
        }
        var pixels = 48
        if let index = CommandLine.arguments.firstIndex(of: "--check-display-pixels"),
           index + 1 < CommandLine.arguments.count,
           let value = Int(CommandLine.arguments[index + 1]) { pixels = value }
        try exportMaterialTemporalSampling(palette: palette, bodyPixels: pixels)
    } catch { fputs("Temporal sampling export failed: \(error.localizedDescription)\n", stderr); exit(1) }
} else if CommandLine.arguments.contains("--check-material-cycle") || CommandLine.arguments.contains("--check-whale-vector-cycle") {
    app.setActivationPolicy(.prohibited)
    do {
        guard let index = CommandLine.arguments.firstIndex(of:"--review-palette"),CommandLine.arguments.count>index+1,
              let palette = PetPalette(rawValue:CommandLine.arguments[index+1]) else {
            throw NSError(domain:"MaterialCycle",code:5,userInfo:[NSLocalizedDescriptionKey:"--review-palette is required"])
        }
        var pixels = 48
        if let index = CommandLine.arguments.firstIndex(of:"--check-display-pixels"),CommandLine.arguments.count>index+1,
           let requested = Int(CommandLine.arguments[index+1]) { pixels = requested }
        try verifyMaterialCycle(palette:palette,bodyPixels:pixels,whaleVector:CommandLine.arguments.contains("--check-whale-vector-cycle"))
    } catch { fputs("Material cycle failed: \(error.localizedDescription)\n",stderr);exit(1) }
} else if CommandLine.arguments.contains("--check-star-ring-cycle") {
    app.setActivationPolicy(.prohibited)
    do {
        var displayPixels = 48
        if let index = CommandLine.arguments.firstIndex(of:"--check-display-pixels") {
            guard index+1 < CommandLine.arguments.count,let value = Int(CommandLine.arguments[index+1]) else {
                throw NSError(domain:"StarRingCycle",code:4,userInfo:[NSLocalizedDescriptionKey:L("--check-display-pixels requires an integer from 12 to 192")])
            }
            displayPixels = value
        }
        try verifyStarRingCycle(displayPixels:displayPixels)
    }
    catch { fputs("Cycle check failed: \(error.localizedDescription)\n",stderr);exit(1) }
} else if CommandLine.arguments.contains("--watch-policy-test") {
    verifyDutyEngine()
    verifyAgentActivityAnalyzer()
    do { try verifyPowerModes() }
    catch { fputs("Power mode test failed: \(error.localizedDescription)\n", stderr); exit(1) }
    do { try verifyLidWatchdog() }
    catch { fputs("Lid watchdog test failed: \(error.localizedDescription)\n", stderr); exit(1) }
} else if CommandLine.arguments.contains("--lid-pending-auth-live-test") {
    guard !NSRunningApplication.runningApplications(withBundleIdentifier: "app.aiomni.awakepet")
        .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) else {
        fputs("Close the normal Vela instance before a lid live test\n", stderr)
        exit(2)
    }
    app.setActivationPolicy(.prohibited)
    Task { @MainActor in
        let lid = LidServiceClient()
        let opening = Task { await lid.open() }
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        while !lid.hasPendingAuthorization && ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard lid.hasPendingAuthorization else {
            let opened = await opening.value
            if opened { _ = await lid.close() }
            fputs("LID_PENDING_AUTH_NOT_OBSERVED\n", stderr)
            exit(1)
        }
        FileHandle.standardOutput.write(Data("LID_PENDING_AUTH_READY pid=\(getpid())\n".utf8))
        try? await Task.sleep(for: .seconds(8))
        let restored = await lid.disconnectAndConfirmRestored()
        let opened = await opening.value
        if opened { _ = await lid.close() }
        guard restored, !opened, !lid.hasPendingAuthorization else {
            fputs("LID_PENDING_AUTH_UNEXPECTEDLY_APPROVED\n", stderr)
            exit(1)
        }
        FileHandle.standardOutput.write(Data("LID_PENDING_AUTH_CLEANED\n".utf8))
        exit(0)
    }
    RunLoop.main.run()
} else if CommandLine.arguments.contains("--lid-external-live-test") {
    guard !NSRunningApplication.runningApplications(withBundleIdentifier: "app.aiomni.awakepet")
        .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) else {
        fputs("Close the normal Vela instance before a lid live test\n", stderr)
        exit(2)
    }
    app.setActivationPolicy(.prohibited)
    Task { @MainActor in
        let lid = LidServiceClient()
        guard await lid.open() else {
            fputs("LID_OPEN_FAILED: \(lid.lastMessage)\n", stderr)
            exit(1)
        }
        let power = PowerController()
        do { try power.enable(.lid) }
        catch {
            _ = await lid.close()
            fputs("LID_EXTERNAL_SETUP_FAILED: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
        FileHandle.standardOutput.write(Data("LID_EXTERNAL_READY pid=\(getpid())\n".utf8))
        let deadline = ProcessInfo.processInfo.systemUptime + 60
        while ProcessInfo.processInfo.systemUptime < deadline {
            if !(await lid.heartbeat()) {
                power.disable()
                let restored = await lid.close()
                FileHandle.standardOutput.write(Data("LID_EXTERNAL_\(restored ? "STOPPED" : "RESTORE_FAILED")\n".utf8))
                exit(restored ? 0 : 1)
            }
            try? await Task.sleep(for: .seconds(1))
        }
        power.disable()
        _ = await lid.close()
        fputs("LID_EXTERNAL_TIMEOUT: setting did not change\n", stderr)
        exit(1)
    }
    RunLoop.main.run()
} else if CommandLine.arguments.contains("--lid-battery-live-test") ||
    CommandLine.arguments.contains("--lid-thermal-live-test") {
    let testingHeat = CommandLine.arguments.contains("--lid-thermal-live-test")
    guard !NSRunningApplication.runningApplications(withBundleIdentifier: "app.aiomni.awakepet")
        .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) else {
        fputs("Close the normal Vela instance before a lid live test\n", stderr)
        exit(2)
    }
    app.setActivationPolicy(.prohibited)
    Task { @MainActor in
        guard let initialBattery = PowerSafetyMonitor.battery(),
              testingHeat || !initialBattery.onBattery else {
            fputs("LID_BATTERY_SETUP_FAILED: start on AC power with an internal battery\n", stderr)
            exit(2)
        }
        let lid = LidServiceClient()
        guard await lid.open() else {
            fputs("LID_OPEN_FAILED: \(lid.lastMessage)\n", stderr)
            exit(1)
        }
        let power = PowerController()
        do { try power.enable(.lid) }
        catch {
            _ = await lid.close()
            fputs("LID_BATTERY_SETUP_FAILED: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
        var duty = DutyEngine()
        if !testingHeat { duty.batteryFloor = 100 } // Test-only AC-to-battery trigger.
        @MainActor func observation(_ battery: DutyBattery, heat: DutyHeat = .nominal) -> DutyObservation {
            DutyObservation(now: ProcessInfo.processInfo.systemUptime, busyAgents: "",
                            battery: battery, heat: heat,
                            assertionHeld: power.isActuallyHeld(), assertionMode: power.mode,
                            lidHeld: lid.isHeld, lidAvailable: true)
        }
        _ = duty.select(.manual, mode: .lid, observation: observation(initialBattery))
        if testingHeat {
            let effects = duty.tick(observation(initialBattery, heat: .critical))
            guard duty.phase == .thermalPaused,
                  effects.contains(.release), effects.contains(.restoreLid) else {
                power.disable()
                _ = await lid.close()
                fputs("LID_THERMAL_POLICY_FAILED\n", stderr)
                exit(1)
            }
            power.disable()
            let restored = await lid.close()
            FileHandle.standardOutput.write(Data("LID_THERMAL_\(restored ? "RESTORED" : "RESTORE_FAILED")\n".utf8))
            exit(restored ? 0 : 1)
        }
        var observedBattery: DutyBattery?
        guard let powerChange = PowerSourceChangeObserver(onChange: {
            observedBattery = PowerSafetyMonitor.battery()
        }) else {
            power.disable()
            _ = await lid.close()
            fputs("LID_BATTERY_SETUP_FAILED: power source notification unavailable\n", stderr)
            exit(1)
        }
        defer { powerChange.stop() }
        FileHandle.standardOutput.write(Data("LID_BATTERY_READY pid=\(getpid())\n".utf8))
        let deadline = ProcessInfo.processInfo.systemUptime + 90
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let battery = observedBattery, battery.onBattery {
                let effects = duty.tick(observation(battery))
                guard duty.phase == .lowBatteryStopped,
                      effects.contains(.release), effects.contains(.restoreLid) else {
                    power.disable()
                    _ = await lid.close()
                    fputs("LID_BATTERY_POLICY_FAILED\n", stderr)
                    exit(1)
                }
                power.disable()
                let restored = await lid.close()
                FileHandle.standardOutput.write(Data("LID_BATTERY_\(restored ? "RESTORED" : "RESTORE_FAILED") percent=\(battery.percent)\n".utf8))
                exit(restored ? 0 : 1)
            }
            guard await lid.heartbeat() else {
                power.disable()
                _ = await lid.close()
                fputs("LID_BATTERY_WATCHDOG_FAILED\n", stderr)
                exit(1)
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        power.disable()
        _ = await lid.close()
        fputs("LID_BATTERY_TIMEOUT: AC power remained connected\n", stderr)
        exit(1)
    }
    RunLoop.main.run()
} else if let index = CommandLine.arguments.firstIndex(of: "--lid-live-test") {
    guard index + 1 < CommandLine.arguments.count,
          let seconds = Int(CommandLine.arguments[index + 1]),
          (3...300).contains(seconds) else {
        fputs("--lid-live-test requires a duration of 3–300 seconds\n", stderr)
        exit(2)
    }
    guard !NSRunningApplication.runningApplications(withBundleIdentifier: "app.aiomni.awakepet")
        .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) else {
        fputs("Close the normal Vela instance before a lid live test\n", stderr)
        exit(2)
    }
    app.setActivationPolicy(.prohibited)
    Task { @MainActor in
        let lid = LidServiceClient()
        guard await lid.open() else {
            fputs("LID_OPEN_FAILED: \(lid.lastMessage)\n", stderr)
            exit(1)
        }
        FileHandle.standardOutput.write(Data("LID_READY pid=\(getpid())\n".utf8))
        try? await Task.sleep(for: .seconds(seconds))
        let restored = await lid.close()
        FileHandle.standardOutput.write(Data("LID_\(restored ? "RESTORED" : "RESTORE_FAILED")\n".utf8))
        if !restored { fputs("\(lid.lastMessage)\n", stderr) }
        exit(restored ? 0 : 1)
    }
    RunLoop.main.run()
} else if CommandLine.arguments.contains("--diagnose-watch-live") {
    app.setActivationPolicy(.prohibited)
    let monitor = AgentMonitor()
    Task {
        _ = await monitor.scan()
        try? await Task.sleep(for: .seconds(60))
        let report = await monitor.scan()
        print(report.diagnosticText)
        exit(0)
    }
    RunLoop.main.run()
} else if CommandLine.arguments.contains("--diagnose-watch") {
    let monitor = AgentMonitor()
    Task {
        let report = await monitor.scan()
        print(report.diagnosticText)
        exit(0)
    }
    RunLoop.main.run()
} else if CommandLine.arguments.contains("--power-safety-sample") {
    app.setActivationPolicy(.prohibited)
    if let battery = PowerSafetyMonitor.battery() {
        print("BATTERY percent=\(battery.percent) onBattery=\(battery.onBattery)")
    } else {
        print("BATTERY unavailable")
    }
    print("THERMAL \(PowerSafetyMonitor.heat())")
} else if CommandLine.arguments.contains("--check-input-monitor") {
    app.setActivationPolicy(.prohibited)
    let monitor = PhysicalInputMonitor()
    let available = monitor.start(requestPermission: false)
    print("INPUT_MONITOR_\(available ? "READY" : "PERMISSION_REQUIRED")")
    monitor.stop()
} else if CommandLine.arguments.contains("--check-settings-controls") {
    app.setActivationPolicy(.prohibited)
    app.finishLaunching()
    verifySettingsControls()
} else if CommandLine.arguments.contains("--self-test") {
    runVerificationApplication()
} else {
    // LaunchServices normally enforces this; also avoid duplicate global hotkeys on direct launches.
    if NSRunningApplication.runningApplications(withBundleIdentifier: "app.aiomni.awakepet")
        .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
        exit(0)
    }
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
