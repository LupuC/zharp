import Foundation

/// The terminal emulator: owns the main and alternate screen buffers, cursor,
/// attributes and modes, and executes the VT actions produced by the parser.
/// All access (feed / resize / rendering reads) must hold `syncRoot`;
/// `feed` and `resize` take it themselves.
public final class TerminalEmulator {
    public let syncRoot = NSRecursiveLock()

    private var parser: VtParser!
    private var utf8 = Utf8Decoder()

    private let main: ScreenBuffer
    private let alt: ScreenBuffer
    private var active: ScreenBuffer

    public private(set) var cols: Int
    public private(set) var rows: Int

    // Cursor
    public private(set) var cursorX = 0
    public private(set) var cursorY = 0
    public private(set) var cursorVisible = true
    /// DECSCUSR style: 0-2 block, 3-4 underline, 5-6 bar.
    public private(set) var cursorStyle = 0
    public private(set) var wrapPending = false

    // Current attributes
    private var fg: TerminalColor = .default
    private var bg: TerminalColor = .default
    private var flags: CellFlags = .none

    // Modes
    public private(set) var applicationCursorKeys = false
    public private(set) var applicationKeypad = false
    public private(set) var bracketedPaste = false
    public private(set) var focusEvents = false
    public var isAlternateBuffer: Bool { active === alt }
    private var originMode = false
    private var autoWrap = true
    private var insertMode = false
    private var lineFeedMode = false
    private var mouseMode = 0 // 1000/1002/1003, informational only for now

    // Scroll region (0-based, inclusive)
    private var regionTop = 0
    private var regionBottom = 0

    // Charsets (G0/G1 designators, 'B' = ASCII, '0' = DEC line drawing)
    private var g0: Character = "B"
    private var g1: Character = "B"
    private var activeCharset = 0

    private var tabStops: [Bool]
    private var lastPrinted = -1

    private struct SavedCursor {
        var x = 0
        var y = 0
        var fg: TerminalColor = .default
        var bg: TerminalColor = .default
        var flags: CellFlags = .none
        var g0: Character = "B"
        var g1: Character = "B"
        var activeCharset = 0
        var originMode = false
        var autoWrap = true
    }

    private var savedMain = SavedCursor()
    private var savedAlt = SavedCursor()

    public private(set) var title: String?

    /// Shell-reported current directory (OSC 7 / OSC 9;9), if any.
    public private(set) var workingDirectory: String?

    private var promptMarksRaw: [Int64] = []

    /// Absolute main-buffer line where the shell last drew its prompt,
    /// or -1 when no prompt has been seen. Derived from OSC 133;A, which the
    /// injected shell hooks emit on every prompt render.
    public var promptMarkLine: Int {
        guard let last = promptMarksRaw.last else { return -1 }
        return Int(max(0, last - main.droppedLines))
    }

    /// All known prompt-line marks (ascending absolute main-buffer lines),
    /// for block-style rendering. Call under `syncRoot`.
    public func getPromptMarks() -> [Int] {
        var marks: [Int] = []
        marks.reserveCapacity(promptMarksRaw.count)
        let dropped = main.droppedLines
        for raw in promptMarksRaw {
            let abs = raw - dropped
            if abs >= 0 { marks.append(Int(abs)) }
        }
        return marks
    }

    /// Raised when a fresh prompt appears after a command block: the argument is
    /// the command the user ran in that block (from the prompt-end mark to the
    /// end of its soft-wrap chain). Not raised for empty prompts.
    public var commandExecuted: ((String) -> Void)?

    /// Raised when the shell draws a fresh prompt below the last one, so
    /// whatever was running in the foreground has exited.
    ///
    /// This is the only completely reliable way to know an agent is gone. An
    /// agent's own "session ended" hook fires while its process is tearing
    /// itself down, which is the worst possible moment to be asking it to write
    /// to the terminal, and a report that never arrives leaves a tab claiming
    /// to be busy forever. A prompt coming back cannot be missed, and it works
    /// just as well for the agents that report nothing at all.
    ///
    /// Single subscriber, like the callbacks around it.
    public var promptReturned: (() -> Void)?

    private var promptEndMarksRaw: [(line: Int64, col: Int)] = []

