import AppKit

/// Overlay hit targets stay native and full-sized while the visible thumb varies.
@MainActor
private final class VelaScroller: NSScroller {
    private var hoverArea: NSTrackingArea?
    private var hovered = false
    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag],
            owner: self, userInfo: nil)
        addTrackingArea(area); hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        hovered = true; needsDisplay = true
    }
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hovered = false; needsDisplay = true
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        // Leave the track transparent; AppKit owns overlay fading and tracking.
    }
    override func drawKnob() {
        guard isEnabled, knobProportion < 1 else { return }
        var knob = rect(for: .knob)
        guard !knob.isEmpty else { return }
        let expanded = hovered || hitPart == .knob
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ||
            effectiveAppearance.name == .accessibilityHighContrastAqua ||
            effectiveAppearance.name == .accessibilityHighContrastDarkAqua
        let width: CGFloat = expanded ? (contrast ? 8 : 7) : (contrast ? 4 : 3)
        if bounds.height > bounds.width {
            knob.origin.x = bounds.maxX - width - 3
            knob.size.width = width
        } else {
            knob.origin.y = bounds.minY + 3
            knob.size.height = width
        }
        let opacity: CGFloat = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? 1
            : contrast ? (expanded ? 0.88 : 0.6) : (expanded ? 0.62 : 0.25)
        NSColor.labelColor.withAlphaComponent(opacity).setFill()
        NSBezierPath(roundedRect: knob, xRadius: width / 2, yRadius: width / 2).fill()
    }
}

/// Shared by every app-owned scroll region, independently of system gutter style.
@MainActor
public final class VelaScrollView: NSScrollView {
    public override var scrollerStyle: NSScroller.Style {
        get { super.scrollerStyle }
        set { super.scrollerStyle = .overlay }
    }
    public override init(frame: NSRect) {
        super.init(frame: frame)
        let vertical = VelaScroller(frame: NSRect(x: 0, y: 0, width: 14, height: 64))
        let horizontal = VelaScroller(frame: NSRect(x: 0, y: 0, width: 64, height: 14))
        vertical.controlSize = .small; horizontal.controlSize = .small
        verticalScroller = vertical; horizontalScroller = horizontal
        scrollerStyle = .overlay
        autohidesScrollers = true
    }
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
