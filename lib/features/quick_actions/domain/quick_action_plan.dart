import 'package:conduit/features/quick_actions/domain/quick_action.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// What running a quick action comes down to.
sealed class QuickActionPlan {
  const QuickActionPlan();
}

/// Open a URL in the browser.
class OpenUrlPlan extends QuickActionPlan {
  const OpenUrlPlan(this.uri);

  final Uri uri;
}

/// Send a prompt to the project's agent.
class SendPromptPlan extends QuickActionPlan {
  const SendPromptPlan(this.text);

  final String text;
}

/// Run a shell command: in the open terminal named [terminalName] when
/// there is one, else in a new terminal at [directory].
class RunInTerminalPlan extends QuickActionPlan {
  const RunInTerminalPlan({
    required this.command,
    this.directory,
    this.terminalName,
  });

  final String command;

  /// Where a new terminal starts; null: the machine's default.
  final String? directory;
  final String? terminalName;
}

/// The action cannot run (a URL that is not one).
class InvalidPlan extends QuickActionPlan {
  const InvalidPlan(this.reason);

  final String reason;
}

/// How [action] runs for a project whose repo is at [root] (null when it
/// is not known: a shell command then starts where the machine's shell
/// does, or in the action's own absolute `cwd`).
QuickActionPlan planQuickAction(QuickAction action, {String? root}) {
  switch (action.kind) {
    case QuickActionKind.url:
      final raw = action.command.trim();
      final uri = Uri.tryParse(raw.contains('://') ? raw : 'https://$raw');
      if (uri == null || uri.host.isEmpty) {
        return InvalidPlan('"$raw" is not a web address.');
      }
      return OpenUrlPlan(uri);
    case QuickActionKind.prompt:
      return SendPromptPlan(action.command.trim());
    case QuickActionKind.shell:
      return RunInTerminalPlan(
        command: action.command,
        directory: resolveActionDirectory(action.cwd, root),
        terminalName: action.terminalName,
      );
  }
}

/// A command's working directory: an absolute [cwd] as is, a relative one
/// under [root], else [root].
String? resolveActionDirectory(String? cwd, String? root) {
  final dir = cwd?.trim() ?? '';
  if (dir.isEmpty || dir == '.') return root;
  if (dir.startsWith('/') || dir.startsWith('~')) return dir;
  if (root == null || root.isEmpty) return null;
  final base = root.endsWith('/') ? root.substring(0, root.length - 1) : root;
  final relative = dir.startsWith('./') ? dir.substring(2) : dir;
  return '$base/$relative';
}

/// A parsed `keybinding` ("ctrl+shift+b", "cmd+alt+t", "f5").
@immutable
class QuickActionKeys {
  const QuickActionKeys({
    required this.key,
    this.control = false,
    this.shift = false,
    this.alt = false,
    this.meta = false,
  });

  final LogicalKeyboardKey key;
  final bool control;
  final bool shift;
  final bool alt;
  final bool meta;

  /// Null when [spec] names no key this app knows.
  static QuickActionKeys? parse(String? spec) {
    if (spec == null || spec.trim().isEmpty) return null;
    var control = false, shift = false, alt = false, meta = false;
    LogicalKeyboardKey? key;
    for (final part in spec.toLowerCase().split('+')) {
      final token = part.trim();
      switch (token) {
        case 'ctrl' || 'control':
          control = true;
        case 'shift':
          shift = true;
        case 'alt' || 'option' || 'opt':
          alt = true;
        case 'cmd' || 'meta' || 'super' || 'win':
          meta = true;
        default:
          if (key != null) return null;
          key = _keyNamed(token);
          if (key == null) return null;
      }
    }
    if (key == null) return null;
    return QuickActionKeys(
      key: key,
      control: control,
      shift: shift,
      alt: alt,
      meta: meta,
    );
  }

  /// A plain letter without Ctrl, Alt or Cmd would steal typing: those
  /// bindings are refused.
  bool get safe =>
      control || alt || meta || !_typing.contains(key) || _isFunctionKey(key);

