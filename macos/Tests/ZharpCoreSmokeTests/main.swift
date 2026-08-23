import Foundation
import ZharpCore

// Deterministic emulator smoke tests, the Swift port of the Windows build's
// Zharp.Core.SmokeTests. Exit code = number of failures.

var failures = 0
var passed = 0

func check(_ condition: Bool, _ name: String) {
    if condition {
        passed += 1
    } else {
        failures += 1
        print("FAIL  \(name)")
    }
}

func newEmu(_ cols: Int = 20, _ rows: Int = 5) -> TerminalEmulator {
    TerminalEmulator(cols: cols, rows: rows)
}

func feed(_ e: TerminalEmulator, _ s: String) {
    e.feed(text: s)
}

func rowText(_ e: TerminalEmulator, _ screenRow: Int) -> String {
    let line = e.buffer.absoluteLine(e.buffer.scrollbackCount + screenRow)
    var s = ""
    for cell in line.cells {
        if cell.flags.contains(.wideTrailing) { continue }
        s.unicodeScalars.append(cell.rune == 0 ? " " : UnicodeScalar(UInt32(cell.rune))!)
    }
    while s.hasSuffix(" ") { s.removeLast() }
    return s
}

func cellAt(_ e: TerminalEmulator, _ row: Int, _ col: Int) -> Cell {
    e.buffer.absoluteLine(e.buffer.scrollbackCount + row).cells[col]
}

func rune(_ c: Character) -> Int { Int(c.unicodeScalars.first!.value) }

// --- basic printing, CR/LF, wrap -------------------------------------------

do {
    let e = newEmu()
    feed(e, "hello")
    check(rowText(e, 0) == "hello", "print basic text")
    check(e.cursorX == 5 && e.cursorY == 0, "cursor after print")

    feed(e, "\r\nworld")
    check(rowText(e, 1) == "world", "CRLF moves to next line")
}

do {
    let e = newEmu(10, 4)
    feed(e, "0123456789ABC")
    check(rowText(e, 0) == "0123456789", "wrap: first line full")
    check(rowText(e, 1) == "ABC", "wrap: overflow to second line")
    check(e.buffer.absoluteLine(e.buffer.scrollbackCount).wrapped, "wrap: line marked wrapped")
}

do {
    // Deferred wrap: printing exactly to the last column must not wrap yet.
    let e = newEmu(5, 3)
    feed(e, "12345")
    check(e.cursorY == 0 && e.cursorX == 4 && e.wrapPending, "deferred wrap pending")
    feed(e, "\r\nX")
    check(rowText(e, 1) == "X", "CR after wrap-pending stays on line")
}

// --- cursor addressing ------------------------------------------------------

do {
    let e = newEmu()
    feed(e, "\u{1b}[3;5HX")
    check(cellAt(e, 2, 4).rune == rune("X"), "CUP addressing")
    feed(e, "\u{1b}[HY")
    check(cellAt(e, 0, 0).rune == rune("Y"), "CUP home")
    feed(e, "\u{1b}[2B\u{1b}[3CZ")
    check(cellAt(e, 2, 4).rune == rune("Z"), "CUD + CUF relative move")
}

// --- SGR --------------------------------------------------------------------

do {
    let e = newEmu()
    feed(e, "\u{1b}[31mA\u{1b}[38;5;196mB\u{1b}[38;2;10;20;30mC\u{1b}[38:2::40:50:60mD\u{1b}[0mE")
    check(cellAt(e, 0, 0).fg == .indexed(1), "SGR 16-color fg")
    check(cellAt(e, 0, 1).fg == .indexed(196), "SGR 256-color fg")
    check(cellAt(e, 0, 2).fg == .rgb(10, 20, 30), "SGR truecolor semicolon form")
    check(cellAt(e, 0, 3).fg == .rgb(40, 50, 60), "SGR truecolor colon form")
    check(cellAt(e, 0, 4).fg == .default, "SGR reset")

    feed(e, "\u{1b}[1;4;7mF")
    let f = cellAt(e, 0, 5).flags
    check(f.contains(.bold) && f.contains(.underline) && f.contains(.inverse),
          "SGR bold+underline+inverse")

    feed(e, "\u{1b}[22;24;27mG")
    check(cellAt(e, 0, 6).flags == .none, "SGR attribute clears")

    feed(e, "\u{1b}[91mH\u{1b}[103mI")
    check(cellAt(e, 0, 7).fg == .indexed(9), "SGR bright fg")
    check(cellAt(e, 0, 8).bg == .indexed(11), "SGR bright bg")
}

