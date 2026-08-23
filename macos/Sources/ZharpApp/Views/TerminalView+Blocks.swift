import AppKit
import ZharpCore

/// Block interaction: resolving blocks under the pointer, the hover chip, the
/// block menu, find-within-block, and keyboard jumping.
extension TerminalView {

    // ---------------------------------------------------------------- model

    /// The block containing an absolute line, or nil on the alternate buffer,
    /// with no marks, or above a leading block that does not exist.
    func blockAt(line: Int, emu: TerminalEmulator) -> TerminalBlock? {
        if emu.isAlternateBuffer { return nil }
        let marks = emu.getPromptMarks()
        if marks.isEmpty { return nil }
        let buffer = emu.buffer
        let dropped = buffer.droppedLines
        let contentEnd = buffer.scrollbackCount + emu.cursorY

        var idx = -1
        for (i, mark) in marks.enumerated() where mark <= line { idx = i }
        if idx < 0 {
            // Output that predates the first known prompt - a shell banner.
            guard marks[0] > 0 else { return nil }
            return TerminalBlock(start: 0, end: marks[0] - 1, isLive: false, dropped: dropped)
        }
        let start = marks[idx]
        let end = idx + 1 < marks.count ? marks[idx + 1] - 1 : Swift.max(start, contentEnd)
        return TerminalBlock(start: start, end: end,
                             isLive: idx == marks.count - 1, dropped: dropped)
    }

    /// Resolves a drop-stable key back to a block.
    func blockFromKey(_ key: Int64, emu: TerminalEmulator) -> TerminalBlock? {
        if emu.isAlternateBuffer || key < 0 { return nil }
        let marks = emu.getPromptMarks()
        if marks.isEmpty { return nil }
        let buffer = emu.buffer
        let dropped = buffer.droppedLines
        let contentEnd = buffer.scrollbackCount + emu.cursorY
        let start = Int(key - dropped)

        if start == 0 && marks[0] > 0 {
            return TerminalBlock(start: 0, end: marks[0] - 1, isLive: false, dropped: dropped)
        }
        guard let idx = marks.firstIndex(of: start) else { return nil }
        let end = idx + 1 < marks.count ? marks[idx + 1] - 1 : Swift.max(start, contentEnd)
        return TerminalBlock(start: start, end: end,
                             isLive: idx == marks.count - 1, dropped: dropped)
    }

    /// What a keyboard block action acts on: the highlighted block, else the
    /// newest FINISHED one (never the live input).
    func targetBlock(_ emu: TerminalEmulator) -> TerminalBlock? {
        if let selected = blockFromKey(selectedBlockKey, emu: emu) { return selected }
        let marks = emu.getPromptMarks()
        if marks.isEmpty { return nil }
        let idx = Swift.max(0, marks.count - 2)
        let buffer = emu.buffer
        let contentEnd = buffer.scrollbackCount + emu.cursorY
        let start = marks[idx]
        let end = idx + 1 < marks.count ? marks[idx + 1] - 1 : Swift.max(start, contentEnd)
        return TerminalBlock(start: start, end: end, isLive: idx == marks.count - 1,
                             dropped: buffer.droppedLines)
    }

    /// The block under a point in view coordinates.
    func blockAt(point: CGPoint) -> TerminalBlock? {
        let emu = session.emulator
        emu.syncRoot.lock()
        defer { emu.syncRoot.unlock() }
        let hit = hitTestLocked(point: point, emu: emu)
        return blockAt(line: hit.line, emu: emu)
    }

