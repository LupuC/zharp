import AppKit
import CoreText

/// A flat view whose background comes from the active chrome palette, so a
/// theme change is a single `refreshChrome()` walk instead of a rebuild.
class ChromeView: NSView {
    enum Fill {
        case none
        case wash
        case panelOverlay
        case floatingPanel
        case iconChip
        case hairline
        case custom(NSColor)
    }

    var fill: Fill = .none { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 0 { didSet { needsDisplay = true } }
    /// Edge insets that get a 1px hairline border: (top, left, bottom, right).
    var hairlineEdges: NSEdgeInsets = NSEdgeInsets()

    override var isFlipped: Bool { true }

    init(fill: Fill = .none) {
        self.fill = fill
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func color(for fill: Fill) -> NSColor? {
        switch fill {
        case .none: return nil
        case .wash: return Chrome.current.chromeWash
        case .panelOverlay: return Chrome.current.panelOverlay
        case .floatingPanel: return Chrome.current.floatingPanel
        case .iconChip: return Chrome.current.iconChip
        case .hairline: return Chrome.current.hairline
        case .custom(let c): return c
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if let background = color(for: fill) {
            background.setFill()
            if cornerRadius > 0 {
                NSBezierPath(roundedRect: bounds, xRadius: cornerRadius,
                             yRadius: cornerRadius).fill()
            } else {
                bounds.fill()
            }
        }

        let hairline = Chrome.current.hairline
        hairline.setFill()
        if hairlineEdges.top > 0 {
            NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        }
        if hairlineEdges.bottom > 0 {
            NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        }
        if hairlineEdges.left > 0 {
            NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
        }
        if hairlineEdges.right > 0 {
            NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()
        }
    }
}

/// A square icon button drawn from the Tabler webfont, with the rounded hover
/// backplate the Windows title bar uses.
final class IconButton: NSView {
    private var glyph: String
    private var glyphSize: CGFloat
    private var hovering = false
    private var pressed = false
    private var trackingAreaRef: NSTrackingArea?

    var onClick: (() -> Void)?
    /// Shown instead of the plain hover backplate (used by the close button).
    var dangerHover = false
    var tint: NSColor?
    var cornerRadius: CGFloat = 5

    override var isFlipped: Bool { true }

    init(glyph: String, glyphSize: CGFloat = 18, side: CGFloat = 28) {
        self.glyph = glyph
        self.glyphSize = glyphSize
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: side).isActive = true
        heightAnchor.constraint(equalToConstant: side).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func setGlyph(_ glyph: String, size: CGFloat? = nil) {
        self.glyph = glyph
        if let size { glyphSize = size }
        needsDisplay = true
    }

    /// Resizes the button and its glyph for the current chrome zoom.
    func setMetrics(side: CGFloat, glyphSize: CGFloat) {
        for constraint in constraints {
            if constraint.firstAttribute == .width { constraint.constant = side }
            if constraint.firstAttribute == .height { constraint.constant = side }
        }
        self.glyphSize = glyphSize
        needsDisplay = true
    }

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
    override func mouseExited(with event: NSEvent) { hovering = false; pressed = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { pressed = true; needsDisplay = true }

    override func mouseUp(with event: NSEvent) {
        let wasPressed = pressed
        pressed = false
        needsDisplay = true
        if wasPressed && bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick?()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovering || pressed {
            let backplate: NSColor
            if dangerHover {
                backplate = NSColor(srgbRed: 0xC4 / 255.0, green: 0x2B / 255.0,
                                    blue: 0x1C / 255.0, alpha: pressed ? 0.9 : 1.0)
            } else {
                backplate = pressed ? Chrome.current.rowSelected : Chrome.current.rowHover
            }
            backplate.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).fill()
        }

        let color: NSColor = (dangerHover && (hovering || pressed))
            ? .white
            : (tint ?? Chrome.current.barIcon)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Icons.font(size: glyphSize),
            .foregroundColor: color,
        ]
        let text = NSAttributedString(string: glyph, attributes: attributes)
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                              y: (bounds.height - size.height) / 2))
    }
}

