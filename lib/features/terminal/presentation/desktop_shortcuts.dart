import 'package:conduit/core/platform_features.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// App-level keyboard shortcuts of the terminal on Linux, Windows and macOS.
/// Phones never match any of them (see [matchDesktopShortcut]).
///
/// The keys follow GNOME Terminal / kitty / Windows Terminal on Linux and
/// Windows and Terminal.app / iTerm2 on macOS, and avoid keys a shell or a
/// TUI needs:
///
/// * Ctrl+PgUp / Ctrl+PgDn are left to the multiplexer tab switcher
///   (previous / next Herdr tab or tmux window).
/// * Zoom uses Ctrl+= / Ctrl++ / Ctrl+- / Ctrl+0. None is a readline,
///   Claude Code, vim or tmux binding (undo is Ctrl+_ = Ctrl+Shift+-, which
///   stays with the shell).
/// * Go to session N uses Alt+1..9, not Ctrl+digit: Ctrl+2..8 are control
///   characters (Ctrl+6 is vim's alternate file). Alt+digit was readline's
///   rarely used numeric argument.
/// * The help sheet is Ctrl+Shift+/ (Ctrl+?), not Ctrl+/, which sends ^_
///   (undo). F1 stays with htop and mc.
/// * The desktop shell's splits: Ctrl+Shift+\ (right) and Ctrl+Shift+-
///   (down), like Windows Terminal's Alt+Shift pair but on Ctrl so Alt
///   stays Meta. Ctrl+Shift+- used to send Ctrl+_ (undo); Ctrl+/ still
///   sends the same ^_. Alt+arrows move between splits, and only when a
///   split lies that way: otherwise the shell gets them (word motion).
///   Ctrl+Shift+U jumps to the next unread row of the sidebar.
/// * macOS uses Cmd, which never reaches the shell (iTerm2's Cmd+D /
///   Cmd+Shift+D split, Cmd+Option+arrows move).
enum DesktopAction {
  zoomIn('Zoom in'),
  zoomOut('Zoom out'),
  zoomReset('Reset zoom'),
  newSession('New session on this machine'),
  closeSession('Close session'),
  nextSession('Next session'),
  previousSession('Previous session'),
  goToSession('Go to session 1 to 9'),
  toggleFullscreen('Fullscreen terminal'),
  showShortcuts('Keyboard shortcuts'),
  splitRight('Split right'),
  splitDown('Split down'),

  /// [DesktopShortcutMatch.index]: 0 left, 1 right, 2 up, 3 down.
  focusPane('Move between splits'),
  nextUnread('Next unread'),

  /// The desktop shell's command palette (every action, session, agent).
  commandPalette('Command palette'),
  openSettings('Settings'),
  toggleSidebar('Show or hide the sidebar');

  const DesktopAction(this.label);

  final String label;
}

/// A matched shortcut; [index] is the zero-based session for
/// [DesktopAction.goToSession], the direction for
/// [DesktopAction.focusPane] (see [focusDirections]).
@immutable
class DesktopShortcutMatch {
  const DesktopShortcutMatch(this.action, [this.index = 0]);

  final DesktopAction action;
  final int index;

  @override
  bool operator ==(Object other) =>
      other is DesktopShortcutMatch &&
      other.action == action &&
      other.index == index;

  @override
  int get hashCode => Object.hash(action, index);

  @override
  String toString() => 'DesktopShortcutMatch($action, $index)';
}

bool get _mac => defaultTargetPlatform == TargetPlatform.macOS;

/// Step of the zoom keys and of Ctrl + wheel, in logical pixels.
const desktopZoomStep = 1.0;

