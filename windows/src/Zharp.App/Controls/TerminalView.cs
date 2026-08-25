using System.Text;
using System.Text.RegularExpressions;
using Microsoft.Graphics.Canvas.Text;
using Microsoft.Graphics.Canvas.UI.Xaml;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Windows.ApplicationModel.DataTransfer;
using Windows.Foundation;
using Windows.System;
using Windows.UI;
using Zharp.Core.Terminal;

namespace Zharp.App.Controls;

/// <summary>
/// The terminal surface: renders a <see cref="TerminalSession"/>'s screen with
/// Win2D and translates keyboard/mouse input into VT sequences.
/// </summary>
public sealed class TerminalView : UserControl, IDisposable
{
    private const string DefaultFontFamily = "Cascadia Mono";
    private const float PaddingPx = 8f;
    private const double MinFontSize = 7;
    private const double MaxFontSize = 36;
    private const double DefaultFontSize = 13;

    private readonly TerminalSession _session;
    private readonly CanvasControl _canvas;
    private Palette _palette = Palette.Campbell();
    private readonly StringBuilder _runText = new(256);

    private readonly CanvasTextFormat?[] _formats = new CanvasTextFormat?[4];
    private float _cellWidth;
    private float _cellHeight;
    private double _fontSize = DefaultFontSize;
    private string _fontFamily = DefaultFontFamily;

    /// <summary>
    /// DECSCUSR-style code used when the application hasn't chosen a cursor:
    /// 0 block, 3 underline, 5 bar.
    /// </summary>
    public int DefaultCursorStyleCode { get; set; }

    /// <summary>
    /// Returns true for key combos reserved as app shortcuts. Those must be left
    /// unhandled here so the window's accelerators (which only fire on unhandled
    /// input) receive them instead of the shell.
    /// </summary>
    public Func<int, InputModifiers, bool>? IsReservedShortcut { get; set; }

    /// <summary>Maps a key combo to a rebindable block action id (blockPrev,
    /// blockNext, copyOutput, findInBlock), or null when unbound.</summary>
    public Func<int, InputModifiers, string?>? ResolveBlockShortcut { get; set; }

    /// <summary>The user's current binding text for an action id (menu labels).</summary>
    public Func<string, string>? BlockShortcutText { get; set; }

    private int _cols = 120;
    private int _rows = 30;
    private int _scrollOffset;
    private int _inputPosition; // 0 = classic top, 1 = pinned bottom, 2 = pinned top (blocks)
    private int _alignPad;      // rows the content is shifted down (bottom mode)
    private float _pinScrollPx; // pinned-top: scroll position within the block stack
    private readonly List<(int Start, int Count, float TopPx)> _blockLayout = new();

    // Collapsed blocks, keyed by drop-stable line (absolute + DroppedLines) so
    // entries stay valid while scrollback trims.
    private readonly HashSet<long> _collapsed = new();

    // Selected (highlighted) block + the hover "..." chip, same stable keys.
    private long _selectedBlockKey = -1;
    private long _hoverChipKey = -1;
    private Button _chip = null!;

    // Find-within-block overlay state. Matches store drop-stable lines; the
    // abs-keyed lookup (_findByLine) is rebuilt when DroppedLines moves.
    private Border _findPanel = null!;
    private TextBox _findBox = null!;
    private ToggleButton _findCaseBtn = null!;
    private ToggleButton _findRegexBtn = null!;
    private TextBlock _findCount = null!;
    private bool _findFocused;
    private long _findKey = -1;
    private readonly List<(long RawLine, int From, int To)> _findMatches = new();
    private int _findIndex = -1;
    private Dictionary<int, List<(int From, int To, bool Current)>>? _findByLine;
    private long _findByLineDropped = -1;

    // Overlay chrome brushes, recolored on every SetPalette so the chip and
    // find bar match whatever terminal theme is active.
    private readonly SolidColorBrush _overlayBg = new();        // panel / chip surface
    private readonly SolidColorBrush _overlayBgHover = new();   // opaque hover (chip)
    private readonly SolidColorBrush _overlayBgActive = new();  // opaque pressed (chip)
    private readonly SolidColorBrush _overlayInputBg = new();   // text field inset
    private readonly SolidColorBrush _overlayHover = new();     // translucent hover (panel buttons)
    private readonly SolidColorBrush _overlayActive = new();    // translucent pressed
    private readonly SolidColorBrush _overlayAccent = new();    // checked toggle / selection
    private readonly SolidColorBrush _overlayBorder = new();
    private readonly SolidColorBrush _overlayFg = new();
    private readonly SolidColorBrush _overlayFgDim = new();
    private static readonly SolidColorBrush TransparentBrush = new(Microsoft.UI.Colors.Transparent);

    /// <summary>Input position: 0 classic top, 1 pinned bottom, 2 pinned top.</summary>
    public void SetInputPosition(int mode)
    {
        if (_inputPosition == mode)
            return;
        _inputPosition = mode;
        DismissHistoryOverlay();
        _pinScrollPx = 0;
        if (_scrollOffset < 0)
            _scrollOffset = 0;
        _canvas.Invalidate();
    }
    private int _lastScrollbackCount;
    private int _invalidatePending;

    private bool _cursorBlinkOn = true;
    private bool _hasFocus;
    private Microsoft.UI.Dispatching.DispatcherQueueTimer? _blinkTimer;

    private bool _selecting;
    private bool _hasSelection;
    private (int Line, int Col) _selAnchor;
    private (int Line, int Col) _selFocus;

    private char _pendingHighSurrogate;
    private bool _disposed;

    // Per-row scratch buffers, sized to the column count.
    private uint[] _fgRow = [];
    private uint[] _bgRow = [];
    private bool[] _bgDefaultRow = [];

    public TerminalView(TerminalSession session, double fontSize = DefaultFontSize, string? fontFamily = null)
    {
        _session = session;
        _fontSize = Math.Clamp(fontSize, MinFontSize, MaxFontSize);
        if (!string.IsNullOrWhiteSpace(fontFamily))
            _fontFamily = fontFamily;

        IsTabStop = true;
        UseSystemFocusVisuals = false;
        AllowFocusOnInteraction = true;

        _canvas = new CanvasControl { ClearColor = Microsoft.UI.Colors.Transparent };
        UpdateOverlayBrushes();
        _chip = BuildChip();
        _findPanel = BuildFindPanel();
        _historyPanel = BuildHistoryPanel();
        var root = new Grid();
        root.Children.Add(_canvas);
        root.Children.Add(_chip);
        root.Children.Add(_findPanel);
        root.Children.Add(_historyPanel);
        Content = root;
        UpdateOverlayBrushes(); // now that chip/panel exist, apply their theme
        PointerExited += (_, _) => HideChip();

        _canvas.CreateResources += (_, _) => RebuildTypography();
        _canvas.Draw += OnDraw;

        SizeChanged += (_, _) => { UpdateGridSize(); RepositionHistoryOverlay(); };
        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
        GotFocus += OnGotFocus;
        LostFocus += OnLostFocus;
        CharacterReceived += OnCharacterReceived;

        PointerPressed += OnPointerPressed;
        PointerMoved += OnPointerMoved;
        PointerReleased += OnPointerReleased;
        PointerWheelChanged += OnPointerWheelChanged;

        _session.OutputArrived += OnOutputArrived;

        // Whether a program is running in the foreground. Set when a command is
        // submitted, cleared when the shell draws its next prompt.
        _session.CommandExecuted += _ => _foregroundBusy = true;
        _session.PromptReturned += () => _foregroundBusy = false;
    }

    /// <summary>
    /// True between a command being submitted and the shell prompting again.
    ///
    /// The prompt marks alone cannot tell: a full screen program that does not
    /// take the alternate buffer, which is most of the agent CLIs, leaves the
    /// last prompt's marks sitting there looking live while it paints over the
    /// screen. Arrow Up then opened Zharp's history on top of a running Codex
    /// instead of reaching Codex's own menu.
    ///
    /// Written on the pty thread and read on the UI thread. A stale read is
    /// worth nothing more than one keystroke going the wrong way, which is why
    /// this is a volatile bool rather than a lock on the input path.
    /// </summary>
    private volatile bool _foregroundBusy;

    public TerminalSession Session => _session;

    public void FocusTerminal() => Focus(FocusState.Programmatic);

