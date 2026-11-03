import AppKit
import VelaLocalization

@MainActor
final class SettingsPageView: NSViewController {
    let scroll = VelaScrollView()
    let stack = NSStackView()
    let page: SettingsPage
    init(_ page: SettingsPage, sections: [NSView]) {
        self.page = page
        super.init(nibName: nil, bundle: nil)
        let background = SettingsSurface()
        background.isCard = false; background.refreshColors()
        background.layer?.cornerRadius = 0
        view = background
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = true
        view.addSubview(scroll)
        let document = SettingsSurface()
        document.isCard = false; document.refreshColors(); document.layer?.cornerRadius = 0
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -20)
        ])
        for section in sections {
            stack.addArrangedSubview(section)
            section.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor
private final class SettingsSidebar: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    let table = NSTableView()
    var pages = SettingsPage.allCases
    var onSelect: ((SettingsPage) -> Void)?
    var selectedPage: SettingsPage = .general
    private var updatingSelection = false

    override func loadView() {
        view = NSView()
        let scroll = VelaScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.contentView.drawsBackground = false
        table.addTableColumn(NSTableColumn(identifier: .init("page")))
        table.headerView = nil; table.style = .sourceList; table.backgroundColor = .clear
        table.rowHeight = 30; table.intercellSpacing = NSSize(width: 0, height: 2)
        table.dataSource = self; table.delegate = self; table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.setAccessibilityLabel(L("Settings categories"))
        scroll.documentView = table; view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12)
        ])
    }
    func numberOfRows(in tableView: NSTableView) -> Int { pages.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let page = pages[row]
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: page.title)
        label.font = .systemFont(ofSize: 13)
        let icon = SettingsStyle.icon(page, size: 20)
        let stack = NSStackView(views: [icon, label]); stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(stack)
        cell.textField = label
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updatingSelection, pages.indices.contains(table.selectedRow) else { return }
        selectedPage = pages[table.selectedRow]; onSelect?(selectedPage)
    }
    func select(_ page: SettingsPage) {
        selectedPage = page
        if let index = pages.firstIndex(of: page) {
            if table.selectedRow != index { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        } else { table.deselectAll(nil) }
    }
    func refreshLanguage() {
        LocalizationUI.refresh(view)
        updatingSelection = true
        table.reloadData(); select(selectedPage)
        updatingSelection = false
    }
}

/// Real glass for the navigation cluster, with a semantic opaque fallback.
@MainActor
final class SettingsGlassNavigation: NSView {
    let glass = NSGlassEffectView()
    let back = NSButton(image: NSImage(systemSymbolName: "chevron.left", accessibilityDescription: nil)!, target: nil, action: nil)
    let forward = NSButton(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)!, target: nil, action: nil)
    private let fallbackSurface = SettingsSurface()
    private let controls = NSStackView()
    private(set) var usesOpaqueBackground = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        glass.style = .regular; glass.cornerRadius = 18
        if #available(macOS 27.0, *) { glass.effectIsInteractive = true }
        for button in [back, forward] {
            button.isBordered = false; button.imagePosition = .imageOnly
            button.contentTintColor = .labelColor
            button.widthAnchor.constraint(equalToConstant: 31).isActive = true
            button.heightAnchor.constraint(equalToConstant: 30).isActive = true
            controls.addArrangedSubview(button)
            if button === back {
                let divider = NSBox(); divider.boxType = .separator
                divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
                divider.heightAnchor.constraint(equalToConstant: 20).isActive = true
                controls.addArrangedSubview(divider)
            }
        }
        controls.spacing = 0; controls.alignment = .centerY
        controls.translatesAutoresizingMaskIntoConstraints = false
        for child in [glass, fallbackSurface] {
            child.translatesAutoresizingMaskIntoConstraints = false; addSubview(child)
            NSLayoutConstraint.activate([
                child.leadingAnchor.constraint(equalTo: leadingAnchor), child.trailingAnchor.constraint(equalTo: trailingAnchor),
                child.topAnchor.constraint(equalTo: topAnchor), child.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }
        fallbackSurface.layer?.cornerRadius = 18
        glass.contentView = controls
        installControlConstraints(in: glass)
        configure(reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private var controlConstraints: [NSLayoutConstraint] = []
    private func installControlConstraints(in parent: NSView) {
        controlConstraints = [
            controls.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: 5),
            controls.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -5),
            controls.topAnchor.constraint(equalTo: parent.topAnchor, constant: 2),
            controls.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -2)
        ]
        NSLayoutConstraint.activate(controlConstraints)
    }
    func configure(reduceTransparency: Bool) {
        guard controls.superview == nil || usesOpaqueBackground != reduceTransparency || controlConstraints.isEmpty else {
            glass.isHidden = reduceTransparency; fallbackSurface.isHidden = !reduceTransparency
            return
        }
        NSLayoutConstraint.deactivate(controlConstraints)
        glass.contentView = nil; controls.removeFromSuperview()
        if reduceTransparency { fallbackSurface.addSubview(controls); installControlConstraints(in: fallbackSurface) }
        else { glass.contentView = controls; installControlConstraints(in: glass) }
        usesOpaqueBackground = reduceTransparency
        glass.isHidden = reduceTransparency; fallbackSurface.isHidden = !reduceTransparency
    }
}

