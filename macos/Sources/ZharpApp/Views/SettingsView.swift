import AppKit
import CoreText
import ZharpCore

/// The settings page, hosted as a tab in the main window :
/// a navigation rail of pages on the left, setting cards on the right.
/// Changes are saved immediately and broadcast via `changed`.
final class SettingsView: ChromeView {
    private let settings: AppSettings
    private var ready = false

    /// Raised after any setting has been modified and saved.
    var changed: (() -> Void)?

    private lazy var cursorClaim = CursorClaim(view: self)

    private let navRail = ChromeView(fill: .panelOverlay)
    private var navWidth: NSLayoutConstraint!
    private var navRows: [RoundedRowView] = []
    private let scrollView = NSScrollView()
    private let pageStack = NSStackView()
    private var pages: [NSStackView] = []

    private var themeGrid: ThemeGridView!
    private var backdropCombo: ActionPopUpButton!
    private var opacitySlider: NSSlider!
    private var layoutCombo: ActionPopUpButton!
    private var densityCombo: ActionPopUpButton!
    private var titleModeCombo: ActionPopUpButton!
    private var showPathToggle: ActionSwitch!
    private var showSearchToggle: ActionSwitch!
    private var cursorCombo: ActionPopUpButton!
    private var scrollbackBox: NumberBox!
    private var agentAlertToggle: ActionSwitch!
    private var fontSizeBox: NumberBox!
    private var shellCombo: ActionPopUpButton!
    private var noColorToggle: ActionSwitch!
    private var restoreToggle: ActionSwitch!
    private var inputPositionGrid: InputPositionGridView!
    private var updateStatusLabel: NSTextField!
    private var checkButton: PushButton!
    private var shortcutsPanel: NSStackView!
    private var shortcutHint: NSTextField!
    private var capturingRow: ShortcutRow?

    private static let pageTitles = ["Appearance", "Terminal", "Shell", "Shortcuts", "About"]
    private static let pageGlyphs = [Icons.palette, Icons.terminal2, Icons.prompt,
                                     Icons.keyboard, Icons.info]

    init(settings: AppSettings) {
        self.settings = settings
        super.init(fill: .none)
        translatesAutoresizingMaskIntoConstraints = false

        buildNavRail()
        buildPages()
        select(page: 0)
        ready = true
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    // ---------------------------------------------------------------- chrome

    private func buildNavRail() {
        navRail.translatesAutoresizingMaskIntoConstraints = false
        navRail.hairlineEdges = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 1)
        addSubview(navRail)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        navRail.addSubview(stack)

        for (index, title) in Self.pageTitles.enumerated() {
            let row = RoundedRowView()
            row.translatesAutoresizingMaskIntoConstraints = false
            let icon = Label.icon(Self.pageGlyphs[index], size: 19)
            let label = Label.make(title, size: 12.5)
            row.addSubview(icon)
            row.addSubview(label)
            row.onClick = { [weak self] in self?.select(page: index) }
            NSLayoutConstraint.activate([
                row.heightAnchor.constraint(equalToConstant: 34),
                icon.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 8),
                icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
                label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            ])
            navRows.append(row)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        navWidth = navRail.widthAnchor.constraint(equalToConstant: 180)
        NSLayoutConstraint.activate([
            navRail.leadingAnchor.constraint(equalTo: leadingAnchor),
            navRail.topAnchor.constraint(equalTo: topAnchor),
            navRail.bottomAnchor.constraint(equalTo: bottomAnchor),
            navWidth,
            stack.leadingAnchor.constraint(equalTo: navRail.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: navRail.trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: navRail.topAnchor, constant: 8),
        ])
    }