// --- erase with background color -------------------------------------------

do {
    let e = newEmu()
    feed(e, "junk\u{1b}[41m\u{1b}[2K")
    check(cellAt(e, 0, 0).rune == 0 && cellAt(e, 0, 0).bg == .indexed(1),
          "EL2 erases with current bg")
}

// --- alternate screen -------------------------------------------------------

do {
    let e = newEmu()
    feed(e, "main-content")
    let savedX = e.cursorX
    feed(e, "\u{1b}[?1049h")
    check(e.isAlternateBuffer, "1049 enters alt buffer")
    check(rowText(e, 0) == "", "alt buffer starts cleared")
    feed(e, "ALT")
    check(rowText(e, 0) == "ALT", "alt buffer content")
    feed(e, "\u{1b}[?1049l")
    check(!e.isAlternateBuffer, "1049 leaves alt buffer")
    check(rowText(e, 0) == "main-content", "main buffer restored")
    check(e.cursorX == savedX, "cursor restored after alt buffer")
}

// --- scroll region ----------------------------------------------------------

do {
    let e = newEmu(10, 5)
    feed(e, "AAA\r\nBBB\r\nCCC\r\nDDD\r\nEEE")
    feed(e, "\u{1b}[2;4r")       // region rows 2..4
    feed(e, "\u{1b}[4;1H\n")     // LF at region bottom scrolls region only
    check(rowText(e, 0) == "AAA", "scroll region: top line untouched")
    check(rowText(e, 1) == "CCC", "scroll region: shifted up")
    check(rowText(e, 2) == "DDD", "scroll region: shifted up 2")
    check(rowText(e, 3) == "", "scroll region: new blank line")
    check(rowText(e, 4) == "EEE", "scroll region: bottom line untouched")
    feed(e, "\u{1b}[r")
    check(e.buffer.scrollbackCount == 0, "region scroll does not pollute scrollback")
}

// --- scrollback -------------------------------------------------------------

do {
    let e = newEmu(10, 3)
    feed(e, "L1\r\nL2\r\nL3\r\nL4\r\nL5")
    check(e.buffer.scrollbackCount == 2, "scrollback captured")
    let sb0 = e.buffer.absoluteLine(0)
    var text = ""
    for c in sb0.cells {
        text.unicodeScalars.append(c.rune == 0 ? " " : UnicodeScalar(UInt32(c.rune))!)
    }
    while text.hasSuffix(" ") { text.removeLast() }
    check(text == "L1", "scrollback oldest line")
    check(rowText(e, 2) == "L5", "screen bottom line")
}

// --- DEC line drawing -------------------------------------------------------

do {
    let e = newEmu()
    feed(e, "\u{1b}(0qx\u{1b}(Bq")
    check(cellAt(e, 0, 0).rune == 0x2500, "DEC graphics: q to horizontal line")
    check(cellAt(e, 0, 1).rune == 0x2502, "DEC graphics: x to vertical line")
    check(cellAt(e, 0, 2).rune == rune("q"), "charset restore to ASCII")
}

// --- wide characters --------------------------------------------------------

do {
    let e = newEmu()
    feed(e, "\u{5B57}A")
    check(cellAt(e, 0, 0).rune == 0x5B57, "wide char lead cell")
    check(cellAt(e, 0, 1).flags.contains(.wideTrailing), "wide char trailing cell")
    check(cellAt(e, 0, 2).rune == rune("A"), "char after wide char")
}