    // ---------------------------------------------------------------- lifecycle

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        if (_blinkTimer == null)
        {
            _blinkTimer = DispatcherQueue.CreateTimer();
            _blinkTimer.Interval = TimeSpan.FromMilliseconds(530);
            _blinkTimer.Tick += (_, _) =>
            {
                if (_hasFocus)
                {
                    _cursorBlinkOn = !_cursorBlinkOn;
                    _canvas.Invalidate();
                }
            };
        }
        _blinkTimer.Start();
        UpdateGridSize();
        FocusTerminal();
    }

    private void OnUnloaded(object sender, RoutedEventArgs e) => _blinkTimer?.Stop();

    public void Dispose()
    {
        if (_disposed)
            return;
        _disposed = true;
        _session.OutputArrived -= OnOutputArrived;
        _blinkTimer?.Stop();
        _canvas.RemoveFromVisualTree();
    }

    // ---------------------------------------------------------------- typography & layout

    private void RebuildTypography()
    {
        for (int i = 0; i < 4; i++)
        {
            _formats[i] = new CanvasTextFormat
            {
                FontFamily = _fontFamily,
                FontSize = (float)(_fontSize * _uiZoom),
                WordWrapping = CanvasWordWrapping.NoWrap,
                HorizontalAlignment = CanvasHorizontalAlignment.Left,
                VerticalAlignment = CanvasVerticalAlignment.Top,
                FontWeight = (i & 1) != 0 ? Microsoft.UI.Text.FontWeights.SemiBold : Microsoft.UI.Text.FontWeights.Normal,
                FontStyle = (i & 2) != 0 ? Windows.UI.Text.FontStyle.Italic : Windows.UI.Text.FontStyle.Normal,
            };
        }

        using var layout = new CanvasTextLayout(_canvas, "0000000000", _formats[0], 0, 0);
        _cellWidth = (float)(layout.LayoutBounds.Width / 10.0);
        _cellHeight = (float)Math.Ceiling(layout.LayoutBounds.Height);
        float baseline = layout.LineMetrics.Length > 0
            ? layout.LineMetrics[0].Baseline
            : _cellHeight * 0.78f;

        foreach (var format in _formats)
        {
            format!.LineSpacing = _cellHeight;
            format.LineSpacingBaseline = baseline;
        }

        UpdateGridSize();
    }

    private CanvasTextFormat PickFormat(CellFlags flags)
    {
        int index = ((flags & CellFlags.Bold) != 0 ? 1 : 0) | ((flags & CellFlags.Italic) != 0 ? 2 : 0);
        return _formats[index] ?? _formats[0]!;
    }

    private void UpdateGridSize()
    {
        if (_cellWidth <= 0 || ActualWidth <= 0 || ActualHeight <= 0)
            return;

        double w = ActualWidth - 2 * PaddingPx;
        double h = ActualHeight - 2 * PaddingPx;
        int cols = Math.Max(2, (int)(w / _cellWidth));
        int rows = Math.Max(2, (int)(h / _cellHeight));

        if (!_session.IsStarted)
        {
            _cols = cols;
            _rows = rows;
            _session.EnsureStarted(cols, rows);
        }
        else if (cols != _cols || rows != _rows)
        {
            _cols = cols;
            _rows = rows;
            _session.Resize(cols, rows);
        }
        _canvas.Invalidate();
    }

    /// <summary>Swaps the color scheme (theme change) and repaints.</summary>
    public void SetPalette(Palette palette)
    {
        _palette = palette;
        UpdateOverlayBrushes();
        _canvas.Invalidate();
    }

    /// <summary>Overlay chrome (chip / find panel) recolored from the palette.</summary>
    private void UpdateOverlayBrushes()
    {
        uint bg = _palette.DefaultBackground;
        uint fg = _palette.DefaultForeground;
        _overlayBg.Color = Blend(bg, fg, 0.07, 0xFA);
        _overlayBgHover.Color = Blend(bg, fg, 0.15, 0xFA);
        _overlayBgActive.Color = Blend(bg, fg, 0.22, 0xFA);
        _overlayInputBg.Color = Blend(bg, fg, 0.13, 0xFF);
        _overlayHover.Color = FromRgb(fg, 0x17);
        _overlayActive.Color = FromRgb(fg, 0x26);
        _overlayAccent.Color = FromRgb(_palette.CursorColor, 0x59);
        _overlayBorder.Color = FromRgb(fg, 0x2A);
        _overlayFg.Color = FromRgb(fg, 0xE6);
        _overlayFgDim.Color = FromRgb(fg, 0x78);

        // Built-in control visuals (focus rings, caret, tooltips, and every
        // flyout opened from this view - chip menu and right-click menu alike)
        // should follow the terminal palette, not the app chrome theme.
        double lum = (0.299 * ((bg >> 16) & 0xFF) + 0.587 * ((bg >> 8) & 0xFF) + 0.114 * (bg & 0xFF)) / 255.0;
        RequestedTheme = lum < 0.5 ? ElementTheme.Dark : ElementTheme.Light;
    }

    private static Color Blend(uint baseRgb, uint overRgb, double t, byte alpha)
    {
        byte Mix(int shift) => (byte)((1 - t) * ((baseRgb >> shift) & 0xFF) + t * ((overRgb >> shift) & 0xFF));
        return Color.FromArgb(alpha, Mix(16), Mix(8), Mix(0));
    }

    private double _uiZoom = 1.0;

    /// <summary>
    /// Whole-UI zoom factor. This view lives in an untransformed overlay layer
    /// sized in physical pixels; the zoom is realized purely by scaling the font
    /// size - text is freshly rasterized, never bitmap-stretched.
    /// </summary>
    public void SetUiZoom(double zoom)
    {
        zoom = Math.Clamp(zoom, 0.5, 3.0);
        if (Math.Abs(_uiZoom - zoom) < 0.001)
            return;
        _uiZoom = zoom;
        if (_canvas.ReadyToDraw)
            RebuildTypography();
        RepositionHistoryOverlay();
    }

    /// <summary>Applies appearance settings live (font family/size, default cursor).</summary>
    public void ApplyAppearance(string? fontFamily, double fontSize, int cursorStyleCode)
    {
        DefaultCursorStyleCode = cursorStyleCode;
        if (!string.IsNullOrWhiteSpace(fontFamily))
            _fontFamily = fontFamily;
        _fontSize = Math.Clamp(fontSize, MinFontSize, MaxFontSize);
        if (_canvas.ReadyToDraw)
            RebuildTypography();
        else
            _canvas.Invalidate();
        RepositionHistoryOverlay();
    }

    private void ChangeFontSize(double delta)
    {
        double next = Math.Clamp(delta == 0 ? DefaultFontSize : _fontSize + delta, MinFontSize, MaxFontSize);
        if (Math.Abs(next - _fontSize) < 0.1)
            return;
        _fontSize = next;
        if (_canvas.ReadyToDraw)
            RebuildTypography();
        // Ctrl+wheel moves the input bar (cell height changes) - keep an open
        // history panel docked to it.
        RepositionHistoryOverlay();
    }

    // ---------------------------------------------------------------- output pump

    /// <summary>
    /// How long a program may hold the screen mid frame before it is shown
    /// anyway. Only reached by a program that set synchronized output and then
    /// died or stalled; a frozen terminal is worse than a torn frame.
    /// </summary>
    private const int MaxHoldMs = 120;

    private long _holdingSince;

    private void OnOutputArrived()
    {
        // Mid frame: the program has said it is still painting. Showing this
        // would be showing a cleared screen, or half a redraw, which is what
        // flickering is made of. The sequence that ends the frame is itself
        // output, so it brings us straight back here to paint the whole thing.
        var emulator = _session.Emulator;
        bool holding;
        lock (emulator.SyncRoot)
            holding = emulator.SynchronizedOutput;

        if (holding)
        {
            long now = Environment.TickCount64;
            if (_holdingSince == 0)
                _holdingSince = now;
            if (now - _holdingSince < MaxHoldMs)
                return;
        }
        _holdingSince = 0;

        if (Interlocked.CompareExchange(ref _invalidatePending, 1, 0) == 0)
        {
            DispatcherQueue.TryEnqueue(() =>
            {
                Interlocked.Exchange(ref _invalidatePending, 0);
                _canvas.Invalidate();
            });
        }
    }

    // ---------------------------------------------------------------- rendering

    private void OnDraw(CanvasControl sender, CanvasDrawEventArgs args)
    {
        var ds = args.DrawingSession;
        // Fully transparent surface: the chrome wash behind (same color as the
        // palette background by design) is the single translucency layer, so
        // the opacity slider and Acrylic blur work without double-covering.
        ds.Clear(Windows.UI.Color.FromArgb(0, 0, 0, 0));

        if (_cellWidth <= 0)
            return;

        var emu = _session.Emulator;
        lock (emu.SyncRoot)
        {
            int rows = emu.Rows;
            int cols = emu.Cols;
            var buffer = emu.Buffer;
            int scrollback = buffer.ScrollbackCount;

            if (emu.IsAlternateBuffer)
            {
                _scrollOffset = 0;
            }
            else
            {
                // Keep the viewport pinned to content while scrolled up.
                if (_scrollOffset > 0 && scrollback > _lastScrollbackCount)
                    _scrollOffset += scrollback - _lastScrollbackCount;
                _scrollOffset = Math.Clamp(_scrollOffset, 0, scrollback);
            }
            _lastScrollbackCount = scrollback;

            // Find-within-block: refresh the abs-keyed match lookup whenever
            // scrollback trimming has shifted absolute line numbers.
            if (_findMatches.Count > 0)
            {
                long droppedNow = buffer.DroppedLines;
                if (_findByLine == null || _findByLineDropped != droppedNow)
                {
                    _findByLine = new Dictionary<int, List<(int, int, bool)>>();
                    _findByLineDropped = droppedNow;
                    for (int i = 0; i < _findMatches.Count; i++)
                    {
                        var m = _findMatches[i];
                        int abs = (int)(m.RawLine - droppedNow);
                        if (abs < 0)
                            continue;
                        if (!_findByLine.TryGetValue(abs, out var list))
                            _findByLine[abs] = list = new List<(int, int, bool)>();
                        list.Add((m.From, m.To, i == _findIndex));
                    }
                }
            }
            else
            {
                _findByLine = null;
            }

            if (_fgRow.Length < cols)
            {
                _fgRow = new uint[cols];
                _bgRow = new uint[cols];
                _bgDefaultRow = new bool[cols];
            }

            var (selStart, selEnd) = NormalizedSelection();

            // Every input mode renders prompt-marked content as blocks:
            // pinned-top stacks newest-first, pinned-bottom is chronological
            // anchored to the bottom edge, classic is chronological flowing
            // from the top until content overflows (then it follows the
            // prompt, exactly like a traditional terminal).
            // Blocks are for the output of commands. A program painting the
            // whole screen decides what goes on every row itself, and laying
            // that out by command instead swallowed it: Codex's menus and
            // dialogs were parsed correctly and then never drawn, because the
            // block layout had no row to put them on. Most such programs take
            // the alternate buffer; the agent CLIs do not, which is why the
            // marks from the last real prompt were still being believed.
            if (!emu.IsAlternateBuffer && !emu.FullScreenPaint)
            {
                var marks = emu.GetPromptMarks();
                if (marks.Count > 0)
                {
                    _scrollOffset = 0;
                    DrawBlocks(ds, emu, buffer, rows, cols, selStart, selEnd, marks,
                        newestFirst: _inputPosition == 2);
                    return;
                }
            }
            _blockLayout.Clear();

            // Pinned-bottom fallback for shells without prompt marks: a short
            // screen bottom-aligns (main buffer only).
            _alignPad = 0;
            if (_inputPosition == 1 && !emu.IsAlternateBuffer && _scrollOffset == 0)
            {
                int used = emu.CursorY + 1;
                for (int r = rows - 1; r >= used; r--)
                {
                    if (!buffer.GetScreenLine(r).IsEmpty())
                    {
                        used = r + 1;
                        break;
                    }
                }
                _alignPad = rows - used;
            }

            // Linear fallback: shells without prompt marks (and the alternate
            // screen) render plain rows with no block chrome.
            int firstAbs = scrollback - _scrollOffset;

            for (int r = 0; r < rows; r++)
            {
                if (r + _alignPad >= rows)
                    break; // rows pushed off the bottom by the align pad are blank
                int abs = firstAbs + r;
                if (abs < 0 || abs >= buffer.TotalLines)
                    continue;
                DrawBufferLine(ds, buffer, abs, PaddingPx + (r + _alignPad) * _cellHeight,
                    cols, selStart, selEnd);
            }

            DrawCursor(ds, emu, buffer, scrollback, firstAbs, rows, cols);
        }
    }

    /// <summary>Draws one buffer line (backgrounds, selection, text) at y.</summary>
    private void DrawBufferLine(Microsoft.Graphics.Canvas.CanvasDrawingSession ds, ScreenBuffer buffer,
        int abs, float y, int cols, (int Line, int Col) selStart, (int Line, int Col) selEnd)
    {
        var line = buffer.GetAbsoluteLine(abs);
        var cells = line.Cells;
        int n = Math.Min(cols, cells.Length);

        for (int c = 0; c < n; c++)
            _palette.Resolve(in cells[c], out _fgRow[c], out _bgRow[c], out _bgDefaultRow[c]);

        // Background runs (only where it differs from the panel background).
        int runStart = -1;
        uint runBg = 0;
        for (int c = 0; c <= n; c++)
        {
            bool paint = c < n && !_bgDefaultRow[c];
            uint bg = paint ? _bgRow[c] : 0;
            if (runStart >= 0 && (!paint || bg != runBg))
            {
                ds.FillRectangle(PaddingPx + runStart * _cellWidth, y,
                    (c - runStart) * _cellWidth, _cellHeight, FromRgb(runBg));
                runStart = -1;
            }
            if (paint && runStart < 0)
            {
                runStart = c;
                runBg = bg;
            }
        }

        // Find-within-block match highlights (current match is stronger).
        if (_findByLine != null && _findByLine.TryGetValue(abs, out var found))
        {
            foreach (var (from, to, current) in found)
            {
                if (from >= cols)
                    continue;
                int last = Math.Min(to, cols - 1);
                ds.FillRectangle(PaddingPx + from * _cellWidth, y,
                    (last - from + 1) * _cellWidth, _cellHeight,
                    FromRgb(_palette.CursorColor, current ? (byte)0x8C : (byte)0x46));
            }
        }

        // Selection highlight.
        if (_hasSelection && abs >= selStart.Line && abs <= selEnd.Line)
        {
            int from = abs == selStart.Line ? selStart.Col : 0;
            int to = abs == selEnd.Line ? selEnd.Col : cols - 1;
            from = Math.Clamp(from, 0, cols - 1);
            to = Math.Clamp(to, 0, cols - 1);
            if (to >= from)
            {
                ds.FillRectangle(PaddingPx + from * _cellWidth, y,
                    (to - from + 1) * _cellWidth, _cellHeight,
                    FromRgb(_palette.SelectionColor, 0x46));
            }
        }

        DrawTextRuns(ds, cells, n, y);
    }

    /// <summary>
    /// Block rendering. Pinned-top: the live prompt block at the
    /// top, earlier blocks below newest-first. Pinned-bottom: chronological,
    /// the live prompt hugging the bottom edge. Hairlines divide blocks;
    /// wheel scrolls the stack, typing snaps back to the prompt.
    /// </summary>
    private void DrawBlocks(Microsoft.Graphics.Canvas.CanvasDrawingSession ds, TerminalEmulator emu,
        ScreenBuffer buffer, int rows, int cols, (int Line, int Col) selStart, (int Line, int Col) selEnd,
        List<int> marks, bool newestFirst)
    {
        int scrollback = buffer.ScrollbackCount;
        int contentEnd = scrollback + emu.CursorY; // the input line
        int cursorAbs = contentEnd;

        _blockLayout.Clear();

        var segments = new List<(int Start, int Count)>();
        if (newestFirst)
        {
            segments.Add((marks[^1], Math.Max(1, contentEnd - marks[^1] + 1)));
            for (int i = marks.Count - 2; i >= 0; i--)
                segments.Add((marks[i], Math.Max(1, marks[i + 1] - marks[i])));
            if (marks[0] > 0)
                segments.Add((0, marks[0]));
        }
        else
        {
            if (marks[0] > 0)
                segments.Add((0, marks[0]));
            for (int i = 0; i < marks.Count - 1; i++)
                segments.Add((marks[i], Math.Max(1, marks[i + 1] - marks[i])));
            segments.Add((marks[^1], Math.Max(1, contentEnd - marks[^1] + 1)));
        }

        float gap = _cellHeight * 0.7f;
        float viewContentH = rows * _cellHeight;
        float canvasH = (float)_canvas.ActualHeight;
        float viewH = Math.Max(PaddingPx + viewContentH, canvasH);

        // A collapsed block renders as its title line plus a "hidden" row.
        // The live block (holding the cursor) is never collapsible.
        long dropped = buffer.DroppedLines;
        var collapsed = new bool[segments.Count];
        var effRows = new int[segments.Count];
        int liveIdx = -1;
        for (int i = 0; i < segments.Count; i++)
        {
            var (start, count) = segments[i];
            if (cursorAbs >= start && cursorAbs < start + count)
            {
                liveIdx = i;
                break;
            }
        }
        // Stale marks can briefly leave the cursor outside every segment
        // (alt-screen roundtrips, shell redraws). The prompt block is by
        // construction the newest segment - never lose its input bar.
        if (liveIdx < 0)
            liveIdx = newestFirst ? 0 : segments.Count - 1;
        for (int i = 0; i < segments.Count; i++)
        {
            var (start, count) = segments[i];
            collapsed[i] = i != liveIdx && count > 1 && _collapsed.Contains(start + dropped);
            effRows[i] = collapsed[i] ? 2 : count;
        }

        // Pinned modes: the input block and its rule stay FIXED at the window
        // edge; only the history stack scrolls (clipped at the rule). Classic
        // keeps the traditional flow below, where the input scrolls away.
        if (_inputPosition != 0)
        {
            DrawPinnedStack(ds, emu, buffer, cols, selStart, selEnd, segments, collapsed, effRows,
                liveIdx, newestFirst, gap, dropped, canvasH, cursorAbs);
            return;
        }

        // Input bar spacing: its hairline sits one full blank line above the
        // prompt (plus a normal gap toward the history), and one blank line
        // separates the prompt from the window edge.
        float BoundaryBefore(int s) => s == liveIdx || s - 1 == liveIdx ? _cellHeight + gap : gap;

        float totalPx = 0;
        foreach (int eff in effRows)
            totalPx += eff * _cellHeight;
        for (int s = 1; s < segments.Count; s++)
            totalPx += BoundaryBefore(s);
        float edgePad = liveIdx >= 0 ? _cellHeight : 0;
        totalPx += edgePad; // edge margin next to the input

        float width = (float)_canvas.ActualWidth;
        float liveTopY = float.NaN;

        // Top mode: stack starts at the top, scrolling digs downward.
        // Bottom mode: the stack is anchored to the REAL canvas bottom (not
        // the row grid), so the blank line under the prompt is exactly one
        // cell - the same as the one above it.
        float y;
        if (newestFirst)
        {
            _pinScrollPx = Math.Clamp(_pinScrollPx, 0, Math.Max(0, totalPx - viewContentH));
            y = PaddingPx - _pinScrollPx + (liveIdx == 0 ? _cellHeight : 0);
        }
        else
        {
            float stackPx = totalPx - edgePad;
            float avail = canvasH - edgePad - PaddingPx;
            _pinScrollPx = Math.Clamp(_pinScrollPx, 0, Math.Max(0, stackPx - avail));
            // Classic keeps short content at the top (the input follows the
            // output downward); pinned-bottom always hugs the bottom edge.
            y = _inputPosition == 0 && stackPx <= avail
                ? PaddingPx
                : canvasH - edgePad - stackPx + _pinScrollPx;
        }
        for (int s = 0; s < segments.Count; s++)
        {
            var (start, count) = segments[s];
            if (s > 0)
            {
                float boundary = BoundaryBefore(s);
                // The live boundary's rule is drawn after the loop, at a fixed
                // one-line distance from the prompt.
                if (s != liveIdx && s - 1 != liveIdx)
                {
                    float sepY = y + boundary / 2;
                    if (sepY > 0 && sepY < viewH)
                        DrawHairline(ds, sepY, width);
                }
                y += boundary;
            }
            if (s == liveIdx)
                liveTopY = y;
            _blockLayout.Add((start, collapsed[s] ? 1 : count, y));

            if (start + dropped == _selectedBlockKey)
            {
                // The tint fills the block's whole band: up/down to the
                // neighboring separators (for the input boundary, up to its
                // hairline), so the highlight has no uneven leftover margins.
                float segPx = effRows[s] * _cellHeight;
                float padTop = s == 0 ? gap / 2
                    : s - 1 == liveIdx ? gap
                    : BoundaryBefore(s) / 2;
                float padBottom = s + 1 >= segments.Count ? gap / 2
                    : s + 1 == liveIdx ? gap
                    : BoundaryBefore(s + 1) / 2;
                ds.FillRectangle(0f, y - padTop, width, segPx + padTop + padBottom,
                    FromRgb(_palette.SelectionColor, 0x14));
            }

            if (y > viewH)
                break; // everything below is off-screen

            if (collapsed[s])
            {
                if (y + _cellHeight >= 0 && start < buffer.TotalLines)
                    DrawBufferLine(ds, buffer, start, y, cols, selStart, selEnd);
                float iy = y + _cellHeight;
                if (iy + _cellHeight >= 0 && iy <= viewH && _formats[0] is { } fmt)
                {
                    ds.DrawText($"··· {count - 1} hidden lines", PaddingPx + _cellWidth, iy,
                        FromRgb(_palette.DefaultForeground, 0x66), fmt);
                }
                y += 2 * _cellHeight;
                continue;
            }

            for (int j = 0; j < count; j++)
            {
                float ly = y + j * _cellHeight;
                if (ly + _cellHeight < 0)
                    continue;
                if (ly > viewH)
                    break;
                int abs = start + j;
                if (abs >= buffer.TotalLines)
                    break;
                DrawBufferLine(ds, buffer, abs, ly, cols, selStart, selEnd);
                if (abs == cursorAbs)
                    DrawCursorAt(ds, emu, buffer, cursorAbs, ly, cols);
            }
            y += count * _cellHeight;
        }

        // The input's own rule: always present (even on a fresh tab with a
        // single block), one blank line away from the prompt. Classic content
        // flows from the top, so a fresh tab has NO room above the input -
        // the rule flips below it instead of being clipped away.
        if (liveIdx >= 0 && !float.IsNaN(liveTopY))
        {
            float ruleAbove = liveTopY - _cellHeight;
            if (ruleAbove >= PaddingPx)
            {
                if (ruleAbove < viewH)
                    DrawHairline(ds, ruleAbove, width);
            }
            else
            {
                float ruleBelow = liveTopY + effRows[liveIdx] * _cellHeight + _cellHeight;
                if (ruleBelow > 0 && ruleBelow < viewH)
                    DrawHairline(ds, ruleBelow, width);
            }
        }
    }

    private float _histClipTop;
    private float _histClipBottom;

    /// <summary>Pinned rendering: the live input block and its hairline are
    /// anchored to the window edge; the history stack scrolls in the clipped
    /// region on the other side of the rule.</summary>
    private void DrawPinnedStack(Microsoft.Graphics.Canvas.CanvasDrawingSession ds, TerminalEmulator emu,
        ScreenBuffer buffer, int cols, (int Line, int Col) selStart, (int Line, int Col) selEnd,
        List<(int Start, int Count)> segments, bool[] collapsed, int[] effRows,
        int liveIdx, bool newestFirst, float gap, long dropped, float canvasH, int cursorAbs)
    {
        float width = (float)_canvas.ActualWidth;
        float cell = _cellHeight;
        var (liveStart, liveCount) = segments[liveIdx];
        float livePx = liveCount * cell;

        float liveTop;
        float ruleY;
        if (newestFirst)
        {
            liveTop = PaddingPx + cell;
            ruleY = liveTop + livePx + cell;
            _histClipTop = ruleY + gap / 2;
            _histClipBottom = canvasH - 4f;
        }
        else
        {
            liveTop = canvasH - cell - livePx;
            ruleY = liveTop - cell;
            _histClipTop = PaddingPx;
            _histClipBottom = ruleY - gap / 2;
        }

        _blockLayout.Clear();

        float histPx = 0;
        int histCount = 0;
        for (int i = 0; i < segments.Count; i++)
        {
            if (i == liveIdx)
                continue;
            histPx += effRows[i] * cell;
            histCount++;
        }
        if (histCount > 1)
            histPx += (histCount - 1) * gap;
        float avail = Math.Max(0, _histClipBottom - _histClipTop);
        _pinScrollPx = Math.Clamp(_pinScrollPx, 0, Math.Max(0, histPx - avail));

        if (histCount > 0 && avail > 0)
        {
            // Top mode: newest history right under the rule, older digging
            // downward. Bottom mode: newest right above the rule, older above.
            float y = newestFirst
                ? _histClipTop - _pinScrollPx
                : _histClipBottom - histPx + _pinScrollPx;

            using var layer = ds.CreateLayer(1f,
                new Rect(0, _histClipTop, width, avail));
            bool first = true;
            for (int i = 0; i < segments.Count; i++)
            {
                if (i == liveIdx)
                    continue;
                var (start, count) = segments[i];
                if (!first)
                {
                    float sepY = y + gap / 2;
                    if (sepY > _histClipTop - cell && sepY < _histClipBottom + cell)
                        DrawHairline(ds, sepY, width);
                    y += gap;
                }
                first = false;

                _blockLayout.Add((start, collapsed[i] ? 1 : count, y));

                float segPx = effRows[i] * cell;
                if (start + dropped == _selectedBlockKey)
                {
                    ds.FillRectangle(0f, y - gap / 2, width, segPx + gap,
                        FromRgb(_palette.SelectionColor, 0x14));
                }

                if (y > _histClipBottom + cell)
                {
                    y += segPx;
                    continue; // keep layout positions accurate, skip drawing
                }

                if (collapsed[i])
                {
                    if (y + cell >= _histClipTop - cell && start < buffer.TotalLines)
                        DrawBufferLine(ds, buffer, start, y, cols, selStart, selEnd);
                    float iy = y + cell;
                    if (iy + cell >= _histClipTop - cell && iy <= _histClipBottom + cell && _formats[0] is { } fmt)
                    {
                        ds.DrawText($"··· {count - 1} hidden lines", PaddingPx + _cellWidth, iy,
                            FromRgb(_palette.DefaultForeground, 0x66), fmt);
                    }
                    y += 2 * cell;
                    continue;
                }

                for (int j = 0; j < count; j++)
                {
                    float ly = y + j * cell;
                    if (ly + cell < _histClipTop - cell)
                        continue;
                    if (ly > _histClipBottom + cell)
                        break;
                    int abs = start + j;
                    if (abs >= buffer.TotalLines)
                        break;
                    DrawBufferLine(ds, buffer, abs, ly, cols, selStart, selEnd);
                    if (abs == cursorAbs)
                        DrawCursorAt(ds, emu, buffer, cursorAbs, ly, cols);
                }
                y += count * cell;
            }
        }

        DrawHairline(ds, ruleY, width);

        _blockLayout.Add((liveStart, liveCount, liveTop));
        for (int j = 0; j < liveCount; j++)
        {
            int abs = liveStart + j;
            if (abs >= buffer.TotalLines)
                break;
            float ly = liveTop + j * cell;
            DrawBufferLine(ds, buffer, abs, ly, cols, selStart, selEnd);
            if (abs == cursorAbs)
                DrawCursorAt(ds, emu, buffer, cursorAbs, ly, cols);
        }
    }

    /// <summary>A one-physical-pixel edge-to-edge rule in the exact colors of
    /// the app chrome's HairlineBrush, snapped to the pixel grid.</summary>
    private void DrawHairline(Microsoft.Graphics.Canvas.CanvasDrawingSession ds, float y, float width)
    {
        float scale = (float)(XamlRoot?.RasterizationScale ?? 1.0);
        float snapped = MathF.Round(y * scale) / scale;
        uint bg = _palette.DefaultBackground;
        double lum = (0.299 * ((bg >> 16) & 0xFF) + 0.587 * ((bg >> 8) & 0xFF) + 0.114 * (bg & 0xFF)) / 255.0;
        var color = lum < 0.5
            ? Color.FromArgb(0x16, 0xFF, 0xFF, 0xFF)
            : Color.FromArgb(0x21, 0x00, 0x00, 0x00);
        ds.FillRectangle(0f, snapped, width, 1f / scale, color);
    }

    private void DrawTextRuns(Microsoft.Graphics.Canvas.CanvasDrawingSession ds, Cell[] cells, int n, float y)
    {
        _runText.Clear();
        int runStartCol = 0;
        int runCells = 0;
        uint runFg = 0;
        CellFlags runFlags = 0;
        bool runHasGlyphs = false;
        const CellFlags StyleMask = CellFlags.Bold | CellFlags.Italic | CellFlags.Underline |
                                    CellFlags.DoubleUnderline | CellFlags.Strikethrough;

        void Flush(Microsoft.Graphics.Canvas.CanvasDrawingSession session)
        {
            if (_runText.Length == 0)
                return;
            float x = PaddingPx + runStartCol * _cellWidth;
            if (runHasGlyphs)
                session.DrawText(_runText.ToString(), x, y, FromRgb(runFg), PickFormat(runFlags));

            float width = runCells * _cellWidth;
            var color = FromRgb(runFg);
            if ((runFlags & (CellFlags.Underline | CellFlags.DoubleUnderline)) != 0)
            {
                session.DrawLine(x, y + _cellHeight - 1.5f, x + width, y + _cellHeight - 1.5f, color, 1f);
                if ((runFlags & CellFlags.DoubleUnderline) != 0)
                    session.DrawLine(x, y + _cellHeight - 3.5f, x + width, y + _cellHeight - 3.5f, color, 1f);
            }
            if ((runFlags & CellFlags.Strikethrough) != 0)
            {
                float sy = y + _cellHeight * 0.55f;
                session.DrawLine(x, sy, x + width, sy, color, 1f);
            }
            _runText.Clear();
            runCells = 0;
            runHasGlyphs = false;
        }

        for (int c = 0; c < n; c++)
        {
            ref readonly var cell = ref cells[c];
            if ((cell.Flags & CellFlags.WideTrailing) != 0)
                continue;

            int rune = cell.Rune == 0 ? ' ' : cell.Rune;
            uint fg = _fgRow[c];
            CellFlags style = cell.Flags & StyleMask;

            bool wide = rune > 0xFF && CharWidth.GetWidth(rune) == 2;

            if (_runText.Length > 0 && (fg != runFg || style != runFlags))
                Flush(ds);

            if (wide)
            {
                // Draw wide glyphs individually so fallback-font metrics can't
                // push the rest of the row out of alignment.
                Flush(ds);
                ds.DrawText(char.ConvertFromUtf32(rune), PaddingPx + c * _cellWidth, y,
                    FromRgb(fg), PickFormat(cell.Flags));
                continue;
            }

            if (_runText.Length == 0)
            {
                runStartCol = c;
                runFg = fg;
                runFlags = style;
            }

            if (rune > 0xFFFF)
                _runText.Append(char.ConvertFromUtf32(rune));
            else
                _runText.Append((char)rune);
            runCells++;
            if (rune != ' ')
                runHasGlyphs = true;
        }
        Flush(ds);
    }

    private void DrawCursor(Microsoft.Graphics.Canvas.CanvasDrawingSession ds, TerminalEmulator emu,
        ScreenBuffer buffer, int scrollback, int firstAbs, int rows, int cols)
    {
        int cursorAbs = scrollback + emu.CursorY;
        int r = cursorAbs - firstAbs + _alignPad;
        if (r < 0 || r >= rows)
            return;
        DrawCursorAt(ds, emu, buffer, cursorAbs, PaddingPx + r * _cellHeight, cols);
    }

    private void DrawCursorAt(Microsoft.Graphics.Canvas.CanvasDrawingSession ds, TerminalEmulator emu,
        ScreenBuffer buffer, int cursorAbs, float y, int cols)
    {
        if (!emu.CursorVisible)
            return;

        int cx = Math.Clamp(emu.CursorX, 0, cols - 1);
        float x = PaddingPx + cx * _cellWidth;
        var cursorColor = FromRgb(_palette.CursorColor);

        if (!_hasFocus)
        {
            ds.DrawRectangle(x + 0.5f, y + 0.5f, _cellWidth - 1, _cellHeight - 1, cursorColor, 1f);
            return;
        }

        if (!_cursorBlinkOn)
            return;

        int style = emu.CursorStyle == 0 ? DefaultCursorStyleCode : emu.CursorStyle;
        switch (style)
        {
            case 3:
            case 4:
                ds.FillRectangle(x, y + _cellHeight - 2, _cellWidth, 2, cursorColor);
                break;
            case 5:
            case 6:
                ds.FillRectangle(x, y, 1.5f, _cellHeight, cursorColor);
                break;
            default:
                ds.FillRectangle(x, y, _cellWidth, _cellHeight, cursorColor);
                var line = buffer.GetAbsoluteLine(cursorAbs);
                if (cx < line.Cells.Length)
                {
                    var cell = line.Cells[cx];
                    if (cell.Rune != 0 && cell.Rune != ' ')
                    {
                        ds.DrawText(char.ConvertFromUtf32(cell.Rune), x, y,
                            FromRgb(_palette.DefaultBackground), PickFormat(cell.Flags));
                    }
                }
                break;
        }
    }

    private static Color FromRgb(uint rgb, byte alpha = 0xFF) =>
        Color.FromArgb(alpha, (byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb);

    // ---------------------------------------------------------------- keyboard

    private static InputModifiers GetModifiers()
    {
        InputModifiers mods = InputModifiers.None;
        if (IsDown(VirtualKey.Shift)) mods |= InputModifiers.Shift;
        if (IsDown(VirtualKey.Control)) mods |= InputModifiers.Ctrl;
        if (IsDown(VirtualKey.Menu)) mods |= InputModifiers.Alt;
        return mods;

        static bool IsDown(VirtualKey key) =>
            InputKeyboardSource.GetKeyStateForCurrentThread(key)
                .HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
    }

    protected override void OnKeyDown(KeyRoutedEventArgs e)
    {
        // Keys bubbling out of the find box must never reach the shell.
        if (_findFocused)
        {
            base.OnKeyDown(e);
            return;
        }

        var mods = GetModifiers();
        bool ctrl = (mods & InputModifiers.Ctrl) != 0;
        bool shift = (mods & InputModifiers.Shift) != 0;
        bool alt = (mods & InputModifiers.Alt) != 0;
        int vk = (int)e.Key;

        // UI shortcuts first.
        if (ctrl && shift && e.Key == VirtualKey.C)
        {
            CopySelection();
            e.Handled = true;
            return;
        }
        if ((ctrl && shift && e.Key == VirtualKey.V) || (shift && !ctrl && e.Key == VirtualKey.Insert))
        {
            _ = PasteFromClipboardAsync();
            e.Handled = true;
            return;
        }
        if (ctrl && !shift && e.Key == VirtualKey.Insert)
        {
            CopySelection();
            e.Handled = true;
            return;
        }
        // Rebindable block actions (jump, copy output, find). A failed jump
        // (no prompt marks, or an app owns the screen) falls through so the
        // key still reaches the shell.
        if (ResolveBlockShortcut?.Invoke(vk, mods) is { } blockAction &&
            HandleBlockAction(blockAction))
        {
            e.Handled = true;
            return;
        }
        // History panel open: it owns Up/Down/Enter/Tab/Esc; any other key
        // closes it (keeping the previewed text at the prompt) and continues
        // to the shell, so you can just keep typing to edit the command.
        if (_historyPanel.Visibility == Visibility.Visible)
        {
            // Bare modifier presses (Alt of Alt+Tab, Ctrl, Shift...) must not
            // dismiss the panel - it survives window switches.
            if (e.Key is VirtualKey.Menu or VirtualKey.LeftMenu or VirtualKey.RightMenu
                or VirtualKey.Control or VirtualKey.LeftControl or VirtualKey.RightControl
                or VirtualKey.Shift or VirtualKey.LeftShift or VirtualKey.RightShift
                or VirtualKey.LeftWindows or VirtualKey.RightWindows or VirtualKey.CapitalLock)
            {
                base.OnKeyDown(e);
                return;
            }
            if (HandleHistoryKey(e.Key, ctrl || shift || alt))
            {
                e.Handled = true;
                return;
            }
            // App chords (Ctrl+= zoom, Ctrl+Shift+C copy, ...) act with the
            // panel open - it repositions itself after zoom changes. Only
            // plain typing closes it (keeping the preview for editing).
            if (!ctrl && !alt)
                CloseHistory(discardText: false);
        }
        // Arrow Up on an EMPTY prompt opens the history panel; with anything
        // typed (or without shell integration) it reaches the shell untouched,
        // so PSReadLine's own history/prefix search keeps working.
        if (!ctrl && !shift && !alt && e.Key == VirtualKey.Up && TryOpenHistory())
        {
            e.Handled = true;
            return;
        }
        // Esc dismisses the find bar, then the block highlight, then reaches
        // the shell as usual.
        if (!ctrl && !shift && !alt && e.Key == VirtualKey.Escape)
        {
            if (_findPanel.Visibility == Visibility.Visible)
            {
                CloseFind();
                e.Handled = true;
                return;
            }
            if (_selectedBlockKey >= 0)
            {
                _selectedBlockKey = -1;
                _canvas.Invalidate();
                e.Handled = true;
                return;
            }
        }
        // App shortcuts (zoom, tab management, …) only fire their window
        // accelerators when the key bubbles up unhandled - never swallow them
        // into the shell (plain Ctrl+- would otherwise become the 0x1F chord).
        if (IsReservedShortcut?.Invoke(vk, mods) == true)
        {
            base.OnKeyDown(e);
            return;
        }

        // Ctrl chords → control characters (Ctrl+C = 0x03 etc.).
        if (ctrl && !alt)
        {
            string? chord = TerminalInput.EncodeControlChord(vk, mods);
            if (chord != null)
            {
                SendInput(chord);
                e.Handled = true;
                return;
            }
        }

        // Alt+key → ESC prefix (but never for AltGr = Ctrl+Alt).
        if (alt && !ctrl)
        {
            if (vk >= 'A' && vk <= 'Z')
            {
                char c = shift ? (char)vk : (char)(vk + 32);
                SendInput("\x1b" + c);
                e.Handled = true;
                return;
            }
            if (vk >= '0' && vk <= '9')
            {
                SendInput("\x1b" + (char)vk);
                e.Handled = true;
                return;
            }
        }

        string? seq = TerminalInput.EncodeKey(vk, mods, _session.Emulator.ApplicationCursorKeys);
        if (seq != null)
        {
            SendInput(seq);
            e.Handled = true;
            return;
        }

        base.OnKeyDown(e);
    }

    private void OnCharacterReceived(UIElement sender, CharacterReceivedRoutedEventArgs args)
    {
        if (_findFocused)
            return; // typing in the find box, not the shell
        char c = args.Character;
        if (c < 0x20 || c == 0x7F)
            return; // control characters are produced from OnKeyDown

        args.Handled = true;

        if (char.IsHighSurrogate(c))
        {
            _pendingHighSurrogate = c;
            return;
        }

        string text;
        if (char.IsLowSurrogate(c))
        {
            if (_pendingHighSurrogate == 0)
                return;
            text = new string(new[] { _pendingHighSurrogate, c });
            _pendingHighSurrogate = '\0';
        }
        else
        {
            text = c.ToString();
        }

        SendInput(text);
    }

    private void SendInput(string text)
    {
        _cursorBlinkOn = true;
        ClearSelection();
        if (_selectedBlockKey >= 0)
        {
            _selectedBlockKey = -1; // typing returns attention to the prompt
            _canvas.Invalidate();
        }
        ScrollToBottom();
        _session.Send(text);
    }

    // ---------------------------------------------------------------- mouse

    private void OnPointerWheelChanged(object sender, PointerRoutedEventArgs e)
    {
        var point = e.GetCurrentPoint(this);
        int delta = point.Properties.MouseWheelDelta;
        var mods = GetModifiers();

        if ((mods & InputModifiers.Ctrl) != 0)
        {
            ChangeFontSize(delta > 0 ? +1 : -1);
            e.Handled = true;
            return;
        }

        var emu = _session.Emulator;
        if (emu.IsAlternateBuffer)
        {
            // Full-screen apps get arrow keys instead of scrollback.
            string key = delta > 0
                ? (emu.ApplicationCursorKeys ? "\x1bOA" : "\x1b[A")
                : (emu.ApplicationCursorKeys ? "\x1bOB" : "\x1b[B");
            int repeat = Math.Max(1, Math.Abs(delta) / 120) * 3;
            _session.Send(string.Concat(Enumerable.Repeat(key, repeat)));
        }
        else
        {
            int lines = Math.Max(1, Math.Abs(delta) / 120) * 3;
            int scrollback;
            bool blocks;
            lock (emu.SyncRoot)
            {
                scrollback = emu.ScrollbackCount;
                blocks = emu.PromptMarkLine >= 0;
            }
            if (blocks)
            {
                // Scroll the block stack toward older content: down in the
                // pinned-top stack, up in the pinned-bottom one (clamped in draw).
                int toward = _inputPosition == 2
                    ? (delta > 0 ? -lines : lines)
                    : (delta > 0 ? lines : -lines);
                _pinScrollPx = Math.Max(0, _pinScrollPx + toward * _cellHeight);
            }
            else
            {
                _scrollOffset = Math.Clamp(_scrollOffset + (delta > 0 ? lines : -lines), 0, scrollback);
            }
            _canvas.Invalidate();
        }
        e.Handled = true;
    }

    private void OnPointerPressed(object sender, PointerRoutedEventArgs e)
    {
        FocusTerminal();
        var point = e.GetCurrentPoint(this);

        if (point.Properties.IsRightButtonPressed)
        {
            SelectBlockAt(point.Position);
            ShowContextMenu(point.Position);
            e.Handled = true;
            return;
        }

        if (point.Properties.IsLeftButtonPressed)
        {
            SelectBlockAt(point.Position);
            _selecting = true;
            _hasSelection = false;
            _selAnchor = _selFocus = HitTest(point.Position);
            CapturePointer(e.Pointer);
            _canvas.Invalidate();
            e.Handled = true;
        }
    }

    /// <summary>Highlights the block under the pointer. The live
    /// input block is not selectable - clicking it clears the highlight.</summary>
    private void SelectBlockAt(Point pos)
    {
        long key = BlockAt(pos) is { IsLive: false } block ? block.Key : -1;
        if (key != _selectedBlockKey)
        {
            _selectedBlockKey = key;
            _canvas.Invalidate();
        }
    }

    private void OnPointerMoved(object sender, PointerRoutedEventArgs e)
    {
        var point = e.GetCurrentPoint(this);
        if (!_selecting)
        {
            UpdateHoverChip(point.Position);
            return;
        }
        var hit = HitTest(point.Position);
        if (hit != _selFocus)
        {
            _selFocus = hit;
            _hasSelection = _selFocus != _selAnchor;
            _canvas.Invalidate();
        }
    }

    private void OnPointerReleased(object sender, PointerRoutedEventArgs e)
    {
        if (_selecting)
        {
            _selecting = false;
            ReleasePointerCapture(e.Pointer);
        }
    }

    private (int Line, int Col) HitTest(Point p)
    {
        var emu = _session.Emulator;
        lock (emu.SyncRoot)
        {
            int col = Math.Clamp((int)((p.X - PaddingPx) / _cellWidth), 0, emu.Cols - 1);

            // Block stack: map through the layout captured during the last draw.
            if (!emu.IsAlternateBuffer && _blockLayout.Count > 0)
            {
                var seg = _blockLayout[0];
                foreach (var candidate in _blockLayout)
                {
                    if (candidate.TopPx <= p.Y)
                        seg = candidate;
                }
                int segRow = Math.Clamp((int)((p.Y - seg.TopPx) / _cellHeight), 0, seg.Count - 1);
                int absLine = Math.Clamp(seg.Start + segRow, 0, emu.Buffer.TotalLines - 1);
                return (absLine, col);
            }

            int row = Math.Clamp((int)((p.Y - PaddingPx) / _cellHeight) - _alignPad, 0, emu.Rows - 1);
            int firstAbs = emu.Buffer.ScrollbackCount - _scrollOffset;
            int line = Math.Clamp(firstAbs + row, 0, emu.Buffer.TotalLines - 1);
            return (line, col);
        }
    }

    private ((int Line, int Col) Start, (int Line, int Col) End) NormalizedSelection()
    {
        if (_selAnchor.Line < _selFocus.Line ||
            (_selAnchor.Line == _selFocus.Line && _selAnchor.Col <= _selFocus.Col))
            return (_selAnchor, _selFocus);
        return (_selFocus, _selAnchor);
    }

    private void ClearSelection()
    {
        if (_hasSelection)
        {
            _hasSelection = false;
            _canvas.Invalidate();
        }
    }

    private void ScrollToBottom()
    {
        // Typing returns to the live prompt: block-stack home and offset zero.
        bool changed = false;
        if (_pinScrollPx != 0)
        {
            _pinScrollPx = 0;
            changed = true;
        }
        if (_scrollOffset != 0)
        {
            _scrollOffset = 0;
            changed = true;
        }
        if (changed)
            _canvas.Invalidate();
    }

    // ---------------------------------------------------------------- blocks

    /// <summary>Runs a rebindable block action; false means the key should
    /// fall through to the shell instead.</summary>
    private bool HandleBlockAction(string actionId)
    {
        switch (actionId)
        {
            case "blockPrev":
                return TryJumpBlocks(-1);
            case "blockNext":
                return TryJumpBlocks(+1);
            case "copyOutput":
                if (TargetBlock() is { } outBlock)
                    CopyText(GetBlockOutput(outBlock.Start, outBlock.End));
                return true;
            case "findInBlock":
                if (TargetBlock() is { } findBlock)
                    OpenFind(findBlock.Key);
                return true;
        }
        return false;
    }

    /// <summary>Scrolls one block older (dir -1) or newer (dir +1). Returns
    /// false when there is nothing to jump between (no marks / alt buffer).</summary>
    private bool TryJumpBlocks(int dir)
    {
        var emu = _session.Emulator;
        lock (emu.SyncRoot)
        {
            if (emu.IsAlternateBuffer)
                return false;
            var marks = emu.GetPromptMarks();
            if (marks.Count == 0)
                return false;

            if (_blockLayout.Count > 0)
            {
                // Candidates: history blocks only in pinned modes (the live
                // block is fixed at the edge and never a scroll target).
                int liveStart = _inputPosition != 0 ? marks[^1] : -1;
                var candidates = new List<(int Index, float TopPx)>();
                for (int i = 0; i < _blockLayout.Count; i++)
                {
                    if (_blockLayout[i].Start != liveStart)
                        candidates.Add((i, _blockLayout[i].TopPx));
                }
                if (candidates.Count == 0)
                    return true;

                // Home: top of the history viewport (below the input in
                // pinned-top mode, the window top otherwise).
                float home = _inputPosition == 2 ? _histClipTop : PaddingPx;
                int cur = 0;
                float best = float.MaxValue;
                for (int i = 0; i < candidates.Count; i++)
                {
                    float d = Math.Abs(candidates[i].TopPx - home);
                    if (d < best)
                    {
                        best = d;
                        cur = i;
                    }
                }
                bool newestFirst = _inputPosition == 2;
                int target = cur + (newestFirst ? -dir : dir);
                if (target < 0 || target >= candidates.Count)
                {
                    if (dir > 0)
                        ScrollToBottom(); // past the newest block = back home
                    return true;
                }
                float delta = candidates[target].TopPx - home;
                _pinScrollPx = Math.Max(0, _pinScrollPx + (newestFirst ? delta : -delta));
                _canvas.Invalidate();
                return true;
            }

            // Classic: align the target block's prompt line with the view top.
            int scrollback = emu.Buffer.ScrollbackCount;
            int top = scrollback - _scrollOffset;
            int targetMark = -1;
            if (dir < 0)
            {
                foreach (int m in marks)
                {
                    if (m < top)
                        targetMark = m;
                    else
                        break;
                }
            }
            else
            {
                foreach (int m in marks)
                {
                    if (m > top)
                    {
                        targetMark = m;
                        break;
                    }
                }
            }
            if (targetMark < 0)
            {
                if (dir > 0)
                    ScrollToBottom(); // past the newest block = live prompt
                return true;
            }
            _scrollOffset = Math.Clamp(scrollback - targetMark, 0, scrollback);
            _canvas.Invalidate();
            return true;
        }
    }

    /// <summary>The block under a view point: absolute first/last line, whether
    /// it holds the live prompt, and its drop-stable collapse key.</summary>
    private (int Start, int End, bool IsLive, long Key)? BlockAt(Point pos)
    {
        var emu = _session.Emulator;
        lock (emu.SyncRoot)
        {
            if (emu.IsAlternateBuffer)
                return null;
            var marks = emu.GetPromptMarks();
            if (marks.Count == 0)
                return null;

            int line = HitTest(pos).Line;
            long dropped = emu.Buffer.DroppedLines;
            int contentEnd = emu.Buffer.ScrollbackCount + emu.CursorY;

            int idx = -1;
            foreach (int m in marks)
            {
                if (m <= line)
                    idx++;
                else
                    break;
            }
            if (idx < 0)
            {
                // Output that predates the first known prompt.
                return marks[0] == 0 ? null : (0, marks[0] - 1, false, dropped);
            }
            int start = marks[idx];
            int end = idx + 1 < marks.Count ? marks[idx + 1] - 1 : Math.Max(start, contentEnd);
            return (start, end, idx == marks.Count - 1, start + dropped);
        }
    }

    private void ShowContextMenu(Point pos)
    {
        BuildBlockMenu(BlockAt(pos)).ShowAt(this, pos);
    }

    /// <summary>The block menu, shared by right-click and the hover chip.</summary>
    private MenuFlyout BuildBlockMenu((int Start, int End, bool IsLive, long Key)? blockOpt)
    {
        var menu = new MenuFlyout();

        AddItem("Copy", () => { CopySelection(); ClearSelection(); }, _hasSelection, "Ctrl+Shift+C");
        AddItem("Paste", () => _ = PasteFromClipboardAsync(), true, "Ctrl+Shift+V");

        if (blockOpt is { } block)
        {
            menu.Items.Add(new MenuFlyoutSeparator());
            AddItem("Copy command", () => CopyText(GetBlockCommand(block.Start, block.End)));
            AddItem("Copy output", () => CopyText(GetBlockOutput(block.Start, block.End)), true,
                BlockShortcutText?.Invoke("copyOutput"));
            AddItem("Copy block", () => CopyText(GetBlockText(block.Start, block.End)));
            AddItem("Copy block as Markdown", () => CopyText(GetBlockMarkdown(block.Start, block.End)));

            menu.Items.Add(new MenuFlyoutSeparator());
            AddItem("Find within block", () => OpenFind(block.Key), true,
                BlockShortcutText?.Invoke("findInBlock"));

            if (!block.IsLive && block.End > block.Start)
            {
                bool isCollapsed = _collapsed.Contains(block.Key);
                AddItem(isCollapsed ? "Expand block" : "Collapse block", () =>
                {
                    if (!_collapsed.Remove(block.Key))
                        _collapsed.Add(block.Key);
                    _canvas.Invalidate();
                });
            }
        }

        return menu;

        void AddItem(string text, Action action, bool enabled = true, string? accelerator = null)
        {
            var item = new MenuFlyoutItem { Text = text, FontSize = 12, IsEnabled = enabled };
            if (accelerator != null)
                item.KeyboardAcceleratorTextOverride = accelerator;
            item.Click += (_, _) => action();
            menu.Items.Add(item);
        }
    }

    /// <summary>Resolves a drop-stable block key back to its current range.</summary>
    private (int Start, int End, bool IsLive, long Key)? BlockFromKey(long key)
    {
        var emu = _session.Emulator;
        lock (emu.SyncRoot)
        {
            if (key < 0 || emu.IsAlternateBuffer)
                return null;
            var marks = emu.GetPromptMarks();
            if (marks.Count == 0)
                return null;
            long dropped = emu.Buffer.DroppedLines;
            int start = (int)(key - dropped);
            int contentEnd = emu.Buffer.ScrollbackCount + emu.CursorY;
            if (start == 0 && marks[0] > 0)
                return (0, marks[0] - 1, false, key);
            int idx = marks.IndexOf(start);
            if (idx < 0)
                return null;
            int end = idx + 1 < marks.Count ? marks[idx + 1] - 1 : Math.Max(start, contentEnd);
            return (start, end, idx == marks.Count - 1, key);
        }
    }

    /// <summary>Keybind target: the highlighted block, else the newest finished
    /// block, else the live one.</summary>
    private (int Start, int End, bool IsLive, long Key)? TargetBlock()
    {
        if (BlockFromKey(_selectedBlockKey) is { } selected)
            return selected;
        var emu = _session.Emulator;
        lock (emu.SyncRoot)
        {
            if (emu.IsAlternateBuffer)
                return null;
            var marks = emu.GetPromptMarks();
            if (marks.Count == 0)
                return null;
            long dropped = emu.Buffer.DroppedLines;
            int contentEnd = emu.Buffer.ScrollbackCount + emu.CursorY;
            int idx = Math.Max(0, marks.Count - 2);
            int start = marks[idx];
            int end = idx + 1 < marks.Count ? marks[idx + 1] - 1 : Math.Max(start, contentEnd);
            return (start, end, idx == marks.Count - 1, start + dropped);
        }
    }

    // ---------------------------------------------------------------- hover chip

    private Button BuildChip()
    {
        var chip = new Button
        {
            Width = 30,
            Height = 26,
            Padding = new Thickness(0),
            CornerRadius = new CornerRadius(6),
            BorderThickness = new Thickness(1),
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(0, 6, 12, 0),
            Visibility = Visibility.Collapsed,
            Background = _overlayBg,
            BorderBrush = _overlayBorder,
            Foreground = _overlayFg,
            IsTabStop = false,
            Content = new FontIcon
            {
                FontFamily = new FontFamily("Segoe Fluent Icons"),
                Glyph = "", // "More" (three dots)
                FontSize = 14,
            },
        };
        chip.Resources["ButtonBackgroundPointerOver"] = _overlayBgHover;
        chip.Resources["ButtonBackgroundPressed"] = _overlayBgActive;
        chip.Resources["ButtonForegroundPointerOver"] = _overlayFg;
        chip.Resources["ButtonForegroundPressed"] = _overlayFg;
        chip.Resources["ButtonBorderBrushPointerOver"] = _overlayBorder;
        chip.Resources["ButtonBorderBrushPressed"] = _overlayBorder;
        ToolTipService.SetToolTip(chip, "Block actions");
        chip.Click += OnChipClick;
        return chip;
    }

    /// <summary>Shows the "..." chip pinned to the hovered block's top-right.
    /// The live input block gets no chip - it is not a finished block.</summary>
    private void UpdateHoverChip(Point p)
    {
        var block = BlockAt(p);
        if (block == null || block.Value.IsLive)
        {
            HideChip();
            return;
        }
        var range = BlockPixelRange(block.Value.Start, block.Value.End);
        if (range == null)
        {
            HideChip();
            return;
        }
        float viewBottom = (float)ActualHeight;
        float minY = _findPanel.Visibility == Visibility.Visible ? 52f : 4f;
        if (range.Value.Bottom < minY + 24 || range.Value.Top > viewBottom - 10)
        {
            HideChip();
            return;
        }
        float top = Math.Clamp(range.Value.Top + 3f, minY, Math.Max(minY, viewBottom - 32f));
        _hoverChipKey = block.Value.Key;
        if (Math.Abs(_chip.Margin.Top - top) > 0.5 || _chip.Visibility == Visibility.Collapsed)
        {
            _chip.Margin = new Thickness(0, top, 12, 0);
            _chip.Visibility = Visibility.Visible;
        }
    }

    private void HideChip()
    {
        _hoverChipKey = -1;
        if (_chip.Visibility == Visibility.Visible)
            _chip.Visibility = Visibility.Collapsed;
    }

    private void OnChipClick(object sender, RoutedEventArgs e)
    {
        if (BlockFromKey(_hoverChipKey) is not { } block)
            return;
        if (_selectedBlockKey != block.Key)
        {
            _selectedBlockKey = block.Key;
            _canvas.Invalidate();
        }
        var menu = BuildBlockMenu(block);
        // Drop down from the button, right edges aligned - never upward.
        menu.Placement = FlyoutPlacementMode.BottomEdgeAlignedRight;
        menu.ShowAt(_chip);
    }

    /// <summary>A block's current on-screen pixel span (top, bottom).</summary>
    private (float Top, float Bottom)? BlockPixelRange(int start, int end)
    {
        var emu = _session.Emulator;
        lock (emu.SyncRoot)
        {
            if (emu.IsAlternateBuffer)
                return null;
            if (_blockLayout.Count > 0)
            {
                foreach (var seg in _blockLayout)
                {
                    if (seg.Start == start)
                        return (seg.TopPx, seg.TopPx + Math.Max(seg.Count, 2) * _cellHeight);
                }
                return null;
            }
            int firstAbs = emu.Buffer.ScrollbackCount - _scrollOffset;
            float top = PaddingPx + (start - firstAbs + _alignPad) * _cellHeight;
            float bottom = PaddingPx + (end - firstAbs + 1 + _alignPad) * _cellHeight;
            return (top, bottom);
        }
    }

    // ---------------------------------------------------------------- find in block

    private Border BuildFindPanel()
    {
        _findBox = new TextBox
        {
            Width = 180,
            Height = 28,
            MinHeight = 0,
            FontSize = 12,
            Padding = new Thickness(8, 5, 8, 0),
            CornerRadius = new CornerRadius(5),
            PlaceholderText = "Find in block",
            VerticalAlignment = VerticalAlignment.Center,
            SelectionHighlightColor = _overlayAccent,
        };
        // Flatten the box into the panel: every visual state takes its colors
        // from the terminal palette instead of the app chrome theme.
        var boxRes = _findBox.Resources;
        boxRes["TextControlBackground"] = _overlayInputBg;
        boxRes["TextControlBackgroundPointerOver"] = _overlayInputBg;
        boxRes["TextControlBackgroundFocused"] = _overlayInputBg;
        boxRes["TextControlBorderBrush"] = _overlayBorder;
        boxRes["TextControlBorderBrushPointerOver"] = _overlayBorder;
        boxRes["TextControlBorderBrushFocused"] = _overlayBorder;
        boxRes["TextControlForeground"] = _overlayFg;
        boxRes["TextControlForegroundPointerOver"] = _overlayFg;
        boxRes["TextControlForegroundFocused"] = _overlayFg;
        boxRes["TextControlPlaceholderForeground"] = _overlayFgDim;
        boxRes["TextControlPlaceholderForegroundPointerOver"] = _overlayFgDim;
        boxRes["TextControlPlaceholderForegroundFocused"] = _overlayFgDim;
        boxRes["TextControlBorderThemeThickness"] = new Thickness(1);
        boxRes["TextControlBorderThemeThicknessFocused"] = new Thickness(1);
        _findBox.TextChanged += (_, _) => RecomputeFind();
        _findBox.KeyDown += OnFindBoxKeyDown;
        _findBox.GotFocus += (_, _) => _findFocused = true;
        _findBox.LostFocus += (_, _) => _findFocused = false;

        _findCaseBtn = MakeToggle("Aa", "Match case");
        _findRegexBtn = MakeToggle(".*", "Regular expression");
        _findCount = new TextBlock
        {
            Text = "0/0",
            FontSize = 11,
            Foreground = _overlayFgDim,
            MinWidth = 36,
            TextAlignment = TextAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(2, 0, 0, 0),
        };

        var prev = MakeIconButton("", "Previous match (Shift+Enter)");
        prev.Click += (_, _) => StepFind(-1);
        var next = MakeIconButton("", "Next match (Enter)");
        next.Click += (_, _) => StepFind(+1);
        var close = MakeIconButton("", "Close (Esc)");
        close.Click += (_, _) => CloseFind();

        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        row.Children.Add(_findBox);
        row.Children.Add(_findCaseBtn);
        row.Children.Add(_findRegexBtn);
        row.Children.Add(_findCount);
        row.Children.Add(prev);
        row.Children.Add(next);
        row.Children.Add(close);

        var panel = new Border
        {
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(0, 8, 12, 0),
            CornerRadius = new CornerRadius(8),
            BorderThickness = new Thickness(1),
            Padding = new Thickness(8, 5, 5, 5),
            Background = _overlayBg,
            BorderBrush = _overlayBorder,
            Visibility = Visibility.Collapsed,
            Child = row,
        };
        // Clicks on the panel chrome must not fall through into the terminal
        // (they would start a selection and steal focus from the box).
        panel.PointerPressed += (_, args) => args.Handled = true;
        panel.PointerReleased += (_, args) => args.Handled = true;
        return panel;

        ToggleButton MakeToggle(string label, string tip)
        {
            var toggle = new ToggleButton
            {
                Content = label,
                FontSize = 11.5,
                Height = 28,
                MinWidth = 32,
                Padding = new Thickness(7, 0, 7, 0),
                CornerRadius = new CornerRadius(5),
                BorderThickness = new Thickness(0),
                Background = TransparentBrush,
                Foreground = _overlayFgDim,
                IsTabStop = false,
                VerticalAlignment = VerticalAlignment.Center,
            };
            var res = toggle.Resources;
            res["ToggleButtonBackgroundPointerOver"] = _overlayHover;
            res["ToggleButtonBackgroundPressed"] = _overlayActive;
            res["ToggleButtonBackgroundChecked"] = _overlayAccent;
            res["ToggleButtonBackgroundCheckedPointerOver"] = _overlayAccent;
            res["ToggleButtonBackgroundCheckedPressed"] = _overlayAccent;
            res["ToggleButtonForegroundPointerOver"] = _overlayFg;
            res["ToggleButtonForegroundPressed"] = _overlayFg;
            res["ToggleButtonForegroundChecked"] = _overlayFg;
            res["ToggleButtonForegroundCheckedPointerOver"] = _overlayFg;
            res["ToggleButtonForegroundCheckedPressed"] = _overlayFg;
            res["ToggleButtonBorderBrushPointerOver"] = TransparentBrush;
            res["ToggleButtonBorderBrushPressed"] = TransparentBrush;
            res["ToggleButtonBorderBrushChecked"] = TransparentBrush;
            res["ToggleButtonBorderBrushCheckedPointerOver"] = TransparentBrush;
            res["ToggleButtonBorderBrushCheckedPressed"] = TransparentBrush;
            ToolTipService.SetToolTip(toggle, tip);
            toggle.Checked += (_, _) => RecomputeFind();
            toggle.Unchecked += (_, _) => RecomputeFind();
            return toggle;
        }

        Button MakeIconButton(string glyph, string tip)
        {
            var button = new Button
            {
                Width = 28,
                Height = 28,
                Padding = new Thickness(0),
                CornerRadius = new CornerRadius(5),
                Background = TransparentBrush,
                BorderThickness = new Thickness(0),
                Foreground = _overlayFg,
                IsTabStop = false,
                VerticalAlignment = VerticalAlignment.Center,
                Content = new FontIcon
                {
                    FontFamily = new FontFamily("Segoe Fluent Icons"),
                    Glyph = glyph,
                    FontSize = 11,
                },
            };
            var res = button.Resources;
            res["ButtonBackgroundPointerOver"] = _overlayHover;
            res["ButtonBackgroundPressed"] = _overlayActive;
            res["ButtonForegroundPointerOver"] = _overlayFg;
            res["ButtonForegroundPressed"] = _overlayFg;
            res["ButtonBorderBrushPointerOver"] = TransparentBrush;
            res["ButtonBorderBrushPressed"] = TransparentBrush;
            ToolTipService.SetToolTip(button, tip);
            return button;
        }
    }

    private void OnFindBoxKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Enter)
        {
            StepFind((GetModifiers() & InputModifiers.Shift) != 0 ? -1 : +1);
            e.Handled = true;
        }
        else if (e.Key == VirtualKey.Escape)
        {
            CloseFind();
            e.Handled = true;
        }
    }

    /// <summary>Opens the find bar scoped to one block (expands it if collapsed).</summary>
    private void OpenFind(long key)
    {
        _findKey = key;
        _collapsed.Remove(key);
        if (_selectedBlockKey != key)
            _selectedBlockKey = key;
        _findPanel.Visibility = Visibility.Visible;
        RecomputeFind();
        _findBox.Focus(FocusState.Programmatic);
        _findBox.SelectAll();
        _canvas.Invalidate();
    }

    private void CloseFind()
    {
        _findPanel.Visibility = Visibility.Collapsed;
        _findKey = -1;
        _findMatches.Clear();
        _findByLine = null;
        _findIndex = -1;
        _findCount.Text = "0/0";
        FocusTerminal();
        _canvas.Invalidate();
    }

    private void RecomputeFind()
    {
        _findMatches.Clear();
        _findIndex = -1;
        _findByLine = null;

        string query = _findBox?.Text ?? "";
        bool valid = true;
        if (_findKey >= 0 && query.Length > 0)
        {
            bool matchCase = _findCaseBtn.IsChecked == true;
            Regex? rx = null;
            if (_findRegexBtn.IsChecked == true)
            {
                try
                {
                    rx = new Regex(query, matchCase ? RegexOptions.None : RegexOptions.IgnoreCase);
                }
                catch (ArgumentException)
                {
                    valid = false;
                }
            }
            if (valid)
            {
                var emu = _session.Emulator;
                lock (emu.SyncRoot)
                {
                    if (BlockFromKey(_findKey) is { } block)
                    {
                        var buffer = emu.Buffer;
                        long dropped = buffer.DroppedLines;
                        var cmp = matchCase ? StringComparison.Ordinal : StringComparison.OrdinalIgnoreCase;
                        for (int abs = block.Start;
                             abs <= block.End && abs < buffer.TotalLines && _findMatches.Count < 2000;
                             abs++)
                        {
                            var (text, colMap) = LineTextWithMap(buffer, abs);
                            if (text.Length == 0)
                                continue;
                            if (rx != null)
                            {
                                foreach (Match m in rx.Matches(text))
                                {
                                    if (m.Length == 0)
                                        continue;
                                    _findMatches.Add((abs + dropped, colMap[m.Index], colMap[m.Index + m.Length - 1]));
                                    if (_findMatches.Count >= 2000)
                                        break;
                                }
                            }
                            else
                            {
                                int at = 0;
                                while ((at = text.IndexOf(query, at, cmp)) >= 0 && _findMatches.Count < 2000)
                                {
                                    _findMatches.Add((abs + dropped, colMap[at], colMap[at + query.Length - 1]));
                                    at += query.Length;
                                }
                            }
                        }
                    }
                }
            }
        }

        if (_findMatches.Count > 0)
            _findIndex = 0;
        _findCount.Text = !valid ? "bad rx" : $"{_findIndex + 1}/{_findMatches.Count}";
        if (_findIndex >= 0)
            ScrollToMatch();
        _canvas.Invalidate();
    }

    private void StepFind(int dir)
    {
        int count = _findMatches.Count;
        if (count == 0)
            return;
        _findIndex = ((_findIndex + dir) % count + count) % count;
        _findByLine = null; // re-flag the current match
        _findCount.Text = $"{_findIndex + 1}/{count}";
        ScrollToMatch();
        _canvas.Invalidate();
    }

    /// <summary>Brings the current match roughly a third down the viewport.</summary>
    private void ScrollToMatch()
    {
        if (_findIndex < 0 || _findIndex >= _findMatches.Count)
            return;
        var emu = _session.Emulator;
        lock (emu.SyncRoot)
        {
            long dropped = emu.Buffer.DroppedLines;
            int line = (int)(_findMatches[_findIndex].RawLine - dropped);
            if (line < 0)
                return;
            if (!emu.IsAlternateBuffer && _blockLayout.Count > 0)
            {
                foreach (var seg in _blockLayout)
                {
                    if (line < seg.Start || line >= seg.Start + seg.Count)
                        continue;
                    float px = seg.TopPx + (line - seg.Start) * _cellHeight;
                    float home = _inputPosition == 2 ? _histClipTop : PaddingPx;
                    float want = home + _rows * _cellHeight / 3f;
                    float delta = px - want;
                    _pinScrollPx = Math.Max(0, _pinScrollPx + (_inputPosition == 2 ? delta : -delta));
                    break;
                }
                return;
            }
            int scrollback = emu.Buffer.ScrollbackCount;
            _scrollOffset = Math.Clamp(scrollback - (line - Math.Max(1, _rows / 3)), 0, scrollback);
        }
    }

    /// <summary>Line text plus a char-index → cell-column map (wide runes and
    /// surrogate pairs make the two disagree).</summary>
    private static (string Text, List<int> ColMap) LineTextWithMap(ScreenBuffer buffer, int abs)
    {
        var line = buffer.GetAbsoluteLine(abs);
        var sb = new StringBuilder();
        var map = new List<int>();
        for (int c = 0; c < line.Cells.Length; c++)
        {
            ref readonly var cell = ref line.Cells[c];
            if ((cell.Flags & CellFlags.WideTrailing) != 0)
                continue;
            string s = cell.Rune == 0 ? " " : char.ConvertFromUtf32(cell.Rune);
            for (int k = 0; k < s.Length; k++)
                map.Add(c);
            sb.Append(s);
        }
        int len = sb.Length;
        while (len > 0 && sb[len - 1] == ' ')
            len--;
        sb.Length = len;
        if (map.Count > len)
            map.RemoveRange(len, map.Count - len);
        return (sb.ToString(), map);
    }

    private static void CopyText(string? text)
    {
        if (string.IsNullOrEmpty(text))
            return;
        var package = new DataPackage();
        package.SetText(text);
        Clipboard.SetContent(package);
        try { Clipboard.Flush(); } catch { }
    }

    /// <summary>One buffer line as trimmed text, from a start column.</summary>
    private static string LineText(ScreenBuffer buffer, int abs, int fromCol = 0)
    {
        var line = buffer.GetAbsoluteLine(abs);
        var sb = new StringBuilder();
        for (int c = fromCol; c < line.Cells.Length; c++)
        {
            ref readonly var cell = ref line.Cells[c];
            if ((cell.Flags & CellFlags.WideTrailing) != 0)
                continue;
            sb.Append(cell.Rune == 0 ? " " : char.ConvertFromUtf32(cell.Rune));
        }
        int len = sb.Length;
        while (len > 0 && sb[len - 1] == ' ')
            len--;
        sb.Length = len;
        return sb.ToString();
    }

    /// <summary>The line where the block's command input ends: the prompt-end
    /// line plus its soft-wrap continuation chain (long commands wrap).</summary>
    private static int CommandEndLine(ScreenBuffer buffer, int cmdLine, int end)
    {
        int i = cmdLine;
        while (i < end && i < buffer.TotalLines && buffer.GetAbsoluteLine(i).Wrapped)
            i++;
        return i;
    }

    /// <summary>The typed command of a block, without the prompt decoration
    /// when the shell reported a prompt-end mark (OSC 133;B).</summary>
    private string GetBlockCommand(int start, int end)
    {
        var emu = _session.Emulator;
        lock (emu.SyncRoot)
        {
            var buffer = emu.Buffer;
            int cmdLine = start;
            int cmdCol = 0;
            foreach (var (l, c) in emu.GetPromptEnds())
            {
                if (l >= start && l <= end)
                {
                    cmdLine = l;
                    cmdCol = c;
                    break;
                }
            }
            var sb = new StringBuilder();
            int last = CommandEndLine(buffer, cmdLine, end);
            for (int i = cmdLine; i <= last && i < buffer.TotalLines; i++)
                sb.Append(LineText(buffer, i, i == cmdLine ? cmdCol : 0));
            return sb.ToString().Trim();
        }
    }

    /// <summary>Everything a block printed below its command line(s).</summary>
    private string GetBlockOutput(int start, int end)
    {
        var emu = _session.Emulator;
        lock (emu.SyncRoot)
        {
            int cmdLine = start;
            foreach (var (l, _) in emu.GetPromptEnds())
            {
                if (l >= start && l <= end)
                {
                    cmdLine = l;
                    break;
                }
            }
            int from = CommandEndLine(emu.Buffer, cmdLine, end) + 1;
            return from > end ? "" : JoinLines(emu.Buffer, from, end);
        }
    }

    /// <summary>The whole block (prompt, command and output) as plain text.</summary>
    private string GetBlockText(int start, int end)
    {
        var emu = _session.Emulator;
        lock (emu.SyncRoot)
            return JoinLines(emu.Buffer, start, end);
    }

    /// <summary>A block as a fenced Markdown snippet, ready to share.</summary>
    private string GetBlockMarkdown(int start, int end)
    {
        string command = GetBlockCommand(start, end);
        string output = GetBlockOutput(start, end);
        var sb = new StringBuilder();
        sb.Append("```console\r\n");
        if (command.Length > 0)
            sb.Append("$ ").Append(command).Append("\r\n");
        if (output.Length > 0)
            sb.Append(output).Append("\r\n");
        sb.Append("```");
        return sb.ToString();
    }

    /// <summary>Lines joined with soft-wrap awareness, trailing blanks dropped.</summary>
    private static string JoinLines(ScreenBuffer buffer, int from, int to)
    {
        var sb = new StringBuilder();
        int lastContent = 0;
        for (int i = from; i <= to && i < buffer.TotalLines; i++)
        {
            string text = LineText(buffer, i);
            sb.Append(text);
            if (text.Length > 0)
                lastContent = sb.Length;
            if (i < to && !buffer.GetAbsoluteLine(i).Wrapped)
                sb.Append("\r\n");
        }
        sb.Length = lastContent; // drop trailing empty lines
        return sb.ToString();
    }

    // ---------------------------------------------------------------- history panel

    private Border _historyPanel = null!;
    private ListView _historyList = null!;
    private ToggleButton _historyThisDir = null!;
    private string _historyInserted = "";
    private double _historyListHeight = 170; // ~6 compact rows by default

    private Border BuildHistoryPanel()
    {
        _historyThisDir = new ToggleButton
        {
            Content = "This folder",
            FontSize = 11.5,
            Height = 28,
            Padding = new Thickness(9, 0, 9, 0),
            CornerRadius = new CornerRadius(5),
            BorderThickness = new Thickness(0),
            Background = TransparentBrush,
            Foreground = _overlayFgDim,
            IsTabStop = false,
            AllowFocusOnInteraction = false, // keep keyboard focus in the shell
            VerticalAlignment = VerticalAlignment.Center,
        };
        var tRes = _historyThisDir.Resources;
        tRes["ToggleButtonBackgroundPointerOver"] = _overlayHover;
        tRes["ToggleButtonBackgroundPressed"] = _overlayActive;
        tRes["ToggleButtonBackgroundChecked"] = _overlayAccent;
        tRes["ToggleButtonBackgroundCheckedPointerOver"] = _overlayAccent;
        tRes["ToggleButtonBackgroundCheckedPressed"] = _overlayAccent;
        tRes["ToggleButtonForegroundPointerOver"] = _overlayFg;
        tRes["ToggleButtonForegroundChecked"] = _overlayFg;
        tRes["ToggleButtonForegroundCheckedPointerOver"] = _overlayFg;
        tRes["ToggleButtonForegroundCheckedPressed"] = _overlayFg;
        tRes["ToggleButtonBorderBrushPointerOver"] = TransparentBrush;
        tRes["ToggleButtonBorderBrushChecked"] = TransparentBrush;
        tRes["ToggleButtonBorderBrushCheckedPointerOver"] = TransparentBrush;
        tRes["ToggleButtonBorderBrushCheckedPressed"] = TransparentBrush;
        _historyThisDir.Checked += (_, _) => RefreshHistory();
        _historyThisDir.Unchecked += (_, _) => RefreshHistory();

        var title = new TextBlock
        {
            Text = "HISTORY",
            FontSize = 10.5,
            CharacterSpacing = 80,
            Foreground = _overlayFgDim,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(4, 0, 0, 0),
        };

        var grip = new TextBlock
        {
            Text = "· · ·",
            FontSize = 11,
            Foreground = _overlayFgDim,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };

        var header = new Grid { ColumnSpacing = 6, Background = TransparentBrush, MinHeight = 22 };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.Children.Add(title);
        Grid.SetColumn(grip, 1);
        header.Children.Add(grip);
        Grid.SetColumn(_historyThisDir, 2);
        header.Children.Add(_historyThisDir);

        // Dragging the header resizes the list (up = taller).
        bool dragging = false;
        double dragStartY = 0, dragStartHeight = 0;
        header.PointerPressed += (_, e) =>
        {
            dragging = true;
            dragStartY = e.GetCurrentPoint(this).Position.Y;
            dragStartHeight = _historyListHeight;
            header.CapturePointer(e.Pointer);
            e.Handled = true;
        };
        header.PointerMoved += (_, e) =>
        {
            if (!dragging)
                return;
            double y = e.GetCurrentPoint(this).Position.Y;
            _historyListHeight = Math.Clamp(dragStartHeight + (dragStartY - y),
                72, Math.Max(120, _canvas.ActualHeight * 0.7));
            _historyList.MaxHeight = _historyListHeight;
            e.Handled = true;
        };
        header.PointerReleased += (_, e) =>
        {
            dragging = false;
            header.ReleasePointerCapture(e.Pointer);
            e.Handled = true;
        };
        header.PointerCaptureLost += (_, _) => dragging = false;

        _historyList = new ListView
        {
            SelectionMode = ListViewSelectionMode.Single,
            IsItemClickEnabled = true,
            MaxHeight = _historyListHeight,
            IsTabStop = false,
            AllowFocusOnInteraction = false,
        };
        // Compact, full-width rows: without Stretch the row grids shrink-wrap
        // and the folder/timestamp never reach the right edge.
        var containerStyle = new Style(typeof(ListViewItem))
        {
            BasedOn = Application.Current.Resources["RoundedListViewItem"] as Style,
        };
        containerStyle.Setters.Add(new Setter(Control.HorizontalContentAlignmentProperty, HorizontalAlignment.Stretch));
        containerStyle.Setters.Add(new Setter(Control.MinHeightProperty, 0d));
        containerStyle.Setters.Add(new Setter(Control.PaddingProperty, new Thickness(0)));
        containerStyle.Setters.Add(new Setter(FrameworkElement.MarginProperty, new Thickness(0, 0.5, 0, 0.5)));
        _historyList.ItemContainerStyle = containerStyle;
        _historyList.ItemContainerTransitions = new TransitionCollection();
        _historyList.SelectionChanged += (_, _) => PreviewHistorySelection();
        _historyList.ItemClick += (_, _) => CloseHistory(discardText: false);

        var stack = new StackPanel { Spacing = 6 };
        stack.Children.Add(header);
        stack.Children.Add(_historyList);

        // Docked sheet: spans the full pane width and sits flush against the
        // input bar (its bottom edge IS the input's rule) - not a floating card.
        var panel = new Border
        {
            HorizontalAlignment = HorizontalAlignment.Stretch,
            VerticalAlignment = VerticalAlignment.Bottom,
            Margin = new Thickness(0, 0, 0, 96),
            CornerRadius = new CornerRadius(0),
            BorderThickness = new Thickness(0, 1, 0, 0),
            Padding = new Thickness(16, 10, 16, 12),
            Background = _overlayBg,
            BorderBrush = _overlayBorder,
            Visibility = Visibility.Collapsed,
            Child = stack,
        };
        panel.PointerPressed += (_, args) => args.Handled = true;
        panel.PointerReleased += (_, args) => args.Handled = true;
        return panel;
    }

    /// <summary>Opens history when the prompt is empty and shell integration
    /// is active. Returns false to let the key flow to the shell instead.</summary>
    private bool TryOpenHistory()
    {
        if (_historyPanel.Visibility == Visibility.Visible)
            return false;

        // Something is running. Arrow Up belongs to it, not to us: an agent CLI
        // uses it to move around its own menus, and the shell is not at a
        // prompt to put a command on anyway.
        if (_foregroundBusy)
            return false;

        var emu = _session.Emulator;
        lock (emu.SyncRoot)
        {
            if (!emu.HasLivePromptInput || emu.PeekPendingCommand() != null)
            {
                // Opt-in diagnostics: this gate depends on the user's prompt
                // layout, which only reproduces on their machine.
                if (Environment.GetEnvironmentVariable("ZHARP_DEBUG_HISTORY") == "1")
                {
                    App.Log($"hist refuse: live={emu.HasLivePromptInput} " +
                            $"pending='{emu.PeekPendingCommand()}' cols={emu.Cols} " +
                            $"font={_fontSize} marks={emu.GetPromptMarks().Count}");
                }
                return false;
            }
        }
        if (HistoryStore.Instance.IsEmpty)
            return false;

        PositionHistoryPanel();

        _historyThisDir.IsChecked = false;
        _historyInserted = "";
        _historyPanel.Visibility = Visibility.Visible;
        RefreshHistory(); // selects the newest entry, which previews it at the prompt
        return true;
    }

    private (float Top, float Bottom)? LiveBlockPixelRange()
    {
        var emu = _session.Emulator;
        lock (emu.SyncRoot)
        {
            var marks = emu.GetPromptMarks();
            if (marks.Count == 0)
                return null;
            int contentEnd = emu.Buffer.ScrollbackCount + emu.CursorY;
            return BlockPixelRange(marks[^1], Math.Max(marks[^1], contentEnd));
        }
    }

    /// <summary>Keeps an open panel alive across zoom, font and window-size
    /// changes: re-dock at the input's new position and rebuild the rows at
    /// the new scale. A stale position would sit off-screen while still
    /// swallowing the Up/Down keys.</summary>
    private void RepositionHistoryOverlay()
    {
        if (_historyPanel == null || _historyPanel.Visibility != Visibility.Visible)
            return;
        PositionHistoryPanel();
        RefreshHistory();
    }

    /// <summary>Dismisses the panel (input-position switches change the whole
    /// geometry model; a fresh open is cleaner than a re-dock).</summary>
    private void DismissHistoryOverlay()
    {
        if (_historyPanel != null && _historyPanel.Visibility == Visibility.Visible)
            CloseHistory(discardText: false);
    }

    /// <summary>Docks the sheet flush against the input bar. Pinned modes are
    /// computed analytically from the CURRENT cell metrics (layout snapshots
    /// go stale for a frame after zoom changes); classic uses the last draw's
    /// block layout.</summary>
    private void PositionHistoryPanel()
    {
        float canvasH = (float)Math.Max(ActualHeight, 200);
        float cell = _cellHeight;
        bool dockBelow; // panel under the input (input near the top) or above
        float ruleY;
        if (_inputPosition is 1 or 2)
        {
            int liveCount = 1;
            var emu = _session.Emulator;
            lock (emu.SyncRoot)
            {
                var marks = emu.GetPromptMarks();
                if (marks.Count > 0)
                {
                    int contentEnd = emu.Buffer.ScrollbackCount + emu.CursorY;
                    liveCount = Math.Max(1, contentEnd - marks[^1] + 1);
                }
            }
            dockBelow = _inputPosition == 2;
            ruleY = dockBelow
                ? PaddingPx + cell + liveCount * cell + cell
                : canvasH - cell - liveCount * cell - cell;
        }
        else
        {
            // Classic: the input can sit anywhere. Dock above it when there
            // is room; on a fresh tab (input at the top) dock below instead.
            var range = LiveBlockPixelRange();
            float liveTop = range?.Top ?? canvasH - 70;
            dockBelow = liveTop - cell < PaddingPx + 60;
            ruleY = dockBelow ? (range?.Bottom ?? 60) + cell : liveTop - cell;
        }

        _historyList.MaxHeight = _historyListHeight;
        if (dockBelow)
        {
            _historyPanel.VerticalAlignment = VerticalAlignment.Top;
            _historyPanel.BorderThickness = new Thickness(0, 0, 0, 1);
            _historyPanel.Margin = new Thickness(0, Math.Clamp(ruleY, 0, canvasH - 160), 0, 0);
        }
        else
        {
            _historyPanel.VerticalAlignment = VerticalAlignment.Bottom;
            _historyPanel.BorderThickness = new Thickness(0, 1, 0, 0);
            _historyPanel.Margin = new Thickness(0, 0, 0, Math.Clamp(canvasH - ruleY, 40, canvasH - 100));
        }
    }

    /// <summary>Closes the panel; discard erases the previewed command from
    /// the prompt, otherwise it stays there for editing or Enter.</summary>
    private void CloseHistory(bool discardText)
    {
        if (discardText)
            EraseInserted();
        else
            _historyInserted = "";
        _historyPanel.Visibility = Visibility.Collapsed;
        FocusTerminal();
    }

    /// <summary>Keys routed here while the panel is open (focus never leaves
    /// the terminal). Returns false for keys the shell should still get.</summary>
    private bool HandleHistoryKey(VirtualKey key, bool anyModifier)
    {
        if (anyModifier)
            return false;
        int count = _historyList.Items.Count;
        switch (key)
        {
            // Newest sits at the BOTTOM, so Up moves visually up
            // toward older entries.
            case VirtualKey.Up when count > 0:
                _historyList.SelectedIndex = Math.Max(_historyList.SelectedIndex - 1, 0);
                _historyList.ScrollIntoView(_historyList.SelectedItem);
                return true;
            case VirtualKey.Down when count > 0:
                if (_historyList.SelectedIndex >= count - 1)
                {
                    CloseHistory(discardText: true); // below the newest = empty prompt again
                    return true;
                }
                _historyList.SelectedIndex++;
                _historyList.ScrollIntoView(_historyList.SelectedItem);
                return true;
            case VirtualKey.Enter:
                CloseHistory(discardText: false);
                _session.Send("\r"); // the command is already typed at the prompt
                return true;
            case VirtualKey.Tab:
                CloseHistory(discardText: false);
                return true;
            case VirtualKey.Escape:
                CloseHistory(discardText: true);
                return true;
        }
        return false;
    }

    /// <summary>Types the highlighted entry at the prompt, replacing whatever
    /// the previous preview typed - live, like classic shell history.</summary>
    private void PreviewHistorySelection()
    {
        if (_historyPanel.Visibility != Visibility.Visible)
            return;
        if ((_historyList.SelectedItem as FrameworkElement)?.Tag is not HistoryEntry entry)
            return;
        if (entry.Command == _historyInserted)
            return;
        var text = new StringBuilder();
        AppendErase(text);
        text.Append(entry.Command);
        _historyInserted = entry.Command;
        _session.Send(text.ToString());
    }

    private void EraseInserted()
    {
        if (_historyInserted.Length == 0)
            return;
        var text = new StringBuilder();
        AppendErase(text);
        _historyInserted = "";
        _session.Send(text.ToString());
    }

    /// <summary>One backspace (DEL, what the Backspace key sends) per
    /// displayed character of the last preview.</summary>
    private void AppendErase(StringBuilder text)
    {
        foreach (var _ in _historyInserted.EnumerateRunes())
            text.Append((char)0x7F);
    }

    private void RefreshHistory()
    {
        if (_historyPanel.Visibility != Visibility.Visible)
            return;
        string? dir = _historyThisDir.IsChecked == true ? _session.WorkingDirectory : null;
        var entries = HistoryStore.Instance.Query(null, dir, limit: 60);
        entries.Reverse(); // newest at the BOTTOM, adjacent to the prompt

        _historyList.Items.Clear();
        foreach (var entry in entries)
        {
            double z = _uiZoom;
            var row = new Grid { ColumnSpacing = 10, Padding = new Thickness(8 * z, 3 * z, 8 * z, 3 * z), Tag = entry };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

            var icon = new FontIcon
            {
                FontFamily = new FontFamily("ms-appx:///Assets/Fonts/tabler-icons.ttf#tabler-icons"),
                Glyph = char.ConvertFromUtf32(0xEB0F), // prompt chevron
                FontSize = 11 * z,
                Foreground = _overlayFgDim,
                VerticalAlignment = VerticalAlignment.Center,
            };
            row.Children.Add(icon);

            var command = new TextBlock
            {
                Text = entry.Command,
                FontSize = 13 * z,
                Foreground = _overlayFg,
                TextTrimming = TextTrimming.CharacterEllipsis,
                VerticalAlignment = VerticalAlignment.Center,
            };
            Grid.SetColumn(command, 1);
            row.Children.Add(command);

            if (entry.Directory is { Length: > 0 } d)
            {
                var dirText = new TextBlock
                {
                    Text = SessionItem.Abbreviate(d),
                    FontSize = 11 * z,
                    Foreground = _overlayFgDim,
                    MaxWidth = 200,
                    TextTrimming = TextTrimming.CharacterEllipsis,
                    VerticalAlignment = VerticalAlignment.Center,
                };
                Grid.SetColumn(dirText, 2);
                row.Children.Add(dirText);
            }

            // Timestamp last, in its own column - never truncated away.
            var time = new TextBlock
            {
                Text = RelativeTime(entry.When),
                FontSize = 11 * z,
                Foreground = _overlayFgDim,
                VerticalAlignment = VerticalAlignment.Center,
            };
            Grid.SetColumn(time, 3);
            row.Children.Add(time);

            // Hovering previews, exactly like keyboard navigation.
            int index = _historyList.Items.Count;
            row.PointerEntered += (_, _) =>
            {
                if (_historyList.SelectedIndex != index)
                    _historyList.SelectedIndex = index;
            };

            _historyList.Items.Add(row);
        }
        if (_historyList.Items.Count > 0)
        {
            _historyList.SelectedIndex = -1; // force a change notification
            _historyList.SelectedIndex = _historyList.Items.Count - 1;
            // ScrollIntoView before the first layout pass is a no-op (the
            // panel opens showing the TOP of the list): force a layout, then
            // scroll again on the next tick for the virtualized case.
            _historyList.UpdateLayout();
            _historyList.ScrollIntoView(_historyList.SelectedItem);
            DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () =>
            {
                if (_historyPanel.Visibility == Visibility.Visible && _historyList.Items.Count > 0)
                    _historyList.ScrollIntoView(_historyList.Items[^1]);
            });
        }
        else
        {
            CloseHistory(discardText: true);
        }
    }

    private static string RelativeTime(DateTimeOffset when)
    {
        var age = DateTimeOffset.Now - when;
        if (age < TimeSpan.FromMinutes(1)) return "just now";
        if (age < TimeSpan.FromHours(1)) return $"{(int)age.TotalMinutes}m ago";
        if (age < TimeSpan.FromHours(48)) return $"{(int)age.TotalHours}h ago";
        return $"{(int)age.TotalDays}d ago";
    }

    // ---------------------------------------------------------------- clipboard

    private void CopySelection()
    {
        string? text = GetSelectedText();
        if (string.IsNullOrEmpty(text))
            return;
        var package = new DataPackage();
        package.SetText(text);
        Clipboard.SetContent(package);
        try { Clipboard.Flush(); } catch { }
    }

    private string? GetSelectedText()
    {
        if (!_hasSelection)
            return null;

        var (start, end) = NormalizedSelection();
        var emu = _session.Emulator;
        var sb = new StringBuilder();
        lock (emu.SyncRoot)
        {
            var buffer = emu.Buffer;
            for (int lineIdx = start.Line; lineIdx <= end.Line && lineIdx < buffer.TotalLines; lineIdx++)
            {
                var line = buffer.GetAbsoluteLine(lineIdx);
                int from = lineIdx == start.Line ? start.Col : 0;
                int to = lineIdx == end.Line ? end.Col : line.Cells.Length - 1;
                from = Math.Clamp(from, 0, Math.Max(0, line.Cells.Length - 1));
                to = Math.Clamp(to, 0, line.Cells.Length - 1);

                int lineStart = sb.Length;
                for (int c = from; c <= to; c++)
                {
                    ref readonly var cell = ref line.Cells[c];
                    if ((cell.Flags & CellFlags.WideTrailing) != 0)
                        continue;
                    sb.Append(cell.Rune == 0 ? " " : char.ConvertFromUtf32(cell.Rune));
                }

                // Trim trailing blanks on each line.
                int len = sb.Length;
                while (len > lineStart && sb[len - 1] == ' ')
                    len--;
                sb.Length = len;

                if (lineIdx < end.Line && !line.Wrapped)
                    sb.Append("\r\n");
            }
        }
        return sb.ToString();
    }

    private async Task PasteFromClipboardAsync()
    {
        try
        {
            var content = Clipboard.GetContent();
            if (!content.Contains(StandardDataFormats.Text))
                return;
            string text = await content.GetTextAsync();
            if (string.IsNullOrEmpty(text))
                return;
            _cursorBlinkOn = true;
            ScrollToBottom();
            _session.Paste(text);
        }
        catch
        {
            // Clipboard access can fail transiently; ignore.
        }
    }

    // ---------------------------------------------------------------- focus

    private void OnGotFocus(object sender, RoutedEventArgs e)
    {
        _hasFocus = true;
        _cursorBlinkOn = true;
        _session.NotifyFocus(true);
        _canvas.Invalidate();
    }

    private void OnLostFocus(object sender, RoutedEventArgs e)
    {
        _hasFocus = false;
        _session.NotifyFocus(false);
        _canvas.Invalidate();
    }
}
