import AppKit

@MainActor
public final class LanguagePicker: NSPopUpButton {
    public init() {
        super.init(frame: .zero, pullsDown: false)
        addItems(withTitles: VelaLanguage.allCases.map(\.displayName))
        selectItem(at: VelaLanguage.allCases.firstIndex(of: Localization.language) ?? 0)
        target = self
        action = #selector(changeLanguage)
        setAccessibilityLabel(L("Language"))
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func changeLanguage() {
        guard VelaLanguage.allCases.indices.contains(indexOfSelectedItem) else { return }
        Localization.setLanguage(VelaLanguage.allCases[indexOfSelectedItem])
    }
}

@MainActor
public enum LocalizationUI {
    public static func refreshWindows() {
        for window in NSApp.windows {
            window.title = L(window.title)
            if let content = window.contentView { refresh(content) }
        }
        refresh(NSApp.mainMenu)
    }

    public static func refresh(_ menu: NSMenu?) {
        guard let menu else { return }
        menu.title = L(menu.title)
        for item in menu.items {
            item.title = L(item.title)
            item.toolTip = item.toolTip.map { L($0) }
            refresh(item.submenu)
        }
    }

    public static func refresh(_ view: NSView) {
        view.toolTip = view.toolTip.map { L($0) }
        if let label = view.accessibilityLabel() { view.setAccessibilityLabel(L(label)) }
        if let picker = view as? LanguagePicker {
            picker.selectItem(at: VelaLanguage.allCases.firstIndex(of: Localization.language) ?? 0)
        } else if let popup = view as? NSPopUpButton {
            refresh(popup.menu)
        } else if let button = view as? NSButton {
            button.title = L(button.title)
        } else if let segmented = view as? NSSegmentedControl {
            for index in 0..<segmented.segmentCount {
                if let label = segmented.label(forSegment: index) { segmented.setLabel(L(label), forSegment: index) }
            }
        } else if let field = view as? NSTextField {
            field.placeholderString = field.placeholderString.map { L($0) }
            // Never translate user-entered addresses, passwords, text, or numeric settings.
            if !field.isEditable { field.stringValue = L(field.stringValue) }
        }
        for child in view.subviews { refresh(child) }
    }
}
