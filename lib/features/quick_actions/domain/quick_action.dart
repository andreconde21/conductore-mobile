import 'dart:convert';

import 'package:flutter/foundation.dart';

/// What running a quick action does.
enum QuickActionKind {
  /// Runs [QuickAction.command] in a terminal: a new one, or the terminal
  /// named [QuickAction.terminalName] when it is open.
  shell,

  /// Sends [QuickAction.command] to the project's agent as a prompt.
  prompt,

  /// Opens [QuickAction.command] (a URL) in the browser.
  url;

  static QuickActionKind parse(Object? raw) =>
      values.where((kind) => kind.name == raw).firstOrNull ??
      QuickActionKind.shell;
}

/// A project's quick action: a button in the toolbar, a palette entry and
/// a row of the session menu.
///
/// The format is Conductore Lite's workspace command (`id`, `label`,
/// `command`, `cwd`, `terminalName`), kept in the repo's `.code-workspace`
/// file under `commands`, plus optional fields Lite ignores: `icon`,
/// `keybinding`, `confirm`, `onWorktreeCreate` and `kind`. Personal ones
/// (in Settings, synced) use the same shape and may name a [project].
@immutable
class QuickAction {
  const QuickAction({
    required this.id,
    required this.label,
    required this.command,
    this.cwd,
    this.terminalName,
    this.icon,
    this.keybinding,
    this.confirm = false,
    this.onWorktreeCreate = false,
    this.kind = QuickActionKind.shell,
    this.project,
  });

  final String id;
  final String label;

  /// The shell command, the prompt text or the URL, per [kind].
  final String command;

  /// Where a shell command runs, relative to the repo (or absolute).
  final String? cwd;

  /// Runs in the terminal of this name, opening it when needed.
  final String? terminalName;

  /// A Material icon name (`play_arrow`, `bug_report`…), see [iconNames].
  final String? icon;

  /// Keys that run it, like `ctrl+shift+b` (VS Code's spelling).
  final String? keybinding;

  /// Asks before running (deploys, destructive commands).
  final bool confirm;

  /// Runs by itself when a worktree of the repo is created.
  final bool onWorktreeCreate;
  final QuickActionKind kind;

  /// Personal actions only: the project they show for (null for every
  /// project).
  final String? project;

  QuickAction copyWith({
    String? id,
    String? label,
    String? command,
    String? cwd,
    String? terminalName,
    String? icon,
    String? keybinding,
    bool? confirm,
    bool? onWorktreeCreate,
    QuickActionKind? kind,
    String? project,
  }) => QuickAction(
    id: id ?? this.id,
    label: label ?? this.label,
    command: command ?? this.command,
    cwd: cwd ?? this.cwd,
    terminalName: terminalName ?? this.terminalName,
    icon: icon ?? this.icon,
    keybinding: keybinding ?? this.keybinding,
    confirm: confirm ?? this.confirm,
    onWorktreeCreate: onWorktreeCreate ?? this.onWorktreeCreate,
    kind: kind ?? this.kind,
    project: project ?? this.project,
  );