/// The terminal shortcut [event] triggers, or null. Always null on phones.
/// Key repeats only count for zoom and next/previous session.
DesktopShortcutMatch? matchDesktopShortcut(KeyEvent event) {
  if (!PlatformFeatures.isDesktop || event is KeyUpEvent) return null;
  final keyboard = HardwareKeyboard.instance;
  final ctrl = keyboard.isControlPressed;
  final shift = keyboard.isShiftPressed;
  final alt = keyboard.isAltPressed;
  final meta = keyboard.isMetaPressed;
  final key = event.logicalKey;
  final repeat = event is KeyRepeatEvent;

  // Cmd on macOS, Ctrl elsewhere, with nothing else but (sometimes) Shift.
  final primary = _mac ? meta && !ctrl && !alt : ctrl && !meta && !alt;

  DesktopShortcutMatch? match(DesktopAction action, [int index = 0]) {
    final repeats =
        action == DesktopAction.zoomIn ||
        action == DesktopAction.zoomOut ||
        action == DesktopAction.nextSession ||
        action == DesktopAction.previousSession;
    if (repeat && !repeats) return null;
    return DesktopShortcutMatch(action, index);
  }

  if (primary) {
    if (key == LogicalKeyboardKey.equal ||
        key == LogicalKeyboardKey.add ||
        key == LogicalKeyboardKey.numpadAdd) {
      return match(DesktopAction.zoomIn);
    }
    if (!shift &&
        (key == LogicalKeyboardKey.minus ||
            key == LogicalKeyboardKey.numpadSubtract)) {
      return match(DesktopAction.zoomOut);
    }
    if (!shift &&
        (key == LogicalKeyboardKey.digit0 ||
            key == LogicalKeyboardKey.numpad0)) {
      return match(DesktopAction.zoomReset);
    }
    // Linux/Windows: Ctrl+Shift+T/W; macOS: Cmd+T/W.
    if (shift != _mac) {
      if (key == LogicalKeyboardKey.keyT) {
        return match(DesktopAction.newSession);
      }
      if (key == LogicalKeyboardKey.keyW) {
        return match(DesktopAction.closeSession);
      }
    }
    // Shift+/ is reported as slash or as question depending on the OS.
    if (!_mac &&
        shift &&
        (key == LogicalKeyboardKey.slash ||
            key == LogicalKeyboardKey.question)) {
      return match(DesktopAction.showShortcuts);
    }
    if (_mac && !shift && key == LogicalKeyboardKey.slash) {
      return match(DesktopAction.showShortcuts);
    }
    if (_mac && shift && key == LogicalKeyboardKey.bracketRight) {
      return match(DesktopAction.nextSession);
    }
    if (_mac && shift && key == LogicalKeyboardKey.bracketLeft) {
      return match(DesktopAction.previousSession);
    }
    if (_mac && !shift) {
      final index = _digitIndex(key);
      if (index != null) return match(DesktopAction.goToSession, index);
    }
    // Splits. Shift+\ and Shift+- arrive as \ / | and - / _ depending on
    // the OS.
    if (!_mac &&
        shift &&
        (key == LogicalKeyboardKey.backslash ||
            key == LogicalKeyboardKey.bar)) {
      return match(DesktopAction.splitRight);
    }
    if (!_mac &&
        shift &&
        (key == LogicalKeyboardKey.minus ||
            key == LogicalKeyboardKey.underscore)) {
      return match(DesktopAction.splitDown);
    }
    if (_mac && key == LogicalKeyboardKey.keyD) {
      return match(shift ? DesktopAction.splitDown : DesktopAction.splitRight);
    }
    if (shift && key == LogicalKeyboardKey.keyU) {
      return match(DesktopAction.nextUnread);
    }
    // Ctrl+Shift+P / Cmd+Shift+P, like VS Code. Plain Ctrl+P stays with
    // the shell (previous history line).
    if (shift && key == LogicalKeyboardKey.keyP) {
      return match(DesktopAction.commandPalette);
    }
    // Ctrl+, / Cmd+, : Ctrl+, sends nothing to a shell.
    if (!shift && key == LogicalKeyboardKey.comma) {
      return match(DesktopAction.openSettings);
    }
    // Ctrl+Shift+B / Cmd+B: plain Ctrl+B is tmux's prefix.
    if (shift != _mac && key == LogicalKeyboardKey.keyB) {
      return match(DesktopAction.toggleSidebar);
    }
  }

  // Between splits: Alt+arrows, Cmd+Option+arrows on macOS.
  final paneModifiers = _mac
      ? meta && alt && !ctrl && !shift
      : alt && !ctrl && !meta && !shift;
  if (paneModifiers) {
    final direction = focusDirections.indexOf(key);
    if (direction >= 0) return match(DesktopAction.focusPane, direction);
  }

  // Ctrl+Tab / Ctrl+Shift+Tab on every desktop.
  if (ctrl && !alt && !meta && key == LogicalKeyboardKey.tab) {
    return match(
      shift ? DesktopAction.previousSession : DesktopAction.nextSession,
    );
  }
  if (!_mac && alt && !ctrl && !meta && !shift) {
    final index = _digitIndex(key);
    if (index != null) return match(DesktopAction.goToSession, index);
  }
  if (!ctrl && !alt && !meta && !shift && key == LogicalKeyboardKey.f11) {
    return match(DesktopAction.toggleFullscreen);
  }
  if (_mac &&
      ctrl &&
      meta &&
      !alt &&
      !shift &&
      key == LogicalKeyboardKey.keyF) {
    return match(DesktopAction.toggleFullscreen);
  }
  return null;
}

