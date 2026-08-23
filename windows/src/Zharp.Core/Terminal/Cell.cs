namespace Zharp.Core.Terminal;

/// <summary>Style flags for a terminal cell.</summary>
[Flags]
public enum CellFlags : ushort
{
    None = 0,
    Bold = 1 << 0,
    Dim = 1 << 1,
    Italic = 1 << 2,
    Underline = 1 << 3,
    Blink = 1 << 4,
    Inverse = 1 << 5,
    Hidden = 1 << 6,
    Strikethrough = 1 << 7,
    DoubleUnderline = 1 << 8,

    /// <summary>This cell is the right half of a double-width character.</summary>
    WideTrailing = 1 << 9,
}

/// <summary>
/// A terminal color: default (scheme-defined), an indexed palette entry (0-255),
/// or a 24-bit RGB value. Packed into a single uint.
/// </summary>
public readonly struct TerminalColor : IEquatable<TerminalColor>
{
    private const uint KindDefault = 0u << 24;
    private const uint KindIndexed = 1u << 24;
    private const uint KindRgb = 2u << 24;

    public readonly uint Raw;

    private TerminalColor(uint raw) => Raw = raw;

    public static readonly TerminalColor Default = new(KindDefault);

    public static TerminalColor Indexed(int index) =>
        new(KindIndexed | (uint)(index & 0xFF));

    public static TerminalColor Rgb(int r, int g, int b) =>
        new(KindRgb | (uint)((r & 0xFF) << 16 | (g & 0xFF) << 8 | (b & 0xFF)));

    public bool IsDefault => (Raw >> 24) == 0;
    public bool IsIndexed => (Raw >> 24) == 1;
    public bool IsRgb => (Raw >> 24) == 2;

    public int Index => (int)(Raw & 0xFF);
    public uint RgbValue => Raw & 0xFFFFFF;

    public bool Equals(TerminalColor other) => Raw == other.Raw;
    public override bool Equals(object? obj) => obj is TerminalColor c && c.Raw == Raw;
    public override int GetHashCode() => (int)Raw;
    public static bool operator ==(TerminalColor a, TerminalColor b) => a.Raw == b.Raw;
    public static bool operator !=(TerminalColor a, TerminalColor b) => a.Raw != b.Raw;
}

/// <summary>One character cell of the terminal grid.</summary>
public struct Cell
{
    /// <summary>Unicode code point; 0 means an empty (blank) cell.</summary>
    public int Rune;
    public TerminalColor Fg;
    public TerminalColor Bg;
    public CellFlags Flags;

    public readonly bool IsBlank => Rune == 0 || Rune == ' ';
}

/// <summary>One row of cells plus line-level metadata.</summary>
public sealed class TerminalLine
{
    public Cell[] Cells;

    /// <summary>True if this line soft-wrapped into the next (no hard newline).</summary>
    public bool Wrapped;

    public TerminalLine(int cols)
    {
        Cells = new Cell[cols];
    }

    public TerminalLine(int cols, in Cell fill)
    {
        Cells = new Cell[cols];
        if (fill.Rune != 0 || fill.Bg != TerminalColor.Default || fill.Fg != TerminalColor.Default || fill.Flags != CellFlags.None)
            Array.Fill(Cells, fill);
    }

    public void Fill(in Cell fill)
    {
        Array.Fill(Cells, fill);
        Wrapped = false;
    }

    /// <summary>Fills [from, to) with the given cell. Bounds are clamped.</summary>
    public void FillRange(int from, int to, in Cell fill)
    {
        from = Math.Max(0, from);
        to = Math.Min(Cells.Length, to);
        for (int i = from; i < to; i++)
            Cells[i] = fill;
    }

    public void Resize(int cols)
    {
        if (cols == Cells.Length)
            return;
        var next = new Cell[cols];
        Array.Copy(Cells, next, Math.Min(cols, Cells.Length));
        Cells = next;
    }

    public bool IsEmpty()
    {
        foreach (ref readonly var c in Cells.AsSpan())
        {
            if (!c.IsBlank || c.Bg != TerminalColor.Default)
                return false;
        }
        return true;
    }
}