// --- device reports ---------------------------------------------------------

do {
    let e = newEmu()
    var response: String?
    e.responseRequested = { response = $0 }
    feed(e, "\u{1b}[3;7H\u{1b}[6n")
    check(response == "\u{1b}[3;7R",
          "DSR cursor report (got '\(response?.replacingOccurrences(of: "\u{1b}", with: "ESC") ?? "nil")')")
    feed(e, "\u{1b}[c")
    check(response != nil && response!.hasPrefix("\u{1b}[?"), "DA1 responds")
}

// --- OSC title ---------------------------------------------------------------

do {
    let e = newEmu()
    var title: String?
    e.titleChanged = { title = $0 }
    feed(e, "\u{1b}]0;My Title\u{7}")
    check(title == "My Title", "OSC 0 BEL title")
    feed(e, "\u{1b}]2;Other\u{1b}\\")
    check(title == "Other", "OSC 2 ST title")
}

// --- modes -------------------------------------------------------------------

do {
    let e = newEmu()
    feed(e, "\u{1b}[?2004h\u{1b}[?1h\u{1b}[?25l")
    check(e.bracketedPaste, "bracketed paste set")
    check(e.applicationCursorKeys, "app cursor keys set")
    check(!e.cursorVisible, "cursor hidden")
    feed(e, "\u{1b}[?2004l\u{1b}[?1l\u{1b}[?25h")
    check(!e.bracketedPaste && !e.applicationCursorKeys && e.cursorVisible, "modes reset")
}

// --- insert / delete --------------------------------------------------------

do {
    let e = newEmu()
    feed(e, "ABCDEF\u{1b}[1;3H\u{1b}[2@")
    check(rowText(e, 0) == "AB  CDEF", "ICH inserts blanks")
    feed(e, "\u{1b}[1;3H\u{1b}[2P")
    check(rowText(e, 0) == "ABCDEF", "DCH deletes chars")
}

do {
    let e = newEmu(10, 4)
    feed(e, "111\r\n222\r\n333\r\n444")
    feed(e, "\u{1b}[2;1H\u{1b}[1L")
    check(rowText(e, 1) == "" && rowText(e, 2) == "222" && rowText(e, 3) == "333",
          "IL inserts line")
    feed(e, "\u{1b}[2;1H\u{1b}[1M")
    check(rowText(e, 1) == "222" && rowText(e, 2) == "333" && rowText(e, 3) == "",
          "DL deletes line")
}

// --- REP ---------------------------------------------------------------------

do {
    let e = newEmu()
    feed(e, "A\u{1b}[3b")
    check(rowText(e, 0) == "AAAA", "REP repeats last char")
}

// --- save/restore cursor -----------------------------------------------------

do {
    let e = newEmu()
    feed(e, "\u{1b}[2;3H\u{1b}7\u{1b}[4;5H\u{1b}8X")
    check(cellAt(e, 1, 2).rune == rune("X"), "DECSC/DECRC")
}

// --- resize -----------------------------------------------------------------

do {
    let e = newEmu(10, 5)
    feed(e, "one\r\ntwo\r\nthree")
    e.resize(cols: 8, rows: 3)
    check(e.rows == 3 && e.cols == 8, "resize dimensions")
    check(e.cursorY >= 0 && e.cursorY < 3, "resize keeps cursor in bounds")
    check(rowText(e, e.cursorY) == "three", "cursor line content preserved after shrink")
    e.resize(cols: 12, rows: 6)
    check(e.rows == 6 && e.cols == 12, "grow dimensions")
    feed(e, "!")
    check(rowText(e, e.cursorY).hasSuffix("three!"), "typing continues after grow")
}

// --- full reset --------------------------------------------------------------

