import VelaLocalization
import AppKit
import RemoteCore
import ServiceManagement

@MainActor
private final class SettingsReviewLoginItem: LoginItemServicing {
    var status: SMAppService.Status = .notRegistered
    func register() throws { status = .enabled }
    func unregister() throws { status = .notRegistered }
    func openSettings() {}
}

/// Visual review uses private preferences and remote files, without registering
/// a hotkey, starting a listener, or acquiring a power assertion.
@MainActor
final class SettingsReview: NSObject, NSApplicationDelegate {
    private var settings: SettingsController!
    private var pet: PetController!
    private let suite = "Vela.SettingsReview.\(UUID().uuidString)"
    private var directory: URL!

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let defaults = UserDefaults(suiteName: suite)!
            pet = try PetController(defaults: defaults)
            pet.hide()
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
            let files = RemoteFiles(directory: directory)
            try files.save(RemoteConfiguration())
            settings = SettingsController(hotKey: HotKey(), pet: pet,
                watchSettings: WatchSettingsController(defaults: defaults), loginItem: SettingsReviewLoginItem(),
                remoteSettings: RemoteSettingsController(files: files), appearanceDefaults: defaults)
            // Use -velaLanguage en / zh-Hans for process-only language previews.
            // Keep language changes within this development-only process.
            settings.navigationController.isVisualReview = true
            settings.window.title = L("Vela Settings — Preview")
            settings.languagePicker.target = self
            settings.languagePicker.action = #selector(changeReviewLanguage)
            if let index = CommandLine.arguments.firstIndex(of: "--settings-appearance"), index + 1 < CommandLine.arguments.count {
                let names: [String: NSAppearance.Name] = ["light": .aqua, "dark": .darkAqua,
                    "contrast-light": .accessibilityHighContrastAqua, "contrast-dark": .accessibilityHighContrastDarkAqua]
                if let name = names[CommandLine.arguments[index + 1]] { settings.window.appearance = NSAppearance(named: name) }
            }
            if let index = CommandLine.arguments.firstIndex(of: "--settings-page"), index + 1 < CommandLine.arguments.count,
               let page = SettingsPage(rawValue: CommandLine.arguments[index + 1]) { settings.navigationController.select(page) }
            if CommandLine.arguments.contains("--settings-opaque") { settings.navigationController.navigation.configure(reduceTransparency: true) }
            settings.show()
            print("SETTINGS_REVIEW_READY window=\(settings.window.windowNumber)")
        } catch { fputs("Settings review failed: \(error.localizedDescription)\n", stderr); NSApp.terminate(nil) }
    }
    @objc private func changeReviewLanguage() {
        let index = settings.languagePicker.indexOfSelectedItem
        guard VelaLanguage.allCases.indices.contains(index) else { return }
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments[Localization.preferenceKey] = VelaLanguage.allCases[index].rawValue
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        NotificationCenter.default.post(name: Localization.didChange, object: nil)
        settings.refreshLocalizedState()
        settings.window.title = L("Vela Settings — Preview")
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {
        UserDefaults.standard.removePersistentDomain(forName: suite)
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }
}