    private func recordPromptMark() {
        let raw = main.droppedLines + Int64(main.scrollbackCount) + Int64(cursorY)

        // A genuinely NEW prompt below the last one means the previous block
        // just finished - report the command that ran in it.
        let freshPrompt = (promptMarksRaw.last.map { raw > $0 }) ?? false

        if freshPrompt, let prevMark = promptMarksRaw.last, commandExecuted != nil {
            for i in stride(from: promptEndMarksRaw.count - 1, through: 0, by: -1) {
                let (line, col) = promptEndMarksRaw[i]
                if line >= prevMark && line < raw {
                    let command = readCommandText(rawLine: line, fromCol: col, rawLimit: raw)
                    if !command.isEmpty {
                        commandExecuted?(command)
                    }
                    break
                }
            }
        }

        // A prompt re-rendered at or above an old mark (clear, redraw) invalidates
        // the marks below it - keep the list strictly ascending.
        while let last = promptMarksRaw.last, last >= raw {
            promptMarksRaw.removeLast()
        }
        while let last = promptEndMarksRaw.last, last.line >= raw {
            promptEndMarksRaw.removeLast()
        }
        promptMarksRaw.append(raw)
        if promptMarksRaw.count > 256 {
            promptMarksRaw.removeFirst()
        }

        // After the bookkeeping, so anyone listening sees settled state.
        if freshPrompt {
            promptReturned?()
        }
    }

    /// OSC 133;B: the prompt finished rendering - the cursor now sits where the
    /// user's command starts. Lets block copy separate the typed command from
    /// the prompt decoration.
    private func recordPromptEnd() {
        let raw = main.droppedLines + Int64(main.scrollbackCount) + Int64(cursorY)
        while let last = promptEndMarksRaw.last, last.line >= raw {
            promptEndMarksRaw.removeLast()
        }
        promptEndMarksRaw.append((raw, cursorX))
        if promptEndMarksRaw.count > 256 {
            promptEndMarksRaw.removeFirst()
        }
    }

    /// All known prompt-end marks as (absolute main-buffer line, column where
    /// the command starts), ascending. Call under `syncRoot`.
    public func getPromptEnds() -> [(line: Int, col: Int)] {
        var ends: [(line: Int, col: Int)] = []
        ends.reserveCapacity(promptEndMarksRaw.count)
        let dropped = main.droppedLines
        for (rawLine, col) in promptEndMarksRaw {
            let abs = rawLine - dropped
            if abs >= 0 { ends.append((Int(abs), col)) }
        }
        return ends
    }

    /// True when the live prompt has a valid prompt-end mark - i.e. the shell
    /// integration is active and the input line's contents are readable.
    /// Call under `syncRoot`.
    public var hasLivePromptInput: Bool {
        if isAlternateBuffer || promptEndMarksRaw.isEmpty || promptMarksRaw.isEmpty {
            return false
        }
        return promptEndMarksRaw[promptEndMarksRaw.count - 1].line
            >= promptMarksRaw[promptMarksRaw.count - 1]
    }

    /// The command currently typed at the live prompt (from the last prompt-end
    /// mark), or nil. Lets the host capture a command on Enter - commands like
    /// clear erase the screen before the next prompt, so waiting for it would
    /// lose them. Call under `syncRoot`.
    public func peekPendingCommand() -> String? {
        if isAlternateBuffer || promptEndMarksRaw.isEmpty || promptMarksRaw.isEmpty {
            return nil
        }
        let (line, col) = promptEndMarksRaw[promptEndMarksRaw.count - 1]
        if line < promptMarksRaw[promptMarksRaw.count - 1] {
            return nil // stale mark from an older prompt
        }
        // Typed input connects the B mark to the cursor along a soft-wrap chain.
        // Prompt re-renders can strand B on a decoration line (a right-aligned
        // clock) with the cursor elsewhere - anything after such a B is
        // decoration, not input.
        let dropped = main.droppedLines
        let bAbs = Int(line - dropped)
        let cursorAbs = main.scrollbackCount + cursorY
        if cursorAbs < bAbs { return nil }
        var reach = bAbs
        while reach < cursorAbs, reach < main.totalLines,
              main.absoluteLine(reach).wrapped, reach - bAbs < 4 {
            reach += 1
        }
        if reach != cursorAbs { return nil }
        // Stop at the cursor: typed text ends there, while right-aligned prompt
        // decorations (clocks etc.) live beyond it on the same row.
        let command = readCommandText(rawLine: line, fromCol: col,
                                      rawLimit: line + 4, stopAtCursor: true)
        return command.isEmpty ? nil : command
    }

