import AppKit
import ZharpCore

/// The command history sheet: Arrow Up on an empty prompt opens it, and the
/// highlighted entry is typed at the prompt live, classic-shell style. Keyboard
/// focus never leaves the terminal.
extension TerminalView {

    // ---------------------------------------------------------------- opening

    /// Returns false when Arrow Up should reach the shell untouched, so the
    /// shell's own history keeps working.
    func tryOpenHistory() -> Bool {
        if historyPanel?.isHidden == false { return false }

        let emu = session.emulator
        emu.syncRoot.lock()
        let live = emu.hasLivePromptInput
        let pending = emu.peekPendingCommand()
        emu.syncRoot.unlock()

        if ProcessInfo.processInfo.environment["ZHARP_DEBUG_HISTORY"] == "1" {
            App.log("hist: live=\(live) pending='\(pending ?? "")' "
                    + "empty=\(HistoryStore.shared.isEmpty)")
        }
        // Shell integration live, prompt genuinely empty, something to show.
        guard live, pending == nil, !HistoryStore.shared.isEmpty else { return false }

        if historyPanel == nil { buildHistoryPanel() }
        historyFolderOnly = false
        historyPanel?.folderToggle.isOn = false
        historyInserted = ""
        historyPanel?.isHidden = false
        positionHistoryPanel()
        refreshHistory()
        return true
    }

    var isHistoryOpen: Bool { historyPanel?.isHidden == false }

    private func buildHistoryPanel() {
        let panel = HistoryPanelView()
        panel.translatesAutoresizingMaskIntoConstraints = true
        panel.colors = overlay
        panel.setListHeight(historyListHeight)
        panel.folderToggle.onClick = { [weak self] in
            guard let self else { return }
            self.historyFolderOnly = self.historyPanel?.folderToggle.isOn ?? false
            self.refreshHistory()
        }
        panel.onResize = { [weak self] height in
            guard let self else { return }
            // Dragging up makes the list taller.
            let maxHeight = Swift.max(120, self.bounds.height * 0.7)
            self.historyListHeight = Swift.min(Swift.max(height, 72), maxHeight)
            self.historyPanel?.setListHeight(self.historyListHeight)
            self.positionHistoryPanel()
        }
        addSubview(panel)
        historyPanel = panel
    }

    // ---------------------------------------------------------------- rows

    func refreshHistory() {
        guard let panel = historyPanel, !panel.isHidden else { return }
        let directory = historyFolderOnly ? session.workingDirectory : nil
        let entries = HistoryStore.shared.query(directory: directory, limit: 60)

        for view in panel.rowsStack.arrangedSubviews {
            panel.rowsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        if entries.isEmpty {
            // "This folder" scoped everything away - nothing left to show.
            closeHistory(discardText: true)
            return
        }

        // Oldest first so the NEWEST sits at the bottom, next to the prompt.
        for (index, entry) in entries.reversed().enumerated() {
            let row = HistoryRowView(entry: entry, zoom: CGFloat(uiZoomValue), colors: overlay)
            row.onHover = { [weak self] in self?.selectHistory(index) }
            row.onClick = { [weak self] in self?.closeHistory(discardText: false) }
            panel.rowsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: panel.rowsStack.widthAnchor).isActive = true
        }
        historyRowCount = entries.count
        historyIndex = -1
        selectHistory(entries.count - 1) // newest, already previewed
        panel.scrollToNewest()
    }

    /// Highlights a row and types it at the prompt.
    private func selectHistory(_ index: Int) {
        guard let panel = historyPanel, !panel.isHidden else { return }
        let rows = panel.rowsStack.arrangedSubviews.compactMap { $0 as? HistoryRowView }
        guard index >= 0, index < rows.count else { return }
        if historyIndex == index { return }
        historyIndex = index
        for (i, row) in rows.enumerated() { row.isSelected = i == index }
        rows[index].scrollToVisible(rows[index].bounds)
        previewHistory(rows[index].entry.command)
    }

    /// Replaces whatever the previous preview typed with this command - live,
    /// like classic shell history.
    private func previewHistory(_ command: String) {
        if command == historyInserted { return }
        var text = eraseSequence()
        text += command
        historyInserted = command
        session.send(text)
    }

    /// One DEL per rune of the last preview - what Backspace sends.
    private func eraseSequence() -> String {
        String(repeating: "\u{7f}", count: historyInserted.unicodeScalars.count)
    }

    private func eraseInserted() {
        if historyInserted.isEmpty { return }
        session.send(eraseSequence())
        historyInserted = ""
    }