do {
    let e = newEmu()
    feed(e, "content\u{1b}[31m\u{1b}[?1049h")
    feed(e, "\u{1b}c")
    check(!e.isAlternateBuffer && rowText(e, 0) == "" && e.cursorX == 0 && e.cursorY == 0,
          "RIS full reset")
}

// --- tabs --------------------------------------------------------------------

do {
    let e = newEmu(24, 3)
    feed(e, "\tX")
    check(cellAt(e, 0, 8).rune == rune("X"), "tab to default stop")
    feed(e, "\r\u{1b}[4C\u{1b}H\rA\tB")
    check(cellAt(e, 0, 4).rune == rune("B"), "custom tab stop via HTS")
}

// --- working directory reporting ---------------------------------------------
// POSIX paths here, where the Windows build reports drive letters.

do {
    let e = newEmu()
    var cwd: String?
    e.workingDirectoryChanged = { cwd = $0 }
    feed(e, "\u{1b}]9;9;/Users/test\u{7}")
    check(cwd == "/Users/test", "OSC 9;9 reports cwd")
    feed(e, "\u{1b}]7;file://localhost/Users/test/Some%20Dir\u{1b}\\")
    check(cwd == "/Users/test/Some Dir", "OSC 7 file URI cwd (got '\(cwd ?? "nil")')")
    feed(e, "\u{1b}]9;9;/Volumes/Data/\u{7}")
    check(cwd == "/Volumes/Data", "OSC 9;9 trailing separator trimmed")
    feed(e, "\u{1b}]7;file:///\u{1b}\\")
    check(cwd == "/", "filesystem root preserved")
}

// --- prompt marks (block rendering) --------------------------------

do {
    let e = newEmu(20, 5)
    check(e.promptMarkLine == -1, "no prompt seen yet")
    feed(e, "\u{1b}]133;A\u{7}$ ls\r\nfile\r\n")
    check(e.promptMarkLine == 0, "first prompt mark at line 0")
    feed(e, "\u{1b}]133;A\u{7}$ ")
    check(e.getPromptMarks() == [0, 2], "two ascending marks")
}

// --- prompt-end marks and command capture -------------------------------------

func endsMatch(_ ends: [(line: Int, col: Int)], _ expected: [(Int, Int)]) -> Bool {
    ends.count == expected.count
        && zip(ends, expected).allSatisfy { $0.line == $1.0 && $0.col == $1.1 }
}


do {
    let e = newEmu(40, 6)
    var executed: [String] = []
    e.commandExecuted = { executed.append($0) }

    // A prompt (133;A), the prompt text, then 133;B where input starts.
    feed(e, "\u{1b}]133;A\u{7}$ \u{1b}]133;B\u{7}")
    check(e.hasLivePromptInput, "133;B marks the live prompt as readable")
    check(endsMatch(e.getPromptEnds(), [(0, 2)]), "prompt-end mark records line and column")
    check(e.peekPendingCommand() == nil, "nothing typed yet")

    feed(e, "git status")
    check(e.peekPendingCommand() == "git status", "reads the command being typed")

    // Output, then the next prompt - which reports the command that ran.
    feed(e, "\r\nnothing to commit\r\n\u{1b}]133;A\u{7}$ \u{1b}]133;B\u{7}")
    check(executed == ["git status"], "next prompt reports the finished command")
    check(e.peekPendingCommand() == nil, "fresh prompt has no pending command")
}

do {
    // A right-aligned prompt decoration must not be read as part of the command.
    let e = newEmu(40, 6)
    var executed: [String] = []
    e.commandExecuted = { executed.append($0) }
    feed(e, "\u{1b}]133;A\u{7}$ \u{1b}]133;B\u{7}dir            19:08")
    feed(e, "\r\nout\r\n\u{1b}]133;A\u{7}$ \u{1b}]133;B\u{7}")
    check(executed == ["dir"], "eight-plus spaces cut off a right prompt (got \(executed))")
}

