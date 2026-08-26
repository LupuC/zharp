import AppKit
import ZharpCore

/// One tab-list entry: either a terminal session (with live current-directory
/// subtitle, last-command title and AI agent detection) or an embedded page
/// like Settings.
final class SessionItem {
    private static let home = NSHomeDirectory()

    /// Status line shown after an agent finishes working.
    private static let doneStatus = "✓ Done"

    /// Spinner frames used by agent CLIs (Claude Code's asterisk family and
    /// friends). A status row starts with one of these and contains "…".
    private static let spinnerGlyphs = Set("·✢✳✶✻✽✦✧∗✱*+")

    private var subtitleValue: String
    private var titleIsCwd = false
    private var showPath = true
    private var zoom: Double = 1.0

    private var agent = -1
    private var agentStatus: String?
    private var agentWasBusy = false
    private var lastStatusScrape: TimeInterval = 0
    private var lastCommand: String?

    let session: TerminalSession?
    let view: TerminalView?

    /// What gets shown in the content area when this tab is active.
    let content: NSView

    /// Tabler glyph for the tab icon.
    let iconGlyph: String

    /// ShellDiscovery id this tab was opened with; nil = the default shell.
    /// Persisted so session restore reopens the same flavor.
    let shellId: String?

    /// Tabs are only ever created on the main thread, so a plain counter is
    /// enough where the Windows build reaches for an interlocked increment.
    private static var nextId = 0

    /// Identifies this tab to things outside the app that have to name it
    /// later, which today means a desktop notification's click target.
    let id: Int

    var isSettings: Bool { session == nil }

    /// Whether the changes panel is open for THIS session.
    ///
    /// There is one panel in the window, but the flag belongs to the session:
    /// each tab is its own workspace in its own repository, so opening the
    /// diff in one says nothing about what the others want to see.
    var diffOpen = false

    /// Fixed display name (shell name / page name).
    let title: String

    /// Raised on the main thread whenever a displayed value changed.
    var changed: (() -> Void)?

    /// Raised on the main thread when the shell reports a new directory (OSC 7).
    ///
    /// `session.workingDirectoryChanged` is a single closure and this item
    /// already owns it to keep the tab subtitle honest, so a second assignment
    /// elsewhere would silently drop the first. Anything else that cares hangs
    /// itself here instead.
    var directoryChanged: ((String) -> Void)?

    /// Raised on the main thread once a command has finished, which the
    /// emulator knows from the next prompt's OSC 133 mark. Same reason as
    /// `directoryChanged`: `session.commandExecuted` is already spoken for.
    var commandFinished: (() -> Void)?

    /// Raised on the main thread when this session starts or stops needing you.
    ///
    /// Single closure, with the same caveat as `directoryChanged`: the owning
    /// window takes it, and a second assignment would silently drop the first.
    var attentionChanged: ((SessionItem) -> Void)?

    /// Raised on the main thread with a file the agent just WROTE, for whoever
    /// wants to follow along. Same single-subscriber caveat.
    var agentTouchedFile: ((SessionItem, String) -> Void)?

    /// Abbreviated working directory ("~", "~/src/app") or a fixed caption.
    var subtitle: String {
        get { subtitleValue }
        set {
            if subtitleValue == newValue { return }
            subtitleValue = newValue
            changed?()
        }
    }

    /// Card name: the last command run in the session ("New session" until one
    /// runs), or the agent's name while an AI agent owns the tab.
    private var effectiveName: String {
        if agent >= 0 { return AgentKind.all[agent].name }
        return lastCommand ?? "New session"
    }

    /// Card first line, per the sidebar title-mode setting.
    var displayTitle: String {
        isSettings ? title : (titleIsCwd ? subtitleValue : effectiveName)
    }

    /// Card second line: a working agent's live status line
    /// ("Wants to run npm test · 12s"), else the usual counterpart of the first
    /// line.
    var displaySubtitle: String {
        if isSettings { return subtitleValue }
        if let agentStatus { return agentStatus }
        return titleIsCwd ? effectiveName : subtitleValue
    }

