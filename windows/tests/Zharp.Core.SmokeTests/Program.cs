using System.Text;
using Zharp.Core.Remote;
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

// --- alternate screen restore, which is how a TUI leaves no mess behind -------

{
    var e = NewEmu(20, 5);
    Feed(e, "shell line one\r\nshell line two");

    // A full screen program takes the alternate buffer and paints over it.
    Feed(e, "\x1b[?1049h");
    Feed(e, "\x1b[2J\x1b[H");
    Feed(e, "TUI FRAME\r\nbox border here");
    Check(RowText(e, 0) == "TUI FRAME", "alt buffer shows the program");

    // Leaving it must put back exactly what was underneath.
    Feed(e, "\x1b[?1049l");
    Check(RowText(e, 0) == "shell line one", $"alt exit restores row 0 (got '{RowText(e, 0)}')");
    Check(RowText(e, 1) == "shell line two", $"alt exit restores row 1 (got '{RowText(e, 1)}')");
    Check(!e.IsAlternateBuffer, "alt exit leaves the main buffer active");
}

{
    // A program that paints inline, with no alternate buffer at all, is
    // entitled to leave its last frame on screen: that is scrollback, and the
    // shell simply prompts underneath it.
    var e = NewEmu(20, 5);
    Feed(e, "\x1b]133;A\x07$ ");
    Feed(e, "codex\r\n");
    Feed(e, "box border here\r\n");
    Feed(e, "\x1b]133;A\x07$ ");
    Check(RowText(e, 1) == "box border here", $"inline TUI output stays in scrollback (got '{RowText(e, 1)}')");
    Check(RowText(e, 2) == "$", $"and the shell prompts underneath it (got '{RowText(e, 2)}')");
}

// --- synchronized output (mode 2026), which is what stops the flicker --------

{
    var e = NewEmu();
    Check(!e.SynchronizedOutput, "not holding by default");

    Feed(e, "\x1b[?2026h");
    Check(e.SynchronizedOutput, "2026h holds the frame");

    Feed(e, "\x1b[?2026l");
    Check(!e.SynchronizedOutput, "2026l releases it");

    // A program that dies mid frame must not leave the screen held forever.
    //  rather than \x1b: a C# \x escape eats as many hex digits as it
    // can find, so "\x1bc" is the single character U+01BC, not ESC then c.
    Feed(e, "\x1b[?2026h");
    Feed(e, "c");
    Check(!e.SynchronizedOutput, "a full reset releases it");
}

{
    // DECRQM. A program asks before it uses a mode, and silence reads as no,
    // so answering is what makes the mode above worth having.
    var e = NewEmu();
    string reply = "";
    e.ResponseRequested += r => reply += r;

    Feed(e, "\x1b[?2026$p");
    Check(reply == "\x1b[?2026;2$y", $"DECRQM: 2026 supported, currently reset (got '{Vis(reply)}')");

    reply = "";
    Feed(e, "\x1b[?2026h\x1b[?2026$p");
    Check(reply == "\x1b[?2026;1$y", $"DECRQM: reports it as set (got '{Vis(reply)}')");
    Feed(e, "\x1b[?2026l");

    reply = "";
    Feed(e, "\x1b[?9999$p");
    Check(reply == "\x1b[?9999;0$y", $"DECRQM: unknown mode is not recognized (got '{Vis(reply)}')");

    reply = "";
    Feed(e, "\x1b[?2004h\x1b[?2004$p");
    Check(reply == "\x1b[?2004;1$y", $"DECRQM: bracketed paste reports set (got '{Vis(reply)}')");

    // DECRQM must not be mistaken for anything else that ends in p.
    reply = "";
    Feed(e, "\x1b[?25$p");
    Check(reply == "\x1b[?25;1$y", $"DECRQM: cursor visible reports set (got '{Vis(reply)}')");
}

static string Vis(string s) => s.Replace("\x1b", "<ESC>");

// --- full screen paint, which decides blocks versus plain rows ----------------

{
    var e = NewEmu(40, 10);
    Check(!e.FullScreenPaint, "a plain shell is not painting the screen");

    Feed(e, "\x1b]133;A\x07$ ");
    Feed(e, "ls\r\nfile-one\r\n");
    Feed(e, "\x1b]133;A\x07$ ");
    Check(!e.FullScreenPaint, "ordinary command output is not either");

    // A program that draws frames says so by asking for them to be presented
    // whole, and no shell ever does.
    Feed(e, "codex\r\n");
    Feed(e, "\x1b[?2026h");
    Feed(e, "\x1b[5;1Hmenu row");
    Feed(e, "\x1b[?2026l");
    Check(e.FullScreenPaint, "synchronized frames mark a full screen program");

    // It has to stay set between frames, or the layout would flip back and
    // forth on every repaint.
    Feed(e, "\x1b[6;1Hanother row");
    Check(e.FullScreenPaint, "and stays set between its frames");

    // The shell getting its prompt back means the program is gone.
    Feed(e, "\r\n\x1b]133;A\x07$ ");
    Check(!e.FullScreenPaint, "a returned prompt clears it");
}

