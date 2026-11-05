import VelaLocalization
import AppKit
import RemoteServer

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let defaults: UserDefaults
    let power = PowerController()
    var powerSourceObserver: PowerSourceChangeObserver?
    var wakeDuration: WakeDuration
    var idleThreshold: IdleThreshold
    var idleTimer: IdleWakeTimer
    private(set) var wakeDeadline: Date?
    private var wakeTimer: Timer?
    let physicalInput = PhysicalInputMonitor()
    let agentMonitor = AgentMonitor()
    let lidClient = LidServiceClient()
    var duty = DutyEngine()
    static let keepAwakeModeKey = "keepAwakeMode"
    var keepAwakeMode: KeepAwakeMode
    private var lidOperationInFlight = false
    private var terminationPending = false
    private var latestAgents = AgentReport(entries: [])
    private var watchTimer: Timer?
    private var watchTickInFlight = false
    let hotKey = HotKey()
    var pet: PetController!
    var settings: SettingsController!
    var watchSettings: WatchSettingsController!
    var status: NSStatusItem!
    let toggleItem = NSMenuItem()
    let petDisplayItem = NSMenuItem()
    let agentWatchItem = NSMenuItem()
    let activityModeItem = NSMenuItem()
    let watchDetailItem = NSMenuItem()
    let watchModeItem = NSMenuItem()
    private let updateItem = NSMenuItem()
    private var updater: AppUpdater!
    private var applicationIcon: NSImage?
    private var statusIcon: NSImage?
    var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private let injectedRemoteSettings: RemoteSettingsController?
    private var remoteRuntime: RemoteHostRuntime?
    private var terminationSignals: [DispatchSourceSignal] = []

    init(defaults: UserDefaults = .standard, remoteSettings: RemoteSettingsController? = nil) {
        injectedRemoteSettings = remoteSettings
        self.defaults = defaults
        keepAwakeMode = Self.savedMode(from: defaults)
        wakeDuration = WakeDuration.load(from: defaults)
        idleThreshold = IdleThreshold.load(from: defaults)
        idleTimer = IdleWakeTimer(duration: wakeDuration, threshold: idleThreshold)
        super.init()
        duty.graceSeconds = TimeInterval(WatchSettingsController.graceMinutes(from: defaults) * 60)
        duty.batteryFloor = WatchSettingsController.batteryFloor(from: defaults)
    }

    private static func savedMode(from defaults: UserDefaults) -> KeepAwakeMode {
        guard let raw = defaults.string(forKey: keepAwakeModeKey),
              let mode = KeepAwakeMode(rawValue: raw) else { return .display }
        return mode
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppAppearance.load(from: defaults).apply()
        if let icon = Bundle.main.url(forResource: "Vela", withExtension: "icns") {
            NSApp.applicationIconImage = NSImage(contentsOf: icon)
        }
        do { pet = try PetController(defaults: defaults) }
        catch { showError(L(error.localizedDescription)); NSApp.terminate(nil); return }
        pet.setHeat(PowerSafetyMonitor.heat())
        pet.onToggle = { [weak self] in self?.toggle() }
        pet.onModeSelect = { [weak self] mode in self?.activateWatchMode(mode) }
        pet.onAgentToggle = { [weak self] in self?.toggleAgentWatch() }
        pet.onSettings = { [weak self] in self?.showSettings() }
        pet.onPaletteChange = { [weak self] in
            self?.updateMenu()
        }
        watchSettings = WatchSettingsController(defaults: defaults)
        watchSettings.onChange = { [weak self] grace, battery, names, activityMode in
            guard let self else { return }
            self.duty.graceSeconds = TimeInterval(grace * 60)
            self.duty.batteryFloor = battery
            Task {
                await self.agentMonitor.setCustomNames(names)
                await self.agentMonitor.setMode(activityMode)
                self.runWatchTick()
            }
            self.updateMenu()
        }
        var remoteSettings = injectedRemoteSettings
        if remoteSettings == nil {
            let runtime = RemoteHostRuntime()
            do {
                try runtime.start()
                remoteRuntime = runtime
                remoteSettings = RemoteSettingsController(files: runtime.service.files, service: runtime.service)
                for number in [SIGTERM, SIGINT] {
                    signal(number, SIG_IGN)
                    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
                    source.setEventHandler {
                        RunLoop.main.perform { MainActor.assumeIsolated { NSApp.terminate(nil) } }
                    }
                    source.resume(); terminationSignals.append(source)
                }
            } catch { showError(L(error.localizedDescription)) }
        }
        updater = AppUpdater(defaults: defaults)
        settings = SettingsController(hotKey: hotKey, pet: pet, watchSettings: watchSettings,
                                      wakeDuration: wakeDuration, idleThreshold: idleThreshold,
                                      remoteSettings: remoteSettings, appearanceDefaults: defaults, updater: updater)
        settings.onDuration = { [weak self] duration in self?.setWakeDuration(duration) ?? false }
        settings.onIdleThreshold = { [weak self] threshold in self?.setIdleThreshold(threshold) }
        settings.onWatchMode = { [weak self] mode in self?.activateWatchMode(mode) }
        settings.onShortcut = { [weak self] shortcut in
            if let data = try? JSONEncoder().encode(shortcut) { self?.defaults.set(data, forKey: "shortcut") }
            self?.updateMenu()
        }
        settings.onReset = { [weak self] in try self?.resetSettings() }
        Task {
            await agentMonitor.setCustomNames(WatchSettingsController.customAgents(from: defaults))
            await agentMonitor.setMode(WatchSettingsController.activityMode(from: defaults))
        }
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        toggleItem.target = self
        toggleItem.action = #selector(toggle)
        menu.addItem(toggleItem)
        petDisplayItem.target = self
        petDisplayItem.action = #selector(togglePetDisplay)
        menu.addItem(petDisplayItem)
        menu.addItem(.separator())
        agentWatchItem.title = L("Turn on Agent watch")
        agentWatchItem.target = self
        agentWatchItem.action = #selector(toggleAgentWatch)
        menu.addItem(agentWatchItem)
        watchDetailItem.isEnabled = false
        menu.addItem(watchDetailItem)
        let activityModes = NSMenu(title: L("Agent detection"))
        for mode in AgentActivityMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(selectActivityMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            activityModes.addItem(item)
        }
        activityModeItem.title = L("Agent detection")
        activityModeItem.submenu = activityModes
        menu.addItem(activityModeItem)
        let modes = NSMenu(title: L("Keep-awake mode"))
        for (title, mode) in [(L("Keep display awake"), KeepAwakeMode.display),
                              (L("Allow display sleep, keep system running"), .system),
                              (L("Keep running with lid closed"), .lid)] {
            let item = NSMenuItem(title: title, action: #selector(selectWatchMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            modes.addItem(item)
        }
        watchModeItem.title = L("Keep-awake mode")
        watchModeItem.submenu = modes
        menu.addItem(watchModeItem)
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: L("Settings…"), action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        updateItem.title = L("Check for Updates…")
        updateItem.action = #selector(checkForUpdates)
        updater.onChange = { [weak self] in
            guard let self else { return }
            self.updateItem.title = self.updater.updateAvailable ? L("Update Available…") : L("Check for Updates…")
        }
        updateItem.target = self
        menu.addItem(updateItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: L("Quit Vela"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        status.menu = menu
        let petMenu = NSMenu()
        for (title, action) in [(L("Turn off keep-awake"), #selector(toggle)), (L("Settings…"), #selector(showSettings))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            petMenu.addItem(item)
        }
        pet.view.menu = petMenu
        let expressions = NSMenu(title: L("Expression"))
        let automatic = NSMenuItem(title: L("Automatic"), action: #selector(PetView.selectMood(_:)), keyEquivalent: "")
        automatic.target = pet.view
        automatic.state = pet.view.moodOverride == nil ? .on : .off
        expressions.addItem(automatic)
        expressions.addItem(.separator())
        for mood in PetAnimation.catalog {
            let item = NSMenuItem(title: mood.title, action: #selector(PetView.selectMood(_:)), keyEquivalent: "")
            item.target = pet.view
            item.representedObject = mood.id
            item.state = pet.view.moodOverride == mood.id ? .on : .off
            expressions.addItem(item)
        }
        let expressionItem = NSMenuItem(title: L("Expression"), action: nil, keyEquivalent: "")
        expressionItem.submenu = expressions
        petMenu.addItem(expressionItem)
        let closePetItem = NSMenuItem(title: L("Hide companion"), action: #selector(closePet), keyEquivalent: "")
        closePetItem.target = self
        petMenu.addItem(closePetItem)
        pet.view.onMoodChange = { mood in
            self.pet.persistMood(mood)
            for item in expressions.items where !item.isSeparatorItem {
                item.state = (item.representedObject as? String) == mood ? .on : .off
            }
        }
        let mainMenu = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L("Quit Vela"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        NSApp.mainMenu = mainMenu
        hotKey.onPress = { [weak self] in self?.toggle() }
        physicalInput.onPhysicalInput = { [weak self] in
            guard let self, self.power.isEnabled else { return }
            if self.idleTimer.recordPhysicalInput(at: ProcessInfo.processInfo.systemUptime) {
                self.wakeDeadline = nil
                self.updateMenu()
            }
        }
        let saved = defaults.data(forKey: "shortcut")
            .flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) } ?? .initial
        do { try hotKey.install(); try hotKey.register(saved) }
        catch { settings.hint.stringValue = L(error.localizedDescription) }
        updateMenu()

        observe(.default, Localization.didChange) { [weak self] in
            guard let self else { return }
            LocalizationUI.refreshWindows()
            LocalizationUI.refresh(self.status.menu)
            LocalizationUI.refresh(self.pet.view.menu)
            self.settings.refreshLocalizedState()
            self.updateMenu()
        }

        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.screensDidSleepNotification) { [weak self] in
            self?.pet.setSleeping(true)
        }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.screensDidWakeNotification) { [weak self] in
            self?.pet.setSleeping(false)
            self?.runWatchTick()
        }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.willSleepNotification) { [weak self] in
            self?.pet.setSleeping(true)
        }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification) { [weak self] in
            self?.pet.setSleeping(false)
            self?.refreshWakeCountdown()
            self?.runWatchTick()
        }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) { [weak self] in
            self?.pet.updateAnimation()
        }
        observe(.default, ProcessInfo.thermalStateDidChangeNotification) { [weak self] in
            self?.pet.setHeat(PowerSafetyMonitor.heat())
            self?.updateMenu()
            self?.runWatchTick()
        }
        powerSourceObserver = PowerSourceChangeObserver { [weak self] in self?.runWatchTick() }
        observe(.default, NSApplication.didChangeScreenParametersNotification) { [weak self] in
            self?.pet.fitOnScreen(); self?.pet.savePosition()
        }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.activeSpaceDidChangeNotification) { [weak self] in
            self?.pet.container.dismissForContextChange()
        }
        // No startup assertion and no restoration of an enabled session after relaunch.
        if CommandLine.arguments.contains("--show-settings") { showSettings() }
        pet.show()
        updateMenu()
        updater.start()
        if let warning = defaults.string(forKey: "pendingLidRestoreWarning") {
            defaults.removeObject(forKey: "pendingLidRestoreWarning")
            showError(L("Normal closed-lid sleep could not be confirmed after the previous exit. Check pmset -g. If SleepDisabled is still 1, restore it with sudo pmset -a disablesleep 0.\n\n{0}", "\(warning)"))
        }
        if let index = CommandLine.arguments.firstIndex(of: "--resume-wake-deadline"),
           index + 1 < CommandLine.arguments.count,
           let timestamp = TimeInterval(CommandLine.arguments[index + 1]), timestamp.isFinite {
            resumeKeepAwake(until: Date(timeIntervalSince1970: timestamp))
        } else if CommandLine.arguments.contains("--start-enabled") { toggle() }
        startWatchTimer()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, action: @escaping @MainActor () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { action() }
        }
        observers.append((center, token))
    }

    @objc func toggle() {
        if power.isEnabled || duty.source == .manual {
            power.disable()
            stopWakeCountdown()
            applyDutyEffects(duty.select(.off, mode: keepAwakeMode, observation: watchObservation()))
        } else {
            if wakeDuration.interval != nil && !physicalInput.start(requestPermission: true) {
                showInputMonitorError()
                updateMenu()
                return
            }
            do {
                if keepAwakeMode == .lid {
                    startLidManualSession()
                    return
                }
                try power.enable(keepAwakeMode)
                idleTimer.arm(at: ProcessInfo.processInfo.systemUptime)
                startWakeTimer()
                applyDutyEffects(duty.select(.manual, mode: keepAwakeMode, observation: watchObservation()))
                refreshWakeCountdown()
            }
            catch { physicalInput.stop(); showError(L(error.localizedDescription)) }
        }
        updateMenu()
    }

    @objc func toggleAgentWatch() {
        if duty.source == .agent {
            power.disable()
            stopWakeCountdown()
            latestAgents = AgentReport(entries: [])
            applyDutyEffects(duty.select(.off, mode: keepAwakeMode, observation: watchObservation()))
        } else {
            power.disable()
            stopWakeCountdown()
            applyDutyEffects(duty.select(.agent, mode: keepAwakeMode, observation: watchObservation()))
            runWatchTick()
        }
        updateMenu()
    }

    private func startLidManualSession() {
        idleTimer.arm(at: ProcessInfo.processInfo.systemUptime)
        startWakeTimer()
        applyDutyEffects(duty.select(.manual, mode: .lid, observation: watchObservation()))
        updateMenu()
    }

    @objc private func selectWatchMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = KeepAwakeMode(rawValue: raw) else { return }
        activateWatchMode(mode)
    }

    @objc private func selectActivityMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = AgentActivityMode(rawValue: raw) else { return }
        defaults.set(mode.rawValue, forKey: "agentActivityMode")
        watchSettings?.refresh()
        Task {
            await agentMonitor.setMode(mode)
            runWatchTick()
        }
        updateMenu()
    }

    private func activateWatchMode(_ mode: KeepAwakeMode) {
        keepAwakeMode = mode
        defaults.set(mode.rawValue, forKey: Self.keepAwakeModeKey)
        if duty.source != .off {
            applyDutyEffects(duty.select(duty.source, mode: mode, observation: watchObservation()))
        }
        updateMenu()
    }

    @discardableResult func setWakeDuration(_ duration: WakeDuration) -> Bool {
        let uptime = ProcessInfo.processInfo.systemUptime
        if duty.source == .manual && power.isEnabled && duration.interval != nil && !physicalInput.isRunning {
            guard physicalInput.start(requestPermission: true) else {
                showInputMonitorError()
                return false
            }
            idleTimer.arm(at: uptime)
        }
        wakeDuration = duration
        duration.save(to: defaults)
        idleTimer.setDuration(duration, at: uptime)
        if duty.source == .manual && power.isEnabled {
            if duration.interval == nil { physicalInput.stop(); wakeDeadline = nil; wakeTimer?.invalidate(); wakeTimer = nil }
            else { startWakeTimer(); refreshWakeCountdown() }
        } else { updateMenu() }
        return true
    }

    func setIdleThreshold(_ threshold: IdleThreshold) {
        idleThreshold = threshold
        threshold.save(to: defaults)
        idleTimer.setThreshold(threshold)
        if power.isEnabled { refreshWakeCountdown() }
        else { updateMenu() }
    }

    func resumeKeepAwake(until deadline: Date) {
        guard deadline > Date(), wakeDuration.interval != nil else { return }
        if !power.isEnabled { toggle() }
        guard duty.source == .manual, power.isEnabled else { return }
        idleTimer.resumeCountdown(remaining: deadline.timeIntervalSinceNow,
                                  at: ProcessInfo.processInfo.systemUptime)
        wakeDeadline = deadline
        updateMenu()
    }

    private func startWakeTimer() {
        wakeTimer?.invalidate()
        guard wakeDuration.interval != nil else { wakeTimer = nil; return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshWakeCountdown() }
        }
        wakeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopWakeCountdown() {
        wakeTimer?.invalidate()
        wakeTimer = nil
        wakeDeadline = nil
        idleTimer.disarm()
        physicalInput.stop()
    }

    private func startWatchTimer() {
        watchTimer?.invalidate()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pet?.setHeat(PowerSafetyMonitor.heat())
                self?.runWatchTick()
            }
        }
        watchTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func watchObservation(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> DutyObservation {
        DutyObservation(now: now, busyAgents: latestAgents.busyNames,
                        battery: PowerSafetyMonitor.battery(), heat: PowerSafetyMonitor.heat(),
                        assertionHeld: power.isActuallyHeld(), assertionMode: power.mode,
                        lidHeld: lidClient.isHeld, lidAvailable: lidClient.isAuthorized)
    }

    private func runWatchTick() {
        guard !terminationPending, duty.source != .off else { return }
        if !lidOperationInFlight {
            let safety = watchObservation()
            if safety.heat == .critical ||
                (safety.battery?.onBattery == true && (safety.battery?.percent ?? 100) <= duty.batteryFloor) {
                applyDutyEffects(duty.tick(safety))
                updateMenu()
                return
            }
        }
        guard !watchTickInFlight, !lidOperationInFlight else { return }
        let startedPaused = duty.phase == .thermalPaused
        watchTickInFlight = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.watchTickInFlight = false }
            let report = self.duty.source == .agent ? await self.agentMonitor.scan() : AgentReport(entries: [])
            guard !self.terminationPending, self.duty.source != .off,
                  self.duty.phase != .thermalPaused || startedPaused else { return }
            self.latestAgents = report
            if self.lidClient.isHeld {
                let alive = await self.lidClient.heartbeat()
                guard !self.terminationPending, self.duty.source != .off,
                      self.duty.phase != .thermalPaused || startedPaused else { return }
                if !alive {
                    let reason = self.lidClient.lastMessage
                    _ = await self.lidClient.close()
                    self.applyDutyEffects(self.duty.fail(reason, observation: self.watchObservation()))
                    self.updateMenu()
                    return
                }
            }
            self.applyDutyEffects(self.duty.tick(self.watchObservation()))
            self.updateMenu()
        }
    }

    func applyDutyEffects(_ effects: [DutyEffect]) {
        guard !terminationPending else { return }
        if duty.phase == .off || duty.phase == .lowBatteryStopped || duty.phase == .fault {
            stopWakeCountdown()
        }
        for effect in effects {
            switch effect {
            case .acquire(let mode):
                do { try power.enable(mode) }
                catch {
                    applyDutyEffects(duty.fail(error.localizedDescription, observation: watchObservation()))
                    return
                }
            case .release:
                power.disable()
                if duty.source != .manual || duty.phase == .lowBatteryStopped || duty.phase == .fault || duty.phase == .off {
                    stopWakeCountdown()
                }
            case .enableLid:
                guard !lidOperationInFlight else { return }
                lidOperationInFlight = true
                Task { [weak self] in
                    guard let self else { return }
                    let ok = await self.lidClient.open()
                    self.lidOperationInFlight = false
                    if ok { self.applyDutyEffects(self.duty.tick(self.watchObservation())) }
                    else { self.applyDutyEffects(self.duty.fail(self.lidClient.lastMessage, observation: self.watchObservation())) }
                    self.updateMenu()
                }
                return
            case .restoreLid:
                guard !lidOperationInFlight else { return }
                lidOperationInFlight = true
                Task { [weak self] in
                    guard let self else { return }
                    let ok = await self.lidClient.close()
                    self.lidOperationInFlight = false
                    if ok {
                        if self.duty.phase == .agentStandby {
                            self.duty.finishLidSession()
                        }
                        self.applyDutyEffects(self.duty.tick(self.watchObservation()))
                    }
                    else { self.applyDutyEffects(self.duty.fail(self.lidClient.lastMessage, observation: self.watchObservation())) }
                    self.updateMenu()
                }
                return
            case .record(let message):
                NSLog("Vela: %@", message)
            }
        }
    }

    func refreshWakeCountdown(now: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard duty.source == .manual, power.isEnabled else { return }
        if wakeDuration.interval != nil && !physicalInput.ensureRunning() {
            power.disable()
            stopWakeCountdown()
            applyDutyEffects(duty.select(.off, mode: .display, observation: watchObservation()))
            showError(L("Physical input monitoring stopped. Keep-awake is off. Check Input Monitoring access for this Vela build, then quit and reopen it."))
        } else if idleTimer.tick(at: uptime) {
            power.disable()
            stopWakeCountdown()
            applyDutyEffects(duty.select(.off, mode: .display, observation: watchObservation()))
        } else {
            wakeDeadline = idleTimer.remaining(at: uptime).map { now.addingTimeInterval($0) }
        }
        updateMenu(now: now)
    }

    func updateMenu(now: Date = Date()) {
        let heat = PowerSafetyMonitor.heat()
        toggleItem.title = duty.source == .manual || power.isEnabled ? L("Turn off keep-awake") : L("Turn on keep-awake")
        toggleItem.state = power.isEnabled ? .on : .off
        pet?.setEnabled(power.isEnabled)
        pet?.setKeepAwakeMode(keepAwakeMode)
        pet?.setDutyPhase(duty.phase)
        pet?.setAgentWatchEnabled(duty.source == .agent)
        agentWatchItem.title = duty.source == .agent ? L("Turn off Agent watch") : L("Turn on Agent watch")
        agentWatchItem.state = duty.source == .agent ? .on : .off
        let activityMode = WatchSettingsController.activityMode(from: defaults)
        for item in activityModeItem.submenu?.items ?? [] {
            item.state = item.representedObject as? String == activityMode.rawValue ? .on : .off
        }
        settings?.watchMode = keepAwakeMode
        for item in watchModeItem.submenu?.items ?? [] {
            item.state = item.representedObject as? String == keepAwakeMode.rawValue ? .on : .off
        }
        switch duty.phase {
        case .agentStandby: watchDetailItem.title = L("Agent standby · Keep-awake inactive")
        case .agentActive: watchDetailItem.title = L("Agent watch · {0}", "\(duty.lastBusyAgents)")
        case .grace:
            let left = Int(ceil(duty.graceRemaining(at: ProcessInfo.processInfo.systemUptime) ?? 0))
            watchDetailItem.title = L("Agents idle · Releasing in {0} seconds", "\(left)")
        case .thermalPaused: watchDetailItem.title = L("Device overheating · Watch paused")
        case .lowBatteryStopped: watchDetailItem.title = L("Low battery · Watch ended")
        case .fault: watchDetailItem.title = L("Watch fault · {0}", "\(L(duty.faultReason ?? "Check Settings"))")
        case .manual: watchDetailItem.title = power.isActuallyHeld() ? L("Manual keep-awake") : L("Enabling keep-awake…")
        case .off: watchDetailItem.title = L("Watch is off")
        }
        if heat == .serious && duty.phase != .thermalPaused {
            watchDetailItem.title += L(" · Device temperature is high")
        }
        pet?.view.menu?.items.first?.title = toggleItem.title
        petDisplayItem.title = pet?.panel.isVisible == true ? L("Hide companion") : L("Show companion")
        petDisplayItem.state = pet?.panel.isVisible == true ? .on : .off
        if let pet, applicationIcon == nil {
            applicationIcon = makeApplicationIcon(geometry: pet.view.geometry)
            statusIcon = makeStatusPetIcon(geometry: pet.view.geometry)
        }
        if let applicationIcon { NSApp.applicationIconImage = applicationIcon }
        if let button = status?.button {
            button.image = statusIcon
            let stateLabel: String?
            if power.isEnabled && duty.source != .agent {
                switch idleTimer.phase {
                case .waiting: stateLabel = nil
                case .counting: stateLabel = wakeDeadline.map { WakeDuration.remainingLabel(until: $0, now: now) }
                case .unlimited: stateLabel = "∞"
                case .off: stateLabel = nil
                }
            } else { stateLabel = nil }
            button.title = stateLabel.map { " \($0)" } ?? ""
            button.imagePosition = .imageLeft
            switch duty.phase {
            case .agentStandby: button.toolTip = L("Vela · Agent watch standby")
            case .agentActive: button.toolTip = L("Vela · Watching {0}", "\(duty.lastBusyAgents)")
            case .grace: button.toolTip = L("Vela · Agent idle grace period")
            case .thermalPaused: button.toolTip = L("Vela · Paused due to heat")
            case .lowBatteryStopped: button.toolTip = L("Vela · Stopped due to low battery")
            case .fault: button.toolTip = L("Vela · Watch fault")
            default: switch idleTimer.phase {
            case .waiting where power.isEnabled:
                button.toolTip = L("Vela · Enabled; countdown starts after {0} minutes of continuous idle time", "\(idleThreshold.minutes)")
            case .counting where power.isEnabled:
                button.toolTip = L("Vela · Idle countdown remaining {0}", "\(stateLabel ?? "")")
            case .unlimited where power.isEnabled:
                button.toolTip = L("Vela · Unlimited keep-awake")
            default:
                button.toolTip = L("Vela · Keep-awake is off")
            }
            }
            if heat == .serious && duty.phase != .thermalPaused {
                button.toolTip = (button.toolTip ?? "Vela") + L(" · Device temperature is high")
            }
            button.setAccessibilityLabel(button.toolTip)
        }
    }

    @objc func togglePetDisplay() {
        if pet.panel.isVisible { closePet() }
        else { pet.show(); updateMenu() }
    }

    @objc func closePet() { pet.hide(); updateMenu() }

    @objc func showSettings() { settings.show() }

    @objc private func checkForUpdates() {
        showSettings()
        settings.navigationController.select(.general)
        if !updater.updateAvailable { updater.check() }
    }

    func resetSettings() throws {
        try settings.remoteSettings.reset()
        try hotKey.register(.initial)
        defaults.removeObject(forKey: "shortcut")
        power.disable()
        stopWakeCountdown()
        applyDutyEffects(duty.select(.off, mode: .display, observation: watchObservation()))
        wakeDuration = .unlimited
        wakeDuration.save(to: defaults)
        idleThreshold = .defaultValue
        idleThreshold.save(to: defaults)
        idleTimer.setDuration(.unlimited, at: ProcessInfo.processInfo.systemUptime)
        idleTimer.setThreshold(.defaultValue)
        for key in ["agentGraceMinutes", "watchBatteryFloor", "watchCustomAgents"] {
            defaults.removeObject(forKey: key)
        }
        duty.graceSeconds = 300
        duty.batteryFloor = 20
        keepAwakeMode = .display
        defaults.removeObject(forKey: Self.keepAwakeModeKey)
        Task { await agentMonitor.setCustomNames([]) }
        watchSettings?.refresh()
        defaults.removeObject(forKey: AppAppearance.preferenceKey)
        AppAppearance.automatic.apply()
        pet.resetPreferences()
        pet.show()
        updateMenu()
    }

    private func showInputMonitorError() {
        switch physicalInput.startFailure {
        case .permissionRequired:
            showError(L("This Vela build needs Input Monitoring access to measure physical input in timed mode. In System Settings → Privacy & Security → Input Monitoring, authorize the running Vela build. Ad-hoc test builds and the installed app may have different identities. Fully quit and reopen after granting access. Unlimited mode does not require this permission."))
        case .tapUnavailable, .none:
            showError(L("Input Monitoring could not start. Keep-awake is not enabled. Fully quit and reopen Vela even if access appears granted. If it still fails, use Unlimited mode and check for system policies restricting Input Monitoring."))
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Vela"
        alert.informativeText = message
        alert.addButton(withTitle: L("OK"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard remoteRuntime != nil || lidClient.hasSession || lidOperationInFlight else { return .terminateNow }
        if terminationPending { return .terminateLater }
        terminationPending = true
        watchTimer?.invalidate()
        watchTimer = nil
        power.disable()
        stopWakeCountdown()
        _ = duty.select(.off, mode: .display, observation: watchObservation())
        Task { [weak self, weak sender] in
            guard let self else { sender?.reply(toApplicationShouldTerminate: true); return }
            let remoteShutdown = Task { await self.remoteRuntime?.stop() }
            let deadline = ProcessInfo.processInfo.systemUptime + 7
            while self.lidOperationInFlight && ProcessInfo.processInfo.systemUptime < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if self.lidOperationInFlight {
                let restored = await self.lidClient.disconnectAndConfirmRestored()
                if restored { self.defaults.removeObject(forKey: "pendingLidRestoreWarning") }
                else { self.defaults.set(L("The closed-lid operation did not finish before exit, and normal sleep restoration could not be confirmed"), forKey: "pendingLidRestoreWarning") }
                await remoteShutdown.value
                sender?.reply(toApplicationShouldTerminate: true)
                return
            }
            let restored = await self.lidClient.close()
            if !restored {
                NSLog("Vela: closed-lid restoration was not confirmed on exit: %@", self.lidClient.lastMessage)
                self.defaults.set(self.lidClient.lastMessage, forKey: "pendingLidRestoreWarning")
            } else {
                self.defaults.removeObject(forKey: "pendingLidRestoreWarning")
            }
            await remoteShutdown.value
            sender?.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        for source in terminationSignals { source.cancel() }
        terminationSignals.removeAll()
        powerSourceObserver?.stop()
        powerSourceObserver = nil
        watchTimer?.invalidate()
        watchTimer = nil
        updater?.stop()
        settings?.finishRecording()
        hotKey.stop()
        lidClient.disconnect()
        power.disable()
        stopWakeCountdown()
        _ = duty.select(.off, mode: .display, observation: watchObservation())
        pet?.hide()
        for (center, token) in observers { center.removeObserver(token) }
    }
}
