import AppKit
import ZharpCore

/// Title-bar strip: the gaps between the controls drag the window, exactly like
/// the Caption regions the Windows build declares on its frameless title bar.
final class TitleBarView: ChromeView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            window?.zoom(nil)
            return
        }
        super.mouseDown(with: event)
    }
}

/// The main window: a slim custom title bar over a vibrancy backdrop, sessions
/// in a sidebar or a top strip, and the active terminal filling the rest.
final class MainWindowController: NSWindowController, NSWindowDelegate {
    /// Shared with every other window: a change made here is what they read.
    let settings = App.settings

    /// Set while this window is adopting a torn-out tab, so the session it
    /// receives is not torn down as it leaves its old window.
    private var adopting = false
    private var restoreOnBuild = true

    private var sessions: [SessionItem] = []
    private var visibleSessions: [SessionItem] = []
    private var active: SessionItem?
    private var settingsItem: SessionItem?
    private var settingsView: SettingsView?

    private static let minSidebarWidth: CGFloat = 168
    private var terminalPalette = Palette.cream()

    // Chrome
    private let backdrop = NSVisualEffectView()
    private let root = ChromeView(fill: .wash)
    private let titleBar = TitleBarView(fill: .none)
    private var titleBarHeight: NSLayoutConstraint!
    private let sidebarHost = ChromeView(fill: .panelOverlay)
    private var sidebarWidth: NSLayoutConstraint!
    private let splitter = SidebarSplitterView()
    private let topStripHost = ChromeView(fill: .none)
    private var topStripHeight: NSLayoutConstraint!
    private let terminalHost = ChromeView(fill: .none)
    private let sessionList = SessionListView()
    private let sessionStrip = SessionListView()
    private let emptyState = ChromeView(fill: .none)
    private let tabSearchField = NSSearchField()
    /// Shown instead of the search box when tab search is off.
    private let sessionsLabel = Label.make("Sessions", size: 12, weight: .semibold)
    private let sidebarFooter = ChromeView(fill: .none)
    private let sidebarLogo = NSImageView()
    private let sidebarWordmark = Label.make("zharp", size: 12)
    private let sidebarVersion = Label.make("", size: 11, opacity: 0.45)
    private var updateBadge: UpdateBadgeButton!
    private var availableUpdate: String?
    private var updateTimer: Timer?

    private var sidebarToggle: IconButton!
    private var settingsButton: IconButton!
    private var searchButton: IconButton!
    private var newTabSidebarButton: IconButton!
    private var newTabStripButton: IconButton!

    private var searchOverlay: SearchOverlayView?
    private var onboardingOverlay: OnboardingView?

    private var keyMonitor: Any?