// ---------------------------------------------------------------------------
// Knowing which machine a session is on.
// ---------------------------------------------------------------------------
{
    var e = NewEmu();

    // OSC 7 with no host, and with this machine's own name, both describe
    // this computer. The empty host is what the file URI scheme says means
    // local, and a shell reporting our own hostname is not elsewhere either.
    Feed(e, "\x1b]7;file:///C:/work/app\x07");
    Check(e.WorkingDirectory == "C:\\work\\app", "OSC 7 with no host stays a Windows path");
    Check(e.WorkingDirectoryHost == null, "and is not treated as remote");

    Feed(e, $"\x1b]7;file://{Environment.MachineName}/C:/work/two\x07");
    Check(e.WorkingDirectoryHost == null, "our own hostname is not another machine");

    // The half that used to be thrown away.
    Feed(e, "\x1b]7;file://srv1/home/claudiu/proj\x07");
    Check(e.WorkingDirectoryHost == "srv1", "OSC 7 keeps the host it was given");
    Check(e.WorkingDirectory == "/home/claudiu/proj",
        "and leaves a remote path in the far end's own notation");

    // Percent escapes are the normal way a space arrives.
    Feed(e, "\x1b]7;file://srv1/home/my%20work\x07");
    Check(e.WorkingDirectory == "/home/my work", "escaped characters are decoded");

    // OSC 9;9 has no host field at all, so it can only ever be local. A
    // remote path arriving through it would be a local path by definition.
    Feed(e, "\x1b]9;9;C:\\other\x07");
    Check(e.WorkingDirectoryHost == null, "OSC 9;9 always describes this machine");
}

// ---------------------------------------------------------------------------
// Reading the ssh command the user typed.
// ---------------------------------------------------------------------------
{
    Check(SshTarget.Parse("ssh srv1") is { Label: "srv1" }, "a bare destination");
    Check(SshTarget.Parse("ssh claudiu@10.0.0.4") is { Label: "10.0.0.4" },
        "the user@ half is not part of the name");
    Check(SshTarget.Parse("ssh ssh://me@box:2222") is { Label: "box" }, "a URL destination");

    // The port has to be skipped or it reads as the machine.
    var ported = SshTarget.Parse("ssh -p 2222 srv1");
    Check(ported is { Label: "srv1" }, "a flag value is not mistaken for the destination");
    Check(ported != null && ported.Args.SequenceEqual(new[] { "-p", "2222", "srv1" }),
        "and the port is carried to our own connection");

    // Glued and clustered short flags.
    Check(SshTarget.Parse("ssh -p2222 srv1") is { Label: "srv1" }, "a glued flag value");
    var clustered = SshTarget.Parse("ssh -46C srv1");
    Check(clustered is { Label: "srv1" }, "clustered flags");
    Check(clustered != null && clustered.Args.SequenceEqual(new[] { "-4", "-6", "-C", "srv1" }),
        "each one kept separately");

    // Identity and jump host are exactly the flags that decide whether a
    // second connection reaches the same place, so they carry over.
    var keyed = SshTarget.Parse("ssh -i \"C:\\My Keys\\id_ed25519\" -J bastion srv1");
    Check(keyed != null && keyed.Args.SequenceEqual(
        new[] { "-i", "C:\\My Keys\\id_ed25519", "-J", "bastion", "srv1" }),
        "a quoted key path survives, and so does the jump host");

    // Forwards must NOT carry over: opening them again either fails on a
    // bound port or silently duplicates what the user set up.
    var forwarded = SshTarget.Parse("ssh -L 8080:localhost:80 srv1");
    Check(forwarded != null && forwarded.Args.SequenceEqual(new[] { "srv1" }),
        "a port forward is dropped from our own connection");

    // Invocations that never produce a shell to be standing in.
    Check(SshTarget.Parse("ssh -N -L 9000:localhost:9000 srv1") == null, "a tunnel is not a session");
    Check(SshTarget.Parse("ssh -O exit srv1") == null, "a control command is not a session");
    Check(SshTarget.Parse("ssh -W host:22 srv1") == null, "a stdio forward is not a session");

    // The rest of the family never connects anywhere.
    Check(SshTarget.Parse("ssh-keygen -t ed25519") == null, "ssh-keygen is not ssh");
    Check(SshTarget.Parse("ssh-add ~/.ssh/id_ed25519") == null, "ssh-add is not ssh");
    Check(SshTarget.Parse("git status") == null, "and neither is anything else");
    Check(SshTarget.Parse("ssh") == null, "ssh with no destination goes nowhere");

    // A full path to the program, which is what a completion may produce.
    Check(SshTarget.Parse("C:\\Windows\\System32\\OpenSSH\\ssh.exe srv1") is { Label: "srv1" },
        "a fully qualified ssh");

    // A remote command still means the user went to that machine.
    Check(SshTarget.Parse("ssh srv1 uptime") is { Label: "srv1" }, "a trailing command keeps the host");
    var withCommand = SshTarget.Parse("ssh srv1 uptime");
    Check(withCommand != null && withCommand.Args.SequenceEqual(new[] { "srv1" }),
        "but the command itself is not ours to run");
}

