import 'dart:math' as math;

import 'package:conduit_vt/conduit_vt.dart';
import 'package:flutter/foundation.dart';

/// A downscaled text snapshot of a terminal's viewport for the session grid.
class TerminalPreview {
  const TerminalPreview(this.lines);

  static const empty = TerminalPreview([]);

  /// Visible rows, oldest first, each already cut to the preview width.
  final List<String> lines;

  bool get isEmpty => lines.isEmpty;

  /// Captures the last [rows] non-blank rows of the current viewport (the
  /// alternate screen when a full-screen app is active), each truncated to
  /// [columns] characters. Trailing blank rows are dropped so a mostly
  /// empty screen shows its content instead of whitespace.
  static TerminalPreview capture(
    Terminal terminal, {
    int rows = 12,
    int columns = 48,
  }) {
    final buffer = terminal.buffer;
    final height = buffer.height;
    final viewHeight = math.max(1, terminal.viewHeight);
    final start = math.max(0, height - viewHeight);
    final lines = <String>[];
    for (var index = start; index < height; index++) {
      final line = buffer.lines[index];
      lines.add(line.getText(0, math.min(columns, line.length)));
    }
    var end = lines.length;
    while (end > 0 && lines[end - 1].trim().isEmpty) {
      end -= 1;
    }
    final begin = math.max(0, end - rows);
    return TerminalPreview(lines.sublist(begin, end));
  }

  /// The last [rows] non-blank rows of [preview], each cut to [columns].
  factory TerminalPreview.fromStyled(
    StyledTerminalPreview preview, {
    int rows = 12,
    int columns = 48,
  }) {
    final lines = [
      for (final line in preview.lines)
        line.length > columns ? line.substring(0, columns) : line,
    ];
    var end = lines.length;
    while (end > 0 && lines[end - 1].trim().isEmpty) {
      end -= 1;
    }
    return TerminalPreview(lines.sublist(math.max(0, end - rows), end));
  }

