import VelaLocalization
import AppKit

@MainActor
final class PetSizeProgressBar: NSControl {
    var size: Double = 48 { didSet { synchronize() } }
    var onChange: ((Double) -> Void)?

    private let stops: [(position: Double, size: Double)] = [
        (0, 24), (0.5, 96), (0.75, 256), (1, 512)
    ]
    let native = SettingsSlider()
    private let valueLabel = NSTextField(labelWithString: "")
    override var acceptsFirstResponder: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        native.translatesAutoresizingMaskIntoConstraints = false
        addSubview(native)
        native.setMarks([(0, "24"), (0.5, "96"), (0.75, "256"), (1, "512")])
        native.slider.setAccessibilityLabel(L("Companion size"))
        native.onChange = { [weak self] position in
            guard let self else { return }
            let next = self.size(at: position)
            guard next != self.size else { return }
            self.size = next; self.onChange?(next)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityChildren([native.slider])
        let sizeLabel = NSTextField(labelWithString: L("Companion size"))
        sizeLabel.font = .systemFont(ofSize: 13)
        sizeLabel.translatesAutoresizingMaskIntoConstraints = false; addSubview(sizeLabel)
        NSLayoutConstraint.activate([
            sizeLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            sizeLabel.topAnchor.constraint(equalTo: topAnchor)
        ])
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.translatesAutoresizingMaskIntoConstraints = false; addSubview(valueLabel)
        NSLayoutConstraint.activate([
            valueLabel.topAnchor.constraint(equalTo: topAnchor),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            native.topAnchor.constraint(equalTo: valueLabel.bottomAnchor, constant: 2)
        ])
        NSLayoutConstraint.activate([
            native.leadingAnchor.constraint(equalTo: leadingAnchor),
            native.trailingAnchor.constraint(equalTo: trailingAnchor),
            native.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        synchronize()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func synchronize() {
        native.slider.doubleValue = position(for: size)
        valueLabel.stringValue = "\(Int(size)) pt"
    }

    func position(for size: Double) -> Double {
        let size = size.isFinite ? min(512, max(24, size)) : 48
        for index in 1..<stops.count where size <= stops[index].size {
            let previous = stops[index - 1], next = stops[index]
            return previous.position + (size - previous.size) / (next.size - previous.size)
                * (next.position - previous.position)
        }
        return 1
    }

    func size(at position: Double) -> Double {
        let position = min(1, max(0, position))
        for index in 1..<stops.count where position <= stops[index].position {
            let previous = stops[index - 1], next = stops[index]
            return (previous.size + (position - previous.position) / (next.position - previous.position)
                * (next.size - previous.size)).rounded()
        }
        return 512
    }

    override func keyDown(with event: NSEvent) {
        let step: Double
        switch event.keyCode {
        case 123: step = -1
        case 124: step = 1
        default: super.keyDown(with: event); return
        }
        let newSize = min(512, max(24, size + step))
        if newSize != size { size = newSize; onChange?(newSize) }
    }
}
