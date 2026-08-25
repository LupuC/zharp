using System.Text;

namespace Zharp.Core.Terminal;

/// <summary>
/// The terminal emulator: owns the main and alternate screen buffers, cursor,
/// attributes and modes, and executes the VT actions produced by the parser.
/// All access (Feed / Resize / rendering reads) must hold <see cref="SyncRoot"/>;
/// Feed and Resize take it themselves.
/// </summary>
public sealed class TerminalEmulator : IVtHandler
{
    public object SyncRoot { get; } = new();

    private readonly VtParser _parser;
    private readonly Decoder _utf8 = Encoding.UTF8.GetDecoder();
    private char[] _decodeBuffer = new char[4096];
    private char _pendingHighSurrogate;

    private readonly ScreenBuffer _main;
    private readonly ScreenBuffer _alt;
    private ScreenBuffer _active;

    public int Cols { get; private set; }
    public int Rows { get; private set; }

    // Cursor
    public int CursorX { get; private set; }
    public int CursorY { get; private set; }
    public bool CursorVisible { get; private set; } = true;
    /// <summary>DECSCUSR style: 0-2 block, 3-4 underline, 5-6 bar.</summary>
    public int CursorStyle { get; private set; }
    public bool WrapPending { get; private set; }

    // Current attributes
    private TerminalColor _fg = TerminalColor.Default;
    private TerminalColor _bg = TerminalColor.Default;
    private CellFlags _flags;

    // Modes
    public bool ApplicationCursorKeys { get; private set; }
    public bool ApplicationKeypad { get; private set; }
    public bool BracketedPaste { get; private set; }
    public bool FocusEvents { get; private set; }
    public bool IsAlternateBuffer => _active == _alt;
    private bool _originMode;
    private bool _autoWrap = true;
    private bool _insertMode;
    private bool _lineFeedMode;
    private int _mouseMode; // 1000/1002/1003, informational only for now

    // Scroll region (0-based, inclusive)
    private int _regionTop;
    private int _regionBottom;

    // Charsets (G0/G1 designators, 'B' = ASCII, '0' = DEC line drawing)
    private char _g0 = 'B';
    private char _g1 = 'B';
    private int _activeCharset;

    private bool[] _tabStops;
    private int _lastPrinted = -1;

    private struct SavedCursor
    {
        public int X, Y;
        public TerminalColor Fg, Bg;
        public CellFlags Flags;
        public char G0, G1;
        public int ActiveCharset;
        public bool OriginMode;
        public bool AutoWrap;
    }

    private SavedCursor _savedMain;
    private SavedCursor _savedAlt;

    public string? Title { get; private set; }

    /// <summary>Shell-reported current directory (OSC 9;9 / OSC 7), if any.</summary>
    public string? WorkingDirectory { get; private set; }

    private readonly List<long> _promptMarksRaw = new();

    /// <summary>Absolute main-buffer line where the shell last drew its prompt,
    /// or -1 when no prompt has been seen. Derived from OSC 9;9, which the
    /// injected shell hooks emit on every prompt render.</summary>
    public int PromptMarkLine => _promptMarksRaw.Count == 0
        ? -1
        : (int)Math.Max(0, _promptMarksRaw[^1] - _main.DroppedLines);

    /// <summary>All known prompt-line marks (ascending absolute main-buffer
    /// lines), for block-style rendering. Call under SyncRoot.</summary>
    public List<int> GetPromptMarks()
    {
        var marks = new List<int>(_promptMarksRaw.Count);
        long dropped = _main.DroppedLines;
        foreach (long raw in _promptMarksRaw)
        {
            long abs = raw - dropped;
            if (abs >= 0)
                marks.Add((int)abs);
        }
        return marks;
    }

    /// <summary>Raised when a fresh prompt appears after a command block: the
    /// argument is the command the user ran in that block (from the prompt-end
    /// mark to the end of its soft-wrap chain). Not raised for empty prompts.</summary>
    public event Action<string>? CommandExecuted;

    /// <summary>
    /// The shell has drawn a fresh prompt below the last one, so whatever was
    /// running in the foreground has exited.
    ///
    /// This is the only completely reliable way to know an agent is gone. An
    /// agent's own "session ended" hook fires while its process is tearing
    /// itself down, which is the worst possible moment to be asking it to write
    /// to the terminal, and a report that never arrives leaves a tab claiming
    /// to be busy forever. A prompt coming back cannot be missed.
    /// </summary>
    public event Action? PromptReturned;

    private void RecordPromptMark()
    {
        long raw = _main.DroppedLines + _main.ScrollbackCount + CursorY;

        // A genuinely NEW prompt below the last one means the previous block
        // just finished - report the command that ran in it.
        bool freshPrompt = _promptMarksRaw.Count > 0 && raw > _promptMarksRaw[^1];

        if (freshPrompt && CommandExecuted != null)
        {
            long prevMark = _promptMarksRaw[^1];
            for (int i = _promptEndMarksRaw.Count - 1; i >= 0; i--)
            {
                var (line, col) = _promptEndMarksRaw[i];
                if (line >= prevMark && line < raw)
                {
                    string command = ReadCommandText(line, col, raw);
                    if (command.Length > 0)
                        CommandExecuted(command);
                    break;
                }
            }
        }

        // A prompt re-rendered at or above an old mark (cls, redraw) invalidates
        // the marks below it - keep the list strictly ascending.
        while (_promptMarksRaw.Count > 0 && _promptMarksRaw[^1] >= raw)
            _promptMarksRaw.RemoveAt(_promptMarksRaw.Count - 1);
        while (_promptEndMarksRaw.Count > 0 && _promptEndMarksRaw[^1].Line >= raw)
            _promptEndMarksRaw.RemoveAt(_promptEndMarksRaw.Count - 1);
        _promptMarksRaw.Add(raw);
        if (_promptMarksRaw.Count > 256)
            _promptMarksRaw.RemoveAt(0);

        // After the bookkeeping, so anyone listening sees settled state.
        if (freshPrompt)
            PromptReturned?.Invoke();
    }