    private func buildPages() {
        pageStack.orientation = .vertical
        pageStack.alignment = .leading
        pageStack.spacing = 0
        pageStack.translatesAutoresizingMaskIntoConstraints = false

        ScrollBox.configure(scrollView, document: pageStack)
        addSubview(scrollView)

        pages = [buildAppearancePage(), buildTerminalPage(), buildShellPage(),
                 buildShortcutsPage(), buildAboutPage()]
        for page in pages {
            pageStack.addArrangedSubview(page)
            page.widthAnchor.constraint(equalTo: pageStack.widthAnchor,
                                        constant: -64).isActive = true
        }

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: navRail.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            pageStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])
    }

    private func select(page index: Int) {
        for (i, row) in navRows.enumerated() { row.isSelected = i == index }
        for (i, page) in pages.enumerated() { page.isHidden = i != index }
        scrollView.documentView?.scroll(.zero)
    }

    /// Re-reads every control from the shared settings. Another window may have
    /// changed them, and populating must not look like the user editing - so
    /// the ready flag is dropped for the duration.
    func loadValues() {
        ready = false
        defer { ready = true }

        themeGrid.setSelection(settings.theme)
        let modes = Backdrop.allCases
        backdropCombo.selectItem(at: modes.firstIndex(of: Backdrop.parse(settings.backdrop)) ?? 1)
        opacitySlider.doubleValue = Swift.min(Swift.max(settings.backgroundOpacity * 100, 50), 100)
        layoutCombo.selectItem(at: settings.useSidebar ? 0 : 1)
        densityCombo.selectItem(at: settings.sidebarCompact ? 1 : 0)
        titleModeCombo.selectItem(at: settings.sidebarTitleIsCwd ? 1 : 0)
        showPathToggle.state = settings.sidebarShowPath ? .on : .off
        showSearchToggle.state = settings.sidebarShowSearch ? .on : .off
        cursorCombo.selectItem(at: AppSettings.cursorStyleToCode(settings.cursorStyle) == 3
                               ? 1 : (AppSettings.cursorStyleToCode(settings.cursorStyle) == 5 ? 2 : 0))
        fontSizeBox.setValue(settings.fontSize)
        scrollbackBox.setValue(Double(settings.scrollbackLines))
        agentAlertToggle.state = settings.agentNotifications ? .on : .off
        inputPositionGrid.setSelection(AppSettings.inputPositionToCode(settings.inputPosition))
        noColorToggle.state = settings.overrideNoColor ? .on : .off
        restoreToggle.state = settings.restoreSessions ? .on : .off
        defaultDirField?.stringValue = settings.defaultDirectory
    }

    /// Moves keyboard focus into the page (used when this tab activates).
    func focusFirst() {
        window?.makeFirstResponder(self)
    }

    /// The About page reflects an update the background check already found,
    /// so opening Settings does not re-run it.
    func setAvailableUpdate(_ version: String?) {
        guard let updateStatusLabel else { return }
        if let version {
            updateStatusLabel.stringValue =
                "Zharp \(version) is available (you have \(App.version))."
            offerDownload()
        } else {
            updateStatusLabel.stringValue = "Zharp \(App.version) is up to date."
        }
    }

    /// Turns the check button into a download button for the available release.
    private func offerDownload() {
        guard let checkButton else { return }
        checkButton.setTitle("Download")
        checkButton.isAccent = true
        checkButton.onClick = {
            if let url = UpdateService.downloadURL { NSWorkspace.shared.open(url) }
        }
    }

    /// Jumps to the About page (update-notification click target).
    func showAbout() { select(page: pages.count - 1) }

    /// Zoom-dependent layout metrics.
    func setZoom(_ zoom: Double) {
        navWidth.constant = 180 * CGFloat(zoom)
    }

    func refreshChrome() {
        ChromeRefresh.apply(to: self)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        cursorClaim.update()
    }

    override func cursorUpdate(with event: NSEvent) {
        cursorClaim.set()
    }

    // ---------------------------------------------------------------- builders

    private func page() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 32, bottom: 28, right: 32)
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func sectionHeader(_ text: String, first: Bool = false) -> NSView {
        let label = Label.make(text, size: 15, weight: .semibold)
        return pad(label, top: first ? 4 : 22, bottom: 6)
    }

    private func description(_ text: String) -> NSView {
        pad(Label.make(text, size: 11.5, opacity: 0.55, wraps: true), top: 0, bottom: 6)
    }

    private func divider() -> NSView {
        let line = ChromeView(fill: .custom(Chrome.current.sectionDivider))
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return pad(line, top: 16, bottom: 0, stretch: true)
    }

    private func pad(_ view: NSView, top: CGFloat, bottom: CGFloat,
                     stretch: Bool = false) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: top),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -bottom),
            stretch
                ? view.trailingAnchor.constraint(equalTo: container.trailingAnchor)
                : view.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
        ])
        return container
    }

    /// A settings row: title + description on the left, the control on the right.
    private func row(_ title: String, _ detail: String, _ control: NSView) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = Label.make(title, size: 13)
        let detailLabel = Label.make(detail, size: 11.5, opacity: 0.55, wraps: true)
        let text = NSStackView(views: [titleLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.translatesAutoresizingMaskIntoConstraints = false

        control.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(text)
        container.addSubview(control)

        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            text.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            text.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
            text.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -16),
            control.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            control.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

    private func add(_ page: NSStackView, _ views: [NSView]) {
        for view in views {
            page.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: page.widthAnchor,
                                        constant: -64).isActive = true
        }
    }

    // ---------------------------------------------------------------- Appearance

    private func buildAppearancePage() -> NSStackView {
        let p = page()

        themeGrid = ThemeGridView(selectedId: settings.theme)
        themeGrid.onSelect = { [weak self] id in
            self?.apply { self?.settings.theme = id }
        }

        let backdropModes = Backdrop.allCases
        backdropCombo = combo(backdropModes.map(\.label),
                                  selected: backdropModes.firstIndex(
                                      of: Backdrop.parse(settings.backdrop)) ?? 1,
                                  width: 170) { [weak self] index in
            self?.apply { self?.settings.backdrop = backdropModes[index].rawValue }
        }

        opacitySlider = NSSlider(value: min(max(settings.backgroundOpacity * 100, 50), 100),
                                     minValue: 50, maxValue: 100,
                                     target: self, action: #selector(onOpacityChanged))
        opacitySlider.widthAnchor.constraint(equalToConstant: 200).isActive = true

        layoutCombo = combo(["Sidebar (vertical)", "Top strip (horizontal)"],
                                selected: settings.useSidebar ? 0 : 1, width: 200) { [weak self] i in
            self?.apply { self?.settings.tabLayout = i == 0 ? "sidebar" : "top" }
        }

        densityCombo = combo(["Comfortable", "Compact"],
                                 selected: settings.sidebarCompact ? 1 : 0, width: 160) { [weak self] i in
            self?.apply { self?.settings.sidebarDensity = i == 1 ? "compact" : "comfortable" }
        }

        titleModeCombo = combo(["Last command", "Working directory"],
                                   selected: settings.sidebarTitleIsCwd ? 1 : 0,
                                   width: 180) { [weak self] i in
            self?.apply { self?.settings.sidebarTitleMode = i == 1 ? "cwd" : "shell" }
        }

        showPathToggle = toggle(settings.sidebarShowPath) { [weak self] on in
            self?.apply { self?.settings.sidebarShowPath = on }
        }

        showSearchToggle = toggle(settings.sidebarShowSearch) { [weak self] on in
            self?.apply { self?.settings.sidebarShowSearch = on }
        }

        let fontCombo = fontFamilyCombo()

        fontSizeBox = numberBox(value: settings.fontSize, min: 7, max: 36,
                                        step: 1, width: 130) { [weak self] value in
            self?.apply { self?.settings.fontSize = value }
        }

        cursorCombo = combo(["▮  Block", "▁  Underline", "▏  Bar"],
                                selected: AppSettings.cursorStyleToCode(settings.cursorStyle) == 3
                                    ? 1 : (AppSettings.cursorStyleToCode(settings.cursorStyle) == 5 ? 2 : 0),
                                width: 160) { [weak self] i in
            self?.apply { self?.settings.cursorStyle = ["block", "underline", "bar"][i] }
        }

        inputPositionGrid = InputPositionGridView(
            selected: AppSettings.inputPositionToCode(settings.inputPosition))
        inputPositionGrid.onSelect = { [weak self] index in
            self?.apply { self?.settings.inputPosition = ["top", "bottom", "pinTop"][index] }
        }

        add(p, [
            sectionHeader("Theme", first: true),
            description("Applies live to the whole app and all terminals."),
            pad(themeGrid, top: 0, bottom: 4),
            divider(),
            sectionHeader("Window"),
            row("Background blur",
                Backdrop.suppressedBySystem
                    ? "Turned off by Reduce transparency in System Settings > Accessibility > Display. Zharp renders opaque while that is on."
                    : "Blurs the desktop behind the window.",
                backdropCombo),
            row("Window opacity", "Lower lets more of the blurred background through. Applies live.",
                opacitySlider),
            divider(),
            sectionHeader("Tabs"),
            row("Tab layout", "Where session tabs live.", layoutCombo),
            row("Density", "Compact shows single-line session cards.", densityCombo),
            row("Tab title", "What the first line of a session card shows.", titleModeCombo),
            row("Show details", "Second line on session cards (path or shell name).",
                showPathToggle),
            row("Tab search", "Search box above the session list; off shows a Sessions label.",
                showSearchToggle),
            divider(),
            sectionHeader("Text"),
            row("Font family", "Monospace fonts work best. Applies live.", fontCombo),
            row("Font size", "Cmd+wheel zooms a single session temporarily.", fontSizeBox),
            row("Cursor style", "Used unless an application picks its own. Applies live.",
                cursorCombo),
            divider(),
            sectionHeader("Input position"),
            description("Where the prompt sits. Applies live; full-screen apps are unaffected."),
            pad(inputPositionGrid, top: 0, bottom: 4),
            divider(),
        ])
        return p
    }

    @objc private func onOpacityChanged(_ sender: NSSlider) {
        apply { settings.backgroundOpacity = sender.doubleValue / 100.0 }
    }

    // ---------------------------------------------------------------- Terminal

    private func buildTerminalPage() -> NSStackView {
        let p = page()
        scrollbackBox = numberBox(value: Double(settings.scrollbackLines), min: 100,
                                      max: 200000, step: 1000, width: 160) { [weak self] value in
            self?.apply { self?.settings.scrollbackLines = Int(value) }
        }

        agentAlertToggle = toggle(settings.agentNotifications) { [weak self] on in
            self?.apply { self?.settings.agentNotifications = on }
        }

        add(p, [
            sectionHeader("History", first: true),
            row("Scrollback lines", "History kept per session. Applies to new sessions.",
                scrollbackBox),
            divider(),
            sectionHeader("Notifications"),
            row("When an AI agent needs you",
                "Desktop notification and a bouncing Dock icon while Zharp is not the app in front. Click it to jump to the session. The tab always shows it either way.",
                agentAlertToggle),
            divider(),
        ])
        return p
    }

    // ---------------------------------------------------------------- Shell

    private func buildShellPage() -> NSStackView {
        let p = page()

        let available = ShellDiscovery.availableShells()
        var shellNames = ["Auto (your login shell)"]
        var shellIds = ["auto"]
        for (id, name) in available {
            shellNames.append(name)
            shellIds.append(id)
        }
        let selectedShell = shellIds.firstIndex(of: settings.shell.lowercased()) ?? 0
        shellCombo = combo(shellNames, selected: selectedShell, width: 220) { [weak self] i in
            self?.apply { self?.settings.shell = shellIds[i] }
        }

        let dirField = NSTextField(string: settings.defaultDirectory)
        dirField.placeholderString = "~"
        dirField.font = NSFont.systemFont(ofSize: 13)
        dirField.translatesAutoresizingMaskIntoConstraints = false
        dirField.widthAnchor.constraint(equalToConstant: 200).isActive = true
        dirField.target = self
        dirField.action = #selector(onDefaultDirChanged)
        defaultDirField = dirField

        let browse = PushButton(title: "Browse")
        browse.onClick = { [weak self] in self?.browseDefaultDirectory() }

        let dirRow = NSStackView(views: [dirField, browse])
        dirRow.orientation = .horizontal
        dirRow.spacing = 8

        noColorToggle = toggle(settings.overrideNoColor) { [weak self] on in
            self?.apply { self?.settings.overrideNoColor = on }
        }

        restoreToggle = toggle(settings.restoreSessions) { [weak self] on in
            // Saved without the Changed broadcast: only the next launch reads
            // this, so there is nothing live to re-apply.
            self?.applyWithoutBroadcast { self?.settings.restoreSessions = on }
        }

        add(p, [
            sectionHeader("Shell", first: true),
            row("Default shell",
                "Zharp reports the current directory for all of these. Applies to new sessions.",
                shellCombo),
            row("Default directory",
                "Where new terminals start. Leave empty for your home folder.", dirRow),
            divider(),
            sectionHeader("Startup"),
            row("Continue where you left off",
                "Reopen the tabs you had open when you quit - same shells, same folders.",
                restoreToggle),
            divider(),
            sectionHeader("Colors"),
            row("Shell colors",
                "Remove NO_COLOR from the environment of spawned shells so tools emit ANSI colors. Applies to new sessions.",
                noColorToggle),
            divider(),
        ])
        return p
    }

    private var defaultDirField: NSTextField?

    @objc private func onDefaultDirChanged() {
        guard let defaultDirField else { return }
        apply { settings.defaultDirectory = defaultDirField.stringValue }
    }

    private func browseDefaultDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            defaultDirField?.stringValue = url.path
            apply { settings.defaultDirectory = url.path }
        }
    }

    // ---------------------------------------------------------------- Shortcuts

    private func buildShortcutsPage() -> NSStackView {
        let p = page()
        shortcutsPanel = NSStackView()
        shortcutsPanel.orientation = .vertical
        shortcutsPanel.alignment = .leading
        shortcutsPanel.spacing = 2
        shortcutsPanel.translatesAutoresizingMaskIntoConstraints = false

        shortcutHint = Label.make("", size: 11.5,
                                  color: ChromeColors.rgb(0xD97757, alpha: 1), wraps: true)

        for action in Shortcuts.actions {
            let row = ShortcutRow(action: action,
                                  binding: Shortcuts.binding(settings, action.id))
            row.onCapture = { [weak self] captured in
                self?.applyShortcut(action: action, binding: captured, row: row)
            }
            row.onBeginCapture = { [weak self] in
                self?.capturingRow?.endCapture()
                self?.capturingRow = row
                self?.shortcutHint.stringValue = ""
            }
            shortcutsPanel.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: shortcutsPanel.widthAnchor).isActive = true
        }

        add(p, [
            sectionHeader("Keyboard shortcuts", first: true),
            description("Click a shortcut, then press the new key combination. Esc cancels. Shortcuts must include Cmd, Ctrl or Alt."),
            pad(shortcutsPanel, top: 0, bottom: 4, stretch: true),
            pad(shortcutHint, top: 6, bottom: 0),
            divider(),
        ])
        return p
    }

    private func applyShortcut(action: ShortcutAction, binding: String?, row: ShortcutRow) {
        capturingRow = nil
        guard let binding else { return }
        guard let combo = Shortcuts.parse(binding),
              !combo.modifiers.intersection([.command, .control, .option]).isEmpty else {
            shortcutHint.stringValue = "Shortcuts must include Cmd, Ctrl or Alt."
            return
        }
        // Reject a combination already taken by a different action.
        for other in Shortcuts.actions where other.id != action.id {
            if Shortcuts.parse(Shortcuts.binding(settings, other.id)) == combo {
                shortcutHint.stringValue = "\(binding) is already used by \(other.displayName)."
                return
            }
        }
        row.setBinding(binding)
        shortcutHint.stringValue = ""
        apply { settings.keybindings[action.id] = binding }
    }

    // ---------------------------------------------------------------- About

    private func buildAboutPage() -> NSStackView {
        let p = page()

        let logo = NSImageView()
        logo.image = App.logoImage
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            logo.widthAnchor.constraint(equalToConstant: 52),
            logo.heightAnchor.constraint(equalToConstant: 52),
        ])

        let text = NSStackView(views: [
            Label.make("Zharp", size: 16, weight: .semibold),
            Label.make("Version \(App.version)", size: 11.5, opacity: 0.55),
            Label.make("A fast, modern terminal for macOS - AppKit, Core Text GPU-composited rendering, a Unix pty host, and a custom VT emulator.",
                       size: 11.5, opacity: 0.55, wraps: true),
            Label.make("Icons: Tabler Icons (MIT) - tabler.io/icons", size: 11.5, opacity: 0.55),
        ])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 4
        text.translatesAutoresizingMaskIntoConstraints = false

        let about = NSStackView(views: [logo, text])
        about.orientation = .horizontal
        about.alignment = .top
        about.spacing = 16
        about.translatesAutoresizingMaskIntoConstraints = false

        updateStatusLabel = Label.make("Zharp \(App.version)", size: 11.5, opacity: 0.55, wraps: true)
        checkButton = PushButton(title: "Check now")
        checkButton.onClick = { [weak self] in
            guard let self else { return }
            self.checkForUpdates(button: self.checkButton)
        }

        let updateRow = NSView()
        updateRow.translatesAutoresizingMaskIntoConstraints = false
        let updateText = NSStackView(views: [Label.make("Check for updates", size: 13),
                                             updateStatusLabel])
        updateText.orientation = .vertical
        updateText.alignment = .leading
        updateText.spacing = 2
        updateText.translatesAutoresizingMaskIntoConstraints = false
        updateRow.addSubview(updateText)
        updateRow.addSubview(checkButton)
        NSLayoutConstraint.activate([
            updateText.leadingAnchor.constraint(equalTo: updateRow.leadingAnchor),
            updateText.topAnchor.constraint(equalTo: updateRow.topAnchor, constant: 8),
            updateText.bottomAnchor.constraint(equalTo: updateRow.bottomAnchor, constant: -8),
            updateText.trailingAnchor.constraint(lessThanOrEqualTo: checkButton.leadingAnchor,
                                                 constant: -16),
            checkButton.trailingAnchor.constraint(equalTo: updateRow.trailingAnchor),
            checkButton.centerYAnchor.constraint(equalTo: updateRow.centerYAnchor),
        ])

        let openFolder = PushButton(title: "Open folder")
        openFolder.onClick = {
            NSWorkspace.shared.open(AppSettings.supportDirectory)
        }

        add(p, [
            sectionHeader("About", first: true),
            pad(about, top: 8, bottom: 8),
            divider(),
            sectionHeader("Updates"),
            updateRow,
            divider(),
            sectionHeader("Configuration"),
            row("Settings file", "settings.json in ~/Library/Application Support/Zharp",
                openFolder),
            divider(),
        ])
        return p
    }

    private func checkForUpdates(button: PushButton) {
        updateStatusLabel.stringValue = "Checking…"
        Task { @MainActor in
            guard let latest = await UpdateService.latest(baseURL: settings.updateBaseUrl) else {
                updateStatusLabel.stringValue = "Could not reach the update server."
                return
            }
            if UpdateService.isNewer(latest, than: App.version) {
                updateStatusLabel.stringValue =
                    "Zharp \(latest) is available (you have \(App.version))."
                button.setTitle("Download")
                button.isAccent = true
                button.onClick = {
                    if let url = UpdateService.downloadURL { NSWorkspace.shared.open(url) }
                }
            } else {
                updateStatusLabel.stringValue = "Zharp \(App.version) is up to date."
            }
        }
    }

    // ---------------------------------------------------------------- controls

    /// Applies a settings mutation and persists it. Ignored until the page has
    /// finished populating its controls, so wiring them up can never write back
    /// (the `_ready` guard every Windows handler carries).
    private func apply(_ mutate: () -> Void) {
        guard ready else { return }
        mutate()
        settings.save()
        changed?()
    }

    /// Persists a setting nothing live reads, so the rest of the app is not
    /// asked to re-apply a change it cannot see.
    private func applyWithoutBroadcast(_ mutate: () -> Void) {
        guard ready else { return }
        mutate()
        settings.save()
    }

    private func combo(_ titles: [String], selected: Int, width: CGFloat,
                       action: @escaping (Int) -> Void) -> ActionPopUpButton {
        let popup = ActionPopUpButton(handler: action)
        popup.addItems(withTitles: titles)
        popup.selectItem(at: min(max(selected, 0), titles.count - 1))
        popup.font = NSFont.systemFont(ofSize: 13)
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.widthAnchor.constraint(equalToConstant: width).isActive = true
        return popup
    }

    private func toggle(_ on: Bool, action: @escaping (Bool) -> Void) -> ActionSwitch {
        let toggle = ActionSwitch(handler: action)
        toggle.state = on ? .on : .off
        return toggle
    }

    private func numberBox(value: Double, min minimum: Double, max maximum: Double,
                           step: Double, width: CGFloat,
                           action: @escaping (Double) -> Void) -> NumberBox {
        let box = NumberBox(value: value, minimum: minimum, maximum: maximum,
                            step: step, handler: action)
        box.widthAnchor.constraint(equalToConstant: width).isActive = true
        return box
    }

    private func fontFamilyCombo() -> NSView {
        // Every installed family, with the monospaced ones first - the Windows
        // build lists all system families and renders each in its own face.
        var families = NSFontManager.shared.availableFontFamilies.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        if !families.contains(where: { $0.caseInsensitiveCompare(settings.fontFamily) == .orderedSame }) {
            families.insert(settings.fontFamily, at: 0)
        }
        let monospaced = families.filter { isMonospaced($0) }
        let rest = families.filter { !isMonospaced($0) }
        let ordered = monospaced + rest

        let popup = ActionPopUpButton { [weak self] index in
            guard index < ordered.count else { return }
            self?.apply { self?.settings.fontFamily = ordered[index] }
        }
        for (index, family) in ordered.enumerated() {
            popup.addItem(withTitle: family)
            // Each entry renders in its own face (preview-in-list).
            if let item = popup.item(at: index), let font = NSFont(name: family, size: 13) {
                item.attributedTitle = NSAttributedString(string: family, attributes: [.font: font])
            }
        }
        let selected = ordered.firstIndex {
            $0.caseInsensitiveCompare(settings.fontFamily) == .orderedSame
        } ?? 0
        popup.selectItem(at: selected)
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.widthAnchor.constraint(equalToConstant: 220).isActive = true
        return popup
    }

    private func isMonospaced(_ family: String) -> Bool {
        guard let font = NSFont(name: family, size: 12) else { return false }
        return font.isFixedPitch
    }
}