@MainActor
final class SettingsNavigationController: NSSplitViewController, NSToolbarDelegate {
    private let sidebar = SettingsSidebar()
    var sidebarTable: NSTableView { sidebar.table }
    private let detail = NSViewController()
    let navigation = SettingsGlassNavigation()
    let titleLabel = NSTextField(labelWithString: "")
    let pages: [SettingsPage: SettingsPageView]
    private(set) var selectedPage: SettingsPage = .general
    var isVisualReview = false { didSet { refreshLanguage() } }
    private var displayTitle: String { isVisualReview ? L("{0} · Preview", selectedPage.title) : selectedPage.title }
    private var history: [SettingsPage] = [.general]
    private var historyIndex = 0
    var onPageChange: ((SettingsPage) -> Void)?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init(pages: [SettingsPage: SettingsPageView]) {
        self.pages = pages
        super.init(nibName: nil, bundle: nil)
        splitView.isVertical = true; splitView.dividerStyle = .thin
        let item = NSSplitViewItem(sidebarWithViewController: sidebar)
        item.minimumThickness = 164; item.maximumThickness = 184
        item.preferredThicknessFraction = 0.19
        item.canCollapse = false; item.canCollapseFromWindowResize = false
        item.holdingPriority = .init(751)
        addSplitViewItem(item)
        detail.view = NSView()
        let content = NSSplitViewItem(viewController: detail)
        content.minimumThickness = 530; content.automaticallyAdjustsSafeAreaInsets = true
        addSplitViewItem(content)
        for page in SettingsPage.allCases {
            let controller = pages[page]!
            detail.addChild(controller); detail.view.addSubview(controller.view)
            controller.view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                controller.view.leadingAnchor.constraint(equalTo: detail.view.leadingAnchor),
                controller.view.trailingAnchor.constraint(equalTo: detail.view.trailingAnchor),
                controller.view.topAnchor.constraint(equalTo: detail.view.topAnchor),
                controller.view.bottomAnchor.constraint(equalTo: detail.view.bottomAnchor)
            ])
        }
        sidebar.onSelect = { [weak self] in self?.select($0) }
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        navigation.back.target = self; navigation.back.action = #selector(back)
        navigation.forward.target = self; navigation.forward.action = #selector(forward)
        select(.general, recordHistory: false)
        let language = NotificationCenter.default.addObserver(forName: Localization.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshLanguage() }
        }
        observers.append((.default, language))
        let center = NSWorkspace.shared.notificationCenter
        let accessibility = center.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.navigation.configure(reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)
                for page in self?.pages.values ?? [:].values { Self.refreshSurfaces(page.view) }
            }
        }
        observers.append((center, accessibility))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    isolated deinit { for (center, observer) in observers { center.removeObserver(observer) } }

    private static func refreshSurfaces(_ view: NSView) {
        (view as? SettingsSurface)?.refreshColors()
        for child in view.subviews { refreshSurfaces(child) }
    }

    func installToolbar(on window: NSWindow) {
        let toolbar = NSToolbar(identifier: "Vela.Settings")
        toolbar.delegate = self; toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar; window.toolbarStyle = .unified
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        splitView.setPosition(164, ofDividerAt: 0)
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarTrackingSeparator, .init("navigation"), .init("pageTitle"), .flexibleSpace]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.view = identifier.rawValue == "pageTitle" ? titleLabel : navigation
        item.label = identifier.rawValue == "pageTitle" ? displayTitle : L("Settings navigation")
        item.isNavigational = true
        return item
    }
    func select(_ page: SettingsPage, recordHistory: Bool = true) {
        if selectedPage != page {
            onPageChange?(page)
            if recordHistory {
                history = Array(history.prefix(historyIndex + 1)) + [page]
                historyIndex = history.count - 1
            }
        }
        selectedPage = page
        titleLabel.stringValue = displayTitle
        titleLabel.setAccessibilityLabel(displayTitle)
        view.window?.toolbar?.items.first { $0.itemIdentifier.rawValue == "pageTitle" }?.label = displayTitle
        for (id, controller) in pages { controller.view.isHidden = id != page }
        sidebar.select(page)
        navigation.back.isEnabled = historyIndex > 0
        navigation.forward.isEnabled = historyIndex + 1 < history.count
    }
    @objc func back() {
        guard historyIndex > 0 else { return }
        historyIndex -= 1; select(history[historyIndex], recordHistory: false)
    }
    @objc func forward() {
        guard historyIndex + 1 < history.count else { return }
        historyIndex += 1; select(history[historyIndex], recordHistory: false)
    }
    func refreshLanguage() {
        for page in pages.values { LocalizationUI.refresh(page.view) }
        sidebar.refreshLanguage()
        titleLabel.stringValue = displayTitle
        titleLabel.setAccessibilityLabel(displayTitle)
        for item in view.window?.toolbar?.items ?? [] {
            item.label = item.itemIdentifier.rawValue == "pageTitle" ? displayTitle : L("Settings navigation")
        }
        navigation.back.toolTip = L("Back"); navigation.back.setAccessibilityLabel(L("Back"))
        navigation.forward.toolTip = L("Forward"); navigation.forward.setAccessibilityLabel(L("Forward"))
    }
}