do {
    // Empty prompts report nothing.
    let e = newEmu(40, 6)
    var executed: [String] = []
    e.commandExecuted = { executed.append($0) }
    feed(e, "\u{1b}]133;A\u{7}$ \u{1b}]133;B\u{7}")
    feed(e, "\r\n\u{1b}]133;A\u{7}$ \u{1b}]133;B\u{7}")
    check(executed.isEmpty, "an empty prompt reports no command")
}

do {
    // A wrapped command follows the soft-wrap chain.
    let e = newEmu(20, 6)
    feed(e, "\u{1b}]133;A\u{7}$ \u{1b}]133;B\u{7}")
    feed(e, "echo hello-world-th")   // fills to the wrap
    feed(e, "is-wraps")
    check(e.peekPendingCommand() == "echo hello-world-this-wraps",
          "wrapped input is joined (got \(e.peekPendingCommand() ?? "nil"))")
}

do {
    // The alternate screen never reports commands.
    let e = newEmu(40, 6)
    var executed: [String] = []
    e.commandExecuted = { executed.append($0) }
    feed(e, "\u{1b}[?1049h\u{1b}]133;A\u{7}$ \u{1b}]133;B\u{7}vim")
    check(e.peekPendingCommand() == nil, "alt buffer has no pending command")
    check(!e.hasLivePromptInput, "alt buffer has no live prompt input")
    check(executed.isEmpty, "alt buffer reports no commands")
}

do {
    // Re-rendering a prompt at or above an old mark drops the stale end marks.
    let e = newEmu(40, 6)
    feed(e, "\u{1b}]133;A\u{7}$ \u{1b}]133;B\u{7}one\r\n")
    feed(e, "\u{1b}]133;A\u{7}$ \u{1b}]133;B\u{7}")
    check(e.getPromptEnds().count == 2, "two prompt-end marks")
    feed(e, "\u{1b}[H\u{1b}]133;A\u{7}$ \u{1b}]133;B\u{7}")
    check(endsMatch(e.getPromptEnds(), [(0, 2)]),
          "a prompt redrawn at the top invalidates the marks below it")
}

do {
    // Marks stay valid across scrollback trimming (droppedLines adjustment) -
    // the raw indices are absolute, so trimming has to be subtracted back out.
    let e = TerminalEmulator(cols: 20, rows: 4, maxScrollback: 100)
    feed(e, "\u{1b}]133;A\u{7}> \u{1b}]133;B\u{7}cmd")
    for i in 0..<150 {
        feed(e, "\r\nline\(i)")
    }
    feed(e, "\r\n\u{1b}]133;A\u{7}> \u{1b}]133;B\u{7}")
    let marks = e.getPromptMarks()
    let ends = e.getPromptEnds()
    check(marks.count >= 1 && ends.count >= 1, "trim keeps recent marks")
    check(marks[marks.count - 1] == e.buffer.scrollbackCount + e.cursorY,
          "last mark tracks the live prompt after trim")
    check(ends[ends.count - 1].line == marks[marks.count - 1]
          && ends[ends.count - 1].col == 2,
          "last prompt end adjusted after trim")
}

do {
    // A second 133;B on the same row replaces the first, so a prompt that
    // re-renders in place reports the new input column rather than stacking.
    let e = newEmu(40, 6)
    feed(e, "\u{1b}]133;A\u{7}$ \u{1b}]133;B\u{7}")
    feed(e, "\r\u{1b}]133;B\u{7}")
    check(endsMatch(e.getPromptEnds(), [(0, 0)]),
          "a repeated prompt-end on one row replaces the earlier column")
}

