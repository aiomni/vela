import AppKit
import VelaLocalization

enum AppAppearance: String, CaseIterable {
    case light, dark, automatic
    static let preferenceKey = "velaAppearance"
    var title: String {
        switch self { case .light: L("Light"); case .dark: L("Dark"); case .automatic: L("Auto") }
    }
    static func load(from defaults: UserDefaults) -> Self {
        Self(rawValue: defaults.string(forKey: preferenceKey) ?? "") ?? .automatic
    }
    @MainActor func apply() {
        switch self {
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .automatic: NSApp.appearance = nil
        }
    }
}

@MainActor
private final class AppearancePreferenceButton: NSButton {
    var onMove: ((Int) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 123 { onMove?(-1) }
        else if event.keyCode == 124 { onMove?(1) }
        else { super.keyDown(with: event) }
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard state == .on, let cell = cell as? NSButtonCell else { return }
        let rect = cell.imageRect(forBounds: bounds).insetBy(dx: -3, dy: -3)
        NSColor.controlAccentColor.setStroke()
        let ring = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        ring.lineWidth = 3
        ring.stroke()
    }
}

@MainActor
final class AppearancePreferencesController: NSObject {
    let view = NSStackView()
    private(set) var buttons: [NSButton] = []
    private let defaults: UserDefaults
    var onChange: (() -> Void)?

    init(defaults: UserDefaults) {
        self.defaults = defaults
        super.init()
        view.orientation = .horizontal; view.spacing = 10; view.alignment = .top
        for (index, mode) in AppAppearance.allCases.enumerated() {
            let button = AppearancePreferenceButton(title: mode.title, image: Self.thumbnail(mode), target: self, action: #selector(selectAppearance(_:)))
            button.tag = index; button.setButtonType(.radio)
            button.image = Self.thumbnail(mode); button.alternateImage = nil
            button.onMove = { [weak self] direction in
                guard let self else { return }
                let next = buttons[(index + direction + buttons.count) % buttons.count]
                next.window?.makeFirstResponder(next)
                selectAppearance(next)
            }
            button.isBordered = false; button.imagePosition = .imageAbove
            button.imageScaling = .scaleNone
            button.font = .systemFont(ofSize: 12)
            button.contentTintColor = .labelColor
            button.cell?.alignment = .center
            (button.cell as? NSButtonCell)?.showsStateBy = []
            button.setAccessibilityLabel(mode.title)
            button.widthAnchor.constraint(equalToConstant: 90).isActive = true
            button.heightAnchor.constraint(equalToConstant: 84).isActive = true
            buttons.append(button); view.addArrangedSubview(button)
        }
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.radioGroup)
        view.setAccessibilityLabel(L("Appearance"))
        view.setAccessibilityChildren(buttons)
        refresh()
    }

    func refresh() {
        let selected = AppAppearance.load(from: defaults)
        for (button, mode) in zip(buttons, AppAppearance.allCases) {
            button.title = mode.title; button.setAccessibilityLabel(mode.title)
            button.state = mode == selected ? .on : .off
            button.needsDisplay = true
        }
    }
    @objc private func selectAppearance(_ button: NSButton) {
        guard AppAppearance.allCases.indices.contains(button.tag) else { return }
        let selected = AppAppearance.allCases[button.tag]
        defaults.set(selected.rawValue, forKey: AppAppearance.preferenceKey)
        selected.apply(); refresh(); onChange?()
    }
    func reset() {
        defaults.removeObject(forKey: AppAppearance.preferenceKey)
        AppAppearance.automatic.apply(); refresh(); onChange?()
    }

    /// Original vector thumbnails; no downloaded wallpaper or image assets.
    private static func thumbnail(_ mode: AppAppearance) -> NSImage {
        NSImage(size: NSSize(width: 82, height: 54), flipped: false) { _ in
            func draw(_ dark: Bool, clip: NSRect) {
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: clip).addClip()
                let bounds = NSRect(x: 0, y: 0, width: 82, height: 54)
                let surface = NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5)
                surface.addClip()
                NSGradient(starting: dark ? NSColor(srgbRed: 0.08, green: 0.09, blue: 0.28, alpha: 1)
                                           : NSColor(srgbRed: 0.65, green: 0.87, blue: 1, alpha: 1),
                           ending: dark ? NSColor(srgbRed: 0.08, green: 0.22, blue: 0.62, alpha: 1)
                                        : NSColor(srgbRed: 0.08, green: 0.43, blue: 0.86, alpha: 1))!.draw(in: surface, angle: 35)
                let sweep = NSBezierPath()
                sweep.move(to: NSPoint(x: -5, y: 4)); sweep.curve(to: NSPoint(x: 88, y: 48),
                    controlPoint1: NSPoint(x: 36, y: 58), controlPoint2: NSPoint(x: 32, y: -10))
                sweep.lineWidth = 8
                NSColor.white.withAlphaComponent(dark ? 0.10 : 0.22).setStroke(); sweep.stroke()
                let window = NSRect(x: 11, y: 7, width: 61, height: 34)
                (dark ? NSColor(white: 0.15, alpha: 1) : NSColor(white: 0.98, alpha: 1)).setFill()
                NSBezierPath(roundedRect: window, xRadius: 4, yRadius: 4).fill()
                (dark ? NSColor(white: 0.22, alpha: 1) : NSColor(white: 0.89, alpha: 1)).setFill()
                NSBezierPath(roundedRect: NSRect(x: 11, y: 29, width: 61, height: 12), xRadius: 4, yRadius: 4).fill()
                for (index, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                    color.setFill()
                    NSBezierPath(ovalIn: NSRect(x: 16 + index * 7, y: 33, width: 4, height: 4)).fill()
                }
                NSColor.systemBlue.withAlphaComponent(0.85).setFill()
                NSBezierPath(roundedRect: NSRect(x: 16, y: 17, width: 21, height: 6), xRadius: 2, yRadius: 2).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            if mode == .automatic {
                draw(false, clip: NSRect(x: 0, y: 0, width: 41, height: 54))
                draw(true, clip: NSRect(x: 41, y: 0, width: 41, height: 54))
            } else { draw(mode == .dark, clip: NSRect(x: 0, y: 0, width: 82, height: 54)) }
            return true
        }
    }
}
