namespace Zharp.Core.Terminal;

/// <summary>
/// A grid of cells with optional scrollback. The emulator owns two of these
/// (main + alternate screen) and drives all mutations.
/// </summary>
public sealed class ScreenBuffer
{
    private readonly List<TerminalLine> _screen = new();
    private readonly List<TerminalLine> _scrollback = new();
    private readonly int _maxScrollback;

    public int Rows { get; private set; }
    public int Cols { get; private set; }
    public bool HasScrollback => _maxScrollback > 0;
    public int ScrollbackCount => _scrollback.Count;
    public int TotalLines => _scrollback.Count + Rows;

    /// <summary>Scrollback lines ever dropped (trim or clear). Absolute line
    /// marks recorded as DroppedLines + index stay valid across drops.</summary>
    public long DroppedLines { get; private set; }

    public ScreenBuffer(int cols, int rows, int maxScrollback)
    {
        Cols = Math.Max(1, cols);
        Rows = Math.Max(1, rows);
        _maxScrollback = maxScrollback;
        for (int i = 0; i < Rows; i++)
            _screen.Add(new TerminalLine(Cols));
    }

    /// <summary>Gets a line by screen row (0 = top of visible screen).</summary>
    public TerminalLine GetScreenLine(int row) => _screen[row];

    /// <summary>Gets a line by absolute index (0 = oldest scrollback line).</summary>
    public TerminalLine GetAbsoluteLine(int index) =>
        index < _scrollback.Count ? _scrollback[index] : _screen[index - _scrollback.Count];

    /// <summary>
    /// Scrolls lines [top, bottom] up by n. When the region starts at the top of a
    /// buffer with scrollback and spans the full height, evicted lines are preserved.
    /// </summary>
    public void ScrollUp(int top, int bottom, int n, in Cell fill)
    {
        n = Math.Clamp(n, 0, bottom - top + 1);
        bool capture = top == 0 && bottom == Rows - 1 && HasScrollback;
        for (int i = 0; i < n; i++)
        {
            var line = _screen[top];
            _screen.RemoveAt(top);
            if (capture)
            {
                _scrollback.Add(line);
                _screen.Insert(bottom, new TerminalLine(Cols, fill));
            }
            else
            {
                line.Fill(fill);
                _screen.Insert(bottom, line);
            }
        }
        TrimScrollback();
    }

    public void ScrollDown(int top, int bottom, int n, in Cell fill)
    {
        n = Math.Clamp(n, 0, bottom - top + 1);
        for (int i = 0; i < n; i++)
        {
            var line = _screen[bottom];
            _screen.RemoveAt(bottom);
            line.Fill(fill);
            _screen.Insert(top, line);
        }
    }

    public void ClearScreen(in Cell fill)
    {
        foreach (var line in _screen)
            line.Fill(fill);
    }

    public void ClearScrollback()
    {
        DroppedLines += _scrollback.Count;
        _scrollback.Clear();
    }

    /// <summary>
    /// Resizes the buffer. Shrinking prefers dropping blank lines below the cursor,
    /// then pushes top lines into scrollback; growing pulls lines back out.
    /// No text reflow (matches classic conhost behavior).
    /// </summary>
    public void Resize(int newCols, int newRows, ref int cursorY)
    {
        newCols = Math.Max(1, newCols);
        newRows = Math.Max(1, newRows);

        if (newCols != Cols)
        {
            foreach (var line in _screen)
                line.Resize(newCols);
            Cols = newCols;
        }

        if (newRows < Rows)
        {
            int excess = Rows - newRows;
            // Drop trailing blank lines first so a shell prompt stays put.
            while (excess > 0 && _screen.Count - 1 > cursorY && _screen[^1].IsEmpty())
            {
                _screen.RemoveAt(_screen.Count - 1);
                excess--;
            }
            while (excess > 0)
            {
                var line = _screen[0];
                _screen.RemoveAt(0);
                if (HasScrollback)
                    _scrollback.Add(line);
                if (cursorY > 0)
                    cursorY--;
                excess--;
            }
            TrimScrollback();
        }
        else if (newRows > Rows)
        {
            int need = newRows - Rows;
            while (need > 0 && _scrollback.Count > 0)
            {
                var line = _scrollback[^1];
                _scrollback.RemoveAt(_scrollback.Count - 1);
                line.Resize(newCols);
                _screen.Insert(0, line);
                cursorY++;
                need--;
            }
            while (need > 0)
            {
                _screen.Add(new TerminalLine(newCols));
                need--;
            }
        }

        Rows = newRows;
        cursorY = Math.Clamp(cursorY, 0, Rows - 1);
    }

    private void TrimScrollback()
    {
        // Trim in chunks to amortize the list shift.
        if (_scrollback.Count > _maxScrollback + 256)
        {
            int drop = _scrollback.Count - _maxScrollback;
            _scrollback.RemoveRange(0, drop);
            DroppedLines += drop;
        }
    }
}
