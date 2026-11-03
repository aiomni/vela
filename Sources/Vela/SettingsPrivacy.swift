import AppKit
import VelaLocalization

@MainActor
enum SettingsPrivacy {
    static var controlTitle: String {
        if #available(macOS 27.0, *) { return L("Device Control and Data Access") }
        return L("Accessibility")
    }

    static func open(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}