    /// Session name for the hover card.
    var sessionName: String { isSettings ? title : effectiveName }

    /// Kind row for the hover card: the shell name (the agent's full name
    /// already lives in the card title).
    var kindLabel: String { isSettings ? "Settings" : title }

    /// Logo glyph of the detected agent (brand icons in the font).
    var agentGlyph: String { agent >= 0 ? AgentKind.all[agent].glyph : "" }

    /// Badge color of the detected agent.
    var agentColor: NSColor? { agent >= 0 ? AgentKind.all[agent].color : nil }

    var hasAgent: Bool { agent >= 0 }

    var subtitleVisible: Bool { isSettings || showPath || agentStatus != nil }

    /// Overflow direction per line: paths keep their tail visible, commands and
    /// status lines keep their head.
    var titleTailFirst: Bool { isSettings || titleIsCwd }
    var subtitleTailFirst: Bool { isSettings || (agentStatus == nil && !titleIsCwd) }

    /// Compact text for horizontal pill tabs.
    var compactTitle: String { isSettings ? title : effectiveName }

    /// Dimmed while this tab is being carried in a drag. It lives on the item
    /// rather than on its row: the tab lists rebuild rows as items move, so
    /// anything written straight onto a row ends up dimming whichever tab
    /// inherits it.
    var dragOpacity: CGFloat = 1 {
        didSet {
            if abs(dragOpacity - oldValue) > 0.001 { changed?() }
        }
    }

    /// The raw title the shell set via OSC (full path etc.) - tooltip only.
    var nativeTitle: String { session?.title ?? title }

    /// Creates a terminal tab.
    init(session: TerminalSession, view: TerminalView, displayName: String,
         shellId: String? = nil) {
        self.session = session
        self.view = view
        self.content = view
        self.title = displayName
        self.shellId = shellId
        self.iconGlyph = Icons.terminal2
        self.subtitleValue = Self.abbreviate(session.workingDirectory)
        self.id = Self.makeId()

        session.workingDirectoryChanged = { [weak self] cwd in
            DispatchQueue.main.async {
                self?.subtitle = Self.abbreviate(cwd)
                self?.directoryChanged?(cwd)
            }
        }

        session.commandExecuted = { [weak self] command in
            DispatchQueue.main.async {
                guard let self else { return }
                // Each executed command is authoritative: launching an agent
                // sets the badge, running anything else clears it.
                var changedAny = self.setAgent(Self.detectAgentFromCommand(command))
                if self.lastCommand != command {
                    self.lastCommand = command
                    changedAny = true
                }
                HistoryStore.shared.add(command: command,
                                        directory: session.workingDirectory,
                                        shell: self.title)
                if changedAny { self.changed?() }
                self.commandFinished?()
            }
        }

        session.titleChanged = { [weak self] title in
            DispatchQueue.main.async {
                guard let self else { return }
                // Titles only SET an agent (a matching name proves one runs).
                // They never clear: agents like Claude Code replace the title
                // with a task summary that carries no product name.
                if let detected = AgentKind.detect(in: title), self.setAgent(detected) {
                    self.changed?()
                }
            }
        }

        session.addOutputObserver { [weak self] in
            // Live agent status ("✳ Infusing… (10s · ↓ 452 tokens)"): scrape the
            // visible screen for the spinner row, throttled, only while an agent
            // is active. Runs on the pty thread; UI via the main queue.
            //
            // Only until the agent introduces itself. Once one is reporting its
            // own state there is nothing here worth reading: the screen can say
            // that it is busy, and never that it is waiting on you.
            guard let self, self.agent >= 0, !self.reports else { return }
            let now = Date().timeIntervalSince1970
            if now - self.lastStatusScrape < 0.25 { return }
            self.lastStatusScrape = now
            let status = Self.scrapeAgentStatus(session.emulator)
            DispatchQueue.main.async { self.applyAgentStatus(status) }
        }

        session.agentReported = { [weak self] payload in
            // Parsed off the pty thread, so a malformed payload costs the
            // terminal nothing and never reaches the main queue at all.
            guard let report = AgentReport.parse(payload) else { return }
            DispatchQueue.main.async { self?.applyReport(report) }
        }

        session.promptReturned = { [weak self] in
            DispatchQueue.main.async { self?.agentFinished() }
        }

        // Already on the main thread: keystrokes arrive there.
        session.userTyped = { [weak self] in
            self?.userTyped()
        }

        // The other transport. Agents that cannot write to the terminal drop
        // their reports in a directory instead, and the spool routes the ones
        // carrying this session's key here. Same report and the same handler
        // from here on: the two differ only in how they travelled.
        AgentSpool.shared.addObserver(session: session.sessionKey) { [weak self] report in
            self?.applyReport(report)
        }
    }

