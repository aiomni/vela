import AppKit
import VelaLocalization

/// A passive recognizer: direct touches are delivered here, not through sendEvent.
@MainActor
final class DirectTouchObserver: NSGestureRecognizer {
    var evidence: TouchEvidence?
    private var active: [any NSObjectProtocol] = []
    override func canPrevent(_ preventedGestureRecognizer: NSGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: NSGestureRecognizer) -> Bool { false }
    override func reset() { super.reset(); active.removeAll() }

    private func record(_ event: NSEvent, phase: NSTouch.Phase, key: String) {
        let touches = event.touches(matching: phase, in: view).filter { $0.type == .direct }
        guard !touches.isEmpty else { return }
        evidence?.increment("directTouchCallbacks")
        for touch in touches {
            let identity = touch.identity
            if phase == .began, !active.contains(where: { $0.isEqual(identity) }) { active.append(identity) }
            if phase == .ended || phase == .cancelled { active.removeAll { $0.isEqual(identity) } }
            let point = touch.location(in: view)
            evidence?.increment(key)
            evidence?.increment("\(key).\(evidence?.stage ?? "idle")")
            evidence?.values["pendingNativeContacts"] = active.count
            var sample: [String: Any] = ["kind": "directTouch", "phase": key, "x": point.x, "y": point.y]
            if let view, let window = view.window, let screen = window.screen, let evidence {
                let global = window.convertPoint(toScreen: view.convert(point, to: nil))
                let normalizedX = (global.x - screen.frame.minX) / screen.frame.width
                let normalizedY = (screen.frame.maxY - global.y) / screen.frame.height
                sample["displayNormalizedX"] = normalizedX
                sample["displayNormalizedY"] = normalizedY
                let match = evidence.lastReportedContacts.first {
                    abs($0.x - normalizedX) * screen.frame.width <= 20 &&
                    abs($0.y - normalizedY) * screen.frame.height <= 20 &&
                    ((phase == .ended || phase == .cancelled) ? !$0.touching : $0.touching)
                }
                if let match {
                    sample["candidateReportContactID"] = Int(match.id)
                    evidence.increment("matched.\(key).\(evidence.stage)")
                }
            }
            evidence?.sample(sample)
        }
        // Observe the entire lifecycle without winning recognition or delaying controls.
        if active.isEmpty { state = .failed }
    }
    override func touchesBegan(with event: NSEvent) {
        super.touchesBegan(with: event); record(event, phase: .began, key: "directTouchBegan")
    }
    override func touchesMoved(with event: NSEvent) {
        super.touchesMoved(with: event); record(event, phase: .moved, key: "directTouchMoved")
    }
    override func touchesEnded(with event: NSEvent) {
        super.touchesEnded(with: event); record(event, phase: .ended, key: "directTouchEnded")
    }
    override func touchesCancelled(with event: NSEvent) {
        super.touchesCancelled(with: event); record(event, phase: .cancelled, key: "directTouchCancelled")
    }
}

