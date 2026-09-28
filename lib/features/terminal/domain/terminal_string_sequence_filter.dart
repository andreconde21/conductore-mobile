/// Drops DCS, SOS, PM and APC string sequences from terminal output.
///
/// A sequence ends at ST (ESC \ or the 8-bit 0x9c). Like a real terminal
/// it is also cancelled by CAN or SUB, and by ESC followed by anything but
/// `\` (that ESC starts a new sequence, which is passed on), so a stray
/// ESC P in a binary `cat` cannot hide all later output. A doubled ESC
/// (tmux passthrough's escaping) stays inside the string. At most
/// [maxStrippedLength] characters are dropped per sequence.
class TerminalStringSequenceFilter {
  static const Set<int> _introducers = {0x50, 0x58, 0x5e, 0x5f};
  static const int _esc = 0x1b;
  static const int _can = 0x18;
  static const int _sub = 0x1a;
  static const int _st8bit = 0x9c;
  static const int _stFinal = 0x5c;

  /// Longest string sequence dropped; what follows is shown again.
  static const int maxStrippedLength = 1 << 20;

  _FilterState _state = _FilterState.normal;
  int _stripped = 0;

  void reset() {
    _state = _FilterState.normal;
    _stripped = 0;
  }

  String process(String chunk) {
    // Most output has no string sequence at all: pass the text through
    // whole, and copy plain runs in one piece, instead of one character
    // at a time.
    if (_state == _FilterState.normal) {
      final first = chunk.indexOf(_escString);
      if (first == -1) return chunk;
      return _process(chunk, first, StringBuffer(chunk.substring(0, first)));
    }
    return _process(chunk, 0, StringBuffer());
  }

  static const _escString = '\x1b';

  String _process(String chunk, int start, StringBuffer out) {
    final length = chunk.length;
    var i = start;
    while (i < length) {
      if (_state == _FilterState.normal) {
        final next = chunk.indexOf(_escString, i);
        if (next == -1) {
          out.write(chunk.substring(i));
          break;
        }
        if (next > i) out.write(chunk.substring(i, next));
        _state = _FilterState.sawEsc;
        i = next + 1;
        continue;
      }
      _step(chunk.codeUnitAt(i), out);
      i += 1;
    }
    return out.toString();
  }

  void _step(int code, StringBuffer out) {
    if (_state == _FilterState.stripping ||
        _state == _FilterState.strippingSawEsc) {
      _stripped += 1;
      if (_stripped > maxStrippedLength) {
        _state = _FilterState.normal;
      }
    }
    switch (_state) {
      case _FilterState.normal:
        _normal(code, out);
      case _FilterState.sawEsc:
        _sawEsc(code, out);
      case _FilterState.stripping:
        if (code == _esc) {
          _state = _FilterState.strippingSawEsc;
        } else if (code == _st8bit || code == _can || code == _sub) {
          _state = _FilterState.normal;
        }
      case _FilterState.strippingSawEsc:
        if (code == _stFinal) {
          _state = _FilterState.normal;
        } else if (code == _esc) {
          _state = _FilterState.stripping;
        } else {
          // The string was cut short; this ESC starts a new sequence.
          _sawEsc(code, out);
        }
    }
  }

  void _normal(int code, StringBuffer out) {
    if (code == _esc) {
      _state = _FilterState.sawEsc;
    } else {
      out.writeCharCode(code);
    }
  }

  void _sawEsc(int code, StringBuffer out) {
    if (_introducers.contains(code)) {
      _state = _FilterState.stripping;
      _stripped = 0;
      return;
    }
    out.writeCharCode(_esc);
    if (code == _esc) {
      _state = _FilterState.sawEsc;
    } else {
      out.writeCharCode(code);
      _state = _FilterState.normal;
    }
  }
}

enum _FilterState { normal, sawEsc, stripping, strippingSawEsc }