    /// <summary>True when the live prompt has a valid prompt-end mark - i.e.
    /// the shell integration is active and the input line's contents are
    /// readable. Call under SyncRoot.</summary>
    public bool HasLivePromptInput
    {
        get
        {
            if (IsAlternateBuffer || _promptEndMarksRaw.Count == 0 || _promptMarksRaw.Count == 0)
                return false;
            return _promptEndMarksRaw[^1].Line >= _promptMarksRaw[^1];
        }
    }

    /// <summary>The command currently typed at the live prompt (from the last
    /// prompt-end mark), or null. Lets the host capture a command on Enter -
    /// commands like cls/clear erase the screen before the next prompt, so
    /// waiting for it would lose them. Call under SyncRoot.</summary>
    public string? PeekPendingCommand()
    {
        if (IsAlternateBuffer || _promptEndMarksRaw.Count == 0 || _promptMarksRaw.Count == 0)
            return null;
        var (line, col) = _promptEndMarksRaw[^1];
        if (line < _promptMarksRaw[^1])
            return null; // stale mark from an older prompt
        // Typed input connects the B mark to the cursor along a soft-wrap
        // chain. Prompt re-renders can strand B on a decoration line (a
        // right-aligned clock) with the cursor elsewhere - anything after
        // such a B is decoration, not input.
        long dropped = _main.DroppedLines;
        int bAbs = (int)(line - dropped);
        int cursorAbs = _main.ScrollbackCount + CursorY;
        if (cursorAbs < bAbs)
            return null;
        int reach = bAbs;
        while (reach < cursorAbs && reach < _main.TotalLines &&
               _main.GetAbsoluteLine(reach).Wrapped && reach - bAbs < 4)
            reach++;
        if (reach != cursorAbs)
            return null;
        // Stop at the cursor: typed text ends there, while right-aligned
        // prompt decorations (clocks etc.) live beyond it on the same row.
        string command = ReadCommandText(line, col, line + 4, stopAtCursor: true);
        return command.Length > 0 ? command : null;
    }

    /// <summary>The typed command starting at a prompt-end mark, following the
    /// soft-wrap chain (long commands wrap), capped defensively. stopAtCursor
    /// reads only up to the caret (live input); otherwise a wide blank gap
    /// cuts the rest of the row off - right-aligned prompt decorations.</summary>
    private string ReadCommandText(long rawLine, int fromCol, long rawLimit, bool stopAtCursor = false)
    {
        var sb = new System.Text.StringBuilder();
        long dropped = _main.DroppedLines;
        int abs = (int)(rawLine - dropped);
        int cursorAbs = _main.ScrollbackCount + CursorY;
        int limit = (int)Math.Min(rawLimit - dropped, abs + 4); // cap wrap chain
        for (int i = abs; i >= 0 && i < limit && i < _main.TotalLines; i++)
        {
            var line = _main.GetAbsoluteLine(i);
            int start = i == abs ? fromCol : 0;
            int end = Math.Min(line.Cells.Length, Cols); // shrink leaves stale tails
            if (stopAtCursor && i == cursorAbs)
                end = Math.Min(end, CursorX);
            int lineStart = sb.Length;
            for (int c = start; c < end && sb.Length < 300; c++)
            {
                ref readonly var cell = ref line.Cells[c];
                if ((cell.Flags & CellFlags.WideTrailing) != 0)
                    continue;
                sb.Append(cell.Rune == 0 ? " " : char.ConvertFromUtf32(cell.Rune));
            }
            int len = sb.Length;
            while (len > lineStart && sb[len - 1] == ' ')
                len--;
            sb.Length = len;
            if (!line.Wrapped || sb.Length >= 300 || (stopAtCursor && i == cursorAbs))
                break;
        }
        string result = sb.ToString().Trim();
        if (!stopAtCursor)
        {
            // "dir        19:08" -> "dir": eight-plus consecutive spaces mean
            // the rest of the row is a right prompt, not the command.
            int gap = result.IndexOf("        ", StringComparison.Ordinal);
            if (gap > 0)
                result = result[..gap].TrimEnd();
        }
        return result;
    }

    private readonly List<(long Line, int Col)> _promptEndMarksRaw = new();

    /// <summary>OSC 133;B: the prompt finished rendering - the cursor now sits
    /// where the user's command starts. Lets block copy separate the typed
    /// command from the prompt decoration.</summary>
    private void RecordPromptEnd()
    {
        long raw = _main.DroppedLines + _main.ScrollbackCount + CursorY;
        while (_promptEndMarksRaw.Count > 0 && _promptEndMarksRaw[^1].Line >= raw)
            _promptEndMarksRaw.RemoveAt(_promptEndMarksRaw.Count - 1);
        _promptEndMarksRaw.Add((raw, CursorX));
        if (_promptEndMarksRaw.Count > 256)
            _promptEndMarksRaw.RemoveAt(0);
    }

