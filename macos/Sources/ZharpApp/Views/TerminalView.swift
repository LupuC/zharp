import AppKit
import CoreText
import ZharpCore

/// The terminal surface: renders a `TerminalSession`'s screen with Core Text on
/// a layer-backed view (the counterpart of the Windows build's Win2D canvas)
/// and translates keyboard/mouse input into VT sequences.
final class TerminalView: NSView {
    private static let defaultFontFamily = "SF Mono"
    private static let paddingPx: CGFloat = 8
    private static let minFontSize: Double = 7
    private static let maxFontSize: Double = 36
    private static let defaultFontSize: Double = 13

    let session: TerminalSession
    private var palette = Palette.campbell()

    /// Normal / bold / italic / bold-italic, indexed by the same bit pattern
    /// the Windows renderer uses.
    private var fonts = [CTFont?](repeating: nil, count: 4)
    var cellWidth: CGFloat = 0
    var cellHeight: CGFloat = 0
    private var baseline: CGFloat = 0
    private var fontSize: Double = defaultFontSize
    private var fontFamily = TerminalView.defaultFontFamily

    /// DECSCUSR-style code used when the application hasn't chosen a cursor:
    /// 0 block, 3 underline, 5 bar.
    var defaultCursorStyleCode = 0

    /// Returns true for key combos reserved as app shortcuts. Those must be left
    /// unhandled here so the window's menu/key handling receives them instead of
    /// the shell.
    var isReservedShortcut: ((NSEvent) -> Bool)?

    private var cols = 120
    private var rows = 30
    private var scrollOffset = 0
    private var inputPosition = 0 // 0 = classic top, 1 = pinned bottom, 2 = pinned top (blocks)
    private var alignPad = 0      // rows the content is shifted down (bottom mode)
    var pinScrollPx: CGFloat = 0
    var blockLayout: [(start: Int, count: Int, topPx: CGFloat)] = []

    private var lastScrollbackCount = 0
    private var invalidatePending = false

    private var cursorBlinkOn = true
    private var hasFocus = false
    private var blinkTimer: Timer?

    private var selecting = false
    private var hasSelection = false
    private var selAnchor = (line: 0, col: 0)
    private var selFocus = (line: 0, col: 0)

    private var uiZoom: Double = 1.0
    private var disposed = false

    // ---------------------------------------------------------------- blocks
    /// Blocks the user collapsed, by drop-stable key.
    var collapsedKeys: Set<Int64> = []
    /// The highlighted block, or -1. Cleared by typing and by Escape.
    var selectedBlockKey: Int64 = -1
    /// The block whose hover chip is showing.
    var hoverChipKey: Int64 = -1
    /// Where the pinned history is clipped, recomputed on every pinned draw and
    /// read back by block jumping and find scrolling.
    var histClipTop: CGFloat = 0
    var overlay = OverlayColors.make(Palette.campbell())

    /// Resolves a key event to a terminal-scoped block action, or nil.
    var resolveBlockShortcut: ((NSEvent) -> String?)?
    /// The user's binding for a block action, for the menu accelerators.
    var blockShortcutText: ((String) -> String?)?

    // Find within block.
    var findKey: Int64 = -1
    var findMatches: [(rawLine: Int64, from: Int, to: Int)] = []
    var findIndex = -1
    var findByLine: [Int: [(from: Int, to: Int, current: Bool)]]?
    var findByLineDropped: Int64 = -1
    var findPanel: OverlayPanel?
    var findField: FindTextField?
    var findCounter: NSTextField?
    var findCaseToggle: OverlayButton?
    var findRegexToggle: OverlayButton?
    var chipButton: OverlayButton?

    // Command history sheet.
    var historyPanel: HistoryPanelView?
    /// Default list height: about six compact rows.
    var historyListHeight: CGFloat = 170
    var historyInserted = ""
    var historyIndex = -1
    var historyRowCount = 0
    var historyFolderOnly = false

    var uiZoomValue: Double { uiZoom }

    // Per-row scratch buffers, sized to the column count.
    private var fgRow: [UInt32] = []
    private var bgRow: [UInt32] = []
    private var bgDefaultRow: [Bool] = []

