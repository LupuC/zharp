using System.Text;
using Zharp.Core.Terminal;

// Deterministic emulator smoke tests. Exit code = number of failures.

int failures = 0;
int passed = 0;

void Check(bool condition, string name)
{
    if (condition)
    {
        passed++;
    }
    else
    {
        failures++;
        Console.WriteLine($"FAIL  {name}");
    }
}

static TerminalEmulator NewEmu(int cols = 20, int rows = 5) => new(cols, rows);

static void Feed(TerminalEmulator e, string s) => e.Feed(Encoding.UTF8.GetBytes(s));

static string RowText(TerminalEmulator e, int screenRow)
{
    var line = e.Buffer.GetAbsoluteLine(e.Buffer.ScrollbackCount + screenRow);
    var sb = new StringBuilder();
    foreach (var cell in line.Cells)
    {
        if ((cell.Flags & CellFlags.WideTrailing) != 0)
            continue;
        sb.Append(cell.Rune == 0 ? ' ' : (char)cell.Rune);
    }
    return sb.ToString().TrimEnd();
}

static Cell CellAt(TerminalEmulator e, int row, int col) =>
    e.Buffer.GetAbsoluteLine(e.Buffer.ScrollbackCount + row).Cells[col];

// --- basic printing, CR/LF, wrap -------------------------------------------

{
    var e = NewEmu();
    Feed(e, "hello");
    Check(RowText(e, 0) == "hello", "print basic text");
    Check(e.CursorX == 5 && e.CursorY == 0, "cursor after print");

    Feed(e, "\r\nworld");
    Check(RowText(e, 1) == "world", "CRLF moves to next line");
}

{
    var e = NewEmu(10, 4);
    Feed(e, "0123456789ABC");
    Check(RowText(e, 0) == "0123456789", "wrap: first line full");
    Check(RowText(e, 1) == "ABC", "wrap: overflow to second line");
    Check(e.Buffer.GetAbsoluteLine(e.Buffer.ScrollbackCount).Wrapped, "wrap: line marked wrapped");
}

{
    // Deferred wrap: printing exactly to the last column must not wrap yet.
    var e = NewEmu(5, 3);
    Feed(e, "12345");
    Check(e.CursorY == 0 && e.CursorX == 4 && e.WrapPending, "deferred wrap pending");
    Feed(e, "\r\nX");
    Check(RowText(e, 1) == "X", "CR after wrap-pending stays on line");
}

// --- cursor addressing ------------------------------------------------------

{
    var e = NewEmu();
    Feed(e, "\x1b[3;5HX");
    Check(CellAt(e, 2, 4).Rune == 'X', "CUP addressing");
    Feed(e, "\x1b[HY");
    Check(CellAt(e, 0, 0).Rune == 'Y', "CUP home");
    Feed(e, "\x1b[2B\x1b[3CZ");
    Check(CellAt(e, 2, 4).Rune == 'Z', "CUD + CUF relative move");
}

// --- SGR --------------------------------------------------------------------

{
    var e = NewEmu();
    Feed(e, "\x1b[31mA\x1b[38;5;196mB\x1b[38;2;10;20;30mC\x1b[38:2::40:50:60mD\x1b[0mE");
    Check(CellAt(e, 0, 0).Fg == TerminalColor.Indexed(1), "SGR 16-color fg");
    Check(CellAt(e, 0, 1).Fg == TerminalColor.Indexed(196), "SGR 256-color fg");
    Check(CellAt(e, 0, 2).Fg == TerminalColor.Rgb(10, 20, 30), "SGR truecolor semicolon form");
    Check(CellAt(e, 0, 3).Fg == TerminalColor.Rgb(40, 50, 60), "SGR truecolor colon form");
    Check(CellAt(e, 0, 4).Fg == TerminalColor.Default, "SGR reset");

    Feed(e, "\x1b[1;4;7mF");
    var f = CellAt(e, 0, 5).Flags;
    Check((f & CellFlags.Bold) != 0 && (f & CellFlags.Underline) != 0 && (f & CellFlags.Inverse) != 0,
        "SGR bold+underline+inverse");

    Feed(e, "\x1b[22;24;27mG");
    Check(CellAt(e, 0, 6).Flags == CellFlags.None, "SGR attribute clears");

    Feed(e, "\x1b[91mH\x1b[103mI");
    Check(CellAt(e, 0, 7).Fg == TerminalColor.Indexed(9), "SGR bright fg");
    Check(CellAt(e, 0, 8).Bg == TerminalColor.Indexed(11), "SGR bright bg");
}

