import AppKit
import VelaLocalization

/// Settings content uses opaque semantic surfaces. Glass belongs to navigation.
@MainActor
final class SettingsSurface: NSView {
    var isCard = true
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 12
        refreshColors()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refreshColors() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); refreshColors() }
    func refreshColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let base = NSColor.textBackgroundColor
            let highContrast = effectiveAppearance.name == .accessibilityHighContrastAqua ||
                effectiveAppearance.name == .accessibilityHighContrastDarkAqua ||
                NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            layer?.backgroundColor = (isCard ? base.blended(withFraction: 0.035, of: .labelColor)! : base).cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
            layer?.borderWidth = isCard && highContrast ? 1 : 0

        }
    }
}

@MainActor
enum SettingsStyle {
    static func compactSwitch() -> NSSwitch {
        let control = NSSwitch()
        control.controlSize = .mini
        return control
    }

    static func note(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    static func row(_ title: String, _ control: NSView, subtitle: String? = nil, detail: NSView? = nil,
                    alignment: NSLayoutConstraint.Attribute = .centerY) -> NSView {
        let label = NSTextField(wrappingLabelWithString: title)
        label.font = .systemFont(ofSize: 13)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let labels = NSStackView(views: [label])
        labels.orientation = .vertical; labels.alignment = .leading; labels.spacing = 3
        if let subtitle { labels.addArrangedSubview(note(subtitle)) }
        if let detail {
            labels.addArrangedSubview(detail)
            detail.widthAnchor.constraint(equalTo: labels.widthAnchor).isActive = true
        }
        let stack = NSStackView(views: [labels, NSView(), control])
        stack.alignment = alignment; stack.spacing = 14
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        let container = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 9),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -9),
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 38),
            labels.widthAnchor.constraint(greaterThanOrEqualToConstant: title.isEmpty ? 0 : 100)
        ])
        return container
    }

    static func block(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 9
        let container = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 9),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -9)
        ])
        for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return container
    }

    static func group(_ rows: [NSView]) -> NSView {
        let surface = SettingsSurface()
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            stack.topAnchor.constraint(equalTo: surface.topAnchor),
            stack.bottomAnchor.constraint(equalTo: surface.bottomAnchor)
        ])
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let inset = NSView()
                let line = NSBox(); line.boxType = .separator
                line.translatesAutoresizingMaskIntoConstraints = false; inset.addSubview(line)
                NSLayoutConstraint.activate([
                    inset.heightAnchor.constraint(equalToConstant: 1),
                    line.leadingAnchor.constraint(equalTo: inset.leadingAnchor, constant: 14),
                    line.trailingAnchor.constraint(equalTo: inset.trailingAnchor, constant: -14),
                    line.centerYAnchor.constraint(equalTo: inset.centerYAnchor)
                ])
                stack.addArrangedSubview(inset)
                inset.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return surface
    }

    static func heading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    static func icon(_ page: SettingsPage, size: CGFloat) -> NSView {
        let tile = NSView(); tile.wantsLayer = true
        tile.layer?.cornerRadius = size * 0.23
        tile.layer?.backgroundColor = page.color.cgColor
        let image = NSImageView()
        image.image = NSImage(systemSymbolName: page.symbol, accessibilityDescription: nil)
        image.symbolConfiguration = .init(pointSize: size * 0.6, weight: .medium)
        image.contentTintColor = .white
        image.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(image)
        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: size), tile.heightAnchor.constraint(equalToConstant: size),
            image.centerXAnchor.constraint(equalTo: tile.centerXAnchor), image.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: size * 0.75), image.heightAnchor.constraint(equalToConstant: size * 0.75)
        ])
        tile.setAccessibilityElement(false)
        return tile
    }


}

enum SettingsPage: String, CaseIterable {
    case general, keepAwake, agent, appearance, remote
    var title: String {
        switch self {
        case .general: L("General")
        case .keepAwake: L("Awake")
        case .agent: L("Watch")
        case .appearance: L("Appearance")
        case .remote: L("Remote")
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .keepAwake: "sun.max.fill"
        case .agent: "cpu.fill"
        case .appearance: "paintpalette.fill"
        case .remote: "network"
        }
    }
    var color: NSColor {
        switch self {
        case .general: .systemGray
        case .keepAwake: .systemOrange
        case .agent: .systemPurple
        case .appearance: .systemPink
        case .remote: .systemBlue
        }
    }
}
