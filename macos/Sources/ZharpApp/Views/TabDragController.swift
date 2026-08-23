import AppKit

/// Drives a tab drag: press to arm, move to pick up, reorder live, and on
/// release either keep it here, hand it to another window, or tear it out into
/// a new one.
///
/// AppKit's implicit mouse capture keeps delivering drags and the mouse-up even
/// outside the window, so this needs none of the cursor polling the Windows
/// build does.
final class TabDragController {
    /// How far the pointer must move before a press becomes a drag.
    private static let threshold: CGFloat = 5

    private weak var list: SessionListView?
    /// Held strongly: the row that received mouseDown must outlive a list
    /// rebuild that happens mid-gesture, or AppKit routes drags to a dead view.
    private var pressedRow: SessionRowView?
    private var item: SessionItem?
    private var startScreen: NSPoint = .zero
    private var grabOffset: NSPoint = .zero
    private var ghost: NSWindow?
    private var picked = false

    var isDragging: Bool { picked }

    /// Called when the tab is dropped somewhere this window does not own.
    var onTearOut: ((SessionItem, NSPoint) -> Void)?
    /// Called when the tab is dropped on another Zharp window.
    var onHandOff: ((SessionItem, MainWindowController) -> Void)?
    /// Called whenever the live reorder moves the tab.
    var onReorder: ((SessionItem, Int) -> Void)?

    init(list: SessionListView) {
        self.list = list
    }

    func press(row: SessionRowView, event: NSEvent) {
        pressedRow = row
        item = row.item
        startScreen = NSEvent.mouseLocation
        picked = false
        if let window = row.window {
            let inRow = row.convert(event.locationInWindow, from: nil)
            grabOffset = NSPoint(x: inRow.x, y: inRow.y)
            _ = window
        }
    }

    func drag(event: NSEvent) {
        guard let item else { return }
        let now = NSEvent.mouseLocation
        if !picked {
            let moved = hypot(now.x - startScreen.x, now.y - startScreen.y)
            if moved < Self.threshold { return }
            pickUp(item)
        }
        moveGhost(to: now)
        reorderIfNeeded(at: now)
    }

    func release(event: NSEvent) {
        defer { reset() }
        guard picked, let item else { return }

        let drop = NSEvent.mouseLocation
        // The ghost still answers "what is under the cursor", even with
        // ignoresMouseEvents - so it has to go before the hit test, or every
        // drop reads as "outside".
        closeGhost()

        if let target = MainWindowController.controller(under: drop) {
            if target !== list?.owner {
                onHandOff?(item, target)
            }
            // Same window: the live reorder already put it where it belongs.
        } else {
            onTearOut?(item, drop)
        }
    }

    /// Aborts a drag in flight - a window closing mid-gesture would otherwise
    /// leave the ghost on screen, keeping the process alive.
    func cancel() {
        closeGhost()
        reset()
    }

    private func reset() {
        item?.dragOpacity = 1
        pressedRow = nil
        item = nil
        picked = false
    }

    // ---------------------------------------------------------------- ghost

    private func pickUp(_ item: SessionItem) {
        picked = true
        item.dragOpacity = 0.35
        list?.refreshLabels()
        buildGhost(for: item)
    }

    private func buildGhost(for item: SessionItem) {
        let size = NSSize(width: 190, height: 30)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.ignoresMouseEvents = true
        // Never let the ghost keep the app alive or take key focus.
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.transient, .ignoresCycle]

        let plate = GhostPlate(frame: NSRect(origin: .zero, size: size))
        plate.configure(glyph: item.hasAgent ? item.agentGlyph : item.iconGlyph,
                        tint: item.agentColor ?? Chrome.current.barIcon,
                        title: item.displayTitle)
        window.contentView = plate
        window.orderFront(nil)
        ghost = window
    }

    private func moveGhost(to point: NSPoint) {
        guard let ghost else { return }
        ghost.setFrameOrigin(NSPoint(x: point.x - grabOffset.x,
                                     y: point.y - ghost.frame.height + grabOffset.y))
    }

    private func closeGhost() {
        ghost?.orderOut(nil)
        ghost?.close()
        ghost = nil
    }

    // ---------------------------------------------------------------- reorder

    /// Live reorder: as the pointer passes a neighbour, the tab moves in the
    /// backing list straight away. There is no insertion caret.
    private func reorderIfNeeded(at screenPoint: NSPoint) {
        guard let list, let item, let window = list.window else { return }
        let inWindow = window.convertPoint(fromScreen: screenPoint)
        let local = list.convert(inWindow, from: nil)
        guard list.bounds.insetBy(dx: -20, dy: -20).contains(local) else { return }
        guard let index = list.indexForDrop(at: local), index != list.indexOf(item) else { return }
        onReorder?(item, index)
    }
}

/// The little plate that follows the cursor during a drag.
final class GhostPlate: NSView {
    private let icon = NSTextField(labelWithString: "")
    private let title = NSTextField(labelWithString: "")

    override var isFlipped: Bool { true }

    func configure(glyph: String, tint: NSColor, title text: String) {
        icon.stringValue = glyph
        icon.font = Icons.font(size: 14)
        icon.textColor = tint
        icon.translatesAutoresizingMaskIntoConstraints = false
        title.stringValue = text
        title.font = NSFont.systemFont(ofSize: 12)
        title.textColor = Chrome.current.text
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false

        addSubview(icon)
        addSubview(title)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    override func draw(_ dirtyRect: NSRect) {
        Chrome.current.floatingPanel.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        Chrome.current.hairline.setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                  xRadius: 7, yRadius: 7)
        border.lineWidth = 1
        border.stroke()
    }
}