  bool matches(KeyEvent event, {required Set<LogicalKeyboardKey> pressed}) {
    if (event is! KeyDownEvent || event.logicalKey != key) return false;
    bool any(Set<LogicalKeyboardKey> keys) => keys.any(pressed.contains);
    return any(_controls) == control &&
        any(_shifts) == shift &&
        any(_alts) == alt &&
        any(_metas) == meta;
  }

  /// "Ctrl+Shift+B", for tooltips and the palette.
  String get label => [
    if (control) 'Ctrl',
    if (alt) 'Alt',
    if (shift) 'Shift',
    if (meta) defaultTargetPlatform == TargetPlatform.macOS ? 'Cmd' : 'Super',
    key.keyLabel.length == 1 ? key.keyLabel.toUpperCase() : key.keyLabel,
  ].join('+');

  static bool _isFunctionKey(LogicalKeyboardKey key) =>
      _functionKeys.contains(key);

  static LogicalKeyboardKey? _keyNamed(String name) {
    if (name.length == 1) {
      final code = name.codeUnitAt(0);
      if (code >= 0x61 && code <= 0x7a) {
        return LogicalKeyboardKey(LogicalKeyboardKey.keyA.keyId + code - 0x61);
      }
      if (code >= 0x30 && code <= 0x39) {
        return LogicalKeyboardKey(
          LogicalKeyboardKey.digit0.keyId + code - 0x30,
        );
      }
    }
    final match = RegExp(r'^f(\d{1,2})$').firstMatch(name);
    if (match != null) {
      final n = int.parse(match.group(1)!);
      if (n >= 1 && n <= 12) return _functionKeys[n - 1];
    }
    return switch (name) {
      'enter' || 'return' => LogicalKeyboardKey.enter,
      'space' => LogicalKeyboardKey.space,
      'tab' => LogicalKeyboardKey.tab,
      'escape' || 'esc' => LogicalKeyboardKey.escape,
      'backspace' => LogicalKeyboardKey.backspace,
      'delete' => LogicalKeyboardKey.delete,
      'up' => LogicalKeyboardKey.arrowUp,
      'down' => LogicalKeyboardKey.arrowDown,
      'left' => LogicalKeyboardKey.arrowLeft,
      'right' => LogicalKeyboardKey.arrowRight,
      _ => null,
    };
  }

  static const _functionKeys = [
    LogicalKeyboardKey.f1,
    LogicalKeyboardKey.f2,
    LogicalKeyboardKey.f3,
    LogicalKeyboardKey.f4,
    LogicalKeyboardKey.f5,
    LogicalKeyboardKey.f6,
    LogicalKeyboardKey.f7,
    LogicalKeyboardKey.f8,
    LogicalKeyboardKey.f9,
    LogicalKeyboardKey.f10,
    LogicalKeyboardKey.f11,
    LogicalKeyboardKey.f12,
  ];

  static final Set<LogicalKeyboardKey> _typing = {
    for (var i = 0; i < 26; i += 1)
      LogicalKeyboardKey(LogicalKeyboardKey.keyA.keyId + i),
    for (var i = 0; i < 10; i += 1)
      LogicalKeyboardKey(LogicalKeyboardKey.digit0.keyId + i),
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.space,
    LogicalKeyboardKey.tab,
    LogicalKeyboardKey.escape,
    LogicalKeyboardKey.backspace,
    LogicalKeyboardKey.delete,
    LogicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.arrowDown,
    LogicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.arrowRight,
  };

  static final _controls = <LogicalKeyboardKey>{
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.controlRight,
  };
  static final _shifts = <LogicalKeyboardKey>{
    LogicalKeyboardKey.shiftLeft,
    LogicalKeyboardKey.shiftRight,
  };
  static final _alts = <LogicalKeyboardKey>{
    LogicalKeyboardKey.altLeft,
    LogicalKeyboardKey.altRight,
  };
  static final _metas = <LogicalKeyboardKey>{
    LogicalKeyboardKey.metaLeft,
    LogicalKeyboardKey.metaRight,
  };
}