    /// Creates an embedded-page tab (e.g. Settings).
    init(content: NSView, title: String, subtitle: String, iconGlyph: String) {
        self.session = nil
        self.view = nil
        self.content = content
        self.title = title
        self.shellId = nil
        self.subtitleValue = subtitle
        self.iconGlyph = iconGlyph
        self.id = Self.makeId()
    }

    deinit {
        clock?.invalidate()
    }

    private static func makeId() -> Int {
        nextId += 1
        return nextId
    }

    // ------------------------------------------------------- reported status

    /// True once this session's agent has reported its own state at least once.
    /// From then on the screen scrape is off for good, including across the
    /// quiet stretches between turns: falling back mid-session would let the
    /// two disagree, and the guess would win whenever it spoke last.
    private var reports = false

    /// The report's own words, without the elapsed time on the end.
    private var agentSummary: String?

    private var lastEvent: AgentEvent?

    /// When the current turn began, and when the current state began. Two marks
    /// because they answer different questions.
    private var turnStart: Date?
    private var stateSince: Date?

    /// Re-composes the status line once a second while the number on the end of
    /// it is still moving.
    private var clock: Timer?

    /// Whether the agent here is blocked on you rather than working. The one
    /// state worth showing on a tab you are not looking at.
    private(set) var needsAttention = false {
        didSet {
            if needsAttention == oldValue { return }
            changed?()
            attentionChanged?(self)
        }
    }

    /// You are looking at this tab, so it has stopped being news. The status
    /// line still says what the agent wants; only the badge goes, because a
    /// badge on the tab you are already reading is just decoration.
    func markSeen() {
        needsAttention = false
    }

    /// Typing into a session whose agent is waiting IS the answer to it. The
    /// badge is about a question you have not seen, and you are answering it;
    /// Zharp is the one holding the keyboard, so nothing has to be inferred
    /// from the agent's later tool calls.
    func userTyped() {
        needsAttention = false
    }

    /// The shell is back at its prompt, so nothing is running in the foreground
    /// and any agent this tab was showing has exited.
    ///
    /// The agent's own "session ended" hook is not enough on its own. It fires
    /// while the process is tearing down, which is the worst moment to ask it
    /// to write to the pty, and quitting an agent left a tab counting up
    /// "Working" forever. The prompt coming back cannot be missed, needs no
    /// cooperation from the agent, and works just as well for the agents that
    /// report nothing at all.
    ///
    /// Main thread.
    func agentFinished() {
        // Not gated on there being an agent index to clear. A report names its
        // own agent, and one Zharp carries no logo for is left without an index
        // on purpose, so a tab can be waiting on you while the index is still
        // -1. Gated on the index alone, the prompt coming back did nothing at
        // all in that case: the dot, the Dock count and the ticking clock all
        // stayed up for the rest of the session, which is the very thing this
        // is here to prevent.
        guard agent >= 0 || lastEvent != nil || needsAttention || agentStatus != nil else {
            return
        }
        clearAgentState()
        changed?()
    }

