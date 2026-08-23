import AppKit

/// The session list: vertical cards for the sidebar, horizontal pills for the
/// top strip. One view covers both, matching the Windows build where the same
/// items feed three `DataTemplate`s.
final class SessionListView: ChromeView {
    enum Style {
        case card       // comfortable: icon chip + two lines
        case compact    // single line
        case pill       // horizontal strip
    }

    var style: Style = .card { didSet { rebuild() } }
    var zoom: Double = 1.0

    private(set) var items: [SessionItem] = []
    private var selected: SessionItem?
    private let stack = NSStackView()
    private let scrollView: NSScrollView

    var onSelect: ((SessionItem) -> Void)?
    var onClose: ((SessionItem) -> Void)?
    /// The window this list belongs to, so a drop can tell "here" from "there".
    weak var owner: MainWindowController?
    /// Started when a row is pressed; nil when the list is not draggable.
    var dragController: TabDragController?

    func indexOf(_ item: SessionItem) -> Int? {
        items.firstIndex { $0 === item }
    }

    /// The slot a pointer at `point` would drop into.
    func indexForDrop(at point: CGPoint) -> Int? {
        let rows = stack.arrangedSubviews.compactMap { $0 as? SessionRowView }
        if rows.isEmpty { return nil }
        let horizontal = style == .pill
        for (index, row) in rows.enumerated() {
            let frame = stack.convert(row.frame, to: self)
            let middle = horizontal ? frame.midX : frame.midY
            let position = horizontal ? point.x : point.y
            if position < middle { return index }
        }
        return rows.count - 1
    }

    /// Moves a row without rebuilding the list. Rebuilding mid-drag would
    /// deallocate the row AppKit is still routing events to.
    func moveRow(_ item: SessionItem, to index: Int) {
        guard let from = indexOf(item), from != index,
              index >= 0, index < items.count else { return }
        let moved = items.remove(at: from)
        items.insert(moved, at: index)
        let views = stack.arrangedSubviews
        guard from < views.count else { return }
        let view = views[from]
        stack.removeArrangedSubview(view)
        stack.insertArrangedSubview(view, at: index)
    }

    override init(fill: Fill = .none) {
        scrollView = NSScrollView()
        super.init(fill: fill)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 4, bottom: 2, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false

        ScrollBox.configure(scrollView, document: stack)
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func setItems(_ items: [SessionItem], selected: SessionItem?) {
        self.items = items
        self.selected = selected
        rebuild()
    }

    func setSelected(_ item: SessionItem?) {
        selected = item
        for case let row as SessionRowView in stack.arrangedSubviews {
            row.isSelected = row.item === item
        }
    }

    private func rebuild() {
        let horizontal = style == .pill
        stack.orientation = horizontal ? .horizontal : .vertical
        stack.alignment = horizontal ? .centerY : .leading
        stack.spacing = horizontal ? 4 : 2
        stack.edgeInsets = horizontal
            ? NSEdgeInsets(top: 4, left: 2, bottom: 4, right: 2)
            : NSEdgeInsets(top: 2, left: 4, bottom: 2, right: 4)
        scrollView.hasVerticalScroller = !horizontal
        scrollView.hasHorizontalScroller = false

        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for item in items {
            let row = SessionRowView(item: item, style: style, zoom: zoom)
            row.isSelected = item === selected
            row.onClick = { [weak self] in self?.onSelect?(item) }
            row.onClose = { [weak self] in self?.onClose?(item) }
            row.onPress = { [weak self] row, event in
                self?.dragController?.press(row: row, event: event)
            }
            row.onDragged = { [weak self] event in self?.dragController?.drag(event: event) }
            row.onReleased = { [weak self] event in self?.dragController?.release(event: event) }
            stack.addArrangedSubview(row)
            if !horizontal {
                row.widthAnchor.constraint(equalTo: stack.widthAnchor,
                                           constant: -8).isActive = true
            }
        }
    }

    /// Rebuilds only the labels, for a live cwd/title update.
    func refreshLabels() {
        for case let row as SessionRowView in stack.arrangedSubviews {
            row.refresh()
        }
    }
}

/// One row of `SessionListView`.
final class SessionRowView: RoundedRowView {
    let item: SessionItem
    private let style: SessionListView.Style
    private let zoom: Double

    private let iconChip = ChromeView(fill: .iconChip)
    private let iconLabel = NSTextField(labelWithString: "")
    private let titleLabel = TailTextField()
    private let subtitleLabel = TailTextField()
    private let pillTitle = NSTextField(labelWithString: "")
    private let closeButton: IconButton

    var onClose: (() -> Void)?
    var onPress: ((SessionRowView, NSEvent) -> Void)?
    var onDragged: ((NSEvent) -> Void)?
    var onReleased: ((NSEvent) -> Void)?