    /// <summary>All known prompt-end marks as (absolute main-buffer line,
    /// column where the command starts), ascending. Call under SyncRoot.</summary>
    public List<(int Line, int Col)> GetPromptEnds()
    {
        var ends = new List<(int, int)>(_promptEndMarksRaw.Count);
        long dropped = _main.DroppedLines;
        foreach (var (rawLine, col) in _promptEndMarksRaw)
        {
            long abs = rawLine - dropped;
            if (abs >= 0)
                ends.Add(((int)abs, col));
        }
        return ends;
    }

    public event Action<string>? TitleChanged;
    public event Action<string>? WorkingDirectoryChanged;
    public event Action<string>? ResponseRequested;
    public event Action? BellRang;

    public TerminalEmulator(int cols, int rows, int maxScrollback = 10000)
    {
        Cols = Math.Max(2, cols);
        Rows = Math.Max(2, rows);
        _main = new ScreenBuffer(Cols, Rows, maxScrollback);
        _alt = new ScreenBuffer(Cols, Rows, 0);
        _active = _main;
        _regionBottom = Rows - 1;
        _tabStops = BuildTabStops(Cols);
        _parser = new VtParser(this);
    }

    /// <summary>The buffer currently displayed (main or alternate).</summary>
    public ScreenBuffer Buffer => _active;

    /// <summary>Scrollback lines available for the current view (alt screen has none).</summary>
    public int ScrollbackCount => _active.ScrollbackCount;

    // ---------------------------------------------------------------- input

    public void Feed(ReadOnlySpan<byte> data)
    {
        lock (SyncRoot)
        {
            int maxChars = _utf8.GetCharCount(data, flush: false);
            if (_decodeBuffer.Length < maxChars)
                _decodeBuffer = new char[Math.Max(maxChars, _decodeBuffer.Length * 2)];
            int written = _utf8.GetChars(data, _decodeBuffer, flush: false);

            for (int i = 0; i < written; i++)
            {
                char c = _decodeBuffer[i];
                if (_pendingHighSurrogate != 0)
                {
                    if (char.IsLowSurrogate(c))
                        _parser.Process(char.ConvertToUtf32(_pendingHighSurrogate, c));
                    _pendingHighSurrogate = '\0';
                    if (char.IsLowSurrogate(c))
                        continue;
                }
                if (char.IsHighSurrogate(c))
                {
                    _pendingHighSurrogate = c;
                    continue;
                }
                if (char.IsLowSurrogate(c))
                    continue; // orphaned low surrogate, drop
                _parser.Process(c);
            }
        }
    }

    public void Resize(int cols, int rows)
    {
        cols = Math.Max(2, cols);
        rows = Math.Max(2, rows);
        lock (SyncRoot)
        {
            if (cols == Cols && rows == Rows)
                return;

            int cursorY = CursorY;
            _main.Resize(cols, rows, ref cursorY);
            int altY = _active == _alt ? CursorY : 0;
            _alt.Resize(cols, rows, ref altY);
            CursorY = _active == _main ? cursorY : altY;

            Cols = cols;
            Rows = rows;
            CursorX = Math.Clamp(CursorX, 0, Cols - 1);
            CursorY = Math.Clamp(CursorY, 0, Rows - 1);
            _regionTop = 0;
            _regionBottom = Rows - 1;
            _tabStops = BuildTabStops(Cols);
            WrapPending = false;
        }
    }

    // ---------------------------------------------------------------- IVtHandler

    void IVtHandler.Print(int rune) => PrintRune(rune);

    void IVtHandler.Execute(int c)
    {
        switch (c)
        {
            case 0x07: BellRang?.Invoke(); break;
            case 0x08: Backspace(); break;
            case 0x09: HorizontalTab(); break;
            case 0x0A:
            case 0x0B:
            case 0x0C:
                LineFeed();
                if (_lineFeedMode)
                    CarriageReturn();
                break;
            case 0x0D: CarriageReturn(); break;
            case 0x0E: _activeCharset = 1; break; // SO
            case 0x0F: _activeCharset = 0; break; // SI
        }
    }

    void IVtHandler.EscDispatch(string intermediates, char final)
    {
        if (intermediates.Length == 0)
        {
            switch (final)
            {
                case '7': SaveCursor(); break;
                case '8': RestoreCursor(); break;
                case 'D': Index(); break;
                case 'E': Index(); CarriageReturn(); break;
                case 'H': if (CursorX < Cols) _tabStops[CursorX] = true; break;
                case 'M': ReverseIndex(); break;
                case 'c': FullReset(); break;
                case '=': ApplicationKeypad = true; break;
                case '>': ApplicationKeypad = false; break;
            }
            return;
        }

        switch (intermediates[0])
        {
            case '#':
                if (final == '8')
                    ScreenAlignmentPattern();
                break;
            case '(': _g0 = final; break;
            case ')': _g1 = final; break;
        }
    }