    /// Takes one report from the agent, whichever transport carried it. Main
    /// thread: it composes the status line and raises the display closures.
    func applyReport(_ report: AgentReport) {
        // Only a report that could only have come from a running turn proves
        // the agent narrates its whole life. Codex reports one thing, that it
        // is blocked, because every hook it runs costs a process; the rest of
        // its status still has to be read off the screen, and switching that
        // off after a single permission would leave the tab silent for the
        // rest of the session.
        switch report.event {
        case .permission, .idle, .error: break
        default: reports = true
        }

        lastEvent = report.event
        stateSince = Date()

        // A turn begins at the prompt. Everything after it is measured from
        // there, so "how long has this been going" survives the agent moving
        // from tool to tool.
        if report.event == .prompt || report.event == .start {
            turnStart = stateSince
        }

        if report.event == .end {
            // The agent is gone. The logo, the status line, the clock and any
            // standing request for attention go with it, whether or not this
            // tab was wearing a logo to begin with.
            clearAgentState()
            changed?()
            return
        }

        // The report names its own agent, so a tab launched in some way the
        // command sniffing cannot read still gets the right logo: through a
        // wrapper script, resumed by the shell's history, started by a task
        // runner. Being told beats inferring.
        //
        // An agent we carry no logo for keeps whatever badge it already had.
        // Clearing it would punish a new agent for being new, and its status
        // line still works either way.
        if let known = Self.indexOfAgent(named: report.agent), setAgent(known) {
            changed?()
        }

        // "Working" has nothing to say unless it is unsticking a stale "waiting
        // for you". The line already on screen is the more specific one, and
        // the batch that just resolved is usually the very edit it names.
        let wasBlocked = needsAttention
        let keepSpecificLine =
            report.event == .working && !wasBlocked && agentSummary != nil

        if !keepSpecificLine {
            agentSummary = report.summary.isEmpty ? nil : report.summary
        }

        refreshAgentClock()

        // Announced after the line is composed, unlike the Windows build, so a
        // listener building a notification out of this card quotes what the
        // report just said rather than what it replaced.
        needsAttention = report.needsAttention

        if let path = report.path, !path.isEmpty {
            agentTouchedFile?(self, path)
        }
    }

    /// Puts the elapsed time on the end of the status line, and keeps it moving.
    ///
    /// Which span is shown depends on what the agent is doing, because the
    /// useful number is different in each case. While it works, the question is
    /// how long the turn has been going. While it is blocked, the question is
    /// how long it has been sitting there waiting for you. When it finishes,
    /// the question is how long the whole thing took.
    private func refreshAgentClock() {
        guard let summary = agentSummary else {
            stopClock()
            setAgentStatus(nil)
            return
        }

        if let elapsed = elapsedLabel() {
            setAgentStatus("\(summary) · \(elapsed)")
        } else {
            setAgentStatus(summary)
        }

        // "Done" is a finished measurement, so it stops rather than counting
        // on. A blocked agent keeps counting: the number growing is the point.
        switch lastEvent {
        case .prompt, .tool, .working, .permission, .idle, .error: startClock()
        default: stopClock()
        }
    }

    private func elapsedLabel() -> String? {
        var from: Date?
        switch lastEvent {
        // Measured from the prompt, through however many tools it took.
        case .prompt, .tool, .working, .done: from = turnStart

        // Measured from the moment it stopped being able to continue.
        case .permission, .idle, .error: from = stateSince

        // "Ready" has nothing to measure yet.
        default: from = nil
        }

        // No prompt seen: Zharp can start in the middle of somebody else's
        // turn. Falling back to this state's own start beats reporting the
        // time since the epoch.
        if from == nil, lastEvent != .start { from = stateSince }
        guard let from else { return nil }

        return Self.format(Date().timeIntervalSince(from))
    }