do {
    // A right-aligned clock beyond the cursor is prompt decoration, not input.
    let e = newEmu(40, 6)
    var commands: [String] = []
    e.commandExecuted = { commands.append($0) }
    feed(e, "\u{1b}]133;A\u{7}PS> \u{1b}]133;B\u{7}")
    feed(e, "\u{1b}[1;30H19:08\u{1b}[1;5H")
    check(e.peekPendingCommand() == nil, "clock beyond the cursor is not a pending command")
    feed(e, "\u{1b}]133;B\u{7}dir")
    check(e.peekPendingCommand() == "dir", "typed input after a fresh B is pending")
    feed(e, "\r\nfiles...\r\n\u{1b}]133;A\u{7}PS> \u{1b}]133;B\u{7}")
    check(commands == ["dir"], "the clock is not reported as a command (got \(commands))")
}

do {
    // A B mark stranded on a decoration line, with the cursor a row below and
    // no soft-wrap chain joining them, is not input either.
    let e = newEmu(40, 6)
    feed(e, "\u{1b}]133;A\u{7}")
    feed(e, "\u{1b}[1;20H\u{1b}]133;B\u{7}09:47")
    feed(e, "\u{1b}[2;1H$ ")
    check(e.peekPendingCommand() == nil, "cursor-disconnected B is not pending input")
}

// --- new themes ----------------------------------------------------------------

do {
    let dracula = Palette.dracula()
    check(dracula.defaultBackground == 0x282A36 && dracula.defaultForeground == 0xF8F8F2,
          "Dracula fg/bg")
    check(dracula.colors[5] == 0xFF79C6, "Dracula magenta")
    let catppuccin = Palette.catppuccin()
    check(catppuccin.defaultBackground == 0x1E1E2E && catppuccin.cursorColor == 0xF5E0DC,
          "Catppuccin bg/cursor")
    let gruvbox = Palette.gruvbox()
    check(gruvbox.defaultBackground == 0x1D2021 && gruvbox.cursorColor == 0xFE8019,
          "Gruvbox bg/cursor")
    // The 256-colour cube and grey ramp are shared by every scheme.
    check(gruvbox.colors[16 + 5 * 36 + 5 * 6 + 5] == 0xFFFFFF, "new schemes keep the colour cube")
}

// --- character width ----------------------------------------------------------

do {
    check(CharWidth.width(of: rune("A")) == 1, "ASCII is one cell")
    check(CharWidth.width(of: 0x5B57) == 2, "CJK is two cells")
    check(CharWidth.width(of: 0x1F600) == 2, "emoji is two cells")
    check(CharWidth.width(of: 0x0301) == 0, "combining acute is zero cells")
    check(CharWidth.width(of: 0x00E9) == 1, "precomposed e-acute is one cell")
}

// --- input encoding -----------------------------------------------------------

do {
    check(TerminalInput.encodeKey(virtualKey: TerminalInput.VK_UP, mods: .none,
                                  applicationCursorKeys: false) == "\u{1b}[A",
          "up arrow, normal mode")
    check(TerminalInput.encodeKey(virtualKey: TerminalInput.VK_UP, mods: .none,
                                  applicationCursorKeys: true) == "\u{1b}OA",
          "up arrow, application mode")
    check(TerminalInput.encodeKey(virtualKey: TerminalInput.VK_LEFT, mods: [.ctrl],
                                  applicationCursorKeys: false) == "\u{1b}[1;5D",
          "ctrl+left")
    check(TerminalInput.encodeKey(virtualKey: TerminalInput.VK_F1 + 4, mods: .none,
                                  applicationCursorKeys: false) == "\u{1b}[15~", "F5")
    check(TerminalInput.encodeControlChord(virtualKey: rune("C"), mods: [.ctrl]) == "\u{3}",
          "Ctrl+C is 0x03")
    check(TerminalInput.encodeKey(virtualKey: TerminalInput.VK_BACK, mods: .none,
                                  applicationCursorKeys: false) == "\u{7f}",
          "backspace sends DEL")
}

// --- palettes ------------------------------------------------------------------