    init(session: TerminalSession, fontSize: Double = TerminalView.defaultFontSize,
         fontFamily: String? = nil) {
        self.session = session
        self.fontSize = min(max(fontSize, Self.minFontSize), Self.maxFontSize)
        if let fontFamily, !fontFamily.trimmingCharacters(in: .whitespaces).isEmpty {
            self.fontFamily = fontFamily
        }
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        // Redraw only the damaged rows on resize, and keep glyphs crisp when
        // the window moves between displays of different scale.
        layerContentsRedrawPolicy = .onSetNeedsDisplay

        rebuildTypography()

        session.addOutputObserver { [weak self] in self?.onOutputArrived() }
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    // ---------------------------------------------------------------- lifecycle

    private var hoverTracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        // .mouseMoved drives the block hover chip; .inVisibleRect keeps it in
        // step with scrolling and resizing without rebuilding on every frame.
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .mouseMoved,
                                            .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            startBlinking()
            updateGridSize()
            focusTerminal()
        } else {
            blinkTimer?.invalidate()
            blinkTimer = nil
        }
    }

    private func startBlinking() {
        blinkTimer?.invalidate()
        let timer = Timer(timeInterval: 0.53, repeats: true) { [weak self] _ in
            guard let self, self.hasFocus else { return }
            self.cursorBlinkOn.toggle()
            self.setNeedsDisplay(self.bounds)
        }
        RunLoop.main.add(timer, forMode: .common)
        blinkTimer = timer
    }

    func dispose() {
        if disposed { return }
        disposed = true
        // Observers are cleared by the session when the tab closes.
        blinkTimer?.invalidate()
        blinkTimer = nil
        removeFromSuperview()
    }

    func focusTerminal() {
        window?.makeFirstResponder(self)
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    // ---------------------------------------------------------------- typography & layout

    private func rebuildTypography() {
        let size = CGFloat(fontSize * uiZoom)
        let family = fontFamily

        func make(bold: Bool, italic: Bool) -> CTFont {
            var traits: CTFontSymbolicTraits = []
            if bold { traits.insert(.traitBold) }
            if italic { traits.insert(.traitItalic) }
            let base = NSFont(name: family, size: size)
                ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            if traits.isEmpty { return base as CTFont }
            return CTFontCreateCopyWithSymbolicTraits(base as CTFont, size, nil, traits, traits)
                ?? (base as CTFont)
        }

        fonts[0] = make(bold: false, italic: false)
        fonts[1] = make(bold: true, italic: false)
        fonts[2] = make(bold: false, italic: true)
        fonts[3] = make(bold: true, italic: true)

        // Cell metrics come from the advance of a run of digits, exactly as the
        // Windows renderer measures "0000000000" - it keeps a proportional
        // fallback font from throwing the grid off.
        let regular = fonts[0]!
        let probe = NSAttributedString(string: "0000000000",
                                       attributes: [.font: regular as Any])
        let line = CTLineCreateWithAttributedString(probe)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        cellWidth = CGFloat(width) / 10.0

        let ascent = CTFontGetAscent(regular)
        let descent = CTFontGetDescent(regular)
        let leading = CTFontGetLeading(regular)
        cellHeight = ceil(ascent + descent + leading)
        baseline = ceil(ascent)

        updateGridSize()
    }

    private func pickFont(_ flags: CellFlags) -> CTFont {
        let index = (flags.contains(.bold) ? 1 : 0) | (flags.contains(.italic) ? 2 : 0)
        return fonts[index] ?? fonts[0]!
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateGridSize()
        repositionHistoryOverlay()
    }

    private func updateGridSize() {
        guard cellWidth > 0, bounds.width > 0, bounds.height > 0 else { return }

        let w = bounds.width - 2 * Self.paddingPx
        let h = bounds.height - 2 * Self.paddingPx
        let newCols = max(2, Int(w / cellWidth))
        let newRows = max(2, Int(h / cellHeight))

        if !session.isStarted {
            cols = newCols
            rows = newRows
            session.ensureStarted(cols: newCols, rows: newRows)
        } else if newCols != cols || newRows != rows {
            cols = newCols
            rows = newRows
            session.resize(cols: newCols, rows: newRows)
        }
        setNeedsDisplay(bounds)
    }

    /// Swaps the color scheme (theme change) and repaints.
    func setPalette(_ palette: Palette) {
        self.palette = palette
        overlay = OverlayColors.make(palette)
        // Built-in control visuals inside this view - the find field's caret,
        // its focus ring, and any menu popped from here - follow the TERMINAL
        // palette rather than the app chrome.
        appearance = NSAppearance(named: overlay.isDark ? .darkAqua : .aqua)
        refreshOverlayColors()
        setNeedsDisplay(bounds)
    }

    /// Whole-UI zoom factor. This view is sized in real points; the zoom is
    /// realized purely by scaling the font size, so text is freshly rasterized
    /// rather than bitmap-stretched.
    func setUiZoom(_ zoom: Double) {
        let zoom = min(max(zoom, 0.5), 3.0)
        if abs(uiZoom - zoom) < 0.001 { return }
        uiZoom = zoom
        rebuildTypography()
        repositionHistoryOverlay()
    }

    /// input position: 0 classic top, 1 pinned bottom, 2 pinned top.
    func setInputPosition(_ mode: Int) {
        if inputPosition == mode { return }
        inputPosition = mode
        dismissHistoryOverlay()
        pinScrollPx = 0
        if scrollOffset < 0 { scrollOffset = 0 }
        setNeedsDisplay(bounds)
    }

    /// Applies appearance settings live (font family/size, default cursor).
    func applyAppearance(fontFamily: String?, fontSize: Double, cursorStyleCode: Int) {
        defaultCursorStyleCode = cursorStyleCode
        if let fontFamily, !fontFamily.trimmingCharacters(in: .whitespaces).isEmpty {
            self.fontFamily = fontFamily
        }
        self.fontSize = min(max(fontSize, Self.minFontSize), Self.maxFontSize)
        rebuildTypography()
        repositionHistoryOverlay()
    }

    private func changeFontSize(_ delta: Double) {
        let next = min(max(delta == 0 ? Self.defaultFontSize : fontSize + delta,
                           Self.minFontSize), Self.maxFontSize)
        if abs(next - fontSize) < 0.1 { return }
        fontSize = next
        rebuildTypography()
        repositionHistoryOverlay()
    }

    // ---------------------------------------------------------------- output pump

    private func onOutputArrived() {
        // Coalesce: heavy output must never flood the main queue.
        if invalidatePending { return }
        invalidatePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.invalidatePending = false
            self.setNeedsDisplay(self.bounds)
        }
    }

    // ---------------------------------------------------------------- rendering

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        // Fully transparent surface: the chrome wash behind (the same color as
        // the palette background by design) is the single translucency layer,
        // so the opacity slider and the vibrancy blur work without
        // double-covering.
        context.clear(dirtyRect)
        guard cellWidth > 0 else { return }

        context.saveGState()
        defer { context.restoreGState() }
        context.setShouldAntialias(true)
        context.setAllowsFontSmoothing(true)

        let emu = session.emulator
        emu.syncRoot.lock()
        defer { emu.syncRoot.unlock() }

        let rows = emu.rows
        let cols = emu.cols
        let buffer = emu.buffer
        let scrollback = buffer.scrollbackCount

        if emu.isAlternateBuffer {
            scrollOffset = 0
        } else {
            // Keep the viewport pinned to content while scrolled up.
            if scrollOffset > 0 && scrollback > lastScrollbackCount {
                scrollOffset += scrollback - lastScrollbackCount
            }
            scrollOffset = min(max(scrollOffset, 0), scrollback)
        }
        lastScrollbackCount = scrollback

        if fgRow.count < cols {
            fgRow = [UInt32](repeating: 0, count: cols)
            bgRow = [UInt32](repeating: 0, count: cols)
            bgDefaultRow = [Bool](repeating: false, count: cols)
        }

        let (selStart, selEnd) = normalizedSelection()

        // Find matches are keyed by raw line so they survive trimming; rebuild
        // the per-line lookup whenever the buffer has dropped lines since.
        if !findMatches.isEmpty {
            let droppedNow = buffer.droppedLines
            if findByLine == nil || findByLineDropped != droppedNow {
                var map: [Int: [(from: Int, to: Int, current: Bool)]] = [:]
                findByLineDropped = droppedNow
                for (i, match) in findMatches.enumerated() {
                    let abs = Int(match.rawLine - droppedNow)
                    if abs < 0 { continue }
                    map[abs, default: []].append((match.from, match.to, i == findIndex))
                }
                findByLine = map
            }
        } else {
            findByLine = nil
        }

        // Once a session has prompt marks EVERY input position renders as
        // blocks - classic included, where the whole stack scrolls as one.
        if !emu.isAlternateBuffer {
            let marks = emu.getPromptMarks()
            if !marks.isEmpty {
                scrollOffset = 0
                drawBlocks(context, emu, buffer, rows: rows, cols: cols,
                           selStart: selStart, selEnd: selEnd, marks: marks,
                           newestFirst: inputPosition == 2)
                positionOverlays()
                return
            }
        }
        blockLayout.removeAll(keepingCapacity: true)
        positionOverlays()

        // Pinned-bottom fallback for shells without prompt marks: a short
        // screen bottom-aligns (main buffer only).
        alignPad = 0
        if inputPosition == 1 && !emu.isAlternateBuffer && scrollOffset == 0 {
            var used = emu.cursorY + 1
            var r = rows - 1
            while r >= used {
                if !buffer.screenLine(r).isEmpty() {
                    used = r + 1
                    break
                }
                r -= 1
            }
            alignPad = rows - used
        }

        let firstAbs = scrollback - scrollOffset

        for r in 0..<rows {
            if r + alignPad >= rows { break } // rows pushed off the bottom by the pad
            let abs = firstAbs + r
            if abs < 0 || abs >= buffer.totalLines { continue }
            drawBufferLine(context, buffer, abs: abs,
                           y: Self.paddingPx + CGFloat(r + alignPad) * cellHeight,
                           cols: cols, selStart: selStart, selEnd: selEnd)
        }

        drawCursor(context, emu, buffer, scrollback: scrollback, firstAbs: firstAbs,
                   rows: rows, cols: cols)
    }

    /// Draws one buffer line (backgrounds, selection, text) at y.
    private func drawBufferLine(_ ctx: CGContext, _ buffer: ScreenBuffer, abs: Int, y: CGFloat,
                                cols: Int, selStart: (line: Int, col: Int),
                                selEnd: (line: Int, col: Int)) {
        let line = buffer.absoluteLine(abs)
        let cells = line.cells
        let n = min(cols, cells.count)
        if n <= 0 { return }

        for c in 0..<n {
            let r = palette.resolve(cells[c])
            fgRow[c] = r.fg
            bgRow[c] = r.bg
            bgDefaultRow[c] = r.bgIsDefault
        }

        // Background runs (only where they differ from the panel background).
        var runStart = -1
        var runBg: UInt32 = 0
        for c in 0...n {
            let paint = c < n && !bgDefaultRow[c]
            let bg = paint ? bgRow[c] : 0
            if runStart >= 0 && (!paint || bg != runBg) {
                ctx.setFillColor(cgColor(runBg))
                ctx.fill(CGRect(x: Self.paddingPx + CGFloat(runStart) * cellWidth, y: y,
                                width: CGFloat(c - runStart) * cellWidth, height: cellHeight))
                runStart = -1
            }
            if paint && runStart < 0 {
                runStart = c
                runBg = bg
            }
        }

        // Find matches, under the text selection so an active selection wins.
        if let found = findByLine?[abs] {
            for (from, to, current) in found where from < cols {
                let last = Swift.min(to, cols - 1)
                if last < from { continue }
                ctx.setFillColor(cgColor(palette.cursorColor, alpha: current ? 0x8C : 0x46))
                ctx.fill(CGRect(x: Self.paddingPx + CGFloat(from) * cellWidth, y: y,
                                width: CGFloat(last - from + 1) * cellWidth, height: cellHeight))
            }
        }

        // Selection highlight.
        if hasSelection && abs >= selStart.line && abs <= selEnd.line {
            var from = abs == selStart.line ? selStart.col : 0
            var to = abs == selEnd.line ? selEnd.col : cols - 1
            from = min(max(from, 0), cols - 1)
            to = min(max(to, 0), cols - 1)
            if to >= from {
                ctx.setFillColor(cgColor(palette.selectionColor, alpha: 0x46))
                ctx.fill(CGRect(x: Self.paddingPx + CGFloat(from) * cellWidth, y: y,
                                width: CGFloat(to - from + 1) * cellWidth, height: cellHeight))
            }
        }

        drawTextRuns(ctx, cells: cells, n: n, y: y)
    }

    /// Renders the buffer as command blocks. Once a session has prompt marks
    /// every input position uses this: pinned-top stacks history newest-first
    /// under a fixed live-input bar, pinned-bottom keeps chronological order
    /// with the live input glued to the bottom edge, and classic scrolls the
    /// whole stack together.
    private func drawBlocks(_ ctx: CGContext, _ emu: TerminalEmulator, _ buffer: ScreenBuffer,
                            rows: Int, cols: Int, selStart: (line: Int, col: Int),
                            selEnd: (line: Int, col: Int), marks: [Int], newestFirst: Bool) {
        let scrollback = buffer.scrollbackCount
        let contentEnd = scrollback + emu.cursorY // the live input line
        let cursorAbs = contentEnd
        let dropped = buffer.droppedLines

        blockLayout.removeAll(keepingCapacity: true)

        var segments: [(start: Int, count: Int)] = []
        if newestFirst {
            segments.append((marks[marks.count - 1],
                             Swift.max(1, contentEnd - marks[marks.count - 1] + 1)))
            var i = marks.count - 2
            while i >= 0 {
                segments.append((marks[i], Swift.max(1, marks[i + 1] - marks[i])))
                i -= 1
            }
            if marks[0] > 0 { segments.append((0, marks[0])) }
        } else {
            if marks[0] > 0 { segments.append((0, marks[0])) }
            for i in 0..<(marks.count - 1) {
                segments.append((marks[i], Swift.max(1, marks[i + 1] - marks[i])))
            }
            segments.append((marks[marks.count - 1],
                             Swift.max(1, contentEnd - marks[marks.count - 1] + 1)))
        }

        // Which segment holds the live prompt. Marks can go momentarily stale
        // after an alt-screen round trip, so fall back to the end the live
        // block occupies rather than losing the input bar entirely.
        var liveIdx = -1
        for (i, seg) in segments.enumerated()
        where cursorAbs >= seg.start && cursorAbs < seg.start + seg.count {
            liveIdx = i
            break
        }
        if liveIdx < 0 { liveIdx = newestFirst ? 0 : segments.count - 1 }

        // The live block is never collapsible.
        var collapsed = [Bool](repeating: false, count: segments.count)
        var effRows = [Int](repeating: 0, count: segments.count)
        for i in segments.indices {
            collapsed[i] = i != liveIdx && segments[i].count > 1
                && collapsedKeys.contains(Int64(segments[i].start) + dropped)
            effRows[i] = collapsed[i] ? 2 : segments[i].count
        }

        let cell = cellHeight
        let gap = cell * 0.7
        let canvasH = bounds.height

        if inputPosition != 0 {
            drawPinnedStack(ctx, emu, buffer, segments: segments, collapsed: collapsed,
                            effRows: effRows, liveIdx: liveIdx, newestFirst: newestFirst,
                            cols: cols, cursorAbs: cursorAbs, dropped: dropped,
                            gap: gap, cell: cell, canvasH: canvasH,
                            selStart: selStart, selEnd: selEnd)
        } else {
            drawClassicStack(ctx, emu, buffer, segments: segments, collapsed: collapsed,
                             effRows: effRows, liveIdx: liveIdx, rows: rows, cols: cols,
                             cursorAbs: cursorAbs, dropped: dropped,
                             gap: gap, cell: cell, canvasH: canvasH,
                             selStart: selStart, selEnd: selEnd)
        }
    }

    /// Pinned layouts: the live block and its rule are fixed at one edge, and
    /// only the history scrolls, clipped on the other side of the rule.
    private func drawPinnedStack(_ ctx: CGContext, _ emu: TerminalEmulator, _ buffer: ScreenBuffer,
                                 segments: [(start: Int, count: Int)], collapsed: [Bool],
                                 effRows: [Int], liveIdx: Int, newestFirst: Bool,
                                 cols: Int, cursorAbs: Int, dropped: Int64,
                                 gap: CGFloat, cell: CGFloat, canvasH: CGFloat,
                                 selStart: (line: Int, col: Int),
                                 selEnd: (line: Int, col: Int)) {
        let (liveStart, liveCount) = segments[liveIdx]
        let livePx = CGFloat(liveCount) * cell
        let width = bounds.width

        let liveTop: CGFloat
        let ruleY: CGFloat
        let clipTop: CGFloat
        let clipBottom: CGFloat
        if newestFirst {
            liveTop = Self.paddingPx + cell
            ruleY = liveTop + livePx + cell
            clipTop = ruleY + gap / 2
            clipBottom = canvasH - 4
        } else {
            liveTop = canvasH - cell - livePx
            ruleY = liveTop - cell
            clipTop = Self.paddingPx
            clipBottom = ruleY - gap / 2
        }
        histClipTop = clipTop

        var histPx: CGFloat = 0
        var histCount = 0
        for i in segments.indices where i != liveIdx {
            histPx += CGFloat(effRows[i]) * cell
            histCount += 1
        }
        if histCount > 1 { histPx += CGFloat(histCount - 1) * gap }
        let avail = Swift.max(0, clipBottom - clipTop)
        pinScrollPx = Swift.min(Swift.max(pinScrollPx, 0), Swift.max(0, histPx - avail))

        var y = newestFirst ? clipTop - pinScrollPx : clipBottom - histPx + pinScrollPx

        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: clipTop, width: width, height: avail))
        var drewOne = false
        for i in segments.indices {
            if i == liveIdx { continue }
            let (start, count) = segments[i]
            if drewOne {
                let sepY = y + gap / 2
                if sepY > clipTop - cell && sepY < clipBottom + cell {
                    drawHairline(ctx, at: sepY, width: width)
                }
                y += gap
            }
            drewOne = true
            blockLayout.append((start, collapsed[i] ? 1 : count, y))

            if Int64(start) + dropped == selectedBlockKey {
                ctx.setFillColor(cgColor(palette.selectionColor, alpha: 0x14))
                ctx.fill(CGRect(x: 0, y: y - gap / 2, width: width,
                                height: CGFloat(effRows[i]) * cell + gap))
            }
            if y > clipBottom + cell {
                y += CGFloat(effRows[i]) * cell
                continue
            }
            if collapsed[i] {
                if y + cell >= clipTop - cell {
                    drawBufferLine(ctx, buffer, abs: start, y: y, cols: cols,
                                   selStart: selStart, selEnd: selEnd)
                }
                let iy = y + cell
                if iy + cell >= clipTop - cell && iy <= clipBottom + cell {
                    drawCollapsedPlaceholder(ctx, hidden: count - 1, y: iy)
                }
                y += 2 * cell
                continue
            }
            for j in 0..<count {
                let ly = y + CGFloat(j) * cell
                if ly + cell < clipTop - cell { continue }
                if ly > clipBottom + cell { break }
                let abs = start + j
                if abs >= buffer.totalLines { break }
                drawBufferLine(ctx, buffer, abs: abs, y: ly, cols: cols,
                               selStart: selStart, selEnd: selEnd)
                if abs == cursorAbs {
                    drawCursorAt(ctx, emu, buffer, cursorAbs: cursorAbs, y: ly, cols: cols)
                }
            }
            y += CGFloat(count) * cell
        }
        ctx.restoreGState()

        drawHairline(ctx, at: ruleY, width: width)

        blockLayout.append((liveStart, liveCount, liveTop))
        for j in 0..<liveCount {
            let abs = liveStart + j
            if abs >= buffer.totalLines { break }
            let ly = liveTop + CGFloat(j) * cell
            drawBufferLine(ctx, buffer, abs: abs, y: ly, cols: cols,
                           selStart: selStart, selEnd: selEnd)
            if abs == cursorAbs {
                drawCursorAt(ctx, emu, buffer, cursorAbs: cursorAbs, y: ly, cols: cols)
            }
        }
    }

    /// Classic: everything scrolls together, including the input, with a wider
    /// boundary either side of the live block.
    private func drawClassicStack(_ ctx: CGContext, _ emu: TerminalEmulator, _ buffer: ScreenBuffer,
                                  segments: [(start: Int, count: Int)], collapsed: [Bool],
                                  effRows: [Int], liveIdx: Int, rows: Int, cols: Int,
                                  cursorAbs: Int, dropped: Int64,
                                  gap: CGFloat, cell: CGFloat, canvasH: CGFloat,
                                  selStart: (line: Int, col: Int),
                                  selEnd: (line: Int, col: Int)) {
        let width = bounds.width
        histClipTop = Self.paddingPx

        func boundaryBefore(_ s: Int) -> CGFloat {
            (s == liveIdx || s - 1 == liveIdx) ? cell + gap : gap
        }

        let edgePad = cell
        var totalPx: CGFloat = 0
        for i in segments.indices { totalPx += CGFloat(effRows[i]) * cell }
        if segments.count > 1 {
            for s in 1..<segments.count { totalPx += boundaryBefore(s) }
        }
        totalPx += edgePad

        let viewH = Swift.max(Self.paddingPx + CGFloat(rows) * cell, canvasH)
        let stackPx = totalPx - edgePad
        let avail = canvasH - edgePad - Self.paddingPx
        pinScrollPx = Swift.min(Swift.max(pinScrollPx, 0), Swift.max(0, stackPx - avail))

        var y = stackPx <= avail
            ? Self.paddingPx
            : canvasH - edgePad - stackPx + pinScrollPx
        var liveTopY = y

        for s in segments.indices {
            let (start, count) = segments[s]
            if s > 0 {
                let boundary = boundaryBefore(s)
                // The live block's own rule is drawn after the loop, so skip
                // the separator on either side of it here.
                if s != liveIdx && s - 1 != liveIdx {
                    let sepY = y + boundary / 2
                    if sepY > 0 && sepY < viewH { drawHairline(ctx, at: sepY, width: width) }
                }
                y += boundary
            }
            if s == liveIdx { liveTopY = y }
            blockLayout.append((start, collapsed[s] ? 1 : count, y))

            if Int64(start) + dropped == selectedBlockKey {
                // Fill gap-to-gap so the band has no uneven margin.
                let segPx = CGFloat(effRows[s]) * cell
                let padTop = s == 0 ? gap / 2
                    : (s - 1 == liveIdx ? gap : boundaryBefore(s) / 2)
                let padBottom = s + 1 >= segments.count ? gap / 2
                    : (s + 1 == liveIdx ? gap : boundaryBefore(s + 1) / 2)
                ctx.setFillColor(cgColor(palette.selectionColor, alpha: 0x14))
                ctx.fill(CGRect(x: 0, y: y - padTop, width: width,
                                height: segPx + padTop + padBottom))
            }
            if y > viewH { break }

            if collapsed[s] {
                if y + cell >= 0 && start < buffer.totalLines {
                    drawBufferLine(ctx, buffer, abs: start, y: y, cols: cols,
                                   selStart: selStart, selEnd: selEnd)
                }
                let iy = y + cell
                if iy + cell >= 0 && iy <= viewH {
                    drawCollapsedPlaceholder(ctx, hidden: count - 1, y: iy)
                }
                y += 2 * cell
                continue
            }
            for j in 0..<count {
                let ly = y + CGFloat(j) * cell
                if ly + cell < 0 { continue }
                if ly > viewH { break }
                let abs = start + j
                if abs >= buffer.totalLines { break }
                drawBufferLine(ctx, buffer, abs: abs, y: ly, cols: cols,
                               selStart: selStart, selEnd: selEnd)
                if abs == cursorAbs {
                    drawCursorAt(ctx, emu, buffer, cursorAbs: cursorAbs, y: ly, cols: cols)
                }
            }
            y += CGFloat(count) * cell
        }

        // The live input always gets a rule. A fresh tab has no room above it,
        // so the rule flips below rather than being clipped away.
        let ruleAbove = liveTopY - cell
        if ruleAbove >= Self.paddingPx {
            if ruleAbove < viewH { drawHairline(ctx, at: ruleAbove, width: width) }
        } else {
            let ruleBelow = liveTopY + CGFloat(effRows[liveIdx]) * cell + cell
            if ruleBelow > 0 && ruleBelow < viewH {
                drawHairline(ctx, at: ruleBelow, width: width)
            }
        }
    }

    /// The dim "N hidden lines" row that stands in for a collapsed body.
    private func drawCollapsedPlaceholder(_ ctx: CGContext, hidden: Int, y: CGFloat) {
        let text = NSAttributedString(string: "··· \(hidden) hidden lines", attributes: [
            .font: fonts[0] as Any,
            .foregroundColor: nsColor(palette.defaultForeground, alpha: 0x66),
        ])
        ctx.saveGState()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        text.draw(at: NSPoint(x: Self.paddingPx + cellWidth, y: y))
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()
    }

    /// One physical pixel, edge to edge, in the app-chrome hairline color for
    /// this palette's background - the same rule the sidebar and title bar use.
    private func drawHairline(_ ctx: CGContext, at y: CGFloat, width: CGFloat) {
        let scale = window?.backingScaleFactor ?? 1
        let snapped = (y * scale).rounded() / scale
        let bg = palette.defaultBackground
        let lum = (0.299 * Double((bg >> 16) & 0xFF)
                   + 0.587 * Double((bg >> 8) & 0xFF)
                   + 0.114 * Double(bg & 0xFF)) / 255.0
        ctx.setFillColor(lum < 0.5
                         ? cgColor(0xFFFFFF, alpha: 0x16)
                         : cgColor(0x000000, alpha: 0x21))
        ctx.fill(CGRect(x: 0, y: snapped, width: width, height: 1 / scale))
    }

    private func drawTextRuns(_ ctx: CGContext, cells: [Cell], n: Int, y: CGFloat) {
        var runText = ""
        var runStartCol = 0
        var runCells = 0
        var runFg: UInt32 = 0
        var runFlags: CellFlags = .none
        var runHasGlyphs = false
        let styleMask: CellFlags = [.bold, .italic, .underline, .doubleUnderline, .strikethrough]

        func flush() {
            if runText.isEmpty { return }
            let x = Self.paddingPx + CGFloat(runStartCol) * cellWidth
            let color = nsColor(runFg)
            if runHasGlyphs {
                drawRun(ctx, runText, x: x, y: y, color: color, flags: runFlags)
            }

            let width = CGFloat(runCells) * cellWidth
            if runFlags.contains(.underline) || runFlags.contains(.doubleUnderline) {
                ctx.setStrokeColor(color.cgColor)
                ctx.setLineWidth(1)
                ctx.move(to: CGPoint(x: x, y: y + cellHeight - 1.5))
                ctx.addLine(to: CGPoint(x: x + width, y: y + cellHeight - 1.5))
                ctx.strokePath()
                if runFlags.contains(.doubleUnderline) {
                    ctx.move(to: CGPoint(x: x, y: y + cellHeight - 3.5))
                    ctx.addLine(to: CGPoint(x: x + width, y: y + cellHeight - 3.5))
                    ctx.strokePath()
                }
            }
            if runFlags.contains(.strikethrough) {
                let sy = y + cellHeight * 0.55
                ctx.setStrokeColor(color.cgColor)
                ctx.setLineWidth(1)
                ctx.move(to: CGPoint(x: x, y: sy))
                ctx.addLine(to: CGPoint(x: x + width, y: sy))
                ctx.strokePath()
            }
            runText = ""
            runCells = 0
            runHasGlyphs = false
        }

        for c in 0..<n {
            let cell = cells[c]
            if cell.flags.contains(.wideTrailing) { continue }

            let rune = cell.rune == 0 ? 32 : cell.rune
            let fg = fgRow[c]
            let style = cell.flags.intersection(styleMask)

            let wide = rune > 0xFF && CharWidth.width(of: rune) == 2

            if !runText.isEmpty && (fg != runFg || style != runFlags) {
                flush()
            }

            // Box-drawing and block elements are painted to the cell rect, so
            // TUI borders and bars join seamlessly whatever the font covers.
            if BoxDrawing.handles(rune) {
                flush()
                BoxDrawing.draw(rune,
                                in: CGRect(x: Self.paddingPx + CGFloat(c) * cellWidth, y: y,
                                           width: cellWidth, height: cellHeight),
                                color: nsColor(fg), context: ctx)
                continue
            }

            if wide {
                // Draw wide glyphs individually so fallback-font metrics can't
                // push the rest of the row out of alignment.
                flush()
                if let scalar = UnicodeScalar(UInt32(rune)) {
                    drawRun(ctx, String(Character(scalar)),
                            x: Self.paddingPx + CGFloat(c) * cellWidth, y: y,
                            color: nsColor(fg), flags: cell.flags)
                }
                continue
            }

            if runText.isEmpty {
                runStartCol = c
                runFg = fg
                runFlags = style
            }

            if let scalar = UnicodeScalar(UInt32(rune)) {
                runText.unicodeScalars.append(scalar)
            } else {
                runText.append(" ")
            }
            runCells += 1
            if rune != 32 { runHasGlyphs = true }
        }
        flush()
    }

    /// Draws a run of single-width cells, positioning every glyph on the grid so
    /// a fallback font can never shift the row.
    private func drawRun(_ ctx: CGContext, _ text: String, x: CGFloat, y: CGFloat,
                         color: NSColor, flags: CellFlags) {
        let font = pickFont(flags)
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font as Any,
            .foregroundColor: color,
            // Snap each cell to the grid: without this the run drifts whenever a
            // glyph comes from a fallback face with different advances.
            .kern: 0,
        ])
        let line = CTLineCreateWithAttributedString(attributed)

        ctx.saveGState()
        // Core Text draws bottom-up; this view is flipped, so mirror the text
        // matrix and place the baseline by hand.
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: x, y: y + baseline)

        if text.count == 1 || isMonospacedRun(line, expected: CGFloat(text.count) * cellWidth) {
            CTLineDraw(line, ctx)
        } else {
            // Mixed-advance run: lay the characters out cell by cell.
            var offset: CGFloat = 0
            for character in text {
                let piece = NSAttributedString(string: String(character), attributes: [
                    .font: font as Any,
                    .foregroundColor: color,
                ])
                let pieceLine = CTLineCreateWithAttributedString(piece)
                ctx.textPosition = CGPoint(x: x + offset, y: y + baseline)
                CTLineDraw(pieceLine, ctx)
                offset += cellWidth
            }
        }
        ctx.restoreGState()
    }

    private func isMonospacedRun(_ line: CTLine, expected: CGFloat) -> Bool {
        abs(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) - expected) < 0.5
    }

    private func drawCursor(_ ctx: CGContext, _ emu: TerminalEmulator, _ buffer: ScreenBuffer,
                            scrollback: Int, firstAbs: Int, rows: Int, cols: Int) {
        let cursorAbs = scrollback + emu.cursorY
        let r = cursorAbs - firstAbs + alignPad
        if r < 0 || r >= rows { return }
        drawCursorAt(ctx, emu, buffer, cursorAbs: cursorAbs,
                     y: Self.paddingPx + CGFloat(r) * cellHeight, cols: cols)
    }

    private func drawCursorAt(_ ctx: CGContext, _ emu: TerminalEmulator, _ buffer: ScreenBuffer,
                              cursorAbs: Int, y: CGFloat, cols: Int) {
        if !emu.cursorVisible { return }

        let cx = min(max(emu.cursorX, 0), cols - 1)
        let x = Self.paddingPx + CGFloat(cx) * cellWidth
        let cursorColor = cgColor(palette.cursorColor)

        if !hasFocus {
            ctx.setStrokeColor(cursorColor)
            ctx.setLineWidth(1)
            ctx.stroke(CGRect(x: x + 0.5, y: y + 0.5, width: cellWidth - 1, height: cellHeight - 1))
            return
        }

        if !cursorBlinkOn { return }

        let style = emu.cursorStyle == 0 ? defaultCursorStyleCode : emu.cursorStyle
        ctx.setFillColor(cursorColor)
        switch style {
        case 3, 4:
            ctx.fill(CGRect(x: x, y: y + cellHeight - 2, width: cellWidth, height: 2))
        case 5, 6:
            ctx.fill(CGRect(x: x, y: y, width: 1.5, height: cellHeight))
        default:
            ctx.fill(CGRect(x: x, y: y, width: cellWidth, height: cellHeight))
            let line = buffer.absoluteLine(cursorAbs)
            if cx < line.cells.count {
                let cell = line.cells[cx]
                if cell.rune != 0 && cell.rune != 32,
                   let scalar = UnicodeScalar(UInt32(cell.rune)) {
                    drawRun(ctx, String(Character(scalar)), x: x, y: y,
                            color: nsColor(palette.defaultBackground), flags: cell.flags)
                }
            }
        }
    }

    // ---------------------------------------------------------------- input support
    // Narrow accessors so `TerminalView+Input` can drive the private render
    // state without exposing it to the rest of the app.

    static var paddingPxValue: CGFloat { paddingPx }
    var alignPadValue: Int { alignPad }

    /// Hit test for callers that ALREADY hold `emu.syncRoot` - re-locking a
    /// non-recursive path here would be a deadlock waiting to happen, and the
    /// public `hitTest(point:)` takes the lock itself.
    func hitTestLocked(point p: CGPoint, emu: TerminalEmulator) -> (line: Int, col: Int) {
        let col = Swift.min(Swift.max(Int((p.x - Self.paddingPx) / cellWidth), 0), emu.cols - 1)

        if !emu.isAlternateBuffer && !blockLayout.isEmpty {
            // Prefer the block that actually CONTAINS the point: pinned-top
            // appends the live block last with the smallest top, so "last entry
            // at or above y" would resolve everything to the live block.
            var seg = blockLayout[0]
            var found = false
            for candidate in blockLayout
            where p.y >= candidate.topPx
                && p.y < candidate.topPx + CGFloat(Swift.max(candidate.count, 2)) * cellHeight {
                seg = candidate
                found = true
                break
            }
            if !found {
                for candidate in blockLayout where candidate.topPx <= p.y { seg = candidate }
            }
            let segRow = Swift.min(Swift.max(Int((p.y - seg.topPx) / cellHeight), 0),
                                   Swift.max(0, seg.count - 1))
            let absLine = Swift.min(Swift.max(seg.start + segRow, 0), emu.buffer.totalLines - 1)
            return (absLine, col)
        }

        let row = Swift.min(Swift.max(Int((p.y - Self.paddingPx) / cellHeight) - alignPad, 0),
                            emu.rows - 1)
        let firstAbs = emu.buffer.scrollbackCount - scrollOffset
        let line = Swift.min(Swift.max(firstAbs + row, 0), emu.buffer.totalLines - 1)
        return (line, col)
    }

    /// Scrolls the block stack by a pixel delta (find and block jumping).
    func scrollBlockStack(byPixels delta: CGFloat) {
        pinScrollPx = Swift.max(0, pinScrollPx + delta)
    }

    var inputPositionMode: Int { inputPosition }
    var scrollOffsetValue: Int { scrollOffset }
    var isSelecting: Bool { selecting }
    var hasSelectionValue: Bool { hasSelection }

    func setScrollOffset(_ value: Int, max scrollback: Int) {
        scrollOffset = min(Swift.max(value, 0), scrollback)
    }

    func scrollBlockStack(by lines: CGFloat) {
        pinScrollPx = Swift.max(0, pinScrollPx + lines * cellHeight)
    }

    func changeFontSizeExternal(_ delta: Double) {
        changeFontSize(delta)
    }

    func resetBlink() {
        cursorBlinkOn = true
    }

    func setFocused(_ focused: Bool) {
        hasFocus = focused
        if focused { cursorBlinkOn = true }
        session.notifyFocus(focused)
        setNeedsDisplay(bounds)
    }

    func beginSelection(at hit: (line: Int, col: Int)) {
        selecting = true
        hasSelection = false
        selAnchor = hit
        selFocus = hit
    }

    /// Returns true when the selection changed and a repaint is needed.
    func updateSelection(to hit: (line: Int, col: Int)) -> Bool {
        if hit == selFocus { return false }
        selFocus = hit
        hasSelection = selFocus != selAnchor
        return true
    }

    func endSelection() {
        selecting = false
    }

    func clearSelection() {
        if hasSelection {
            hasSelection = false
            setNeedsDisplay(bounds)
        }
    }

    func scrollToBottom() {
        // Typing returns to the live prompt: block-stack home and offset zero.
        var changed = false
        if pinScrollPx != 0 {
            pinScrollPx = 0
            changed = true
        }
        if scrollOffset != 0 {
            scrollOffset = 0
            changed = true
        }
        if changed { setNeedsDisplay(bounds) }
    }

    func normalizedSelection() -> (start: (line: Int, col: Int), end: (line: Int, col: Int)) {
        if selAnchor.line < selFocus.line
            || (selAnchor.line == selFocus.line && selAnchor.col <= selFocus.col) {
            return (selAnchor, selFocus)
        }
        return (selFocus, selAnchor)
    }

    func hitTest(point p: CGPoint) -> (line: Int, col: Int) {
        let emu = session.emulator
        emu.syncRoot.lock()
        defer { emu.syncRoot.unlock() }
        return hitTestLocked(point: p, emu: emu)
    }

    private func nsColor(_ rgb: UInt32, alpha: UInt8 = 0xFF) -> NSColor {
        NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255.0,
                green: CGFloat((rgb >> 8) & 0xFF) / 255.0,
                blue: CGFloat(rgb & 0xFF) / 255.0,
                alpha: CGFloat(alpha) / 255.0)
    }

    private func cgColor(_ rgb: UInt32, alpha: UInt8 = 0xFF) -> CGColor {
        nsColor(rgb, alpha: alpha).cgColor
    }
}