    /// Short enough for a tab card, and stable in width as it counts: the
    /// seconds are padded so the text does not shuffle every tick.
    private static func format(_ seconds: TimeInterval) -> String {
        let total = Int(Swift.max(0, seconds))
        if total < 60 { return "\(total)s" }
        if total < 3600 {
            return String(format: "%dm %02ds", total / 60, total % 60)
        }
        return String(format: "%dh %02dm", total / 3600, (total % 3600) / 60)
    }

    private func startClock() {
        if clock != nil { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshAgentClock()
        }
        // .common rather than the default mode: a plain timer stops dead while
        // a menu is tracking or the window is being resized, and a clock that
        // freezes while you drag the sidebar is worse than no clock.
        RunLoop.main.add(timer, forMode: .common)
        clock = timer
    }

    private func stopClock() {
        clock?.invalidate()
        clock = nil
    }

    /// The tab is closing. The run loop holds the clock, so without this it
    /// goes on firing for a tab nobody can see, and the spool is process wide
    /// and would otherwise hold on to every tab ever opened.
    ///
    /// Only for a tab that is going away for good. A tab dragged into another
    /// window keeps its shell, so it keeps both of these.
    func stopAgentClock() {
        stopClock()
        if let key = session?.sessionKey {
            AgentSpool.shared.removeObserver(session: key)
        }
    }

    // ---------------------------------------------------------------- colors

    private static let doneGreen = ChromeColors.rgb(0x3FB950, alpha: 1)

    // Amber has to carry on both a near-black and a cream background, and one
    // value cannot: the bright gold that reads as a warning on dark is barely
    // legible on paper.
    private static let waitingAmberDark = ChromeColors.rgb(0xF0B429, alpha: 1)
    private static let waitingAmberLight = ChromeColors.rgb(0xB06900, alpha: 1)

    /// Status line color: amber while the agent is waiting on you, green when
    /// it has finished, nil for the theme's own.
    var subtitleTint: NSColor? {
        if needsAttention {
            return Chrome.current.isDark ? Self.waitingAmberDark : Self.waitingAmberLight
        }
        if lastEvent == .done || agentStatus == Self.doneStatus { return Self.doneGreen }
        return nil
    }

    /// Bold only while the agent is blocked. The status line is glanced at, not
    /// read, so the one state that wants you to act is the one state that gets
    /// weight; making the rest bold would spend the emphasis on nothing.
    var subtitleBold: Bool { needsAttention }

    /// The second line is normally held back so the first one leads. A blocked
    /// agent is the exception: dimming the one line that is asking for
    /// something was undoing the color meant to make it stand out.
    var subtitleOpacity: CGFloat { needsAttention ? 1.0 : 0.55 }

    // ---------------------------------------------------------------- agents

    private func applyAgentStatus(_ spinner: String?) {
        let next: String?
        if let spinner {
            agentWasBusy = true
            next = spinner
        } else {
            // Spinner gone after a busy period = the agent finished a task.
            next = agentWasBusy ? Self.doneStatus : nil
        }
        setAgentStatus(next)
    }

    private func setAgentStatus(_ status: String?) {
        if agentStatus == status { return }
        agentStatus = status
        changed?()
    }

    @discardableResult
    private func setAgent(_ next: Int) -> Bool {
        if next == agent { return false }
        if next < 0 {
            clearAgentState()
        } else {
            agent = next
        }
        return true
    }