/// An icon button that can carry a short label beside its glyph, so its width
/// follows its content instead of being pinned square. Everything else (the
/// hover backplate, the corner radius, the tint) is `IconButton`'s.
///
/// The label sits BEFORE the glyph: it grows from "+9" to "+1204" as you work,
/// and putting it after would walk the icon along the title bar while you were
/// looking at it.
final class ChipButton: NSView {
    private var glyph: String
    private var glyphSize: CGFloat
    private var side: CGFloat
    private var hovering = false
    private var pressed = false
    private var trackingAreaRef: NSTrackingArea?

    var onClick: (() -> Void)?
    var tint: NSColor?
    var cornerRadius: CGFloat = 5

    /// Attributed rather than plain because the counts are two-tone: a green
    /// `+n` next to a red `-n`, in the terminal palette's own colours.
    var label: NSAttributedString? {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    override var isFlipped: Bool { true }

    init(glyph: String, glyphSize: CGFloat = 18, side: CGFloat = 28) {
        self.glyph = glyph
        self.glyphSize = glyphSize
        self.side = side
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: side).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Resizes the button and its glyph for the current chrome zoom.
    func setMetrics(side: CGFloat, glyphSize: CGFloat) {
        self.side = side
        self.glyphSize = glyphSize
        for constraint in constraints where constraint.firstAttribute == .height {
            constraint.constant = side
        }
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: max(side, contentWidth() + leadPadding + trailPadding), height: side)
    }

    /// Matches the Windows chip's 6,0,8,0 padding: a little more room on the
    /// glyph's side so it is not crowded against the next control.
    private var leadPadding: CGFloat { 6 * side / 28 }
    private var trailPadding: CGFloat { 8 * side / 28 }
    private var labelGap: CGFloat { 6 * side / 28 }

    private func glyphText() -> NSAttributedString {
        NSAttributedString(string: glyph, attributes: [
            .font: Icons.font(size: glyphSize),
            .foregroundColor: tint ?? Chrome.current.barIcon,
        ])
    }

    private func contentWidth() -> CGFloat {
        let glyphWidth = glyphText().size().width
        guard let label, label.length > 0 else { return glyphWidth }
        return label.size().width + labelGap + glyphWidth
    }

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
    override func mouseExited(with event: NSEvent) { hovering = false; pressed = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { pressed = true; needsDisplay = true }

    override func mouseUp(with event: NSEvent) {
        let wasPressed = pressed
        pressed = false
        needsDisplay = true
        if wasPressed && bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick?()
        }
    }

    func refreshChrome() {
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovering || pressed {
            let backplate = pressed ? Chrome.current.rowSelected : Chrome.current.rowHover
            backplate.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).fill()
        }

        var x = (bounds.width - contentWidth()) / 2
        if let label, label.length > 0 {
            let size = label.size()
            label.draw(at: NSPoint(x: x, y: (bounds.height - size.height) / 2))
            x += size.width + labelGap
        }
        let text = glyphText()
        let size = text.size()
        text.draw(at: NSPoint(x: x, y: (bounds.height - size.height) / 2))
    }
}

/// Single-line text that fades out on overflow instead of being trimmed with an
/// ellipsis. `tailFirst` picks which end survives: the TAIL for paths (fade the
/// left edge in), the HEAD for commands and status lines (fade the right edge
/// out). The direct port of the Windows build's `TailTextBlock`.
final class TailTextField: NSView {
    private static let fadeWidth: CGFloat = 28