    override func mouseDown(with event: NSEvent) {
        onPress?(self, event)
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        onDragged?(event)
    }

    override func mouseUp(with event: NSEvent) {
        onReleased?(event)
    }

    init(item: SessionItem, style: SessionListView.Style, zoom: Double) {
        self.item = item
        self.style = style
        self.zoom = zoom
        closeButton = IconButton(glyph: Icons.close,
                                 glyphSize: style == .card ? item.z14 : item.z12,
                                 side: 20 * zoom)
        super.init(fill: .none)
        translatesAutoresizingMaskIntoConstraints = false
        closeButton.cornerRadius = 4
        closeButton.tint = Chrome.current.subtleIcon
        closeButton.onClick = { [weak self] in self?.onClose?() }
        closeButton.toolTip = "Close session"

        switch style {
        case .card: buildCard()
        case .compact: buildCompact()
        case .pill: buildPill()
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private func configureIcon(size: CGFloat) {
        iconLabel.font = Icons.font(size: size)
        iconLabel.stringValue = item.hasAgent ? item.agentGlyph : item.iconGlyph
        iconLabel.textColor = item.agentColor ?? Chrome.current.barIcon
        iconLabel.translatesAutoresizingMaskIntoConstraints = false
        iconLabel.identifier = NSUserInterfaceItemIdentifier("icon")
    }

    private func buildCard() {
        configureIcon(size: item.z16)
        iconChip.cornerRadius = 5
        iconChip.translatesAutoresizingMaskIntoConstraints = false
        iconChip.addSubview(iconLabel)

        titleLabel.fontSize = item.z12
        titleLabel.emphasisBold = true
        subtitleLabel.fontSize = item.z11
        subtitleLabel.opacity = 0.55
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconChip)
        addSubview(titleLabel)
        addSubview(subtitleLabel)
        addSubview(closeButton)

        let chipSide = item.z24
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: max(38, 40 * zoom)),
            iconChip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconChip.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconChip.widthAnchor.constraint(equalToConstant: chipSide),
            iconChip.heightAnchor.constraint(equalToConstant: chipSide),
            iconLabel.centerXAnchor.constraint(equalTo: iconChip.centerXAnchor),
            iconLabel.centerYAnchor.constraint(equalTo: iconChip.centerYAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: iconChip.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            titleLabel.heightAnchor.constraint(equalToConstant: ceil(item.z12 * 1.45)),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
            subtitleLabel.heightAnchor.constraint(equalToConstant: ceil(item.z11 * 1.45)),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private func buildCompact() {
        configureIcon(size: 14 * zoom)
        titleLabel.fontSize = item.z12
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconLabel)
        addSubview(titleLabel)
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: max(24, 26 * zoom)),
            iconLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: iconLabel.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.heightAnchor.constraint(equalToConstant: ceil(item.z12 * 1.45)),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private func buildPill() {
        configureIcon(size: 15 * zoom)
        pillTitle.font = NSFont.systemFont(ofSize: item.z12)
        pillTitle.textColor = Chrome.current.text
        pillTitle.lineBreakMode = .byTruncatingTail
        pillTitle.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconLabel)
        addSubview(pillTitle)
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: item.z26),
            iconLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            pillTitle.leadingAnchor.constraint(equalTo: iconLabel.trailingAnchor, constant: 6),
            pillTitle.centerYAnchor.constraint(equalTo: centerYAnchor),
            pillTitle.widthAnchor.constraint(lessThanOrEqualToConstant: 140 * zoom),

            closeButton.leadingAnchor.constraint(equalTo: pillTitle.trailingAnchor, constant: 6),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    /// Reloads the labels from the item (live cwd, last command, agent state).
    func refresh() {
        iconLabel.stringValue = item.hasAgent ? item.agentGlyph : item.iconGlyph
        iconLabel.textColor = item.agentColor ?? Chrome.current.barIcon
        titleLabel.text = item.displayTitle
        titleLabel.textColor = Chrome.current.text
        titleLabel.tailFirst = item.titleTailFirst
        subtitleLabel.text = item.displaySubtitle
        subtitleLabel.textColor = Chrome.current.text
        subtitleLabel.tailFirst = item.subtitleTailFirst
        subtitleLabel.tint = item.subtitleTint
        subtitleLabel.isHidden = !item.subtitleVisible
        pillTitle.stringValue = item.compactTitle
        pillTitle.textColor = Chrome.current.text
        closeButton.tint = Chrome.current.subtleIcon
        // The close button only appears on hover, so a resting card is quiet.
        closeButton.alphaValue = isHovering || isSelected ? 1 : 0
        alphaValue = item.dragOpacity
        toolTip = "\(item.sessionName) · \(item.subtitle)\n\(item.kindLabel)"
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        closeButton.animator().alphaValue = 1
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if !isSelected { closeButton.animator().alphaValue = 0 }
    }
}
