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

/// Bridges one async call into the synchronous top-level code this runner is.
/// The box is what carries the answer back out: a Task cannot return into a
/// local, and this file has no actor to suspend on.
final class ResultBox<T>: @unchecked Sendable {
    var value: T?
}

func awaitValue<T>(_ operation: @escaping @Sendable () async -> T) -> T {
    let box = ResultBox<T>()
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        box.value = await operation()
        semaphore.signal()
    }
    semaphore.wait()
    return box.value!
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

// --- which machine the directory is on (OSC 7 host) --------------------------
//
// file://host/path carries both halves and the host used to be thrown away, so
// a shell on the far end of an ssh connection handed Zharp a path it then read
// off local disk. Two things are held down here at once: a foreign host has to
// survive, and every spelling this Mac answers to has to stay local. The second
// is the one with teeth, because the injected shell hooks report gethostname(),
// and on a machine named by DHCP that is not the name Foundation gives back.

/// What zsh's $HOST, bash's $HOSTNAME and fish's `hostname` all put in the URI.
func reportedHostName() -> String {
    var buffer = [CChar](repeating: 0, count: 256)
    guard gethostname(&buffer, buffer.count - 1) == 0 else { return "localhost" }
    return String(cString: buffer)
}

/// "foo.local" and "foo" are the same Mac.
func withoutDotLocal(_ name: String) -> String {
    name.hasSuffix(".local") ? String(name.dropLast(6)) : name
}