/// A pop-up button that reports its selection to a closure.
final class ActionPopUpButton: NSPopUpButton {
    private let handler: (Int) -> Void

    init(handler: @escaping (Int) -> Void) {
        self.handler = handler
        super.init(frame: .zero, pullsDown: false)
        target = self
        action = #selector(fire)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    @objc private func fire() { handler(indexOfSelectedItem) }
}

/// A switch that reports its state to a closure.
final class ActionSwitch: NSSwitch {
    private let handler: (Bool) -> Void

    init(handler: @escaping (Bool) -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        target = self
        action = #selector(fire)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    @objc private func fire() { handler(state == .on) }
}

/// A numeric field with inline steppers - the NumberBox equivalent.
final class NumberBox: NSView {
    private let field = NSTextField()
    private let stepper = NSStepper()
    private let handler: (Double) -> Void

    init(value: Double, minimum: Double, maximum: Double, step: Double,
         handler: @escaping (Double) -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        field.font = NSFont.systemFont(ofSize: 13)
        field.alignment = .right
        field.stringValue = format(value)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.target = self
        field.action = #selector(fieldChanged)

        stepper.minValue = minimum
        stepper.maxValue = maximum
        stepper.increment = step
        stepper.doubleValue = value
        stepper.valueWraps = false
        stepper.translatesAutoresizingMaskIntoConstraints = false
        stepper.target = self
        stepper.action = #selector(stepperChanged)

        addSubview(field)
        addSubview(stepper)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor),
            field.topAnchor.constraint(equalTo: topAnchor),
            field.bottomAnchor.constraint(equalTo: bottomAnchor),
            field.trailingAnchor.constraint(equalTo: stepper.leadingAnchor, constant: -4),
            stepper.trailingAnchor.constraint(equalTo: trailingAnchor),
            stepper.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func setValue(_ value: Double) {
        let clamped = Swift.min(Swift.max(value, stepper.minValue), stepper.maxValue)
        stepper.doubleValue = clamped
        field.stringValue = format(clamped)
    }

