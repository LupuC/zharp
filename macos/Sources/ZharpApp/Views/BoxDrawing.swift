import AppKit

/// Draws box-drawing (U+2500-257F) and block-element (U+2580-259F) characters
/// geometrically instead of as glyphs.
///
/// On Windows, Cascadia Mono ships these with cell-exact metrics, so vim
/// borders, htop bars and lazygit panes line up seamlessly. Most macOS
/// monospace faces (SF Mono included) do not cover the full range, and the
/// fallback font's are drawn at its own scale - visibly broken lines. Drawing
/// them to the cell rectangle restores the Windows look on any font.
enum BoxDrawing {

    /// True when `rune` is handled here rather than by the text renderer.
    static func handles(_ rune: Int) -> Bool {
        (0x2500...0x259F).contains(rune)
    }

    /// Line weight per side, in the order left, up, right, down.
    /// 0 = none, 1 = light, 2 = heavy, 3 = double.
    private static let lines: [Int: [Int]] = [
        0x2500: [1, 0, 1, 0], 0x2501: [2, 0, 2, 0],
        0x2502: [0, 1, 0, 1], 0x2503: [0, 2, 0, 2],
        0x250C: [0, 0, 1, 1], 0x250D: [0, 0, 2, 1], 0x250E: [0, 0, 1, 2], 0x250F: [0, 0, 2, 2],
        0x2510: [1, 0, 0, 1], 0x2511: [2, 0, 0, 1], 0x2512: [1, 0, 0, 2], 0x2513: [2, 0, 0, 2],
        0x2514: [0, 1, 1, 0], 0x2515: [0, 1, 2, 0], 0x2516: [0, 2, 1, 0], 0x2517: [0, 2, 2, 0],
        0x2518: [1, 1, 0, 0], 0x2519: [2, 1, 0, 0], 0x251A: [1, 2, 0, 0], 0x251B: [2, 2, 0, 0],
        0x251C: [0, 1, 1, 1], 0x2520: [0, 2, 1, 2], 0x2523: [0, 2, 2, 2],
        0x2524: [1, 1, 0, 1], 0x2528: [1, 2, 0, 2], 0x252B: [2, 2, 0, 2],
        0x252C: [1, 0, 1, 1], 0x2530: [1, 0, 1, 2], 0x2533: [2, 0, 2, 2],
        0x2534: [1, 1, 1, 0], 0x2538: [1, 2, 1, 0], 0x253B: [2, 2, 2, 0],
        0x253C: [1, 1, 1, 1], 0x2542: [1, 2, 1, 2], 0x254B: [2, 2, 2, 2],
        0x2550: [3, 0, 3, 0], 0x2551: [0, 3, 0, 3],
        0x2554: [0, 0, 3, 3], 0x2557: [3, 0, 0, 3],
        0x255A: [0, 3, 3, 0], 0x255D: [3, 3, 0, 0],
        0x2560: [0, 3, 3, 3], 0x2563: [3, 3, 0, 3],
        0x2566: [3, 0, 3, 3], 0x2569: [3, 3, 3, 0], 0x256C: [3, 3, 3, 3],
        0x2574: [1, 0, 0, 0], 0x2575: [0, 1, 0, 0],
        0x2576: [0, 0, 1, 0], 0x2577: [0, 0, 0, 1],
        0x2578: [2, 0, 0, 0], 0x2579: [0, 2, 0, 0],
        0x257A: [0, 0, 2, 0], 0x257B: [0, 0, 0, 2],
    ]

    /// Fractions of the cell filled, for the eighth blocks and shades.
    /// (edge, amount) where edge is .lower/.left/.upper/.right.
    private enum Edge { case lower, left, upper, right, full }