do {
    let e = newEmu()
    var reports = 0
    e.workingDirectoryChanged = { _ in reports += 1 }

    func osc7(_ uri: String) { feed(e, "\u{1b}]7;\(uri)\u{1b}\\") }
    func host() -> String { e.workingDirectoryHost ?? "nil" }
    func path() -> String { e.workingDirectory ?? "nil" }

    // Every value that means "here". A miss on any of these marks an ordinary
    // local tab as remote, which costs the tab subtitle, the changes panel and
    // history for every session: worse than the bug the host field fixes.
    let bare = withoutDotLocal(ProcessInfo.processInfo.hostName)
    let spellings = [
        "",                               // file:///path, the scheme's own "here"
        "localhost",
        "127.0.0.1",
        "::1",
        "[::1]",                          // as an IPv6 literal is written in a URI
        reportedHostName(),               // what the shell hooks actually emit
        ProcessInfo.processInfo.hostName, // what Foundation answers
        bare,                             // the bare name
        bare + ".local",                  // and its mDNS spelling
        bare.uppercased(),                // one machine, whatever the case
    ]
    for (i, name) in spellings.enumerated() {
        osc7("file://\(name)/Users/test/local\(i)")
        check(path() == "/Users/test/local\(i)" && e.workingDirectoryHost == nil,
              "OSC 7 host '\(name)' is this machine (got host '\(host())')")
    }

    // A machine that is not this one. The host survives and the path is left in
    // the far end's own notation, which is what lets the app layer tell a
    // remote repository from a local one sitting at the same path.
    osc7("file://srv1/home/me/app")
    check(path() == "/home/me/app" && host() == "srv1",
          "a foreign host is remote and preserved (got '\(host())')")

    let quiet = reports
    osc7("file://srv1/home/me/app")
    check(reports == quiet, "the same machine and path is reported once")

    // The exact shape of the bug: two checkouts at /home/me/app on two servers.
    // Comparing paths alone says nothing moved.
    osc7("file://srv2/home/me/app")
    check(reports == quiet + 1 && host() == "srv2",
          "a change of machine at the same path is a move")

    osc7("file://srv1/home/me/Some%20Dir")
    check(path() == "/home/me/Some Dir" && host() == "srv1",
          "a remote path is percent decoded (got '\(path())')")

    // The host gets a decode of its own now that it is kept; it never had one
    // while it was being dropped. %2D is '-'.
    osc7("file://srv%2Done/home/me")
    check(host() == "srv-one", "the host half is percent decoded too (got '\(host())')")

    // Split first, decode after: an escaped slash belongs to the filename and
    // must not be promoted into the separator that ends the host.
    osc7("file://srv1/home/me%2Fmine")
    check(host() == "srv1" && path() == "/home/me/mine",
          "an escaped slash does not end the host (got '\(host())' '\(path())')")

    // A backslash is an ordinary character in a POSIX filename, so the remote
    // branch trims "/" and nothing else.
    osc7("file://srv1/home/me/odd%5C")
    check(path() == "/home/me/odd\\",
          "a trailing backslash survives a remote path (got '\(path())')")
    osc7("file://srv1/home/me/dir/")
    check(path() == "/home/me/dir", "a remote trailing slash is trimmed (got '\(path())')")
    osc7("file://srv1/")
    check(path() == "/" && host() == "srv1", "the remote filesystem root is preserved")

    osc7("file://\(reportedHostName())/Users/test/back")
    check(path() == "/Users/test/back" && e.workingDirectoryHost == nil,
          "OSC 7 from this machine clears a stale host")

    // OSC 9;9 has no host field at all, so it can only ever describe this
    // machine, and it clears a stale one rather than leaving it standing.
    osc7("file://srv1/home/me/app")
    feed(e, "\u{1b}]9;9;/Users/test/here\u{7}")
    check(path() == "/Users/test/here" && e.workingDirectoryHost == nil,
          "OSC 9;9 always describes this machine")

    // Nothing below should throw or run off the end of the string, and none of
    // it names a directory, so the last good answer stands.
    for bad in ["", "file", "not-a-uri", "file:/Users/test", "file://", "file://srv1"] {
        osc7(bad)
    }
    check(path() == "/Users/test/here" && e.workingDirectoryHost == nil,
          "a file URI with no path is ignored rather than fatal (got '\(path())')")

    // An escape that is not valid percent encoding is handed over as it stands
    // rather than dropping the report: what the shell said is still the best
    // answer available, and refusing it would leave the panel on the last one.
    osc7("file://srv1/home/%zz")
    check(path() == "/home/%zz" && host() == "srv1",
          "an undecodable escape falls back to the raw text (got '\(path())')")
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

// --- agent reports (OSC 777) --------------------------------------------------

do {
    let e = newEmu()
    var payload: String?
    e.agentReported = { payload = $0 }

    feed(e, "\u{1b}]777;notify;zharp://agent;{\"v\":1,\"event\":\"done\"}\u{7}")
    check(payload == "{\"v\":1,\"event\":\"done\"}",
          "OSC 777 agent report (got '\(payload ?? "nil")')")

    // A JSON body is full of semicolons and colons; only the first two
    // separators belong to the OSC framing.
    payload = nil
    feed(e, "\u{1b}]777;notify;zharp://agent;{\"a\":\"x;y\",\"b\":\"z\"}\u{7}")
    check(payload == "{\"a\":\"x;y\",\"b\":\"z\"}",
          "semicolons inside the body survive (got '\(payload ?? "nil")')")

    // Our own hooks end the sequence with BEL, but ST is just as valid and a
    // report written by hand or by somebody else's wrapper may use it.
    payload = nil
    feed(e, "\u{1b}]777;notify;zharp://agent;{\"v\":1}\u{1b}\\")
    check(payload == "{\"v\":1}", "ST ends the report too (got '\(payload ?? "nil")')")
}

do {
    // Several terminals carry desktop notifications on OSC 777, so the title is
    // the only thing separating an agent talking to us from traffic that is
    // none of our business.
    let e = newEmu()
    var payload: String?
    e.agentReported = { payload = $0 }

    feed(e, "\u{1b}]777;notify;other-terminal://agent;{\"v\":1}\u{7}")
    check(payload == nil, "another terminal's OSC 777 is ignored")

    feed(e, "\u{1b}]777;notify;zharp://agentx;{\"v\":1}\u{7}")
    check(payload == nil, "a title we merely begin is not ours")

    feed(e, "\u{1b}]777;Notify;zharp://agent;{\"v\":1}\u{7}")
    feed(e, "\u{1b}]777;notify;zharp://Agent;{\"v\":1}\u{7}")
    check(payload == nil, "the verb and the title are both case sensitive")

    feed(e, "\u{1b}]777;notify;zharp://agent\u{7}")
    feed(e, "\u{1b}]777;something-else;zharp://agent;{}\u{7}")
    feed(e, "\u{1b}]777\u{7}")
    check(payload == nil, "malformed OSC 777 raises nothing")

    feed(e, "\u{1b}]778;notify;zharp://agent;{\"v\":1}\u{7}")
    check(payload == nil, "a neighbouring OSC code is not ours either")
}

do {
    // The emulator hands the body over exactly as it arrived and judges none of
    // it. The version gate, the field limits and the event names belong to the
    // report parser a layer up: this end of the pipe cannot tell a stale
    // protocol from a hostile one, and both look like text.
    let e = newEmu()
    var bodies: [String] = []
    e.agentReported = { bodies.append($0) }

    feed(e, "\u{1b}]777;notify;zharp://agent;{\"v\":2,\"agent\":\"claude\",\"event\":\"done\"}\u{7}")
    feed(e, "\u{1b}]777;notify;zharp://agent;not json at all\u{7}")
    feed(e, "\u{1b}]777;notify;zharp://agent;\u{7}")
    check(bodies == ["{\"v\":2,\"agent\":\"claude\",\"event\":\"done\"}", "not json at all", ""],
          "the body arrives verbatim, version and all (got \(bodies))")
}

do {
    // Past the OSC length limit the body is cut where the limit falls, so what
    // arrives is broken JSON the report parser drops. What matters here is that
    // the overflow costs nothing else: the sequence still ends where its
    // terminator says it does, and the next report is read normally.
    let e = newEmu()
    var payload: String?
    e.agentReported = { payload = $0 }

    // The framing is counted against the same limit as the body.
    let framing = "777;notify;zharp://agent;".count
    let huge = String(repeating: "A", count: 5000)
    feed(e, "\u{1b}]777;notify;zharp://agent;{\"v\":1,\"summary\":\"\(huge)\"}\u{7}")
    check(payload?.count == 4096 - framing,
          "an oversized body is cut at the OSC limit (got \(payload?.count ?? -1))")
    check(payload?.hasSuffix("}") == false, "and cannot be mistaken for a whole report")

    payload = nil
    feed(e, "ok")
    feed(e, "\u{1b}]777;notify;zharp://agent;{\"v\":1,\"event\":\"idle\"}\u{7}")
    check(rowText(e, 0) == "ok", "text after the overflow still prints (got '\(rowText(e, 0))')")
    check(payload == "{\"v\":1,\"event\":\"idle\"}", "and the next report is read normally")
}

do {
    // The limit is counted in UTF-16 units, the way the Windows parser counts
    // StringBuilder.Length, and NOT in Characters.
    //
    // A Character is a grapheme cluster, so a run of combining marks all joins
    // the one cluster in front of it: the count stays at 1 no matter how many
    // arrive, the cap never trips, and every append pays for a fresh walk of
    // the whole buffer. Anything that can print to a terminal could send them,
    // and 50k of them took 65 seconds on the reader thread - which holds the
    // emulator's lock, so the app stops drawing rather than just that tab.
    let e = newEmu()
    var payload: String?
    e.agentReported = { payload = $0 }

    let framing = "777;notify;zharp://agent;".count
    let marks = String(repeating: "\u{0301}", count: 20_000)
    let started = Date()
    feed(e, "\u{1b}]777;notify;zharp://agent;X\(marks)\u{7}")
    let took = Date().timeIntervalSince(started)

    check(payload?.unicodeScalars.count == 4096 - framing,
          "combining marks are counted against the OSC limit "
          + "(got \(payload?.unicodeScalars.count ?? -1) scalars)")
    check(took < 1, "and cost no walk of the buffer per mark (took \(String(format: "%.2f", took))s)")

    feed(e, "after")
    check(rowText(e, 0) == "after", "text after them still prints (got '\(rowText(e, 0))')")
}

do {
    // Anything below 0x20 is dropped where it stands rather than ending the
    // sequence, so a report carrying a raw newline arrives quietly corrupted
    // instead of not arriving at all. That is why the protocol asks for the
    // JSON to be escaped.
    let e = newEmu()
    var payload: String?
    e.agentReported = { payload = $0 }
    feed(e, "\u{1b}]777;notify;zharp://agent;{\"summary\":\"a\nb\"}\u{7}")
    check(payload == "{\"summary\":\"ab\"}",
          "raw control characters are stripped, not fatal (got '\(payload ?? "nil")')")
}

do {
    // A read from the pty returns whatever had arrived by then, so a report can
    // be split anywhere, including inside the escape that opens it.
    let e = newEmu()
    var payload: String?
    e.agentReported = { payload = $0 }

    feed(e, "\u{1b}]777;notify;zharp:/")
    check(payload == nil, "half a report raises nothing yet")
    feed(e, "/agent;{\"v\":1,\"eve")
    feed(e, "nt\":\"permission\"}\u{7}")
    check(payload == "{\"v\":1,\"event\":\"permission\"}",
          "a split report is assembled (got '\(payload ?? "nil")')")

    payload = nil
    feed(e, "\u{1b}")
    feed(e, "]777;notify;zharp://agent;{\"v\":1}")
    feed(e, "\u{7}")
    check(payload == "{\"v\":1}", "even when the split lands on the escape (got '\(payload ?? "nil")')")
}

do {
    // A crashed or hostile writer can leave an OSC open forever. Whatever comes
    // next has to win the parser back and be read as itself, rather than as
    // more of the abandoned report.
    let e = newEmu(20, 5)
    var payload: String?
    e.agentReported = { payload = $0 }

    // CAN abandons the sequence outright.
    feed(e, "\u{1b}]777;notify;zharp://agent;{\"v\":1\u{18}after")
    check(payload == nil, "an abandoned report raises nothing")
    check(rowText(e, 0) == "after", "and what follows it prints as text (got '\(rowText(e, 0))')")

    // Unterminated, then a real sequence: the ESC ends the OSC.
    feed(e, "\r\n\u{1b}]777;notify;zharp://agent;{\"v\":1\u{1b}[31mred")
    check(payload == nil, "an unterminated report raises nothing")
    check(rowText(e, 1) == "red", "the sequence after it is honoured (got '\(rowText(e, 1))')")
    check(cellAt(e, 1, 0).fg == .indexed(1), "including its colour")

    // And a well formed report still gets through after all of that.
    feed(e, "\u{1b}]777;notify;zharp://agent;{\"v\":1,\"event\":\"end\"}\u{7}")
    check(payload == "{\"v\":1,\"event\":\"end\"}",
          "reports still arrive afterwards (got '\(payload ?? "nil")')")
}

// --- prompt returned ----------------------------------------------------------
//
// The signal a tab uses to decide its agent has exited. An agent's own "session
// ended" hook fires while its process is tearing down, so it is the one report
// that routinely never arrives; a prompt appearing below the last one cannot be
// missed, and needs nothing from the agent.

do {
    let e = newEmu()
    var returns = 0
    e.promptReturned = { returns += 1 }

    feed(e, "\u{1b}]133;A\u{7}$ ")
    check(returns == 0, "the first prompt is not a return (nothing ran before it)")

    feed(e, "ls\r\nfile\r\n\u{1b}]133;A\u{7}$ ")
    check(returns == 1, "a prompt below the last one is (got \(returns))")

    feed(e, "claude\r\n")
    check(returns == 1, "output alone raises nothing")
    feed(e, "\u{1b}]133;A\u{7}$ ")
    check(returns == 2, "and the prompt after the agent exits raises it again (got \(returns))")
}

do {
    // A prompt re-rendered in place is not a new one. Agent CLIs repaint their
    // own line constantly, and treating each repaint as "the agent is gone"
    // would clear the tab's status a few times a second.
    let e = newEmu()
    var returns = 0
    e.promptReturned = { returns += 1 }

    feed(e, "\u{1b}]133;A\u{7}$ ")
    feed(e, "\r\u{1b}]133;A\u{7}$ ")
    feed(e, "\r\u{1b}]133;A\u{7}$ ")
    check(returns == 0, "a prompt redrawn on the same line is not a return (got \(returns))")
}

do {
    // Raised after the mark bookkeeping, so a listener that turns round and
    // asks the emulator what it knows sees the new prompt, not the old one.
    let e = newEmu()
    var marksWhenRaised = 0
    e.promptReturned = { }
    feed(e, "\u{1b}]133;A\u{7}$ ls\r\nout\r\n")
    e.promptReturned = { marksWhenRaised = e.getPromptMarks().count }
    feed(e, "\u{1b}]133;A\u{7}$ ")
    check(marksWhenRaised == 2, "the new mark is already recorded when it fires "
          + "(got \(marksWhenRaised))")
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


// ---------------------------------------------------------------------------
// Sessions on another machine: which machine a session is on, what may be
// dialled, and the ssh transport itself. See docs/remote-sessions.md.
// ---------------------------------------------------------------------------

do {
    // ---- SshTarget.parse, the accepted shapes
    check(SshTarget.parse("ssh srv1")?.label == "srv1", "ssh: a bare destination")
    check(SshTarget.parse("ssh claudiu@10.0.0.4")?.label == "10.0.0.4",
          "ssh: user@host keeps only the host")
    check(SshTarget.parse("ssh ssh://me@box:2222")?.label == "box", "ssh: a URL destination")
    check(SshTarget.parse("ssh ssh://me@box:2222")?.invocation?.port == 2222, "ssh: and its port")
    check(SshTarget.parse("ssh ssh://me@box:2222")?.invocation?.user == "me", "ssh: and its user")
    check(SshTarget.parse("ssh ssh://me@box:2222")?.invocation?.destination == "ssh://me@box:2222",
          "ssh: the destination goes on the wire as typed")

    let ported = SshTarget.parse("ssh -p 2222 srv1")
    check(ported?.label == "srv1", "ssh: a flag value is not mistaken for the destination")
    check(ported?.invocation?.arguments == ["-p", "2222", "srv1"], "ssh: and the port is carried over")
    check(ported?.invocation?.port == 2222, "ssh: structured port")
    check(SshTarget.parse("ssh -p2222 srv1")?.label == "srv1", "ssh: a glued flag value")
    check(SshTarget.parse("ssh -p2222 srv1")?.invocation?.arguments == ["-p", "2222", "srv1"],
          "ssh: glued, split out")

    let clustered = SshTarget.parse("ssh -46C srv1")
    check(clustered?.invocation?.arguments == ["-4", "-6", "-C", "srv1"],
          "ssh: clustered flags carry over")

    let keyed = SshTarget.parse("ssh -i \"/Users/me/My Keys/id_ed25519\" -J bastion srv1")
    check(keyed?.invocation?.arguments == ["-i", "/Users/me/My Keys/id_ed25519", "-J", "bastion", "srv1"],
          "ssh: an identity and a jump host reach the same place")
    check(keyed?.invocation?.identityFile == "/Users/me/My Keys/id_ed25519", "ssh: identity field")
    check(keyed?.invocation?.jumpHost == "bastion", "ssh: jump field")

    let escaped = SshTarget.parse("ssh -i ~/my\\ keys/id srv1")
    check(escaped?.label == "srv1", "ssh: a backslash escaped space is one argument")
    check(escaped?.invocation?.arguments == ["-i", "~/my keys/id", "srv1"], "ssh: and is unescaped once")

    let forwarded = SshTarget.parse("ssh -L 8080:localhost:80 srv1")
    check(forwarded?.invocation?.arguments == ["srv1"], "ssh: a port forward is consumed and dropped")
    check(SshTarget.parse("ssh srv1 uptime")?.invocation?.arguments == ["srv1"],
          "ssh: a trailing command is dropped")
    check(SshTarget.parse("ssh -- srv1")?.label == "srv1", "ssh: -- names the destination")
    check(SshTarget.parse("ssh -l bob srv1")?.invocation?.user == "bob", "ssh: -l supplies the user")
    check(SshTarget.parse("ssh -l bob alice@srv1")?.invocation?.user == "alice",
          "ssh: user@ wins over -l")
    check(SshTarget.parse("/usr/bin/ssh srv1")?.label == "srv1", "ssh: a full path to ssh")
    check(SshTarget.parse("ssh ::1")?.label == "::1", "ssh: a bare IPv6 literal")
    check(SshTarget.parse("ssh [2001:db8::1]:2222")?.label == "2001:db8::1",
          "ssh: a bracketed literal loses its brackets")
    check(SshTarget.parse("ssh [2001:db8::1]:2222")?.invocation?.port == 2222,
          "ssh: and keeps its port")
    check(SshTarget.parse("ssh fe80::1%25en0") != nil, "ssh: a zone id survives")
    check(SshTarget.parse("ssh user@domain.com@bastion")?.label == "bastion",
          "ssh: an @ inside the user")
    check(SshTarget.parse("ssh -J bastion,two.example srv1")?.invocation?.jumpHost
            == "bastion,two.example",
          "ssh: a jump chain is allowed when every hop is a destination")

    // ---- SshTarget.parse, the refusals. Each of these would otherwise put a
    // string of somebody else's choosing into an outbound connection.
    check(SshTarget.parse("ssh-keygen -t ed25519") == nil, "ssh: ssh-keygen is not ssh")
    check(SshTarget.parse("ssh-add ~/.ssh/id_ed25519") == nil, "ssh: ssh-add is not ssh")
    check(SshTarget.parse("git status") == nil, "ssh: and neither is anything else")
    check(SshTarget.parse("ssh") == nil, "ssh: ssh with no destination goes nowhere")
    check(SshTarget.parse("sudo ssh srv1") == nil, "ssh: a wrapper is not unwrapped")
    check(SshTarget.parse("ssh -N -L 9000:localhost:9000 srv1") == nil,
          "ssh: a tunnel is not a session")
    check(SshTarget.parse("ssh -O exit srv1") == nil, "ssh: a control command is not a session")
    check(SshTarget.parse("ssh -W host:22 srv1") == nil, "ssh: a stdio forward is not a session")
    check(SshTarget.parse("ssh -f srv1 cmd") == nil, "ssh: backgrounding is not a session")
    check(SshTarget.parse("ssh -p") == nil, "ssh: a value flag with no value")
    check(SshTarget.parse("ssh --") == nil, "ssh: -- with nothing after it")
    check(SshTarget.parse("ssh -- -oProxyCommand=curl") == nil,
          "ssh: an option is never a destination")
    check(SshTarget.parse("ssh -") == nil, "ssh: a lone dash is not a machine")
    check(SshTarget.parse("ssh \"my host\"") == nil, "ssh: a hostname has no spaces in it")
    check(SshTarget.parse("ssh 'a; rm -rf /'") == nil, "ssh: nor a semicolon")
    check(SshTarget.parse("ssh '$(id)@srv1'") == nil, "ssh: a command substitution is not a user")
    check(SshTarget.parse("ssh 'srv1`id`'") == nil, "ssh: nor a backtick a host")
    check(SshTarget.parse("ssh me@") == nil, "ssh: an empty host")
    check(SshTarget.parse("ssh keys/id") == nil, "ssh: a path is not a host")
    check(SshTarget.parse("ssh -J '-x' srv1") == nil, "ssh: a jump hop that is an option")
    check(SshTarget.parse("ssh -l 'a;b' srv1") == nil, "ssh: a login name that is not one")
    check(SshTarget.parse("ssh -p '$(id)' srv1") == nil, "ssh: a port that is not a number")
    check(SshTarget.parse("ssh -p 2222x srv1") == nil, "ssh: nor one with a tail on it")

    // ---- what a carried command line may put on Zharp's own ssh line.
    //
    // Everything below is an option ssh would obey and that runs a program, or
    // loads one, or decides whether an unknown host key stops the connection.
    // Zharp opens this connection by itself, on a timer, so none of them may
    // travel: the argv is spliced verbatim into a child process.
    func carried(_ command: String) -> [String] {
        SshTarget.parse(command)?.invocation?.arguments ?? []
    }
    check(carried("ssh -o ProxyCommand=/tmp/evil.sh srv1") == ["srv1"],
          "carry: a ProxyCommand is dropped, not carried")
    check(carried("ssh -oProxyCommand=id>/tmp/x srv1") == ["srv1"],
          "carry: including glued to the flag")
    check(carried("ssh -o proxycommand=id srv1") == ["srv1"],
          "carry: keywords are case insensitive")
    check(carried("ssh -o 'ProxyCommand /tmp/evil.sh' srv1") == ["srv1"],
          "carry: and written with a space instead of an =")
    check(carried("ssh -o LocalCommand=/tmp/evil.sh -o PermitLocalCommand=yes srv1") == ["srv1"],
          "carry: nor a LocalCommand")
    check(carried("ssh -o KnownHostsCommand=/tmp/evil.sh srv1") == ["srv1"],
          "carry: nor a KnownHostsCommand")
    check(carried("ssh -o PKCS11Provider=/tmp/evil.dylib srv1") == ["srv1"],
          "carry: nor a library to dlopen")
    check(carried("ssh -o StrictHostKeyChecking=no srv1") == ["srv1"],
          "carry: nor anything that stops an unknown key being an error")
    check(carried("ssh -o UserKnownHostsFile=/tmp/theirs srv1") == ["srv1"],
          "carry: nor a known_hosts of somebody else's choosing")
    check(carried("ssh -o Include=/tmp/evil srv1") == ["srv1"],
          "carry: nor a file of further options")
    check(carried("ssh -F /tmp/evil_config srv1") == ["srv1"],
          "carry: -F is a file of further options with a flag of its own")
    check(carried("ssh -I /tmp/evil.dylib srv1") == ["srv1"],
          "carry: -I is a shared library ssh loads")
    check(carried("ssh -o HostName=$(id) srv1") == ["srv1"],
          "carry: nor a HostName, which ssh expands into %h")
    check(carried("ssh -o User=$(id) srv1") == ["srv1"],
          "carry: nor a User, which it expands into %r")
    // And the ones that are the whole point of carrying anything.
    check(carried("ssh -p 2222 -l bob -i ~/.ssh/id_ed25519 srv1")
            == ["-p", "2222", "-l", "bob", "-i", "~/.ssh/id_ed25519", "srv1"],
          "carry: how to reach it and who to be still travels")
    check(carried("ssh -o IdentitiesOnly=yes -o Compression=yes srv1")
            == ["-o", "IdentitiesOnly=yes", "-o", "Compression=yes", "srv1"],
          "carry: and a -o that cannot run anything")
    check(carried("ssh -4 -C -J bastion srv1") == ["-4", "-C", "-J", "bastion", "srv1"],
          "carry: as do the plain flags and a checked jump host")

    // ---- watched against reported: the whole security boundary
    let watched = SshTarget.parse("ssh srv1")!
    check(watched.canConnect, "reach: one the user reached is dialable")
    check(watched.invocation != nil, "reach: and carries an invocation")
    check(RemoteHost.reported("srv1")?.canConnect == false,
          "reach: a machine we only heard about is not")
    check(RemoteHost.reported("srv1")?.invocation == nil, "reach: and has nothing to dial with")
    check(RemoteHost.reported("srv1") != watched,
          "reach: and is not the same host as the dialable one")
    check(RemoteHost.reported("-oProxyCommand=x") == nil,
          "reach: a reported name that is an option is refused")
    check(RemoteHost.reported("srv1; id") == nil,
          "reach: a reported name with a metacharacter is refused")
    check(RemoteHost.reported("  srv1  ")?.label == "srv1", "reach: a reported name is trimmed")
    check(SshTarget.parse("ssh srv1") == SshTarget.parse("ssh srv1"),
          "reach: same command, same host")
    check(SshTarget.parse("ssh srv1") != SshTarget.parse("ssh -p 2222 srv1"),
          "reach: the same name on a different port is a different machine")
    check(RemoteHost.reported("a") != RemoteHost.reported("b"),
          "reach: two reported machines stay distinct")
    check(RemoteHost.reported("srv1")!.key != watched.key,
          "reach: and do not share a connection key")

    // ---- SessionLocation
    check(SessionLocation.local("  ") == nil, "location: blank is not a directory")
    check(SessionLocation.local("/Users/me")?.isRemote == false, "location: local is local")
    check(SessionLocation.on(watched, path: nil).hasPath == false,
          "location: a host with nowhere to stand")
    check(SessionLocation.on(watched, path: "/home/me") != SessionLocation.local("/home/me"),
          "location: the same path on another machine is another place")
    check(SessionLocation.local("/Users/Work") == SessionLocation.local("/users/work"),
          "location: this machine is case insensitive")
    check(SessionLocation.on(watched, path: "/A") != SessionLocation.on(watched, path: "/a"),
          "location: the far end is case sensitive even though this one is not")
    check(SessionLocation.on(watched, path: "/home/me/app").displayName == "app",
          "location: the last segment")
    check(SessionLocation.on(watched, path: "/home/me").withPath("/tmp").remote == watched,
          "location: a new directory does not change the machine")

    // ---- PromptTitle, the fallback that is never a promotion
    check(PromptTitle.parse("claudiu@srv1: ~/work/proj")?.host == "srv1",
          "title: the default Debian title")
    check(PromptTitle.parse("claudiu@srv1: ~/work/proj")?.path == "~/work/proj", "title: and its path")
    check(PromptTitle.parse("srv1:/var/www")?.path == "/var/www",
          "title: a bare host and an absolute path")
    check(PromptTitle.parse("make: *** [all] Error 1") == nil,
          "title: an error message is not a location")
    check(PromptTitle.parse("nvim") == nil, "title: a program name is not a location")
    check(PromptTitle.parse("Zharp") == nil, "title: and neither is ours")
    check(PromptTitle.parse("weird host: ~/x") == nil, "title: a hostname has no spaces in it")
    check(PromptTitle.parse(nil) == nil, "title: no title at all")

    // ---- PosixPath: the far end's arithmetic, never this machine's
    check(PosixPath.fileName("/home/me/app/main.ts") == "main.ts", "posix: the last segment")
    check(PosixPath.fileName("/home/me/app/") == "app", "posix: a trailing slash is not a segment")
    check(PosixPath.fileName("/") == "/", "posix: the root keeps its slash")
    check(PosixPath.relative("/home/me/app/src/x.ts", under: "/home/me/app") == "src/x.ts",
          "posix: the part below")
    check(PosixPath.relative("/home/me/other/x.ts", under: "/home/me/app") == nil,
          "posix: a sibling is not under it")
    check(PosixPath.relative("/home/me/application/x.ts", under: "/home/me/app") == nil,
          "posix: a longer name is not under it")
    check(PosixPath.relative("/home/me/App/x.ts", under: "/home/me/app") == nil,
          "posix: and neither is another case")
    check(PosixPath.combine("/home/me/", "/app") == "/home/me/app", "posix: one slash between them")
    check(PosixPath.expandHome("~/work", home: "/home/me") == "/home/me/work",
          "posix: ~ becomes the home directory")
    check(PosixPath.expandHome("~", home: "/home/me") == "/home/me", "posix: ~ on its own")
    check(PosixPath.expandHome("~other/work", home: "/home/me") == "~other/work",
          "posix: another user's home is left alone")
    check(PosixPath.expandHome("/var/www", home: "/home/me") == "/var/www",
          "posix: an absolute path is left alone")

    // ---- ShellWords: every argument that goes over the wire passes through this
    check(ShellWords.quote("plain") == "'plain'", "quote: ordinary text")
    check(ShellWords.quote("it's") == "'it'\\''s'", "quote: a quote is closed, escaped and reopened")
    check(ShellWords.quote("a; rm -rf /") == "'a; rm -rf /'", "quote: a semicolon stays data")

    // Which names mean "this machine" is decided in TerminalEmulator, against
    // the OSC 7 host, and it is checked there: see the "which machine the
    // directory is on" section above, which walks every spelling this Mac
    // answers to. There is deliberately no second definition of it here for a
    // caller to reach for by mistake.
}

// ---------------------------------------------------------------------------
// The ssh transport, run for real against a stub that is a local shell.
//
// ZHARP_SSH names the program SshGitChannel runs instead of ssh, so this
// replaces the network with a pipe and leaves everything above it untouched:
// the handshake, the marker framing, the single quoting, the base64 and the
// git hardening are all exercised exactly as they would be against a server.
// There is no ssh server on a build machine, and a test that mocked the
// channel would prove nothing about the part that actually breaks.
// ---------------------------------------------------------------------------

do {
    let stub = URL(fileURLWithPath: #filePath)      // .../Tests/<target>/main.swift
        .deletingLastPathComponent()                // .../Tests/<target>
        .deletingLastPathComponent()                // .../Tests
        .appendingPathComponent("Fixtures/ssh-stub.sh")

    if !FileManager.default.isExecutableFile(atPath: stub.path)
        || !FileManager.default.isExecutableFile(atPath: "/bin/sh") {
        // A skip rather than a failure: this section needs a POSIX shell and
        // its fixture, and neither says anything about the code under test.
        print("SKIP  ssh transport: no /bin/sh or no executable stub at \(stub.path)")
    } else {
        setenv("ZHARP_SSH", stub.path, 1)
        defer { unsetenv("ZHARP_SSH") }

        let here = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().path  // the repo root

        let host = SshTarget.parse("ssh -p 2222 me@srv1")!
        let channel = awaitValue { await SshGitChannel.connect(to: host) }
        check(channel.isUsable, "transport: the handshake completes (\(channel.problem ?? "ok"))")
        check(channel.home == NSHomeDirectory(),
              "transport: $HOME comes back from the far end (\(channel.home ?? "-"))")

        // A real read of a real repository, through the whole frame.
        let root = awaitValue {
            await channel.runGit(in: here, ["rev-parse", "--show-toplevel"])
        }.trimmingCharacters(in: .whitespacesAndNewlines)
        check(root.hasSuffix("/zharp") || root == here,
              "transport: git rev-parse answers through the channel (\(root))")

        // NUL separators are the reason for the base64: a filename may contain
        // both a newline and a NUL byte, so a line-oriented protocol reading
        // raw output would eventually mistake a filename for an end of frame.
        let status = awaitValue {
            await channel.runGit(in: here,
                                 ["status", "--porcelain=v1", "-z", "--untracked-files=all"])
        }
        check(!status.contains("\n") || status.contains("\0"),
              "transport: -z output survives the frame with its NUL bytes")

        // The quoting, with everything a shell would otherwise act on.
        let hostile = "a; rm -rf / $HOME `id` 'x' *"
        let echoed = awaitValue { await channel.run(in: here, ["printf", "%s", hostile]) }
        check(echoed == hostile, "transport: an argument arrives literally (\(echoed))")

        // A frame that contains the marker's own text must not end early.
        let marker = awaitValue {
            await channel.run(in: here, ["printf", "one\nZHARP-END-deadbeef\nthree\n"])
        }
        check(marker == "one\nZHARP-END-deadbeef\nthree\n",
              "transport: the marker's text inside a payload does not end the frame")

        // It never writes. The subcommand allowlist is what makes that true of
        // a caller this file never sees.
        check(awaitValue { await channel.runGit(in: here, ["fetch", "--all"]) }.isEmpty,
              "transport: a writing subcommand is refused")
        check(awaitValue { await channel.runGit(in: here, ["checkout", "main"]) }.isEmpty,
              "transport: and so is checkout")

        // Missing directory, missing command, silent command: all one answer.
        check(awaitValue { await channel.run(in: "/no/such/dir", ["pwd"]) }.isEmpty,
              "transport: a directory that is not there answers empty")
        check(awaitValue { await channel.run(in: here, ["zharp-not-a-command"]) }.isEmpty,
              "transport: and so does a command that is not there")

        channel.dispose()
        check(!channel.isUsable, "transport: a disposed channel stops being usable")

        // The rule the whole feature rests on, at the two places it is enforced.
        let reported = RemoteHost.reported("srv1")!
        let refused = awaitValue { await SshGitChannel.connect(to: reported) }
        check(!refused.isUsable, "transport: a host we only heard about is never dialled")
        check(refused.problem?.contains("did not see the ssh command") == true,
              "transport: and says why (\(refused.problem ?? "-"))")
        check(awaitValue { await SshGitChannels.channel(for: reported) } == nil,
              "transport: the registry refuses it too")

        // The off switch, which means now rather than in five minutes.
        SshGitChannels.enabled = false
        check(awaitValue { await SshGitChannels.channel(for: host) } == nil,
              "transport: turned off, nothing connects")
        SshGitChannels.enabled = true

        // One channel per host, shared by every tab on it.
        let first = awaitValue { await SshGitChannels.channel(for: host) }
        let second = awaitValue { await SshGitChannels.channel(for: host) }
        check(first != nil && first === second, "transport: one connection per host, not per question")
        SshGitChannels.closeAll()
    }
}

print("")
print(failures == 0
      ? "All \(passed) checks passed."
      : "\(failures) FAILED, \(passed) passed.")
exit(Int32(failures))
