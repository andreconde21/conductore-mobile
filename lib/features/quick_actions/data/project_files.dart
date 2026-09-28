import 'dart:convert';

import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/quick_actions/domain/quick_action.dart';
import 'package:flutter/foundation.dart';

/// What the Projects tab reads from a repo on its machine: the icon and
/// the `.code-workspace` file with its quick actions.
@immutable
class ProjectFiles {
  const ProjectFiles({
    required this.root,
    this.icon,
    this.iconPath,
    this.workspaceFile,
    this.workspaceSource = '',
  });

  /// The repo's top directory (git's, else the directory asked about).
  final String root;

  /// The favicon or app icon (PNG, ICO, JPEG, GIF, WebP), when one small
  /// enough was found.
  final Uint8List? icon;
  final String? iconPath;

  /// The `.code-workspace` file's name in [root], if there is one.
  final String? workspaceFile;
  final String workspaceSource;

  List<QuickAction> get actions => parseCodeWorkspaceCommands(workspaceSource);

  /// Where a new workspace file goes: Lite's `<repo>.code-workspace`.
  String get workspaceFileOrDefault {
    if (workspaceFile case final file?) return file;
    final name = root.split('/').where((part) => part.isNotEmpty).lastOrNull;
    return '${name ?? 'project'}.code-workspace';
  }
}

/// Reads and writes project files with one short shell command each, over
/// the machine's command channel (the companion monitor's connection).
abstract final class ProjectFilesCommands {
  /// Icons are looked for in this order; the first under [maxIconBytes]
  /// wins. SVG is left out (no SVG decoder in the app).
  static const iconCandidates = [
    'favicon.ico',
    'favicon.png',
    'public/favicon.ico',
    'public/favicon.png',
    'public/apple-touch-icon.png',
    'public/icon.png',
    'static/favicon.ico',
    'static/favicon.png',
    'app/favicon.ico',
    'src/app/favicon.ico',
    'src/favicon.ico',
    'web/favicon.png',
    'assets/icon.png',
    'assets/icon/icon.png',
    'assets/favicon.png',
    'wwwroot/favicon.ico',
    'icon.png',
    'logo.png',
    '.github/logo.png',
  ];

  static const maxIconBytes = 96 * 1024;
  static const maxWorkspaceBytes = 256 * 1024;

  static String _q(String value) => "'${value.replaceAll("'", r"'\''")}'";

  /// Prints `ROOT`, then `ICON` and `WORKSPACE` lines (base64 content) for
  /// the repo containing [directory].
  static String read(String directory) {
    final dir = directory.startsWith('~/')
        ? '"\$HOME"/${_q(directory.substring(2))}'
        : _q(directory);
    final icons = iconCandidates.map(_q).join(' ');
    return _readScript
        .replaceAll('@DIR@', dir)
        .replaceAll('@ICONS@', icons)
        .replaceAll('@MAXICON@', '$maxIconBytes')
        .replaceAll('@MAXWS@', '$maxWorkspaceBytes');
  }

  static const _readScript = r"""
cd @DIR@ 2>/dev/null || exit 3
root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$root" || exit 3
printf 'ROOT\t%s\n' "$root"
for f in @ICONS@; do
  if [ -f "$f" ] && [ "$(wc -c < "$f")" -le @MAXICON@ ]; then
    printf 'ICON\t%s\t' "$f"; base64 < "$f" | tr -d '\n'; echo; break
  fi
done
for w in *.code-workspace; do
  if [ -f "$w" ] && [ "$(wc -c < "$w")" -le @MAXWS@ ]; then
    printf 'WORKSPACE\t%s\t' "$w"; base64 < "$w" | tr -d '\n'; echo; break
  fi
done
""";

  /// Writes [content] to [file] in [root] (through base64, so no quoting
  /// can go wrong), keeping a `.bak` of the previous file.
  static String write(String root, String file, String content) {
    final encoded = base64.encode(utf8.encode(content));
    final path = '${root.endsWith('/') ? root : '$root/'}$file';
    return [
      'set -e',
      'f=${_q(path)}',
      r'if [ -f "$f" ]; then cp "$f" "$f.bak"; fi',
      "printf '%s' ${_q(encoded)} | base64 -d > \"\$f.tmp\"",
      r'mv "$f.tmp" "$f"',
    ].join('\n');
  }

  /// Reads [read]'s output; null without a `ROOT` line.
  static ProjectFiles? parse(String stdout) {
    String? root;
    Uint8List? icon;
    String? iconPath;
    String? workspaceFile;
    var workspaceSource = '';
    for (final line in const LineSplitter().convert(stdout)) {
      final parts = line.split('\t');
      switch (parts.first) {
        case 'ROOT' when parts.length >= 2:
          root = parts[1].trim();
        case 'ICON' when parts.length >= 3:
          try {
            icon = base64.decode(parts[2].trim());
            iconPath = parts[1];
          } on FormatException {
            icon = null;
          }
        case 'WORKSPACE' when parts.length >= 3:
          try {
            workspaceSource = utf8.decode(
              base64.decode(parts[2].trim()),
              allowMalformed: true,
            );
            workspaceFile = parts[1];
          } on FormatException {
            workspaceSource = '';
          }
      }
    }
    if (root == null || root.isEmpty) return null;
    return ProjectFiles(
      root: root,
      icon: icon == null || icon.isEmpty ? null : icon,
      iconPath: icon == null ? null : iconPath,
      workspaceFile: workspaceFile,
      workspaceSource: workspaceSource,
    );
  }

  static const timeout = Duration(seconds: 10);

  static Future<ProjectFiles?> load(
    AgentCommandRunner runner,
    String directory,
  ) async {
    final result = await runner.run(read(directory), timeout: timeout);
    return parse(result.stdout);
  }

  static Future<void> save(
    AgentCommandRunner runner, {
    required String root,
    required String file,
    required String content,
  }) async {
    final result = await runner.run(
      write(root, file, content),
      timeout: timeout,
    );
    if ((result.exitCode ?? 0) != 0) {
      final error = result.stderr.trim();
      throw StateError(
        error.isEmpty
            ? 'Could not write $file.'
            : 'Could not write $file: $error',
      );
    }
  }
}
