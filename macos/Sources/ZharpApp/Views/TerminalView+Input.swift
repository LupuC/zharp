import AppKit
import ZharpCore

/// Keyboard, mouse and clipboard handling - the counterpart of the Windows
/// view's OnKeyDown / OnCharacterReceived / pointer handlers.
extension TerminalView {

    // ---------------------------------------------------------------- keyboard

    override func keyDown(with event: NSEvent) {
        let mods = MacKeyMap.modifiers(for: event)
        let vk = MacKeyMap.virtualKey(for: event)

        // Escape, in precedence order, before anything reaches the shell:
        // close the find bar, else drop the block highlight, else fall through.
        if vk == TerminalInput.VK_ESCAPE && mods.isEmpty {
            if isFindOpen {
                closeFind()
                return
            }
            if clearBlockSelection() { return }
        }

        // Terminal-scoped block actions resolve here rather than at the window,
        // so a chord with no block to act on still reaches the shell.
        if let action = resolveBlockShortcut?(event), handleBlockAction(action) {
            return
        }

        if isHistoryOpen {
            // Bare modifier presses - the Option of Option+Tab, Control, Shift -
            // must not dismiss the sheet; it survives window switches.
            if vk == 0 && event.charactersIgnoringModifiers?.isEmpty != false {
                super.keyDown(with: event)
                return
            }
            let anyModifier = mods.contains(.ctrl) || mods.contains(.shift)
                || mods.contains(.alt) || mods.contains(.cmd)
            if handleHistoryKey(virtualKey: vk, anyModifier: anyModifier) { return }

            // App chords (zoom, copy) act with the sheet open - it re-docks
            // itself afterwards. Only plain typing closes it, and the key keeps
            // travelling so the previewed command can be edited straight away.
            if !mods.contains(.ctrl) && !mods.contains(.alt) && !mods.contains(.cmd) {
                closeHistory(discardText: false)
            }
        }

        // Arrow Up on a genuinely empty prompt opens the history sheet;
        // otherwise it reaches the shell so its own history still works.
        if vk == TerminalInput.VK_UP, mods.isEmpty, tryOpenHistory() {
            return
        }

        // App shortcuts (zoom, tab management, copy/paste, ...) must reach the
        // window's key handling rather than being swallowed into the shell -
        // plain Cmd+- would otherwise become a chord.
        if isReservedShortcut?(event) == true {
            super.keyDown(with: event)
            return
        }

        // Everything with Command that is not a reserved shortcut belongs to the
        // system (Cmd+Q, Cmd+H, ...), never to the shell.
        if mods.contains(.cmd) {
            super.keyDown(with: event)
            return
        }

        let ctrl = mods.contains(.ctrl)
        let alt = mods.contains(.alt)
        let shift = mods.contains(.shift)

        // Ctrl chords -> control characters (Ctrl+C = 0x03 etc.).
        if ctrl && !alt {
            if let chord = TerminalInput.encodeControlChord(virtualKey: vk, mods: mods) {
                sendInput(chord)
                return
            }
        }

        // Option+key -> ESC prefix, the macOS "Use Option as Meta" behavior.
        // Option composes accented characters otherwise, so only letters and
        // digits are treated as Meta - the rest fall through to text input.
        if alt && !ctrl {
            if vk >= 0x41 && vk <= 0x5A {
                let c = Character(UnicodeScalar(UInt8(shift ? vk : vk + 32)))
                sendInput("\u{1b}\(c)")
                return
            }
            if vk >= 0x30 && vk <= 0x39 {
                sendInput("\u{1b}\(Character(UnicodeScalar(UInt8(vk))))")
                return
            }
        }

        if let sequence = TerminalInput.encodeKey(virtualKey: vk, mods: mods,
                                                  applicationCursorKeys: applicationCursorKeys) {
            sendInput(sequence)
            return
        }

        // Plain text (including dead-key composition) goes through the input
        // context so accents and IME candidates work as in any Cocoa app.
        interpretKeyEvents([event])
    }

    private var applicationCursorKeys: Bool {
        session.emulator.syncRoot.lock()
        defer { session.emulator.syncRoot.unlock() }
        return session.emulator.applicationCursorKeys
    }

    override func insertText(_ insertString: Any) {
        let text: String
        if let s = insertString as? String {
            text = s
        } else if let s = insertString as? NSAttributedString {
            text = s.string
        } else {
            return
        }
        if text.isEmpty { return }
        sendInput(text)
    }

    override func doCommand(by selector: Selector) {
        // Control characters are produced in keyDown; swallow the AppKit
        // equivalents so they never insert stray text.
    }

