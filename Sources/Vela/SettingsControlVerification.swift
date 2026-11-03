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
}