    private func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    @objc private func fieldChanged() {
        let value = min(max(field.doubleValue, stepper.minValue), stepper.maxValue)
        stepper.doubleValue = value
        field.stringValue = format(value)
        handler(value)
    }

    @objc private func stepperChanged() {
        field.stringValue = format(stepper.doubleValue)
        handler(stepper.doubleValue)
    }
}

/// One rebindable shortcut: name on the left, a clickable key chip on the right
/// that captures the next combination pressed.
final class ShortcutRow: NSView {
    private let nameLabel: NSTextField
    private let chip = ChromeView(fill: .iconChip)
    private let chipLabel: NSTextField
    private var capturing = false
    private var monitor: Any?

    var onCapture: ((String?) -> Void)?
    var onBeginCapture: (() -> Void)?

    override var isFlipped: Bool { true }

    init(action: ShortcutAction, binding: String) {
        nameLabel = Label.make(action.displayName, size: 13)
        chipLabel = Label.make(Shortcuts.symbolic(binding), size: 12)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        chip.cornerRadius = 5
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(chipLabel)
        addSubview(nameLabel)
        addSubview(chip)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 32),
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            chip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            chip.centerYAnchor.constraint(equalTo: centerYAnchor),
            chip.heightAnchor.constraint(equalToConstant: 24),
            chipLabel.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 9),
            chipLabel.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -9),
            chipLabel.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func setBinding(_ binding: String) {
        chipLabel.stringValue = Shortcuts.symbolic(binding)
    }