/// The arrows of [DesktopAction.focusPane], by match index.
const focusDirections = [
  LogicalKeyboardKey.arrowLeft,
  LogicalKeyboardKey.arrowRight,
  LogicalKeyboardKey.arrowUp,
  LogicalKeyboardKey.arrowDown,
];

int? _digitIndex(LogicalKeyboardKey key) {
  const digits = [
    LogicalKeyboardKey.digit1,
    LogicalKeyboardKey.digit2,
    LogicalKeyboardKey.digit3,
    LogicalKeyboardKey.digit4,
    LogicalKeyboardKey.digit5,
    LogicalKeyboardKey.digit6,
    LogicalKeyboardKey.digit7,
    LogicalKeyboardKey.digit8,
    LogicalKeyboardKey.digit9,
  ];
  final index = digits.indexOf(key);
  return index < 0 ? null : index;
}

/// The modifier keys that turn the wheel into zoom: Cmd on macOS, Ctrl
/// elsewhere. The terminal's ScrollConfiguration also treats them as axis
/// modifiers, so a wheel event with one held does not scroll.
Set<LogicalKeyboardKey> get wheelZoomModifierKeys => _mac
    ? {LogicalKeyboardKey.metaLeft, LogicalKeyboardKey.metaRight}
    : {LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.controlRight};

/// Whether the wheel zoom modifier is held right now.
bool get isWheelZoomModifierPressed => HardwareKeyboard
    .instance
    .logicalKeysPressed
    .any(wheelZoomModifierKeys.contains);

/// One row of the help sheet.
@immutable
class DesktopShortcutHelp {
  const DesktopShortcutHelp(this.label, this.keys);

  final String label;
  final String keys;
}

String get _mod => _mac ? 'Cmd' : 'Ctrl';

/// The quick switcher's keys (quick_switcher_shortcut.dart) for the
/// running OS.
String get quickSwitcherKeys => _mac ? 'Cmd+K' : 'Ctrl+Shift+K';