do {
    let cream = Palette.cream()
    check(cream.defaultBackground == 0xEDE6D8, "cream background matches the logo")
    check(cream.colors[16 + 5 * 36 + 5 * 6 + 5] == 0xFFFFFF, "color cube top corner")
    check(cream.colors[255] == 0xEEEEEE, "grayscale ramp end")

    var cell = Cell(rune: rune("A"), fg: .indexed(1), bg: .default, flags: .bold)
    var resolved = cream.resolve(cell)
    check(resolved.fg == cream.colors[9], "bold brightens indexed fg")
    check(resolved.bgIsDefault, "default bg stays translucent")

    cell.flags = .inverse
    cell.fg = .default
    resolved = cream.resolve(cell)
    check(resolved.fg == cream.defaultBackground && resolved.bg == cream.defaultForeground,
          "inverse swaps fg/bg")
    check(!resolved.bgIsDefault, "inverse bg is painted")
}

// --- pty integration (the real shell, end to end) -----------------------------

do {
    let e = TerminalEmulator(cols: 40, rows: 6)
    var done = false
    do {
        let pty = try PseudoTerminal.start(
            arguments: ["/bin/sh", "-c", "printf 'zharp-pty-ok\\r\\n'; printf '\\033[32mgreen\\033[0m\\r\\n'"],
            workingDirectory: "/tmp",
            extraEnvironment: ["TERM": "xterm-256color"],
            cols: 40, rows: 6)
        pty.exited = { _ in done = true }

        // Drain until the child exits or a second passes.
        let deadline = Date().addingTimeInterval(2)
        var buffer = [UInt8](repeating: 0, count: 4096)
        let fd = pty.output.fileDescriptor
        var flags = fcntl(fd, F_GETFL, 0)
        flags |= O_NONBLOCK
        _ = fcntl(fd, F_SETFL, flags)

        while Date() < deadline {
            let count = buffer.withUnsafeMutableBufferPointer { read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                buffer.withUnsafeBufferPointer {
                    e.feed(UnsafeBufferPointer(start: $0.baseAddress, count: count))
                }
            } else if done && count <= 0 {
                break
            } else {
                usleep(20_000)
            }
        }
        pty.dispose()

        check(rowText(e, 0) == "zharp-pty-ok", "pty: shell output reaches the emulator (got '\(rowText(e, 0))')")
        check(rowText(e, 1) == "green", "pty: second line rendered")
        check(cellAt(e, 1, 0).fg == .indexed(2), "pty: ANSI color survives the round trip")
    } catch {
        check(false, "pty: starting /bin/sh failed with \(error)")
    }
}

do {
    // Resizing must reach the child through TIOCSWINSZ.
    let e = TerminalEmulator(cols: 40, rows: 6)
    do {
        let pty = try PseudoTerminal.start(
            arguments: ["/bin/sh", "-c", "sleep 0.3; stty size"],
            workingDirectory: "/tmp", extraEnvironment: nil, cols: 40, rows: 6)
        pty.resize(cols: 100, rows: 24)

        let deadline = Date().addingTimeInterval(2)
        var buffer = [UInt8](repeating: 0, count: 4096)
        let fd = pty.output.fileDescriptor
        var flags = fcntl(fd, F_GETFL, 0)
        flags |= O_NONBLOCK
        _ = fcntl(fd, F_SETFL, flags)
        e.resize(cols: 100, rows: 24)
        while Date() < deadline {
            let count = buffer.withUnsafeMutableBufferPointer { read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                buffer.withUnsafeBufferPointer {
                    e.feed(UnsafeBufferPointer(start: $0.baseAddress, count: count))
                }
            } else {
                usleep(20_000)
            }
        }
        pty.dispose()
        check(rowText(e, 0) == "24 100", "pty: resize reaches the child (got '\(rowText(e, 0))')")
    } catch {
        check(false, "pty: resize test could not start a shell")
    }
}

print("")
print(failures == 0
      ? "All \(passed) checks passed."
      : "\(failures) FAILED, \(passed) passed.")
exit(Int32(failures))