    /// Vertical extent of a block on screen, for placing the chip.
    func blockPixelRange(start: Int, end: Int) -> (top: CGFloat, bottom: CGFloat)? {
        let emu = session.emulator
        if emu.isAlternateBuffer { return nil }
        if !blockLayout.isEmpty {
            guard let seg = blockLayout.first(where: { $0.start == start }) else { return nil }
            return (seg.topPx,
                    seg.topPx + CGFloat(Swift.max(seg.count, 2)) * cellHeight)
        }
        let firstAbs = emu.buffer.scrollbackCount - scrollOffsetValue
        let top = Self.paddingPxValue + CGFloat(start - firstAbs + alignPadValue) * cellHeight
        let bottom = Self.paddingPxValue + CGFloat(end - firstAbs + 1 + alignPadValue) * cellHeight
        return (top, bottom)
    }

    // ---------------------------------------------------------------- selection

    /// Highlights the block under a point; clicking the live input clears it.
    func selectBlock(at point: CGPoint) {
        let key = blockAt(point: point).flatMap { $0.isLive ? nil : $0.key } ?? -1
        if key != selectedBlockKey {
            selectedBlockKey = key
            setNeedsDisplay(bounds)
        }
    }

    func clearBlockSelection() -> Bool {
        if selectedBlockKey < 0 { return false }
        selectedBlockKey = -1
        setNeedsDisplay(bounds)
        return true
    }

    // ---------------------------------------------------------------- copying