// ---------------------------------------------------------------------------
// Reading a remote shell's window title, the fallback when OSC 7 is absent.
// ---------------------------------------------------------------------------
{
    // What Debian and Ubuntu put there without anyone configuring anything.
    var (host, path) = PromptTitle.Parse("claudiu@srv1: ~/work/proj");
    Check(host == "srv1" && path == "~/work/proj", "the default Debian title");

    (host, path) = PromptTitle.Parse("srv1:/var/www");
    Check(host == "srv1" && path == "/var/www", "a bare host and an absolute path");

    // Things that are not locations, which a title very often is.
    Check(PromptTitle.Parse("make: *** [all] Error 1").Host == null, "an error message is not a location");
    Check(PromptTitle.Parse("nvim").Host == null, "a program name is not a location");
    Check(PromptTitle.Parse("Zharp").Host == null, "and neither is ours");
    Check(PromptTitle.Parse("weird host: ~/x").Host == null, "a hostname has no spaces in it");
    Check(PromptTitle.Parse(null).Host == null, "no title at all");
}

// ---------------------------------------------------------------------------
// Paths on the other machine, which are not this machine's paths.
// ---------------------------------------------------------------------------
{
    Check(PosixPath.GetFileName("/home/me/app/main.ts") == "main.ts", "the last segment");
    Check(PosixPath.GetFileName("/home/me/app/") == "app", "a trailing slash is not a segment");

    Check(PosixPath.IsUnder("/home/me/app", "/home/me/app/src/x.ts", out var rel)
        && rel == "src/x.ts", "a file inside the repository");
    Check(!PosixPath.IsUnder("/home/me/app", "/home/me/other/x.ts", out _),
        "a file outside it");
    Check(!PosixPath.IsUnder("/home/me/app", "/home/me/application/x.ts", out _),
        "a sibling whose name starts the same way");
    Check(!PosixPath.IsUnder("/home/me/app", "/home/me/App/x.ts", out _),
        "the far end is case sensitive even though this one is not");

    Check(PosixPath.ExpandHome("~/work", "/home/me") == "/home/me/work", "~ becomes the home directory");
    Check(PosixPath.ExpandHome("~", "/home/me") == "/home/me", "~ on its own");
    Check(PosixPath.ExpandHome("~other/work", "/home/me") == "~other/work",
        "another user's home is not ours to guess");
    Check(PosixPath.ExpandHome("/var/www", "/home/me") == "/var/www", "an absolute path is left alone");

    // Everything sent over the wire is quoted, because a filename is allowed
    // to contain the characters a shell acts on.
    Check(ShellWords.Quote("plain") == "'plain'", "ordinary text");
    Check(ShellWords.Quote("it's") == "'it'\\''s'", "a quote is closed, escaped and reopened");
    Check(ShellWords.Quote("a; rm -rf /") == "'a; rm -rf /'", "a semicolon stays data");
}

