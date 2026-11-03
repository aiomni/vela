import VelaLocalization
import AppKit
import ServiceManagement

@MainActor
final class SettingsController: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    let window: NSWindow
    let shortcutButton = NSButton()
    let languagePicker = LanguagePicker()
    let appearancePicker: AppearancePreferencesController
    let hint = NSTextField(wrappingLabelWithString: "")
    let durationBar = DurationProgressBar()
    let durationValueLabel = NSTextField(labelWithString: "")
    let durationField = NSTextField()
    let durationUnit = NSTextField(labelWithString: L("minutes"))
    let durationHint = NSTextField(wrappingLabelWithString: "")
    let idleField = NSTextField()
    let idleHint = NSTextField(wrappingLabelWithString: "")
    let inputMonitoringButton = NSButton(title: L("Open settings…"), target: nil, action: nil)
    private let inputMonitoringStatus = SettingsStyle.note("")
    let watchModeButton = NSPopUpButton()
    let sizeBar = PetSizeProgressBar()
    let loginButton = SettingsStyle.compactSwitch()
    let loginHint = NSTextField(wrappingLabelWithString: "")
    let loginSettingsButton = NSButton(title: L("Open Login Items settings…"), target: nil, action: nil)
    let resetButton = NSButton(title: L("Reset to defaults"), target: nil, action: nil)
    let remoteSettings: RemoteSettingsController
    private(set) var navigationController: SettingsNavigationController!
    let colorStyleButton = NSPopUpButton()
    let shapeButton = NSButton()
    let moodButton = NSButton()
    private let shapePopover = NSPopover()
    private let moodPopover = NSPopover()
    let paletteButton = NSButton()
    let restPaletteButton = NSButton()
    private var palettePicker: PalettePickerController!
    private var restPalettePicker: PalettePickerController!
    private let loginItem: any LoginItemServicing
    private let hotKey: HotKey
    private let pet: PetController
    private let watchSettings: WatchSettingsController
    private var wakeDuration: WakeDuration
    private var idleThreshold: IdleThreshold
    var watchMode: KeepAwakeMode = .display {
        didSet { watchModeButton.selectItem(withTitle: watchModeTitle) }
    }
    private var recorder: Any?
    var onShortcut: ((Shortcut) -> Void)?
    var onDuration: ((WakeDuration) -> Bool)?
    var onIdleThreshold: ((IdleThreshold) -> Void)?
    var onWatchMode: ((KeepAwakeMode) -> Void)?
    var onReset: (() throws -> Void)?

    init(hotKey: HotKey, pet: PetController, watchSettings: WatchSettingsController,
         wakeDuration: WakeDuration = .unlimited,
         idleThreshold: IdleThreshold = .defaultValue,
         loginItem: any LoginItemServicing = MainAppLoginItem(),
         remoteSettings injectedRemoteSettings: RemoteSettingsController? = nil,
         appearanceDefaults: UserDefaults = .standard) {
        appearancePicker = AppearancePreferencesController(defaults: appearanceDefaults)
        self.remoteSettings = injectedRemoteSettings ?? RemoteSettingsController()
        self.hotKey = hotKey
        self.pet = pet
        self.watchSettings = watchSettings
        self.wakeDuration = wakeDuration
        self.idleThreshold = idleThreshold
        self.loginItem = loginItem
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 620),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.title = L("Vela Settings")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        pet.onShapeChange = { [weak self] in self?.refreshShape() }
        window.minSize = NSSize(width: 740, height: 540)
        shortcutButton.target = self
        shortcutButton.action = #selector(recordShortcut)
        shortcutButton.bezelStyle = .rounded
        shortcutButton.widthAnchor.constraint(equalToConstant: 190).isActive = true
        hint.stringValue = L("Click, then press a new shortcut. Esc cancels.")
        for label in [hint, durationHint, idleHint, loginHint] {
            label.textColor = .secondaryLabelColor
            label.font = .systemFont(ofSize: 11)
        }
        durationBar.duration = wakeDuration
        durationBar.onChange = { [weak self] in self?.applyDuration($0) }
        durationBar.setAccessibilityLabel(L("Keep-awake duration. Drag or use the arrow keys to adjust"))
        durationBar.heightAnchor.constraint(equalToConstant: 42).isActive = true
        durationValueLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        durationValueLabel.textColor = .secondaryLabelColor
        durationField.placeholderString = L("Custom")
        durationField.setAccessibilityLabel(L("Custom keep-awake duration in minutes"))
        durationField.delegate = self
        durationField.widthAnchor.constraint(equalToConstant: 90).isActive = true
        let durationControls = NSStackView(views: [durationField, durationUnit])
        durationControls.spacing = 8
        durationHint.stringValue = L("Drag for finer short durations; the right edge is unlimited. You can also enter any number of minutes.")
        idleField.setAccessibilityLabel(L("Minutes of continuous idle time before the countdown starts"))
        idleField.delegate = self
        idleField.widthAnchor.constraint(equalToConstant: 75).isActive = true
        let idleControls = NSStackView(views: [idleField, NSTextField(labelWithString: L("minutes"))])
        idleControls.spacing = 8
        idleHint.stringValue = L("Only physical keyboard and mouse activity counts. Input resets the countdown. Enter 0 to start immediately.")
        for (title, mode) in [(L("Keep display awake"), KeepAwakeMode.display),
                              (L("Allow display sleep, keep system running"), .system),
                              (L("Keep running with lid closed"), .lid)] {
            watchModeButton.addItem(withTitle: title)
            watchModeButton.lastItem?.representedObject = mode.rawValue
        }
        watchModeButton.target = self
        watchModeButton.action = #selector(watchModeChanged)
        watchModeButton.widthAnchor.constraint(equalToConstant: 280).isActive = true
        sizeBar.size = pet.petSize
        sizeBar.onChange = { [weak self] in self?.sizeChanged($0) }
        sizeBar.heightAnchor.constraint(equalToConstant: 58).isActive = true
        shapeButton.target = self; shapeButton.action = #selector(showShapePicker)
        moodButton.target = self; moodButton.action = #selector(showMoodPicker)
        shapePopover.behavior = .transient; moodPopover.behavior = .transient
        colorStyleButton.addItems(withTitles: ColorTransitionStyle.allCases.map(\.title))
        colorStyleButton.target = self; colorStyleButton.action = #selector(colorStyleChanged)
        colorStyleButton.alignment = .right; colorStyleButton.cell?.alignment = .right
        colorStyleButton.widthAnchor.constraint(equalToConstant: 190).isActive = true
        palettePicker = PalettePickerController(pet: pet)
        palettePicker.onChange = { [weak self] in self?.refreshPalette() }
        restPalettePicker = PalettePickerController(pet: pet, target: .resting)
        restPalettePicker.onChange = { [weak self] in self?.refreshRestPalette() }
        paletteButton.target = self; paletteButton.action = #selector(showPalettePicker)
        restPaletteButton.target = self; restPaletteButton.action = #selector(showRestPalettePicker)
        for button in [shapeButton, moodButton, paletteButton, restPaletteButton] {
            button.bezelStyle = .rounded
            button.isBordered = false
            button.alignment = .right
            button.contentTintColor = .labelColor
            button.image = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)
            button.imagePosition = .imageRight
            button.widthAnchor.constraint(equalToConstant: 190).isActive = true
        }
        loginButton.setAccessibilityLabel(L("Launch at login"))
        loginButton.target = self; loginButton.action = #selector(toggleLoginItem)
        loginSettingsButton.target = self; loginSettingsButton.action = #selector(openLoginSettings)
        resetButton.target = self; resetButton.action = #selector(confirmReset)
        resetButton.toolTip = L("Restore shortcuts, duration, watch settings, appearance, and position; turn off keep-awake and launch at login")
        inputMonitoringButton.target = self
        inputMonitoringButton.action = #selector(openInputMonitoring)
        inputMonitoringButton.setAccessibilityLabel(L("Open Input Monitoring settings"))
        let language = languagePicker
        for popup in [language, watchModeButton, colorStyleButton] {
            popup.isBordered = false; popup.alignment = .right; popup.cell?.alignment = .right
        }
        language.widthAnchor.constraint(equalToConstant: 190).isActive = true
        let loginDetails = NSStackView(views: [loginHint, loginSettingsButton])
        loginDetails.orientation = .vertical; loginDetails.alignment = .leading; loginDetails.spacing = 4
        let general = SettingsPageView(.general, sections: [
            SettingsStyle.heading(L("Preferences")),
            SettingsStyle.group([
                SettingsStyle.row(L("Language"), language),
                SettingsStyle.row(L("Launch at login"), loginButton, detail: loginDetails),
                SettingsStyle.row(L("Toggle shortcut"), shortcutButton)
            ]),
            hint,
            SettingsStyle.heading(L("Reset")),
            SettingsStyle.group([SettingsStyle.row(L("Reset settings"), resetButton)])
        ])
        let durationHeading = NSStackView(views: [NSTextField(labelWithString: L("Keep-awake duration")), NSView(), durationValueLabel])
        durationHeading.alignment = .centerY
        let keepAwake = SettingsPageView(.keepAwake, sections: [
            SettingsStyle.heading(L("Keep-awake mode")),
            SettingsStyle.group([SettingsStyle.row(L("Keep-awake mode"), watchModeButton)]),
            SettingsStyle.heading(L("Timing")),
            SettingsStyle.group([SettingsStyle.block([durationHeading, durationBar]),
                                 SettingsStyle.row(L("Custom duration"), durationControls),
                                 SettingsStyle.row(L("Count down after idle"), idleControls)]),
            durationHint, idleHint,
            SettingsStyle.heading(L("Permissions")),
            SettingsStyle.group([SettingsStyle.row(L("Input Monitoring"), inputMonitoringButton,
                detail: inputMonitoringStatus)]),
            SettingsStyle.note(L("Measures physical keyboard and mouse activity for the idle countdown. Unlimited mode does not require this permission."))
        ])
        let agent = SettingsPageView(.agent, sections: [SettingsStyle.heading(L("Activity detection")), watchSettings.view])
        let appearance = SettingsPageView(.appearance, sections: [
            SettingsStyle.group([SettingsStyle.row(L("Appearance"), appearancePicker.view, alignment: .top)]),
            SettingsStyle.heading(L("Companion")),
            SettingsStyle.group([SettingsStyle.row(L("Shape"), shapeButton), SettingsStyle.row(L("Expression"), moodButton)]),
            SettingsStyle.group([SettingsStyle.block([sizeBar])]),
            SettingsStyle.heading(L("Colors")),
            SettingsStyle.group([SettingsStyle.row(L("Awake colors"), paletteButton),
                                 SettingsStyle.row(L("Resting colors"), restPaletteButton),
                                 SettingsStyle.row(L("Color transition"), colorStyleButton)]),
            SettingsStyle.note(L("Drag the companion to move it. Hover to reveal controls. Settings save automatically."))
        ])
        let remote = SettingsPageView(.remote, sections: [SettingsStyle.heading(L("Connection")), remoteSettings.view])
        navigationController = SettingsNavigationController(pages: [
            .general: general, .keepAwake: keepAwake, .agent: agent, .appearance: appearance, .remote: remote
        ])
        appearancePicker.onChange = { [weak self] in self?.window.appearance = nil }
        navigationController.onPageChange = { [weak self] page in
            guard let self else { return }
            if let responder = window.firstResponder as? NSView,
               responder.isDescendant(of: navigationController.pages[navigationController.selectedPage]!.view)
                || (responder as? NSTextView)?.isFieldEditor == true {
                window.makeFirstResponder(nil)
            }
            if recorder != nil && page != .general { finishRecording() }
            shapePopover.close(); moodPopover.close()
            palettePicker.popover.close(); restPalettePicker.popover.close()
        }
        window.contentViewController = navigationController
        navigationController.installToolbar(on: window)
        window.setContentSize(NSSize(width: 800, height: 620))
        window.center()
        navigationController.refreshLanguage()
        refresh()
    }

    func show() {
        refresh()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showShortcutRecorder() {
        navigationController.select(.general)
        show()
        if recorder == nil { recordShortcut() }
    }

    func refresh() {
        refreshInputMonitoring()
        appearancePicker.refresh()
        remoteSettings.refresh()
        shortcutButton.title = hotKey.shortcut?.display ?? L("Set shortcut…")
        watchModeButton.selectItem(withTitle: watchModeTitle)
        watchSettings.refresh()
        refreshDuration()
        idleField.stringValue = String(idleThreshold.minutes)
        sizeBar.size = pet.petSize
        sizeBar.setAccessibilityLabel(L("Companion size {0} pt. Drag or use arrow keys to adjust", "\(Int(pet.petSize))"))
        refreshShape()
        moodButton.title = pet.view.moodOverride.flatMap { id in PetAnimation.catalog.first { $0.id == id }?.title } ?? L("Automatic")
        colorStyleButton.selectItem(at: ColorTransitionStyle.allCases.firstIndex(of: pet.view.colorStyle)!)
        refreshPalette()
        refreshRestPalette()
        refreshLoginItem()
    }

    func refreshLocalizedState() {
        refreshInputMonitoring()
        appearancePicker.refresh()
        navigationController.refreshLanguage()
        remoteSettings.refresh()
        if recorder == nil { shortcutButton.title = hotKey.shortcut?.display ?? L("Set shortcut…") }
        if case .minutes(let minutes) = wakeDuration { durationValueLabel.stringValue = Self.durationLabel(minutes) }
        else { durationValueLabel.stringValue = L("Unlimited") }
        refreshShape()
        moodButton.title = pet.view.moodOverride.flatMap { id in PetAnimation.catalog.first { $0.id == id }?.title } ?? L("Automatic")
        refreshPalette(); refreshRestPalette(); refreshLoginItem()
    }

    private var watchModeTitle: String {
        switch watchMode {
        case .display: L("Keep display awake")
        case .system: L("Allow display sleep, keep system running")
        case .lid: L("Keep running with lid closed")
        }
    }

    @objc func watchModeChanged() {
        guard let raw = watchModeButton.selectedItem?.representedObject as? String,
              let mode = KeepAwakeMode(rawValue: raw) else { return }
        watchMode = mode
        onWatchMode?(mode)
    }

    @objc private func confirmReset() {
        let alert = NSAlert()
        alert.messageText = L("Reset to defaults?")
        alert.informativeText = L("Reset the shortcut, duration, idle threshold, keep-awake mode, Agent settings, app appearance, companion size, shape, expression, effects, awake and resting colors, eye color, and position. Keep-awake and launch at login will be turned off.")
        alert.addButton(withTitle: L("Reset to defaults"))
        alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try resetToDefaults() }
        catch { loginHint.stringValue = L("Reset failed: {0}", "\(L(error.localizedDescription))") }
    }

    func resetToDefaults() throws {
        finishRecording()
        palettePicker.popover.close()
        restPalettePicker.popover.close()
        shapePopover.close()
        moodPopover.close()
        if loginItem.status == .enabled || loginItem.status == .requiresApproval {
            try loginItem.unregister()
        }
        try onReset?()
        appearancePicker.reset()
        wakeDuration = .unlimited
        idleThreshold = .defaultValue
        refresh()
    }

    private func refreshDuration() {
        durationBar.duration = wakeDuration
        switch wakeDuration {
        case .unlimited:
            durationValueLabel.stringValue = L("Unlimited")
            durationField.stringValue = ""
        case .minutes(let minutes):
            durationValueLabel.stringValue = Self.durationLabel(minutes)
            durationField.stringValue = String(minutes)
        }
    }

    private static func durationLabel(_ minutes: Int) -> String {
        if minutes > 10080 { return L("Custom duration") }
        if minutes < 60 { return L("{0} minutes", "\(minutes)") }
        if minutes % 1440 == 0 { return L("{0} days", "\(minutes / 1440)") }
        if minutes % 60 == 0 { return L("{0} hours", "\(minutes / 60)") }
        return L("{0}h {1}m", "\(minutes / 60)", "\(minutes % 60)")
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        if notification.object as? NSTextField === durationField { customDurationChanged() }
        else if notification.object as? NSTextField === idleField { customIdleChanged() }
    }

    private func customDurationChanged() {
        let input = durationField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let minutes = Int(input), minutes >= 1 else {
            durationHint.stringValue = L("Enter a whole number of at least 1 minute.")
            return
        }
        applyDuration(.minutes(minutes))
    }

    private func applyDuration(_ duration: WakeDuration) {
        guard onDuration?(duration) != false else { refreshDuration(); return }
        wakeDuration = duration
        durationHint.stringValue = L("Drag for finer short durations; the right edge is unlimited. You can also enter any number of minutes.")
        refreshDuration()
    }

    private func customIdleChanged() {
        let input = idleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let minutes = Int(input), (0...1440).contains(minutes) else {
            idleHint.stringValue = L("Enter a whole number of minutes from 0 to 1440.")
            idleField.stringValue = String(idleThreshold.minutes)
            return
        }
        let threshold = IdleThreshold(minutes: minutes)
        idleThreshold = threshold
        idleHint.stringValue = L("Only physical keyboard and mouse activity counts. Input resets the countdown. Enter 0 to start immediately.")
        onIdleThreshold?(threshold)
    }

    func refreshLoginItem() {
        loginSettingsButton.isHidden = loginItem.status != .requiresApproval
        switch loginItem.status {
        case .enabled:
            loginButton.state = .on
            loginHint.stringValue = L("Automatically launch and show the companion at the next login.")
        case .requiresApproval:
            loginButton.state = .on
            loginHint.stringValue = L("Waiting for system approval. Allow Vela in Login Items settings.")
        case .notRegistered:
            loginButton.state = .off
            loginHint.stringValue = L("You can open Vela manually when this is off.")
        case .notFound:
            loginButton.state = .off
            loginHint.stringValue = L("Login item not registered. Enable it to register.")
        @unknown default:
            loginButton.state = .off
            loginHint.stringValue = L("Unable to read the system login item status.")
        }
    }

    @objc private func toggleLoginItem() {
        do {
            if loginButton.state == .on { try loginItem.register() }
            else { try loginItem.unregister() }
            refreshLoginItem()
        } catch {
            refreshLoginItem()
            loginHint.stringValue = L("Setting failed: {0}", "\(L(error.localizedDescription))")
        }
    }

    @objc private func openLoginSettings() { loginItem.openSettings() }
    private func refreshInputMonitoring() {
        inputMonitoringStatus.stringValue = CGPreflightListenEventAccess() ? L("Granted") : L("Not granted")
    }

    @objc private func openInputMonitoring() {
        if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
        SettingsPrivacy.open("Privacy_ListenEvent")
        refreshInputMonitoring()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        refreshLoginItem()
        refreshInputMonitoring()
        remoteSettings.refresh()
    }

    private func sizeChanged(_ size: Double) { pet.resize(to: size); pet.savePosition(); refresh() }
    private func preview(shape: PetShape, mood: String?) -> NSImage {
        NSImage(size: NSSize(width: 64, height: 64), flipped: true) { [geometry = pet.view.geometry] _ in
            let preview = PetView(geometry: geometry)
            preview.frame = NSRect(x: 0, y: 0, width: 64, height: 64)
            preview.drawingPadding = 0
            preview.shape = shape
            preview.palette = .blue
            preview.moodOverride = mood
            preview.reduceMotion = true
            preview.isAwake = true
            preview.draw(preview.bounds)
            return true
        }
    }
    func appearancePopover(items: [(String, PetShape, String?)], shapePicker: Bool) -> NSViewController {
        let controller = NSViewController()
        let columns = 4
        let rows = Int(ceil(Double(items.count) / Double(columns)))
        let tileSide: CGFloat = 76
        let spacing: CGFloat = 6
        let inset: CGFloat = 12
        let background = PopoverBackgroundView(frame: NSRect(x: 0, y: 0,
            width: inset * 2 + CGFloat(columns) * tileSide + CGFloat(columns - 1) * spacing,
            height: inset * 2 + CGFloat(rows) * tileSide + CGFloat(rows - 1) * spacing))
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.refreshAppearance()
        controller.view = background
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor, constant: inset),
            stack.topAnchor.constraint(equalTo: controller.view.topAnchor, constant: inset)
        ])
        for rowIndex in 0..<rows {
            let row = NSStackView()
            row.spacing = spacing
            for column in 0..<columns {
                let index = rowIndex * columns + column
                let slot = AppearanceTileView()
                slot.widthAnchor.constraint(equalToConstant: tileSide).isActive = true
                slot.heightAnchor.constraint(equalToConstant: tileSide).isActive = true
                if index < items.count {
                    let item = items[index]
                    let selected = shapePicker
                        ? (index == 0 ? pet.automaticShape : !pet.automaticShape && pet.view.shape == item.1)
                        : pet.view.moodOverride == item.2
                    slot.wantsLayer = true
                    slot.layer?.cornerRadius = 10
                    slot.isTileVisible = true
                    slot.isSelected = selected
                    let image = NSImageView()
                    image.image = shapePicker && index == 0
                        ? NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: L("Automatic"))
                        : preview(shape: item.1, mood: item.2)
                    image.imageScaling = .scaleProportionallyDown
                    let label = NSTextField(labelWithString: item.0)
                    label.font = .systemFont(ofSize: 11, weight: selected ? .semibold : .regular)
                    label.textColor = selected ? .controlAccentColor : .labelColor
                    label.alignment = .center
                    let content = NSStackView(views: [image, label])
                    content.orientation = .vertical
                    content.alignment = .centerX
                    content.spacing = 1
                    content.translatesAutoresizingMaskIntoConstraints = false
                    slot.addSubview(content)
                    let button = NSButton(title: "", target: self,
                        action: shapePicker ? #selector(selectShapeTile(_:)) : #selector(selectMoodTile(_:)))
                    button.tag = index
                    button.isBordered = false
                    button.translatesAutoresizingMaskIntoConstraints = false
                    button.setAccessibilityLabel("\(shapePicker ? L("Shape") : L("Expression")): \(item.0)")
                    slot.addSubview(button)
                    NSLayoutConstraint.activate([
                        content.centerXAnchor.constraint(equalTo: slot.centerXAnchor),
                        content.centerYAnchor.constraint(equalTo: slot.centerYAnchor),
                        image.widthAnchor.constraint(equalToConstant: 46),
                        image.heightAnchor.constraint(equalToConstant: 46),
                        label.widthAnchor.constraint(equalToConstant: tileSide - 4),
                        button.leadingAnchor.constraint(equalTo: slot.leadingAnchor),
                        button.trailingAnchor.constraint(equalTo: slot.trailingAnchor),
                        button.topAnchor.constraint(equalTo: slot.topAnchor),
                        button.bottomAnchor.constraint(equalTo: slot.bottomAnchor)
                    ])
                }
                row.addArrangedSubview(slot)
            }
            stack.addArrangedSubview(row)
        }
        return controller
    }
    @objc private func showShapePicker() {
        if shapePopover.isShown { shapePopover.close(); return }
        let items: [(String, PetShape, String?)] = [(L("Automatic"), pet.view.shape, nil)] +
            PetShape.allCases.map { ($0.title, $0, String?.none) }
        shapePopover.contentViewController = appearancePopover(items: items, shapePicker: true)
        shapePopover.show(relativeTo: shapeButton.bounds, of: shapeButton, preferredEdge: .maxX)
    }
    @objc private func showMoodPicker() {
        if moodPopover.isShown { moodPopover.close(); return }
        let items: [(String, PetShape, String?)] = [(L("Automatic"), pet.view.shape, nil)] +
            PetAnimation.catalog.map { ($0.title, pet.view.shape, $0.id) }
        moodPopover.contentViewController = appearancePopover(items: items, shapePicker: false)
        moodPopover.show(relativeTo: moodButton.bounds, of: moodButton, preferredEdge: .maxX)
    }
    @objc private func selectShapeTile(_ sender: NSButton) {
        if sender.tag == 0 { pet.setAutomaticShape(true) }
        else { pet.setShape(PetShape.allCases[sender.tag - 1]) }
        shapePopover.close()
        refresh()
    }
    @objc private func selectMoodTile(_ sender: NSButton) {
        pet.setMood(sender.tag == 0 ? nil : PetAnimation.catalog[sender.tag - 1].id)
        moodPopover.close()
        refresh()
    }
    @objc private func colorStyleChanged() {
        pet.setColorStyle(ColorTransitionStyle.allCases[colorStyleButton.indexOfSelectedItem])
    }
    private func refreshPalette() {
        paletteButton.title = pet.view.palette.title
        paletteButton.setAccessibilityLabel(L("Awake colors: {0}", "\(pet.view.palette.title)"))
    }
    private func refreshShape() {
        shapeButton.title = pet.automaticShape ? L("Automatic") : pet.view.shape.title
        shapeButton.toolTip = pet.automaticShape ? L("Switch to a random shape every 1–5 minutes") : L("Choose companion shape")
    }
    private func refreshRestPalette() {
        let title = pet.view.restPalette?.title ?? L("Default (follow system)")
        restPaletteButton.title = title
        restPaletteButton.setAccessibilityLabel(L("Resting colors: {0}", "\(title)"))
    }
    @objc private func showPalettePicker() { palettePicker.toggle(attachedTo: paletteButton, preferredEdge: .maxX) }
    @objc private func showRestPalettePicker() { restPalettePicker.toggle(attachedTo: restPaletteButton, preferredEdge: .maxX) }

    @objc private func recordShortcut() {
        if recorder != nil { finishRecording(); return }
        hotKey.suspended = true
        shortcutButton.title = L("Press a shortcut…")
        hint.stringValue = L("Include ⌘, ⌥, or ⌃. Esc cancels.")
        recorder = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self else { return false }
                if event.keyCode == 53 { self.finishRecording(); return true }
                guard let candidate = Shortcut.from(event) else {
                    self.hint.stringValue = L("Add a ⌘, ⌥, or ⌃ modifier.")
                    return true
                }
                do {
                    try self.hotKey.register(candidate)
                    self.onShortcut?(candidate)
                    self.finishRecording()
                    self.hint.stringValue = L("Saved. The shortcut works across apps.")
                } catch {
                    self.hint.stringValue = L(error.localizedDescription)
                }
                return true
            }
            return consumed ? nil : event
        }
    }

    func finishRecording() {
        if let recorder { NSEvent.removeMonitor(recorder) }
        recorder = nil
        hotKey.suspended = false
        refresh()
        hint.stringValue = L("Click, then press a new shortcut. Esc cancels.")
    }

    func windowWillClose(_ notification: Notification) {
        palettePicker.popover.close()
        restPalettePicker.popover.close()
        shapePopover.close()
        moodPopover.close()
        finishRecording()
    }
}
