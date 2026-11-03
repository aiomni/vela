import VelaLocalization
import AppKit

@MainActor
final class DurationProgressBar: NSControl {
    var duration: WakeDuration = .unlimited { didSet { synchronize() } }
    var onChange: ((WakeDuration) -> Void)?

    // More room for short sessions; the last stop represents an unlimited session.
    private let stops: [(position: Double, minutes: Int)] = [
        (0, 1), (0.10, 15), (0.19, 30), (0.29, 60),
        (0.36, 120), (0.43, 240), (0.54, 720), (0.73, 1440), (0.92, 10080)
    ]
    let native = SettingsSlider()
    override var acceptsFirstResponder: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        native.translatesAutoresizingMaskIntoConstraints = false
        addSubview(native)
        native.setMarks([(0, L("1m")), (0.29, L("1h")), (0.54, L("12h")), (0.92, L("7d")), (1, "∞")])
        native.slider.setAccessibilityLabel(L("Keep-awake duration"))
        native.onChange = { [weak self] position in
            guard let self else { return }
            let next = self.duration(at: position)
            guard next != self.duration else { return }
            self.duration = next; self.onChange?(next)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityChildren([native.slider])
        native.topAnchor.constraint(equalTo: topAnchor).isActive = true
        NSLayoutConstraint.activate([
            native.leadingAnchor.constraint(equalTo: leadingAnchor),
            native.trailingAnchor.constraint(equalTo: trailingAnchor),
            native.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        synchronize()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func synchronize() {
        native.slider.doubleValue = position(for: duration)
    }

    func position(for duration: WakeDuration) -> Double {
        guard case .minutes(let minutes) = duration else { return 1 }
        if minutes >= 10080 { return 0.92 }
        for index in 1..<stops.count where minutes <= stops[index].minutes {
            let previous = stops[index - 1], next = stops[index]
            let fraction = Double(minutes - previous.minutes) / Double(next.minutes - previous.minutes)
            return previous.position + fraction * (next.position - previous.position)
        }
        return 0
    }

    func duration(at position: Double) -> WakeDuration {
        if position >= 0.96 { return .unlimited }
        let position = min(0.92, max(0, position))
        for index in 1..<stops.count where position <= stops[index].position {
            let previous = stops[index - 1], next = stops[index]
            let fraction = (position - previous.position) / (next.position - previous.position)
            return .minutes(max(1, Int((Double(previous.minutes) + fraction * Double(next.minutes - previous.minutes)).rounded())))
        }
        return .minutes(10080)
    }

    override func keyDown(with event: NSEvent) {
        let step: Int
        switch event.keyCode {
        case 123: step = -1
        case 124: step = 1
        default: super.keyDown(with: event); return
        }
        let current = position(for: duration)
        let next = duration(at: current + Double(step) * 0.01)
        if next != duration { duration = next; onChange?(next) }
    }
}
