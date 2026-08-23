import Foundation

/// A grid of cells with optional scrollback. The emulator owns two of these
/// (main + alternate screen) and drives all mutations.
public final class ScreenBuffer {
    private var screen: [TerminalLine] = []
    private var scrollback: [TerminalLine] = []
    private let maxScrollback: Int

    public private(set) var rows: Int
    public private(set) var cols: Int

    public var hasScrollback: Bool { maxScrollback > 0 }
    public var scrollbackCount: Int { scrollback.count }
    public var totalLines: Int { scrollback.count + rows }

    /// Scrollback lines ever dropped (trim or clear). Absolute line marks
    /// recorded as droppedLines + index stay valid across drops.
    public private(set) var droppedLines: Int64 = 0

    public init(cols: Int, rows: Int, maxScrollback: Int) {
        self.cols = max(1, cols)
        self.rows = max(1, rows)
        self.maxScrollback = maxScrollback
        for _ in 0..<self.rows {
            screen.append(TerminalLine(cols: self.cols))
        }
    }

    /// Gets a line by screen row (0 = top of visible screen).
    public func screenLine(_ row: Int) -> TerminalLine { screen[row] }

    /// Gets a line by absolute index (0 = oldest scrollback line).
    public func absoluteLine(_ index: Int) -> TerminalLine {
        index < scrollback.count ? scrollback[index] : screen[index - scrollback.count]
    }

    /// Scrolls lines [top, bottom] up by n. When the region starts at the top of a
    /// buffer with scrollback and spans the full height, evicted lines are preserved.
    public func scrollUp(top: Int, bottom: Int, count n: Int, fill: Cell) {
        let n = min(max(n, 0), bottom - top + 1)
        let capture = top == 0 && bottom == rows - 1 && hasScrollback
        for _ in 0..<n {
            let line = screen[top]
            screen.remove(at: top)
            if capture {
                scrollback.append(line)
                screen.insert(TerminalLine(cols: cols, fill: fill), at: bottom)
            } else {
                line.fill(fill)
                screen.insert(line, at: bottom)
            }
        }
        trimScrollback()
    }

    public func scrollDown(top: Int, bottom: Int, count n: Int, fill: Cell) {
        let n = min(max(n, 0), bottom - top + 1)
        for _ in 0..<n {
            let line = screen[bottom]
            screen.remove(at: bottom)
            line.fill(fill)
            screen.insert(line, at: top)
        }
    }

    public func clearScreen(fill: Cell) {
        for line in screen { line.fill(fill) }
    }

    public func clearScrollback() {
        droppedLines += Int64(scrollback.count)
        scrollback.removeAll()
    }

    /// Resizes the buffer. Shrinking prefers dropping blank lines below the cursor,
    /// then pushes top lines into scrollback; growing pulls lines back out.
    /// No text reflow (matches classic conhost behavior).
    public func resize(cols newCols: Int, rows newRows: Int, cursorY: inout Int) {
        let newCols = max(1, newCols)
        let newRows = max(1, newRows)

        if newCols != cols {
            for line in screen { line.resize(cols: newCols) }
            cols = newCols
        }

        if newRows < rows {
            var excess = rows - newRows
            // Drop trailing blank lines first so a shell prompt stays put.
            while excess > 0, screen.count - 1 > cursorY, screen[screen.count - 1].isEmpty() {
                screen.removeLast()
                excess -= 1
            }
            while excess > 0 {
                let line = screen[0]
                screen.remove(at: 0)
                if hasScrollback { scrollback.append(line) }
                if cursorY > 0 { cursorY -= 1 }
                excess -= 1
            }
            trimScrollback()
        } else if newRows > rows {
            var need = newRows - rows
            while need > 0, let line = scrollback.popLast() {
                line.resize(cols: newCols)
                screen.insert(line, at: 0)
                cursorY += 1
                need -= 1
            }
            while need > 0 {
                screen.append(TerminalLine(cols: newCols))
                need -= 1
            }
        }

        rows = newRows
        cursorY = min(max(cursorY, 0), rows - 1)
    }

    private func trimScrollback() {
        // Trim in chunks to amortize the array shift.
        if scrollback.count > maxScrollback + 256 {
            let drop = scrollback.count - maxScrollback
            scrollback.removeFirst(drop)
            droppedLines += Int64(drop)
        }
    }
}