    private static let blocks: [Int: (Edge, CGFloat)] = [
        0x2580: (.upper, 1.0 / 2),
        0x2581: (.lower, 1.0 / 8), 0x2582: (.lower, 2.0 / 8), 0x2583: (.lower, 3.0 / 8),
        0x2584: (.lower, 4.0 / 8), 0x2585: (.lower, 5.0 / 8), 0x2586: (.lower, 6.0 / 8),
        0x2587: (.lower, 7.0 / 8), 0x2588: (.full, 1.0),
        0x2589: (.left, 7.0 / 8), 0x258A: (.left, 6.0 / 8), 0x258B: (.left, 5.0 / 8),
        0x258C: (.left, 4.0 / 8), 0x258D: (.left, 3.0 / 8), 0x258E: (.left, 2.0 / 8),
        0x258F: (.left, 1.0 / 8),
        0x2590: (.right, 1.0 / 2),
        0x2594: (.upper, 1.0 / 8), 0x2595: (.right, 1.0 / 8),
    ]

    /// Draws one character into its cell. Returns false when the rune is not
    /// covered here, so the caller falls back to the text renderer.
    @discardableResult
    static func draw(_ rune: Int, in cell: CGRect, color: NSColor, context ctx: CGContext) -> Bool {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setFillColor(color.cgColor)
        ctx.setShouldAntialias(false)

        if let (edge, amount) = blocks[rune] {
            ctx.fill(blockRect(edge: edge, amount: amount, in: cell))
            return true
        }

        // Shade blocks: a stippled fill reads better than a solid grey.
        if rune >= 0x2591 && rune <= 0x2593 {
            let alpha: CGFloat = rune == 0x2591 ? 0.25 : (rune == 0x2592 ? 0.5 : 0.75)
            ctx.setFillColor(color.withAlphaComponent(alpha).cgColor)
            ctx.fill(cell)
            return true
        }

        guard let sides = lines[rune] else { return false }

        // Light strokes are one device pixel, heavy ones twice that, scaled up
        // with the font so the weight tracks the text.
        let unit = max(1, (cell.height / 14).rounded())
        let midX = (cell.midX - unit / 2).rounded()
        let midY = (cell.midY - unit / 2).rounded()

        func stroke(_ weight: Int, _ rect: (CGFloat) -> CGRect) {
            if weight == 0 { return }
            if weight == 3 {
                // Double lines: two light strokes straddling the center.
                ctx.fill(rect(-unit * 1.5))
                ctx.fill(rect(unit * 1.5))
            } else {
                ctx.fill(rect(0).insetBy(dx: 0, dy: 0)
                    .applying(weight: weight, unit: unit))
            }
        }

        // left / right run to the cell edges through the center.
        stroke(sides[0]) { offset in
            CGRect(x: cell.minX, y: midY + offset, width: cell.width / 2 + unit, height: unit)
        }
        stroke(sides[2]) { offset in
            CGRect(x: cell.midX - unit, y: midY + offset,
                   width: cell.width / 2 + unit, height: unit)
        }
        stroke(sides[1]) { offset in
            CGRect(x: midX + offset, y: cell.minY, width: unit, height: cell.height / 2 + unit)
        }
        stroke(sides[3]) { offset in
            CGRect(x: midX + offset, y: cell.midY - unit,
                   width: unit, height: cell.height / 2 + unit)
        }
        return true
    }

    private static func blockRect(edge: Edge, amount: CGFloat, in cell: CGRect) -> CGRect {
        switch edge {
        case .full:
            return cell
        case .lower:
            let h = (cell.height * amount).rounded()
            return CGRect(x: cell.minX, y: cell.maxY - h, width: cell.width, height: h)
        case .upper:
            return CGRect(x: cell.minX, y: cell.minY, width: cell.width,
                          height: (cell.height * amount).rounded())
        case .left:
            return CGRect(x: cell.minX, y: cell.minY,
                          width: (cell.width * amount).rounded(), height: cell.height)
        case .right:
            let w = (cell.width * amount).rounded()
            return CGRect(x: cell.maxX - w, y: cell.minY, width: w, height: cell.height)
        }
    }
}

private extension CGRect {
    /// Thickens a one-unit stroke to the given weight, growing about its center.
    func applying(weight: Int, unit: CGFloat) -> CGRect {
        guard weight == 2 else { return self }
        return height <= unit
            ? CGRect(x: minX, y: minY - unit / 2, width: width, height: unit * 2)
            : CGRect(x: minX - unit / 2, y: minY, width: unit * 2, height: height)
    }
}
