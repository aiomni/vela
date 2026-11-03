import VelaLocalization
import Foundation

enum WakeDuration: Equatable {
    case unlimited
    case minutes(Int)

    static let preferenceKey = "wakeDurationMinutes"

    static func load(from defaults: UserDefaults) -> WakeDuration {
        guard let saved = defaults.string(forKey: preferenceKey),
              let minutes = Int(saved), minutes >= 1 else { return .unlimited }
        return .minutes(minutes)
    }

    func save(to defaults: UserDefaults) {
        switch self {
        case .unlimited: defaults.removeObject(forKey: Self.preferenceKey)
        case .minutes(let minutes): defaults.set(String(minutes), forKey: Self.preferenceKey)
        }
    }

    var interval: TimeInterval? {
        switch self {
        case .unlimited: nil
        case .minutes(let minutes): TimeInterval(minutes) * 60
        }
    }

    static func remainingLabel(until deadline: Date, now: Date) -> String {
        let total = max(0, ceil(deadline.timeIntervalSince(now)))
        let days = Int(total / 86_400)
        let seconds = Int(total.truncatingRemainder(dividingBy: 86_400))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainder = seconds % 60
        if days > 0 { return L("{0}d ", "\(days)") + String(format: "%02d:%02d", hours, minutes) }
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, remainder) }
        return String(format: "%d:%02d", minutes, remainder)
    }
}