    override func mouseDown(with event: NSEvent) {
        if capturing { return }
        onBeginCapture?()
        capturing = true
        chipLabel.stringValue = "Press keys…"
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.capture(event)
            return nil
        }
    }

    private func capture(_ event: NSEvent) {
        defer { endCapture() }
        if let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first,
           scalar.value == 0x1B {
            onCapture?(nil) // Esc cancels
            return
        }
        let vk = MacKeyMap.virtualKey(for: event)
        guard vk != 0,
              let binding = Shortcuts.format(modifiers: event.modifierFlags, virtualKey: vk) else {
            onCapture?(nil)
            return
        }
        onCapture?(binding)
    }

    func endCapture() {
        capturing = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if chipLabel.stringValue == "Press keys…" {
            chipLabel.stringValue = ""
        }
    }
}

/// The three input-position previews (classic / pinned bottom / pinned top).
final class InputPositionGridView: NSView {
    private var cards: [InputPositionCard] = []
    var onSelect: ((Int) -> Void)?

    /// Selects without notifying - used when re-reading shared settings.
    func setSelection(_ index: Int) {
        for card in cards { card.isSelected = card.mode == index }
    }

    override var isFlipped: Bool { true }

    init(selected: Int) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        for (index, title) in ["Classic", "Pinned bottom", "Pinned top"].enumerated() {
            let card = InputPositionCard(mode: index, title: title)
            card.isSelected = index == selected
            card.onClick = { [weak self] in
                for c in self?.cards ?? [] { c.isSelected = c.mode == index }
                self?.onSelect?(index)
            }
            cards.append(card)
            stack.addArrangedSubview(card)
        }

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }
}