    private func copyToPasteboard(_ text: String) {
        if text.isEmpty { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func copyBlockCommand(_ block: TerminalBlock) {
        let emu = session.emulator
        emu.syncRoot.lock()
        let text = BlockText.command(emu, emu.buffer, block.start, block.end)
        emu.syncRoot.unlock()
        copyToPasteboard(text)
    }

    func copyBlockOutput(_ block: TerminalBlock) {
        let emu = session.emulator
        emu.syncRoot.lock()
        let text = BlockText.output(emu, emu.buffer, block.start, block.end)
        emu.syncRoot.unlock()
        copyToPasteboard(text)
    }

    func copyBlockWhole(_ block: TerminalBlock) {
        let emu = session.emulator
        emu.syncRoot.lock()
        let text = BlockText.whole(emu.buffer, block.start, block.end)
        emu.syncRoot.unlock()
        copyToPasteboard(text)
    }

    func copyBlockMarkdown(_ block: TerminalBlock) {
        let emu = session.emulator
        emu.syncRoot.lock()
        let text = BlockText.markdown(emu, emu.buffer, block.start, block.end)
        emu.syncRoot.unlock()
        copyToPasteboard(text)
    }

    // ---------------------------------------------------------------- menu

    /// The block menu, shared by right-click and the hover chip.
    func showBlockMenu(at point: CGPoint, block: TerminalBlock?) {
        let menu = NSMenu()
        menu.font = NSFont.systemFont(ofSize: 12)

        menu.addItem(BlockMenuItem(title: "Copy",
                                   binding: blockShortcutText?("copy"),
                                   enabled: hasSelectionValue) { [weak self] in
            self?.copySelection()
            self?.clearSelection()
        })
        menu.addItem(BlockMenuItem(title: "Paste",
                                   binding: blockShortcutText?("paste")) { [weak self] in
            self?.pasteFromClipboard()
        })

        if let block {
            menu.addItem(.separator())
            menu.addItem(BlockMenuItem(title: "Copy command", binding: nil) { [weak self] in
                self?.copyBlockCommand(block)
            })
            menu.addItem(BlockMenuItem(title: "Copy output",
                                       binding: blockShortcutText?("copyOutput")) { [weak self] in
                self?.copyBlockOutput(block)
            })
            menu.addItem(BlockMenuItem(title: "Copy block", binding: nil) { [weak self] in
                self?.copyBlockWhole(block)
            })
            menu.addItem(BlockMenuItem(title: "Copy block as Markdown", binding: nil) { [weak self] in
                self?.copyBlockMarkdown(block)
            })
            menu.addItem(.separator())
            menu.addItem(BlockMenuItem(title: "Find within block",
                                       binding: blockShortcutText?("findInBlock")) { [weak self] in
                self?.openFind(key: block.key)
            })
            if !block.isLive && block.end > block.start {
                let isCollapsed = collapsedKeys.contains(block.key)
                menu.addItem(BlockMenuItem(title: isCollapsed ? "Expand block" : "Collapse block",
                                           binding: nil) { [weak self] in
                    guard let self else { return }
                    if isCollapsed {
                        self.collapsedKeys.remove(block.key)
                    } else {
                        self.collapsedKeys.insert(block.key)
                    }
                    self.setNeedsDisplay(self.bounds)
                })
            }
        }

        menu.popUp(positioning: nil, at: point, in: self)
    }

    // ---------------------------------------------------------------- chip

    /// Repositions the hover chip and the find bar after a draw.
    func positionOverlays() {
        positionFindPanel()
        positionChip()
        positionHistoryPanel()
    }

    private func positionChip() {
        guard let chip = chipButton, !chip.isHidden else { return }
        let emu = session.emulator
        emu.syncRoot.lock()
        let block = blockFromKey(hoverChipKey, emu: emu)
        emu.syncRoot.unlock()
        guard let block, !block.isLive,
              let range = blockPixelRange(start: block.start, end: block.end) else {
            chip.isHidden = true
            return
        }
        let viewBottom = bounds.height
        let minY: CGFloat = (findPanel?.isHidden == false) ? 52 : 4
        if range.bottom < minY + 24 || range.top > viewBottom - 10 {
            chip.isHidden = true
            return
        }
        let top = Swift.min(Swift.max(range.top + 3, minY), Swift.max(minY, viewBottom - 32))
        chip.frame = CGRect(x: bounds.width - 12 - 30, y: top, width: 30, height: 26)
    }

    /// Shows or hides the chip for whatever block the pointer is over.
    func updateHoverChip(at point: CGPoint) {
        let block = blockAt(point: point)
        guard let block, !block.isLive else {
            hideChip()
            return
        }
        if chipButton == nil { buildChip() }
        hoverChipKey = block.key
        chipButton?.isHidden = false
        positionChip()
    }

    func hideChip() {
        hoverChipKey = -1
        chipButton?.isHidden = true
    }

    private func buildChip() {
        let chip = OverlayButton(content: .symbol("ellipsis"), pointSize: 14,
                                 width: 30, height: 26)
        chip.translatesAutoresizingMaskIntoConstraints = true
        chip.isPlated = true
        chip.colors = overlay
        chip.toolTip = "Block actions"
        chip.onClick = { [weak self] in
            guard let self, let chip = self.chipButton else { return }
            let emu = self.session.emulator
            emu.syncRoot.lock()
            let block = self.blockFromKey(self.hoverChipKey, emu: emu)
            emu.syncRoot.unlock()
            if let block {
                self.selectedBlockKey = block.key
                self.setNeedsDisplay(self.bounds)
            }
            // Anchored below the chip, right edges aligned - never upward.
            self.showBlockMenu(at: CGPoint(x: chip.frame.maxX, y: chip.frame.maxY + 2),
                               block: block)
        }
        addSubview(chip)
        chipButton = chip
    }

    // ---------------------------------------------------------------- find

    func openFind(key: Int64) {
        findKey = key
        // A collapsed block expands so its matches are visible.
        collapsedKeys.remove(key)
        selectedBlockKey = key
        if findPanel == nil { buildFindPanel() }
        findPanel?.isHidden = false
        recomputeFind()
        positionFindPanel()
        if let field = findField {
            window?.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }
        setNeedsDisplay(bounds)
    }

    func closeFind() {
        findPanel?.isHidden = true
        findKey = -1
        findMatches.removeAll()
        findByLine = nil
        findIndex = -1
        findCounter?.stringValue = "0/0"
        focusTerminal()
        setNeedsDisplay(bounds)
    }

    var isFindOpen: Bool { findPanel?.isHidden == false }

    private func positionFindPanel() {
        guard let panel = findPanel, !panel.isHidden else { return }
        panel.layoutSubtreeIfNeeded()
        let size = panel.fittingSize
        panel.frame = CGRect(x: bounds.width - 12 - size.width, y: 8,
                             width: size.width, height: size.height)
    }

    private func buildFindPanel() {
        let panel = OverlayPanel()
        panel.translatesAutoresizingMaskIntoConstraints = true
        panel.colors = overlay

        let field = FindTextField()
        field.placeholderString = "Find in block"
        field.font = NSFont.systemFont(ofSize: 12)
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        field.translatesAutoresizingMaskIntoConstraints = false
        field.target = self
        field.action = #selector(onFindFieldChanged)
        field.delegate = self
        field.onStep = { [weak self] dir in self?.stepFind(dir) }
        field.onClose = { [weak self] in self?.closeFind() }

        let caseToggle = OverlayButton(content: .text("Aa"), pointSize: 11.5,
                                       width: 32, height: 28)
        caseToggle.isToggle = true
        caseToggle.toolTip = "Match case"
        caseToggle.onClick = { [weak self] in self?.recomputeFind() }

        let regexToggle = OverlayButton(content: .text(".*"), pointSize: 11.5,
                                        width: 32, height: 28)
        regexToggle.isToggle = true
        regexToggle.toolTip = "Regular expression"
        regexToggle.onClick = { [weak self] in self?.recomputeFind() }

        let counter = NSTextField(labelWithString: "0/0")
        counter.font = NSFont.systemFont(ofSize: 11)
        counter.alignment = .center
        counter.translatesAutoresizingMaskIntoConstraints = false
        counter.widthAnchor.constraint(greaterThanOrEqualToConstant: 36).isActive = true

        let prev = OverlayButton(content: .symbol("chevron.up"), pointSize: 11,
                                 width: 28, height: 28)
        prev.toolTip = "Previous match (Shift+Enter)"
        prev.onClick = { [weak self] in self?.stepFind(-1) }

        let next = OverlayButton(content: .symbol("chevron.down"), pointSize: 11,
                                 width: 28, height: 28)
        next.toolTip = "Next match (Enter)"
        next.onClick = { [weak self] in self?.stepFind(+1) }

        let close = OverlayButton(content: .symbol("xmark"), pointSize: 11,
                                  width: 28, height: 28)
        close.toolTip = "Close (Esc)"
        close.onClick = { [weak self] in self?.closeFind() }

        let row = NSStackView(views: [field, caseToggle, regexToggle, counter, prev, next, close])
        row.orientation = .horizontal
        row.spacing = 4
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(row)

        NSLayoutConstraint.activate([
            field.widthAnchor.constraint(equalToConstant: 180),
            field.heightAnchor.constraint(equalToConstant: 28),
            row.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 8),
            row.topAnchor.constraint(equalTo: panel.topAnchor, constant: 5),
            row.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -5),
            row.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -5),
        ])

