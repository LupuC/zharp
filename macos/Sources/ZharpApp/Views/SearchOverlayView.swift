import AppKit

/// The floating session palette: a transparent scrim catches click-away, the
/// centered panel swallows its own taps. Type to filter, arrows + Enter to
/// jump, Escape or a click outside to dismiss.
final class SearchOverlayView: NSView {
    private let panel = ChromeView(fill: .floatingPanel)
    private let searchField = NSTextField()
    private let resultsStack = NSStackView()
    private let scrollView = NSScrollView()

    private let allSessions: [SessionItem]
    private var matches: [SessionItem] = []
    private var selectedIndex = -1

    var onPick: ((SessionItem) -> Void)?
    var onDismiss: (() -> Void)?

    private lazy var cursorClaim = CursorClaim(view: self)

    override var isFlipped: Bool { true }

    init(sessions: [SessionItem]) {
        allSessions = sessions
        super.init(frame: .zero)
        wantsLayer = true

        panel.cornerRadius = 10
        panel.hairlineEdges = NSEdgeInsets(top: 1, left: 1, bottom: 1, right: 1)
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)

        searchField.placeholderString = "Search sessions…"
        searchField.font = NSFont.systemFont(ofSize: 13)
        searchField.isBordered = true
        searchField.bezelStyle = .roundedBezel
        searchField.focusRingType = .none
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.delegate = self
        panel.addSubview(searchField)

        resultsStack.orientation = .vertical
        resultsStack.alignment = .leading
        resultsStack.spacing = 2
        resultsStack.translatesAutoresizingMaskIntoConstraints = false

        ScrollBox.configure(scrollView, document: resultsStack)
        panel.addSubview(scrollView)

        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: centerXAnchor),
            panel.topAnchor.constraint(equalTo: topAnchor, constant: 0),
            panel.widthAnchor.constraint(equalToConstant: 460),

            searchField.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -10),
            searchField.topAnchor.constraint(equalTo: panel.topAnchor, constant: 10),
            searchField.heightAnchor.constraint(equalToConstant: 30),

            scrollView.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 10),
            scrollView.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -10),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -10),
            scrollView.heightAnchor.constraint(lessThanOrEqualToConstant: 280),
            resultsStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])

        refreshResults()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard let superview else { return }
        // 0.55 / 1.45 vertical split, like the Windows palette's row weights.
        panel.topAnchor.constraint(equalTo: superview.topAnchor,
                                   constant: superview.bounds.height * 0.22).isActive = true
    }

    func focusSearchField() {
        window?.makeFirstResponder(searchField)
        searchField.currentEditor()?.selectAll(nil) // keep the query, preselect for overwrite
    }

    func refreshChrome() {
        panel.needsDisplay = true
        refreshResults()
    }

    override func mouseDown(with event: NSEvent) {
        // The scrim dismisses; the panel handles its own clicks.
        if !panel.frame.contains(convert(event.locationInWindow, from: nil)) {
            onDismiss?()
        }
    }

    /// Take the pointer back from the terminal's I-beam rect underneath.
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

    /// Returns true when the palette consumed the key.
    func handleKey(_ event: NSEvent) -> Bool {
        guard let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first else {
            return false
        }
        switch Int(scalar.value) {
        case 0x1B: // Escape
            onDismiss?()
            return true
        case 0x0D, 0x03: // Return / Enter
            if selectedIndex >= 0 && selectedIndex < matches.count {
                onPick?(matches[selectedIndex])
            }
            return true
        case NSDownArrowFunctionKey:
            moveSelection(+1)
            return true
        case NSUpArrowFunctionKey:
            moveSelection(-1)
            return true
        default:
            return false
        }
    }

    private func moveSelection(_ delta: Int) {
        if matches.isEmpty { return }
        selectedIndex = selectedIndex < 0
            ? 0
            : (selectedIndex + delta + matches.count) % matches.count
        updateSelectionVisuals()
    }

    private func updateSelectionVisuals() {
        for (index, row) in resultsStack.arrangedSubviews.enumerated() {
            (row as? RoundedRowView)?.isSelected = index == selectedIndex
        }
        if selectedIndex >= 0 && selectedIndex < resultsStack.arrangedSubviews.count {
            resultsStack.arrangedSubviews[selectedIndex]
                .scrollToVisible(resultsStack.arrangedSubviews[selectedIndex].bounds)
        }
    }

    private func refreshResults() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        matches = query.isEmpty ? allSessions : allSessions.filter { item in
            item.displayTitle.range(of: query, options: .caseInsensitive) != nil
                || item.displaySubtitle.range(of: query, options: .caseInsensitive) != nil
                || item.title.range(of: query, options: .caseInsensitive) != nil
        }
        selectedIndex = matches.isEmpty ? -1 : 0

        for view in resultsStack.arrangedSubviews {
            resultsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, item) in matches.enumerated() {
            let row = buildRow(item)
            row.isSelected = index == selectedIndex
            row.onClick = { [weak self] in self?.onPick?(item) }
            resultsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: resultsStack.widthAnchor).isActive = true
        }
    }

    private func buildRow(_ item: SessionItem) -> RoundedRowView {
        let row = RoundedRowView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let icon = Label.icon(item.hasAgent ? item.agentGlyph : item.iconGlyph, size: item.z15,
                              color: item.agentColor ?? Chrome.current.barIcon)
        let title = Label.make(item.displayTitle, size: item.z13)
        let path = TailTextField()
        path.text = item.displaySubtitle
        path.fontSize = item.z11
        path.opacity = 0.55
        path.alignTrailing = true
        path.translatesAutoresizingMaskIntoConstraints = false

        row.addSubview(icon)
        row.addSubview(title)
        row.addSubview(path)

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 30),
            icon.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            title.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            path.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 10),
            path.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -10),
            path.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            path.widthAnchor.constraint(equalToConstant: item.z170),
        ])
        return row
    }
}

extension SearchOverlayView: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        refreshResults()
    }
}
