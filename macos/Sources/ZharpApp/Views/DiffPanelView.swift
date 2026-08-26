import AppKit
import CoreText
import ZharpCore

/// The colours the changes panel draws with, all taken from the terminal's own
/// palette so a diff in gruvbox looks like gruvbox. ANSI 2 and 1 are the green
/// and red every theme defines, and are what git itself uses in the pane next
/// door.
struct DiffColors {
    var added: NSColor
    var removed: NSColor
    var body: NSColor
    /// Hunk gaps, `\ No newline`, the truncation notice.
    var meta: NSColor
    /// Dimmer than `meta` on purpose: the gutter is scaffolding, and it sits
    /// beside every single line.
    var gutter: NSColor
    /// The same wash the terminal drags over its own selection.
    var selection: NSColor

    /// Only ever seen before the first `setPalette`, which the window does as
    /// soon as it builds the panel. Matches the Windows placeholder brushes.
    static let placeholder = DiffColors(
        added: ChromeColors.rgb(0x2E8B57, alpha: 1),
        removed: ChromeColors.rgb(0xCD5C5C, alpha: 1),
        body: ChromeColors.rgb(0x808080, alpha: 1),
        meta: ChromeColors.rgb(0x808080, alpha: 1),
        gutter: ChromeColors.rgb(0x808080, alpha: 1),
        selection: ChromeColors.rgb(0xFFFFFF, alpha: Double(0x46) / 255.0))

    static func make(_ palette: Palette) -> DiffColors {
        DiffColors(
            added: ChromeColors.rgb(palette.colors[2], alpha: 1),
            removed: ChromeColors.rgb(palette.colors[1], alpha: 1),
            body: ChromeColors.rgb(palette.defaultForeground, alpha: 1),
            meta: ChromeColors.rgb(palette.defaultForeground, alpha: Double(0x77) / 255.0),
            gutter: ChromeColors.rgb(palette.defaultForeground, alpha: Double(0x4D) / 255.0),
            selection: ChromeColors.rgb(palette.selectionColor, alpha: Double(0x46) / 255.0))
    }
}

/// One rendered line of a diff: the number the gutter shows beside it (empty
/// for the rows that have none), the text exactly as git printed it including
/// its leading `+`, `-` or space, and the colour that marker earned it.
struct DiffLine {
    let number: String
    let text: String
    let color: NSColor
}

/// Read-only view of what has changed in the git repository the active session
/// is standing in, shown beside the terminal rather than instead of it.
///
/// Nothing here writes to the repository. There is no stage, no commit, no
/// discard: the terminal is one pane away and is better at all three. This
/// answers "what have I changed" without making you type `git diff` and lose
/// your place.
///
/// One panel serves every session, the way one sidebar does. What it shows
/// follows the active session's working directory, and where each repository
/// was left is remembered so switching tab and back does not drop you at the
/// top of the first file.
final class DiffPanelView: ChromeView {

    // ------------------------------------------------------------ public API

    /// Totals across every changed file, for the title bar's changes chip.
    var onTotalsChanged: ((Int, Int) -> Void)?
    /// The header's close button. The panel never closes itself.
    var onClose: (() -> Void)?

    private(set) var totalAdded = 0
    private(set) var totalRemoved = 0
    /// The repository being shown, machine included, or nil when the session is
    /// not inside one. A path on its own could not say which computer it is on,
    /// and every question below is asked of that computer.
    private(set) var repoRoot: SessionLocation?

    // ------------------------------------------------------------- constants

    /// Laying out a diff costs a Core Text pass per line, and past a couple of
    /// thousand that starts to be felt on open. A diff longer than this is one
    /// to read in the terminal.
    private static let maxLines = 1500

    /// How often the working tree is re-read while the panel is open. Slow
    /// enough that git is not being run constantly, fast enough that saving a
    /// file in an editor shows up without asking.
    private static let pollInterval: TimeInterval = 2

    /// The same idea over ssh, slowed down. Two seconds is chosen against the
    /// cost of running git on a local disk; the same rate against a machine
    /// across a network is a steady trickle of traffic and remote processes for
    /// a panel nobody may be looking at. Six seconds still catches a save
    /// before you have finished looking away.
    private static let remotePollInterval: TimeInterval = 6

    private static let headerHeight: CGFloat = 34
    /// A floor as well as a ceiling: the list sizes to its content, and without
    /// a floor a repository with three changed files sits at a different height
    /// from one with six, so everything below it moves every time the tab
    /// changes.
    private static let listMinHeight: CGFloat = 132
    private static let listMaxHeight: CGFloat = 196
    /// Floors for the dragged divider. The list keeps about two rows so it is
    /// still a list, and the diff keeps enough to show a hunk rather than a
    /// sliver that tells you nothing.
    private static let listDragFloor: CGFloat = 54
    private static let diffFloor: CGFloat = 120
    private static let rowHeight: CGFloat = 23

    // ----------------------------------------------------------------- views

    private let header = ChromeView(fill: .none)
    private let gitIcon = Label.icon(Icons.git, size: 14, color: Chrome.current.subtleIcon)
    /// Which machine this repository is on, shown only when that is not this
    /// one. A chip reading "local" on every session would be noise; a chip
    /// naming a server is the one fact that changes what everything below it
    /// means.
    private let hostChip = ChromeView(fill: .none)
    private let hostLabel = Label.make("", size: 10.5, opacity: 0.75)
    private let repoLabel = Label.make("", size: 12.5)
    private let branchLabel = Label.make("", size: 12, opacity: 0.55)
    private let copyButton = IconButton(glyph: Icons.copy, glyphSize: 15, side: 24)
    private let refreshButton = IconButton(glyph: Icons.refresh, glyphSize: 15, side: 24)
    private let closeButton = IconButton(glyph: Icons.close, glyphSize: 15, side: 24)

    private let listHost = ChromeView(fill: .none)
    private let listScroll = NSScrollView()
    private let rowsStack = NSStackView()

    private let diffScroll = NSScrollView()
    private let diffBody = DiffBodyView()

    private let emptyState = NSView()
    private let emptyTitle = Label.make("", size: 13, opacity: 0.8)
    private let emptyBody = Label.make("", size: 12, opacity: 0.5, wraps: true)

    private var headerHeight: NSLayoutConstraint!
    private var listHeight: NSLayoutConstraint!
    private let listSplitter = SidebarSplitterView()
    /// Set once the divider has been dragged. Until then the list sizes itself
    /// to how many files there are, which is the better default for a
    /// repository with two changes and for one with sixty.
    private var userListHeight: CGFloat?

    /// Fired when the divider is released, so the height can be persisted.
    var onListHeightChanged: ((Double) -> Void)?

    // ----------------------------------------------------------------- state

    private var pendingLocation: SessionLocation?
    private var changes: [GitFileChange] = []
    private var rows: [DiffFileRowView] = []
    private var selectedIndex = -1
    private var shownPath: String?
    private var shownDiff: String?

    private var colors = DiffColors.placeholder
    private var fontFamily = "SF Mono"
    private var zoom: CGFloat = 1

    /// Where each repository was left: which file was open, and how far down
    /// its diff. Keyed case-insensitively, like the paths git hands back.
    private var placeInRepo: [String: (path: String, scroll: CGFloat)] = [:]

    /// git runs off the main thread, so answers can land out of order. Every
    /// request carries the generation it was issued in and drops itself when a
    /// newer one has been issued since: that newer one paints.
    private var refreshGeneration = 0
    private var diffGeneration = 0

