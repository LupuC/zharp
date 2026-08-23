import Foundation
import ZharpCore

/// One command block: a prompt line, the command typed at it, and its output,
/// bounded by the next prompt mark.
struct TerminalBlock {
    /// Absolute main-buffer line of the prompt that opens the block.
    let start: Int
    /// Absolute main-buffer line that closes it (inclusive).
    let end: Int
    /// True for the block holding the live prompt: never collapsible, never
    /// selectable, and never given a hover chip.
    let isLive: Bool
    /// Drop-stable identity. Scrollback trimming shifts every absolute line, so
    /// anything that outlives a repaint - the collapsed set, the highlight, the
    /// find scope - keys off this instead.
    let key: Int64

    init(start: Int, end: Int, isLive: Bool, dropped: Int64) {
        self.start = start
        self.end = end
        self.isLive = isLive
        self.key = Int64(start) + dropped
    }
}

/// Reads block text out of a screen buffer. Every entry point must be called
/// with the emulator's `syncRoot` already held.
enum BlockText {

    /// One line's text, from `fromCol`, with trailing blanks trimmed.
    static func lineText(_ buffer: ScreenBuffer, _ abs: Int, fromCol: Int = 0) -> String {
        guard abs >= 0, abs < buffer.totalLines else { return "" }
        let cells = buffer.absoluteLine(abs).cells
        var out = ""
        var c = Swift.max(0, fromCol)
        while c < cells.count {
            let cell = cells[c]
            c += 1
            if cell.flags.contains(.wideTrailing) { continue }
            if cell.rune == 0 {
                out.append(" ")
            } else if let scalar = UnicodeScalar(UInt32(cell.rune)) {
                out.unicodeScalars.append(scalar)
            }
        }
        while out.hasSuffix(" ") { out.removeLast() }
        return out
    }

    /// Like `lineText`, but also maps each character index back to its cell
    /// column - a wide rune or a surrogate pair makes the two disagree, and the
    /// find highlighter needs columns.
    static func lineTextWithMap(_ buffer: ScreenBuffer,
                                _ abs: Int) -> (text: String, columns: [Int]) {
        guard abs >= 0, abs < buffer.totalLines else { return ("", []) }
        let cells = buffer.absoluteLine(abs).cells
        var out = ""
        var columns: [Int] = []
        for (column, cell) in cells.enumerated() {
            if cell.flags.contains(.wideTrailing) { continue }
            let piece: String
            if cell.rune == 0 {
                piece = " "
            } else if let scalar = UnicodeScalar(UInt32(cell.rune)) {
                piece = String(Character(scalar))
            } else {
                piece = " "
            }
            out += piece
            for _ in 0..<piece.utf16.count { columns.append(column) }
        }
        while out.hasSuffix(" ") {
            out.removeLast()
            if !columns.isEmpty { columns.removeLast() }
        }
        return (out, columns)
    }

    /// The last line of a command's soft-wrap chain: a long typed command
    /// occupies several rows with no newline between them.
    static func commandEndLine(_ buffer: ScreenBuffer, _ cmdLine: Int, _ end: Int) -> Int {
        var i = cmdLine
        while i < end, i < buffer.totalLines, buffer.absoluteLine(i).wrapped {
            i += 1
        }
        return i
    }

    /// Joins a line range, keeping soft-wrapped lines on one line and dropping
    /// trailing blank lines.
    static func joinLines(_ buffer: ScreenBuffer, from: Int, to: Int) -> String {
        var out = ""
        var lastContent = 0
        var i = Swift.max(0, from)
        while i <= to, i < buffer.totalLines {
            let text = lineText(buffer, i)
            out += text
            if !text.isEmpty { lastContent = out.count }
            if i < to, !buffer.absoluteLine(i).wrapped { out += "\n" }
            i += 1
        }
        return String(out.prefix(lastContent))
    }

    /// Where the typed command starts inside a block: the prompt-end mark
    /// (OSC 133;B) that falls in it, or the block's own first line.
    private static func commandOrigin(_ emu: TerminalEmulator,
                                      _ start: Int, _ end: Int) -> (line: Int, col: Int) {
        for mark in emu.getPromptEnds() where mark.line >= start && mark.line <= end {
            return mark
        }
        return (start, 0)
    }

    /// The command alone, with the prompt decoration stripped off.
    static func command(_ emu: TerminalEmulator, _ buffer: ScreenBuffer,
                        _ start: Int, _ end: Int) -> String {
        let origin = commandOrigin(emu, start, end)
        let last = commandEndLine(buffer, origin.line, end)
        var out = ""
        var i = origin.line
        while i <= last, i < buffer.totalLines {
            out += lineText(buffer, i, fromCol: i == origin.line ? origin.col : 0)
            i += 1
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Everything the command printed, without the prompt or the command.
    static func output(_ emu: TerminalEmulator, _ buffer: ScreenBuffer,
                       _ start: Int, _ end: Int) -> String {
        let origin = commandOrigin(emu, start, end)
        let from = commandEndLine(buffer, origin.line, end) + 1
        if from > end { return "" }
        return joinLines(buffer, from: from, to: end)
    }

    /// Prompt, command and output verbatim.
    static func whole(_ buffer: ScreenBuffer, _ start: Int, _ end: Int) -> String {
        joinLines(buffer, from: start, to: end)
    }

    /// A fenced console block, ready to paste into an issue or a PR.
    static func markdown(_ emu: TerminalEmulator, _ buffer: ScreenBuffer,
                         _ start: Int, _ end: Int) -> String {
        let cmd = command(emu, buffer, start, end)
        let out = output(emu, buffer, start, end)
        var text = "```console\n"
        if !cmd.isEmpty { text += "$ " + cmd + "\n" }
        if !out.isEmpty { text += out + "\n" }
        text += "```"
        return text
    }
}