// --- erase with background color -------------------------------------------

{
    var e = NewEmu();
    Feed(e, "junk\x1b[41m\x1b[2K");
    Check(CellAt(e, 0, 0).Rune == 0 && CellAt(e, 0, 0).Bg == TerminalColor.Indexed(1),
        "EL2 erases with current bg");
}

// --- alternate screen -------------------------------------------------------

{
    var e = NewEmu();
    Feed(e, "main-content");
    int savedX = e.CursorX;
    Feed(e, "\x1b[?1049h");
    Check(e.IsAlternateBuffer, "1049 enters alt buffer");
    Check(RowText(e, 0) == "", "alt buffer starts cleared");
    Feed(e, "ALT");
    Check(RowText(e, 0) == "ALT", "alt buffer content");
    Feed(e, "\x1b[?1049l");
    Check(!e.IsAlternateBuffer, "1049 leaves alt buffer");
    Check(RowText(e, 0) == "main-content", "main buffer restored");
    Check(e.CursorX == savedX, "cursor restored after alt buffer");
}

// --- scroll region ----------------------------------------------------------

{
    var e = NewEmu(10, 5);
    Feed(e, "AAA\r\nBBB\r\nCCC\r\nDDD\r\nEEE");
    Feed(e, "\x1b[2;4r");       // region rows 2..4
    Feed(e, "\x1b[4;1H\n");      // LF at region bottom scrolls region only
    Check(RowText(e, 0) == "AAA", "scroll region: top line untouched");
    Check(RowText(e, 1) == "CCC", "scroll region: shifted up");
    Check(RowText(e, 2) == "DDD", "scroll region: shifted up 2");
    Check(RowText(e, 3) == "", "scroll region: new blank line");
    Check(RowText(e, 4) == "EEE", "scroll region: bottom line untouched");
    Feed(e, "\x1b[r");
    Check(e.Buffer.ScrollbackCount == 0, "region scroll does not pollute scrollback");
}

// --- scrollback -------------------------------------------------------------

{
    var e = NewEmu(10, 3);
    Feed(e, "L1\r\nL2\r\nL3\r\nL4\r\nL5");
    Check(e.Buffer.ScrollbackCount == 2, "scrollback captured");
    var sb0 = e.Buffer.GetAbsoluteLine(0);
    var text = new StringBuilder();
    foreach (var c in sb0.Cells) text.Append(c.Rune == 0 ? ' ' : (char)c.Rune);
    Check(text.ToString().TrimEnd() == "L1", "scrollback oldest line");
    Check(RowText(e, 2) == "L5", "screen bottom line");
}

// --- DEC line drawing -------------------------------------------------------

{
    var e = NewEmu();
    Feed(e, "\x1b(0qx\x1b(Bq");
    Check(CellAt(e, 0, 0).Rune == 0x2500, "DEC graphics: q → ─");
    Check(CellAt(e, 0, 1).Rune == 0x2502, "DEC graphics: x → │");
    Check(CellAt(e, 0, 2).Rune == 'q', "charset restore to ASCII");
}

// --- wide characters --------------------------------------------------------

{
    var e = NewEmu();
    Feed(e, "字A");
    Check(CellAt(e, 0, 0).Rune == 0x5B57, "wide char lead cell");
    Check((CellAt(e, 0, 1).Flags & CellFlags.WideTrailing) != 0, "wide char trailing cell");
    Check(CellAt(e, 0, 2).Rune == 'A', "char after wide char");
}

// --- device reports ---------------------------------------------------------

{
    var e = NewEmu();
    string? response = null;
    e.ResponseRequested += r => response = r;
    Feed(e, "\x1b[3;7H\x1b[6n");
    Check(response == "\x1b[3;7R", $"DSR cursor report (got '{response?.Replace("\x1b", "ESC")}')");
    Feed(e, "\x1b[c");
    Check(response != null && response.StartsWith("\x1b[?"), "DA1 responds");
}

// --- OSC title ---------------------------------------------------------------

{
    var e = NewEmu();
    string? title = null;
    e.TitleChanged += t => title = t;
    Feed(e, "\x1b]0;My Title\x07");
    Check(title == "My Title", "OSC 0 BEL title");
    Feed(e, "\x1b]2;Other\x1b\\");
    Check(title == "Other", "OSC 2 ST title");
}

