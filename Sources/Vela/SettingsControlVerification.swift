import AppKit
import VelaLocalization

@MainActor
private final class SwitchActionProbe: NSObject {
    var actions = 0
    @objc func changed(_ sender: NSSwitch) { actions += 1 }
}

/// Isolated UI checks: no visible windows, hotkeys, power assertions, or remote services.
@MainActor
func verifySettingsControls() {
    let toggle = SettingsStyle.compactSwitch()
    let regular = NSSwitch()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.contentView!.addSubview(toggle)
    window.contentView!.addSubview(regular)
    window.contentView!.layoutSubtreeIfNeeded()
    let size = toggle.intrinsicContentSize
    precondition(toggle.controlSize == .mini)
    precondition(size.width < regular.intrinsicContentSize.width && size.height < regular.intrinsicContentSize.height)
    let probe = SwitchActionProbe()
    toggle.target = probe; toggle.action = #selector(SwitchActionProbe.changed(_:))
    toggle.performClick(nil)
    precondition(toggle.state == .on && probe.actions == 1)
    toggle.performClick(nil)
    precondition(toggle.state == .off && probe.actions == 2)
    print("PASS: native compact switches use \(Int(size.width))x\(Int(size.height)) pt and preserve state/action behavior")
    let scrollReview = VelaScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
    scrollReview.hasVerticalScroller = true
    scrollReview.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 1000))
    scrollReview.scrollerStyle = .legacy
    precondition(scrollReview.scrollerStyle == .overlay)
    scrollReview.layoutSubtreeIfNeeded()
    let scroller = scrollReview.verticalScroller!
    scroller.frame = NSRect(x: 0, y: 0, width: 14, height: 200)
    scroller.isEnabled = true; scroller.knobProportion = 0.25; scroller.doubleValue = 0.4
    scroller.checkSpaceForParts()
    let viewport = scrollReview.contentView.bounds.size
    let enter = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
    let leave = NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
    func thumbMetrics() -> (width: Int, alpha: CGFloat) {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 28, pixelsHigh: 400,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.current = context
        context.cgContext.clear(CGRect(x: 0, y: 0, width: 28, height: 400))
        context.cgContext.scaleBy(x: 2, y: 2)
        scroller.effectiveAppearance.performAsCurrentDrawingAppearance { scroller.drawKnob() }
        context.flushGraphics(); NSGraphicsContext.restoreGraphicsState()
        var columns = Set<Int>(), alpha: CGFloat = 0
        for y in 0..<400 { for x in 0..<28 {
            let value = bitmap.colorAt(x: x, y: y)!.alphaComponent
            if value > 0.05 { columns.insert(x) }
            alpha = max(alpha, value)
        }}
        return (columns.count, alpha)
    }
    for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
        scroller.appearance = NSAppearance(named: appearance)
        scroller.mouseExited(with: leave)
        let rest = thumbMetrics()
        scroller.mouseEntered(with: enter)
        let hover = thumbMetrics()
        precondition(rest.width > 0 && hover.width > rest.width)
        precondition(hover.alpha >= rest.alpha)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            precondition(rest.alpha < 1 && hover.alpha > rest.alpha + 0.1)
        }
        precondition(scrollReview.contentView.bounds.size == viewport && scroller.doubleValue == 0.4)
    }
    print("PASS: thin translucent overlay thumbs expand and strengthen on hover without changing scroll values or viewport")

    let suite = "Vela.controls.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let pet = try! PetController(defaults: defaults)
    defer { pet.hide(); defaults.removePersistentDomain(forName: suite) }
    pet.resize(to: 24)
    pet.container.setControlsVisible(true)
    precondition(pet.blackoutButton.image != nil && !pet.blackoutButton.helpText.isEmpty)
    precondition(pet.modeButton.frame.maxX < pet.blackoutButton.frame.minX &&
                 pet.blackoutButton.frame.maxX < pet.settingsButton.frame.minX &&
                 pet.controls.frame.maxX <= pet.container.bounds.maxX)
    var requested = false
    pet.onBlackout = { requested = true }
    pet.blackoutButton.performClick(nil)
    precondition(requested && !pet.container.controlsVisible)
    pet.setBlackout(active: false, starting: true)
    precondition(!pet.blackoutButton.isEnabled)
    pet.setBlackout(active: true)
    precondition(!pet.blackoutButton.isEnabled)
    pet.setBlackout(active: false)
    precondition(pet.blackoutButton.isEnabled)
    print("PASS: companion blackout action, help, layout, and busy/active states")
    for (elapsed, expected) in [(0.0, 5), (0.999, 5), (1.0, 4), (2.0, 3), (3.0, 2), (4.0, 1), (4.999, 1)] {
        precondition(BlackoutCountdownFrame(elapsed: elapsed).number == expected)
    }
    precondition(BlackoutCountdownFrame(elapsed: 5).number == nil)
    let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .privateState), virtualKey: 53, keyDown: true)!
    event.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
    precondition(BlackoutCountdown.isCancelInput(event))
    event.setIntegerValueField(.keyboardEventKeycode, value: 0)
    precondition(!BlackoutCountdown.isCancelInput(event))
    event.setIntegerValueField(.keyboardEventKeycode, value: 53)
    event.setIntegerValueField(.eventSourceUnixProcessID, value: 123)
    precondition(!BlackoutCountdown.isCancelInput(event))
    let countdown = BlackoutCountdownView(frame: NSRect(x: 0, y: 0, width: 960, height: 640))
    countdown.elapsed = 2.3
    let image = countdown.bitmapImageRepForCachingDisplay(in: countdown.bounds)!
    countdown.cacheDisplay(in: countdown.bounds, to: image)
    precondition(!countdown.isOpaque &&
                 abs(image.colorAt(x: 0, y: 0)!.alphaComponent - BlackoutCountdownFrame(elapsed: 2.3).backgroundOpacity) < 0.02)
    if let path = ProcessInfo.processInfo.environment["VELA_COUNTDOWN_PREVIEW"] {
        try! image.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    }
    for (elapsed, opacity) in [(0.0, 0.0), (2.5, 0.5), (5.0, 1.0), (6.0, 1.0)] {
        countdown.elapsed = elapsed
        countdown.cacheDisplay(in: countdown.bounds, to: image)
        precondition(abs(image.colorAt(x: 0, y: 0)!.alphaComponent - opacity) < 0.02)
        if elapsed >= 5 {
            let center = image.colorAt(x: image.pixelsWide / 2, y: image.pixelsHigh / 2)!
            precondition(center.redComponent < 0.01 && center.greenComponent < 0.01 && center.blueComponent < 0.01)
            precondition(center.alphaComponent > 0.99)
        }
    }
    print("PASS: five-second countdown, physical Escape cancellation, and transparent-to-black background")
}
