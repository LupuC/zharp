import AppKit

/// The first-run onboarding: welcome, theme pick, shortcut cheat sheet, done.
/// Shown once; it reappears only if `onboarded` is removed from settings.json.
final class OnboardingView: NSView {
    private let settings: AppSettings
    private var step = 0

    private let panel = ChromeView(fill: .floatingPanel)
    private let body = NSView()
    private var steps: [NSView] = []
    private let dots = NSStackView()
    private var backButton: PushButton!
    private var nextButton: PushButton!
    private var skipButton: PushButton!

    var changed: (() -> Void)?
    var finished: (() -> Void)?

    private lazy var cursorClaim = CursorClaim(view: self)

    override var isFlipped: Bool { true }

    init(settings: AppSettings) {
        self.settings = settings
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.4).cgColor

        panel.cornerRadius = 12
        panel.hairlineEdges = NSEdgeInsets(top: 1, left: 1, bottom: 1, right: 1)
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)

        body.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(body)

        steps = [buildWelcome(), buildTheme(), buildShortcuts(), buildDone()]
        for (index, view) in steps.enumerated() {
            view.isHidden = index != 0
            view.translatesAutoresizingMaskIntoConstraints = false
            body.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: body.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: body.trailingAnchor),
                view.centerYAnchor.constraint(equalTo: body.centerYAnchor),
                view.topAnchor.constraint(greaterThanOrEqualTo: body.topAnchor),
            ])
        }

        buildFooter()

        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: centerYAnchor),
            panel.widthAnchor.constraint(equalToConstant: 520),

            body.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 28),
            body.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -28),
            body.topAnchor.constraint(equalTo: panel.topAnchor, constant: 26),
            body.heightAnchor.constraint(equalToConstant: 280),
        ])
        updateStep()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func refreshChrome() {
        ChromeRefresh.apply(to: panel)
    }

    /// The terminal below claims an I-beam over its whole surface; the scrim
    /// takes the pointer back while onboarding is up.
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

    /// Modal scrim: clicks never reach the terminal behind it.
    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}

    /// Returns true when onboarding consumed the key (Enter advances, Esc skips).
    func handleKey(_ event: NSEvent) -> Bool {
        guard let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first else {
            return false
        }
        switch Int(scalar.value) {
        case 0x0D, 0x03:
            advance(+1)
            return true
        case 0x1B:
            finish()
            return true
        default:
            return false
        }
    }

    // ---------------------------------------------------------------- steps

    private func buildWelcome() -> NSView {
        let logo = NSImageView()
        logo.image = App.logoImage
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            logo.widthAnchor.constraint(equalToConstant: 64),
            logo.heightAnchor.constraint(equalToConstant: 64),
        ])

        let title = Label.make("Welcome to Zharp", size: 22, weight: .semibold)
        title.alignment = .center
        let sub = Label.make("A fast, modern terminal for macOS.", size: 13, opacity: 0.6)
        sub.alignment = .center

        let stack = NSStackView(views: [logo, title, sub])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        return stack
    }

    private func buildTheme() -> NSView {
        let header = headerRow(glyph: Icons.palette, title: "Pick your theme")
        let sub = Label.make("Applies instantly, to the whole app and every terminal.",
                             size: 12.5, opacity: 0.6)
        let grid = ThemeGridView(selectedId: settings.theme)
        grid.onSelect = { [weak self] id in
            guard let self else { return }
            self.settings.theme = id
            self.settings.save()
            self.changed?()
        }

        let stack = NSStackView(views: [header, sub, grid])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        return stack
    }

    private func buildShortcuts() -> NSView {
        let header = headerRow(glyph: Icons.keyboard, title: "Handy shortcuts")
        let sub = Label.make("The essentials - every one of them is rebindable.",
                             size: 12.5, opacity: 0.6)

        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 4
        list.translatesAutoresizingMaskIntoConstraints = false

        let highlights = ["newTab", "closeTab", "toggleSearch", "openSettings", "toggleSidebar"]
        for id in highlights {
            guard let action = Shortcuts.actions.first(where: { $0.id == id }) else { continue }
            let row = NSView()
            row.translatesAutoresizingMaskIntoConstraints = false
            let name = Label.make(action.displayName, size: 13)
            let chip = ChromeView(fill: .iconChip)
            chip.cornerRadius = 5
            chip.translatesAutoresizingMaskIntoConstraints = false
            let keys = Label.make(Shortcuts.symbolic(Shortcuts.binding(settings, id)), size: 12)
            chip.addSubview(keys)
            row.addSubview(name)
            row.addSubview(chip)
            NSLayoutConstraint.activate([
                row.heightAnchor.constraint(equalToConstant: 30),
                name.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 2),
                name.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                chip.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -2),
                chip.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                chip.heightAnchor.constraint(equalToConstant: 22),
                keys.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 9),
                keys.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -9),
                keys.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
            ])
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }

        let stack = NSStackView(views: [header, sub, list])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        return stack
    }

    private func buildDone() -> NSView {
        let icon = Label.icon(Icons.check, size: 44)
        icon.alignment = .center
        let title = Label.make("You're all set", size: 20, weight: .semibold)
        title.alignment = .center
        let sub = Label.make(
            "Themes, shells, keybindings and more live in Settings (\(Shortcuts.symbolic(Shortcuts.binding(settings, "openSettings")))).",
            size: 13, opacity: 0.6, wraps: true)
        sub.alignment = .center

        let stack = NSStackView(views: [icon, title, sub])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        return stack
    }

    private func headerRow(glyph: String, title: String) -> NSView {
        let stack = NSStackView(views: [Label.icon(glyph, size: 19),
                                        Label.make(title, size: 17, weight: .semibold)])
        stack.orientation = .horizontal
        stack.spacing = 10
        return stack
    }

    // ---------------------------------------------------------------- footer

    private func buildFooter() {
        skipButton = PushButton(title: "Skip", fontSize: 12)
        skipButton.onClick = { [weak self] in self?.finish() }

        backButton = PushButton(title: "Back")
        backButton.onClick = { [weak self] in self?.advance(-1) }

        nextButton = PushButton(title: "Get started")
        nextButton.isAccent = true
        nextButton.onClick = { [weak self] in self?.advance(+1) }

        dots.orientation = .horizontal
        dots.spacing = 7
        dots.translatesAutoresizingMaskIntoConstraints = false
        for _ in 0..<4 {
            let dot = DotView()
            dots.addArrangedSubview(dot)
        }

        let right = NSStackView(views: [backButton, nextButton])
        right.orientation = .horizontal
        right.spacing = 8
        right.translatesAutoresizingMaskIntoConstraints = false

        panel.addSubview(skipButton)
        panel.addSubview(dots)
        panel.addSubview(right)

        NSLayoutConstraint.activate([
            skipButton.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 28),
            skipButton.topAnchor.constraint(equalTo: body.bottomAnchor, constant: 16),
            skipButton.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -20),
            dots.centerXAnchor.constraint(equalTo: panel.centerXAnchor),
            dots.centerYAnchor.constraint(equalTo: skipButton.centerYAnchor),
            right.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -28),
            right.centerYAnchor.constraint(equalTo: skipButton.centerYAnchor),
        ])
    }

    private func advance(_ direction: Int) {
        let next = step + direction
        if next >= steps.count {
            finish()
            return
        }
        step = max(0, next)
        updateStep()
    }

    private func updateStep() {
        for (index, view) in steps.enumerated() { view.isHidden = index != step }
        backButton.isHidden = step == 0
        nextButton.setTitle(step == 0 ? "Get started"
                            : (step == steps.count - 1 ? "Start using Zharp" : "Next"))
        skipButton.isHidden = step == steps.count - 1
        for (index, dot) in dots.arrangedSubviews.enumerated() {
            (dot as? DotView)?.isActive = index == step
        }
    }

    private func finish() {
        settings.onboarded = true
        settings.save()
        finished?()
    }
}

/// One page indicator dot.
final class DotView: NSView {
    var isActive = false { didSet { needsDisplay = true } }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 7),
            heightAnchor.constraint(equalToConstant: 7),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func draw(_ dirtyRect: NSRect) {
        (isActive ? Chrome.current.text : Chrome.current.text.withAlphaComponent(0.25)).setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}
