import AppKit
import CoreText
import RemoteCore
import VelaLocalization

struct BlackoutCountdownFrame {
    static let duration: TimeInterval = 5
    let elapsed: TimeInterval

    var number: Int? {
        guard elapsed < Self.duration else { return nil }
        return Int(Self.duration) - Int(max(0, elapsed))
    }

    var phase: CGFloat { CGFloat(max(0, elapsed).truncatingRemainder(dividingBy: 1)) }

    var backgroundOpacity: CGFloat {
        let progress = CGFloat(min(1, max(0, elapsed / Self.duration)))
        return progress * progress * (3 - 2 * progress)
    }
}

@MainActor
final class BlackoutCountdownView: NSView {
    var elapsed: TimeInterval = 0 {
        didSet {
            guard elapsed != oldValue else { return }
            if BlackoutCountdownFrame(elapsed: elapsed).number != BlackoutCountdownFrame(elapsed: oldValue).number {
                setAccessibilityValue(BlackoutCountdownFrame(elapsed: elapsed).number.map(String.init) ?? "")
            }
            needsDisplay = true
        }
    }

    override var isOpaque: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(L("Display blackout countdown"))
        setAccessibilityValue("5")
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(bounds)
        let frame = BlackoutCountdownFrame(elapsed: elapsed)
        context.setFillColor(NSColor.black.withAlphaComponent(frame.backgroundOpacity).cgColor)
        context.fill(bounds)
        guard let number = frame.number else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = min(bounds.width, bounds.height) * 0.28
        let ice = NSColor(srgbRed: 0.64, green: 0.84, blue: 1, alpha: 1)

        context.saveGState()
        context.translateBy(x: center.x, y: center.y)
        for scale: CGFloat in [0.94, 1, 1.07] {
            context.setLineWidth(scale == 1 ? 1 : 0.5)
            context.setStrokeColor(ice.withAlphaComponent(scale == 1 ? 0.36 : 0.15).cgColor)
            context.strokeEllipse(in: CGRect(x: -radius * scale, y: -radius * scale,
                                            width: radius * scale * 2, height: radius * scale * 2))
        }
        context.saveGState()
        context.rotate(by: reduceMotion ? 0 : -CGFloat(elapsed) * 0.12)
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [1, radius * 0.13])
        context.setStrokeColor(ice.withAlphaComponent(0.42).cgColor)
        context.strokeEllipse(in: CGRect(x: -radius * 1.13, y: -radius * 1.13,
                                        width: radius * 2.26, height: radius * 2.26))
        context.restoreGState()
        if !reduceMotion {
            context.setLineWidth(2)
            context.setStrokeColor(ice.withAlphaComponent(0.8).cgColor)
            context.setShadow(offset: .zero, blur: 12, color: ice.withAlphaComponent(0.65).cgColor)
            context.addArc(center: .zero, radius: radius, startAngle: .pi / 2,
                           endAngle: .pi / 2 - 2 * .pi * (1 - frame.phase), clockwise: true)
            context.strokePath()
            context.setShadow(offset: .zero, blur: 0)
            let pulse = radius * (0.85 + frame.phase * 0.42)
            context.setLineWidth(0.8)
            context.setStrokeColor(ice.withAlphaComponent(0.22 * (1 - frame.phase)).cgColor)
            context.strokeEllipse(in: CGRect(x: -pulse, y: -pulse, width: pulse * 2, height: pulse * 2))
        }
        context.restoreGState()

        let font = NSFontManager.shared.convert(NSFont.systemFont(ofSize: radius * 1.8, weight: .black),
                                               toHaveTrait: .condensedFontMask)
        var character = String(number).utf16.first!
        var glyph = CGGlyph()
        guard CTFontGetGlyphsForCharacters(font as CTFont, &character, &glyph, 1),
              let outline = CTFontCreatePathForGlyph(font as CTFont, glyph, nil) else { return }
        let scale: CGFloat = reduceMotion ? 1 : 1 + 0.18 * pow(1 - min(1, frame.phase * 2.5), 3)
        context.saveGState()
        context.translateBy(x: center.x, y: center.y + radius * 0.02)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -outline.boundingBoxOfPath.midX, y: -outline.boundingBoxOfPath.midY)
        context.setShadow(offset: .zero, blur: 28, color: ice.withAlphaComponent(0.7).cgColor)
        context.setFillColor(ice.withAlphaComponent(0.12).cgColor)
        context.addPath(outline)
        context.fillPath()
        context.setShadow(offset: .zero, blur: 0)
        context.saveGState()
        context.addPath(outline)
        context.clip()
        let numeral = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: [ice.withAlphaComponent(0.30).cgColor,
                                          NSColor.white.withAlphaComponent(0.92).cgColor,
                                          ice.withAlphaComponent(0.55).cgColor] as CFArray,
                                 locations: [0, 0.55, 1])!
        context.drawLinearGradient(numeral, start: CGPoint(x: 0, y: outline.boundingBoxOfPath.minY),
                                   end: CGPoint(x: 0, y: outline.boundingBoxOfPath.maxY), options: [])
        context.restoreGState()
        context.setLineWidth(0.75)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.65).cgColor)
        context.addPath(outline)
        context.strokePath()
        context.restoreGState()

        let hint = L("Esc to cancel")
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: max(12, min(16, radius * 0.06)), weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.72),
            .kern: 1.5
        ]
        let size = (hint as NSString).size(withAttributes: attributes)
        (hint as NSString).draw(at: NSPoint(x: center.x - size.width / 2, y: center.y - radius * 1.35 - size.height),
                                withAttributes: attributes)
    }
}