        addSubview(panel)
        findPanel = panel
        findField = field
        findCounter = counter
        findCaseToggle = caseToggle
        findRegexToggle = regexToggle
        refreshOverlayColors()
    }

    /// Recolors every overlay control after a palette change.
    func refreshOverlayColors() {
        chipButton?.colors = overlay
        findPanel?.colors = overlay
        findCaseToggle?.colors = overlay
        findRegexToggle?.colors = overlay
        for view in findPanel?.subviews.first?.subviews ?? [] {
            (view as? OverlayButton)?.colors = overlay
        }
        findCounter?.textColor = overlay.foregroundDim
        findField?.textColor = overlay.foreground
        findField?.backgroundColor = overlay.inputBackground
        findPanel?.needsDisplay = true
    }

    @objc private func onFindFieldChanged() { recomputeFind() }

    func recomputeFind() {
        findMatches.removeAll()
        findIndex = -1
        findByLine = nil

        let query = findField?.stringValue ?? ""
        guard findKey >= 0, !query.isEmpty else {
            findCounter?.stringValue = "0/0"
            setNeedsDisplay(bounds)
            return
        }

        let matchCase = findCaseToggle?.isOn ?? false
        var regex: NSRegularExpression?
        var valid = true
        if findRegexToggle?.isOn == true {
            regex = try? NSRegularExpression(
                pattern: query, options: matchCase ? [] : [.caseInsensitive])
            valid = regex != nil
        }

        let emu = session.emulator
        emu.syncRoot.lock()
        if valid, let block = blockFromKey(findKey, emu: emu) {
            let buffer = emu.buffer
            let dropped = buffer.droppedLines
            var abs = block.start
            while abs <= block.end, abs < buffer.totalLines, findMatches.count < 2000 {
                let (text, columns) = BlockText.lineTextWithMap(buffer, abs)
                if text.isEmpty { abs += 1; continue }
                if let regex {
                    let ns = text as NSString
                    for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
                    where m.range.length > 0 {
                        if findMatches.count >= 2000 { break }
                        let lo = m.range.location
                        let hi = m.range.location + m.range.length - 1
                        guard lo < columns.count, hi < columns.count else { continue }
                        findMatches.append((Int64(abs) + dropped, columns[lo], columns[hi]))
                    }
                } else {
                    let ns = text as NSString
                    var searchFrom = 0
                    let options: NSString.CompareOptions = matchCase ? [] : [.caseInsensitive]
                    while searchFrom < ns.length, findMatches.count < 2000 {
                        let found = ns.range(of: query, options: options,
                                             range: NSRange(location: searchFrom,
                                                            length: ns.length - searchFrom))
                        if found.location == NSNotFound { break }
                        let lo = found.location
                        let hi = found.location + found.length - 1
                        if lo < columns.count, hi < columns.count {
                            findMatches.append((Int64(abs) + dropped, columns[lo], columns[hi]))
                        }
                        searchFrom = found.location + Swift.max(1, found.length)
                    }
                }
                abs += 1
            }
        }
        emu.syncRoot.unlock()

        findIndex = findMatches.isEmpty ? -1 : 0
        findCounter?.stringValue = !valid
            ? "bad rx"
            : "\(findIndex + 1)/\(findMatches.count)"
        if findIndex >= 0 { scrollToMatch() }
        setNeedsDisplay(bounds)
    }

    func stepFind(_ dir: Int) {
        if findMatches.isEmpty { return }
        let count = findMatches.count
        findIndex = ((findIndex + dir) % count + count) % count
        findByLine = nil // re-flags which match is current
        findCounter?.stringValue = "\(findIndex + 1)/\(count)"
        scrollToMatch()
        setNeedsDisplay(bounds)
    }

    private func scrollToMatch() {
        guard findIndex >= 0, findIndex < findMatches.count else { return }
        let emu = session.emulator
        emu.syncRoot.lock()
        defer { emu.syncRoot.unlock() }
        let buffer = emu.buffer
        let line = Int(findMatches[findIndex].rawLine - buffer.droppedLines)
        if line < 0 { return }

        if !emu.isAlternateBuffer, !blockLayout.isEmpty,
           let seg = blockLayout.first(where: { line >= $0.start && line < $0.start + Swift.max($0.count, 1) })
            ?? blockLayout.last(where: { $0.start <= line }) {
            let px = seg.topPx + CGFloat(line - seg.start) * cellHeight
            let home = inputPositionMode == 2 ? histClipTop : Self.paddingPxValue
            let want = home + CGFloat(emu.rows) * cellHeight / 3
            let delta = px - want
            scrollBlockStack(byPixels: inputPositionMode == 2 ? delta : -delta)
        } else {
            let scrollback = buffer.scrollbackCount
            let target = scrollback - (line - Swift.max(1, emu.rows / 3))
            setScrollOffset(target, max: scrollback)
        }
    }

    /// Sets the find query without a pointer, for headless verification.
    var findFieldTextForTesting: String {
        get { findField?.stringValue ?? "" }
        set { findField?.stringValue = newValue }
    }

    /// A textual description of the laid-out blocks, for headless verification.
    func blockDebugState() -> String {
        var lines: [String] = []
        lines.append("layout=\(blockLayout.count) collapsed=\(collapsedKeys.count) "
                     + "selected=\(selectedBlockKey) find=\(findMatches.count) "
                     + "chip=\(chipButton?.isHidden == false) findOpen=\(isFindOpen)")
        for seg in blockLayout {
            lines.append(String(format: "  block start=%d rows=%d top=%.1f",
                                seg.start, seg.count, seg.topPx))
        }
        return lines.joined(separator: "\n")
    }

    // ---------------------------------------------------------------- keyboard

    /// Runs a terminal-scoped block action. Returns false only for a failed
    /// jump, which lets the chord fall through to the shell.
    func handleBlockAction(_ actionId: String) -> Bool {
        switch actionId {
        case "blockPrev": return tryJumpBlocks(-1)
        case "blockNext": return tryJumpBlocks(+1)
        case "copyOutput":
            let emu = session.emulator
            emu.syncRoot.lock()
            let block = targetBlock(emu)
            emu.syncRoot.unlock()
            if let block { copyBlockOutput(block) }
            return true
        case "findInBlock":
            let emu = session.emulator
            emu.syncRoot.lock()
            let block = targetBlock(emu)
            emu.syncRoot.unlock()
            if let block { openFind(key: block.key) }
            return true
        default:
            return false
        }
    }

    /// Moves the block stack one block in `dir`. Returns false when there is no
    /// block layout to move through, so the chord reaches the shell instead.
    func tryJumpBlocks(_ dir: Int) -> Bool {
        let emu = session.emulator
        emu.syncRoot.lock()
        defer { emu.syncRoot.unlock() }
        if emu.isAlternateBuffer { return false }
        let marks = emu.getPromptMarks()
        if marks.isEmpty { return false }

        if !blockLayout.isEmpty {
            // In pinned layouts the live block is fixed, so it is never a target.
            let liveStart = inputPositionMode != 0 ? marks[marks.count - 1] : -1
            let candidates = blockLayout.filter { $0.start != liveStart }
            if candidates.isEmpty { return true }

            let home = inputPositionMode == 2 ? histClipTop : Self.paddingPxValue
            var cur = 0
            var best = CGFloat.greatestFiniteMagnitude
            for (i, candidate) in candidates.enumerated() {
                let distance = abs(candidate.topPx - home)
                if distance < best { best = distance; cur = i }
            }
            let newestFirst = inputPositionMode == 2
            let target = cur + (newestFirst ? -dir : dir)
            if target < 0 || target >= candidates.count {
                if dir > 0 { scrollToBottom() }
                return true
            }
            let delta = candidates[target].topPx - home
            scrollBlockStack(byPixels: newestFirst ? delta : -delta)
            setNeedsDisplay(bounds)
            return true
        }

        // No layout (a session without marks): fall back to scrollback offsets.
        let scrollback = emu.buffer.scrollbackCount
        let top = scrollback - scrollOffsetValue
        var targetMark: Int?
        if dir < 0 {
            for mark in marks where mark < top { targetMark = mark }
        } else {
            targetMark = marks.first { $0 > top }
        }
        guard let targetMark else {
            if dir > 0 { scrollToBottom() }
            return true
        }
        setScrollOffset(scrollback - targetMark, max: scrollback)
        setNeedsDisplay(bounds)
        return true
    }
}

extension TerminalView: NSTextFieldDelegate {
    public func controlTextDidChange(_ obj: Notification) {
        recomputeFind()
    }
}