  /// Lite's fields first, then ours only when set, so a file Lite wrote
  /// stays as Lite wrote it.
  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'command': command,
    if (_set(cwd)) 'cwd': cwd,
    if (_set(terminalName)) 'terminalName': terminalName,
    if (_set(icon)) 'icon': icon,
    if (_set(keybinding)) 'keybinding': keybinding,
    if (confirm) 'confirm': true,
    if (onWorktreeCreate) 'onWorktreeCreate': true,
    if (kind != QuickActionKind.shell) 'kind': kind.name,
    if (_set(project)) 'project': project,
  };

  static bool _set(String? value) => value != null && value.isNotEmpty;

  /// Null when [json] is not a usable action (no label or command).
  static QuickAction? fromJson(Object? json) {
    if (json is! Map) return null;
    String? text(String key) {
      final value = json[key];
      return value is String && value.trim().isNotEmpty ? value : null;
    }

    final label = text('label');
    final command = text('command');
    if (label == null || command == null) return null;
    return QuickAction(
      id: text('id') ?? _slug(label),
      label: label.trim(),
      command: command,
      cwd: text('cwd'),
      terminalName: text('terminalName'),
      icon: text('icon'),
      keybinding: text('keybinding'),
      confirm: json['confirm'] == true,
      onWorktreeCreate: json['onWorktreeCreate'] == true,
      kind: QuickActionKind.parse(json['kind']),
      project: text('project'),
    );
  }

  static List<QuickAction> listFromJson(Object? json) => [
    if (json is List)
      for (final item in json) ?QuickAction.fromJson(item),
  ];

  static String encodeList(List<QuickAction> actions) =>
      jsonEncode([for (final action in actions) action.toJson()]);

  static List<QuickAction> decodeList(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      return listFromJson(jsonDecode(raw));
    } on FormatException {
      return const [];
    }
  }

  static String _slug(String label) {
    final slug = label
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return slug.isEmpty ? 'action' : slug;
  }

  /// A fresh id for [label] that none of [taken] uses.
  static String newId(String label, Iterable<String> taken) {
    final base = _slug(label);
    final used = taken.toSet();
    if (!used.contains(base)) return base;
    for (var i = 2; ; i += 1) {
      if (!used.contains('$base-$i')) return '$base-$i';
    }
  }

  /// Whether this personal action shows for [projectName].
  bool appliesTo(String projectName) {
    final only = project?.trim() ?? '';
    return only.isEmpty || only.toLowerCase() == projectName.toLowerCase();
  }

  @override
  bool operator ==(Object other) =>
      other is QuickAction && mapEquals(other.toJson(), toJson());

  @override
  int get hashCode => Object.hashAll(toJson().values);

  @override
  String toString() => 'QuickAction($id, $label)';

  /// The icon names the editor offers (Material icons by name).
  static const iconNames = [
    'play_arrow',
    'build',
    'bug_report',
    'science',
    'rocket_launch',
    'cloud_upload',
    'sync',
    'terminal',
    'code',
    'description',
    'public',
    'smart_toy',
    'cleaning_services',
    'restart_alt',
    'bolt',
  ];
}

/// The `commands` of a `.code-workspace` file (JSON with comments and
/// trailing commas, as VS Code writes it). Unreadable files give none.
List<QuickAction> parseCodeWorkspaceCommands(String source) {
  final json = decodeJsonc(source);
  if (json is! Map) return const [];
  return QuickAction.listFromJson(json['commands']);
}

/// [source] (a `.code-workspace` file, or empty for a new one) with its
/// `commands` replaced by [actions]; every other key is kept. Comments do
/// not survive a rewrite (VS Code's own settings editor does the same).
/// Throws [FormatException] when [source] is not a JSON object.
String updateCodeWorkspaceCommands(String source, List<QuickAction> actions) {
  final Object? decoded = source.trim().isEmpty
      ? <String, Object?>{}
      : decodeJsonc(source);
  if (decoded is! Map) {
    throw const FormatException('The workspace file is not a JSON object.');
  }
  final updated = <String, Object?>{
    for (final MapEntry(:key, :value) in decoded.entries) '$key': value,
  };
  updated['commands'] = [for (final action in actions) action.toJson()];
  return '${const JsonEncoder.withIndent('  ').convert(updated)}\n';
}

/// Decodes JSON with `//` and `/* */` comments and trailing commas; null
/// when it still is not JSON.
Object? decodeJsonc(String source) {
  final out = StringBuffer();
  var i = 0;
  var inString = false;
  while (i < source.length) {
    final char = source[i];
    if (inString) {
      out.write(char);
      if (char == r'\' && i + 1 < source.length) {
        out.write(source[i + 1]);
        i += 2;
        continue;
      }
      if (char == '"') inString = false;
      i += 1;
      continue;
    }
    if (char == '"') {
      inString = true;
      out.write(char);
      i += 1;
      continue;
    }
    if (char == '/' && i + 1 < source.length) {
      final next = source[i + 1];
      if (next == '/') {
        final end = source.indexOf('\n', i);
        i = end < 0 ? source.length : end;
        continue;
      }
      if (next == '*') {
        final end = source.indexOf('*/', i + 2);
        i = end < 0 ? source.length : end + 2;
        continue;
      }
    }
    out.write(char);
    i += 1;
  }
  final withoutTrailingCommas = out.toString().replaceAllMapped(
    RegExp(r',(\s*[}\]])'),
    (match) => match.group(1)!,
  );
  try {
    return jsonDecode(withoutTrailingCommas);
  } on FormatException {
    return null;
  }
}