final class InputPositionCard: NSView {
    let mode: Int
    private let title: String
    var isSelected = false { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    private var hovering = false
    private var trackingAreaRef: NSTrackingArea?

    override var isFlipped: Bool { true }

    init(mode: Int, title: String) {
        self.mode = mode
        self.title = title
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 112),
            heightAnchor.constraint(equalToConstant: 84),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { onClick?() }

    override func draw(_ dirtyRect: NSRect) {
        let swatch = NSRect(x: 4, y: 0, width: 104, height: 58)
        if isSelected || hovering {
            (isSelected ? Chrome.current.rowSelected : Chrome.current.rowHover).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        }

        Chrome.current.iconChip.setFill()
        let body = NSBezierPath(roundedRect: swatch, xRadius: 6, yRadius: 6)
        body.fill()
        NSColor(white: 0.5, alpha: 0.25).setStroke()
        body.lineWidth = 1
        body.stroke()

        func bar(_ y: CGFloat, _ w: CGFloat, prompt: Bool) {
            (prompt ? Chrome.current.barIcon
                    : Chrome.current.subtleIcon.withAlphaComponent(0.55)).setFill()
            NSBezierPath(roundedRect: NSRect(x: swatch.minX + 10, y: swatch.minY + y,
                                             width: w, height: 4),
                         xRadius: 2, yRadius: 2).fill()
        }

        switch mode {
        case 1: // pinned bottom: output above, prompt on the bottom edge
            bar(31, 66, prompt: false)
            bar(40, 54, prompt: false)
            bar(49, 42, prompt: true)
        case 2: // pinned top: prompt on top, a block divider, then output
            bar(9, 42, prompt: true)
            Chrome.current.sectionDivider.setFill()
            NSRect(x: swatch.minX + 6, y: swatch.minY + 19, width: 92, height: 1).fill()
            bar(24, 66, prompt: false)
            bar(33, 54, prompt: false)
        default: // classic: prompt at the top, output below
            bar(9, 42, prompt: true)
            bar(18, 66, prompt: false)
            bar(27, 54, prompt: false)
        }

        let label = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: Chrome.current.text,
        ])
        label.draw(at: NSPoint(x: (bounds.width - label.size().width) / 2, y: 63))
    }
}
