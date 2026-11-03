import Foundation

public enum VelaLanguage: String, CaseIterable, Sendable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    public var displayName: String {
        switch self {
        case .english: "English"
        case .simplifiedChinese: Localization.chinese["Chinese (Simplified)"] ?? "Chinese (Simplified)"
        }
    }
}

public enum Localization {
    public static let preferenceKey = "velaLanguage"
    public static let didChange = Notification.Name("VelaLanguageDidChange")

    // Deliberately do not inherit the OS language: fresh installs always use English.
    public static var language: VelaLanguage {
        VelaLanguage(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "") ?? .english
    }

    public static func setLanguage(_ language: VelaLanguage) {
        UserDefaults.standard.set(language.rawValue, forKey: preferenceKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    static let chinese: [String: String] = {
        guard let url = Bundle.module.url(forResource: "zh-Hans", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return catalog
    }()

    private struct Pattern: @unchecked Sendable {
        let english: String
        let chinese: String
        let expression: NSRegularExpression
        let slots: [Int]
    }

    private static let reverse = Dictionary(chinese.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
    private static let patterns: [Pattern] = chinese.flatMap { english, translation -> [Pattern] in
        [english, translation].compactMap { source in
            let markers = try! NSRegularExpression(pattern: #"\{(\d+)\}"#)
            let matches = markers.matches(in: source, range: NSRange(source.startIndex..., in: source))
            guard !matches.isEmpty else { return nil }
            var pattern = "^", cursor = source.startIndex, slots: [Int] = []
            for match in matches {
                guard let range = Range(match.range, in: source), let slotRange = Range(match.range(at: 1), in: source),
                      let slot = Int(source[slotRange]) else { return nil }
                pattern += NSRegularExpression.escapedPattern(for: String(source[cursor..<range.lowerBound])) + "([\\s\\S]*?)"
                cursor = range.upperBound; slots.append(slot)
            }
            pattern += NSRegularExpression.escapedPattern(for: String(source[cursor...])) + "$"
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
            return Pattern(english: english, chinese: translation, expression: expression, slots: slots)
        }
    }.sorted { $0.english.count > $1.english.count }

    public static func text(_ key: String, arguments: [String] = [], language: VelaLanguage? = nil) -> String {
        let selected = language ?? self.language
        if !arguments.isEmpty {
            let template = selected == .simplifiedChinese ? (chinese[key] ?? key) : key
            return format(template, arguments: arguments)
        }
        if let translated = chinese[key] { return selected == .simplifiedChinese ? translated : key }
        if let english = reverse[key] { return selected == .english ? english : key }
        // Server messages remain English on the wire. Match formatted messages at the UI boundary.
        for pattern in patterns {
            guard let match = pattern.expression.firstMatch(in: key, range: NSRange(key.startIndex..., in: key)) else { continue }
            var values = [String](repeating: "", count: (pattern.slots.max() ?? -1) + 1)
            for (index, slot) in pattern.slots.enumerated() {
                if let range = Range(match.range(at: index + 1), in: key) { values[slot] = String(key[range]) }
            }
            return format(selected == .english ? pattern.english : pattern.chinese, arguments: values)
        }
        return key
    }

    private static func format(_ template: String, arguments: [String]) -> String {
        // A single pass keeps user-supplied braces from being interpreted as other arguments.
        let markers = try! NSRegularExpression(pattern: #"\{(\d+)\}"#)
        var result = "", cursor = template.startIndex
        for match in markers.matches(in: template, range: NSRange(template.startIndex..., in: template)) {
            guard let range = Range(match.range, in: template), let slotRange = Range(match.range(at: 1), in: template),
                  let index = Int(template[slotRange]) else { continue }
            result += template[cursor..<range.lowerBound]
            result += arguments.indices.contains(index) ? arguments[index] : String(template[range])
            cursor = range.upperBound
        }
        return result + template[cursor...]
    }
}

public func L(_ key: String, _ arguments: String...) -> String {
    Localization.text(key, arguments: arguments)
}