// --- modes -------------------------------------------------------------------

{
    var e = NewEmu();
    Feed(e, "\x1b[?2004h\x1b[?1h\x1b[?25l");
    Check(e.BracketedPaste, "bracketed paste set");
    Check(e.ApplicationCursorKeys, "app cursor keys set");
    Check(!e.CursorVisible, "cursor hidden");
    Feed(e, "\x1b[?2004l\x1b[?1l\x1b[?25h");
    Check(!e.BracketedPaste && !e.ApplicationCursorKeys && e.CursorVisible, "modes reset");
}

// --- insert / delete --------------------------------------------------------

{
    var e = NewEmu();
    Feed(e, "ABCDEF\x1b[1;3H\x1b[2@");
    Check(RowText(e, 0) == "AB  CDEF", "ICH inserts blanks");
    Feed(e, "\x1b[1;3H\x1b[2P");
    Check(RowText(e, 0) == "ABCDEF", "DCH deletes chars");
}

{
    var e = NewEmu(10, 4);
    Feed(e, "111\r\n222\r\n333\r\n444");
    Feed(e, "\x1b[2;1H\x1b[1L");
    Check(RowText(e, 1) == "" && RowText(e, 2) == "222" && RowText(e, 3) == "333", "IL inserts line");
    Feed(e, "\x1b[2;1H\x1b[1M");
    Check(RowText(e, 1) == "222" && RowText(e, 2) == "333" && RowText(e, 3) == "", "DL deletes line");
}

// --- REP ---------------------------------------------------------------------

{
    var e = NewEmu();
    Feed(e, "A\x1b[3b");
    Check(RowText(e, 0) == "AAAA", "REP repeats last char");
}

// --- save/restore cursor -----------------------------------------------------

{
    var e = NewEmu();
    Feed(e, "\x1b[2;3H\u001b7\x1b[4;5H\u001b8X");
    Check(CellAt(e, 1, 2).Rune == 'X', "DECSC/DECRC");
}

// --- resize -----------------------------------------------------------------

{
    var e = NewEmu(10, 5);
    Feed(e, "one\r\ntwo\r\nthree");
    e.Resize(8, 3);
    Check(e.Rows == 3 && e.Cols == 8, "resize dimensions");
    Check(e.CursorY >= 0 && e.CursorY < 3, "resize keeps cursor in bounds");
    Check(RowText(e, e.CursorY) == "three", "cursor line content preserved after shrink");
    e.Resize(12, 6);
    Check(e.Rows == 6 && e.Cols == 12, "grow dimensions");
    Feed(e, "!");
    Check(RowText(e, e.CursorY).EndsWith("three!"), "typing continues after grow");
}

// --- full reset --------------------------------------------------------------

{
    var e = NewEmu();
    Feed(e, "content\x1b[31m\x1b[?1049h");
    Feed(e, "\u001bc");
    Check(!e.IsAlternateBuffer && RowText(e, 0) == "" && e.CursorX == 0 && e.CursorY == 0, "RIS full reset");
}

// --- tabs --------------------------------------------------------------------

{
    var e = NewEmu(24, 3);
    Feed(e, "\tX");
    Check(CellAt(e, 0, 8).Rune == 'X', "tab to default stop");
    Feed(e, "\r\x1b[4C\x1bH\rA\tB");
    Check(CellAt(e, 0, 4).Rune == 'B', "custom tab stop via HTS");
}

// --- working directory reporting ---------------------------------------------

{
    var e = NewEmu();
    string? cwd = null;
    e.WorkingDirectoryChanged += p => cwd = p;
    Feed(e, "\x1b]9;9;C:\\Users\\Test\x07");
    Check(cwd == "C:\\Users\\Test", "OSC 9;9 reports cwd");
    Feed(e, "\x1b]7;file:///D:/Some%20Dir\x1b\\");
    Check(cwd == "D:\\Some Dir", $"OSC 7 file URI cwd (got '{cwd}')");
    Feed(e, "\x1b]9;9;E:\x07");
    Check(cwd == "E:\\", "OSC 9;9 drive root normalized");
}

// --- prompt marks (OSC 133) ----------------------------------------------------

