import VelaLocalization
import AppKit

@MainActor
final class WatchSettingsController: NSObject, NSTextFieldDelegate {
    let view = NSStackView()
    let grace = NSPopUpButton()
    let activity = NSPopUpButton()
    let battery = NSPopUpButton()
    let agents = NSTextField()
    private let hint = NSTextField(wrappingLabelWithString: "")
    private let defaults: UserDefaults
    var onChange: ((Int, Int, [String], AgentActivityMode) -> Void)?

    init(defaults: UserDefaults) {
        self.defaults = defaults
        super.init()
        let root = view
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        for value in [1, 2, 3, 5, 10, 15] {
            grace.addItem(withTitle: L("{0} minutes", "\(value)"))
            grace.lastItem?.representedObject = value
        }
        grace.target = self; grace.action = #selector(changed)
        grace.widthAnchor.constraint(equalToConstant: 150).isActive = true
        for mode in AgentActivityMode.allCases {
            activity.addItem(withTitle: mode.title)
            activity.lastItem?.representedObject = mode.rawValue
        }
        activity.target = self; activity.action = #selector(changed)
        activity.widthAnchor.constraint(equalToConstant: 190).isActive = true
        for value in stride(from: 10, through: 50, by: 5) {
            battery.addItem(withTitle: "\(value)%")
            battery.lastItem?.representedObject = value
        }
        battery.target = self; battery.action = #selector(changed)
        battery.widthAnchor.constraint(equalToConstant: 150).isActive = true
        for popup in [grace, activity, battery] {
            popup.isBordered = false; popup.alignment = .right; popup.cell?.alignment = .right
        }
        agents.placeholderString = L("e.g. goose, amp")
        agents.delegate = self
        agents.widthAnchor.constraint(equalToConstant: 220).isActive = true
        for (control, label) in [(grace as NSControl, L("Agent idle grace")), (activity, L("Activity detection")),
                                  (battery, L("Stop on low battery")), (agents, L("Custom agents"))] {
            control.setAccessibilityLabel(label)
        }
        hint.textColor = .secondaryLabelColor; hint.font = .systemFont(ofSize: 11)
        hint.stringValue = L("Only this Mac's current user is monitored. Remote and container agents aren't detected.")
        for section in [
            SettingsStyle.group([SettingsStyle.row(L("Activity detection"), activity),
                                 SettingsStyle.row(L("Agent idle grace"), grace),
                                 SettingsStyle.row(L("Stop on low battery"), battery)]),
            SettingsStyle.group([SettingsStyle.row(L("Custom agents"), agents)]), hint
        ] {
            root.addArrangedSubview(section)
            section.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        }
        refresh()
    }

    static func graceMinutes(from defaults: UserDefaults) -> Int {
        let value = defaults.object(forKey: "agentGraceMinutes") as? Int ?? 5
        return [1, 2, 3, 5, 10, 15].contains(value) ? value : 5
    }
    static func batteryFloor(from defaults: UserDefaults) -> Int {
        let value = defaults.object(forKey: "watchBatteryFloor") as? Int ?? 20
        return value >= 10 && value <= 50 && value.isMultiple(of: 5) ? value : 20
    }
    static func customAgents(from defaults: UserDefaults) -> [String] {
        Array((defaults.stringArray(forKey: "watchCustomAgents") ?? []).filter {
            $0.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$"#, options: .regularExpression) != nil
        }.prefix(16))
    }
    static func activityMode(from defaults: UserDefaults) -> AgentActivityMode {
        AgentActivityMode(rawValue: defaults.string(forKey: "agentActivityMode") ?? "") ?? .working
    }

    func refresh() {
        let graceValue = Self.graceMinutes(from: defaults)
        grace.selectItem(withTitle: L("{0} minutes", "\(graceValue)"))
        activity.selectItem(withTitle: Self.activityMode(from: defaults).title)
        let batteryValue = Self.batteryFloor(from: defaults)
        battery.selectItem(withTitle: "\(batteryValue)%")
        agents.stringValue = Self.customAgents(from: defaults).joined(separator: ", ")
    }
    @objc func changed() {
        let graceValue = grace.selectedItem?.representedObject as? Int ?? 5
        let batteryValue = battery.selectedItem?.representedObject as? Int ?? 20
        let names = agents.stringValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let valid = Array(Set(names.filter {
            $0.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$"#, options: .regularExpression) != nil
        })).sorted().prefix(16)
        defaults.set(graceValue, forKey: "agentGraceMinutes")
        defaults.set(batteryValue, forKey: "watchBatteryFloor")
        defaults.set(Array(valid), forKey: "watchCustomAgents")
        let activityMode = AgentActivityMode(rawValue: activity.selectedItem?.representedObject as? String ?? "") ?? .working
        defaults.set(activityMode.rawValue, forKey: "agentActivityMode")
        onChange?(graceValue, batteryValue, Array(valid), activityMode)
    }
    func controlTextDidEndEditing(_ obj: Notification) { changed() }
}
