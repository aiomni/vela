import AppKit

/// Keep nonlinear value mapping while letting AppKit draw and operate the slider.
@MainActor
final class SettingsSlider: NSView {
    let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let scale = NSView()
    private var labels: [(Double, NSTextField)] = []
    var onChange: ((Double) -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        slider.isContinuous = true
        slider.target = self; slider.action = #selector(changed)
        slider.translatesAutoresizingMaskIntoConstraints = false
        scale.translatesAutoresizingMaskIntoConstraints = false
        addSubview(slider); addSubview(scale)
        NSLayoutConstraint.activate([
            slider.leadingAnchor.constraint(equalTo: leadingAnchor),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor),
            slider.topAnchor.constraint(equalTo: topAnchor),
            scale.topAnchor.constraint(equalTo: slider.bottomAnchor, constant: 2),
            scale.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            scale.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            scale.heightAnchor.constraint(equalToConstant: 14)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func setMarks(_ marks: [(Double, String)]) {
        for (_, label) in labels { label.removeFromSuperview() }
        labels = marks.map { position, text in
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 10)
            label.textColor = .secondaryLabelColor
            scale.addSubview(label)
            return (position, label)
        }
        needsLayout = true
    }
    override func layout() {
        super.layout()
        for (position, label) in labels {
            label.sizeToFit()
            label.setFrameOrigin(NSPoint(x: min(max(0, scale.bounds.width * position - label.frame.width / 2),
                                               scale.bounds.width - label.frame.width), y: 0))
        }
    }
    @objc private func changed() { onChange?(slider.doubleValue) }
}