    func sendInput(_ text: String) {
        resetBlink()
        clearSelection()
        // Typing returns attention to the prompt.
        _ = clearBlockSelection()
        scrollToBottom()
        session.send(text)
    }

    // ---------------------------------------------------------------- mouse

    override func scrollWheel(with event: NSEvent) {
        let mods = MacKeyMap.modifiers(for: event)
        // Trackpads report fractional deltas; a wheel notch reports ~1 line.
        let delta = event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY / 3.0
            : event.scrollingDeltaY

        if mods.contains(.cmd) {
            changeFontSizeExternal(delta > 0 ? +1 : -1)
            return
        }
        if abs(delta) < 0.01 { return }

        let emu = session.emulator
        if emu.isAlternateBuffer {
            // Full-screen apps get arrow keys instead of scrollback.
            let appMode = applicationCursorKeys
            let key = delta > 0
                ? (appMode ? "\u{1b}OA" : "\u{1b}[A")
                : (appMode ? "\u{1b}OB" : "\u{1b}[B")
            let repeats = max(1, min(12, Int(abs(delta).rounded())))
            session.send(String(repeating: key, count: repeats))
        } else {
            let lines = max(1, min(24, Int(abs(delta).rounded())))
            var scrollback = 0
            var blocks = false
            emu.syncRoot.lock()
            scrollback = emu.scrollbackCount
            // Classic scrolls the block stack too, once marks exist.
            blocks = emu.promptMarkLine >= 0
            emu.syncRoot.unlock()

            if blocks {
                // Scroll the block stack toward older content: down in the
                // pinned-top stack, up in the pinned-bottom one.
                let toward = inputPositionMode == 2
                    ? (delta > 0 ? -lines : lines)
                    : (delta > 0 ? lines : -lines)
                scrollBlockStack(by: CGFloat(toward))
            } else {
                setScrollOffset(scrollOffsetValue + (delta > 0 ? lines : -lines), max: scrollback)
            }
            setNeedsDisplay(bounds)
        }
    }

    override func mouseDown(with event: NSEvent) {
        focusTerminal()
        let point = convert(event.locationInWindow, from: nil)
        selectBlock(at: point)
        beginSelection(at: hitTest(point: point))
        setNeedsDisplay(bounds)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isSelecting else { return }
        let point = convert(event.locationInWindow, from: nil)
        if updateSelection(to: hitTest(point: point)) {
            setNeedsDisplay(bounds)
        }
    }

    override func mouseUp(with event: NSEvent) {
        endSelection()
    }

    override func rightMouseDown(with event: NSEvent) {
        // The old copy-or-paste convention is now the menu's first two items.
        let point = convert(event.locationInWindow, from: nil)
        selectBlock(at: point)
        showBlockMenu(at: point, block: blockAt(point: point))
    }

    override func mouseMoved(with event: NSEvent) {
        updateHoverChip(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        hideChip()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .iBeam)
    }

    // ---------------------------------------------------------------- focus

    override func becomeFirstResponder() -> Bool {
        setFocused(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        setFocused(false)
        return true
    }

    // ---------------------------------------------------------------- clipboard

    func copySelection() {
        guard let text = selectedText(), !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func pasteFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            return
        }
        resetBlink()
        scrollToBottom()
        session.paste(text)
    }

    func selectedText() -> String? {
        guard hasSelectionValue else { return nil }

        let (start, end) = normalizedSelection()
        let emu = session.emulator
        var out = ""
        emu.syncRoot.lock()
        defer { emu.syncRoot.unlock() }

        let buffer = emu.buffer
        var lineIdx = start.line
        while lineIdx <= end.line && lineIdx < buffer.totalLines {
            let line = buffer.absoluteLine(lineIdx)
            var from = lineIdx == start.line ? start.col : 0
            var to = lineIdx == end.line ? end.col : line.cells.count - 1
            from = min(max(from, 0), max(0, line.cells.count - 1))
            to = min(max(to, 0), line.cells.count - 1)

            var lineText = ""
            if from <= to {
                for c in from...to {
                    let cell = line.cells[c]
                    if cell.flags.contains(.wideTrailing) { continue }
                    if cell.rune == 0 {
                        lineText.append(" ")
                    } else if let scalar = UnicodeScalar(UInt32(cell.rune)) {
                        lineText.unicodeScalars.append(scalar)
                    }
                }
            }
            // Trim trailing blanks on each line.
            while lineText.hasSuffix(" ") { lineText.removeLast() }
            out += lineText

            // Soft-wrapped lines join without a break.
            if lineIdx < end.line && !line.wrapped {
                out += "\n"
            }
            lineIdx += 1
        }
        return out
    }
}
