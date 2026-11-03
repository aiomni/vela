import AppKit

@MainActor
final class PopoverBackgroundView: NSView {
    var onAppearanceChange: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }

    func refreshAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
        onAppearanceChange?()
    }
}

@MainActor
final class AppearanceTileView: NSView {
    var isTileVisible = false { didSet { refreshAppearance() } }
    var isSelected = false { didSet { refreshAppearance() } }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }

    func refreshAppearance() {
        guard let layer else { return }
        if !isTileVisible {
            layer.backgroundColor = nil
            layer.borderWidth = 0
            return
        }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = (isSelected
                ? NSColor.controlAccentColor.withAlphaComponent(0.16)
                : NSColor.controlBackgroundColor).cgColor
            layer.borderWidth = isSelected ? 1.5 : 1
            layer.borderColor = (isSelected
                ? NSColor.controlAccentColor
                : NSColor.separatorColor.withAlphaComponent(0.22)).cgColor
        }
    }
}