    /// The argument is deliberately not defaulted. `MainWindowController()`
    /// would bind to NSWindowController's inherited `init()` instead of this
    /// one, producing a controller with no window and no registration.
    convenience init(restoring: Bool) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Zharp"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.minSize = NSSize(width: 480, height: 340)
        window.center()
        self.init(window: window)
        window.delegate = self
        self.restoreOnBuild = restoring
        App.register(self)
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            App.lastActive = self
        }
        build()
    }

    // ---------------------------------------------------------------- layout

    private func build() {
        guard let window, let contentView = window.contentView else { return }

        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(backdrop)

        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)

        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: contentView.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            root.topAnchor.constraint(equalTo: contentView.topAnchor),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        buildTitleBar()
        buildContent()

        applyTheme()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                self?.applyTheme()
            }
        applySidebarDisplay()
        applyTabLayout()
        applyUiZoom()
        installKeyMonitor()

        if restoreOnBuild {
            restoreOrOpenFirstTab()
        }

        // Same hook the Windows build carries: opens Settings a few seconds in
        // so a screenshot pass can reach the page without driving the UI.
        if ProcessInfo.processInfo.environment["ZHARP_TEST_SETTINGS"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.openSettings()
            }
        }
        // Types a line into the active session through the real AppKit key
        // path (MacKeyMap -> TerminalInput -> pty), for end-to-end checks.
        if let script = ProcessInfo.processInfo.environment["ZHARP_TEST_INPUT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.typeForTesting(script)
            }
        }
        if ProcessInfo.processInfo.environment["ZHARP_TEST_SEARCH"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.toggleSearchOverlay()
            }
        }

        if !settings.onboarded {
            showOnboarding()
        }
        startUpdateChecks()

        // ZHARP_DEBUG_DUMP=<seconds> writes the active terminal's visible text
        // and the sidebar's state to the log - a textual screenshot, which
        // verifies rendering inputs precisely and works headless.
        if let delay = ProcessInfo.processInfo.environment["ZHARP_DEBUG_DUMP"],
           let seconds = Double(delay) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                self?.dumpStateForTesting()
            }
        }

        // ZHARP_TEST_BLOCKS=1 exercises the block interactions headlessly:
        // collapse one, highlight another, run a find, then jump.
        if ProcessInfo.processInfo.environment["ZHARP_TEST_BLOCKS"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 7) { [weak self] in
                self?.exerciseBlocksForTesting()
            }
        }

        // ZHARP_TEST_HISTORY=1 opens the history sheet with a synthesized
        // Arrow Up and reports what it did.
        if ProcessInfo.processInfo.environment["ZHARP_TEST_HISTORY"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                self?.exerciseHistoryForTesting()
            }
        }

        // ZHARP_TEST_TEAROUT=1 moves a live tab into a second window and
        // reports both windows' contents.
        if ProcessInfo.processInfo.environment["ZHARP_TEST_TEAROUT"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                self?.exerciseTearOutForTesting()
            }
        }

        // ZHARP_DEBUG_LAYOUT=1 dumps the chrome's geometry a moment after
        // launch - a blank window is otherwise indistinguishable from a
        // correctly drawn one in a screenshot.
        if ProcessInfo.processInfo.environment["ZHARP_DEBUG_LAYOUT"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, let window = self.window else { return }
                func f(_ label: String, _ v: NSView?) {
                    guard let v else { App.log("  \(label): nil"); return }
                    App.log("  \(label): frame=\(v.frame) hidden=\(v.isHidden) "
                            + "alpha=\(v.alphaValue) subviews=\(v.subviews.count)")
                }
                App.log("LAYOUT window=\(window.frame) visible=\(window.isVisible) "
                        + "opaque=\(window.isOpaque) alpha=\(window.alphaValue)")
                f("contentView", window.contentView)
                f("backdrop", self.backdrop)
                f("root", self.root)
                f("titleBar", self.titleBar)
                f("sidebarHost", self.sidebarHost)
                f("sidebarFooter", self.sidebarFooter)
                f("terminalHost", self.terminalHost)
                f("activeView", self.active?.view)
            }
        }
    }

    private func buildTitleBar() {
        titleBar.translatesAutoresizingMaskIntoConstraints = false
        titleBar.hairlineEdges = NSEdgeInsets(top: 0, left: 0, bottom: 1, right: 0)
        root.addSubview(titleBar)

        sidebarToggle = IconButton(glyph: Icons.sidebar)
        sidebarToggle.toolTip = "Toggle tab panel"
        sidebarToggle.onClick = { [weak self] in self?.toggleSidebar() }

        settingsButton = IconButton(glyph: Icons.settings)
        settingsButton.toolTip = "Settings"
        settingsButton.onClick = { [weak self] in self?.openSettings() }

        searchButton = IconButton(glyph: Icons.search)
        searchButton.toolTip = "Search"
        searchButton.onClick = { [weak self] in self?.toggleSearchOverlay() }

        let leftButtons = NSStackView(views: [sidebarToggle, settingsButton, searchButton])
        leftButtons.orientation = .horizontal
        leftButtons.spacing = 2
        leftButtons.translatesAutoresizingMaskIntoConstraints = false
        titleBar.addSubview(leftButtons)

        updateBadge = UpdateBadgeButton()
        updateBadge.isHidden = true
        updateBadge.toolTip = "A new version of Zharp is available"
        updateBadge.onClick = { [weak self] in self?.showUpdatePage() }
        titleBar.addSubview(updateBadge)

        titleBarHeight = titleBar.heightAnchor.constraint(equalToConstant: 34)
        NSLayoutConstraint.activate([
            titleBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            titleBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            titleBar.topAnchor.constraint(equalTo: root.topAnchor),
            titleBarHeight,
            // Clear the traffic lights: macOS draws close/minimize/zoom at the
            // left, where the Windows build puts nothing, so the control cluster
            // starts just after them and keeps the same left-to-right order.
            leftButtons.leadingAnchor.constraint(equalTo: titleBar.leadingAnchor, constant: 78),
            leftButtons.centerYAnchor.constraint(equalTo: titleBar.centerYAnchor),
            updateBadge.trailingAnchor.constraint(equalTo: titleBar.trailingAnchor, constant: -12),
            updateBadge.centerYAnchor.constraint(equalTo: titleBar.centerYAnchor),
            updateBadge.leadingAnchor.constraint(greaterThanOrEqualTo: leftButtons.trailingAnchor,
                                                 constant: 12),
        ])
    }

    private func buildContent() {
        sidebarHost.translatesAutoresizingMaskIntoConstraints = false
        sidebarHost.hairlineEdges = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 1)
        root.addSubview(sidebarHost)

        // Sidebar header: filter box + new-session button.
        tabSearchField.placeholderString = "Search tabs..."
        tabSearchField.font = NSFont.systemFont(ofSize: 11)
        tabSearchField.translatesAutoresizingMaskIntoConstraints = false
        tabSearchField.target = self
        tabSearchField.action = #selector(onTabSearchChanged)
        tabSearchField.sendsWholeSearchString = false
        tabSearchField.sendsSearchStringImmediately = true

        newTabSidebarButton = IconButton(glyph: Icons.plus, glyphSize: 17, side: 24)
        newTabSidebarButton.toolTip = "New session"
        newTabSidebarButton.onClick = { [weak self] in
            guard let self else { return }
            self.showNewTabMenu(from: self.newTabSidebarButton)
        }

        sessionsLabel.translatesAutoresizingMaskIntoConstraints = false
        sessionsLabel.textColor = Chrome.current.barIcon
        sessionsLabel.isHidden = true

        let header = NSStackView(views: [tabSearchField, sessionsLabel, newTabSidebarButton])
        header.orientation = .horizontal
        header.spacing = 3
        header.translatesAutoresizingMaskIntoConstraints = false
        sidebarHost.addSubview(header)

        buildSidebarFooter()

        sessionList.translatesAutoresizingMaskIntoConstraints = false
        sessionList.owner = self
        sessionList.dragController = makeDragController(for: sessionList)
        sessionList.onSelect = { [weak self] in
            self?.activate($0)
            // Clicking anywhere in the tab list (including the already-active
            // card) returns keyboard focus to the terminal - otherwise the row
            // keeps focus and typing goes nowhere.
            self?.active?.view?.focusTerminal()
        }
        sessionList.onClose = { [weak self] in self?.closeTab($0) }
        sidebarHost.addSubview(sessionList)

        splitter.translatesAutoresizingMaskIntoConstraints = false
        splitter.onDrag = { [weak self] delta in self?.dragSidebar(by: delta) }
        splitter.onDragEnded = { [weak self] in self?.persistSidebarWidth() }
        root.addSubview(splitter)

        // Top strip (horizontal tabs).
        topStripHost.translatesAutoresizingMaskIntoConstraints = false
        topStripHost.hairlineEdges = NSEdgeInsets(top: 0, left: 0, bottom: 1, right: 0)
        root.addSubview(topStripHost)

        sessionStrip.style = .pill
        sessionStrip.translatesAutoresizingMaskIntoConstraints = false
        sessionStrip.owner = self
        sessionStrip.dragController = makeDragController(for: sessionStrip)
        sessionStrip.onSelect = { [weak self] in
            self?.activate($0)
            self?.active?.view?.focusTerminal()
        }
        sessionStrip.onClose = { [weak self] in self?.closeTab($0) }
        topStripHost.addSubview(sessionStrip)

        newTabStripButton = IconButton(glyph: Icons.plus, glyphSize: 17, side: 24)
        newTabStripButton.toolTip = "New session (\(Shortcuts.symbolic(Shortcuts.binding(settings, "newTab"))))"
        newTabStripButton.onClick = { [weak self] in
            guard let self else { return }
            self.showNewTabMenu(from: self.newTabStripButton)
        }
        topStripHost.addSubview(newTabStripButton)

        terminalHost.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(terminalHost)

        buildEmptyState()

        sidebarWidth = sidebarHost.widthAnchor.constraint(equalToConstant: 230)
        topStripHeight = topStripHost.heightAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            sidebarHost.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebarHost.topAnchor.constraint(equalTo: titleBar.bottomAnchor),
            sidebarHost.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebarWidth,

            header.leadingAnchor.constraint(equalTo: sidebarHost.leadingAnchor, constant: 6),
            header.trailingAnchor.constraint(equalTo: sidebarHost.trailingAnchor, constant: -6),
            header.topAnchor.constraint(equalTo: sidebarHost.topAnchor, constant: 6),
            header.heightAnchor.constraint(equalToConstant: 26),

            sessionList.leadingAnchor.constraint(equalTo: sidebarHost.leadingAnchor),
            sessionList.trailingAnchor.constraint(equalTo: sidebarHost.trailingAnchor),
            sessionList.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 3),
            sessionList.bottomAnchor.constraint(equalTo: sidebarFooter.topAnchor),

            sidebarFooter.leadingAnchor.constraint(equalTo: sidebarHost.leadingAnchor),
            sidebarFooter.trailingAnchor.constraint(equalTo: sidebarHost.trailingAnchor),
            sidebarFooter.bottomAnchor.constraint(equalTo: sidebarHost.bottomAnchor),

            splitter.leadingAnchor.constraint(equalTo: sidebarHost.trailingAnchor, constant: -3),
            splitter.widthAnchor.constraint(equalToConstant: 6),
            splitter.topAnchor.constraint(equalTo: sidebarHost.topAnchor),
            splitter.bottomAnchor.constraint(equalTo: sidebarHost.bottomAnchor),

            topStripHost.leadingAnchor.constraint(equalTo: sidebarHost.trailingAnchor),
            topStripHost.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            topStripHost.topAnchor.constraint(equalTo: titleBar.bottomAnchor),
            topStripHeight,

            sessionStrip.leadingAnchor.constraint(equalTo: topStripHost.leadingAnchor, constant: 6),
            sessionStrip.topAnchor.constraint(equalTo: topStripHost.topAnchor),
            sessionStrip.bottomAnchor.constraint(equalTo: topStripHost.bottomAnchor),
            sessionStrip.trailingAnchor.constraint(equalTo: newTabStripButton.leadingAnchor,
                                                   constant: -4),
            newTabStripButton.trailingAnchor.constraint(equalTo: topStripHost.trailingAnchor,
                                                        constant: -6),
            newTabStripButton.centerYAnchor.constraint(equalTo: topStripHost.centerYAnchor),

            terminalHost.leadingAnchor.constraint(equalTo: sidebarHost.trailingAnchor),
            terminalHost.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            terminalHost.topAnchor.constraint(equalTo: topStripHost.bottomAnchor),
            terminalHost.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
    }

    /// Sidebar footer: the brand lockup (mark + wordmark) and the running
    /// version, over a hairline.
    private func buildSidebarFooter() {
        sidebarFooter.translatesAutoresizingMaskIntoConstraints = false
        sidebarFooter.hairlineEdges = NSEdgeInsets(top: 1, left: 0, bottom: 0, right: 0)
        sidebarHost.addSubview(sidebarFooter)

        sidebarLogo.imageScaling = .scaleProportionallyUpOrDown
        sidebarLogo.translatesAutoresizingMaskIntoConstraints = false

        // The wordmark is set in the brand face with its own tracking, which
        // NSTextField only honors through an attributed string.
        sidebarWordmark.translatesAutoresizingMaskIntoConstraints = false

        sidebarVersion.stringValue = App.version
        sidebarVersion.translatesAutoresizingMaskIntoConstraints = false

        let lockup = NSStackView(views: [sidebarLogo, sidebarWordmark])
        lockup.orientation = .horizontal
        lockup.spacing = 7
        lockup.alignment = .centerY
        lockup.translatesAutoresizingMaskIntoConstraints = false
        sidebarFooter.addSubview(lockup)
        sidebarFooter.addSubview(sidebarVersion)

        NSLayoutConstraint.activate([
            sidebarFooter.heightAnchor.constraint(equalToConstant: 32),
            sidebarLogo.heightAnchor.constraint(equalToConstant: 15),
            sidebarLogo.widthAnchor.constraint(equalToConstant: 15),
            lockup.leadingAnchor.constraint(equalTo: sidebarFooter.leadingAnchor, constant: 12),
            lockup.centerYAnchor.constraint(equalTo: sidebarFooter.centerYAnchor),
            sidebarVersion.trailingAnchor.constraint(equalTo: sidebarFooter.trailingAnchor,
                                                     constant: -12),
            sidebarVersion.centerYAnchor.constraint(equalTo: sidebarFooter.centerYAnchor),
            sidebarVersion.leadingAnchor.constraint(greaterThanOrEqualTo: lockup.trailingAnchor,
                                                    constant: 8),
        ])
        refreshBrandFooter()
    }

    /// Re-resolves the brand mark and wordmark for the active theme.
    private func refreshBrandFooter() {
        sidebarLogo.image = App.logoImage
        sidebarWordmark.attributedStringValue = NSAttributedString(string: "zharp", attributes: [
            .font: Icons.brandFont(size: 12),
            .foregroundColor: Chrome.current.brandForeground,
            // Windows sets CharacterSpacing 117, i.e. 0.117em.
            .kern: 12 * 0.117,
        ])
        sidebarVersion.textColor = Chrome.current.text.withAlphaComponent(0.45)
        sessionsLabel.textColor = Chrome.current.barIcon
    }

    private func buildEmptyState() {
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        emptyState.isHidden = true
        terminalHost.addSubview(emptyState)

        let logo = NSImageView()
        logo.image = App.logoImage
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.alphaValue = 0.85
        logo.translatesAutoresizingMaskIntoConstraints = false

        let caption = Label.make("No open sessions", size: 13, opacity: 0.55)
        caption.alignment = .center

        let button = PushButton(title: "New session", glyph: Icons.plus)
        button.onClick = { [weak self, weak button] in
            guard let self, let button else { return }
            self.showNewTabMenu(from: button)
        }

        let stack = NSStackView(views: [logo, caption, button])
        stack.orientation = .vertical
        stack.spacing = 14
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        emptyState.addSubview(stack)

        NSLayoutConstraint.activate([
            emptyState.leadingAnchor.constraint(equalTo: terminalHost.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: terminalHost.trailingAnchor),
            emptyState.topAnchor.constraint(equalTo: terminalHost.topAnchor),
            emptyState.bottomAnchor.constraint(equalTo: terminalHost.bottomAnchor),
            logo.widthAnchor.constraint(equalToConstant: 52),
            logo.heightAnchor.constraint(equalToConstant: 52),
            stack.centerXAnchor.constraint(equalTo: emptyState.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: emptyState.centerYAnchor),
        ])
    }

    /// Which Zharp window sits under a screen point, if any. Asked AFTER the
    /// drag ghost is closed - the ghost is a window too and would answer first.
    static func controller(under screenPoint: NSPoint) -> MainWindowController? {
        let number = NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0)
        guard number != 0 else { return nil }
        return App.windows.first { $0.window?.windowNumber == number }
    }

    /// Opens another terminal window, positioned clear of this one.
    @discardableResult
    static func openNewWindow(at origin: NSPoint? = nil,
                              size: NSSize? = nil) -> MainWindowController {
        let controller = MainWindowController(restoring: false)
        if let window = controller.window {
            if let size { window.setContentSize(size) }
            if let origin {
                window.setFrameOrigin(origin)
            } else if let previous = App.windows.dropLast().last?.window {
                window.setFrameOrigin(NSPoint(x: previous.frame.origin.x + 24,
                                              y: previous.frame.origin.y - 24))
            }
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        return controller
    }

    /// Snapshots the tabs of EVERY window, in window order. Taken once for the
    /// whole app: letting each window snapshot itself on the way out would
    /// leave only the last one's tabs behind.
    static func saveSessionSnapshot() {
        var saved: [SavedSession] = []
        var activeIndex = 0
        for window in App.windows {
            for item in window.sessions where !item.isSettings {
                if item === window.active { activeIndex = saved.count }
                saved.append(SavedSession(shell: item.shellId ?? "",
                                          directory: item.session?.workingDirectory ?? ""))
            }
        }
        App.settings.savedSessions = saved
        App.settings.savedActiveIndex = activeIndex
    }

    /// Re-applies settings another window changed.
    func applySharedSettings() {
        applyTheme()
        applySidebarDisplay()
        applyTabLayout()
        let cursorCode = AppSettings.cursorStyleToCode(settings.cursorStyle)
        for item in sessions {
            guard let session = item.session, let view = item.view else { continue }
            session.overrideNoColor = settings.overrideNoColor
            view.applyAppearance(fontFamily: settings.fontFamily, fontSize: settings.fontSize,
                                 cursorStyleCode: cursorCode)
            view.setInputPosition(AppSettings.inputPositionToCode(settings.inputPosition))
        }
        settingsView?.loadValues()
    }

    // ---------------------------------------------------------------- sessions

    /// Wires a list's drag gesture to reordering, hand-off and tear-out.
    private func makeDragController(for list: SessionListView) -> TabDragController {
        let controller = TabDragController(list: list)
        controller.onReorder = { [weak self, weak list] item, index in
            guard let self, let list else { return }
            list.moveRow(item, to: index)
            // Keep the model in the order the user is seeing.
            if let from = self.sessions.firstIndex(where: { $0 === item }) {
                let moved = self.sessions.remove(at: from)
                self.sessions.insert(moved, at: Swift.min(index, self.sessions.count))
            }
        }
        controller.onHandOff = { [weak self] item, target in
            self?.handOff(item, to: target)
        }
        controller.onTearOut = { [weak self] item, point in
            self?.tearOut(item, at: point)
        }
        return controller
    }

    /// Moves a live tab to another window, shell and scrollback intact.
    func handOff(_ item: SessionItem, to target: MainWindowController) {
        guard let released = release(item) else { return }
        target.adopt(released)
    }

    /// Moves a tab into a brand-new window under the pointer, sized like this
    /// one. A window emptied by the tear-out closes itself.
    func tearOut(_ item: SessionItem, at screenPoint: NSPoint) {
        guard sessions.contains(where: { $0 === item }) else { return }
        // A lone tab dragged out of its only window has nowhere to go.
        if sessions.filter({ !$0.isSettings }).count <= 1 { return }
        guard let released = release(item) else { return }

        let size = window?.frame.size ?? NSSize(width: 1280, height: 800)
        let origin = NSPoint(x: screenPoint.x - size.width / 3,
                             y: screenPoint.y - size.height + 40)
        let target = MainWindowController.openNewWindow(at: origin, size: size)
        target.adopt(released)
    }

    /// Detaches a tab WITHOUT tearing down its shell, so another window can
    /// take it over.
    private func release(_ item: SessionItem) -> SessionItem? {
        guard let index = sessions.firstIndex(where: { $0 === item }) else { return nil }
        // The exit handler belongs to this window; the new owner installs its own.
        item.session?.exited = nil
        item.view?.removeFromSuperview()
        sessions.remove(at: index)
        refreshVisibleSessions()

        if sessions.isEmpty {
            showEmptyState()
            // A window emptied by a tear-out closes itself.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.sessions.isEmpty, App.windows.count > 1 else { return }
                self.window?.close()
            }
        } else if active === item {
            activate(sessions[Swift.min(index, sessions.count - 1)])
        }
        return item
    }

    /// Takes over a tab released by another window.
    func adopt(_ item: SessionItem) {
        item.changed = { [weak self] in
            self?.sessionList.refreshLabels()
            self?.sessionStrip.refreshLabels()
        }
        item.session?.exited = { [weak self] _ in
            DispatchQueue.main.async { self?.closeTab(item) }
        }
        item.view?.isReservedShortcut = { [weak self] event in
            self?.matchedAction(for: event) != nil
        }
        item.view?.resolveBlockShortcut = { [weak self] event in
            self?.matchedTerminalAction(for: event)
        }
        item.view?.blockShortcutText = { [weak self] actionId in
            guard let self else { return nil }
            return Shortcuts.binding(self.settings, actionId)
        }
        item.setUiZoom(settings.uiZoom)
        item.view?.setUiZoom(settings.uiZoom)
        item.view?.setPalette(terminalPalette)
        sessions.append(item)
        refreshVisibleSessions()
        activate(item)
        window?.makeKeyAndOrderFront(nil)
    }

    /// New terminal tab. Nil shell = the configured default shell;
    /// nil directory = the configured default directory.
    func addTab(shellId: String? = nil, startDirectory: String? = nil) {
        let shell = ShellDiscovery.shell(for: shellId ?? settings.shell)
        let startDir = startDirectory ?? resolveDefaultDirectory()

        let session = TerminalSession(arguments: shell.arguments,
                                      workingDirectory: startDir,
                                      initialTitle: shell.displayName,
                                      scrollbackLines: settings.scrollbackLines)
        session.overrideNoColor = settings.overrideNoColor
        session.extraEnvironment = shell.extraEnvironment

        let view = TerminalView(session: session, fontSize: settings.fontSize,
                                fontFamily: settings.fontFamily)
        view.defaultCursorStyleCode = AppSettings.cursorStyleToCode(settings.cursorStyle)
        view.setPalette(terminalPalette)
        view.setUiZoom(settings.uiZoom)
        view.setInputPosition(AppSettings.inputPositionToCode(settings.inputPosition))
        view.isReservedShortcut = { [weak self] event in
            self?.matchedAction(for: event) != nil
        }
        // Block actions are rebindable but terminal-scoped: the window monitor
        // ignores them so an unbound or failed one still reaches the shell.
        view.resolveBlockShortcut = { [weak self] event in
            self?.matchedTerminalAction(for: event)
        }
        view.blockShortcutText = { [weak self] actionId in
            guard let self else { return nil }
            return Shortcuts.binding(self.settings, actionId)
        }

        let item = SessionItem(session: session, view: view, displayName: shell.displayName,
                               shellId: shellId)
        item.applyDisplayOptions(titleIsCwd: settings.sidebarTitleIsCwd,
                                 showPath: settings.sidebarShowPath)
        item.setUiZoom(settings.uiZoom)
        item.changed = { [weak self] in
            self?.sessionList.refreshLabels()
            self?.sessionStrip.refreshLabels()
        }

        session.exited = { [weak self] _ in
            DispatchQueue.main.async { self?.closeTab(item) }
        }

        sessions.append(item)
        refreshVisibleSessions()
        activate(item)
    }

    /// Reopens the tabs from the previous run, or opens a single fresh one.
    /// A saved directory that no longer exists falls back to the default, so a
    /// deleted project folder cannot stop the app from starting.
    private func restoreOrOpenFirstTab() {
        guard settings.restoreSessions, !settings.savedSessions.isEmpty else {
            addTab()
            return
        }

        for saved in settings.savedSessions {
            let directory = FileManager.default.fileExists(atPath: saved.directory)
                ? saved.directory
                : resolveDefaultDirectory()
            addTab(shellId: saved.shell.isEmpty ? nil : saved.shell,
                   startDirectory: directory)
        }
        if sessions.isEmpty {
            addTab()
            return
        }
        let index = min(max(settings.savedActiveIndex, 0), sessions.count - 1)
        activate(sessions[index])
    }

    /// Snapshots the open terminal tabs so the next launch can reopen them.
    private func saveOpenSessions() {
        let terminals = sessions.filter { !$0.isSettings }
        settings.savedSessions = terminals.map { item in
            SavedSession(shell: item.shellId ?? "",
                         directory: item.session?.workingDirectory ?? "")
        }
        settings.savedActiveIndex = active.flatMap { current in
            terminals.firstIndex { $0 === current }
        } ?? 0
    }

    private func resolveDefaultDirectory() -> String {
        if !settings.defaultDirectory.trimmingCharacters(in: .whitespaces).isEmpty,
           FileManager.default.fileExists(atPath: settings.defaultDirectory) {
            return settings.defaultDirectory
        }
        return NSHomeDirectory()
    }

    private func resolveLastLocation() -> String {
        if !settings.lastClosedDirectory.trimmingCharacters(in: .whitespaces).isEmpty,
           FileManager.default.fileExists(atPath: settings.lastClosedDirectory) {
            return settings.lastClosedDirectory
        }
        if let dir = active?.session?.workingDirectory,
           FileManager.default.fileExists(atPath: dir) {
            return dir
        }
        return resolveDefaultDirectory()
    }

    private func showNewTabMenu(from view: NSView) {
        let menu = NSMenu()
        func add(_ title: String, glyph: String, shortcut: String? = nil,
                 action: @escaping () -> Void) {
            let item = MenuItem(title: title, action: action)
            item.image = App.glyphImage(glyph, size: 16)
            if let shortcut, let combo = Shortcuts.parse(shortcut) {
                item.keyEquivalent = (Shortcuts.format(modifiers: [], virtualKey: combo.virtualKey)
                                      ?? "").lowercased()
                item.keyEquivalentModifierMask = combo.modifiers
            }
            menu.addItem(item)
        }

        add("Terminal", glyph: Icons.terminal,
            shortcut: Shortcuts.binding(settings, "newTab")) { [weak self] in self?.addTab() }
        add("Terminal at last location", glyph: Icons.terminal) { [weak self] in
            guard let self else { return }
            self.addTab(startDirectory: self.resolveLastLocation())
        }
        menu.addItem(.separator())
        for (id, name) in ShellDiscovery.availableShells() {
            add(name, glyph: Icons.shellGlyph(id)) { [weak self] in self?.addTab(shellId: id) }
        }

        let origin = NSPoint(x: 0, y: view.bounds.height + 4)
        menu.popUp(positioning: nil, at: origin, in: view)
    }

    func closeTab(_ item: SessionItem) {
        guard let index = sessions.firstIndex(where: { $0 === item }) else { return }

        if !item.isSettings, let lastDir = item.session?.workingDirectory, !lastDir.isEmpty {
            settings.lastClosedDirectory = lastDir
            settings.save()
        }

        if item.isSettings {
            // The settings view is kept cached; the tab just goes away.
            settingsItem = nil
        } else {
            item.view?.dispose()
            item.session?.dispose()
        }
        sessions.remove(at: index)

        if sessions.isEmpty {
            refreshVisibleSessions()
            showEmptyState()
            return
        }

        refreshVisibleSessions()
        if active === item {
            activate(sessions[min(index, sessions.count - 1)])
        }
    }

    /// All tabs are gone: keep the app open on a placeholder page.
    private func showEmptyState() {
        active = nil
        emptyState.isHidden = false
        for view in terminalHost.subviews where view !== emptyState {
            view.removeFromSuperview()
        }
        sessionList.setSelected(nil)
        sessionStrip.setSelected(nil)
    }

    func activate(_ item: SessionItem) {
        active = item
        emptyState.isHidden = true

        let content = item.content
        if content.superview !== terminalHost {
            for view in terminalHost.subviews where view !== emptyState {
                view.removeFromSuperview()
            }
            content.translatesAutoresizingMaskIntoConstraints = false
            terminalHost.addSubview(content)
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: terminalHost.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: terminalHost.trailingAnchor),
                content.topAnchor.constraint(equalTo: terminalHost.topAnchor),
                content.bottomAnchor.constraint(equalTo: terminalHost.bottomAnchor),
            ])
        }

        if let view = item.view {
            view.focusTerminal()
        } else {
            (content as? SettingsView)?.focusFirst()
        }

        sessionList.setSelected(item)
        sessionStrip.setSelected(item)
    }

    private func cycleSession(_ direction: Int) {
        guard sessions.count >= 2, let active,
              let index = sessions.firstIndex(where: { $0 === active }) else { return }
        let next = (index + direction + sessions.count) % sessions.count
        activate(sessions[next])
    }

    private func refreshVisibleSessions() {
        let filter = tabSearchField.stringValue.trimmingCharacters(in: .whitespaces)
        visibleSessions = sessions.filter { item in
            filter.isEmpty
                || item.title.range(of: filter, options: .caseInsensitive) != nil
                || item.subtitle.range(of: filter, options: .caseInsensitive) != nil
        }
        sessionList.setItems(visibleSessions, selected: active)
        sessionStrip.setItems(visibleSessions, selected: active)
    }

    @objc private func onTabSearchChanged() {
        refreshVisibleSessions()
    }

    // ---------------------------------------------------------------- tab layout

    private func applyTabLayout() {
        let sidebar = settings.useSidebar
        let tabsVisible = settings.sidebarVisible
        let sidebarShown = sidebar && tabsVisible
        let zoom = CGFloat(settings.uiZoom)

        sidebarHost.isHidden = !sidebarShown
        splitter.isHidden = !sidebarShown
        let width = min(max(CGFloat(settings.sidebarWidth) * zoom,
                            Self.minSidebarWidth * zoom), maxSidebarWidth())
        sidebarWidth.constant = sidebarShown ? width : 0

        let stripShown = !sidebar && tabsVisible
        topStripHost.isHidden = !stripShown
        topStripHeight.constant = stripShown ? 34 * zoom : 0
    }

    private func maxSidebarWidth() -> CGFloat {
        let rootWidth = root.bounds.width > 0 ? root.bounds.width : 1280
        return max(Self.minSidebarWidth, rootWidth / 2)
    }

    private func dragSidebar(by delta: CGFloat) {
        let zoom = CGFloat(settings.uiZoom)
        sidebarWidth.constant = min(max(sidebarWidth.constant + delta,
                                        Self.minSidebarWidth * zoom), maxSidebarWidth())
    }

    private func persistSidebarWidth() {
        // Stored width is zoom-independent (logical).
        settings.sidebarWidth = Double(sidebarWidth.constant / CGFloat(settings.uiZoom))
        settings.save()
    }

    private func clampSidebarWidth() {
        if sidebarWidth.constant <= 0 { return }
        let zoom = CGFloat(settings.uiZoom)
        let clamped = min(max(sidebarWidth.constant, Self.minSidebarWidth * zoom),
                          maxSidebarWidth())
        if abs(clamped - sidebarWidth.constant) > 0.5 {
            sidebarWidth.constant = clamped
        }
    }

    // ---------------------------------------------------------------- UI zoom

    private func changeUiZoom(_ direction: Int) {
        let zoom = direction == 0
            ? 1.0
            : (min(max(settings.uiZoom + Double(direction) * 0.1, 0.7), 1.5) * 100).rounded() / 100
        if abs(zoom - settings.uiZoom) < 0.001 { return }
        settings.uiZoom = zoom
        settings.save()
        applyUiZoom()
    }

    /// Whole-UI zoom WITHOUT transforms: the chrome multiplies its real metrics
    /// so everything re-renders crisply; terminals zoom via their font size.
    private func applyUiZoom() {
        let zoom = settings.uiZoom
        let z = CGFloat(zoom)

        titleBarHeight.constant = max(28, 34 * z)
        for button in [sidebarToggle, settingsButton, searchButton] {
            button?.setMetrics(side: 28 * z, glyphSize: 18 * z)
        }
        newTabSidebarButton.setMetrics(side: 24 * z, glyphSize: 17 * z)
        newTabStripButton.setMetrics(side: 24 * z, glyphSize: 17 * z)
        tabSearchField.font = NSFont.systemFont(ofSize: 11 * z)

        sessionList.zoom = zoom
        sessionStrip.zoom = zoom
        settingsView?.setZoom(zoom)

        for item in sessions {
            item.view?.setUiZoom(zoom)
            item.setUiZoom(zoom)
        }

        applyTabLayout()
        clampSidebarWidth()
        refreshVisibleSessions()
    }

    private func toggleSidebar() {
        settings.sidebarVisible.toggle()
        settings.save()
        applyTabLayout()
    }

    /// Applies sidebar card density and content settings.
    private func applySidebarDisplay() {
        sessionList.style = settings.sidebarCompact ? .compact : .card
        // With search off the sidebar shows a plain "Sessions" heading, and the
        // filter is cleared so hidden tabs cannot stay filtered out.
        let showSearch = settings.sidebarShowSearch
        tabSearchField.isHidden = !showSearch
        sessionsLabel.isHidden = showSearch
        if !showSearch, !tabSearchField.stringValue.isEmpty {
            tabSearchField.stringValue = ""
        }
        for item in sessions {
            item.applyDisplayOptions(titleIsCwd: settings.sidebarTitleIsCwd,
                                     showPath: settings.sidebarShowPath)
        }
        refreshVisibleSessions()
    }

    // ---------------------------------------------------------------- settings page

    func openSettings() {
        if settingsItem == nil {
            let view: SettingsView
            if let existing = settingsView {
                view = existing
            } else {
                view = SettingsView(settings: settings)
                view.changed = { [weak self] in self?.onSettingsChanged() }
                settingsView = view
                view.setZoom(settings.uiZoom)
            }
            let item = SessionItem(content: view, title: "Settings", subtitle: "Preferences",
                                   iconGlyph: Icons.settings)
            item.setUiZoom(settings.uiZoom)
            item.changed = { [weak self] in
                self?.sessionList.refreshLabels()
                self?.sessionStrip.refreshLabels()
            }
            settingsItem = item
            sessions.append(item)
            refreshVisibleSessions()
        }
        if let settingsItem { activate(settingsItem) }
    }

    /// Brings the window up and opens Settings on the About page.
    func showUpdatePage() {
        window?.makeKeyAndOrderFront(nil)
        openSettings()
        settingsView?.showAbout()
    }

    private func onSettingsChanged() {
        App.broadcastSettings(from: self)
        applyTheme()
        applySidebarDisplay()
        applyTabLayout()
        newTabStripButton.toolTip =
            "New session (\(Shortcuts.symbolic(Shortcuts.binding(settings, "newTab"))))"

        let cursorCode = AppSettings.cursorStyleToCode(settings.cursorStyle)
        for item in sessions {
            guard let session = item.session, let view = item.view else { continue }
            session.overrideNoColor = settings.overrideNoColor
            view.applyAppearance(fontFamily: settings.fontFamily, fontSize: settings.fontSize,
                                 cursorStyleCode: cursorCode)
            view.setInputPosition(AppSettings.inputPositionToCode(settings.inputPosition))
        }
    }

    /// Applies the color theme, backdrop material and background opacity.
    private func applyTheme() {
        let spec = Themes.get(settings.theme)
        let mode = Backdrop.parse(settings.backdrop).effective
        // With nothing translucent behind it, the wash must be fully opaque or
        // the theme color would blend with whatever sits underneath.
        Chrome.current = ChromeColors.make(
            spec, backgroundOpacity: mode.blurs ? settings.backgroundOpacity : 1.0)

        window?.appearance = NSAppearance(named: spec.isDark ? .darkAqua : .aqua)

        // Background blur, in macOS's own terms rather than Windows' Mica and
        // Acrylic. With blur off the window goes fully opaque, so the chrome
        // wash paints on a solid ground instead of over the desktop.
        backdrop.material = mode.material
        backdrop.isHidden = !mode.blurs
        // Leave the window's own opacity to AppKit while a behind-window
        // material is active - forcing isOpaque/backgroundColor here stops it
        // sampling the desktop. Only the opaque mode sets them.
        if mode.blurs {
            window?.isOpaque = false
            window?.backgroundColor = .clear
        } else {
            window?.isOpaque = true
            window?.backgroundColor = ChromeColors.rgb(spec.chromeBackground, alpha: 1)
        }

        terminalPalette = spec.createPalette()
        for item in sessions {
            item.view?.setPalette(terminalPalette)
        }

        ChromeRefresh.apply(to: root)
        refreshBrandFooter()
        updateBadge?.refreshChrome()
        searchOverlay?.refreshChrome()
        onboardingOverlay?.refreshChrome()
        settingsView?.refreshChrome()
        refreshVisibleSessions()
    }

    // ---------------------------------------------------------------- search palette

    private func toggleSearchOverlay() {
        if searchOverlay != nil {
            closeSearchOverlay()
        } else {
            openSearchOverlay()
        }
    }

    private func openSearchOverlay() {
        let overlay = SearchOverlayView(sessions: sessions)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.onPick = { [weak self] item in
            guard let self else { return }
            if self.sessions.contains(where: { $0 === item }) {
                self.activate(item)
            }
            self.closeSearchOverlay()
        }
        overlay.onDismiss = { [weak self] in self?.closeSearchOverlay() }
        root.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: root.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        searchOverlay = overlay
        overlay.focusSearchField()
    }

    private func closeSearchOverlay() {
        searchOverlay?.removeFromSuperview()
        searchOverlay = nil
        // Focus-first: move focus back before the overlay disappears.
        if let view = active?.view {
            view.focusTerminal()
        } else if let settings = active?.content as? SettingsView {
            settings.focusFirst()
        }
    }

    // ---------------------------------------------------------------- onboarding

    private func showOnboarding() {
        let overlay = OnboardingView(settings: settings)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.changed = { [weak self] in self?.onSettingsChanged() }
        overlay.finished = { [weak self] in
            guard let self else { return }
            self.active?.view?.focusTerminal()
            self.onboardingOverlay?.removeFromSuperview()
            self.onboardingOverlay = nil
        }
        root.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: root.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        onboardingOverlay = overlay
    }

    /// Synthesizes key events into the active terminal (test hook only).
    private func typeForTesting(_ script: String) {
        guard let view = active?.view, let window else { return }
        // Paced, not a tight loop: the shell has to echo each keystroke before
        // the next arrives, or Enter would capture a half-typed line - which is
        // a harness artifact, not something a person can type.
        var delay = 0.0
        for character in script {
            delay += 0.05
            let text = character == "\n" ? "\r" : String(character)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil,
                    characters: text, charactersIgnoringModifiers: text,
                    isARepeat: false, keyCode: 0) else { return }
                view.keyDown(with: event)
            }
        }
    }


    /// Drives the block features from code so they can be checked without a
    /// pointer: collapse, highlight, find and jump.
    private func exerciseBlocksForTesting() {
        guard let view = active?.view, let emu = active?.session?.emulator else { return }
        emu.syncRoot.lock()
        let marks = emu.getPromptMarks()
        let dropped = emu.buffer.droppedLines
        emu.syncRoot.unlock()
        App.log("TEST marks=\(marks)")
        guard marks.count >= 3 else {
            App.log("TEST not enough blocks")
            return
        }

        // Collapse the second block and highlight the first.
        view.collapsedKeys.insert(Int64(marks[1]) + dropped)
        view.selectedBlockKey = Int64(marks[0]) + dropped
        view.setNeedsDisplay(view.bounds)
        view.displayIfNeeded()
        App.log("TEST after collapse+select:")
        App.log(view.blockDebugState())

        // Copy the first block's command and output.
        emu.syncRoot.lock()
        let block = view.blockFromKey(Int64(marks[0]) + dropped, emu: emu)
        emu.syncRoot.unlock()
        if let block {
            emu.syncRoot.lock()
            let cmd = BlockText.command(emu, emu.buffer, block.start, block.end)
            let out = BlockText.output(emu, emu.buffer, block.start, block.end)
            let md = BlockText.markdown(emu, emu.buffer, block.start, block.end)
            emu.syncRoot.unlock()
            App.log("TEST command=[\(cmd)]")
            App.log("TEST output=[\(out)]")
            App.log("TEST markdown=[\(md.replacingOccurrences(of: "\n", with: "\\n"))]")
        }

        // Find inside the last finished block.
        view.openFind(key: Int64(marks[marks.count - 2]) + dropped)
        view.findFieldTextForTesting = "echo"
        view.recomputeFind()
        view.displayIfNeeded()
        App.log("TEST after find 'echo':")
        App.log(view.blockDebugState())

        _ = view.tryJumpBlocks(-1)
        view.displayIfNeeded()
        App.log("TEST after jump:")
        App.log(view.blockDebugState())
        view.closeFind()
    }

    /// Drives the history sheet from code: open it, step through entries, and
    /// report what landed at the prompt.
    private func exerciseHistoryForTesting() {
        guard let view = active?.view, let session = active?.session else { return }
        App.log("HIST store empty=\(HistoryStore.shared.isEmpty) "
                + "entries=\(HistoryStore.shared.query(limit: 20).map(\.command))")

        let opened = view.tryOpenHistory()
        view.displayIfNeeded()
        App.log("HIST opened=\(opened) isOpen=\(view.isHistoryOpen) "
                + "rows=\(view.historyRowCount) index=\(view.historyIndex) "
                + "inserted='\(view.historyInserted)'")
        App.log("HIST panel=\(view.historyPanelFrameForTesting)")

        // Up moves toward older entries; the preview retypes at the prompt.
        _ = view.handleHistoryKey(virtualKey: TerminalInput.VK_UP, anyModifier: false)
        view.displayIfNeeded()
        App.log("HIST after Up: index=\(view.historyIndex) inserted='\(view.historyInserted)'")

        // Escape erases the preview and closes.
        _ = view.handleHistoryKey(virtualKey: TerminalInput.VK_ESCAPE, anyModifier: false)
        App.log("HIST after Esc: isOpen=\(view.isHistoryOpen) "
                + "inserted='\(view.historyInserted)'")
        _ = session
    }

    /// Drives a tear-out from code: open a second tab, move it to a new window,
    /// then hand it back.
    private func exerciseTearOutForTesting() {
        addTab()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            App.log("TEAR before: windows=\(App.windows.count) tabs=\(self.sessions.count)")
            guard let victim = self.sessions.last(where: { !$0.isSettings }) else { return }
            let command = victim.session?.workingDirectory ?? "?"
            self.tearOut(victim, at: NSPoint(x: 700, y: 500))

            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                App.log("TEAR after: windows=\(App.windows.count) "
                        + "tabsHere=\(self.sessions.count) dir=\(command)")
                for (i, window) in App.windows.enumerated() {
                    App.log("  window \(i): \(window.sessions.count) tabs, "
                            + "titles=\(window.sessions.map(\.displayTitle))")
                }
                // Hand it back to prove a live session survives two moves.
                if App.windows.count > 1, let other = App.windows.last, other !== self,
                   let moved = other.sessions.first(where: { !$0.isSettings }) {
                    other.handOff(moved, to: self)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        App.log("TEAR returned: windows=\(App.windows.count) "
                                + "tabsHere=\(self.sessions.count)")
                    }
                }
            }
        }
    }

    /// Writes the visible terminal text and the sidebar's state to the log.
    private func dumpStateForTesting() {
        App.log("=== SIDEBAR (\(sessions.count) tabs) ===")
        for item in sessions {
            let mark = item === active ? "*" : " "
            App.log("\(mark) title=\(item.displayTitle) | sub=\(item.displaySubtitle) "
                    + "| agent=\(item.hasAgent ? item.agentGlyph : "-") "
                    + "| kind=\(item.kindLabel) | shell=\(item.shellId ?? "default")")
        }
        App.log("footer: \(sidebarWordmark.stringValue) \(sidebarVersion.stringValue) "
                + "| searchVisible=\(!tabSearchField.isHidden) "
                + "| updateBadge=\(!(updateBadge?.isHidden ?? true))")

        guard let emu = active?.session?.emulator else {
            App.log("=== no active terminal ===")
            return
        }
        emu.syncRoot.lock()
        let rows = emu.rows, cols = emu.cols
        let buffer = emu.buffer
        let first = buffer.scrollbackCount
        var lines: [String] = []
        for r in 0..<rows {
            let abs = first + r
            guard abs < buffer.totalLines else { break }
            var text = ""
            let cells = buffer.absoluteLine(abs).cells
            for c in 0..<Swift.min(cols, cells.count) {
                let cell = cells[c]
                if cell.flags.contains(.wideTrailing) { continue }
                if cell.rune == 0 { text.append(" ") }
                else if let u = UnicodeScalar(UInt32(cell.rune)) { text.unicodeScalars.append(u) }
            }
            while text.hasSuffix(" ") { text.removeLast() }
            lines.append(text)
        }
        let promptMarks = emu.getPromptMarks()
        let promptEnds = emu.getPromptEnds()
        emu.syncRoot.unlock()

        App.log("=== TERMINAL \(cols)x\(rows) marks=\(promptMarks) "
                + "ends=\(promptEnds.map { "\($0.line):\($0.col)" }) ===")
        for (i, line) in lines.enumerated() {
            App.log(String(format: "%3d|%@%@", i, line.isEmpty ? "" : " ", line))
        }
        if let view = active?.view {
            App.log("=== BLOCKS ===")
            App.log(view.blockDebugState())
        }
        App.log("=== END ===")
    }

    // ---------------------------------------------------------------- shortcuts

    /// Matches a key event against the rebindable shortcut table.
    func matchedAction(for event: NSEvent) -> String? {
        let vk = MacKeyMap.virtualKey(for: event)
        if vk == 0 { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        for action in Shortcuts.actions {
            // Block actions are resolved inside the focused terminal instead,
            // so a chord with no block to act on reaches the shell.
            if Shortcuts.isTerminalScope(action.id) { continue }
            guard let combo = Shortcuts.parse(Shortcuts.binding(settings, action.id)) else {
                continue
            }
            if combo.virtualKey == vk
                && combo.modifiers.intersection(.deviceIndependentFlagsMask) == flags {
                return action.id
            }
        }
        return nil
    }

    /// The terminal-scoped action a key event names, or nil.
    func matchedTerminalAction(for event: NSEvent) -> String? {
        let vk = MacKeyMap.virtualKey(for: event)
        if vk == 0 { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        for action in Shortcuts.actions where Shortcuts.isTerminalScope(action.id) {
            guard let combo = Shortcuts.parse(Shortcuts.binding(settings, action.id)) else {
                continue
            }
            if combo.virtualKey == vk
                && combo.modifiers.intersection(.deviceIndependentFlagsMask) == flags {
                return action.id
            }
        }
        return nil
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            // The search palette owns Escape and the arrows while it is open.
            if let overlay = self.searchOverlay, overlay.handleKey(event) { return nil }
            if let overlay = self.onboardingOverlay, overlay.handleKey(event) { return nil }
            if let action = self.matchedAction(for: event) {
                self.execute(action)
                return nil
            }
            return event
        }
    }

    /// Picks up the periodic update check when the owning window closes.
    func startUpdateChecksIfNeeded() {
        startUpdateChecks()
    }

    /// Runs a rebindable action by id (menu-bar entry point).
    func performShortcut(_ actionId: String) {
        execute(actionId)
    }

    /// Closes the active tab, if any (menu-bar entry point).
    func closeActiveTab() {
        if let active { closeTab(active) }
    }

    private func execute(_ actionId: String) {
        switch actionId {
        case "newTab": addTab()
        case "closeTab": if let active { closeTab(active) }
        case "nextTab": cycleSession(+1)
        case "prevTab": cycleSession(-1)
        case "toggleSidebar": toggleSidebar()
        case "openSettings": openSettings()
        case "toggleSearch": toggleSearchOverlay()
        case "zoomIn": changeUiZoom(+1)
        case "zoomOut": changeUiZoom(-1)
        case "zoomReset": changeUiZoom(0)
        case "copy": active?.view?.copySelection()
        case "paste": active?.view?.pasteFromClipboard()
        default: break
        }
    }

    // ---------------------------------------------------------------- update check

    /// First check 15s after launch, then hourly for as long as the app runs -
    /// a long-lived terminal would otherwise never learn about a release.
    /// Only one window runs the periodic check, or N windows would mean N
    /// checks and N notifications.
    private static weak var updateWatcher: MainWindowController?

    private func startUpdateChecks() {
        if let owner = Self.updateWatcher, owner !== self, App.windows.contains(where: { $0 === owner }) {
            return
        }
        Self.updateWatcher = self
        // ZHARP_FAKE_UPDATE=<version> raises the badge without a real release,
        // so the title-bar chrome can be checked on demand.
        if let fake = ProcessInfo.processInfo.environment["ZHARP_FAKE_UPDATE"], !fake.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.setAvailableUpdate(fake)
            }
            return
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15 * 1_000_000_000)
            await self?.checkForUpdate()
        }
        let timer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            Task { await self?.checkForUpdate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        updateTimer = timer
    }

    /// One update check: raises the title-bar badge, and notifies once per
    /// version so a new release does not nag on every tick.
    @MainActor
    private func checkForUpdate() async {
        guard let latest = await UpdateService.latest(baseURL: settings.updateBaseUrl) else {
            return
        }
        guard UpdateService.isNewer(latest, than: UpdateService.currentVersion) else {
            setAvailableUpdate(nil)
            return
        }
        setAvailableUpdate(latest)

        guard settings.lastNotifiedUpdate != latest else { return }
        UpdateService.notify(version: latest)
        // Recorded only after posting, so a failed notification retries later.
        settings.lastNotifiedUpdate = latest
        settings.save()
    }

    /// Shows or hides the title-bar badge for an available version.
    private func setAvailableUpdate(_ version: String?) {
        if availableUpdate == version { return }
        availableUpdate = version
        updateBadge.isHidden = version == nil
        settingsView?.setAvailableUpdate(version)
        updateTitleBarLayout()
    }

    /// The badge shares the title bar with the drag region, so its appearance
    /// changes what is draggable.
    private func updateTitleBarLayout() {
        titleBar.needsLayout = true
        titleBar.needsDisplay = true
    }

    // ---------------------------------------------------------------- shutdown

    func windowWillClose(_ notification: Notification) {
        // "Last location" must survive quitting the app with tabs still open,
        // not just tabs closed one by one.
        let lastTerminal = (active?.isSettings == false ? active : nil)
            ?? sessions.last { !$0.isSettings }
        sessionList.dragController?.cancel()
        sessionStrip.dragController?.cancel()
        if let dir = lastTerminal?.session?.workingDirectory, !dir.isEmpty {
            settings.lastClosedDirectory = dir
        }
        // During a whole-app quit the snapshot is taken once, across every
        // window; a single window closing takes it for the windows that remain.
        if !App.closingAll {
            App.unregister(self)
            Self.saveSessionSnapshot()
            settings.save()
            if Self.updateWatcher === self {
                Self.updateWatcher = nil
                App.windows.first?.startUpdateChecksIfNeeded()
            }
        } else {
            App.unregister(self)
        }

        for item in sessions {
            item.view?.dispose()
            item.session?.dispose()
        }
        sessions.removeAll()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    func windowDidResize(_ notification: Notification) {
        clampSidebarWidth()
    }
}