    /// The typed command starting at a prompt-end mark, following the soft-wrap
    /// chain (long commands wrap), capped defensively. `stopAtCursor` reads only
    /// up to the caret (live input); otherwise a wide blank gap cuts the rest of
    /// the row off - right-aligned prompt decorations.
    private func readCommandText(rawLine: Int64, fromCol: Int, rawLimit: Int64,
                                 stopAtCursor: Bool = false) -> String {
        var out = ""
        let dropped = main.droppedLines
        let abs = Int(rawLine - dropped)
        let cursorAbs = main.scrollbackCount + cursorY
        let limit = Int(Swift.min(rawLimit - dropped, Int64(abs + 4))) // cap wrap chain
        var i = abs
        while i >= 0 && i < limit && i < main.totalLines {
            let line = main.absoluteLine(i)
            let start = i == abs ? fromCol : 0
            var end = Swift.min(line.cells.count, cols) // shrink leaves stale tails
            if stopAtCursor && i == cursorAbs {
                end = Swift.min(end, cursorX)
            }
            let lineStart = out.count
            var c = start
            while c < end && out.count < 300 {
                let cell = line.cells[c]
                c += 1
                if cell.flags.contains(.wideTrailing) { continue }
                if cell.rune == 0 {
                    out.append(" ")
                } else if let scalar = UnicodeScalar(UInt32(cell.rune)) {
                    out.unicodeScalars.append(scalar)
                }
            }
            while out.count > lineStart, out.hasSuffix(" ") { out.removeLast() }
            if !line.wrapped || out.count >= 300 || (stopAtCursor && i == cursorAbs) {
                break
            }
            i += 1
        }
        var result = out.trimmingCharacters(in: .whitespaces)
        if !stopAtCursor {
            // "dir        19:08" -> "dir": eight-plus consecutive spaces mean the
            // rest of the row is a right prompt, not the command.
            if let gap = result.range(of: "        "), gap.lowerBound != result.startIndex {
                result = String(result[result.startIndex..<gap.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return result
    }

    public var titleChanged: ((String) -> Void)?
    public var workingDirectoryChanged: ((String) -> Void)?
    public var responseRequested: ((String) -> Void)?
    public var bellRang: (() -> Void)?

    /// An AI agent reporting its own state, as the raw JSON body of an
    /// OSC 777 notification addressed to us. Zharp used to work this out by
    /// reading the screen, which could see that an agent was busy but never
    /// that it was waiting on you.
    ///
    /// The body is handed over unparsed and unvalidated: it comes from a script
    /// running in the user's shell, so whoever subscribes treats it as hostile
    /// input that happens to have arrived over an escape sequence.
    ///
    /// Single subscriber, like the callbacks above: assigning twice replaces
    /// rather than adds. Only the owning session subscribes, and anything else
    /// that wants these should hang off it rather than off the emulator.
    public var agentReported: ((String) -> Void)?

    public init(cols: Int, rows: Int, maxScrollback: Int = 10000) {
        self.cols = max(2, cols)
        self.rows = max(2, rows)
        main = ScreenBuffer(cols: self.cols, rows: self.rows, maxScrollback: maxScrollback)
        alt = ScreenBuffer(cols: self.cols, rows: self.rows, maxScrollback: 0)
        active = main
        regionBottom = self.rows - 1
        tabStops = Self.buildTabStops(cols: self.cols)
        parser = VtParser(handler: self)
    }

    /// The buffer currently displayed (main or alternate).
    public var buffer: ScreenBuffer { active }

    /// Scrollback lines available for the current view (alt screen has none).
    public var scrollbackCount: Int { active.scrollbackCount }

    // ---------------------------------------------------------------- input

    public func feed(_ data: UnsafeBufferPointer<UInt8>) {
        syncRoot.lock()
        defer { syncRoot.unlock() }
        utf8.decode(data) { [weak self] rune in
            self?.parser.process(rune)
        }
    }

    public func feed(_ data: [UInt8]) {
        data.withUnsafeBufferPointer { feed($0) }
    }

    public func feed(_ data: Data) {
        data.withUnsafeBytes { raw in
            feed(raw.bindMemory(to: UInt8.self))
        }
    }

    public func feed(text: String) {
        feed(Array(text.utf8))
    }

    public func resize(cols newCols: Int, rows newRows: Int) {
        let newCols = max(2, newCols)
        let newRows = max(2, newRows)
        syncRoot.lock()
        defer { syncRoot.unlock() }

        if newCols == cols && newRows == rows { return }

        var cursorYMain = cursorY
        main.resize(cols: newCols, rows: newRows, cursorY: &cursorYMain)
        var altY = active === alt ? cursorY : 0
        alt.resize(cols: newCols, rows: newRows, cursorY: &altY)
        cursorY = active === main ? cursorYMain : altY

        cols = newCols
        rows = newRows
        cursorX = min(max(cursorX, 0), cols - 1)
        cursorY = min(max(cursorY, 0), rows - 1)
        regionTop = 0
        regionBottom = rows - 1
        tabStops = Self.buildTabStops(cols: cols)
        wrapPending = false
    }

    // ---------------------------------------------------------------- printing

    private static let decGraphics: [Int: Int] = [
        0x60: 0x25C6, 0x61: 0x2592, 0x62: 0x2409, 0x63: 0x240C,
        0x64: 0x240D, 0x65: 0x240A, 0x66: 0x00B0, 0x67: 0x00B1,
        0x68: 0x2424, 0x69: 0x240B, 0x6A: 0x2518, 0x6B: 0x2510,
        0x6C: 0x250C, 0x6D: 0x2514, 0x6E: 0x253C, 0x6F: 0x23BA,
        0x70: 0x23BB, 0x71: 0x2500, 0x72: 0x23BC, 0x73: 0x23BD,
        0x74: 0x251C, 0x75: 0x2524, 0x76: 0x2534, 0x77: 0x252C,
        0x78: 0x2502, 0x79: 0x2264, 0x7A: 0x2265, 0x7B: 0x03C0,
        0x7C: 0x2260, 0x7D: 0x00A3, 0x7E: 0x00B7, 0x5F: 0x20,
    ]

    private func printRune(_ input: Int) {
        var rune = input
        let charset = activeCharset == 0 ? g0 : g1
        if charset == "0", rune >= 0x5F, rune <= 0x7E, let mapped = Self.decGraphics[rune] {
            rune = mapped
        }

        let width = CharWidth.width(of: rune)
        if width == 0 {
            return // combining marks not composed yet - dropped rather than corrupting the grid
        }

        if wrapPending && autoWrap {
            let line = active.screenLine(cursorY)
            line.wrapped = true
            carriageReturn()
            lineFeed()
        }
        wrapPending = false

        if width == 2 && cursorX >= cols - 1 {
            // Wide char doesn't fit in the last column.
            if autoWrap {
                let line = active.screenLine(cursorY)
                line.fillRange(cursorX, cols, makeEraseCell())
                line.wrapped = true
                carriageReturn()
                lineFeed()
            } else {
                cursorX = max(0, cols - 2)
            }
        }

        let row = active.screenLine(cursorY)

        if insertMode {
            let limit = min(cols, row.cells.count)
            var i = limit - 1
            while i > cursorX + width - 1 {
                row.cells[i] = row.cells[i - width]
                i -= 1
            }
        }

        // If we overwrite half of an existing wide char, blank its other half.
        clearWide(at: cursorX, in: row)
        if width == 2 {
            clearWide(at: cursorX + 1, in: row)
        }

        row.cells[cursorX] = Cell(rune: rune, fg: fg, bg: bg, flags: flags)
        if width == 2 && cursorX + 1 < row.cells.count {
            row.cells[cursorX + 1] = Cell(rune: 0, fg: fg, bg: bg,
                                          flags: flags.union(.wideTrailing))
        }

        lastPrinted = rune

        cursorX += width
        if cursorX >= cols {
            cursorX = cols - 1
            if autoWrap { wrapPending = true }
        }
    }

    private func clearWide(at x: Int, in row: TerminalLine) {
        if x < 0 || x >= row.cells.count { return }
        if row.cells[x].flags.contains(.wideTrailing) && x > 0 {
            row.cells[x - 1].rune = 32
            row.cells[x].flags.remove(.wideTrailing)
        } else if x + 1 < row.cells.count && row.cells[x + 1].flags.contains(.wideTrailing) {
            row.cells[x + 1].rune = 32
            row.cells[x + 1].flags.remove(.wideTrailing)
        }
    }

    private func repeatLastCharacter(_ count: Int) {
        if lastPrinted < 0 { return }
        let count = min(count, cols * rows)
        for _ in 0..<count { printRune(lastPrinted) }
    }

    // ---------------------------------------------------------------- cursor & movement

    private func backspace() {
        if wrapPending {
            wrapPending = false
            return
        }
        if cursorX > 0 { cursorX -= 1 }
    }

    private func horizontalTab() {
        wrapPending = false
        var x = cursorX + 1
        while x < cols - 1 && !tabStops[x] { x += 1 }
        cursorX = min(x, cols - 1)
    }

    private func backTab() {
        wrapPending = false
        var x = cursorX - 1
        while x > 0 && !tabStops[x] { x -= 1 }
        cursorX = max(x, 0)
    }

    private func carriageReturn() {
        cursorX = 0
        wrapPending = false
    }

    private func lineFeed() { index() }

    private func index() {
        wrapPending = false
        if cursorY == regionBottom {
            active.scrollUp(top: regionTop, bottom: regionBottom, count: 1, fill: makeEraseCell())
        } else if cursorY < rows - 1 {
            cursorY += 1
        }
    }

    private func reverseIndex() {
        wrapPending = false
        if cursorY == regionTop {
            active.scrollDown(top: regionTop, bottom: regionBottom, count: 1, fill: makeEraseCell())
        } else if cursorY > 0 {
            cursorY -= 1
        }
    }

    private func moveCursor(dx: Int, dy: Int) {
        wrapPending = false
        if dx != 0 {
            cursorX = min(max(cursorX + dx, 0), cols - 1)
        }
        if dy != 0 {
            // Movement is confined to the scroll region when starting inside it.
            let top = cursorY >= regionTop ? regionTop : 0
            let bottom = cursorY <= regionBottom ? regionBottom : rows - 1
            cursorY = min(max(cursorY + dy, top), bottom)
        }
    }

    private func setCursorColumn(_ col: Int) {
        wrapPending = false
        cursorX = min(max(col, 0), cols - 1)
    }

    private func setCursorRow(_ row: Int) {
        wrapPending = false
        var row = row
        if originMode { row += regionTop }
        cursorY = min(max(row, 0), rows - 1)
    }

    private func setCursorPosition(col: Int, row: Int) {
        wrapPending = false
        var row = row
        if originMode {
            row = min(max(row + regionTop, regionTop), regionBottom)
        } else {
            row = min(max(row, 0), rows - 1)
        }
        cursorY = row
        cursorX = min(max(col, 0), cols - 1)
    }

    private func cursorRowForReport() -> Int {
        originMode ? cursorY - regionTop + 1 : cursorY + 1
    }

    private func saveCursor() {
        let slot = SavedCursor(x: cursorX, y: cursorY, fg: fg, bg: bg, flags: flags,
                               g0: g0, g1: g1, activeCharset: activeCharset,
                               originMode: originMode, autoWrap: autoWrap)
        if active === main { savedMain = slot } else { savedAlt = slot }
    }

    private func restoreCursor() {
        let slot = active === main ? savedMain : savedAlt
        cursorX = min(max(slot.x, 0), cols - 1)
        cursorY = min(max(slot.y, 0), rows - 1)
        fg = slot.fg
        bg = slot.bg
        flags = slot.flags
        g0 = slot.g0 == "\0" ? "B" : slot.g0
        g1 = slot.g1 == "\0" ? "B" : slot.g1
        activeCharset = slot.activeCharset
        originMode = slot.originMode
        wrapPending = false
    }

    // ---------------------------------------------------------------- erasing & editing

    private func makeEraseCell() -> Cell {
        Cell(rune: 0, fg: fg, bg: bg, flags: .none)
    }

    private func eraseInDisplay(_ mode: Int) {
        let fill = makeEraseCell()
        switch mode {
        case 0:
            eraseInLine(0)
            if cursorY + 1 < rows {
                for y in (cursorY + 1)..<rows { active.screenLine(y).fill(fill) }
            }
        case 1:
            eraseInLine(1)
            if cursorY > 0 {
                for y in 0..<cursorY { active.screenLine(y).fill(fill) }
            }
        case 2:
            active.clearScreen(fill: fill)
        case 3:
            active.clearScrollback()
        default:
            break
        }
    }

    private func eraseInLine(_ mode: Int) {
        let line = active.screenLine(cursorY)
        let fill = makeEraseCell()
        switch mode {
        case 0: line.fillRange(cursorX, cols, fill)
        case 1: line.fillRange(0, cursorX + 1, fill)
        case 2: line.fill(fill)
        default: break
        }
    }

    private func eraseCharacters(_ count: Int) {
        let line = active.screenLine(cursorY)
        line.fillRange(cursorX, cursorX + count, makeEraseCell())
    }

    private func insertCharacters(_ count: Int) {
        let line = active.screenLine(cursorY)
        let limit = min(cols, line.cells.count)
        let count = min(count, limit - cursorX)
        if count <= 0 { return }
        var i = limit - 1
        while i >= cursorX + count {
            line.cells[i] = line.cells[i - count]
            i -= 1
        }
        line.fillRange(cursorX, cursorX + count, makeEraseCell())
    }

    private func deleteCharacters(_ count: Int) {
        let line = active.screenLine(cursorY)
        let limit = min(cols, line.cells.count)
        let count = min(count, limit - cursorX)
        if count <= 0 { return }
        var i = cursorX
        while i < limit - count {
            line.cells[i] = line.cells[i + count]
            i += 1
        }
        line.fillRange(limit - count, limit, makeEraseCell())
    }

    private func insertLines(_ count: Int) {
        if cursorY < regionTop || cursorY > regionBottom { return }
        active.scrollDown(top: cursorY, bottom: regionBottom, count: count, fill: makeEraseCell())
        cursorX = 0
        wrapPending = false
    }

    private func deleteLines(_ count: Int) {
        if cursorY < regionTop || cursorY > regionBottom { return }
        active.scrollUp(top: cursorY, bottom: regionBottom, count: count, fill: makeEraseCell())
        cursorX = 0
        wrapPending = false
    }

    private func scrollRegion(_ count: Int, up: Bool) {
        if up {
            active.scrollUp(top: regionTop, bottom: regionBottom, count: count, fill: makeEraseCell())
        } else {
            active.scrollDown(top: regionTop, bottom: regionBottom, count: count, fill: makeEraseCell())
        }
    }

    private func setScrollRegion(top1Based: Int, bottom1Based: Int) {
        let top = top1Based <= 0 ? 0 : top1Based - 1
        let bottom = bottom1Based <= 0 ? rows - 1 : bottom1Based - 1
        if bottom <= top || top >= rows { return }
        regionTop = top
        regionBottom = min(bottom, rows - 1)
        setCursorPosition(col: 0, row: 0)
    }

    private func screenAlignmentPattern() {
        let fill = Cell(rune: 0x45, fg: .default, bg: .default) // 'E'
        for y in 0..<rows { active.screenLine(y).fill(fill) }
        regionTop = 0
        regionBottom = rows - 1
        cursorX = 0
        cursorY = 0
    }

    // ---------------------------------------------------------------- modes

    private func setAnsiModes(_ parameters: [[Int]], _ set: Bool) {
        for group in parameters where !group.isEmpty {
            switch group[0] {
            case 4: insertMode = set
            case 20: lineFeedMode = set
            default: break
            }
        }
    }

    private func setPrivateModes(_ parameters: [[Int]], _ set: Bool) {
        for group in parameters where !group.isEmpty {
            switch group[0] {
            case 1: applicationCursorKeys = set
            case 3: break // DECCOLM ignored (no 80/132 switching)
            case 6:
                originMode = set
                setCursorPosition(col: 0, row: 0)
            case 7: autoWrap = set
            case 12: break // cursor blink - always blinking
            case 25: cursorVisible = set
            case 47, 1047:
                if set {
                    enterAlternateBuffer(clear: group[0] == 1047)
                } else {
                    leaveAlternateBuffer(clear: group[0] == 1047)
                }
            case 1048:
                if set { saveCursor() } else { restoreCursor() }
            case 1049:
                if set {
                    saveCursor()
                    enterAlternateBuffer(clear: true)
                    setCursorPosition(col: 0, row: 0)
                } else {
                    leaveAlternateBuffer(clear: false)
                    restoreCursor()
                }
            case 1000, 1002, 1003:
                mouseMode = set ? group[0] : 0
            case 1004: focusEvents = set
            case 1006: break // SGR mouse encoding, accepted silently
            case 2004: bracketedPaste = set
            default: break
            }
        }
    }

    private func enterAlternateBuffer(clear: Bool) {
        if active === alt { return }
        active = alt
        if clear { alt.clearScreen(fill: makeEraseCell()) }
        regionTop = 0
        regionBottom = rows - 1
        wrapPending = false
    }

    private func leaveAlternateBuffer(clear: Bool) {
        if active === main { return }
        if clear { alt.clearScreen(fill: makeEraseCell()) }
        active = main
        regionTop = 0
        regionBottom = rows - 1
        wrapPending = false
    }

    // ---------------------------------------------------------------- SGR

    private func selectGraphicRendition(_ parameters: [[Int]]) {
        if parameters.isEmpty {
            resetAttributes()
            return
        }

        var i = 0
        while i < parameters.count {
            let group = parameters[i]
            let code = group.isEmpty ? 0 : group[0]
            switch code {
            case 0: resetAttributes()
            case 1: flags.insert(.bold)
            case 2: flags.insert(.dim)
            case 3: flags.insert(.italic)
            case 4:
                if group.count > 1 && group[1] == 0 {
                    flags.remove([.underline, .doubleUnderline])
                } else {
                    flags.insert(.underline)
                }
            case 5, 6: flags.insert(.blink)
            case 7: flags.insert(.inverse)
            case 8: flags.insert(.hidden)
            case 9: flags.insert(.strikethrough)
            case 21: flags.insert(.doubleUnderline)
            case 22: flags.remove([.bold, .dim])
            case 23: flags.remove(.italic)
            case 24: flags.remove([.underline, .doubleUnderline])
            case 25: flags.remove(.blink)
            case 27: flags.remove(.inverse)
            case 28: flags.remove(.hidden)
            case 29: flags.remove(.strikethrough)
            case 30...37: fg = .indexed(code - 30)
            case 38: fg = Self.parseExtendedColor(parameters, &i) ?? fg
            case 39: fg = .default
            case 40...47: bg = .indexed(code - 40)
            case 48: bg = Self.parseExtendedColor(parameters, &i) ?? bg
            case 49: bg = .default
            case 90...97: fg = .indexed(code - 90 + 8)
            case 100...107: bg = .indexed(code - 100 + 8)
            default: break
            }
            i += 1
        }
    }

    /// Parses SGR 38/48 extended colors in both forms:
    /// semicolon (38;5;n / 38;2;r;g;b - values in following groups) and
    /// colon (38:5:n / 38:2::r:g:b - values as subparameters of one group).
    private static func parseExtendedColor(_ parameters: [[Int]], _ i: inout Int) -> TerminalColor? {
        let group = parameters[i]
        if group.count > 1 {
            // Colon form: everything is inside this group.
            let mode = group[1]
            if mode == 5 && group.count >= 3 {
                return .indexed(group[2])
            }
            if mode == 2 {
                // 38:2:r:g:b or 38:2:colorspace:r:g:b
                if group.count >= 6 { return .rgb(group[3], group[4], group[5]) }
                if group.count >= 5 { return .rgb(group[2], group[3], group[4]) }
            }
            return nil
        }

        // Semicolon form: consume following groups.
        if i + 1 >= parameters.count { return nil }
        let m = parameters[i + 1].first ?? 0
        if m == 5 && i + 2 < parameters.count {
            let idx = parameters[i + 2].first ?? 0
            i += 2
            return .indexed(idx)
        }
        if m == 2 && i + 4 < parameters.count {
            let r = parameters[i + 2].first ?? 0
            let g = parameters[i + 3].first ?? 0
            let b = parameters[i + 4].first ?? 0
            i += 4
            return .rgb(r, g, b)
        }
        return nil
    }

    private func resetAttributes() {
        fg = .default
        bg = .default
        flags = .none
    }

    // ---------------------------------------------------------------- reset & misc

    private func fullReset() {
        resetAttributes()
        active = main
        main.clearScreen(fill: Cell())
        alt.clearScreen(fill: Cell())
        cursorX = 0
        cursorY = 0
        cursorVisible = true
        cursorStyle = 0
        wrapPending = false
        regionTop = 0
        regionBottom = rows - 1
        originMode = false
        autoWrap = true
        insertMode = false
        lineFeedMode = false
        applicationCursorKeys = false
        applicationKeypad = false
        bracketedPaste = false
        focusEvents = false
        mouseMode = 0
        g0 = "B"
        g1 = "B"
        activeCharset = 0
        tabStops = Self.buildTabStops(cols: cols)
        savedMain = SavedCursor()
        savedAlt = SavedCursor()
    }

    private static func buildTabStops(cols: Int) -> [Bool] {
        var stops = [Bool](repeating: false, count: max(0, cols))
        var i = 8
        while i < cols {
            stops[i] = true
            i += 8
        }
        return stops
    }

    private func respond(_ sequence: String) {
        responseRequested?(sequence)
    }

    private func setWorkingDirectory(_ path: String?) {
        guard var path, !path.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        // Trim a trailing separator, but keep the filesystem root as "/".
        while path.count > 1, path.hasSuffix("/") || path.hasSuffix("\\") {
            path.removeLast()
        }
        if path == workingDirectory { return }
        workingDirectory = path
        workingDirectoryChanged?(path)
    }

    /// The OSC 777 verb and title an agent uses to address Zharp specifically.
    private static let agentNotifyVerb = "notify;"
    private static let agentNotifyTitle = "zharp://agent"

    /// OSC 777;notify;<title>;<body>. Both the verb and the title have to match
    /// exactly, case included: several terminals carry desktop notifications on
    /// this sequence, so the title is the only thing separating an agent
    /// talking to us from a notification that is somebody else's business.
    ///
    /// Only the first two separators are framing. A JSON body is full of
    /// semicolons and colons and every one of them after the title belongs to
    /// the body.
    private func handleNotify(_ arg: String) {
        guard arg.hasPrefix(Self.agentNotifyVerb) else { return }
        let rest = arg.dropFirst(Self.agentNotifyVerb.count)
        guard let sep = rest.firstIndex(of: ";") else { return }
        guard rest[rest.startIndex..<sep] == Self.agentNotifyTitle else { return }
        agentReported?(String(rest[rest.index(after: sep)...]))
    }

    private static func parseFileUri(_ uri: String) -> String? {
        guard uri.lowercased().hasPrefix("file://") else { return nil }
        let rest = String(uri.dropFirst(7))
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let pathPart = String(rest[slash...]) // drop host part
        return pathPart.removingPercentEncoding ?? pathPart
    }
}

// ---------------------------------------------------------------- VtHandler

extension TerminalEmulator: VtHandler {
    public func print(rune: Int) {
        printRune(rune)
    }

    public func execute(controlChar c: Int) {
        switch c {
        case 0x07: bellRang?()
        case 0x08: backspace()
        case 0x09: horizontalTab()
        case 0x0A, 0x0B, 0x0C:
            lineFeed()
            if lineFeedMode { carriageReturn() }
        case 0x0D: carriageReturn()
        case 0x0E: activeCharset = 1 // SO
        case 0x0F: activeCharset = 0 // SI
        default: break
        }
    }

    public func escDispatch(intermediates: String, final: Character) {
        if intermediates.isEmpty {
            switch final {
            case "7": saveCursor()
            case "8": restoreCursor()
            case "D": index()
            case "E": index(); carriageReturn()
            case "H": if cursorX < cols { tabStops[cursorX] = true }
            case "M": reverseIndex()
            case "c": fullReset()
            case "=": applicationKeypad = true
            case ">": applicationKeypad = false
            default: break
            }
            return
        }

        switch intermediates.first! {
        case "#":
            if final == "8" { screenAlignmentPattern() }
        case "(": g0 = final
        case ")": g1 = final
        default: break
        }
    }

    public func oscDispatch(payload: String) {
        guard let sep = payload.firstIndex(of: ";") else { return }
        guard let code = Int(payload[payload.startIndex..<sep]) else { return }
        let arg = String(payload[payload.index(after: sep)...])
        switch code {
        case 0, 1, 2:
            title = arg
            titleChanged?(arg)
        case 7:
            // OSC 7: file://[host]/path - xterm working-directory convention.
            setWorkingDirectory(Self.parseFileUri(arg))
        case 9:
            // OSC 9;9;<path> - ConEmu/Windows Terminal working-directory
            // convention. NOT usable as a prompt mark: the position it lands
            // at in the stream is not the prompt line.
            if arg.hasPrefix("9;") {
                setWorkingDirectory(String(arg.dropFirst(2))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
            }
        case 133:
            // OSC 133 (FinalTerm/FTCS): "A" = prompt start, "B" = prompt end
            // (command input begins). Our shell hooks emit them at the right
            // position on every prompt render.
            if isAlternateBuffer { break }
            if arg.lowercased().hasPrefix("a") {
                recordPromptMark()
            } else if arg.lowercased().hasPrefix("b") {
                recordPromptEnd()
            }
        case 777:
            // OSC 777;notify;<title>;<body> - the rxvt-unicode notification
            // convention, which the AI coding agents have settled on for
            // talking to their terminal. Only our own title is claimed;
            // another program's notification is its business, not ours.
            handleNotify(arg)
        default:
            break
        }
    }

    public func csiDispatch(prefix: Character, intermediates: String,
                            parameters: [[Int]], final: Character) {
        func P(_ index: Int, _ fallback: Int = 0) -> Int {
            index < parameters.count && !parameters[index].isEmpty ? parameters[index][0] : fallback
        }
        func P1(_ index: Int) -> Int { max(1, P(index)) }

        if !intermediates.isEmpty {
            if intermediates == " " && final == "q" { // DECSCUSR
                cursorStyle = P(0)
            }
            return
        }

        if prefix == "?" {
            switch final {
            case "h": setPrivateModes(parameters, true)
            case "l": setPrivateModes(parameters, false)
            case "J": eraseInDisplay(P(0))
            case "K": eraseInLine(P(0))
            case "n":
                if P(0) == 6 {
                    respond("\u{1b}[?\(cursorRowForReport());\(cursorX + 1);1R")
                }
            default: break
            }
            return
        }

        if prefix == ">" {
            if final == "c" {
                respond("\u{1b}[>0;10;1c") // DA2: VT100-family, firmware 1.0
            }
            return
        }

        if prefix != "\0" { return }

        switch final {
        case "@": insertCharacters(P1(0))
        case "A": moveCursor(dx: 0, dy: -P1(0))
        case "B": moveCursor(dx: 0, dy: P1(0))
        case "C": moveCursor(dx: P1(0), dy: 0)
        case "D": moveCursor(dx: -P1(0), dy: 0)
        case "E": moveCursor(dx: 0, dy: P1(0)); cursorX = 0; wrapPending = false
        case "F": moveCursor(dx: 0, dy: -P1(0)); cursorX = 0; wrapPending = false
        case "G", "`": setCursorColumn(P1(0) - 1)
        case "H", "f": setCursorPosition(col: P1(1) - 1, row: P1(0) - 1)
        case "I": for _ in 0..<P1(0) { horizontalTab() }
        case "J": eraseInDisplay(P(0))
        case "K": eraseInLine(P(0))
        case "L": insertLines(P1(0))
        case "M": deleteLines(P1(0))
        case "P": deleteCharacters(P1(0))
        case "S": scrollRegion(P1(0), up: true)
        case "T": scrollRegion(P1(0), up: false)
        case "X": eraseCharacters(P1(0))
        case "Z": for _ in 0..<P1(0) { backTab() }
        case "a": moveCursor(dx: P1(0), dy: 0)
        case "b": repeatLastCharacter(P1(0))
        case "c": respond("\u{1b}[?62;22c") // DA1: VT220 with ANSI color
        case "d": setCursorRow(P1(0) - 1)
        case "e": moveCursor(dx: 0, dy: P1(0))
        case "g":
            if P(0) == 3 {
                tabStops = [Bool](repeating: false, count: tabStops.count)
            } else if P(0) == 0 && cursorX < cols {
                tabStops[cursorX] = false
            }
        case "h": setAnsiModes(parameters, true)
        case "l": setAnsiModes(parameters, false)
        case "m": selectGraphicRendition(parameters)
        case "n":
            if P(0) == 5 {
                respond("\u{1b}[0n")
            } else if P(0) == 6 {
                respond("\u{1b}[\(cursorRowForReport());\(cursorX + 1)R")
            }
        case "r": setScrollRegion(top1Based: P(0), bottom1Based: P(1))
        case "s": saveCursor()
        case "u": restoreCursor()
        default: break
        }
    }
}