    void IVtHandler.OscDispatch(string payload)
    {
        int sep = payload.IndexOf(';');
        if (sep < 0)
            return;
        if (!int.TryParse(payload.AsSpan(0, sep), out int code))
            return;
        string arg = payload[(sep + 1)..];
        switch (code)
        {
            case 0:
            case 1:
            case 2:
                Title = arg;
                TitleChanged?.Invoke(arg);
                break;
            case 7:
                // OSC 7: file://[host]/path - xterm working-directory convention.
                SetWorkingDirectory(ParseFileUri(arg));
                break;
            case 9:
                // OSC 9;9;<path> - ConEmu/Windows Terminal working-directory
                // convention. NOT usable as a prompt mark: ConPTY re-renders
                // the stream and injects these at unpredictable positions.
                if (arg.StartsWith("9;", StringComparison.Ordinal))
                    SetWorkingDirectory(arg[2..].Trim('"'));
                break;
            case 133:
                // OSC 133 (FinalTerm/FTCS): "A" = prompt start, "B" = prompt end
                // (command input begins). Our shell hooks emit them, and ConPTY
                // passes them through at the right position.
                if (IsAlternateBuffer)
                    break;
                if (arg.StartsWith("A", StringComparison.OrdinalIgnoreCase))
                    RecordPromptMark();
                else if (arg.StartsWith("B", StringComparison.OrdinalIgnoreCase))
                    RecordPromptEnd();
                break;
            case 777:
                // OSC 777;notify;<title>;<body> - the rxvt-unicode notification
                // convention, which the AI coding agents have settled on for
                // talking to their terminal. Only our own title is claimed;
                // another program's notification is its business, not ours.
                HandleNotify(arg);
                break;
        }
    }

    /// <summary>The OSC 777 title an agent uses to address Zharp specifically.</summary>
    private const string AgentNotifyTitle = "zharp://agent";

    /// <summary>
    /// An AI agent reporting its own state, as the raw JSON body of the
    /// notification. Zharp used to work this out by reading the screen, which
    /// could see that an agent was busy but never that it was waiting on you.
    /// </summary>
    public event Action<string>? AgentReported;

    private void HandleNotify(string arg)
    {
        const string Verb = "notify;";
        if (!arg.StartsWith(Verb, StringComparison.Ordinal))
            return;

        string rest = arg[Verb.Length..];
        int sep = rest.IndexOf(';');
        if (sep < 0)
            return;
        if (!rest.AsSpan(0, sep).Equals(AgentNotifyTitle, StringComparison.Ordinal))
            return;

        AgentReported?.Invoke(rest[(sep + 1)..]);
    }

    private void SetWorkingDirectory(string? path)
    {
        if (string.IsNullOrWhiteSpace(path))
            return;
        path = path.TrimEnd('\\', '/');
        if (path.Length == 2 && path[1] == ':')
            path += "\\"; // keep drive roots as C:\
        if (path == WorkingDirectory)
            return;
        WorkingDirectory = path;
        WorkingDirectoryChanged?.Invoke(path);
    }

    private static string? ParseFileUri(string uri)
    {
        if (!uri.StartsWith("file://", StringComparison.OrdinalIgnoreCase))
            return null;
        string rest = uri[7..];
        int slash = rest.IndexOf('/');
        if (slash < 0)
            return null;
        rest = rest[slash..]; // drop host part
        string path = Uri.UnescapeDataString(rest).Replace('/', '\\');
        // "/C:\..." → "C:\..."
        if (path.Length >= 3 && path[0] == '\\' && path[2] == ':')
            path = path[1..];
        return path;
    }

    void IVtHandler.CsiDispatch(char prefix, string intermediates, IReadOnlyList<int[]> parameters, char final)
    {
        int P(int index, int fallback = 0) =>
            index < parameters.Count && parameters[index].Length > 0 ? parameters[index][0] : fallback;
        int P1(int index) => Math.Max(1, P(index));

        if (intermediates.Length > 0)
        {
            if (intermediates == " " && final == 'q') // DECSCUSR
                CursorStyle = P(0);
            return;
        }

        if (prefix == '?')
        {
            switch (final)
            {
                case 'h': SetPrivateModes(parameters, true); break;
                case 'l': SetPrivateModes(parameters, false); break;
                case 'J': EraseInDisplay(P(0)); break;
                case 'K': EraseInLine(P(0)); break;
                case 'n':
                    if (P(0) == 6)
                        Respond($"\x1b[?{CursorRowForReport()};{CursorX + 1};1R");
                    break;
            }
            return;
        }

        if (prefix == '>')
        {
            if (final == 'c')
                Respond("\x1b[>0;10;1c"); // DA2: VT100-family, firmware 1.0
            return;
        }

        if (prefix != '\0')
            return;

        switch (final)
        {
            case '@': InsertCharacters(P1(0)); break;
            case 'A': MoveCursor(0, -P1(0)); break;
            case 'B': MoveCursor(0, P1(0)); break;
            case 'C': MoveCursor(P1(0), 0); break;
            case 'D': MoveCursor(-P1(0), 0); break;
            case 'E': MoveCursor(0, P1(0)); CursorX = 0; WrapPending = false; break;
            case 'F': MoveCursor(0, -P1(0)); CursorX = 0; WrapPending = false; break;
            case 'G': SetCursorColumn(P1(0) - 1); break;
            case '`': SetCursorColumn(P1(0) - 1); break;
            case 'H':
            case 'f':
                SetCursorPosition(P1(1) - 1, P1(0) - 1);
                break;
            case 'I': for (int i = 0; i < P1(0); i++) HorizontalTab(); break;
            case 'J': EraseInDisplay(P(0)); break;
            case 'K': EraseInLine(P(0)); break;
            case 'L': InsertLines(P1(0)); break;
            case 'M': DeleteLines(P1(0)); break;
            case 'P': DeleteCharacters(P1(0)); break;
            case 'S': ScrollRegion(P1(0), up: true); break;
            case 'T': ScrollRegion(P1(0), up: false); break;
            case 'X': EraseCharacters(P1(0)); break;
            case 'Z': for (int i = 0; i < P1(0); i++) BackTab(); break;
            case 'a': MoveCursor(P1(0), 0); break;
            case 'b': RepeatLastCharacter(P1(0)); break;
            case 'c': Respond("\x1b[?62;22c"); break; // DA1: VT220 with ANSI color
            case 'd': SetCursorRow(P1(0) - 1); break;
            case 'e': MoveCursor(0, P1(0)); break;
            case 'g':
                if (P(0) == 3) Array.Clear(_tabStops);
                else if (P(0) == 0 && CursorX < Cols) _tabStops[CursorX] = false;
                break;
            case 'h': SetAnsiModes(parameters, true); break;
            case 'l': SetAnsiModes(parameters, false); break;
            case 'm': SelectGraphicRendition(parameters); break;
            case 'n':
                if (P(0) == 5) Respond("\x1b[0n");
                else if (P(0) == 6) Respond($"\x1b[{CursorRowForReport()};{CursorX + 1}R");
                break;
            case 'r':
                SetScrollRegion(P(0), P(1));
                break;
            case 's': SaveCursor(); break;
            case 'u': RestoreCursor(); break;
        }
    }