{
    var e = NewEmu(40, 5);
    Feed(e, "\x1b]133;A\x07PS C:\\> \x1b]133;B\x07");
    var marks = e.GetPromptMarks();
    var ends = e.GetPromptEnds();
    Check(marks.Count == 1 && marks[0] == 0, "133;A records prompt mark");
    Check(ends.Count == 1 && ends[0].Line == 0 && ends[0].Col == 8, "133;B records prompt end at cursor col");

    Feed(e, "dir\r\nout1\r\nout2\r\n");
    Feed(e, "\x1b]133;A\x07PS C:\\> \x1b]133;B\x07");
    marks = e.GetPromptMarks();
    ends = e.GetPromptEnds();
    Check(marks.Count == 2 && marks[1] == 3, "second prompt mark on line 3");
    Check(ends.Count == 2 && ends[1].Line == 3 && ends[1].Col == 8, "second prompt end tracked");

    // A prompt re-rendered at the same line (redraw) replaces, not duplicates.
    Feed(e, "\r\x1b]133;A\x07PS C:\\> \x1b]133;B\x07");
    Check(e.GetPromptMarks().Count == 2 && e.GetPromptEnds().Count == 2,
        "prompt redraw keeps marks unique");

    // Alt-buffer output must not record marks.
    Feed(e, "\x1b[?1049h\x1b]133;A\x07\x1b]133;B\x07\x1b[?1049l");
    Check(e.GetPromptMarks().Count == 2 && e.GetPromptEnds().Count == 2,
        "alt buffer records no prompt marks");
}

{
    // Marks stay valid across scrollback trimming (DroppedLines adjustment).
    var e = new TerminalEmulator(20, 4, 100);
    // BEL as , not : 'c' after  would extend the hex escape.
    Feed(e, "]133;A> ]133;Bcmd");
    for (int i = 0; i < 150; i++)
        Feed(e, $"\r\nline{i}");
    Feed(e, "\r\n\x1b]133;A\x07> \x1b]133;B\x07");
    var marks = e.GetPromptMarks();
    var ends = e.GetPromptEnds();
    Check(marks.Count >= 1 && ends.Count >= 1, "trim keeps recent marks");
    Check(marks[^1] == e.Buffer.ScrollbackCount + e.CursorY, "last mark tracks the live prompt after trim");
    Check(ends[^1].Line == marks[^1] && ends[^1].Col == 2, "last prompt end adjusted after trim");
}

// --- command executed events ---------------------------------------------------

{
    var e = NewEmu(40, 6);
    var commands = new List<string>();
    e.CommandExecuted += c => commands.Add(c);

    Feed(e, "\x1b]133;A\x07PS> \x1b]133;B\u0007dir /w\r\nfile1  file2\r\n");
    Feed(e, "\x1b]133;A\x07PS> \x1b]133;B\x07");
    Check(commands.Count == 1 && commands[0] == "dir /w", $"command reported on next prompt (got '{string.Join("|", commands)}')");

    // Empty prompt (plain Enter) reports nothing.
    Feed(e, "\r\n\x1b]133;A\x07PS> \x1b]133;B\x07");
    Check(commands.Count == 1, "empty command not reported");

    // Prompt redraw at the same line reports nothing.
    Feed(e, "\r\x1b]133;A\x07PS> \x1b]133;B\x07");
    Check(commands.Count == 1, "prompt redraw not reported");

    Feed(e, "git status\r\nclean\r\n\x1b]133;A\x07PS> \x1b]133;B\x07");
    Check(commands.Count == 2 && commands[1] == "git status", "second command reported");
}

{
    // Screen-clearing commands: readable at Enter time via PeekPendingCommand,
    // even though the next prompt arrives on a wiped screen.
    var e = NewEmu(40, 6);
    Feed(e, "\x1b]133;A\x07PS> \x1b]133;B\x07");
    Check(e.PeekPendingCommand() == null, "no pending command at a fresh prompt");

    Feed(e, "cls");
    Check(e.PeekPendingCommand() == "cls", "pending command readable before Enter");

    // The shell clears the screen and re-renders the prompt at the top.
    Feed(e, "\r\n\x1b[2J\x1b[H\x1b]133;A\x07PS> \x1b]133;B\x07");
    Check(e.PeekPendingCommand() == null, "pending command empty after clear");

    // Alt-buffer apps never expose a pending command.
    Feed(e, "vim\x1b[?1049h");
    Check(e.PeekPendingCommand() == null, "no pending command in alt buffer");
    Feed(e, "\x1b[?1049l");
}

// --- right-aligned prompt decorations (clocks) ---------------------------------