    var text: String = "" { didSet { needsDisplay = true } }
    var fontSize: CGFloat = 12 { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var emphasisBold = false { didSet { needsDisplay = true } }
    /// Right-align the text when it fits (it already right-aligns on overflow).
    var alignTrailing = false { didSet { needsDisplay = true } }
    /// On overflow: true keeps the TAIL visible (paths), false keeps the HEAD
    /// visible and fades the right edge out (commands).
    var tailFirst = true { didSet { needsDisplay = true } }
    /// Explicit text color; nil = the theme color.
    var tint: NSColor? { didSet { needsDisplay = true } }
    var textColor: NSColor?
    var opacity: CGFloat = 1.0 { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: ceil(fontSize * 1.45))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty, bounds.width > 1 else { return }

        let font = NSFont.systemFont(ofSize: fontSize,
                                     weight: emphasisBold ? .semibold : .regular)
        let color = (tint ?? textColor ?? Chrome.current.text).withAlphaComponent(opacity)
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: color,
        ])
        let textWidth = attributed.size().width
        let y = max(0, (bounds.height - attributed.size().height) / 2)

        if textWidth <= bounds.width {
            let x = alignTrailing ? bounds.width - textWidth : 0
            attributed.draw(at: NSPoint(x: x, y: y))
            return
        }

        // Overflow: draw the text into a transparency layer and mask it with a
        // linear alpha ramp, so the losing end fades rather than clipping.
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        // The alpha ramp below only covers the band between its start and end
        // points, so everything past that band is never blended and keeps full
        // alpha. The overflowing text then draws outside this view entirely,
        // straight over whatever sits beside it, which in the session list is
        // the close button. Clipping bounds the damage; the ramp still does the
        // fading, and it reaches zero exactly at the edge we clip on, so the cut
        // itself is invisible.
        ctx.clip(to: bounds)
        let clear = NSColor.black.withAlphaComponent(0).cgColor
        let solid = NSColor.black.cgColor
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        if tailFirst {
            // Right-align so the tail stays visible, fade the left edge in.
            attributed.draw(at: NSPoint(x: bounds.width - textWidth, y: y))
            ctx.setBlendMode(.destinationIn)
            if let mask = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(),
                                     colors: [clear, solid] as CFArray, locations: [0, 1]) {
                ctx.drawLinearGradient(mask, start: CGPoint(x: 0, y: 0),
                                       end: CGPoint(x: Self.fadeWidth, y: 0),
                                       options: [.drawsAfterEndLocation])
            }
        } else {
            // Left-align so the head stays visible, fade the right edge out.
            attributed.draw(at: NSPoint(x: 0, y: y))
            ctx.setBlendMode(.destinationIn)
            if let mask = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(),
                                     colors: [solid, clear] as CFArray, locations: [0, 1]) {
                ctx.drawLinearGradient(mask,
                                       start: CGPoint(x: bounds.width - Self.fadeWidth, y: 0),
                                       end: CGPoint(x: bounds.width, y: 0),
                                       options: [.drawsBeforeStartLocation])
            }
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }
}

/// A list row with the rounded hover/selection backplate WinUI's retemplated
/// `ListViewItem` draws.
class RoundedRowView: ChromeView {
    var isSelected = false { didSet { needsDisplay = true } }
    private(set) var isHovering = false
    private var trackingAreaRef: NSTrackingArea?

    var onClick: (() -> Void)?
    var onHoverChanged: ((Bool) -> Void)?

    override init(fill: Fill = .none) {
        super.init(fill: fill)
        cornerRadius = 6
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

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        needsDisplay = true
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        needsDisplay = true
        onHoverChanged?(false)
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func draw(_ dirtyRect: NSRect) {
        let backplate: NSColor? = isSelected
            ? Chrome.current.rowSelected
            : (isHovering ? Chrome.current.rowHover : nil)
        if let backplate {
            backplate.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).fill()
        }
        super.draw(dirtyRect)
    }
}