/// The 6pt grip on the sidebar's right edge.
final class SidebarSplitterView: NSView {
    var onDrag: ((CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?
    private var lastX: CGFloat = 0

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        lastX = event.locationInWindow.x
    }

    override func mouseDragged(with event: NSEvent) {
        let x = event.locationInWindow.x
        onDrag?(x - lastX)
        lastX = x
    }

    override func mouseUp(with event: NSEvent) {
        onDragEnded?()
    }
}

/// A menu item that runs a closure.
final class MenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not supported") }

    @objc private func fire() { handler() }
}

/// A flat push button matching the WinUI accent button used on the empty state.
final class PushButton: NSView {
    private let titleLabel: NSTextField
    private let glyphLabel: NSTextField?
    private var hovering = false
    private var trackingAreaRef: NSTrackingArea?

    var onClick: (() -> Void)?
    var isAccent = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    init(title: String, glyph: String? = nil, fontSize: CGFloat = 13) {
        titleLabel = Label.make(title, size: fontSize)
        glyphLabel = glyph.map { Label.icon($0, size: fontSize + 3) }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        let stack = NSStackView(views: [glyphLabel, titleLabel].compactMap { $0 })
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(equalTo: stack.widthAnchor, constant: 28),
            heightAnchor.constraint(equalToConstant: fontSize + 15),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func setTitle(_ title: String) { titleLabel.stringValue = title }

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
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        let fill: NSColor = isAccent
            ? Chrome.current.accent.withAlphaComponent(hovering ? 0.9 : 1.0)
            : (hovering ? Chrome.current.rowSelected : Chrome.current.iconChip)
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        Chrome.current.hairline.setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                  xRadius: 6, yRadius: 6)
        border.lineWidth = 1
        border.stroke()

        let color: NSColor = isAccent ? .white : Chrome.current.text
        titleLabel.textColor = color
        glyphLabel?.textColor = color
    }
}