    // ---------------------------------------------------------------- printing

    private static readonly Dictionary<int, int> DecGraphics = new()
    {
        ['`'] = 0x25C6, ['a'] = 0x2592, ['b'] = 0x2409, ['c'] = 0x240C,
        ['d'] = 0x240D, ['e'] = 0x240A, ['f'] = 0x00B0, ['g'] = 0x00B1,
        ['h'] = 0x2424, ['i'] = 0x240B, ['j'] = 0x2518, ['k'] = 0x2510,
        ['l'] = 0x250C, ['m'] = 0x2514, ['n'] = 0x253C, ['o'] = 0x23BA,
        ['p'] = 0x23BB, ['q'] = 0x2500, ['r'] = 0x23BC, ['s'] = 0x23BD,
        ['t'] = 0x251C, ['u'] = 0x2524, ['v'] = 0x2534, ['w'] = 0x252C,
        ['x'] = 0x2502, ['y'] = 0x2264, ['z'] = 0x2265, ['{'] = 0x03C0,
        ['|'] = 0x2260, ['}'] = 0x00A3, ['~'] = 0x00B7, ['_'] = ' ',
    };

    private void PrintRune(int rune)
    {
        char charset = _activeCharset == 0 ? _g0 : _g1;
        if (charset == '0' && rune >= 0x5F && rune <= 0x7E && DecGraphics.TryGetValue(rune, out int mapped))
            rune = mapped;

        int width = CharWidth.GetWidth(rune);
        if (width == 0)
            return; // combining marks not composed yet - dropped rather than corrupting the grid

        if (WrapPending && _autoWrap)
        {
            var line = _active.GetScreenLine(CursorY);
            line.Wrapped = true;
            CarriageReturn();
            LineFeed();
        }
        WrapPending = false;

        if (width == 2 && CursorX >= Cols - 1)
        {
            // Wide char doesn't fit in the last column.
            if (_autoWrap)
            {
                var line = _active.GetScreenLine(CursorY);
                line.FillRange(CursorX, Cols, MakeEraseCell());
                line.Wrapped = true;
                CarriageReturn();
                LineFeed();
            }
            else
            {
                CursorX = Math.Max(0, Cols - 2);
            }
        }

        var row = _active.GetScreenLine(CursorY);

        if (_insertMode)
        {
            var cells = row.Cells;
            int limit = Math.Min(Cols, cells.Length);
            for (int i = limit - 1; i > CursorX + width - 1; i--)
                cells[i] = cells[i - width];
        }

        // If we overwrite half of an existing wide char, blank its other half.
        ClearWideAt(row, CursorX);
        if (width == 2)
            ClearWideAt(row, CursorX + 1);

        row.Cells[CursorX] = new Cell { Rune = rune, Fg = _fg, Bg = _bg, Flags = _flags };
        if (width == 2 && CursorX + 1 < row.Cells.Length)
            row.Cells[CursorX + 1] = new Cell { Rune = 0, Fg = _fg, Bg = _bg, Flags = _flags | CellFlags.WideTrailing };

        _lastPrinted = rune;

        CursorX += width;
        if (CursorX >= Cols)
        {
            if (_autoWrap)
            {
                CursorX = Cols - 1;
                WrapPending = true;
            }
            else
            {
                CursorX = Cols - 1;
            }
        }
    }