  @override
  bool operator ==(Object other) {
    if (other is! TerminalPreview || other.lines.length != lines.length) {
      return false;
    }
    for (var index = 0; index < lines.length; index++) {
      if (other.lines[index] != lines[index]) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(lines);
}

/// One run of cells in a [StyledTerminalPreview] row that share colours
/// and attributes. Colours are the terminal's raw cell encoding (see
/// `CellColor`); [LiveTerminalPreview] resolves them against a theme.
class PreviewRun {
  const PreviewRun(this.text, this.foreground, this.background, this.flags);

  final String text;
  final int foreground;
  final int background;
  final int flags;

  @override
  bool operator ==(Object other) =>
      other is PreviewRun &&
      other.text == text &&
      other.foreground == foreground &&
      other.background == background &&
      other.flags == flags;

  @override
  int get hashCode => Object.hash(text, foreground, background, flags);
}

/// A snapshot of a terminal's visible screen with colours and attributes,
/// for live preview tiles.
class StyledTerminalPreview {
  const StyledTerminalPreview(this.rows, {required this.columns});

  static const empty = StyledTerminalPreview([], columns: 80);

  /// Visible rows, top first, trailing blank rows dropped.
  final List<List<PreviewRun>> rows;

  /// Width of the captured screen in cells; the renderer fits this many
  /// columns into the tile width.
  final int columns;

  bool get isEmpty => rows.isEmpty;

  /// Plain text of each row (tests and accessibility).
  List<String> get lines => [
    for (final row in rows) row.map((run) => run.text).join(),
  ];

  /// Captures the current viewport (the alternate screen when a full-screen
  /// app is active) at its full width, keeping at most the last [maxRows]
  /// non-blank rows.
  static StyledTerminalPreview capture(Terminal terminal, {int maxRows = 80}) {
    final buffer = terminal.buffer;
    final height = buffer.height;
    final columns = math.max(1, terminal.viewWidth);
    final viewHeight = math.max(1, terminal.viewHeight);
    final start = math.max(0, height - viewHeight);
    final rows = <List<PreviewRun>>[];
    final blank = <bool>[];
    for (var index = start; index < height; index++) {
      final row = _captureLine(buffer.lines[index], columns);
      rows.add(row);
      blank.add(
        row.every((run) => run.text.trim().isEmpty && run.background == 0),
      );
    }
    var end = rows.length;
    while (end > 0 && blank[end - 1]) {
      end -= 1;
    }
    final begin = math.max(0, end - maxRows);
    return StyledTerminalPreview(rows.sublist(begin, end), columns: columns);
  }

  static List<PreviewRun> _captureLine(BufferLine line, int columns) {
    final runs = <PreviewRun>[];
    final text = StringBuffer();
    var foreground = 0;
    var background = 0;
    var flags = 0;
    var started = false;
    final limit = math.min(columns, line.length);
    for (var index = 0; index < limit; index++) {
      final codePoint = line.getCodePoint(index);
      if (codePoint == 0 && index > 0 && line.getWidth(index - 1) == 2) {
        // Second half of a wide character.
        continue;
      }
      final fg = line.getForeground(index);
      final bg = line.getBackground(index);
      final attrs = line.getAttributes(index);
      if (started && (fg != foreground || bg != background || attrs != flags)) {
        runs.add(PreviewRun(text.toString(), foreground, background, flags));
        text.clear();
      }
      started = true;
      foreground = fg;
      background = bg;
      flags = attrs;
      text.writeCharCode(codePoint == 0 ? 0x20 : codePoint);
    }
    if (started) {
      runs.add(PreviewRun(text.toString(), foreground, background, flags));
    }
    return runs;
  }

  @override
  bool operator ==(Object other) {
    if (other is! StyledTerminalPreview ||
        other.columns != columns ||
        other.rows.length != rows.length) {
      return false;
    }
    for (var index = 0; index < rows.length; index++) {
      final a = rows[index];
      final b = other.rows[index];
      if (a.length != b.length) return false;
      for (var run = 0; run < a.length; run++) {
        if (a[run] != b[run]) return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
    columns,
    Object.hashAll([for (final row in rows) Object.hashAll(row)]),
  );
}

/// What a Herdr session's screen showed the last time its Herdr server's
/// focus was on it.
///
/// Every client of one Herdr server shows the same focused workspace, so a
/// session whose server is focused for another session mirrors that one's
/// screen. Its previews show this snapshot instead, with its time.
@immutable
class SharedViewSnapshot {
  const SharedViewSnapshot({
    required this.preview,
    required this.capturedAt,
    this.label = '',
  });

  /// Captures [terminal] as it is now.
  factory SharedViewSnapshot.capture(
    Terminal terminal, {
    String label = '',
    DateTime? at,
  }) => SharedViewSnapshot(
    preview: StyledTerminalPreview.capture(terminal),
    capturedAt: at ?? DateTime.now(),
    label: label,
  );

  final StyledTerminalPreview preview;
  final DateTime capturedAt;

  /// The Herdr workspace the session is on, when known.
  final String label;

  /// The last line of [preview] worth a one-line preview (see
  /// [meaningfulTail]).
  String get tail => meaningfulTail(preview.lines);

  /// "05:54": when it was taken, for the tile's caption.
  String get timeLabel {
    String two(int value) => value.toString().padLeft(2, '0');
    final local = capturedAt.toLocal();
    return '${two(local.hour)}:${two(local.minute)}';
  }
}

/// Whether [line] is a coding agent's own chrome rather than what it is
/// doing: Claude Code's mode footer ("⏵⏵ auto mode on (alt+m to cycle) · ←
/// for agents"), shortcut hints, the empty prompt box and its rules, and
/// Codex's context gauge. A one-line preview skips these.
bool isAgentChromeLine(String line) {
  final text = line.trim();
  if (text.isEmpty) return true;
  if (text.startsWith('⏵') || text.startsWith('⏸')) return true;
  if (_chromeHints.any(text.contains)) return true;
  return _chromePatterns.any((pattern) => pattern.hasMatch(text));
}

const _chromeHints = [
  'to cycle)',
  '← for agents',
  '? for shortcuts',
  'esc to interrupt',
  'ctrl+p commands',
];

final _chromePatterns = [
  RegExp(
    r'^(auto mode|accept edits|plan mode|bypass permissions) on\b',
    caseSensitive: false,
  ),
  // Rules and the empty prompt box ("╭───", "│ > │", "❯").
  RegExp(r'^[─━═╌┄\-╭╮╰╯│|\s]+$'),
  RegExp(r'^[│|]?\s*[>❯›]\s*[│|]?$'),
  RegExp(r'\b\d{1,3}% context left\b'),
];

/// The last line of [lines] worth a one-line preview: not blank and not
/// agent chrome ([isAgentChromeLine]), looking back at most [lookBack]
/// lines; empty when there is none.
String meaningfulTail(List<String> lines, {int lookBack = 12}) {
  var seen = 0;
  for (final line in lines.reversed) {
    if (line.trim().isEmpty) continue;
    if (++seen > lookBack) break;
    if (!isAgentChromeLine(line)) return line.trim();
  }
  return '';
}

/// [text] with the media-control arrows agents draw (⏵ ⏴ ⏸), which the
/// bundled monospace fonts lack, swapped for look-alikes they have.
String withPreviewGlyphs(String text) => text
    .replaceAll('⏵', '▸')
    .replaceAll('⏴', '◂')
    .replaceAll('⏶', '▴')
    .replaceAll('⏷', '▾')
    .replaceAll('⏸', '‖');

/// Bundled fonts to fall back on in previews: JetBrains Mono Nerd Font has
/// the arrows and box drawing the other monospace choices lack.
const previewFontFallback = ['JetBrainsMonoNerdFontMono'];
