namespace Zharp.Core.Terminal;

/// <summary>Receives decoded actions from <see cref="VtParser"/>.</summary>
public interface IVtHandler
{
    void Print(int rune);
    void Execute(int controlChar);
    void EscDispatch(string intermediates, char final);
    void CsiDispatch(char prefix, string intermediates, IReadOnlyList<int[]> parameters, char final);
    void OscDispatch(string payload);
}

/// <summary>
/// VT500-series escape sequence parser (simplified state machine, covers
/// CSI / ESC / OSC / DCS-passthrough). Feed it decoded Unicode code points.
/// </summary>
public sealed class VtParser
{
    private enum State
    {
        Ground,
        Escape,
        EscapeIntermediate,
        CsiEntry,
        CsiParam,
        CsiIntermediate,
        CsiIgnore,
        OscString,
        OscEsc,
        StringIgnore, // DCS / SOS / PM / APC payloads we swallow
        StringIgnoreEsc,
    }

    private const int MaxOscLength = 4096;
    private const int MaxParams = 32;

    private readonly IVtHandler _handler;
    private State _state = State.Ground;

    private readonly System.Text.StringBuilder _intermediates = new(4);
    private readonly System.Text.StringBuilder _osc = new(64);
    private readonly List<int[]> _paramGroups = new(8);
    private readonly List<int> _currentGroup = new(4);
    private int _currentValue;
    private bool _hasValue;
    private char _prefix;

    public VtParser(IVtHandler handler) => _handler = handler;

    public void Process(int rune)
    {
        // CAN and SUB abort any sequence.
        if (rune == 0x18 || rune == 0x1A)
        {
            _state = State.Ground;
            return;
        }

        switch (_state)
        {
            case State.Ground:
                if (rune == 0x1B)
                    EnterEscape();
                else if (rune < 0x20)
                    _handler.Execute(rune);
                else if (rune != 0x7F)
                    _handler.Print(rune);
                break;

            case State.Escape:
                if (rune == 0x1B) { EnterEscape(); break; }
                if (rune < 0x20) { _handler.Execute(rune); break; }
                if (rune >= 0x20 && rune <= 0x2F)
                {
                    _intermediates.Append((char)rune);
                    _state = State.EscapeIntermediate;
                }
                else if (rune == '[')
                    EnterCsi();
                else if (rune == ']')
                {
                    _osc.Clear();
                    _state = State.OscString;
                }
                else if (rune == 'P' || rune == 'X' || rune == '^' || rune == '_')
                    _state = State.StringIgnore;
                else if (rune >= 0x30 && rune <= 0x7E)
                {
                    _state = State.Ground;
                    _handler.EscDispatch("", (char)rune);
                }
                else
                    _state = State.Ground;
                break;

            case State.EscapeIntermediate:
                if (rune == 0x1B) { EnterEscape(); break; }
                if (rune < 0x20) { _handler.Execute(rune); break; }
                if (rune >= 0x20 && rune <= 0x2F)
                    _intermediates.Append((char)rune);
                else if (rune >= 0x30 && rune <= 0x7E)
                {
                    string interm = _intermediates.ToString();
                    _state = State.Ground;
                    _handler.EscDispatch(interm, (char)rune);
                }
                else
                    _state = State.Ground;
                break;

            case State.CsiEntry:
            case State.CsiParam:
                if (rune == 0x1B) { EnterEscape(); break; }
                if (rune < 0x20) { _handler.Execute(rune); break; }
                if (rune >= '0' && rune <= '9')
                {
                    _currentValue = Math.Min(65535, _currentValue * 10 + (rune - '0'));
                    _hasValue = true;
                    _state = State.CsiParam;
                }
                else if (rune == ';')
                {
                    PushValue();
                    FlushGroup();
                    _state = State.CsiParam;
                }
                else if (rune == ':')
                {
                    PushValue();
                    _state = State.CsiParam;
                }
                else if (rune >= 0x3C && rune <= 0x3F)
                {
                    if (_state == State.CsiEntry)
                        _prefix = (char)rune;
                    else
                        _state = State.CsiIgnore;
                }
                else if (rune >= 0x20 && rune <= 0x2F)
                {
                    _intermediates.Append((char)rune);
                    _state = State.CsiIntermediate;
                }
                else if (rune >= 0x40 && rune <= 0x7E)
                    DispatchCsi((char)rune);
                else
                    _state = State.Ground;
                break;

            case State.CsiIntermediate:
                if (rune == 0x1B) { EnterEscape(); break; }
                if (rune < 0x20) { _handler.Execute(rune); break; }
                if (rune >= 0x20 && rune <= 0x2F)
                    _intermediates.Append((char)rune);
                else if (rune >= 0x40 && rune <= 0x7E)
                    DispatchCsi((char)rune);
                else
                    _state = State.CsiIgnore;
                break;

            case State.CsiIgnore:
                if (rune == 0x1B) { EnterEscape(); break; }
                if (rune >= 0x40 && rune <= 0x7E)
                    _state = State.Ground;
                break;

            case State.OscString:
                if (rune == 0x07)
                {
                    _state = State.Ground;
                    _handler.OscDispatch(_osc.ToString());
                }
                else if (rune == 0x1B)
                    _state = State.OscEsc;
                else if (rune >= 0x20 && _osc.Length < MaxOscLength)
                    _osc.Append(char.ConvertFromUtf32(rune));
                break;

            case State.OscEsc:
                if (rune == '\\')
                {
                    _state = State.Ground;
                    _handler.OscDispatch(_osc.ToString());
                }
                else
                {
                    // Aborted OSC; the ESC starts a new sequence.
                    EnterEscape();
                    Process(rune);
                }
                break;

            case State.StringIgnore:
                if (rune == 0x1B)
                    _state = State.StringIgnoreEsc;
                else if (rune == 0x07)
                    _state = State.Ground; // xterm also accepts BEL for DCS-like strings
                break;

            case State.StringIgnoreEsc:
                _state = rune == '\\' ? State.Ground
                       : rune == 0x1B ? State.StringIgnoreEsc
                       : State.StringIgnore;
                break;
        }
    }

    private void EnterEscape()
    {
        _state = State.Escape;
        _intermediates.Clear();
    }

    private void EnterCsi()
    {
        _state = State.CsiEntry;
        _intermediates.Clear();
        _paramGroups.Clear();
        _currentGroup.Clear();
        _currentValue = 0;
        _hasValue = false;
        _prefix = '\0';
    }

    private void PushValue()
    {
        if (_currentGroup.Count < 8)
            _currentGroup.Add(_hasValue ? _currentValue : 0);
        _currentValue = 0;
        _hasValue = false;
    }

    private void FlushGroup()
    {
        if (_paramGroups.Count < MaxParams)
            _paramGroups.Add(_currentGroup.ToArray());
        _currentGroup.Clear();
    }

    private void DispatchCsi(char final)
    {
        PushValue();
        FlushGroup();
        char prefix = _prefix;
        string interm = _intermediates.ToString();
        _state = State.Ground;
        _handler.CsiDispatch(prefix, interm, _paramGroups, final);
    }
}
