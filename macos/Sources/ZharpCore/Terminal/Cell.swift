import Foundation

/// Style flags for a terminal cell.
public struct CellFlags: OptionSet, Hashable, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let none            = CellFlags([])
    public static let bold            = CellFlags(rawValue: 1 << 0)
    public static let dim             = CellFlags(rawValue: 1 << 1)
    public static let italic          = CellFlags(rawValue: 1 << 2)
    public static let underline       = CellFlags(rawValue: 1 << 3)
    public static let blink           = CellFlags(rawValue: 1 << 4)
    public static let inverse         = CellFlags(rawValue: 1 << 5)
    public static let hidden          = CellFlags(rawValue: 1 << 6)
    public static let strikethrough   = CellFlags(rawValue: 1 << 7)
    public static let doubleUnderline = CellFlags(rawValue: 1 << 8)

    /// This cell is the right half of a double-width character.
    public static let wideTrailing    = CellFlags(rawValue: 1 << 9)
}

/// A terminal color: default (scheme-defined), an indexed palette entry (0-255),
/// or a 24-bit RGB value. Packed into a single UInt32.
public struct TerminalColor: Equatable, Hashable, Sendable {
    private static let kindDefault: UInt32 = 0 << 24
    private static let kindIndexed: UInt32 = 1 << 24
    private static let kindRgb: UInt32 = 2 << 24

    public let raw: UInt32

    private init(_ raw: UInt32) { self.raw = raw }

    public static let `default` = TerminalColor(kindDefault)

    public static func indexed(_ index: Int) -> TerminalColor {
        TerminalColor(kindIndexed | UInt32(index & 0xFF))
    }

    public static func rgb(_ r: Int, _ g: Int, _ b: Int) -> TerminalColor {
        TerminalColor(kindRgb | UInt32(((r & 0xFF) << 16) | ((g & 0xFF) << 8) | (b & 0xFF)))
    }

    public var isDefault: Bool { (raw >> 24) == 0 }
    public var isIndexed: Bool { (raw >> 24) == 1 }
    public var isRgb: Bool { (raw >> 24) == 2 }

    public var index: Int { Int(raw & 0xFF) }
    public var rgbValue: UInt32 { raw & 0xFFFFFF }
}

/// One character cell of the terminal grid.
public struct Cell: Equatable, Sendable {
    /// Unicode scalar value; 0 means an empty (blank) cell.
    public var rune: Int
    public var fg: TerminalColor
    public var bg: TerminalColor
    public var flags: CellFlags

    public init(rune: Int = 0,
                fg: TerminalColor = .default,
                bg: TerminalColor = .default,
                flags: CellFlags = .none) {
        self.rune = rune
        self.fg = fg
        self.bg = bg
        self.flags = flags
    }

    public var isBlank: Bool { rune == 0 || rune == 32 }
}

/// One row of cells plus line-level metadata.
public final class TerminalLine {
    public var cells: [Cell]

    /// True if this line soft-wrapped into the next (no hard newline).
    public var wrapped: Bool = false

    public init(cols: Int) {
        cells = Array(repeating: Cell(), count: max(0, cols))
    }

    public init(cols: Int, fill: Cell) {
        let blank = Cell()
        cells = Array(repeating: fill == blank ? blank : fill, count: max(0, cols))
    }

    public func fill(_ value: Cell) {
        for i in cells.indices { cells[i] = value }
        wrapped = false
    }

    /// Fills [from, to) with the given cell. Bounds are clamped.
    public func fillRange(_ from: Int, _ to: Int, _ value: Cell) {
        let lo = max(0, from)
        let hi = min(cells.count, to)
        if lo >= hi { return }
        for i in lo..<hi { cells[i] = value }
    }

    public func resize(cols: Int) {
        if cols == cells.count { return }
        if cols < cells.count {
            cells.removeLast(cells.count - cols)
        } else {
            cells.append(contentsOf: Array(repeating: Cell(), count: cols - cells.count))
        }
    }

    public func isEmpty() -> Bool {
        for c in cells where !c.isBlank || c.bg != .default {
            return false
        }
        return true
    }
}
