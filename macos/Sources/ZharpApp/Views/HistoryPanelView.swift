import AppKit

/// The docked history sheet: it spans the full pane width and sits flush
/// against the input bar's rule - its edge IS that rule, not a floating card.
final class HistoryPanelView: NSView {
    /// True when the sheet hangs below the rule (pinned-top, or a classic
    /// prompt with no room above it).
    var dockBelow = false { didSet { needsDisplay = true } }
    var colors: OverlayColors? {
        didSet {
            titleLabel.textColor = colors?.foregroundDim
            gripLabel.textColor = colors?.foregroundDim
            folderToggle.colors = colors
            needsDisplay = true
        }
    }

    private let titleLabel = NSTextField(labelWithString: "HISTORY")
    private let gripLabel = NSTextField(labelWithString: "· · ·")
    let folderToggle = OverlayButton(content: .text("This folder"), pointSize: 11.5,
                                     width: 84, height: 28)
    let rowsStack = NSStackView()
    private let scrollView = NSScrollView()
    private let header = NSView()
    private var listHeight: NSLayoutConstraint!

    /// Drag the header to resize; dragging UP makes the list taller.
    var onResize: ((CGFloat) -> Void)?
    private var dragStartY: CGFloat = 0
    private var dragStartHeight: CGFloat = 0
    private var dragging = false

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = NSFont.systemFont(ofSize: 10.5)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        // Windows sets CharacterSpacing 80, i.e. 0.08em tracking.
        titleLabel.attributedStringValue = NSAttributedString(string: "HISTORY", attributes: [
            .font: NSFont.systemFont(ofSize: 10.5),
            .kern: 10.5 * 0.08,
        ])
        gripLabel.font = NSFont.systemFont(ofSize: 11)
        gripLabel.translatesAutoresizingMaskIntoConstraints = false
        folderToggle.isToggle = true
        folderToggle.toolTip = "Only commands run in this folder"

        header.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(titleLabel)
        header.addSubview(gripLabel)
        header.addSubview(folderToggle)
        addSubview(header)

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 1
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        ScrollBox.configure(scrollView, document: rowsStack)
        addSubview(scrollView)

        listHeight = scrollView.heightAnchor.constraint(equalToConstant: 170)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            header.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            header.heightAnchor.constraint(equalToConstant: 22),

            titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 4),
            titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            gripLabel.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            gripLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            folderToggle.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            folderToggle.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            listHeight,
            rowsStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func setListHeight(_ height: CGFloat) {
        listHeight.constant = height
    }

    /// Scrolls to the newest row, which sits at the bottom next to the prompt.
    func scrollToNewest() {
        layoutSubtreeIfNeeded()
        guard let last = rowsStack.arrangedSubviews.last else { return }
        last.scrollToVisible(last.bounds)
    }

    // Clicks in the sheet must never start a terminal text selection.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard header.frame.contains(point) else { return }
        dragging = true
        dragStartY = point.y
        dragStartHeight = listHeight.constant
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        let y = convert(event.locationInWindow, from: nil).y
        onResize?(dragStartHeight + (dragStartY - y))
    }

    override func mouseUp(with event: NSEvent) { dragging = false }
    override func rightMouseDown(with event: NSEvent) {}
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
        addCursorRect(header.frame, cursor: .resizeUpDown)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let colors else { return }
        colors.background.setFill()
        bounds.fill()
        // The sheet's edge IS the input's rule, so only that side is drawn.
        colors.border.setFill()
        let rule = dockBelow
            ? NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
            : NSRect(x: 0, y: 0, width: bounds.width, height: 1)
        rule.fill()
    }
}

/// One history row: chevron, command, folder, relative time.
final class HistoryRowView: NSView {
    let entry: HistoryEntry
    var isSelected = false { didSet { needsDisplay = true } }
    var onHover: (() -> Void)?
    var onClick: (() -> Void)?
    private var colors: OverlayColors
    private var trackingAreaRef: NSTrackingArea?

    override var isFlipped: Bool { true }

    init(entry: HistoryEntry, zoom: CGFloat, colors: OverlayColors) {
        self.entry = entry
        self.colors = colors
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let chevron = NSTextField(labelWithString: Icons.prompt)
        chevron.font = Icons.font(size: 11 * zoom)
        chevron.textColor = colors.foregroundDim
        chevron.translatesAutoresizingMaskIntoConstraints = false

        let command = NSTextField(labelWithString: entry.command)
        command.font = NSFont.systemFont(ofSize: 13 * zoom)
        command.textColor = colors.foreground
        command.lineBreakMode = .byTruncatingTail
        command.translatesAutoresizingMaskIntoConstraints = false
        command.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let time = NSTextField(labelWithString: HistoryRowView.relativeTime(entry.when))
        time.font = NSFont.systemFont(ofSize: 11 * zoom)
        time.textColor = colors.foregroundDim
        time.translatesAutoresizingMaskIntoConstraints = false

        addSubview(chevron)
        addSubview(command)
        addSubview(time)

        var trailing = time.leadingAnchor
        if let directory = entry.directory, !directory.isEmpty {
            let folder = NSTextField(labelWithString: SessionItem.abbreviate(directory))
            folder.font = NSFont.systemFont(ofSize: 11 * zoom)
            folder.textColor = colors.foregroundDim
            folder.lineBreakMode = .byTruncatingTail
            folder.translatesAutoresizingMaskIntoConstraints = false
            addSubview(folder)
            NSLayoutConstraint.activate([
                // Not zoom-scaled, matching Windows.
                folder.widthAnchor.constraint(lessThanOrEqualToConstant: 200),
                folder.trailingAnchor.constraint(equalTo: time.leadingAnchor, constant: -10),
                folder.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            trailing = folder.leadingAnchor
        }

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: (13 * zoom) + 6 * zoom + 8),
            chevron.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8 * zoom),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            command.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 10),
            command.trailingAnchor.constraint(lessThanOrEqualTo: trailing, constant: -10),
            command.centerYAnchor.constraint(equalTo: centerYAnchor),
            // Timestamp last, in its own column - never truncated away.
            time.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8 * zoom),
            time.centerYAnchor.constraint(equalTo: centerYAnchor),
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

    /// Hovering previews, exactly like keyboard navigation.
    override func mouseEntered(with event: NSEvent) { onHover?() }
    override func mouseDown(with event: NSEvent) { onClick?() }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected {
            colors.active.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
    }

    static func relativeTime(_ when: Date) -> String {
        let age = Date().timeIntervalSince(when)
        if age < 60 { return "just now" }
        if age < 3600 { return "\(Int(age / 60))m ago" }
        if age < 48 * 3600 { return "\(Int(age / 3600))h ago" }
        return "\(Int(age / 86400))d ago"
    }
}