    private void ClearWideAt(TerminalLine row, int x)
    {
        if (x < 0 || x >= row.Cells.Length)
            return;
        ref var cell = ref row.Cells[x];
        if ((cell.Flags & CellFlags.WideTrailing) != 0 && x > 0)
        {
            row.Cells[x - 1].Rune = ' ';
            cell.Flags &= ~CellFlags.WideTrailing;
        }
        else if (x + 1 < row.Cells.Length && (row.Cells[x + 1].Flags & CellFlags.WideTrailing) != 0)
        {
            row.Cells[x + 1].Rune = ' ';
            row.Cells[x + 1].Flags &= ~CellFlags.WideTrailing;
        }
    }

    private void RepeatLastCharacter(int count)
    {
        if (_lastPrinted < 0)
            return;
        count = Math.Min(count, Cols * Rows);
        for (int i = 0; i < count; i++)
            PrintRune(_lastPrinted);
    }

    // ---------------------------------------------------------------- cursor & movement

    private void Backspace()
    {
        if (WrapPending)
        {
            WrapPending = false;
            return;
        }
        if (CursorX > 0)
            CursorX--;
    }

    private void HorizontalTab()
    {
        WrapPending = false;
        int x = CursorX + 1;
        while (x < Cols - 1 && !_tabStops[x])
            x++;
        CursorX = Math.Min(x, Cols - 1);
    }

    private void BackTab()
    {
        WrapPending = false;
        int x = CursorX - 1;
        while (x > 0 && !_tabStops[x])
            x--;
        CursorX = Math.Max(x, 0);
    }

    private void CarriageReturn()
    {
        CursorX = 0;
        WrapPending = false;
    }

    private void LineFeed() => Index();

    private void Index()
    {
        WrapPending = false;
        if (CursorY == _regionBottom)
            _active.ScrollUp(_regionTop, _regionBottom, 1, MakeEraseCell());
        else if (CursorY < Rows - 1)
            CursorY++;
    }

    private void ReverseIndex()
    {
        WrapPending = false;
        if (CursorY == _regionTop)
            _active.ScrollDown(_regionTop, _regionBottom, 1, MakeEraseCell());
        else if (CursorY > 0)
            CursorY--;
    }

    private void MoveCursor(int dx, int dy)
    {
        WrapPending = false;
        if (dx != 0)
            CursorX = Math.Clamp(CursorX + dx, 0, Cols - 1);
        if (dy != 0)
        {
            // Movement is confined to the scroll region when starting inside it.
            int top = CursorY >= _regionTop ? _regionTop : 0;
            int bottom = CursorY <= _regionBottom ? _regionBottom : Rows - 1;
            CursorY = Math.Clamp(CursorY + dy, top, bottom);
        }
    }

    private void SetCursorColumn(int col)
    {
        WrapPending = false;
        CursorX = Math.Clamp(col, 0, Cols - 1);
    }

    private void SetCursorRow(int row)
    {
        WrapPending = false;
        if (_originMode)
            row += _regionTop;
        CursorY = Math.Clamp(row, 0, Rows - 1);
    }

    private void SetCursorPosition(int col, int row)
    {
        WrapPending = false;
        if (_originMode)
        {
            row = Math.Clamp(row + _regionTop, _regionTop, _regionBottom);
        }
        else
        {
            row = Math.Clamp(row, 0, Rows - 1);
        }
        CursorY = row;
        CursorX = Math.Clamp(col, 0, Cols - 1);
    }

    private int CursorRowForReport() =>
        _originMode ? CursorY - _regionTop + 1 : CursorY + 1;

    private void SaveCursor()
    {
        ref var slot = ref (_active == _main ? ref _savedMain : ref _savedAlt);
        slot = new SavedCursor
        {
            X = CursorX,
            Y = CursorY,
            Fg = _fg,
            Bg = _bg,
            Flags = _flags,
            G0 = _g0,
            G1 = _g1,
            ActiveCharset = _activeCharset,
            OriginMode = _originMode,
            AutoWrap = _autoWrap,
        };
    }

    private void RestoreCursor()
    {
        var slot = _active == _main ? _savedMain : _savedAlt;
        CursorX = Math.Clamp(slot.X, 0, Cols - 1);
        CursorY = Math.Clamp(slot.Y, 0, Rows - 1);
        _fg = slot.Fg;
        _bg = slot.Bg;
        _flags = slot.Flags;
        _g0 = slot.G0 == '\0' ? 'B' : slot.G0;
        _g1 = slot.G1 == '\0' ? 'B' : slot.G1;
        _activeCharset = slot.ActiveCharset;
        _originMode = slot.OriginMode;
        WrapPending = false;
    }

    // ---------------------------------------------------------------- erasing & editing

    private Cell MakeEraseCell() => new() { Rune = 0, Fg = _fg, Bg = _bg, Flags = CellFlags.None };

    private void EraseInDisplay(int mode)
    {
        var fill = MakeEraseCell();
        switch (mode)
        {
            case 0:
                EraseInLine(0);
                for (int y = CursorY + 1; y < Rows; y++)
                    _active.GetScreenLine(y).Fill(fill);
                break;
            case 1:
                EraseInLine(1);
                for (int y = 0; y < CursorY; y++)
                    _active.GetScreenLine(y).Fill(fill);
                break;
            case 2:
                _active.ClearScreen(fill);
                break;
            case 3:
                _active.ClearScrollback();
                break;
        }
    }

    private void EraseInLine(int mode)
    {
        var line = _active.GetScreenLine(CursorY);
        var fill = MakeEraseCell();
        switch (mode)
        {
            case 0: line.FillRange(CursorX, Cols, fill); break;
            case 1: line.FillRange(0, CursorX + 1, fill); break;
            case 2: line.Fill(fill); break;
        }
    }