    /// Puts the tab back to being a plain shell: no logo, no live status, no
    /// badge, no clock, and the screen scrape allowed again for whatever runs
    /// next.
    ///
    /// Kept apart from `setAgent` because the two answer different questions.
    /// `setAgent` is about which logo the tab wears and returns early when that
    /// is already right; this is about everything the last agent left behind,
    /// which outlives the logo. A tab can be waiting on you wearing no logo at
    /// all, because a report names its own agent and one Zharp has no logo for
    /// is left alone on purpose. Folded together, every "the agent is gone"
    /// path had to remember to clear the badge a second time by hand, and the
    /// ones that forgot left it up for good.
    private func clearAgentState() {
        agent = -1

        // Drop the live status entirely, "Done" included. Nothing is waiting on
        // you in a tab that is back to being a shell, whether the agent said so
        // or the prompt came back on its own.
        agentWasBusy = false
        lastEvent = nil
        agentSummary = nil
        turnStart = nil
        stateSince = nil
        stopClock()
        setAgentStatus(nil)
        needsAttention = false

        // Reading the screen comes back for whatever runs next. Refusing to
        // fall back was about one agent's run, where a guess arriving after
        // a report would overrule it; across runs it would just mean that
        // starting an agent without hooks in this tab showed nothing at all.
        reports = false
    }

    private static func scrapeAgentStatus(_ emu: TerminalEmulator) -> String? {
        emu.syncRoot.lock()
        defer { emu.syncRoot.unlock() }
        let buffer = emu.buffer
        let total = buffer.totalLines
        let screenTop = Swift.max(0, total - emu.rows)
        var abs = total - 1
        while abs >= screenTop {
            let line = lineText(buffer, abs)
            abs -= 1
            guard line.count >= 3, let first = line.first,
                  spinnerGlyphs.contains(first) else { continue }
            guard line.contains("…") else { continue }
            return line.count > 70 ? String(line.prefix(70)) : line
        }
        return nil
    }

    private static func lineText(_ buffer: ScreenBuffer, _ abs: Int) -> String {
        let line = buffer.absoluteLine(abs)
        var out = ""
        for cell in line.cells {
            if cell.flags.contains(.wideTrailing) { continue }
            if cell.rune == 0 {
                out.append(" ")
            } else if let scalar = UnicodeScalar(UInt32(cell.rune)) {
                out.unicodeScalars.append(scalar)
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// The agent a report names, matched whole rather than by substring: this
    /// is the agent introducing itself, not a product name spotted in a window
    /// title, so "claude" is the answer and "claude-ish" is not.
    private static func indexOfAgent(named name: String) -> Int? {
        AgentKind.all.firstIndex { $0.match.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Agent launched directly: the command's first token (or the second, for
    /// launchers like npx) is the agent binary's name.
    private static func detectAgentFromCommand(_ command: String) -> Int {
        let tokens = command.split(separator: " ").map(String.init)
        for token in tokens.prefix(2) {
            let name = (token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'&"))
                as NSString).deletingPathExtension
            let leaf = (name as NSString).lastPathComponent
            for (index, agent) in AgentKind.all.enumerated()
            where leaf.caseInsensitiveCompare(agent.match) == .orderedSame {
                return index
            }
        }
        return -1
    }

    // ---------------------------------------------------------------- zoom

    var z11: CGFloat { 11 * zoom }
    var z12: CGFloat { 12 * zoom }
    var z13: CGFloat { 13 * zoom }
    var z14: CGFloat { 14 * zoom }
    var z15: CGFloat { 15 * zoom }
    var z16: CGFloat { 16 * zoom }
    var z20: CGFloat { 20 * zoom }
    var z24: CGFloat { 24 * zoom }
    var z26: CGFloat { 26 * zoom }
    /// Search-palette path column width.
    var z170: CGFloat { 170 * zoom }

    /// Chrome zoom factor for the card sizes.
    func setUiZoom(_ zoom: Double) {
        if abs(self.zoom - zoom) < 0.001 { return }
        self.zoom = zoom
        changed?()
    }

    /// Applies the sidebar display settings (title mode, path visibility).
    func applyDisplayOptions(titleIsCwd: Bool, showPath: Bool) {
        if self.titleIsCwd == titleIsCwd && self.showPath == showPath { return }
        self.titleIsCwd = titleIsCwd
        self.showPath = showPath
        changed?()
    }

    static func abbreviate(_ path: String?) -> String {
        guard let path, !path.trimmingCharacters(in: .whitespaces).isEmpty else { return "~" }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
