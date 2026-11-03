import VelaLocalization
import AppKit

@MainActor
private func pickerColor(hue: CGFloat, saturation: CGFloat, brightness: CGFloat) -> NSColor {
    let h = (hue == 1 ? 0 : hue) * 6
    let c = brightness * saturation
    let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
    let m = brightness - c
    let rgb: (CGFloat, CGFloat, CGFloat)
    switch Int(h) {
    case 0: rgb = (c, x, 0)
    case 1: rgb = (x, c, 0)
    case 2: rgb = (0, c, x)
    case 3: rgb = (0, x, c)
    case 4: rgb = (x, 0, c)
    default: rgb = (c, 0, x)
    }
    return NSColor(srgbRed: rgb.0 + m, green: rgb.1 + m, blue: rgb.2 + m, alpha: 1)
}

@MainActor
private final class HueSliderCell: NSSliderCell {
    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let colors = (0...6).map { NSColor(calibratedHue: CGFloat($0) / 6, saturation: 1, brightness: 1, alpha: 1) }
        NSGradient(colors: colors)!.draw(in: NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2), angle: 0)
    }
}

@MainActor
final class ColorPlane: NSView {
    var hue: CGFloat = 0 { didSet { needsDisplay = true } }
    var saturation: CGFloat = 1
    var brightness: CGFloat = 1
    var onChange: ((NSColor) -> Void)?
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let space = CGColorSpaceCreateDeviceRGB()
        let hueColor = pickerColor(hue: hue, saturation: 1, brightness: 1).cgColor
        let horizontal = CGGradient(colorsSpace: space, colors: [NSColor.white.cgColor, hueColor] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(horizontal, start: .zero, end: CGPoint(x: bounds.width, y: 0), options: [])
        let vertical = CGGradient(colorsSpace: space, colors: [NSColor.black.withAlphaComponent(0).cgColor, NSColor.black.cgColor] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(vertical, start: .zero, end: CGPoint(x: 0, y: bounds.height), options: [])
        let marker = NSBezierPath(ovalIn: NSRect(x: saturation * bounds.width - 5,
            y: (1 - brightness) * bounds.height - 5, width: 10, height: 10))
        NSColor.black.withAlphaComponent(0.65).setStroke()
        marker.lineWidth = 4
        marker.stroke()
        NSColor.white.setStroke()
        marker.lineWidth = 2
        marker.stroke()
    }
    override func mouseDown(with event: NSEvent) { select(event) }
    override func mouseDragged(with event: NSEvent) { select(event) }
    private func select(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        saturation = min(1, max(0, p.x / bounds.width))
        brightness = min(1, max(0, 1 - p.y / bounds.height))
        needsDisplay = true
        onChange?(pickerColor(hue: hue, saturation: saturation, brightness: brightness))
    }
}

@MainActor
final class PalettePickerController: NSViewController, NSPopoverDelegate {
    enum Target { case awake, resting }
    let popover = NSPopover()
    let plane = ColorPlane()
    let hueSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    let hexField = NSTextField()
    private let swatch = NSView()
    private var effectButtons: [NSButton] = []
    private var inkButtons: [NSButton] = []
    private let inkGrid = NSStackView()
    private let targetControl = NSSegmentedControl(labels: [L("Body"), L("Eyes")], trackingMode: .selectOne, target: nil, action: nil)
    private let modeControl = NSSegmentedControl(labels: PetColorMode.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let resetEyeButton = NSButton(title: L("Reset eye color"), target: nil, action: nil)
    private let resetRestButton = NSButton(title: L("Default (follow system)"), target: nil, action: nil)
    private var editingEye = false
    private let pet: PetController
    private let target: Target
    private var rootStack: NSStackView?
    var onChange: (() -> Void)?

    init(pet: PetController, target: Target = .awake) {
        self.pet = pet
        self.target = target
        super.init(nibName: nil, bundle: nil)
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    override func loadView() {
        let background = PopoverBackgroundView(frame: NSRect(x: 0, y: 0, width: 360,
            height: max(target == .resting ? 430 : 390,
                44 + PetPalette.selectable.count * 23 + (target == .resting ? 40 : 0))))
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.refreshAppearance()
        view = background
        let left = NSStackView()
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 7
        let effectsTitle = NSTextField(labelWithString: L("Effects"))
        effectsTitle.font = .boldSystemFont(ofSize: 12)
        left.addArrangedSubview(effectsTitle)
        if target == .resting {
            resetRestButton.target = self
            resetRestButton.action = #selector(resetRest)
            left.addArrangedSubview(resetRestButton)
        }
        for (index, palette) in PetPalette.selectable.enumerated() {
            let button = NSButton(radioButtonWithTitle: palette.title, target: self, action: #selector(effectSelected(_:)))
            button.tag = index
            effectButtons.append(button)
            left.addArrangedSubview(button)
        }
        let right = NSStackView()
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = 10
        let colorTitle = NSTextField(labelWithString: L("Color"))
        colorTitle.font = .boldSystemFont(ofSize: 12)
        right.addArrangedSubview(colorTitle)
        targetControl.selectedSegment = 0
        targetControl.target = self
        targetControl.action = #selector(targetChanged)
        right.addArrangedSubview(targetControl)
        inkGrid.orientation = .vertical
        inkGrid.spacing = 5
        for rowIndex in 0..<2 {
            let row = NSStackView()
            row.spacing = 5
            for column in 0..<6 {
                let index = rowIndex * 6 + column
                let palette = PetPalette.inkSelectable[index]
                let button = NSButton(title: "", target: self, action: #selector(inkSelected(_:)))
                button.tag = index
                button.isBordered = false
                button.wantsLayer = true
                button.layer?.cornerRadius = 13
                button.layer?.borderWidth = 1
                button.layer?.borderColor = NSColor.separatorColor.cgColor
                button.layer?.backgroundColor = (palette == .custom ? NSColor.systemOrange : palette.colors[0]).cgColor
                button.toolTip = palette.title
                button.setAccessibilityLabel(L("Color: {0}", "\(palette.title)"))
                button.widthAnchor.constraint(equalToConstant: 27).isActive = true
                button.heightAnchor.constraint(equalToConstant: 27).isActive = true
                inkButtons.append(button)
                row.addArrangedSubview(button)
            }
            inkGrid.addArrangedSubview(row)
        }
        right.addArrangedSubview(inkGrid)
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        right.addArrangedSubview(modeControl)
        plane.wantsLayer = true
        plane.layer?.cornerRadius = 6
        plane.layer?.masksToBounds = true
        plane.widthAnchor.constraint(equalToConstant: 220).isActive = true
        plane.heightAnchor.constraint(equalToConstant: 140).isActive = true
        plane.setAccessibilityElement(true)
        plane.setAccessibilityRole(.image)
        plane.setAccessibilityLabel(L("Color area: brighter at the top, more saturated to the right; hexadecimal input is also available"))
        plane.onChange = { [weak self] color in self?.selectColor(color) }
        right.addArrangedSubview(plane)
        hueSlider.target = self
        hueSlider.cell = HueSliderCell()
        hueSlider.minValue = 0
        hueSlider.maxValue = 1
        hueSlider.target = self
        hueSlider.action = #selector(hueChanged)
        hueSlider.isContinuous = true
        hueSlider.setAccessibilityLabel(L("Hue"))
        hueSlider.widthAnchor.constraint(equalToConstant: 220).isActive = true
        right.addArrangedSubview(hueSlider)
        swatch.wantsLayer = true
        swatch.layer?.cornerRadius = 5
        swatch.widthAnchor.constraint(equalToConstant: 28).isActive = true
        swatch.heightAnchor.constraint(equalToConstant: 24).isActive = true
        hexField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        hexField.widthAnchor.constraint(equalToConstant: 100).isActive = true
        hexField.target = self
        hexField.action = #selector(hexChanged)
        hexField.setAccessibilityLabel(L("Hex color"))
        let values = NSStackView(views: [swatch, hexField])
        values.spacing = 10
        right.addArrangedSubview(values)
        resetEyeButton.target = self
        resetEyeButton.action = #selector(resetEye)
        resetEyeButton.bezelStyle = .recessed
        right.addArrangedSubview(resetEyeButton)
        let line = NSBox()
        line.boxType = .separator
        line.widthAnchor.constraint(equalToConstant: 1).isActive = true
        line.heightAnchor.constraint(equalToConstant: 330).isActive = true
        let root = NSStackView(views: [left, line, right])
        rootStack = root
        root.alignment = .top
        root.spacing = 8
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            root.topAnchor.constraint(equalTo: view.topAnchor, constant: 12)
        ])
        background.onAppearanceChange = { [weak self] in self?.refresh() }
        refresh()
    }

    func toggle(attachedTo button: NSView, preferredEdge: NSRectEdge = .minY) {
        if popover.isShown { popover.close(); return }
        _ = view
        refresh()
        popover.contentViewController = self
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: preferredEdge)
    }
    func popoverDidClose(_ notification: Notification) { popover.contentViewController = nil }

    func refresh() {
        LocalizationUI.refresh(view)
        if let rootStack {
            let fitting = rootStack.fittingSize
            let size = NSSize(width: max(360, ceil(fitting.width) + 24),
                              height: max(target == .resting ? 430 : 390, ceil(fitting.height) + 24))
            view.setFrameSize(size)
            popover.contentSize = size
        }
        let selectedPalette = target == .awake ? pet.view.palette : pet.view.restPalette
        let customColor = target == .awake ? pet.view.customColor : pet.view.restColor ?? .systemOrange
        let colorMode = target == .awake ? pet.view.colorMode : pet.view.restColorMode
        for button in effectButtons { button.state = PetPalette.selectable[button.tag] == selectedPalette ? .on : .off }
        for button in inkButtons {
            let palette = PetPalette.inkSelectable[button.tag]
            button.layer?.borderWidth = selectedPalette == palette ? 3 : 1
            button.layer?.borderColor = selectedPalette == palette ? NSColor.controlAccentColor.cgColor : NSColor.separatorColor.cgColor
        }
        inkButtons.last?.layer?.backgroundColor = customColor.cgColor
        inkGrid.isHidden = editingEye
        modeControl.isHidden = editingEye
        resetEyeButton.isHidden = !editingEye
        targetControl.isHidden = target == .resting
        modeControl.selectedSegment = PetColorMode.allCases.firstIndex(of: colorMode)!
        let bodyColor = selectedPalette == .custom ? customColor : selectedPalette?.colors[0] ?? .labelColor
        let color = (editingEye ? pet.view.eyeColor ?? .windowBackgroundColor : bodyColor).usingColorSpace(.sRGB)!
        hueSlider.doubleValue = Double(color.hueComponent)
        plane.hue = color.hueComponent
        plane.saturation = color.saturationComponent
        plane.brightness = color.brightnessComponent
        plane.needsDisplay = true
        swatch.layer?.backgroundColor = color.cgColor
        hexField.stringValue = String(format: "#%02X%02X%02X", Int((color.redComponent * 255).rounded()),
            Int((color.greenComponent * 255).rounded()), Int((color.blueComponent * 255).rounded()))
    }

    @objc private func effectSelected(_ sender: NSButton) {
        if target == .awake { pet.setPalette(PetPalette.selectable[sender.tag]) }
        else { pet.setRestPalette(PetPalette.selectable[sender.tag]) }
        refresh()
        onChange?()
    }
    @objc private func targetChanged() { editingEye = targetControl.selectedSegment == 1; refresh() }
    @objc private func inkSelected(_ sender: NSButton) {
        if target == .awake { pet.setPalette(PetPalette.inkSelectable[sender.tag]) }
        else { pet.setRestPalette(PetPalette.inkSelectable[sender.tag]) }
        refresh()
        onChange?()
    }
    @objc private func modeChanged() {
        if target == .awake { pet.setColorMode(PetColorMode.allCases[modeControl.selectedSegment]) }
        else { pet.setRestColorMode(PetColorMode.allCases[modeControl.selectedSegment]) }
        refresh()
        onChange?()
    }
    @objc private func resetEye() { pet.setEyeColor(nil); refresh(); onChange?() }
    @objc private func resetRest() { pet.setRestColor(nil); refresh(); onChange?() }
    func selectColor(_ color: NSColor) {
        if editingEye { pet.setEyeColor(color) }
        else if target == .awake { pet.setCustomColor(color) }
        else { pet.setRestColor(color) }
        refresh()
        onChange?()
    }
    @objc private func hueChanged() {
        selectColor(pickerColor(hue: CGFloat(hueSlider.doubleValue), saturation: plane.saturation,
            brightness: plane.brightness))
    }
    @objc private func hexChanged() {
        let value = hexField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        guard value.count == 6, let rgb = UInt32(value, radix: 16) else { NSSound.beep(); refresh(); return }
        selectColor(NSColor(srgbRed: Double((rgb >> 16) & 255) / 255,
            green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255, alpha: 1))
    }
}
