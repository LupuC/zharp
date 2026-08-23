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

    var isSettings: Bool { session == nil }

    /// Fixed display name (shell name / page name).
    let title: String

    /// Raised on the main thread whenever a displayed value changed.
    var changed: (() -> Void)?

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
    /// ("✳ Infusing… (10s · ↓ 452 tokens)"), else the usual counterpart of the
    /// first line.
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

    /// Green tint for the "Done" state; nil = the theme's own color.
    var subtitleTint: NSColor? {
        agentStatus == Self.doneStatus ? ChromeColors.rgb(0x3FB950, alpha: 1) : nil
    }

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

        session.workingDirectoryChanged = { [weak self] cwd in
            DispatchQueue.main.async { self?.subtitle = Self.abbreviate(cwd) }
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
            guard let self, self.agent >= 0 else { return }
            let now = Date().timeIntervalSince1970
            if now - self.lastStatusScrape < 0.25 { return }
            self.lastStatusScrape = now
            let status = Self.scrapeAgentStatus(session.emulator)
            DispatchQueue.main.async { self.applyAgentStatus(status) }
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
    }

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
        agent = next
        if next < 0 {
            // No agent: drop the live status entirely (including "Done").
            agentWasBusy = false
            setAgentStatus(nil)
        }
        return true
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
