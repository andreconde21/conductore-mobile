import 'dart:math' as math;

import 'package:conduit_vt/conduit_vt.dart';

/// What a one-finger vertical drag on the terminal does, decided from the
/// state the remote program put the terminal in.
///
/// Desktop terminals (and Moshi) send mouse wheel events when the program
/// asked for mouse reports, and fall back to arrow keys on the alternate
/// screen. A phone drag should do the same: Herdr, tmux (`mouse on`), vim,
/// htop and Claude Code's fullscreen renderer draw on the alternate screen,
/// which has no local history for the app to scroll.
enum RemoteScrollRoute {
  /// Scroll the app's own scrollback, as before (main screen, no mouse).
  local,

  /// Send mouse wheel reports (button 64 up, 65 down) at the finger's cell.
  wheel,

  /// Send Up/Down arrow keys: alternate screen with "alternate scroll"
  /// (DECSET 1007) on, or a plain shell's full-screen program.
  arrows,

  /// Enter the multiplexer's copy mode on the first drag, then scroll
  /// there with arrow keys (tmux without `mouse on`).
  copyMode,
}

/// Picks the [RemoteScrollRoute] for a drag.
///
/// * Mouse tracking with wheel reports (DECSET 1000, 1002 or 1003) wins:
///   the program asked for the wheel. X10 clicks only (DECSET 9) does not
///   report the wheel, so it counts as no tracking.
/// * On the alternate screen without mouse tracking, DECSET 1007 asks for
///   arrow keys. Without it, a multiplexer session ([multiplexer]) enters
///   copy mode, the only way to reach its history; any other program (less,
///   man) gets arrow keys, what conduit_vt sent before.
/// * On the main screen without mouse tracking the drag stays local.
RemoteScrollRoute remoteScrollRouteFor({
  required MouseMode mouseMode,
  required bool altBuffer,
  required bool alternateScroll,
  required bool multiplexer,
}) {
  if (mouseMode.reportScroll) {
    return RemoteScrollRoute.wheel;
  }
  if (!altBuffer) {
    return RemoteScrollRoute.local;
  }
  if (alternateScroll || !multiplexer) {
    return RemoteScrollRoute.arrows;
  }
  return RemoteScrollRoute.copyMode;
}

/// Encodes one mouse wheel notch the way xterm reports it.
///
/// [column] and [row] are zero-based screen cells. Wheel up is button 64
/// and wheel down 65 in every encoding (conduit_vt's own reporter uses
/// 68/69, which is the wheel with the Shift bit set: tmux ignores it and
/// vim scrolls a page). Legacy encodings cap coordinates at their maximum
/// instead of sending a null byte, which some programs read as the end of
/// the report.
String encodeWheelEvent({
  required bool up,
  required int column,
  required int row,
  required MouseReportMode mode,
}) {
  final button = up ? 64 : 65;
  final x = math.max(column, 0) + 1;
  final y = math.max(row, 0) + 1;
  switch (mode) {
    case MouseReportMode.sgr:
      return '\x1b[<$button;$x;${y}M';
    case MouseReportMode.urxvt:
      return '\x1b[${32 + button};$x;${y}M';
    case MouseReportMode.normal:
      return '\x1b[M${String.fromCharCode(32 + button)}'
          '${String.fromCharCode(32 + math.min(x, 223))}'
          '${String.fromCharCode(32 + math.min(y, 223))}';
    case MouseReportMode.utf:
      // Values of 96 and up become two-byte UTF-8 once the string is
      // encoded for the wire, which is what DECSET 1005 means.
      return '\x1b[M${String.fromCharCode(32 + button)}'
          '${String.fromCharCode(32 + math.min(x, 2015))}'
          '${String.fromCharCode(32 + math.min(y, 2015))}';
  }
}

/// The Up or Down arrow as a scroll notch: `ESC O A` in application
/// cursor-key mode (DECSET 1, set by less, vim and most full-screen
/// programs), `ESC [ A` otherwise, as xterm sends for alternate scroll.
/// (conduit_vt's key encoder follows the keypad mode, DECKPAM, instead.)
String encodeScrollArrow({
  required bool up,
  required bool applicationCursorKeys,
}) {
  final final_ = up ? 'A' : 'B';
  return applicationCursorKeys ? '\x1bO$final_' : '\x1b[$final_';
}

/// Desktop: pixels of mouse wheel or trackpad travel per wheel report (or
/// arrow press) sent to a remote program. A wheel notch is 53 px in Flutter
/// on Linux, so each notch sends one report, as xterm, Ghostty and kitty do
/// (tmux and Herdr then scroll several lines per report). The trackpad
/// sends one per the same travel, which scrolls the local history 3 lines.
const double desktopWheelStep = 50;

/// Desktop: arrow presses per wheel notch for a program without mouse
/// reports (less, man), the 3 lines a notch scrolls the local history.
const int desktopArrowsPerNotch = 3;

/// Turns finger travel into wheel notches (or arrow presses): one per
/// [step] pixels, keeping the remainder between moves so slow drags still
/// scroll.
class RemoteScrollAccumulator {
  RemoteScrollAccumulator({this.step = defaultStep});

  /// Pixels of finger travel per notch, like the two-finger scrollback.
  static const double defaultStep = 14;

  final double step;
  double _remainder = 0;

  /// Adds [dy] pixels of finger travel (positive = finger moved down) and
  /// returns the notches it completed: positive scrolls up (older content
  /// comes into view, like dragging a page), negative scrolls down.
  int add(double dy) {
    _remainder += dy;
    final notches = _remainder ~/ step;
    _remainder -= notches * step;
    return notches;
  }

  void reset() => _remainder = 0;
}

/// Extra notches a fling adds after the finger lifts, one entry per
/// [tick], decaying like a scroll view's momentum.
///
/// The fling travels `velocity * timeConstant` pixels in total with
/// exponential decay; it stops once the speed drops under [stopVelocity]
/// or after [maxNotches] notches, so a hard flick in a long history cannot
/// flood the connection. Flings slower than [minVelocity] add nothing.
/// Positive entries scroll up, as in [RemoteScrollAccumulator.add].
List<int> remoteScrollMomentum(
  double velocity, {
  double step = RemoteScrollAccumulator.defaultStep,
  Duration tick = momentumTick,
  double timeConstant = 0.325,
  double minVelocity = 200,
  double stopVelocity = 60,
  int maxNotches = maxMomentumNotches,
}) {
  final speed = velocity.abs();
  if (speed < minVelocity || maxNotches <= 0) {
    return const [];
  }
  final sign = velocity.sign.toInt();
  final dt = tick.inMicroseconds / Duration.microsecondsPerSecond;
  final schedule = <int>[];
  var emitted = 0;
  var t = 0.0;
  while (emitted < maxNotches) {
    t += dt;
    final remainingSpeed = speed * math.exp(-t / timeConstant);
    final travelled = speed * timeConstant * (1 - math.exp(-t / timeConstant));
    final due = math.min((travelled / step).floor(), maxNotches) - emitted;
    schedule.add(sign * due);
    emitted += due;
    if (remainingSpeed < stopVelocity) {
      break;
    }
  }
  // Trailing empty ticks would only keep a timer alive.
  while (schedule.isNotEmpty && schedule.last == 0) {
    schedule.removeLast();
  }
  return schedule;
}

/// Interval between momentum ticks.
const Duration momentumTick = Duration(milliseconds: 16);

/// Upper bound on the notches one fling adds.
const int maxMomentumNotches = 40;