// ---------------------------------------------------------------------------
// A place is a machine and a path, never one without the other.
// ---------------------------------------------------------------------------
{
    var srv = new RemoteHost("srv1", new[] { "srv1" });
    var other = new RemoteHost("srv1", new[] { "-p", "2222", "srv1" });

    Check(!srv.Equals(other), "the same name on a different port is a different machine");
    Check(!RemoteHost.Reported("a").Equals(RemoteHost.Reported("b")),
        "two machines we only heard about stay distinct");
    Check(!RemoteHost.Reported("srv1").CanConnect,
        "a machine that only announced itself is never dialled");
    Check(srv.CanConnect, "one the user reached is");

    Check(!Equals(SessionLocation.On(srv, "/home/me"), SessionLocation.Local("/home/me")),
        "the same path on two machines is two places");
    Check(Equals(SessionLocation.Local("C:\\Work"), SessionLocation.Local("c:\\work")),
        "local paths compare the way Windows does");
    Check(!Equals(SessionLocation.On(srv, "/A"), SessionLocation.On(srv, "/a")),
        "remote paths compare the way the far end does");
    Check(!SessionLocation.On(srv, "").HasPath,
        "being on a machine without knowing where is a real state");
}

// ---------------------------------------------------------------------------
// The ssh transport itself, run against a real POSIX shell.
//
// ZHARP_SSH points the channel at a stub that ignores the connection flags and
// starts a local sh, so everything below this line is the actual code path a
// remote session takes: the handshake, the framing, the base64 that keeps a
// filename with a newline in it from being read as the end of an answer, and
// the quoting. Only the network is missing.
//
// Skipped rather than failed when there is no POSIX shell here, so that this
// never reports a problem with Zharp when the problem is the machine.
// ---------------------------------------------------------------------------
{
    string? sh = new[]
    {
        @"C:\Program Files\Git\usr\bin\sh.exe",
        @"C:\Program Files\Git\bin\sh.exe",
    }.FirstOrDefault(File.Exists);

    if (sh == null)
    {
        Console.WriteLine("SKIP  ssh transport (no POSIX shell on this machine)");
    }
    else
    {
        // A real remote has coreutils on its PATH already; a Git for Windows
        // shell started from outside its own launcher does not, so the stub
        // puts them there. Nothing about the transport depends on this.
        string tools = Path.GetDirectoryName(sh)!;
        string stub = Path.Combine(Path.GetTempPath(), "zharp-ssh-stub.cmd");
        File.WriteAllText(stub,
            "@echo off\r\nset PATH=" + tools + ";%PATH%\r\n\"" + sh + "\"\r\n");
        Environment.SetEnvironmentVariable("ZHARP_SSH", stub);

        var host = new RemoteHost("stub", new[] { "stub" });
        using var channel = await SshGitChannel.ConnectAsync(host, CancellationToken.None);

        Check(channel.IsUsable, "the channel connects and agrees on a protocol");
        if (!channel.IsUsable)
            Console.WriteLine($"      (channel problem: {channel.Problem})");
        Check(!string.IsNullOrEmpty(channel.Home), "and reports the home directory");

        // A path with a space, which is the ordinary reason naive quoting
        // breaks, and the repository this is running from.
        string temp = Path.Combine(Path.GetTempPath(), "zharp remote test");
        Directory.CreateDirectory(temp);
        string posixTemp = "/" + char.ToLowerInvariant(temp[0]) + temp[2..].Replace('\\', '/');

        string echoed = (await channel.RunAsync(posixTemp, new[] { "pwd" }, default)).Trim();
        Check(echoed.EndsWith("zharp remote test", StringComparison.Ordinal),
            "a directory with a space in it is quoted correctly");

        // Bytes that would break a line-oriented protocol: the marker word
        // itself, and a newline in the middle of the payload.
        string tricky = await channel.RunAsync(posixTemp,
            new[] { "printf", "one\\ntwo ZHARP-END three\\n" }, default);
        Check(tricky == "one\ntwo ZHARP-END three\n",
            "output survives newlines and text that looks like the frame marker");

        // Nothing on stdout is a normal answer, not a broken one.
        Check(await channel.RunAsync(posixTemp, new[] { "true" }, default) == "",
            "a command that prints nothing returns nothing");
        Check(await channel.RunAsync("/no/such/directory", new[] { "pwd" }, default) == "",
            "a directory that is not there returns nothing");

        // The channel stays usable across all of that: one connection serving
        // many questions is the entire point of it.
        Check(channel.IsUsable, "and the connection is still good afterwards");

        // Non-ASCII has to survive the round trip, since it is what filenames
        // in half the world are made of.
        string unicode = await channel.RunAsync(posixTemp,
            new[] { "printf", "café ünïcode 日本\\n" }, default);
        Check(unicode.Trim() == "café ünïcode 日本", "and so does UTF-8");

        Environment.SetEnvironmentVariable("ZHARP_SSH", null);
        try { Directory.Delete(temp); File.Delete(stub); } catch { }
    }
}

Console.WriteLine();
Console.WriteLine(failures == 0
    ? $"All {passed} checks passed."
    : $"{failures} FAILED, {passed} passed.");
return failures;
