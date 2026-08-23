import AppKit
import ZharpCore

/// Preview card model for the settings and onboarding theme pickers.
struct ThemeCard {
    let id: String
    let name: String
    let bg: NSColor
    let fg: NSColor
    let accent: NSColor
    let c1: NSColor
    let c2: NSColor
    let c3: NSColor
    let c4: NSColor

    init(_ spec: ThemeSpec) {
        id = spec.id
        name = spec.name
        let palette = spec.createPalette()
        bg = ChromeColors.rgb(palette.defaultBackground, alpha: 1)
        fg = ChromeColors.rgb(palette.defaultForeground, alpha: 1)
        accent = ChromeColors.rgb(palette.cursorColor, alpha: 1)
        c1 = ChromeColors.rgb(palette.colors[1], alpha: 1) // red
        c2 = ChromeColors.rgb(palette.colors[2], alpha: 1) // green
        c3 = ChromeColors.rgb(palette.colors[3], alpha: 1) // yellow
        c4 = ChromeColors.rgb(palette.colors[4], alpha: 1) // blue
    }

    static let all: [ThemeCard] = Themes.all.map(ThemeCard.init)
}

/// One 104x58 theme swatch: two text bars, an accent bar and four ANSI dots,
/// drawn on the theme's own background - the same preview the Windows build
/// composes from XAML rectangles.
final class ThemeCardView: NSView {
    let card: ThemeCard
    var isSelected = false { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?

    private var hovering = false
    private var trackingAreaRef: NSTrackingArea?

    override var isFlipped: Bool { true }

    init(card: ThemeCard) {
        self.card = card
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 112),
            heightAnchor.constraint(equalToConstant: 84),
        ])
        toolTip = card.name
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
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 0),
                         xRadius: 8, yRadius: 8).fill()
        }

        card.bg.setFill()
        let body = NSBezierPath(roundedRect: swatch, xRadius: 6, yRadius: 6)
        body.fill()
        NSColor(white: 0.5, alpha: 0.25).setStroke()
        body.lineWidth = 1
        body.stroke()

        func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ color: NSColor, alpha: CGFloat = 1) {
            color.withAlphaComponent(alpha).setFill()
            NSBezierPath(roundedRect: NSRect(x: swatch.minX + x, y: swatch.minY + y,
                                             width: w, height: 4),
                         xRadius: 2, yRadius: 2).fill()
        }
        bar(10, 9, 58, card.fg)
        bar(10, 18, 38, card.accent, alpha: 0.85)

        for (index, color) in [card.c1, card.c2, card.c3, card.c4].enumerated() {
            color.setFill()
            let dot = NSRect(x: swatch.minX + 10 + CGFloat(index) * 11, y: swatch.minY + 29,
                             width: 7, height: 7)
            NSBezierPath(ovalIn: dot).fill()
        }

        if isSelected {
            Chrome.current.accent.setStroke()
            let ring = NSBezierPath(roundedRect: swatch.insetBy(dx: -1.5, dy: -1.5),
                                    xRadius: 7.5, yRadius: 7.5)
            ring.lineWidth = 2
            ring.stroke()
        }

        let name = NSAttributedString(string: card.name, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: Chrome.current.text,
        ])
        name.draw(at: NSPoint(x: (bounds.width - name.size().width) / 2, y: 63))
    }
}

/// A row of theme swatches with single selection.
final class ThemeGridView: NSView {
    private var cards: [ThemeCardView] = []
    var onSelect: ((String) -> Void)?

    override var isFlipped: Bool { true }

    init(selectedId: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 6
        rows.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rows)

        // Two rows of three, so six themes fit any settings width.
        for chunk in stride(from: 0, to: ThemeCard.all.count, by: 3) {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 6
            for card in ThemeCard.all[chunk..<min(chunk + 3, ThemeCard.all.count)] {
                let view = ThemeCardView(card: card)
                view.isSelected = card.id == selectedId
                view.onClick = { [weak self] in self?.select(card.id) }
                cards.append(view)
                row.addArrangedSubview(view)
            }
            rows.addArrangedSubview(row)
        }

        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: leadingAnchor),
            rows.topAnchor.constraint(equalTo: topAnchor),
            rows.bottomAnchor.constraint(equalTo: bottomAnchor),
            rows.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Selects without notifying - used when re-reading shared settings.
    func setSelection(_ id: String) {
        for card in cards { card.isSelected = card.card.id == id }
    }

    func select(_ id: String) {
        for card in cards { card.isSelected = card.card.id == id }
        onSelect?(id)
    }
}