    private void EraseCharacters(int count)
    {
        var line = _active.GetScreenLine(CursorY);
        line.FillRange(CursorX, CursorX + count, MakeEraseCell());
    }

    private void InsertCharacters(int count)
    {
        var line = _active.GetScreenLine(CursorY);
        var cells = line.Cells;
        int limit = Math.Min(Cols, cells.Length);
        count = Math.Min(count, limit - CursorX);
        for (int i = limit - 1; i >= CursorX + count; i--)
            cells[i] = cells[i - count];
        line.FillRange(CursorX, CursorX + count, MakeEraseCell());
    }

    private void DeleteCharacters(int count)
    {
        var line = _active.GetScreenLine(CursorY);
        var cells = line.Cells;
        int limit = Math.Min(Cols, cells.Length);
        count = Math.Min(count, limit - CursorX);
        for (int i = CursorX; i < limit - count; i++)
            cells[i] = cells[i + count];
        line.FillRange(limit - count, limit, MakeEraseCell());
    }

    private void InsertLines(int count)
    {
        if (CursorY < _regionTop || CursorY > _regionBottom)
            return;
        _active.ScrollDown(CursorY, _regionBottom, count, MakeEraseCell());
        CursorX = 0;
        WrapPending = false;
    }

    private void DeleteLines(int count)
    {
        if (CursorY < _regionTop || CursorY > _regionBottom)
            return;
        _active.ScrollUp(CursorY, _regionBottom, count, MakeEraseCell());
        CursorX = 0;
        WrapPending = false;
    }

    private void ScrollRegion(int count, bool up)
    {
        if (up)
            _active.ScrollUp(_regionTop, _regionBottom, count, MakeEraseCell());
        else
            _active.ScrollDown(_regionTop, _regionBottom, count, MakeEraseCell());
    }

    private void SetScrollRegion(int top1Based, int bottom1Based)
    {
        int top = top1Based <= 0 ? 0 : top1Based - 1;
        int bottom = bottom1Based <= 0 ? Rows - 1 : bottom1Based - 1;
        if (bottom <= top || top >= Rows)
            return;
        _regionTop = top;
        _regionBottom = Math.Min(bottom, Rows - 1);
        SetCursorPosition(0, 0);
    }

    private void ScreenAlignmentPattern()
    {
        var fill = new Cell { Rune = 'E', Fg = TerminalColor.Default, Bg = TerminalColor.Default };
        for (int y = 0; y < Rows; y++)
            _active.GetScreenLine(y).Fill(fill);
        _regionTop = 0;
        _regionBottom = Rows - 1;
        CursorX = 0;
        CursorY = 0;
    }

    // ---------------------------------------------------------------- modes

    private void SetAnsiModes(IReadOnlyList<int[]> parameters, bool set)
    {
        foreach (var group in parameters)
        {
            if (group.Length == 0)
                continue;
            switch (group[0])
            {
                case 4: _insertMode = set; break;
                case 20: _lineFeedMode = set; break;
            }
        }
    }

    private void SetPrivateModes(IReadOnlyList<int[]> parameters, bool set)
    {
        foreach (var group in parameters)
        {
            if (group.Length == 0)
                continue;
            switch (group[0])
            {
                case 1: ApplicationCursorKeys = set; break;
                case 3: break; // DECCOLM ignored (no 80/132 switching)
                case 6:
                    _originMode = set;
                    SetCursorPosition(0, 0);
                    break;
                case 7: _autoWrap = set; break;
                case 12: break; // cursor blink - always blinking
                case 25: CursorVisible = set; break;
                case 47:
                case 1047:
                    if (set) EnterAlternateBuffer(clear: group[0] == 1047);
                    else LeaveAlternateBuffer(clear: group[0] == 1047);
                    break;
                case 1048:
                    if (set) SaveCursor();
                    else RestoreCursor();
                    break;
                case 1049:
                    if (set)
                    {
                        SaveCursor();
                        EnterAlternateBuffer(clear: true);
                        SetCursorPosition(0, 0);
                    }
                    else
                    {
                        LeaveAlternateBuffer(clear: false);
                        RestoreCursor();
                    }
                    break;
                case 1000:
                case 1002:
                case 1003:
                    _mouseMode = set ? group[0] : 0;
                    break;
                case 1004: FocusEvents = set; break;
                case 1006: break; // SGR mouse encoding, accepted silently
                case 2004: BracketedPaste = set; break;
            }
        }
    }

    private void EnterAlternateBuffer(bool clear)
    {
        if (_active == _alt)
            return;
        _active = _alt;
        if (clear)
            _alt.ClearScreen(MakeEraseCell());
        _regionTop = 0;
        _regionBottom = Rows - 1;
        WrapPending = false;
    }

    private void LeaveAlternateBuffer(bool clear)
    {
        if (_active == _main)
            return;
        if (clear)
            _alt.ClearScreen(MakeEraseCell());
        _active = _main;
        _regionTop = 0;
        _regionBottom = Rows - 1;
        WrapPending = false;
    }

    // ---------------------------------------------------------------- SGR