    private var poll: Timer?

    // ------------------------------------------------------------------ init

    init() {
        super.init(fill: .wash)
        translatesAutoresizingMaskIntoConstraints = false
        hairlineEdges = NSEdgeInsets(top: 0, left: 1, bottom: 0, right: 0)

        buildHeader()
        buildFileList()
        buildDiff()
        buildEmptyState()
        buildListSplitter()

        headerHeight = header.heightAnchor.constraint(equalToConstant: Self.headerHeight)
        listHeight = listHost.heightAnchor.constraint(equalToConstant: Self.listMinHeight)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.topAnchor.constraint(equalTo: topAnchor),
            headerHeight,

            listHost.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            listHost.trailingAnchor.constraint(equalTo: trailingAnchor),
            listHost.topAnchor.constraint(equalTo: header.bottomAnchor),
            listHeight,

            listSplitter.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            listSplitter.trailingAnchor.constraint(equalTo: trailingAnchor),
            listSplitter.topAnchor.constraint(equalTo: listHost.bottomAnchor),
            listSplitter.heightAnchor.constraint(equalToConstant: 6),

            diffScroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            diffScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            diffScroll.topAnchor.constraint(equalTo: listSplitter.bottomAnchor),
            diffScroll.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Over the list and the diff, not the header: losing the repository
            // should not also lose the thing naming it.
            emptyState.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            emptyState.trailingAnchor.constraint(equalTo: trailingAnchor),
            emptyState.topAnchor.constraint(equalTo: header.bottomAnchor),
            emptyState.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        applyTypography()
        showEmpty("No changes", "Nothing differs from HEAD.")
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        poll?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    private func buildHeader() {
        header.hairlineEdges = NSEdgeInsets(top: 0, left: 0, bottom: 1, right: 0)
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)

        hostChip.cornerRadius = 4
        hostChip.hairlineEdges = NSEdgeInsets(top: 1, left: 1, bottom: 1, right: 1)
        hostChip.translatesAutoresizingMaskIntoConstraints = false
        hostChip.isHidden = true
        hostChip.addSubview(hostLabel)
        NSLayoutConstraint.activate([
            hostLabel.leadingAnchor.constraint(equalTo: hostChip.leadingAnchor, constant: 5),
            hostLabel.trailingAnchor.constraint(equalTo: hostChip.trailingAnchor, constant: -5),
            hostLabel.topAnchor.constraint(equalTo: hostChip.topAnchor, constant: 1),
            hostLabel.bottomAnchor.constraint(equalTo: hostChip.bottomAnchor, constant: -2),
        ])

        let title = NSStackView(views: [gitIcon, hostChip, repoLabel, branchLabel])
        title.orientation = .horizontal
        title.spacing = 7
        title.alignment = .centerY
        title.translatesAutoresizingMaskIntoConstraints = false

        copyButton.toolTip = "Copy this file's diff"
        copyButton.setAccessibilityLabel("Copy diff")
        copyButton.onClick = { [weak self] in self?.copyWholeDiff() }
        refreshButton.toolTip = "Refresh"
        refreshButton.setAccessibilityLabel("Refresh")
        refreshButton.onClick = { [weak self] in self?.refresh() }
        // The Windows header has no close button: there the title bar chip is
        // the only way in and out. On macOS a docked panel that cannot be
        // dismissed from itself reads as stuck, and Cmd+Shift+D is not
        // something you find by looking.
        closeButton.toolTip = "Close changes"
        closeButton.setAccessibilityLabel("Close changes")
        closeButton.onClick = { [weak self] in self?.onClose?() }

        let buttons = NSStackView(views: [copyButton, refreshButton, closeButton])
        buttons.orientation = .horizontal
        buttons.spacing = 2
        buttons.alignment = .centerY
        buttons.translatesAutoresizingMaskIntoConstraints = false

        header.addSubview(title)
        header.addSubview(buttons)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 12),
            title.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor,
                                            constant: -8),
            buttons.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -6),
            buttons.centerYAnchor.constraint(equalTo: header.centerYAnchor),
        ])
    }

    /// The list already draws a hairline along its bottom edge, so the divider
    /// is a transparent grab strip straddling it rather than another line.
    private func buildListSplitter() {
        listSplitter.axis = .vertical
        listSplitter.translatesAutoresizingMaskIntoConstraints = false
        addSubview(listSplitter)

        listSplitter.onDrag = { [weak self] delta in
            guard let self else { return }
            // The window's y grows upward and the list grows downward, so a
            // drag toward the bottom of the screen has to lengthen the list.
            let proposed = self.listHeight.constant - delta
            self.userListHeight = proposed / self.zoom
            self.applyListHeight()
        }
        listSplitter.onDragEnded = { [weak self] in
            guard let self else { return }
            // Report what was actually applied, not what the pointer asked
            // for, so a drag past the floor does not persist an impossible
            // height that would be silently clamped on every later launch.
            self.userListHeight = self.listHeight.constant / self.zoom
            self.onListHeightChanged?(Double(self.listHeight.constant / self.zoom))
        }
    }

    /// Restores a height chosen on a previous run. Null means size to content.
    func setListHeight(_ height: Double?) {
        userListHeight = height.map { CGFloat($0) }
        applyListHeight()
    }

    private func buildFileList() {
        listHost.hairlineEdges = NSEdgeInsets(top: 0, left: 0, bottom: 1, right: 0)
        listHost.translatesAutoresizingMaskIntoConstraints = false
        addSubview(listHost)

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 2
        rowsStack.edgeInsets = NSEdgeInsets(top: 1, left: 4, bottom: 1, right: 4)
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        ScrollBox.configure(listScroll, document: rowsStack)
        listHost.addSubview(listScroll)
        NSLayoutConstraint.activate([
            listScroll.leadingAnchor.constraint(equalTo: listHost.leadingAnchor, constant: 4),
            listScroll.trailingAnchor.constraint(equalTo: listHost.trailingAnchor, constant: -4),
            listScroll.topAnchor.constraint(equalTo: listHost.topAnchor, constant: 4),
            listScroll.bottomAnchor.constraint(equalTo: listHost.bottomAnchor, constant: -4),
            rowsStack.widthAnchor.constraint(equalTo: listScroll.widthAnchor),
        ])
    }

    private func buildDiff() {
        ScrollBox.configure(diffScroll, document: diffBody)
        addSubview(diffScroll)
        NSLayoutConstraint.activate([
            diffBody.widthAnchor.constraint(equalTo: diffScroll.widthAnchor),
        ])

        diffBody.onCopySelection = { [weak self] in
            guard let self else { return }
            Self.putOnClipboard(self.diffBody.selectedText)
        }
        diffBody.onCopyAll = { [weak self] in self?.copyWholeDiff() }

        // Keeps the remembered place current as the user reads, so that a
        // switch away does not depend on catching them at the right moment.
        diffScroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(diffDidScroll),
            name: NSView.boundsDidChangeNotification, object: diffScroll.contentView)
    }

    private func buildEmptyState() {
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyState)

        emptyTitle.alignment = .center
        emptyBody.alignment = .center
        emptyBody.preferredMaxLayoutWidth = 272

        let stack = NSStackView(views: [emptyTitle, emptyBody])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        emptyState.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: emptyState.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: emptyState.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 272),
            emptyTitle.widthAnchor.constraint(lessThanOrEqualToConstant: 272),
            emptyBody.widthAnchor.constraint(lessThanOrEqualToConstant: 272),
        ])
    }

    // ------------------------------------------------------------- lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updatePolling()
    }

    override func viewDidHide() {
        super.viewDidHide()
        updatePolling()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updatePolling()
    }

    /// git only runs while the panel is actually on screen. A closed panel that
    /// kept polling would keep a repository warm for a view nobody can see, and
    /// over ssh it would keep a login open on somebody's server for it.
    private func updatePolling() {
        let live = window != nil && !isHiddenOrHasHiddenAncestor
        if !live {
            poll?.invalidate()
            poll = nil
            return
        }
        let wanted = pendingLocation?.isRemote == true
            ? Self.remotePollInterval : Self.pollInterval
        // A rate change means a new timer: a Timer's interval is fixed once it
        // is scheduled, so the only way to slow down for a session that has
        // moved to another machine is to replace it.
        if let poll, abs(poll.timeInterval - wanted) < 0.001 { return }

        poll?.invalidate()
        let timer = Timer(timeInterval: wanted, repeats: true) { [weak self] _ in
            self?.refresh(quiet: true)
        }
        // .common so the poll keeps running while the splitter is being dragged
        // or the diff is being scrolled.
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
        // Opening should not sit blank for a whole interval waiting for a tick.
        refresh(quiet: true)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    // ---------------------------------------------------------------- refresh

    /// Points the panel at wherever the active session is standing, which may
    /// be on another machine.
    ///
    /// `force` re-reads even when nothing has moved. The shell reports the same
    /// directory constantly through OSC 7, so the default is to ignore a
    /// repeat, but switching tabs is a different question: the panel is shared
    /// by the window, and the new session needs its own answer even when it
    /// happens to be standing in the same repository.
    func setLocation(_ place: SessionLocation?, force: Bool = false) {
        if !force, pendingLocation == place { return }
        rememberPlace()
        let moved = leavesShownRepository(place)
        pendingLocation = place
        // A session that has just changed machine changes how often the panel
        // is allowed to ask.
        updatePolling()
        // `git status` on a large working tree takes seconds, not milliseconds:
        // a cold read of a 1.2 GB tree measured 2.4s here, against 47ms warm.
        // Leaving the previous repository's files up for that whole time is
        // worse than showing nothing, because every one of them is being
        // attributed to a session standing somewhere else entirely. Blank as
        // soon as the ground moves and let the read fill it back in.
        if moved {
            setTotals(0, 0)
            repoRoot = nil
            // Whatever was being followed belonged to the repository we are
            // leaving, so it cannot be found in the one we are arriving at.
            following = nil
            repoLabel.stringValue = ""
            branchLabel.stringValue = ""
            showHost(place?.remote?.label)
            showEmpty("Reading changes", "Looking at \(shortName(place)).")
        }
        refresh()
    }

    /// True when `place` is outside the repository currently on screen, so what
    /// is displayed cannot possibly describe it. A move WITHIN the same
    /// repository keeps the view, since it still describes the right place and
    /// blanking it would only flicker.
    private func leavesShownRepository(_ place: SessionLocation?) -> Bool {
        guard let root = repoRoot else { return false }
        guard let place, place.hasPath else { return true }
        // A different machine is always a different repository, whatever the
        // paths look like: /home/me/app exists on both, which is the whole
        // reason the machine travels with the path.
        guard place.remote == root.remote else { return true }

        if place.isRemote {
            // Compared the way the far end would: POSIX arithmetic, case
            // sensitive, and nothing resolved against local disk. A tilde is
            // left alone here, so an unexpanded ~ counts as a move and the
            // read fills it back in, which is cheaper than being wrong.
            return place.path != root.path
                && PosixPath.relative(place.path, under: root.path) == nil
        }

        let normalised = (place.path as NSString).standardizingPath
        let rootPath = (root.path as NSString).standardizingPath
        return normalised != rootPath && !normalised.hasPrefix(rootPath + "/")
    }

    private func shortName(_ place: SessionLocation?) -> String {
        guard let place, place.hasPath else {
            return place?.remote?.label ?? "no directory"
        }
        return place.displayName
    }

    /// Re-reads the repository.
    ///
    /// `quiet` is the polling path: it leaves the list and the open diff alone
    /// unless something actually changed, so a refresh every two seconds is
    /// invisible rather than a blink.
    func refresh(quiet: Bool = false) {
        refreshGeneration += 1
        let generation = refreshGeneration
        let place = pendingLocation

        Task { @MainActor in
            let repo = await GitStatus.discoverRepo(place)
            guard generation == self.refreshGeneration else { return }
            self.repoRoot = repo

            guard let repo else {
                // Blank the header too. Leaving the old name up under "not a
                // git repository" reads as a contradiction.
                self.repoLabel.stringValue = ""
                self.branchLabel.stringValue = ""
                self.following = nil
                self.setTotals(0, 0)
                await self.showNothingHere(place, generation: generation)
                return
            }

            // Independent of each other, and each one is a process spawn, so
            // running them together halves the wait before anything appears.
            async let branchRead = GitStatus.currentBranch(repoRoot: repo)
            async let changesRead = GitStatus.changes(repoRoot: repo)
            let branch = await branchRead
            let fresh = await changesRead
            guard generation == self.refreshGeneration else { return }

            self.repoLabel.stringValue = repo.displayName
            self.showHost(repo.remote?.label)
            if let branch, !branch.isEmpty {
                self.branchLabel.stringValue = "on \(branch)"
            } else {
                self.branchLabel.stringValue = ""
            }

            if fresh.isEmpty {
                self.setTotals(0, 0)
                self.showEmpty("No changes", "Nothing differs from HEAD.")
                return
            }

            // Same paths in the same order and the same states means nothing to
            // rebuild. Only the counts can have moved, and those update in
            // place: rebuilding the list to refresh a number makes it blink and
            // jump, which is what a refresh used to look like.
            var sameFiles = self.changes.count == fresh.count
            if sameFiles {
                for (index, change) in fresh.enumerated()
                where self.changes[index].path != change.path
                    || self.changes[index].kind != change.kind {
                    sameFiles = false
                    break
                }
            }

            self.hideEmpty()
            if !sameFiles { self.adoptChanges(fresh) }

            // After the rows exist, and before the diff is read, so the read
            // below is the followed file's rather than a second one.
            self.selectFollowed()

            // Unlike Windows, the open file is re-read on every tick. Nothing
            // else notices an edit to the file already on screen, so without
            // this its +/- counts moved while its diff stayed stale.
            self.loadSelectedDiff()
            self.fillCounts(generation: generation, quiet: quiet)
        }
    }

    /// Swaps in a new file set, keeping the user on the file they were reading.
    private func adoptChanges(_ fresh: [GitFileChange]) {
        // Prefer the file this panel was showing, then the file this repository
        // was last left on, then the first.
        var wanted: String?
        if selectedIndex >= 0 && selectedIndex < changes.count {
            wanted = changes[selectedIndex].path
        } else if let repo = repoRoot {
            wanted = placeInRepo[Self.placeKey(repo)]?.path
        }

        changes = fresh
        rebuildRows()

        let keep = wanted.flatMap { want in rows.firstIndex { $0.change.path == want } } ?? 0
        setSelection(rows.isEmpty ? -1 : keep)

        // Only scroll when the wanted row is genuinely out of view: doing it
        // unconditionally put a small slide on every single tab switch.
        if keep > 0 && keep < rows.count {
            rows[keep].scrollToVisible(rows[keep].bounds)
        }
    }

    /// Builds the row views for the current change set. Also the zoom path: the
    /// rows carry zoom-scaled fonts and heights, so they are made again rather
    /// than adjusted.
    private func rebuildRows() {
        for view in rowsStack.arrangedSubviews {
            rowsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        rows.removeAll(keepingCapacity: true)

        // Labels that would collide get enough parent path to tell them apart.
        // Counted over the whole set, which is only knowable here rather than
        // on a row that can see nothing but itself.
        var byName: [String: Int] = [:]
        for change in changes {
            byName[(change.path as NSString).lastPathComponent.lowercased(), default: 0] += 1
        }

        for (index, change) in changes.enumerated() {
            let row = DiffFileRowView(change: change,
                                      label: Self.labelFor(change.path, byName: byName),
                                      zoom: zoom, colors: colors,
                                      height: Self.rowHeight * zoom)
            row.isSelected = index == selectedIndex
            row.onClick = { [weak self] in self?.selectRow(at: index) }
            rowsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor, constant: -8).isActive = true
            rows.append(row)
        }
        applyListHeight()
    }

    private func applyListHeight() {
        let count = CGFloat(rows.count)
        let content = count * Self.rowHeight * zoom + max(0, count - 1) * 2 + 2 + 8
        // The panel can be shorter than the constants assume, on a small window
        // or with the zoom turned up, so the ceiling comes from what is
        // actually on screen rather than from the constants alone.
        let available = bounds.height - Self.headerHeight * zoom - 6
        let floor = Self.listDragFloor * zoom
        let ceiling = max(floor, available - Self.diffFloor * zoom)

        if let chosen = userListHeight {
            listHeight.constant = min(max(chosen * zoom, floor), ceiling)
        } else {
            listHeight.constant = min(min(max(content, Self.listMinHeight * zoom),
                                          Self.listMaxHeight * zoom), ceiling)
        }
    }

    /// Reads each file's counts and fills them in as they arrive. Runs after
    /// the list is on screen: a repository with hundreds of changed files would
    /// otherwise show nothing until the last number had been read.
    private func fillCounts(generation: Int, quiet: Bool) {
        guard let repo = repoRoot else { return }

        Task { @MainActor in
            let numstat = await GitStatus.counts(repoRoot: repo)
            guard generation == self.refreshGeneration else { return }

            var added = 0
            var removed = 0
            for index in self.changes.indices {
                let change = self.changes[index]
                var pair = numstat[change.path]
                if pair == nil {
                    // Untracked paths are absent from numstat: git has nothing
                    // to compare them against. Their whole content is what a
                    // diff would show as added, so it is counted directly.
                    if change.kind == .untracked, !repo.isRemote {
                        pair = (added: await GitStatus.countUntracked(repoRoot: repo,
                                                                      path: change.path),
                                removed: 0)
                    } else if repo.isRemote {
                        // No per-file fallback across a network. Locally a diff
                        // per row is a process each and nobody notices; over
                        // ssh it is a round trip each, every poll, forever, to
                        // put small grey numbers beside rows the one numstat
                        // above already answered for. A row numstat did not
                        // mention has nothing to count.
                        pair = (added: 0, removed: 0)
                    } else {
                        let raw = await GitStatus.diff(repoRoot: repo, change: change) ?? ""
                        pair = GitStatus.countLines(Self.stripHeaders(raw))
                    }
                    guard generation == self.refreshGeneration,
                          index < self.changes.count else { return }
                }
                let counts = pair ?? (added: 0, removed: 0)
                added += counts.added
                removed += counts.removed

                // Quiet is the whole difference between a poll and a refresh:
                // a row only repaints when its numbers actually moved.
                let moved = self.changes[index].added != counts.added
                    || self.changes[index].removed != counts.removed
                self.changes[index].added = counts.added
                self.changes[index].removed = counts.removed
                if (moved || !quiet) && index < self.rows.count {
                    self.rows[index].setCounts(added: counts.added, removed: counts.removed)
                }
            }

            guard generation == self.refreshGeneration else { return }
            self.setTotals(added, removed)
        }
    }

    private func setTotals(_ added: Int, _ removed: Int) {
        if totalAdded == added && totalRemoved == removed { return }
        totalAdded = added
        totalRemoved = removed
        onTotalsChanged?(added, removed)
    }

    // ------------------------------------------------------------- following

    /// The repository-relative path the panel is trying to land on, and how
    /// many more reads it will wait for git to notice the write.
    private var following: String?
    private var followTries = 0

    /// Points the panel at a file an agent has just written.
    ///
    /// The panel follows the agent around rather than the other way about: an
    /// agent working through a task edits a handful of files over and over, and
    /// watching the diff appear is the whole reason the panel is open beside
    /// it.
    func follow(_ absolutePath: String) {
        guard let repo = repoRoot else { return }

        let relative: String
        if repo.isRemote {
            // An agent running over there reports that machine's paths, which
            // must not be standardised against this one: NSString would resolve
            // symlinks and a tilde on local disk and hand back an answer about
            // a filesystem the file is not on.
            guard let under = PosixPath.relative(absolutePath, under: repo.path) else { return }
            relative = under
        } else {
            let full = (absolutePath as NSString).standardizingPath
            let root = (repo.path as NSString).standardizingPath
            // Editing outside the repository on screen.
            guard full.hasPrefix(root + "/") else { return }
            relative = String(full.dropFirst(root.count + 1))
        }
        following = relative

        // git has not necessarily noticed the write yet, so the next couple of
        // reads get to look as well. Bounded because some writes never become a
        // change at all: an agent that rewrites a file with its own contents,
        // or writes into an ignored directory, would otherwise leave this
        // hunting for a row that is never coming.
        followTries = 3

        // Quiet, because the file set usually has not changed: editing a file
        // that was already changed leaves it identical, and a loud refresh
        // would rebuild the list under the user on every save.
        refresh(quiet: true)
    }

    /// Moves the selection onto the followed file once it is actually in the
    /// list.
    ///
    /// Separate from the rebuild because most of the time there is no rebuild:
    /// editing a file that was already changed leaves the file set identical,
    /// and the selection still has to move. Reading the diff is left to the
    /// caller, which does it for whatever is selected either way.
    private func selectFollowed() {
        guard let want = following, !want.isEmpty else { return }

        guard let index = rows.firstIndex(where: {
            $0.change.path.caseInsensitiveCompare(want) == .orderedSame
        }) else {
            followTries -= 1
            if followTries <= 0 { following = nil }
            return
        }

        following = nil
        setSelection(index)
        rows[index].scrollToVisible(rows[index].bounds)
    }

    // -------------------------------------------------------------- selection

    private func setSelection(_ index: Int) {
        selectedIndex = index
        for (position, row) in rows.enumerated() {
            row.isSelected = position == index
        }
    }

    private func selectRow(at index: Int) {
        if index == selectedIndex { return }
        setSelection(index)
        loadSelectedDiff()
    }

    private func loadSelectedDiff() {
        guard let repo = repoRoot, selectedIndex >= 0, selectedIndex < changes.count else {
            diffBody.clear()
            shownPath = nil
            shownDiff = nil
            return
        }

        let change = changes[selectedIndex]
        diffGeneration += 1
        let generation = diffGeneration

        Task { @MainActor in
            // The change-taking overload, not the path-taking one: it already
            // knows an untracked file has nothing in HEAD to diff against.
            let raw = await GitStatus.diff(repoRoot: repo, change: change)
            guard generation == self.diffGeneration, self.repoRoot == repo else { return }
            guard let raw else {
                App.log("diff: could not read \(change.path)")
                return
            }

            let diff = Self.stripHeaders(raw)
            // Re-rendering identical text would drop the user's selection and
            // reset the scroll position on every poll.
            if self.shownPath == change.path && self.shownDiff == diff { return }

            let sameFile = self.shownPath == change.path
            self.shownPath = change.path
            self.shownDiff = diff
            self.render(diff, keepScroll: sameFile)

            // Coming back to a repository lands where it was left rather than
            // at the top.
            if !sameFile, let place = self.placeInRepo[Self.placeKey(repo)],
               place.path == change.path, place.scroll > 0 {
                self.scrollDiff(to: place.scroll)
            }
        }
    }

    @objc private func diffDidScroll() {
        rememberPlace()
    }

    /// Stores where the current repository is being left.
    private func rememberPlace() {
        guard let repo = repoRoot, selectedIndex >= 0, selectedIndex < changes.count else { return }
        placeInRepo[Self.placeKey(repo)] = (changes[selectedIndex].path,
                                            diffScroll.contentView.bounds.origin.y)
    }

    /// Keyed on the machine as well as the path, so two checkouts at
    /// /home/me/app on two different servers do not share one bookmark.
    /// Folded locally, where the volume usually does not care, and left alone
    /// over there, where the far end does.
    private static func placeKey(_ repo: SessionLocation) -> String {
        repo.isRemote ? repo.description : repo.description.lowercased()
    }

    private func scrollDiff(to offset: CGFloat) {
        // The clip view cannot move past content it has not laid out yet, so
        // the lines just handed to the body are measured first.
        layoutSubtreeIfNeeded()
        let limit = max(0, diffBody.frame.height - diffScroll.contentView.bounds.height)
        diffScroll.contentView.scroll(to: NSPoint(x: 0, y: min(max(offset, 0), limit)))
        diffScroll.reflectScrolledClipView(diffScroll.contentView)
    }

    // ---------------------------------------------------------------- render

    private func render(_ diff: String, keepScroll: Bool) {
        let offset = keepScroll ? diffScroll.contentView.bounds.origin.y : 0

        // Line numbers come from the hunk headers rather than a running count:
        // a diff is a handful of windows into a file, and the @@ line is the
        // only statement of where each window begins.
        var lines: [DiffLine] = []
        var oldLine = 0
        var newLine = 0
        var widest = 0
        var count = 0

        for raw in diff.components(separatedBy: "\n") {
            if count >= Self.maxLines {
                lines.append(DiffLine(
                    number: "",
                    text: "... truncated at \(Self.maxLines) lines. Read the rest with git diff.",
                    color: colors.meta))
                break
            }
            count += 1

            // Hunk headers are dropped: they exist to say where in the file you
            // are, and the gutter says that on every line. A blank row marks
            // the jump instead of leaving @@ syntax on screen.
            if raw.hasPrefix("@@") {
                (oldLine, newLine) = Self.parseHunk(raw, oldLine, newLine)
                if !lines.isEmpty {
                    lines.append(DiffLine(number: "", text: " ", color: colors.meta))
                }
                continue
            }

            let color: NSColor
            let number: String
            if raw.hasPrefix("+") {
                color = colors.added
                number = String(newLine)
                newLine += 1
            } else if raw.hasPrefix("-") {
                color = colors.removed
                // A removed line carries its OLD file number: it does not exist
                // in the new file, so a new-file number would point at a line
                // that is something else entirely.
                number = String(oldLine)
                oldLine += 1
            } else if raw.hasPrefix("\\ No newline") {
                color = colors.meta
                number = ""
            } else {
                color = colors.body
                number = String(newLine)
                oldLine += 1
                newLine += 1
            }

            widest = max(widest, number.count)
            // An empty line still needs a row, or the gutter beside it would
            // sit against the wrong text.
            lines.append(DiffLine(number: number, text: raw.isEmpty ? " " : raw, color: color))
        }

        diffBody.setContent(lines, gutterDigits: max(2, widest))
        scrollDiff(to: offset)
    }

    /// Drops git's file-level preamble: the `diff --git` line, the index hash,
    /// the mode lines and the `---`/`+++` pair. They name the file the user
    /// just clicked and say nothing else, and the `---`/`+++` pair reads as a
    /// large deletion followed by a large addition.
    ///
    /// Hunk headers stay. `@@ -12,7 +12,9 @@` is the only thing telling you
    /// where in the file you are; `render` consumes them.
    ///
    /// Only the preamble is ever matched, never the body of a hunk. Inside a
    /// hunk the leading `-` or `+` is git's own marker, so a deleted `-- note`
    /// arrives as `--- note` and a prefix test cannot tell it from the `---`
    /// header. Matching everywhere ate exactly those lines: deleting a SQL or
    /// Lua comment left the panel showing no deletion at all while the count
    /// beside the filename still said one. Preamble ends at the first `@@`, and
    /// only a new `diff --git` starts another.
    private static func stripHeaders(_ diff: String) -> String {
        var kept: [String] = []
        var inPreamble = true
        for raw in diff.components(separatedBy: "\n") {
            var line = raw
            if line.hasSuffix("\r") { line.removeLast() }

            // One diff can carry several files, and each opens its own preamble.
            if line.hasPrefix("diff --git ") {
                inPreamble = true
                continue
            }
            if line.hasPrefix("@@") { inPreamble = false }

            if inPreamble,
               line.hasPrefix("index ")
                || line.hasPrefix("--- ")
                || line.hasPrefix("+++ ")
                || line == "--- /dev/null"
                || line == "+++ /dev/null"
                || line.hasPrefix("new file mode ")
                || line.hasPrefix("deleted file mode ")
                || line.hasPrefix("old mode ")
                || line.hasPrefix("new mode ")
                || line.hasPrefix("similarity index ")
                || line.hasPrefix("rename from ")
                || line.hasPrefix("rename to ") {
                continue
            }
            kept.append(line)
        }

        // A leading blank line from the stripped preamble is just a gap.
        while let first = kept.first, first.isEmpty { kept.removeFirst() }
        // And the trailing one is git's final newline, not a line of the file.
        // Windows keeps it and renders a numbered blank row under every diff;
        // it is an artefact of the split, not something git said.
        while let last = kept.last, last.isEmpty { kept.removeLast() }
        return kept.joined(separator: "\n")
    }

    /// Reads "@@ -12,7 +34,9 @@" and returns the first old and new line the
    /// hunk covers. A malformed header leaves the counters where they were,
    /// which keeps the numbering plausible rather than resetting it to zero.
    private static func parseHunk(_ header: String, _ oldLine: Int, _ newLine: Int) -> (Int, Int) {
        let chars = Array(header)
        guard let minus = chars.firstIndex(of: "-"),
              let plus = chars[(minus + 1)...].firstIndex(of: "+") else {
            return (oldLine, newLine)
        }

        // The closing "@@", searched past the opening one.
        var end = -1
        var index = 2
        while index + 1 < chars.count {
            if chars[index] == "@" && chars[index + 1] == "@" {
                end = index
                break
            }
            index += 1
        }
        guard end > plus else { return (oldLine, newLine) }

        func firstNumber(_ field: ArraySlice<Character>) -> Int? {
            let text = String(field).trimmingCharacters(in: .whitespaces)
            guard let head = text.split(separator: ",").first else { return nil }
            return Int(head)
        }
        guard let old = firstNumber(chars[(minus + 1)..<plus]),
              let new = firstNumber(chars[(plus + 1)..<end]) else {
            return (oldLine, newLine)
        }
        return (old, new)
    }

    /// A label that is unique within the current file set: the bare filename
    /// when nothing else shares it, otherwise the last directory too. A
    /// repository full of app/page.tsx and docs/page.tsx would otherwise render
    /// a column of identical labels.
    private static func labelFor(_ path: String, byName: [String: Int]) -> String {
        let name = (path as NSString).lastPathComponent
        if name.isEmpty { return path }
        if (byName[name.lowercased()] ?? 0) <= 1 { return name }

        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        if parts.count < 2 { return name }
        if parts.count == 2 { return path }
        return parts.suffix(2).joined(separator: "/")
    }

    // ---------------------------------------------------------------- states

    private func showEmpty(_ title: String, _ message: String) {
        emptyTitle.stringValue = title
        emptyBody.stringValue = message
        emptyState.isHidden = false
        listHost.isHidden = true
        diffScroll.isHidden = true

        diffBody.clear()
        changes.removeAll()
        rebuildRows()
        setSelection(-1)
        shownPath = nil
        shownDiff = nil
    }

    private func hideEmpty() {
        emptyState.isHidden = true
        listHost.isHidden = false
        diffScroll.isHidden = false
    }

    /// Says why there is no file list, which over ssh is rarely "not a git
    /// repository".
    ///
    /// Each of these has a different thing the user can do about it, and the
    /// panel used to answer all of them by showing the last local repository it
    /// had seen: the one wrong answer that looks exactly like a right one.
    @MainActor
    private func showNothingHere(_ place: SessionLocation?, generation: Int) async {
        showHost(place?.remote?.label)

        guard let place, let remote = place.remote else {
            // A missing git also resolves no repository, and blaming the
            // directory for it sends the user cd-ing around looking for a
            // problem that no directory has.
            if GitStatus.isInstalled {
                showEmpty("Not a git repository",
                          "Open a session inside one and this fills in.")
            } else {
                showEmpty("git was not found",
                          "Install git, or the Command Line Tools, and reopen this panel.")
            }
            return
        }

        let host = remote.label

        // The other half of the rule the type already enforces, stated where a
        // reader of the panel will meet it: a host learned from OSC 7 or a
        // window title is a name that arrived over the wire from a program on
        // another computer. It is used to say where you are, and it is never a
        // reason to open a connection. `SshGitChannels.channel(for:)` refuses
        // it too, so this is the message rather than the mechanism.
        if !remote.canConnect {
            showEmpty("Connected to \(host)",
                      "Zharp did not see the ssh command that got here, so it has no way to reach the same machine on its own.")
            return
        }

        // Before asking whether the machine can be reached, because without a
        // directory there is nothing to ask it. Connecting here would be a
        // login on someone's server to find out something already known.
        if !place.hasPath {
            showEmpty("Somewhere on \(host)",
                      "The shell over there has not said which directory it is in. Zharp reads OSC 7, and the window title as a fallback.")
            return
        }

        let problem = await GitStatus.remoteProblem(remote)
        // Opening a connection takes a handshake, and a tab switch during it
        // would otherwise paint this answer over the next session's repository.
        guard generation == refreshGeneration else { return }

        if let problem, !problem.isEmpty {
            showEmpty("Cannot read git on \(host)", problem)
            return
        }
        showEmpty("Not a git repository", "\(place.path) on \(host) is not inside one.")
    }

    /// Names the machine in the header while the panel is showing another
    /// computer's work. Absent for a local repository, which is most of them.
    private func showHost(_ label: String?) {
        let name = label ?? ""
        hostLabel.stringValue = name
        hostChip.isHidden = name.isEmpty
    }

    // ----------------------------------------------------------------- debug

    /// A textual snapshot of what the panel is showing, for the headless checks
    /// the app carries for the rest of its chrome. Reading a screenshot cannot
    /// tell a panel that found nothing from one that never ran.
    func debugState() -> String {
        var lines: [String] = []
        // The empty state keeps its last title while hidden, so naming it when
        // it is not showing would report a repository as missing. The body goes
        // with the title because over ssh the title only names the machine, and
        // the body is the whole difference between "cannot reach it", "no key
        // yet" and "turned off in Settings".
        let empty = emptyState.isHidden
            ? "no" : "\(emptyTitle.stringValue) / \(emptyBody.stringValue)"
        let host = repoRoot?.remote.map { "\($0.label)(\($0.canConnect ? "watched" : "reported")) " }
        lines.append("\(host ?? "")repo=\(repoRoot?.path ?? "-") branch=\(branchLabel.stringValue) "
                     + "files=\(changes.count) selected=\(selectedIndex) "
                     + "poll=\(poll?.timeInterval ?? 0) "
                     + "totals=+\(totalAdded)/-\(totalRemoved) empty=\(empty)")
        for change in changes {
            lines.append("  \(change.kind) \(change.displayPath) "
                         + "+\(change.added)/-\(change.removed)"
                         + (change.staged ? " staged" : ""))
        }
        for line in (shownDiff ?? "").split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(12) {
            lines.append("  | \(line)")
        }
        return lines.joined(separator: "\n")
    }

    // ------------------------------------------------------------------ copy

    /// Copies the selection. The numbers are painted beside the text rather
    /// than being part of it, so a selection here is the diff and nothing else.
    /// Returns false when there was nothing selected, so the window's own copy
    /// shortcut can fall through to the terminal.
    @discardableResult
    func copySelection() -> Bool {
        let text = diffBody.selectedText
        if text.isEmpty { return false }
        Self.putOnClipboard(text)
        return true
    }

    var selectedText: String { diffBody.selectedText }

    /// Copies the selected file's whole diff, header-stripped, as shown.
    private func copyWholeDiff() {
        Self.putOnClipboard(shownDiff ?? "")
    }

    private static func putOnClipboard(_ text: String) {
        if text.isEmpty { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // --------------------------------------------------------------- theming

    func setPalette(_ palette: Palette) {
        colors = DiffColors.make(palette)
        diffBody.setColors(colors)
        for row in rows { row.setColors(colors) }
        // The line colours are baked in at render time, so the text has to be
        // walked again; the reader keeps their place.
        if let diff = shownDiff { render(diff, keepScroll: true) }
    }

    /// Matches the terminal's font, so the diff reads as the same surface.
    func setFontFamily(_ family: String) {
        let trimmed = family.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == fontFamily { return }
        fontFamily = trimmed
        applyTypography()
    }

    func setUiZoom(_ zoom: Double) {
        let next = CGFloat(zoom)
        if abs(next - self.zoom) < 0.001 { return }
        self.zoom = next

        headerHeight.constant = max(28, Self.headerHeight * next)
        gitIcon.font = Icons.font(size: 14 * next)
        hostLabel.font = NSFont.systemFont(ofSize: 10.5 * next)
        repoLabel.font = NSFont.systemFont(ofSize: 12.5 * next)
        branchLabel.font = NSFont.systemFont(ofSize: 12 * next)
        for button in [copyButton, refreshButton, closeButton] {
            button.setMetrics(side: 24 * next, glyphSize: 15 * next)
        }
        emptyTitle.font = NSFont.systemFont(ofSize: 13 * next)
        emptyBody.font = NSFont.systemFont(ofSize: 12 * next)

        applyTypography()
        rebuildRows()
    }

    /// Whole-UI zoom without transforms, like the rest of the chrome: the real
    /// metrics are multiplied so the text re-rasterizes crisply.
    private func applyTypography() {
        diffBody.setTypography(family: fontFamily, fontSize: 12.5 * zoom,
                               lineHeight: 17 * zoom, zoom: zoom)
    }

    func refreshChrome() {
        ChromeRefresh.apply(to: self)
        // ChromeRefresh re-resolves every label against the chrome text colour,
        // which is right for the header and wrong for anything palette-driven.
        gitIcon.textColor = Chrome.current.subtleIcon
        diffBody.setColors(colors)
        for row in rows { row.setColors(colors) }
    }
}

// ---------------------------------------------------------------------------

/// One row of the changed-files list: badge, label, counts.
///
/// The counts are written into the row after it is on screen, never by
/// replacing it. Rebuilding the list to refresh a number makes the whole thing
/// blink and jump, which is what a refresh used to look like.
final class DiffFileRowView: RoundedRowView {
    let change: GitFileChange

    private let badge = NSTextField(labelWithString: "")
    private let pathLabel = TailTextField()
    private let counts = NSTextField(labelWithString: "")
    private let zoom: CGFloat
    private var colors: DiffColors

    init(change: GitFileChange, label: String, zoom: CGFloat, colors: DiffColors,
         height: CGFloat) {
        self.change = change
        self.zoom = zoom
        self.colors = colors
        super.init(fill: .none)
        translatesAutoresizingMaskIntoConstraints = false
        toolTip = change.path

        badge.stringValue = Self.badgeFor(change.kind)
        badge.font = NSFont.systemFont(ofSize: 11.5 * zoom, weight: .semibold)
        badge.alignment = .center
        badge.translatesAutoresizingMaskIntoConstraints = false

        // The label is a filename, so the tail is the half worth keeping.
        pathLabel.text = label
        pathLabel.fontSize = 12.5 * zoom
        pathLabel.tailFirst = true
        pathLabel.translatesAutoresizingMaskIntoConstraints = false

        counts.alignment = .right
        counts.translatesAutoresizingMaskIntoConstraints = false
        counts.setContentHuggingPriority(.required, for: .horizontal)
        counts.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(badge)
        addSubview(pathLabel)
        addSubview(counts)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: height),
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            badge.widthAnchor.constraint(equalToConstant: 13 * zoom),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            pathLabel.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 8),
            pathLabel.trailingAnchor.constraint(equalTo: counts.leadingAnchor, constant: -8),
            pathLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            counts.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            counts.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        applyColors()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func setCounts(added: Int, removed: Int) {
        let font = NSFont.systemFont(ofSize: 11 * zoom)
        let text = NSMutableAttributedString()
        if added > 0 {
            // The trailing space is the only separator between the two.
            text.append(NSAttributedString(string: "+\(added) ", attributes: [
                .font: font, .foregroundColor: colors.added,
            ]))
        }
        if removed > 0 {
            text.append(NSAttributedString(string: "-\(removed)", attributes: [
                .font: font, .foregroundColor: colors.removed,
            ]))
        }
        counts.attributedStringValue = text
    }

    func setColors(_ colors: DiffColors) {
        self.colors = colors
        applyColors()
    }

    private func applyColors() {
        badge.textColor = badgeColor()
        pathLabel.tint = Chrome.current.text
        setCounts(added: change.added, removed: change.removed)
    }

    private func badgeColor() -> NSColor {
        switch change.kind {
        case .added, .untracked: return colors.added
        case .deleted, .conflicted: return colors.removed
        case .modified, .renamed: return colors.meta
        }
    }

    private static func badgeFor(_ kind: GitChangeKind) -> String {
        switch kind {
        case .added: return "A"
        case .deleted: return "D"
        case .renamed: return "R"
        case .untracked: return "?"
        case .conflicted: return "!"
        case .modified: return "M"
        }
    }
}

// ---------------------------------------------------------------------------

/// The diff itself: wrapping, character selection across lines, and a gutter
/// that can never be selected.
///
/// Those three looked mutually exclusive and are not. The problem with a gutter
/// laid out beside the text is that it cannot know logical line 4 wrapped onto
/// visual row 6, so it drifts. The fix is to stop predicting and start
/// measuring: the whole diff is laid out here, line by line, with Core Text, so
/// the exact Y of every line is already known, and the number is painted at it.
///
/// It also means the numbers are paint rather than text. They are not in the
/// string the selection runs over, so no selection can pick one up and no copy
/// can carry one out. That is the entire reason the diff is drawn rather than
/// hosted in a text view.
final class DiffBodyView: NSView {
    var onCopySelection: (() -> Void)?
    var onCopyAll: (() -> Void)?

    private var lines: [DiffLine] = []
    private var colors = DiffColors.placeholder

    /// The whole diff as one string, which is what a selection indexes into.
    private var text: NSString = ""
    /// UTF-16 offset of each logical line inside `text`.
    private var lineStarts: [Int] = []

    /// One wrapped row: the piece of a logical line that fits on it, and where
    /// it landed.
    private struct VisualLine {
        let ctLine: CTLine
        let logical: Int
        /// Offset of this fragment in `text`.
        let start: Int
        let length: Int
        /// Offset of this fragment inside its own logical line, which is the
        /// index space CTLine reports positions in.
        let localStart: Int
        let top: CGFloat
        /// True for the row a line's number belongs beside.
        let isFirst: Bool
    }
    private var visuals: [VisualLine] = []

    private var font: CTFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
    private var fontFamily = "SF Mono"
    private var fontSize: CGFloat = 12.5
    private var lineHeight: CGFloat = 17
    private var zoom: CGFloat = 1
    private var digitWidth: CGFloat = 8
    private var baseline: CGFloat = 13
    private var gutterWidth: CGFloat = 34
    private var gutterDigits = 2

    private var contentHeight: CGFloat = 0
    private var laidOutWidth: CGFloat = -1

    /// Selection endpoints as UTF-16 offsets into `text`. Equal means none.
    private var anchor = 0
    private var focus = 0
    private var selecting = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        rebuildFont()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    // ---------------------------------------------------------------- content

    func setContent(_ lines: [DiffLine], gutterDigits: Int) {
        self.lines = lines
        self.gutterDigits = max(2, gutterDigits)
        anchor = 0
        focus = 0

        var joined = ""
        var offset = 0
        lineStarts.removeAll(keepingCapacity: true)
        for (index, line) in lines.enumerated() {
            if index > 0 {
                joined.append("\n")
                offset += 1
            }
            lineStarts.append(offset)
            joined.append(line.text)
            offset += (line.text as NSString).length
        }
        text = joined as NSString

        laidOutWidth = -1
        rebuildLayout()
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    func clear() {
        setContent([], gutterDigits: 2)
    }

    func setColors(_ colors: DiffColors) {
        self.colors = colors
        needsDisplay = true
    }

    func setTypography(family: String, fontSize: CGFloat, lineHeight: CGFloat, zoom: CGFloat) {
        self.fontFamily = family
        self.fontSize = fontSize
        self.lineHeight = lineHeight
        self.zoom = zoom
        rebuildFont()
        laidOutWidth = -1
        rebuildLayout()
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    var selectedText: String {
        let low = min(anchor, focus)
        let high = max(anchor, focus)
        if high <= low { return "" }
        return text.substring(with: NSRange(location: low, length: high - low))
    }

    // ----------------------------------------------------------------- layout

    private func rebuildFont() {
        let base = NSFont(name: fontFamily, size: fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        font = base as CTFont

        // The gutter is as wide as its digits really are, not as wide as a
        // constant guesses: a diff in a narrow face should not reserve room a
        // wide one needs.
        let probe = NSAttributedString(string: "0000000000", attributes: [.font: font as Any])
        digitWidth = CGFloat(CTLineGetTypographicBounds(
            CTLineCreateWithAttributedString(probe), nil, nil, nil)) / 10.0

        // Sit the text in the middle of its row rather than on the top of it.
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        baseline = ((lineHeight - (ascent + descent)) / 2) + ascent
    }

    private var topPadding: CGFloat { 8 * zoom }
    private var bottomPadding: CGFloat { 12 * zoom }
    private var rightPadding: CGFloat { 12 * zoom }
    /// Between the numbers and the text, and to the left of the numbers.
    private var gutterGap: CGFloat { 10 * zoom }
    private var gutterInset: CGFloat { 8 * zoom }

    private func rebuildLayout() {
        laidOutWidth = bounds.width
        visuals.removeAll(keepingCapacity: true)
        gutterWidth = CGFloat(gutterDigits) * digitWidth + gutterGap + gutterInset

        let wrapWidth = bounds.width - gutterWidth - rightPadding
        guard wrapWidth > digitWidth, !lines.isEmpty else {
            contentHeight = topPadding + bottomPadding
            return
        }

        var y = topPadding
        for (index, line) in lines.enumerated() {
            let attributed = NSAttributedString(string: line.text, attributes: [
                .font: font as Any,
                .foregroundColor: line.color,
            ])
            let length = attributed.length
            guard length > 0 else {
                y += lineHeight
                continue
            }

            let typesetter = CTTypesetterCreateWithAttributedString(attributed)
            var start = 0
            var first = true
            while start < length {
                var count = CTTypesetterSuggestLineBreak(typesetter, start, Double(wrapWidth))
                // A column too narrow for even one glyph still has to advance,
                // or this loop never ends.
                if count <= 0 { count = 1 }
                count = min(count, length - start)

                let ctLine = CTTypesetterCreateLine(
                    typesetter, CFRange(location: start, length: count))
                visuals.append(VisualLine(ctLine: ctLine, logical: index,
                                          start: lineStarts[index] + start, length: count,
                                          localStart: start, top: y, isFirst: first))
                y += lineHeight
                start += count
                first = false
            }
        }
        contentHeight = y + bottomPadding
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: max(contentHeight, 1))
    }

    /// The diff reflowed, so every measured Y is stale. Re-measuring here covers
    /// a window resize, the splitter being dragged and a font change alike,
    /// without any of them needing to know about the gutter.
    override func layout() {
        super.layout()
        if abs(bounds.width - laidOutWidth) > 0.5 {
            rebuildLayout()
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    // ------------------------------------------------------------------ paint

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, !visuals.isEmpty else { return }
        let low = min(anchor, focus)
        let high = max(anchor, focus)

        ctx.saveGState()
        // Core Text draws bottom-up; this view is flipped, so mirror the text
        // matrix and place every baseline by hand.
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)

        for visual in visuals {
            if visual.top > dirtyRect.maxY || visual.top + lineHeight < dirtyRect.minY { continue }

            if high > low { drawSelection(visual, low: low, high: high) }

            if visual.isFirst {
                let number = lines[visual.logical].number
                if !number.isEmpty { drawNumber(ctx, number, top: visual.top) }
            }

            ctx.textPosition = CGPoint(x: gutterWidth, y: visual.top + baseline)
            CTLineDraw(visual.ctLine, ctx)
        }
        ctx.restoreGState()
    }

    private func drawNumber(_ ctx: CGContext, _ number: String, top: CGFloat) {
        let attributed = NSAttributedString(string: number, attributes: [
            .font: font as Any,
            .foregroundColor: colors.gutter,
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        // Right-aligned against the gap, so the ones column stays put as a file
        // runs from line 9 into line 10.
        ctx.textPosition = CGPoint(x: gutterWidth - gutterGap - width, y: top + baseline)
        CTLineDraw(line, ctx)
    }

    private func drawSelection(_ visual: VisualLine, low: Int, high: Int) {
        let start = visual.start
        let end = visual.start + visual.length
        let from = max(low, start)
        let to = min(high, end)
        // Nothing of this row is inside the selection, and the selection does
        // not run past its end either.
        if from >= to && high <= end { return }
        if high <= start || low > end { return }

        let x1 = gutterWidth
            + CTLineGetOffsetForStringIndex(visual.ctLine, from - start + visual.localStart, nil)
        var x2 = gutterWidth
            + CTLineGetOffsetForStringIndex(visual.ctLine, to - start + visual.localStart, nil)
        // A selection continuing onto the next row includes the line break, so
        // the highlight runs to the edge to show that it does.
        if high > end { x2 = max(x2, bounds.width - rightPadding) }

        colors.selection.setFill()
        NSRect(x: x1, y: visual.top, width: max(x2 - x1, 1), height: lineHeight).fill()
    }

    // -------------------------------------------------------------- selection

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .iBeam)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let offset = self.offset(at: point)
        if event.clickCount >= 2 {
            (anchor, focus) = wordRange(around: offset)
            selecting = false
        } else {
            anchor = offset
            focus = offset
            selecting = true
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard selecting else { return }
        autoscroll(with: event)
        focus = offset(at: convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        selecting = false
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(MenuItem(title: "Copy") { [weak self] in self?.onCopySelection?() })
        menu.addItem(MenuItem(title: "Copy whole file diff") { [weak self] in self?.onCopyAll?() })
        return menu
    }

    /// The character offset a point lands on. A point above or below every row
    /// clamps to the ends, so a drag that runs off the edge selects everything
    /// in between.
    private func offset(at point: NSPoint) -> Int {
        guard let last = visuals.last else { return 0 }
        if point.y < visuals[0].top { return 0 }

        var chosen = last
        for visual in visuals where point.y >= visual.top && point.y < visual.top + lineHeight {
            chosen = visual
            break
        }
        if point.y >= chosen.top + lineHeight { return text.length }

        let local = CTLineGetStringIndexForPosition(
            chosen.ctLine, CGPoint(x: point.x - gutterWidth, y: 0))
        if local == kCFNotFound { return chosen.start }
        let global = chosen.start + (local - chosen.localStart)
        return min(max(global, chosen.start), chosen.start + chosen.length)
    }

    /// Double click picks out an identifier, a number or a path segment, which
    /// is what a diff is mostly made of.
    private func wordRange(around offset: Int) -> (Int, Int) {
        if text.length == 0 { return (0, 0) }
        func isWord(_ index: Int) -> Bool {
            guard index >= 0, index < text.length else { return false }
            guard let scalar = Unicode.Scalar(text.character(at: index)) else { return false }
            return CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
        }

        var start = min(offset, text.length - 1)
        if !isWord(start) { start = max(0, start - 1) }
        if !isWord(start) { return (offset, offset) }
        var end = start
        while isWord(start - 1) { start -= 1 }
        while isWord(end + 1) { end += 1 }
        return (start, end + 1)
    }
}