/// The keys of [action] for the running OS, as shown in menus and tooltips.
String desktopShortcutKeys(DesktopAction action) => switch (action) {
  DesktopAction.zoomIn => '$_mod+=',
  DesktopAction.zoomOut => '$_mod+-',
  DesktopAction.zoomReset => '$_mod+0',
  DesktopAction.newSession => _mac ? 'Cmd+T' : 'Ctrl+Shift+T',
  DesktopAction.closeSession => _mac ? 'Cmd+W' : 'Ctrl+Shift+W',
  DesktopAction.nextSession => 'Ctrl+Tab',
  DesktopAction.previousSession => 'Ctrl+Shift+Tab',
  DesktopAction.goToSession => _mac ? 'Cmd+1…9' : 'Alt+1…9',
  DesktopAction.toggleFullscreen => _mac ? 'Ctrl+Cmd+F' : 'F11',
  DesktopAction.showShortcuts => _mac ? 'Cmd+/' : 'Ctrl+Shift+/',
  DesktopAction.splitRight => _mac ? 'Cmd+D' : 'Ctrl+Shift+\\',
  DesktopAction.splitDown => _mac ? 'Cmd+Shift+D' : 'Ctrl+Shift+-',
  DesktopAction.focusPane => _mac ? 'Cmd+Option+arrows' : 'Alt+arrows',
  DesktopAction.nextUnread => _mac ? 'Cmd+Shift+U' : 'Ctrl+Shift+U',
  DesktopAction.commandPalette => _mac ? 'Cmd+Shift+P' : 'Ctrl+Shift+P',
  DesktopAction.openSettings => '$_mod+,',
  DesktopAction.toggleSidebar => _mac ? 'Cmd+B' : 'Ctrl+Shift+B',
};

/// Everything the help sheet lists, for the running OS.
List<DesktopShortcutHelp> desktopShortcutHelp() => [
  for (final action in DesktopAction.values)
    DesktopShortcutHelp(action.label, switch (action) {
      DesktopAction.zoomIn => '$_mod+=  or  $_mod++',
      DesktopAction.nextSession =>
        _mac ? 'Ctrl+Tab  or  Cmd+Shift+]' : 'Ctrl+Tab',
      DesktopAction.previousSession =>
        _mac ? 'Ctrl+Shift+Tab  or  Cmd+Shift+[' : 'Ctrl+Shift+Tab',
      DesktopAction.toggleFullscreen => _mac ? 'Ctrl+Cmd+F  or  F11' : 'F11',
      _ => desktopShortcutKeys(action),
    }),
  // Bound by the multiplexer tab strip (Herdr / tmux sessions only).
  const DesktopShortcutHelp(
    'Previous / next Herdr tab or tmux window',
    'Ctrl+PgUp / Ctrl+PgDn',
  ),
  DesktopShortcutHelp('Zoom with the mouse', '$_mod + wheel, or pinch'),
  DesktopShortcutHelp('Quick switcher', quickSwitcherKeys),
  DesktopShortcutHelp('Copy', _mac ? 'Cmd+C' : 'Ctrl+Shift+C'),
  DesktopShortcutHelp(
    'Paste',
    _mac ? 'Cmd+V' : 'Ctrl+Shift+V  or  Shift+Insert',
  ),
];

/// Listens to the hardware keyboard for [matchDesktopShortcut] while
/// [isActive] (the owning page is the top route). A handled shortcut is
/// consumed before focus dispatch, so the terminal never forwards it to the
/// shell. [onShortcut] returns false to let a key through (nothing to do).
class DesktopShortcutHandler {
  DesktopShortcutHandler({required this.onShortcut, required this.isActive});

  final bool Function(DesktopShortcutMatch match) onShortcut;
  final bool Function() isActive;
  bool _attached = false;

  void attach() {
    if (_attached || !PlatformFeatures.isDesktop) return;
    _attached = true;
    HardwareKeyboard.instance.addHandler(_handle);
  }

  void detach() {
    if (!_attached) return;
    _attached = false;
    HardwareKeyboard.instance.removeHandler(_handle);
  }

  bool _handle(KeyEvent event) {
    final match = matchDesktopShortcut(event);
    if (match == null || !isActive()) return false;
    return onShortcut(match);
  }
}
