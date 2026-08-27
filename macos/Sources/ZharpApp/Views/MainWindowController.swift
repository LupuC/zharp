import AppKit
import UserNotifications
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
    private static let minDiffWidth: CGFloat = 320
    /// What the terminal keeps for itself no matter how wide the panel is
    /// dragged. The panel's ceiling is whatever is left over.
    private static let minTerminalWidth: CGFloat = 240
    private static let splitterGrip: CGFloat = 6
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
    private let diffPanel = DiffPanelView()
    private let diffSplitter = SidebarSplitterView()
    private var diffWidth: NSLayoutConstraint!
    private var diffButton: ChipButton!
    /// The repository the title-bar counts describe. git answers off the main
    /// thread, so a reply that lands after the session has moved on has to be
    /// recognised and dropped.
    private var totalsRepo: String?
    /// The directory the button was last resolved for, so a working-directory
    /// report that did not actually move does not run git again.
    private var diffButtonCwd: String?
    private var diffTotals = (added: 0, removed: 0)
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

        // ZHARP_TEST_DIFF=1 opens the changes panel through the real shortcut
        // path and reports the repository it found.
        if ProcessInfo.processInfo.environment["ZHARP_TEST_DIFF"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                self?.exerciseDiffForTesting()
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
                f("diffPanel", self.diffPanel)
                f("diffSplitter", self.diffSplitter)
                f("diffButton", self.diffButton)
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

        // Hidden until a session proves it is standing in a repository.
        diffButton = ChipButton(glyph: Icons.fileDiff)
        diffButton.isHidden = true
        diffButton.toolTip = "Changes"
        diffButton.onClick = { [weak self] in self?.toggleDiff() }

        updateBadge = UpdateBadgeButton()
        updateBadge.isHidden = true
        updateBadge.toolTip = "A new version of Zharp is available"
        updateBadge.onClick = { [weak self] in self?.showUpdatePage() }

        let rightButtons = NSStackView(views: [diffButton, updateBadge])
        rightButtons.orientation = .horizontal
        rightButtons.spacing = 8
        rightButtons.alignment = .centerY
        rightButtons.translatesAutoresizingMaskIntoConstraints = false
        titleBar.addSubview(rightButtons)

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
            rightButtons.trailingAnchor.constraint(equalTo: titleBar.trailingAnchor, constant: -12),
            rightButtons.centerYAnchor.constraint(equalTo: titleBar.centerYAnchor),
            rightButtons.leadingAnchor.constraint(greaterThanOrEqualTo: leftButtons.trailingAnchor,
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

        // The changes panel is built with the rest of the chrome rather than on
        // first open: hidden it costs a view tree and nothing else, since its
        // git poll only runs while it is actually on screen.
        diffPanel.isHidden = true
        diffPanel.onClose = { [weak self] in self?.toggleDiff() }
        diffPanel.setListHeight(settings.diffListHeight)
        diffPanel.onListHeightChanged = { [weak self] height in
            guard let self else { return }
            // Saved on release, like the panel's own width, rather than on
            // every frame of the drag.
            self.settings.diffListHeight = height
            self.settings.save()
        }
        diffPanel.onTotalsChanged = { [weak self] added, removed in
            // While the panel is open its own poll has the freshest numbers, so
            // the title bar takes them from here instead of running git twice.
            self?.applyDiffTotals(added, removed)
        }
        root.addSubview(diffPanel)

        diffSplitter.translatesAutoresizingMaskIntoConstraints = false
        diffSplitter.isHidden = true
        diffSplitter.onDrag = { [weak self] delta in self?.dragDiff(by: delta) }
        diffSplitter.onDragEnded = { [weak self] in self?.persistDiffWidth() }
        root.addSubview(diffSplitter)

        buildEmptyState()

        sidebarWidth = sidebarHost.widthAnchor.constraint(equalToConstant: 230)
        topStripHeight = topStripHost.heightAnchor.constraint(equalToConstant: 0)
        diffWidth = diffPanel.widthAnchor.constraint(equalToConstant: 0)

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

            // The terminal ends where the changes panel starts. Closed, the
            // panel is zero wide and this is the same as pinning to the root
            // edge; there is no repositioning to do beyond that, because the
            // active session is a real subview of terminalHost and reflows its
            // own pty when the host resizes.
            terminalHost.leadingAnchor.constraint(equalTo: sidebarHost.trailingAnchor),
            terminalHost.trailingAnchor.constraint(equalTo: diffPanel.leadingAnchor),
            terminalHost.topAnchor.constraint(equalTo: topStripHost.bottomAnchor),
            terminalHost.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            // Below the top strip, so the panel covers exactly the terminal's
            // vertical extent and the tab strip still spans the window.
            diffPanel.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            diffPanel.topAnchor.constraint(equalTo: topStripHost.bottomAnchor),
            diffPanel.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            diffWidth,

            diffSplitter.trailingAnchor.constraint(equalTo: diffPanel.leadingAnchor, constant: 3),
            diffSplitter.widthAnchor.constraint(equalToConstant: Self.splitterGrip),
            diffSplitter.topAnchor.constraint(equalTo: diffPanel.topAnchor),
            diffSplitter.bottomAnchor.constraint(equalTo: diffPanel.bottomAnchor),
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
        watchForChanges(item)
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
        showCodexTrustNotice(session)

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
        watchForChanges(item)

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
            // Before the teardown: the clock and the spool subscription both
            // outlive the views, and the spool is process wide.
            item.stopAgentClock()
            item.view?.dispose()
            item.session?.dispose()
        }
        sessions.remove(at: index)
        // Whatever this tab was waiting for, nobody is waiting for it now.
        Self.refreshDockBadge()

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
        // No session means no directory: nothing for the panel to be about.
        applyDiffStateForActive()
        updateDiffButton()
    }

    func activate(_ item: SessionItem) {
        active = item
        emptyState.isHidden = true

        // Looking at the tab is what clears its badge: whatever the agent
        // wants is now on screen in front of you.
        item.markSeen()

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

        applyDiffStateForActive()
        updateDiffButton()
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

        // Showing or hiding the sidebar moves what is left for the panel.
        clampDiffWidth()
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
        diffButton?.setMetrics(side: 28 * z, glyphSize: 18 * z)
        diffPanel.setUiZoom(zoom)
        applyDiffTotals(diffTotals.added, diffTotals.removed)

        for item in sessions {
            item.view?.setUiZoom(zoom)
            item.setUiZoom(zoom)
        }

        applyTabLayout()
        clampSidebarWidth()
        clampDiffWidth()
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

    // ---------------------------------------------------------------- changes panel

    private var isDiffOpen: Bool { !diffPanel.isHidden }

    /// The directory the panel and the button follow.
    ///
    /// Deliberately no fallback to some other session's directory: with one,
    /// the changes button turned up on the Settings page reporting a repository
    /// the visible page has nothing to do with.
    private func lastTerminalDirectory() -> String? {
        active?.session?.workingDirectory
    }

    private func toggleDiff() {
        if isDiffOpen {
            active?.diffOpen = false
            closeDiffPanel()
            return
        }
        // The Settings page has no working directory, so it has no repository.
        guard let active, !active.isSettings else { return }
        active.diffOpen = true
        openDiffPanel()
    }

    /// The one way in, for both the button and a tab switch, so both routes end
    /// up in the same state.
    private func openDiffPanel() {
        let ceiling = maxDiffWidth()
        // Under this there is no panel worth showing, only a sliver that would
        // take the terminal's width for nothing.
        if ceiling < 120 { return }

        let zoom = CGFloat(settings.uiZoom)
        diffWidth.constant = Swift.min(Swift.max(CGFloat(settings.diffPanelWidth) * zoom,
                                                 Swift.min(Self.minDiffWidth * zoom, ceiling)),
                                       ceiling)
        // Pointed at the directory BEFORE it is shown: unhiding is what starts
        // the panel's own refresh, and it should not spend its first tick
        // reading whatever repository it was left on.
        diffPanel.setWorkingDirectory(lastTerminalDirectory(), force: true)
        diffPanel.isHidden = false
        diffSplitter.isHidden = false
        diffButton.isHidden = false
    }

    /// Leaves the button alone: it is also the way back in, and the only way to
    /// close a panel that has been opened.
    private func closeDiffPanel() {
        diffWidth.constant = 0
        diffPanel.isHidden = true
        diffSplitter.isHidden = true
    }

    /// Runs synchronously on every tab switch, before any git call, so the panel
    /// never flashes the previous session's repository on its way to this one.
    private func applyDiffStateForActive() {
        guard let active, !active.isSettings, active.diffOpen else {
            if isDiffOpen { closeDiffPanel() }
            return
        }
        if isDiffOpen {
            // force: the panel is shared by every tab in the window, so
            // activating one has to re-read even when the directory is the
            // same. Without it two sessions in one repository would leave the
            // previous tab's diff on screen until the next poll tick.
            diffPanel.setWorkingDirectory(lastTerminalDirectory(), force: true)
            return
        }
        openDiffPanel()
    }

    private func maxDiffWidth() -> CGFloat {
        let rootWidth = root.bounds.width > 0 ? root.bounds.width : 1280
        return Swift.max(0, rootWidth - sidebarWidth.constant
                            - Self.minTerminalWidth - Self.splitterGrip)
    }

    /// The panel is anchored to the right edge, so dragging the grip LEFT is
    /// what widens it: the opposite sign from the sidebar's.
    private func dragDiff(by delta: CGFloat) {
        let zoom = CGFloat(settings.uiZoom)
        let ceiling = maxDiffWidth()
        diffWidth.constant = Swift.min(Swift.max(diffWidth.constant - delta,
                                                 Swift.min(Self.minDiffWidth * zoom, ceiling)),
                                       Swift.max(ceiling, 1))
    }

    private func persistDiffWidth() {
        // Stored width is zoom-independent (logical), like the sidebar's. Saved
        // on release rather than on every drag frame.
        settings.diffPanelWidth = Double(diffWidth.constant / CGFloat(settings.uiZoom))
        settings.save()
    }

    private func clampDiffWidth() {
        if !isDiffOpen { return }
        let zoom = CGFloat(settings.uiZoom)
        let ceiling = maxDiffWidth()
        let clamped = Swift.min(Swift.max(diffWidth.constant,
                                          Swift.min(Self.minDiffWidth * zoom, ceiling)),
                                Swift.max(ceiling, 0))
        if abs(clamped - diffWidth.constant) > 0.5 {
            diffWidth.constant = clamped
        }
    }

    /// Follows the active session in and out of repositories: whether the title
    /// bar carries a changes button at all is a property of where the prompt is
    /// standing.
    ///
    /// The panel is never closed from here. Whether it is open is the user's
    /// decision, and switching session, or stepping into a directory that is not
    /// a repository, is not them changing it. The panel says "not a git
    /// repository" for itself.
    private func updateDiffButton() {
        let cwd = lastTerminalDirectory()
        if (diffButtonCwd ?? "").caseInsensitiveCompare(cwd ?? "") == .orderedSame { return }
        diffButtonCwd = cwd

        guard let active, !active.isSettings else {
            diffButton.isHidden = true
            totalsRepo = nil
            applyDiffTotals(0, 0)
            return
        }

        Task { @MainActor in
            let repo = await GitStatus.discoverRepo(cwd)
            // The prompt may have moved on while git was answering. Whoever
            // asked last owns the button.
            guard (self.diffButtonCwd ?? "").caseInsensitiveCompare(cwd ?? "")
                    == .orderedSame else { return }

            // The button stays while the panel is open even outside a
            // repository, because hiding it would strand the panel with no way
            // to dismiss it.
            self.diffButton.isHidden = repo == nil && !self.isDiffOpen
            self.totalsRepo = repo
            if self.isDiffOpen { self.diffPanel.setWorkingDirectory(cwd) }

            guard let repo else {
                self.applyDiffTotals(0, 0)
                return
            }
            await self.readDiffTotals(repo)
        }
    }

    /// Re-reads what changed without re-resolving the repository, for when a
    /// command finishes in a directory that has not moved.
    private func refreshDiffTotals() {
        // The panel's own poll would get here within a couple of seconds, but a
        // command that just wrote to the tree is exactly the moment to look.
        if isDiffOpen { diffPanel.refresh(quiet: true) }
        guard let repo = totalsRepo else { return }
        Task { @MainActor in await self.readDiffTotals(repo) }
    }

    /// The whole repository's totals, read here rather than taken from the
    /// panel: the button is live whether or not the panel has ever been opened,
    /// so this has to work with nothing on screen.
    @MainActor
    private func readDiffTotals(_ repo: String) async {
        var added = 0
        var removed = 0
        for counts in await GitStatus.counts(repoRoot: repo).values {
            added += counts.added
            removed += counts.removed
        }
        // numstat says nothing about untracked files: git has nothing to compare
        // them against, so their whole content is counted directly.
        for change in await GitStatus.changes(repoRoot: repo) where change.kind == .untracked {
            added += await GitStatus.countUntracked(repoRoot: repo, path: change.path)
        }
        guard totalsRepo == repo else { return }
        applyDiffTotals(added, removed)
    }

    /// Paints the counts onto the chip in the terminal palette's own green and
    /// red (ANSI 2 and 1), so the title bar agrees with the panel and both
    /// follow the theme.
    private func applyDiffTotals(_ added: Int, _ removed: Int) {
        diffTotals = (added, removed)
        let any = added > 0 || removed > 0
        diffButton.toolTip = any ? "Changes  +\(added) -\(removed)" : "Changes"

        guard any else {
            diffButton.label = nil
            return
        }
        let font = NSFont.systemFont(ofSize: 11.5 * CGFloat(settings.uiZoom))
        let text = NSMutableAttributedString()
        if added > 0 {
            text.append(NSAttributedString(string: "+\(added)", attributes: [
                .font: font,
                .foregroundColor: ChromeColors.rgb(terminalPalette.colors[2], alpha: 1),
            ]))
        }
        if removed > 0 {
            text.append(NSAttributedString(string: added > 0 ? " -\(removed)" : "-\(removed)",
                                           attributes: [
                .font: font,
                .foregroundColor: ChromeColors.rgb(terminalPalette.colors[1], alpha: 1),
            ]))
        }
        diffButton.label = text
    }

    /// A session reports where it is and when it has finished a command, and
    /// both change what the panel should be showing. OSC 7 and OSC 133 already
    /// carry them, so nothing here polls.
    ///
    /// Everything here is window scoped, which is why it is re-pointed by
    /// `adopt` as well as set by `addTab`: a tab carries its shell between
    /// windows, and the panel, the badge and the Dock all belong to whichever
    /// window is holding it at the time.
    private func watchForChanges(_ item: SessionItem) {
        item.directoryChanged = { [weak self, weak item] _ in
            guard let self, let item, self.active === item else { return }
            self.updateDiffButton()
        }
        item.commandFinished = { [weak self, weak item] in
            guard let self, let item, self.active === item else { return }
            // A command can change the tree without moving the prompt, which is
            // the one case updateDiffButton() has nothing to say about.
            self.refreshDiffTotals()
        }
        item.attentionChanged = { [weak self] item in
            self?.onSessionAttentionChanged(item)
        }
        // The agent says which file it just wrote; the panel is what shows it.
        item.agentTouchedFile = { [weak self] item, path in
            self?.followAgentEdit(item, path)
        }
    }

    // ---------------------------------------------------------------- agent status

    /// Explains, once, that Codex is about to ask whether to trust the hooks
    /// Zharp just wrote.
    ///
    /// Codex will not run a hook it has not been told to trust, and that is a
    /// good rule, exactly because a program writing hooks into your agent is
    /// the case it guards. Zharp does not try to route around it. But a Codex
    /// tab that reports nothing looks broken rather than unapproved, so the
    /// user is told what to expect.
    ///
    /// Written into the emulator before the shell starts, while the screen is
    /// still empty. Feeding it later would land in the middle of a prompt line
    /// and corrupt it.
    private func showCodexTrustNotice(_ session: TerminalSession) {
        guard settings.agentIntegration else { return }
        guard let script = CodexIntegration.scriptPath else { return }
        if settings.codexNoticeFor == script { return }
        guard CodexIntegration.isConnected() else { return }

        session.emulator.feed(text: "\u{1b}[2mZharp installed status hooks for Codex. "
            + "Codex will ask you to trust them the next time it starts.\u{1b}[0m\r\n")

        settings.codexNoticeFor = script
        settings.save()
    }

    /// An agent in one of this window's tabs has started or stopped needing you.
    ///
    /// The tab card carries a badge for itself. This is about the case the
    /// badge cannot cover: the tab is not the one on screen, or Zharp is not
    /// the app you are looking at. Then it is worth saying so out loud, because
    /// the whole point of running several agents is not watching them.
    private func onSessionAttentionChanged(_ item: SessionItem) {
        // Both edges: the Dock mark counts what is still waiting, so it has to
        // come down again as well as go up.
        Self.refreshDockBadge()

        guard item.needsAttention else { return }

        // Already in front of them. The status line says the rest.
        if active === item, NSApp.isActive, window?.isKeyWindow == true {
            item.markSeen()
            return
        }

        // The tab always carries its badge. This is only about reaching you
        // somewhere else, which is exactly the part worth being able to switch
        // off, so it is the only part the setting governs.
        guard settings.agentNotifications else { return }

        // The conventional macOS "over here": the Dock icon bounces, then keeps
        // its mark until Zharp is brought forward. Deliberately not a window
        // that steals focus - the user is in the middle of something, and an
        // agent waiting is not an emergency.
        NSApp.requestUserAttention(.informationalRequest)
        notifyAgentWaiting(item)
    }

    /// Marks the Dock icon with how many sessions are waiting, across every
    /// window rather than this one.
    ///
    /// The Windows build flashes the taskbar and stops there. A Dock badge is
    /// the closer equivalent because it persists: the bounce is over in a
    /// second, and the case this exists for is an agent that got blocked while
    /// you were somewhere else entirely.
    static func refreshDockBadge() {
        let waiting = App.windows.reduce(0) { total, window in
            total + window.sessions.filter { $0.needsAttention }.count
        }
        NSApp.dockTile.badgeLabel = waiting > 0 ? String(waiting) : nil
    }

    private func notifyAgentWaiting(_ item: SessionItem) {
        // Read on the main thread; the authorization callback is not on it.
        let title = "\(item.sessionName) needs you"
        let body = "\(item.displaySubtitle) - \(item.subtitle)"

        // Keyed on the tab, so an agent that asks twice replaces its own
        // earlier line rather than stacking a pile from one session in
        // Notification Center. Unlike a Windows toast, these persist.
        let identifier = "zharp.agent.\(item.id)"
        let session = item.id

        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            // A notification is a courtesy. The tab badge and the Dock have
            // already said it, so a refusal is not worth reporting.
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            // Tagged so the click lands on this session. Without it every
            // notification Zharp raises goes to the same handler, and an agent
            // asking a question would open the update page.
            content.userInfo = [
                App.notificationAction: "agent",
                App.notificationSession: session,
            ]
            center.add(UNNotificationRequest(identifier: identifier,
                                             content: content, trigger: nil))
        }
        App.log("agent notify: \(title) - \(body)")
    }

    /// Brings up the session a notification was raised for. The tab may have
    /// been dragged into another window, or closed outright, since it was
    /// posted, so the session is looked up rather than remembered.
    static func showAgentSession(_ id: Int) {
        for window in App.windows {
            guard let item = window.sessions.first(where: { $0.id == id }) else { continue }
            NSApp.activate(ignoringOtherApps: true)
            window.window?.makeKeyAndOrderFront(nil)
            window.activate(item)
            return
        }
    }

    /// Opens the file the agent just wrote, when this tab is the one on screen
    /// and its changes panel is open. Following a file in a tab you cannot see
    /// would move the panel out from under whatever you are actually reading.
    private func followAgentEdit(_ item: SessionItem, _ path: String) {
        guard active === item, isDiffOpen else { return }
        diffPanel.follow(path)
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
        // The panel reads as the same surface as the terminal, so it follows the
        // terminal's font as well as its colours. Both windows that share a
        // settings change come through here.
        diffPanel.setPalette(terminalPalette)
        diffPanel.setFontFamily(settings.fontFamily)

        ChromeRefresh.apply(to: root)
        refreshBrandFooter()
        updateBadge?.refreshChrome()
        searchOverlay?.refreshChrome()
        onboardingOverlay?.refreshChrome()
        settingsView?.refreshChrome()
        // After the walk: it re-resolves every label against the chrome text
        // colour, which is wrong for anything the palette owns.
        diffPanel.refreshChrome()
        diffButton?.refreshChrome()
        applyDiffTotals(diffTotals.added, diffTotals.removed)
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


    /// Opens the changes panel the way the shortcut does, reports what it found,
    /// then proves the open state belongs to the session rather than the window:
    /// a new tab should not inherit it, and going back should restore it.
    private func exerciseDiffForTesting() {
        let opened = active
        performShortcut("openDiff")
        App.log("TEST diff open=\(isDiffOpen) width=\(diffWidth.constant) "
                + "button=\(!diffButton.isHidden) cwd=\(lastTerminalDirectory() ?? "-")")

        // git runs off the main thread, so the panel has nothing to say yet.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            App.log("TEST diff totals=+\(self.diffTotals.added)/-\(self.diffTotals.removed)")
            App.log(self.diffPanel.debugState())

            self.addTab()
            App.log("TEST diff on new tab: open=\(self.isDiffOpen) "
                    + "flag=\(self.active?.diffOpen == true)")

            guard let opened else { return }
            self.activate(opened)
            App.log("TEST diff back on first tab: open=\(self.isDiffOpen) "
                    + "width=\(self.diffWidth.constant)")
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
                    + "| needs=\(item.needsAttention) "
                    + "| kind=\(item.kindLabel) | shell=\(item.shellId ?? "default")")
        }
        App.log("footer: \(sidebarWordmark.stringValue) \(sidebarVersion.stringValue) "
                + "| searchVisible=\(!tabSearchField.isHidden) "
                + "| updateBadge=\(!(updateBadge?.isHidden ?? true))")
        App.log("dock: badge=\(NSApp.dockTile.badgeLabel ?? "-") | appActive=\(NSApp.isActive)")
        if isDiffOpen {
            App.log("=== CHANGES ===")
            App.log(diffPanel.debugState())
        }

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
        case "openDiff": toggleDiff()
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
        // Closing a window does not take its views out of it, so the panel would
        // otherwise keep running git for a window nobody can see.
        closeDiffPanel()
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
            item.stopAgentClock()
            item.view?.dispose()
            item.session?.dispose()
        }
        sessions.removeAll()
        Self.refreshDockBadge()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Bringing the window forward is seeing what is in it. Without this a tab
    /// that was already the active one keeps its badge after you have answered
    /// the agent, because nothing else calls `activate` on it.
    func windowDidBecomeKey(_ notification: Notification) {
        active?.markSeen()
    }

    func windowDidResize(_ notification: Notification) {
        clampSidebarWidth()
        clampDiffWidth()
    }
}

/// The 6pt grip on the sidebar's right edge.
final class SidebarSplitterView: NSView {
    /// Which way the divider moves. `.vertical` is a divider you drag up and
    /// down, which is what separates the file list from the diff below it.
    enum Axis { case horizontal, vertical }

    var axis: Axis = .horizontal
    var onDrag: ((CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?
    private var last: CGFloat = 0

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: axis == .horizontal ? .resizeLeftRight : .resizeUpDown)
    }

    private func position(_ event: NSEvent) -> CGFloat {
        axis == .horizontal ? event.locationInWindow.x : event.locationInWindow.y
    }

    override func mouseDown(with event: NSEvent) {
        last = position(event)
    }

    override func mouseDragged(with event: NSEvent) {
        let now = position(event)
        onDrag?(now - last)
        last = now
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