@MainActor
final class BlackoutCountdown {
    private var windows: [(displayID: UInt32, panel: NSPanel)] = []
    private var timer: Timer?
    private var screenObserver: NSObjectProtocol?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var began: TimeInterval = 0
    private var monitoringFailed = false
    private var cancelled = false
    private var onCancel: (() -> Void)?

    nonisolated static func isCancelInput(_ event: CGEvent) -> Bool {
        event.type == .keyDown && event.getIntegerValueField(.keyboardEventKeycode) == 53 &&
            PhysicalInputMonitor.isPhysical(event) &&
            event.getIntegerValueField(.eventSourceUserData) != 0x41575045545243
    }

    func start(onCancel: @escaping () -> Void) throws {
        self.onCancel = onCancel
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .listenOnly,
                                          eventsOfInterest: 1 << CGEventType.keyDown.rawValue,
                                          callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let countdown = Unmanaged<BlackoutCountdown>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated {
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    countdown.monitoringFailed = true
                    countdown.onCancel?()
                } else if BlackoutCountdown.isCancelInput(event) {
                    countdown.cancelled = true
                    countdown.onCancel?()
                }
            }
            // The countdown observes Escape. All keyboard and pointer events keep flowing.
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            throw RemoteError.message("Local input recovery monitoring could not start. Check Input Monitoring access.")
        }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        began = ProcessInfo.processInfo.systemUptime
        for screen in NSScreen.screens {
            guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let panel = PetPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.ignoresMouseEvents = true
            panel.animationBehavior = .none
            panel.title = L("Display blackout countdown")
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.contentView = BlackoutCountdownView(frame: NSRect(origin: .zero, size: screen.frame.size))
            panel.contentView?.autoresizingMask = [.width, .height]
            panel.orderFrontRegardless()
            windows.append((displayID.uint32Value, panel))
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func update() {
        let elapsed = ProcessInfo.processInfo.systemUptime - began
        if cancelled || monitoringFailed {
            dismissWindows()
            return
        }
        let frames = Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap { screen -> (UInt32, NSRect)? in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return (id.uint32Value, screen.frame)
        })
        for (displayID, panel) in windows {
            // Preparing virtual displays can move windows. Keep each cover on
            // its original output until the physical display transaction finishes.
            if let frame = frames[displayID], panel.frame != frame { panel.setFrame(frame, display: true) }
            (panel.contentView as? BlackoutCountdownView)?.elapsed = min(elapsed, BlackoutCountdownFrame.duration)
        }
    }

    func waitForCompletion() async throws {
        while true {
            try Task.checkCancellation()
            if cancelled { throw CancellationError() }
            guard !monitoringFailed, let tap, CGEvent.tapIsEnabled(tap: tap) else {
                throw RemoteError.message("Local input recovery monitoring could not start. Check Input Monitoring access.")
            }
            if ProcessInfo.processInfo.systemUptime - began >= BlackoutCountdownFrame.duration {
                update()
                for (_, panel) in windows { panel.displayIfNeeded() }
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func dismissWindows() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        timer?.invalidate()
        timer = nil
        for (_, panel) in windows { panel.close() }
        windows.removeAll()
    }

    func stop() {
        dismissWindows()
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
        onCancel = nil
    }
}