{
    var e = NewEmu(40, 6);
    var commands = new List<string>();
    e.CommandExecuted += c => commands.Add(c);

    // Prompt with a clock right-aligned on the SAME row as the input.
    Feed(e, "\x1b]133;A\x07PS> \x1b]133;B\x07");
    Feed(e, "\x1b[1;30H19:08\x1b[1;5H");
    Check(e.PeekPendingCommand() == null, "clock beyond the cursor is not a pending command");

    Feed(e, "\x1b]133;B\x07" + "dir");
    Check(e.PeekPendingCommand() == "dir", $"typed command read up to the cursor (got '{e.PeekPendingCommand()}')");

    // Next prompt confirms the command; the clock past the blank gap is cut.
    Feed(e, "\r\nfiles...\r\n\x1b]133;A\x07PS> \x1b]133;B\x07");
    Check(commands.Count == 1 && commands[0] == "dir",
        $"command confirmed without the right prompt (got '{string.Join("|", commands)}')");
}

{
    // Re-render artifact: B stranded on a decoration line (clock), cursor on
    // the input line below with no wrap chain connecting them.
    var e = NewEmu(40, 6);
    Feed(e, "\x1b]133;A\x07");
    Feed(e, "\x1b[1;20H\x1b]133;B\x07" + "09:47");
    Feed(e, "\x1b[2;1H$ ");
    Check(e.PeekPendingCommand() == null,
        $"cursor-disconnected B is not pending input (got '{e.PeekPendingCommand()}')");
}

// --- agent reports (OSC 777) ---------------------------------------------------

{
    var e = NewEmu();
    string? payload = null;
    e.AgentReported += body => payload = body;

    Feed(e, "\x1b]777;notify;zharp://agent;{\"v\":1,\"event\":\"done\"}\x07");
    Check(payload == "{\"v\":1,\"event\":\"done\"}", $"OSC 777 agent report (got '{payload}')");

    // A JSON body is full of semicolons and colons; only the first two
    // separators belong to the OSC framing.
    payload = null;
    Feed(e, "\x1b]777;notify;zharp://agent;{\"a\":\"x;y\",\"b\":\"z\"}\x07");
    Check(payload == "{\"a\":\"x;y\",\"b\":\"z\"}", $"semicolons inside the body survive (got '{payload}')");

    // Somebody else's notification travelling through the same pty.
    payload = null;
    Feed(e, "\x1b]777;notify;warp://cli-agent;{\"v\":1}\x07");
    Check(payload == null, "another terminal's OSC 777 is ignored");

    payload = null;
    Feed(e, "\x1b]777;notify;zharp://agent\x07");
    Feed(e, "\x1b]777;something-else;zharp://agent;{}\x07");
    Check(payload == null, "malformed OSC 777 raises nothing");
}

// --- prompt return, which is how an exited agent is noticed --------------------

{
    var e = NewEmu(40, 6);
    int returned = 0;
    e.PromptReturned += () => returned++;

    Feed(e, "\x1b]133;A\x07$ ");
    Check(returned == 0, "the first prompt is not a return");

    Feed(e, "\x1b]133;A\x07");
    Check(returned == 0, "redrawing the same prompt is not a return");

    // Run something, then the shell prompts again below it.
    Feed(e, "claude\r\noutput\r\n\x1b]133;A\x07$ ");
    Check(returned == 1, $"a fresh prompt below the last one is (got {returned})");

    Feed(e, "\x1b]133;A\x07");
    Check(returned == 1, $"and does not fire twice for it (got {returned})");

    Feed(e, "\r\nmore\r\n\x1b]133;A\x07$ ");
    Check(returned == 2, $"every later command reports too (got {returned})");
}

{
    // A full screen program owns the alternate buffer, and the prompt marks it
    // paints there are its own business.
    var e = NewEmu(40, 6);
    int returned = 0;
    e.PromptReturned += () => returned++;
    Feed(e, "\x1b]133;A\x07$ ");
    Feed(e, "\x1b[?1049h");
    Feed(e, "\r\n\x1b]133;A\x07\r\n\x1b]133;A\x07");
    Feed(e, "\x1b[?1049l");
    Check(returned == 0, $"alt buffer prompt marks are not returns (got {returned})");
}

Console.WriteLine();
Console.WriteLine(failures == 0
    ? $"All {passed} checks passed."
    : $"{failures} FAILED, {passed} passed.");
return failures;