    // ---------------------------------------------------------------- keys

    /// Returns true when the panel consumed the key.
    func handleHistoryKey(virtualKey: Int, anyModifier: Bool) -> Bool {
        guard let panel = historyPanel, !panel.isHidden else { return false }
        if anyModifier { return false }

        switch virtualKey {
        case TerminalInput.VK_UP:
            // Newest sits at the BOTTOM, so Up moves toward older entries.
            if historyRowCount > 0 { selectHistory(Swift.max(historyIndex - 1, 0)) }
            return true
        case TerminalInput.VK_DOWN:
            if historyRowCount > 0 {
                if historyIndex >= historyRowCount - 1 {
                    // Below the newest = an empty prompt again.
                    closeHistory(discardText: true)
                } else {
                    selectHistory(historyIndex + 1)
                }
            }
            return true
        case TerminalInput.VK_RETURN:
            closeHistory(discardText: false)
            session.send("\r") // the command is already typed at the prompt
            return true
        case TerminalInput.VK_TAB:
            closeHistory(discardText: false) // keep the text for editing
            return true
        case TerminalInput.VK_ESCAPE:
            closeHistory(discardText: true)
            return true
        default:
            return false
        }
    }

    func closeHistory(discardText: Bool) {
        if discardText {
            eraseInserted()
        } else {
            historyInserted = ""
        }
        historyPanel?.isHidden = true
        historyIndex = -1
        historyRowCount = 0
        focusTerminal()
    }

    /// The docked sheet's frame, for headless verification.
    var historyPanelFrameForTesting: String {
        guard let panel = historyPanel, !panel.isHidden else { return "hidden" }
        return String(format: "x=%.0f y=%.0f w=%.0f h=%.0f below=%@",
                      panel.frame.origin.x, panel.frame.origin.y,
                      panel.frame.width, panel.frame.height,
                      panel.dockBelow ? "yes" : "no")
    }

    // ---------------------------------------------------------------- docking

    /// Keeps an open panel alive across zoom, font and window-size changes: it
    /// re-docks at the input's new position and rebuilds the rows at the new
    /// scale. A stale position would sit off-screen while still swallowing the
    /// Up and Down keys.
    func repositionHistoryOverlay() {
        guard historyPanel?.isHidden == false else { return }
        positionHistoryPanel()
        refreshHistory()
    }

    /// Input-position switches change the whole geometry model, so a fresh open
    /// is cleaner than a re-dock.
    func dismissHistoryOverlay() {
        guard historyPanel?.isHidden == false else { return }
        closeHistory(discardText: false)
    }

    /// Docks the sheet flush against the live input's rule.
    func positionHistoryPanel() {
        guard let panel = historyPanel, !panel.isHidden else { return }
        let canvasH = Swift.max(bounds.height, 200)
        let cell = cellHeight
        let padding = Self.paddingPxValue

        let emu = session.emulator
        emu.syncRoot.lock()
        let marks = emu.getPromptMarks()
        let liveCount: Int
        if let last = marks.last {
            liveCount = Swift.max(1, emu.buffer.scrollbackCount + emu.cursorY - last + 1)
        } else {
            liveCount = 1
        }
        let liveStart = marks.last
        emu.syncRoot.unlock()

        var ruleY: CGFloat
        var dockBelow: Bool
        switch inputPositionMode {
        case 2: // pinned top: the input bar is at the top, history hangs below
            ruleY = padding + cell + CGFloat(liveCount) * cell + cell
            dockBelow = true
        case 1: // pinned bottom: the input is at the bottom, history sits above
            ruleY = canvasH - cell - CGFloat(liveCount) * cell - cell
            dockBelow = false
        default: // classic: follow the live block, flipping when there is no room
            let range = liveStart.flatMap {
                blockPixelRange(start: $0, end: $0 + liveCount - 1)
            }
            let liveTop = range?.top ?? (canvasH - 70)
            dockBelow = liveTop - cell < padding + 60
            ruleY = dockBelow ? (range?.bottom ?? 60) + cell : liveTop - cell
        }

        panel.layoutSubtreeIfNeeded()
        let height = panel.fittingSize.height
        let top: CGFloat
        if dockBelow {
            top = Swift.min(Swift.max(ruleY, 0), canvasH - 160)
        } else {
            let fromBottom = Swift.min(Swift.max(canvasH - ruleY, 40), canvasH - 100)
            top = canvasH - fromBottom - height
        }
        panel.dockBelow = dockBelow
        panel.frame = CGRect(x: 0, y: top, width: bounds.width, height: height)
    }
}
