import AppKit
import ZharpCore

/// Colors for the floating block chrome (hover chip, find bar, menus). These
/// derive from the TERMINAL palette rather than the app chrome, so an overlay
/// sitting on the terminal surface belongs to it.
struct OverlayColors {
    var background: NSColor
    var backgroundHover: NSColor
    var backgroundActive: NSColor
    var inputBackground: NSColor
    var hover: NSColor
    var active: NSColor
    var accent: NSColor
    var border: NSColor
    var foreground: NSColor
    var foregroundDim: NSColor
    /// True when the terminal background is dark, so built-in control visuals
    /// (caret, focus ring, menus) can be told which way to render.
    var isDark: Bool

    static func make(_ palette: Palette) -> OverlayColors {
        let bg = palette.defaultBackground
        let fg = palette.defaultForeground

        func blend(_ t: Double, _ alpha: Double) -> NSColor {
            func channel(_ shift: UInt32) -> CGFloat {
                let base = Double((bg >> shift) & 0xFF)
                let over = Double((fg >> shift) & 0xFF)
                return CGFloat(((1 - t) * base + t * over) / 255.0)
            }
            return NSColor(srgbRed: channel(16), green: channel(8), blue: channel(0),
                           alpha: CGFloat(alpha))
        }
        func fgAlpha(_ alpha: UInt32) -> NSColor {
            ChromeColors.rgb(fg, alpha: Double(alpha) / 255.0)
        }

        let lum = (0.299 * Double((bg >> 16) & 0xFF)
                   + 0.587 * Double((bg >> 8) & 0xFF)
                   + 0.114 * Double(bg & 0xFF)) / 255.0

        return OverlayColors(
            background: blend(0.07, Double(0xFA) / 255.0),
            backgroundHover: blend(0.15, Double(0xFA) / 255.0),
            backgroundActive: blend(0.22, Double(0xFA) / 255.0),
            inputBackground: blend(0.13, 1.0),
            hover: fgAlpha(0x17),
            active: fgAlpha(0x26),
            accent: ChromeColors.rgb(palette.cursorColor, alpha: Double(0x59) / 255.0),
            border: fgAlpha(0x2A),
            foreground: fgAlpha(0xE6),
            foregroundDim: fgAlpha(0x78),
            isDark: lum < 0.5
        )
    }
}

/// A small overlay button: an SF Symbol or a short label on a rounded plate.
final class OverlayButton: NSView {
    enum Content {
        case symbol(String)
        case text(String)
    }

    private let content: Content
    private let pointSize: CGFloat
    private var hovering = false
    private var pressed = false
    private var trackingAreaRef: NSTrackingArea?

    var colors: OverlayColors? { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    /// Toggles render with the accent plate when on.
    var isToggle = false
    var isOn = false { didSet { needsDisplay = true } }
    /// Plated buttons carry the panel background; bare ones are transparent.
    var isPlated = false

    override var isFlipped: Bool { true }

    init(content: Content, pointSize: CGFloat, width: CGFloat, height: CGFloat) {
        self.content = content
        self.pointSize = pointSize
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: width),
            heightAnchor.constraint(equalToConstant: height),
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

    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; pressed = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { pressed = true; needsDisplay = true }

    override func mouseUp(with event: NSEvent) {
        let wasPressed = pressed
        pressed = false
        needsDisplay = true
        if wasPressed, bounds.contains(convert(event.locationInWindow, from: nil)) {
            if isToggle { isOn.toggle() }
            onClick?()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let colors else { return }

        let plate: NSColor?
        if isToggle, isOn {
            plate = colors.accent
        } else if pressed {
            plate = isPlated ? colors.backgroundActive : colors.active
        } else if hovering {
            plate = isPlated ? colors.backgroundHover : colors.hover
        } else {
            plate = isPlated ? colors.background : nil
        }
        if let plate {
            plate.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: isPlated ? 6 : 5,
                         yRadius: isPlated ? 6 : 5).fill()
        }
        if isPlated {
            colors.border.setStroke()
            let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                      xRadius: 6, yRadius: 6)
            border.lineWidth = 1
            border.stroke()
        }

        let tint = (isToggle && !isOn) ? colors.foregroundDim : colors.foreground
        switch content {
        case .symbol(let name):
            // SF Symbols rather than the icon webfont: the subset Windows ships
            // carries no chevrons or ellipsis, and these are system-native.
            let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
            guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(config) else { return }
            let size = image.size
            let rect = NSRect(x: (bounds.width - size.width) / 2,
                              y: (bounds.height - size.height) / 2,
                              width: size.width, height: size.height)
            image.isTemplate = true
            // The tint has to be applied where the glyph is ALONE, not over the
            // plate. `sourceAtop` paints wherever the destination is opaque, and
            // the plate has already filled the whole rect by this point, so
            // tinting in place turns the glyph into a solid block. Colouring it
            // in an offscreen image, whose background starts transparent, keeps
            // the fill inside the glyph's own pixels.
            let tinted = NSImage(size: size, flipped: false) { bounds in
                image.draw(in: bounds)
                tint.set()
                bounds.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                        respectFlipped: true, hints: nil)
        case .text(let label):
            let text = NSAttributedString(string: label, attributes: [
                .font: NSFont.systemFont(ofSize: pointSize),
                .foregroundColor: tint,
            ])
            let size = text.size()
            text.draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                                  y: (bounds.height - size.height) / 2))
        }
    }
}

/// The panel plate behind the find bar: rounded, bordered, and it swallows its
/// own mouse presses so a click never starts a terminal text selection.
final class OverlayPanel: NSView {
    var colors: OverlayColors? { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let colors else { return }
        colors.background.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        colors.border.setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                  xRadius: 8, yRadius: 8)
        border.lineWidth = 1
        border.stroke()
    }

    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
}

/// The find field. Subclassed so Enter / Shift+Enter / Escape drive the search
/// instead of leaking to the terminal.
final class FindTextField: NSTextField {
    var onStep: ((Int) -> Void)?
    var onClose: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first else {
            return super.performKeyEquivalent(with: event)
        }
        switch Int(scalar.value) {
        case 0x0D, 0x03: // Return / Enter
            onStep?(event.modifierFlags.contains(.shift) ? -1 : +1)
            return true
        case 0x1B: // Escape
            onClose?()
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }
}

/// A menu item that runs a closure, with an optional shortcut shown at the right.
final class BlockMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, binding: String?, enabled: Bool = true, action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        isEnabled = enabled
        if let binding, let combo = Shortcuts.parse(binding) {
            keyEquivalent = Shortcuts.keyEquivalent(for: combo.virtualKey)
            keyEquivalentModifierMask = combo.modifiers
        }
    }

    required init(coder: NSCoder) { fatalError("not supported") }

    @objc private func fire() { handler() }
}