@MainActor
final class TouchReceiver: NSObject, NSGestureRecognizerDelegate {
    let window: NSWindow
    let scroll = VelaScrollView(frame: .zero)
    let surface = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 2200))
    let evidence: TouchEvidence
    private var directInMagnificationStream = false
    private var initialScrollY: CGFloat = 0
    private var scrollObservation: NSObjectProtocol?

    init(screen: NSScreen, evidence: TouchEvidence) {
        self.evidence = evidence
        let area = screen.visibleFrame
        window = NSWindow(contentRect: NSRect(x: area.midX - screen.frame.minX - 340,
                                               y: area.midY - screen.frame.minY - 250,
                                               width: 680, height: 500),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false, screen: screen)
        super.init()
        window.title = L("Vela Touch Lab")
        window.isReleasedWhenClosed = false
        guard let root = window.contentView else { return }
        let title = NSTextField(wrappingLabelWithString:
            L("Native touch test: keep this window focused and avoid physical input during the sequence."))
        title.frame = NSRect(x: 20, y: 440, width: 640, height: 44)
        root.addSubview(title)
        scroll.frame = NSRect(x: 20, y: 20, width: 640, height: 410)
        scroll.hasVerticalScroller = true
        scroll.documentView = surface
        if #available(macOS 27, *) {
            scroll.isTouchScrollingEnabled = true
            scroll.minimumNumberOfTouchesForScrolling = 1
            scroll.maximumNumberOfTouchesForScrolling = 1
        }
        root.addSubview(scroll)
        for row in 0..<40 {
            let label = NSTextField(labelWithString: L("Touch test row {0}", String(row + 1)))
            label.frame = NSRect(x: 24, y: CGFloat(row * 52), width: 580, height: 32)
            surface.addSubview(label)
        }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 900))
        scroll.reflectScrolledClipView(scroll.contentView)
        initialScrollY = scroll.contentView.bounds.origin.y
        scroll.contentView.postsBoundsChangedNotifications = true
        scrollObservation = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.recordScroll() }
            }
        let observer = DirectTouchObserver(target: nil, action: nil)
        observer.allowedTouchTypes = .direct
        observer.evidence = evidence
        // Root observes both standard control scrolling and document gestures.
        root.addGestureRecognizer(observer)
        let magnify = NSMagnificationGestureRecognizer(target: self, action: #selector(magnify(_:)))
        magnify.allowedTouchTypes = .direct
        magnify.delegate = self
        surface.addGestureRecognizer(magnify)
        let click = NSClickGestureRecognizer(target: self, action: #selector(click(_:)))
        click.allowedTouchTypes = .direct
        click.delegate = self
        surface.addGestureRecognizer(click)
        evidence.values["receiverConfigured"] = true
        evidence.values["receiverUsesDirectGestureRecognizer"] = true
        if #available(macOS 27, *) {
            evidence.values["standardTouchScrollingEnabled"] = scroll.isTouchScrollingEnabled
        } else {
            evidence.values["standardTouchScrollingEnabled"] = false
        }
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func pointOnDisplay(_ point: NSPoint, displayID: CGDirectDisplayID) throws -> NSPoint {
        guard let screen = window.screen,
              screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 == displayID else {
            throw NSError(domain: "VelaTouchLab.Display", code: 1)
        }
        let global = window.convertPoint(toScreen: scroll.convert(point, to: nil))
        // AppKit has bottom-left points. Reports use top-left normalized display space.
        let normalized = NSPoint(x: (global.x - screen.frame.minX) / screen.frame.width,
                                 y: (screen.frame.maxY - global.y) / screen.frame.height)
        guard (0...1).contains(normalized.x), (0...1).contains(normalized.y) else {
            throw NSError(domain: "VelaTouchLab.Display", code: 2)
        }
        return normalized
    }

    func safeToSend(displayID: CGDirectDisplayID, originalFrame: NSRect) -> Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return session?["CGSSessionScreenIsLocked"] as? Bool != true &&
            session?[kCGSessionOnConsoleKey as String] as? Bool == true &&
            NSApp.isActive && window.isKeyWindow && window.isVisible && !window.isMiniaturized &&
            window.frame == originalFrame &&
            window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 == displayID
    }

    func resetScrollBaseline() { initialScrollY = scroll.contentView.bounds.origin.y }
    private func recordScroll() {
        guard evidence.stage == "scroll" else { return }
        let delta = scroll.contentView.bounds.origin.y - initialScrollY
        evidence.sample(["kind": "nativeScrollOrigin", "deltaY": delta])
        if abs(delta) > 2 { evidence.values["scrollOriginChanged"] = true }
    }
    @objc private func magnify(_ recognizer: NSMagnificationGestureRecognizer) {
        evidence.increment("magnificationActions")
        evidence.sample(["kind": "magnification", "state": recognizer.state.rawValue,
                         "magnification": recognizer.magnification,
                         "directTouchStream": directInMagnificationStream])
        if evidence.stage == "pinch", directInMagnificationStream,
           abs(recognizer.magnification) > 0.01 {
            evidence.values["directPinchRecognized"] = true
        }
    }
    @objc private func click(_ recognizer: NSClickGestureRecognizer) {
        evidence.increment("clickActions")
    }
    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldReceive touch: NSTouch) -> Bool {
        if gestureRecognizer is NSMagnificationGestureRecognizer {
            directInMagnificationStream = touch.type == .direct
        }
        return touch.type == .direct
    }
    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer,
                           shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        // Pointer-only stream entry: never count trackpad magnify or mouse click as direct touch.
        if gestureRecognizer is NSMagnificationGestureRecognizer { directInMagnificationStream = false }
        return true
    }
    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: NSGestureRecognizer) -> Bool { true }
    func close() {
        if let scrollObservation { NotificationCenter.default.removeObserver(scrollObservation) }
        window.orderOut(nil)
    }
}