    private void SelectGraphicRendition(IReadOnlyList<int[]> parameters)
    {
        if (parameters.Count == 0)
        {
            ResetAttributes();
            return;
        }

        for (int i = 0; i < parameters.Count; i++)
        {
            var group = parameters[i];
            int code = group.Length > 0 ? group[0] : 0;
            switch (code)
            {
                case 0: ResetAttributes(); break;
                case 1: _flags |= CellFlags.Bold; break;
                case 2: _flags |= CellFlags.Dim; break;
                case 3: _flags |= CellFlags.Italic; break;
                case 4:
                    if (group.Length > 1 && group[1] == 0)
                        _flags &= ~(CellFlags.Underline | CellFlags.DoubleUnderline);
                    else
                        _flags |= CellFlags.Underline;
                    break;
                case 5:
                case 6: _flags |= CellFlags.Blink; break;
                case 7: _flags |= CellFlags.Inverse; break;
                case 8: _flags |= CellFlags.Hidden; break;
                case 9: _flags |= CellFlags.Strikethrough; break;
                case 21: _flags |= CellFlags.DoubleUnderline; break;
                case 22: _flags &= ~(CellFlags.Bold | CellFlags.Dim); break;
                case 23: _flags &= ~CellFlags.Italic; break;
                case 24: _flags &= ~(CellFlags.Underline | CellFlags.DoubleUnderline); break;
                case 25: _flags &= ~CellFlags.Blink; break;
                case 27: _flags &= ~CellFlags.Inverse; break;
                case 28: _flags &= ~CellFlags.Hidden; break;
                case 29: _flags &= ~CellFlags.Strikethrough; break;
                case >= 30 and <= 37: _fg = TerminalColor.Indexed(code - 30); break;
                case 38: _fg = ParseExtendedColor(parameters, ref i) ?? _fg; break;
                case 39: _fg = TerminalColor.Default; break;
                case >= 40 and <= 47: _bg = TerminalColor.Indexed(code - 40); break;
                case 48: _bg = ParseExtendedColor(parameters, ref i) ?? _bg; break;
                case 49: _bg = TerminalColor.Default; break;
                case >= 90 and <= 97: _fg = TerminalColor.Indexed(code - 90 + 8); break;
                case >= 100 and <= 107: _bg = TerminalColor.Indexed(code - 100 + 8); break;
            }
        }
    }

    /// <summary>
    /// Parses SGR 38/48 extended colors in both forms:
    /// semicolon (38;5;n / 38;2;r;g;b - values in following groups) and
    /// colon (38:5:n / 38:2::r:g:b - values as subparameters of one group).
    /// </summary>
    private static TerminalColor? ParseExtendedColor(IReadOnlyList<int[]> parameters, ref int i)
    {
        var group = parameters[i];
        if (group.Length > 1)
        {
            // Colon form: everything is inside this group.
            int mode = group[1];
            if (mode == 5 && group.Length >= 3)
                return TerminalColor.Indexed(group[2]);
            if (mode == 2)
            {
                // 38:2:r:g:b or 38:2:colorspace:r:g:b
                if (group.Length >= 6)
                    return TerminalColor.Rgb(group[3], group[4], group[5]);
                if (group.Length >= 5)
                    return TerminalColor.Rgb(group[2], group[3], group[4]);
            }
            return null;
        }

        // Semicolon form: consume following groups.
        if (i + 1 >= parameters.Count)
            return null;
        int m = parameters[i + 1].Length > 0 ? parameters[i + 1][0] : 0;
        if (m == 5 && i + 2 < parameters.Count)
        {
            int idx = parameters[i + 2].Length > 0 ? parameters[i + 2][0] : 0;
            i += 2;
            return TerminalColor.Indexed(idx);
        }
        if (m == 2 && i + 4 < parameters.Count)
        {
            int r = parameters[i + 2].Length > 0 ? parameters[i + 2][0] : 0;
            int g = parameters[i + 3].Length > 0 ? parameters[i + 3][0] : 0;
            int b = parameters[i + 4].Length > 0 ? parameters[i + 4][0] : 0;
            i += 4;
            return TerminalColor.Rgb(r, g, b);
        }
        return null;
    }

    private void ResetAttributes()
    {
        _fg = TerminalColor.Default;
        _bg = TerminalColor.Default;
        _flags = CellFlags.None;
    }

    // ---------------------------------------------------------------- reset & misc

    private void FullReset()
    {
        ResetAttributes();
        _active = _main;
        _main.ClearScreen(default);
        _alt.ClearScreen(default);
        CursorX = 0;
        CursorY = 0;
        CursorVisible = true;
        CursorStyle = 0;
        WrapPending = false;
        _regionTop = 0;
        _regionBottom = Rows - 1;
        _originMode = false;
        _autoWrap = true;
        _insertMode = false;
        _lineFeedMode = false;
        ApplicationCursorKeys = false;
        ApplicationKeypad = false;
        BracketedPaste = false;
        FocusEvents = false;
        _mouseMode = 0;
        _g0 = 'B';
        _g1 = 'B';
        _activeCharset = 0;
        _tabStops = BuildTabStops(Cols);
        _savedMain = default;
        _savedAlt = default;
    }

    private static bool[] BuildTabStops(int cols)
    {
        var stops = new bool[cols];
        for (int i = 8; i < cols; i += 8)
            stops[i] = true;
        return stops;
    }

    private void Respond(string sequence) => ResponseRequested?.Invoke(sequence);
}