/// Convenience factory for the label styles the settings pages use.
enum Label {
    static func make(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
                     color: NSColor? = nil, opacity: CGFloat = 1.0,
                     wraps: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = NSFont.systemFont(ofSize: size, weight: weight)
        field.textColor = (color ?? Chrome.current.text).withAlphaComponent(opacity)
        field.lineBreakMode = wraps ? .byWordWrapping : .byTruncatingTail
        field.maximumNumberOfLines = wraps ? 0 : 1
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    static func icon(_ glyph: String, size: CGFloat = 16, color: NSColor? = nil) -> NSTextField {
        let field = NSTextField(labelWithString: glyph)
        field.font = Icons.font(size: size)
        field.textColor = color ?? Chrome.current.barIcon
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }
}

/// Walks a view tree and lets every chrome-aware view repaint after a theme or
/// zoom change - the counterpart of the Windows build's `ChromeZoom` walker.
enum ChromeRefresh {
    static func apply(to view: NSView) {
        view.needsDisplay = true
        if let field = view as? NSTextField, !field.isEditable {
            // Labels carry a resolved color; re-resolve it against the new theme.
            if let tag = field.identifier?.rawValue, tag == "icon" {
                field.textColor = Chrome.current.barIcon
            } else if field.textColor?.alphaComponent ?? 1 > 0.99 {
                field.textColor = Chrome.current.text
            } else {
                field.textColor = Chrome.current.text
                    .withAlphaComponent(field.textColor?.alphaComponent ?? 1)
            }
        }
        for child in view.subviews { apply(to: child) }
    }
}

/// A clip view with a flipped coordinate system, so a scroll view's document
/// anchors at the TOP - AppKit anchors it to the bottom otherwise, which would
/// hang short session lists off the wrong edge.
final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

/// Turns a scroll view into a top-anchored, transparent container.
enum ScrollBox {
    static func configure(_ scrollView: NSScrollView, document: NSView,
                          horizontal: Bool = false) {
        scrollView.contentView = FlippedClipView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = !horizontal
        scrollView.hasHorizontalScroller = horizontal
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = document
    }
}

/// Claims the pointer for a view that floats over the terminal.
///
/// The terminal covers itself with an I-beam cursor rect; overlapping cursor
/// rects resolve by hierarchy order, which is fragile. A `.cursorUpdate`
/// tracking area is resolved by hit-testing instead, so the front-most view
/// always wins.
final class CursorClaim {
    private weak var view: NSView?
    private var area: NSTrackingArea?
    private let cursor: NSCursor

    init(view: NSView, cursor: NSCursor = .arrow) {
        self.view = view
        self.cursor = cursor
    }

    func update() {
        guard let view else { return }
        if let area { view.removeTrackingArea(area) }
        let next = NSTrackingArea(rect: view.bounds,
                                  options: [.cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                                  owner: view, userInfo: nil)
        view.addTrackingArea(next)
        area = next
    }

    func set() { cursor.set() }
}

/// The title-bar "Update available" pill. A subtle tinted capsule: red enough
/// to notice, quiet enough to sit in the title bar without reading as an error.
final class UpdateBadgeButton: NSView {
    private let iconLabel = NSTextField(labelWithString: "↑")
    private let textLabel = NSTextField(labelWithString: "Update available")
    private var hovering = false
    private var pressed = false
    private var trackingAreaRef: NSTrackingArea?

    var onClick: (() -> Void)?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        iconLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        textLabel.font = NSFont.systemFont(ofSize: 11.5)
        for label in [iconLabel, textLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.isBezeled = false
            label.drawsBackground = false
            label.isEditable = false
        }

        let stack = NSStackView(views: [iconLabel, textLabel])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 22),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
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

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; pressed = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { pressed = true; needsDisplay = true }

    override func mouseUp(with event: NSEvent) {
        let wasPressed = pressed
        pressed = false
        needsDisplay = true
        if wasPressed && bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick?()
        }
    }

    func refreshChrome() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let base = Chrome.current.updateBadgeBackground
        // Hover and press lift the tint the way the Windows badge does.
        let alphaBoost: CGFloat = pressed ? 0.12 : (hovering ? 0.08 : 0)
        base.withAlphaComponent(Swift.min(1, base.alphaComponent + alphaBoost)).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2,
                     yRadius: bounds.height / 2).fill()

        let fg = Chrome.current.updateBadgeForeground
        let lifted = (hovering || pressed)
            ? fg.blended(withFraction: 0.35, of: .white) ?? fg
            : fg
        iconLabel.textColor = lifted
        textLabel.textColor = lifted
    }
}
