import Foundation

/// Receives decoded actions from `VtParser`.
public protocol VtHandler: AnyObject {
    func print(rune: Int)
    func execute(controlChar: Int)
    func escDispatch(intermediates: String, final: Character)
    func csiDispatch(prefix: Character, intermediates: String,
                     parameters: [[Int]], final: Character)
    func oscDispatch(payload: String)
}

/// VT500-series escape sequence parser (simplified state machine, covers
/// CSI / ESC / OSC / DCS-passthrough). Feed it decoded Unicode code points.
public final class VtParser {
    private enum State {
        case ground
        case escape
        case escapeIntermediate
        case csiEntry
        case csiParam
        case csiIntermediate
        case csiIgnore
        case oscString
        case oscEsc
        case stringIgnore      // DCS / SOS / PM / APC payloads we swallow
        case stringIgnoreEsc
    }

    private static let maxOscLength = 4096
    private static let maxParams = 32

    private unowned let handler: VtHandler
    private var state: State = .ground

    private var intermediates = ""
    private var osc = ""
    private var paramGroups: [[Int]] = []
    private var currentGroup: [Int] = []
    private var currentValue = 0
    private var hasValue = false
    private var prefix: Character = "\0"

    public init(handler: VtHandler) {
        self.handler = handler
    }

    public func process(_ rune: Int) {
        // CAN and SUB abort any sequence.
        if rune == 0x18 || rune == 0x1A {
            state = .ground
            return
        }

        switch state {
        case .ground:
            if rune == 0x1B {
                enterEscape()
            } else if rune < 0x20 {
                handler.execute(controlChar: rune)
            } else if rune != 0x7F {
                handler.print(rune: rune)
            }

        case .escape:
            if rune == 0x1B { enterEscape(); break }
            if rune < 0x20 { handler.execute(controlChar: rune); break }
            if rune >= 0x20 && rune <= 0x2F {
                intermediates.append(Character(UnicodeScalar(UInt8(rune))))
                state = .escapeIntermediate
            } else if rune == 0x5B { // '['
                enterCsi()
            } else if rune == 0x5D { // ']'
                osc = ""
                state = .oscString
            } else if rune == 0x50 || rune == 0x58 || rune == 0x5E || rune == 0x5F { // P X ^ _
                state = .stringIgnore
            } else if rune >= 0x30 && rune <= 0x7E {
                state = .ground
                handler.escDispatch(intermediates: "", final: Character(UnicodeScalar(UInt8(rune))))
            } else {
                state = .ground
            }

        case .escapeIntermediate:
            if rune == 0x1B { enterEscape(); break }
            if rune < 0x20 { handler.execute(controlChar: rune); break }
            if rune >= 0x20 && rune <= 0x2F {
                intermediates.append(Character(UnicodeScalar(UInt8(rune))))
            } else if rune >= 0x30 && rune <= 0x7E {
                let interm = intermediates
                state = .ground
                handler.escDispatch(intermediates: interm, final: Character(UnicodeScalar(UInt8(rune))))
            } else {
                state = .ground
            }

        case .csiEntry, .csiParam:
            if rune == 0x1B { enterEscape(); break }
            if rune < 0x20 { handler.execute(controlChar: rune); break }
            if rune >= 0x30 && rune <= 0x39 { // '0'..'9'
                currentValue = min(65535, currentValue * 10 + (rune - 0x30))
                hasValue = true
                state = .csiParam
            } else if rune == 0x3B { // ';'
                pushValue()
                flushGroup()
                state = .csiParam
            } else if rune == 0x3A { // ':'
                pushValue()
                state = .csiParam
            } else if rune >= 0x3C && rune <= 0x3F {
                if state == .csiEntry {
                    prefix = Character(UnicodeScalar(UInt8(rune)))
                } else {
                    state = .csiIgnore
                }
            } else if rune >= 0x20 && rune <= 0x2F {
                intermediates.append(Character(UnicodeScalar(UInt8(rune))))
                state = .csiIntermediate
            } else if rune >= 0x40 && rune <= 0x7E {
                dispatchCsi(Character(UnicodeScalar(UInt8(rune))))
            } else {
                state = .ground
            }

        case .csiIntermediate:
            if rune == 0x1B { enterEscape(); break }
            if rune < 0x20 { handler.execute(controlChar: rune); break }
            if rune >= 0x20 && rune <= 0x2F {
                intermediates.append(Character(UnicodeScalar(UInt8(rune))))
            } else if rune >= 0x40 && rune <= 0x7E {
                dispatchCsi(Character(UnicodeScalar(UInt8(rune))))
            } else {
                state = .csiIgnore
            }

        case .csiIgnore:
            if rune == 0x1B { enterEscape(); break }
            if rune >= 0x40 && rune <= 0x7E {
                state = .ground
            }

        case .oscString:
            if rune == 0x07 {
                state = .ground
                handler.oscDispatch(payload: osc)
            } else if rune == 0x1B {
                state = .oscEsc
            } else if rune >= 0x20 && osc.count < Self.maxOscLength {
                if let scalar = UnicodeScalar(UInt32(rune)) {
                    osc.unicodeScalars.append(scalar)
                }
            }

        case .oscEsc:
            if rune == 0x5C { // '\\'
                state = .ground
                handler.oscDispatch(payload: osc)
            } else {
                // Aborted OSC; the ESC starts a new sequence.
                enterEscape()
                process(rune)
            }

        case .stringIgnore:
            if rune == 0x1B {
                state = .stringIgnoreEsc
            } else if rune == 0x07 {
                state = .ground // xterm also accepts BEL for DCS-like strings
            }

        case .stringIgnoreEsc:
            state = rune == 0x5C ? .ground
                  : rune == 0x1B ? .stringIgnoreEsc
                  : .stringIgnore
        }
    }

    private func enterEscape() {
        state = .escape
        intermediates = ""
    }

    private func enterCsi() {
        state = .csiEntry
        intermediates = ""
        paramGroups.removeAll(keepingCapacity: true)
        currentGroup.removeAll(keepingCapacity: true)
        currentValue = 0
        hasValue = false
        prefix = "\0"
    }

    private func pushValue() {
        if currentGroup.count < 8 {
            currentGroup.append(hasValue ? currentValue : 0)
        }
        currentValue = 0
        hasValue = false
    }

    private func flushGroup() {
        if paramGroups.count < Self.maxParams {
            paramGroups.append(currentGroup)
        }
        currentGroup.removeAll(keepingCapacity: true)
    }

    private func dispatchCsi(_ final: Character) {
        pushValue()
        flushGroup()
        let prefix = self.prefix
        let interm = intermediates
        state = .ground
        handler.csiDispatch(prefix: prefix, intermediates: interm,
                            parameters: paramGroups, final: final)
    }
}
