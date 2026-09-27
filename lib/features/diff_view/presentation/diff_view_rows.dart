import 'dart:math' as math;

import 'package:conduit/core/platform_features.dart';
import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/features/diff_view/domain/git_diff_source.dart';
import 'package:conduit/features/diff_view/domain/unified_diff.dart';
import 'package:conduit/features/diff_view/domain/word_diff.dart';
import 'package:conduit/features/diff_view/presentation/diff_syntax.dart';
import 'package:conduit/features/diff_view/presentation/diff_view.dart';
import 'package:flutter/material.dart';

/// Row heights are fixed so the list can jump to a file by arithmetic
/// instead of measuring, and so a 2 MB diff scrolls without layout passes.
const diffFileHeaderHeight = 40.0;
const diffHunkHeaderHeight = 26.0;
const diffLineHeight = 20.0;
const diffNoticeHeight = 56.0;

sealed class DiffRow {
  const DiffRow(this.file);

  final DiffFile file;
  double get height;
}

class DiffFileHeaderRow extends DiffRow {
  const DiffFileHeaderRow(super.file);

  @override
  double get height => diffFileHeaderHeight;
}

class DiffHunkHeaderRow extends DiffRow {
  const DiffHunkHeaderRow(super.file, this.hunk);

  final DiffHunk hunk;

  @override
  double get height => diffHunkHeaderHeight;
}

class DiffLineRow extends DiffRow {
  const DiffLineRow(super.file, this.line, {this.spans});

  final DiffLine line;

  /// Word-level highlight spans; null renders the line plain.
  final List<WordDiffSpan>? spans;

  @override
  double get height => diffLineHeight;
}

/// A one-line message inside a file (binary, or nothing to show).
class DiffNoticeRow extends DiffRow {
  const DiffNoticeRow(super.file, this.message);

  final String message;

  @override
  double get height => diffNoticeHeight;
}

/// A [UnifiedDiff] flattened into fixed-height rows for a lazy list.
class DiffRows {
  DiffRows._(this.rows, this._fileOffsets, this.maxLineLength);

  final List<DiffRow> rows;
  final Map<DiffFile, double> _fileOffsets;

  /// Longest rendered line in characters, for the horizontal extent.
  final int maxLineLength;

  /// [fileHeaders] false leaves out the per-file header rows (a view that
  /// shows one file under its own header, like Review's cards).
  static DiffRows build(
    UnifiedDiff diff, {
    required bool Function(DiffFile file) isCollapsed,
    bool wordDiff = true,
    bool fileHeaders = true,
  }) {
    final rows = <DiffRow>[];
    final offsets = <DiffFile, double>{};
    var offset = 0.0;
    var maxLength = 0;
    for (final file in diff.files) {
      offsets[file] = offset;
      if (fileHeaders) {
        rows.add(DiffFileHeaderRow(file));
        offset += diffFileHeaderHeight;
      }
      if (isCollapsed(file)) {
        continue;
      }
      if (file.binary) {
        rows.add(DiffNoticeRow(file, 'Binary file changed'));
        offset += diffNoticeHeight;
        continue;
      }
      if (file.hunks.isEmpty) {
        final message = switch (file.status) {
          DiffFileStatus.renamed => 'Renamed without content changes',
          DiffFileStatus.copied => 'Copied without content changes',
          _ => 'No content changes (mode or metadata only)',
        };
        rows.add(DiffNoticeRow(file, message));
        offset += diffNoticeHeight;
        continue;
      }
      for (final hunk in file.hunks) {
        rows.add(DiffHunkHeaderRow(file, hunk));
        offset += diffHunkHeaderHeight;
        maxLength = math.max(maxLength, hunk.header.length);
        final spans = wordDiff
            ? wordDiffHunk(hunk)
            : const <int, List<WordDiffSpan>>{};
        for (var index = 0; index < hunk.lines.length; index++) {
          final line = hunk.lines[index];
          rows.add(DiffLineRow(file, line, spans: spans[index]));
          offset += diffLineHeight;
          maxLength = math.max(maxLength, line.text.length);
        }
      }
    }
    return DiffRows._(rows, offsets, maxLength);
  }

  double get totalHeight => rows.fold(0.0, (total, row) => total + row.height);

  /// Vertical offset of [file]'s header, or null when it is not listed.
  double? offsetOfFile(DiffFile file) => _fileOffsets[file];

  /// Vertical offset of every hunk header, top to bottom (n / p jumps).
  List<double> get hunkOffsets {
    final out = <double>[];
    var offset = 0.0;
    for (final row in rows) {
      if (row is DiffHunkHeaderRow) out.add(offset);
      offset += row.height;
    }
    return out;
  }
}

/// Renders [DiffRows] as a vertically lazy, horizontally scrollable list.
class DiffRowsList extends StatelessWidget {
  const DiffRowsList({
    required this.rows,
    required this.scrollController,
    required this.palette,
    required this.brightness,
    required this.fontFamily,
    required this.fontSize,
    required this.truncated,
    required this.onToggleFile,
    required this.isCollapsed,
    this.onOpenFile,
    this.syntax = false,
    this.onTapLine,
    this.isLineMarked,
    super.key,
  });

  final DiffRows rows;
  final ScrollController scrollController;
  final AppPalette palette;
  final Brightness brightness;
  final String fontFamily;
  final double fontSize;
  final bool truncated;
  final ValueChanged<DiffFile> onToggleFile;
  final bool Function(DiffFile file) isCollapsed;
  final ValueChanged<DiffFile>? onOpenFile;

  /// Colours code by the file's language ([DiffSyntax]).
  final bool syntax;

  /// Tapping a line (Review's line comments); null: lines are not tappable.
  final void Function(DiffFile file, DiffLine line)? onTapLine;

  /// Lines drawn with a comment mark in the gutter.
  final bool Function(DiffFile file, DiffLine line)? isLineMarked;

  static const _gutterWidth = 92.0;
  static const _tabWidth = 4;

  @override
  Widget build(BuildContext context) {
    final textStyle = TextStyle(
      fontFamily: fontFamily,
      fontSize: fontSize,
      height: diffLineHeight / fontSize,
      color: palette.foregroundFor(brightness),
    );
    final charWidth = _measureCharWidth(textStyle);
    return LayoutBuilder(
      builder: (context, constraints) {
        final contentWidth = math.max(
          constraints.maxWidth,
          _gutterWidth + charWidth * (rows.maxLineLength + 2) + 16,
        );
        final rowCount = rows.rows.length + (truncated ? 1 : 0);
        return Scrollbar(
          controller: scrollController,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: contentWidth,
              child: ListView.builder(
                controller: scrollController,
                itemCount: rowCount,
                padding: const EdgeInsets.only(bottom: 24),
                itemBuilder: (context, index) {
                  if (index >= rows.rows.length) {
                    return _TruncatedNotice(
                      palette: palette,
                      brightness: brightness,
                      viewportWidth: constraints.maxWidth,
                    );
                  }
                  return _buildRow(
                    rows.rows[index],
                    textStyle,
                    constraints.maxWidth,
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  double _measureCharWidth(TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: 'M', style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }

  Widget _buildRow(DiffRow row, TextStyle textStyle, double viewportWidth) {
    return switch (row) {
      DiffFileHeaderRow() => _FileHeader(
        file: row.file,
        collapsed: isCollapsed(row.file),
        palette: palette,
        brightness: brightness,
        fontFamily: fontFamily,
        width: viewportWidth,
        onToggle: () => onToggleFile(row.file),
        onOpen: onOpenFile == null ? null : () => onOpenFile!(row.file),
      ),
      DiffHunkHeaderRow() => _HunkHeader(
        hunk: row.hunk,
        palette: palette,
        brightness: brightness,
        textStyle: textStyle,
      ),
      DiffNoticeRow() => SizedBox(
        height: diffNoticeHeight,
        width: viewportWidth,
        child: Center(
          child: Text(
            row.message,
            style: TextStyle(
              color: palette.mutedForegroundFor(brightness),
              fontSize: 12.5,
            ),
          ),
        ),
      ),
      DiffLineRow() => _LineRow(
        line: row.line,
        spans: row.spans,
        palette: palette,
        brightness: brightness,
        textStyle: textStyle,
        tabWidth: _tabWidth,
        gutterWidth: _gutterWidth,
        language: syntax && row.line.kind != DiffLineKind.meta
            ? DiffSyntax.languageFor(row.file.displayPath)
            : null,
        marked: isLineMarked?.call(row.file, row.line) ?? false,
        onTap: onTapLine == null || row.line.kind == DiffLineKind.meta
            ? null
            : () => onTapLine!(row.file, row.line),
      ),
    };
  }
}

class _FileHeader extends StatelessWidget {
  const _FileHeader({
    required this.file,
    required this.collapsed,
    required this.palette,
    required this.brightness,
    required this.fontFamily,
    required this.width,
    required this.onToggle,
    required this.onOpen,
  });

  final DiffFile file;
  final bool collapsed;
  final AppPalette palette;
  final Brightness brightness;
  final String fontFamily;
  final double width;
  final VoidCallback onToggle;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final muted = palette.mutedForegroundFor(brightness);
    final title =
        file.status == DiffFileStatus.renamed ||
            file.status == DiffFileStatus.copied
        ? '${file.oldPath} → ${file.newPath}'
        : file.displayPath;
    return Align(
      alignment: Alignment.centerLeft,
      child: SizedBox(
        height: diffFileHeaderHeight,
        width: width,
        child: Material(
          color: palette.panelFor(brightness),
          child: Row(
            children: [
              SizedBox(
                width: 40,
                height: diffFileHeaderHeight,
                child: IconButton(
                  tooltip: collapsed ? 'Expand' : 'Collapse',
                  iconSize: 18,
                  padding: EdgeInsets.zero,
                  color: muted,
                  icon: Icon(
                    collapsed
                        ? Icons.chevron_right_rounded
                        : Icons.expand_more_rounded,
                  ),
                  onPressed: onToggle,
                ),
              ),
              Expanded(
                child: InkWell(
                  onTap: onOpen ?? onToggle,
                  onLongPress: onToggle,
                  child: Row(
                    children: [
                      Icon(
                        fileStatusIcon(file),
                        size: 15,
                        color: fileStatusColor(file, palette),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: fontFamily,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: palette.foregroundFor(brightness),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      DiffCountsLabel(
                        additions: file.additions,
                        deletions: file.deletions,
                        palette: palette,
                      ),
                      if (onOpen != null)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Icon(
                            Icons.open_in_new_rounded,
                            size: 15,
                            color: muted,
                          ),
                        )
                      else
                        const SizedBox(width: 12),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HunkHeader extends StatelessWidget {
  const _HunkHeader({
    required this.hunk,
    required this.palette,
    required this.brightness,
    required this.textStyle,
  });

  final DiffHunk hunk;
  final AppPalette palette;
  final Brightness brightness;
  final TextStyle textStyle;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: diffHunkHeaderHeight,
      color: palette.accent.withValues(alpha: 0.08),
      padding: const EdgeInsets.only(left: 12),
      alignment: Alignment.centerLeft,
      child: Text(
        hunk.header,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.visible,
        style: textStyle.copyWith(
          color: palette.accent,
          fontSize: textStyle.fontSize! - 1,
        ),
      ),
    );
  }
}

class _LineRow extends StatelessWidget {
  const _LineRow({
    required this.line,
    required this.spans,
    required this.palette,
    required this.brightness,
    required this.textStyle,
    required this.tabWidth,
    required this.gutterWidth,
    this.language,
    this.marked = false,
    this.onTap,
  });

  final DiffLine line;
  final List<WordDiffSpan>? spans;

  /// Syntax language id, or null for plain text.
  final String? language;

  /// Has a comment (Review).
  final bool marked;
  final VoidCallback? onTap;
  final AppPalette palette;
  final Brightness brightness;
  final TextStyle textStyle;
  final int tabWidth;
  final double gutterWidth;

  @override
  Widget build(BuildContext context) {
    final muted = palette.mutedForegroundFor(brightness);
    final (background, highlight, marker) = switch (line.kind) {
      DiffLineKind.addition => (
        palette.success.withValues(alpha: 0.14),
        palette.success.withValues(alpha: 0.38),
        '+',
      ),
      DiffLineKind.deletion => (
        palette.danger.withValues(alpha: 0.14),
        palette.danger.withValues(alpha: 0.38),
        '-',
      ),
      DiffLineKind.context => (Colors.transparent, Colors.transparent, ' '),
      DiffLineKind.meta => (Colors.transparent, Colors.transparent, ' '),
    };
    final gutterStyle = textStyle.copyWith(color: muted);
    final contentStyle = line.kind == DiffLineKind.meta
        ? textStyle.copyWith(color: muted, fontStyle: FontStyle.italic)
        : textStyle;
    final expanded = line.text.replaceAll('\t', ' ' * tabWidth);
    final Widget content;
    final wordSpans = spans;
    final colours = language == null
        ? null
        : DiffSyntax.highlight(expanded, language!, brightness);
    if (colours != null) {
      final runs = DiffSyntax.merge(colours, [
        for (final span in wordSpans ?? const <WordDiffSpan>[])
          WordDiffSpan(
            span.text.replaceAll('\t', ' ' * tabWidth),
            changed: span.changed,
          ),
      ]);
      content = Text.rich(
        TextSpan(
          style: contentStyle,
          children: [
            for (final run in runs)
              TextSpan(
                text: run.text,
                style: run.changed
                    ? (run.style ?? const TextStyle()).copyWith(
                        backgroundColor: highlight,
                      )
                    : run.style,
              ),
          ],
        ),
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.visible,
      );
    } else if (wordSpans == null || wordSpans.every((span) => !span.changed)) {
      content = Text(
        expanded,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.visible,
        style: contentStyle,
      );
    } else {
      content = Text.rich(
        TextSpan(
          style: contentStyle,
          children: [
            for (final span in wordSpans)
              TextSpan(
                text: span.text.replaceAll('\t', ' ' * tabWidth),
                style: span.changed
                    ? TextStyle(backgroundColor: highlight)
                    : null,
              ),
          ],
        ),
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.visible,
      );
    }
    final row = Container(
      height: diffLineHeight,
      color: background,
      child: Row(
        children: [
          SizedBox(
            width: gutterWidth,
            child: Row(
              children: [
                SizedBox(
                  width: 38,
                  child: Text(
                    line.oldLineNumber?.toString() ?? '',
                    textAlign: TextAlign.right,
                    style: gutterStyle,
                  ),
                ),
                SizedBox(
                  width: 38,
                  child: Text(
                    line.newLineNumber?.toString() ?? '',
                    textAlign: TextAlign.right,
                    style: gutterStyle,
                  ),
                ),
                SizedBox(
                  width: 16,
                  child: marked
                      ? Icon(
                          Icons.mode_comment_rounded,
                          size: 12,
                          color: palette.accent,
                        )
                      : Text(
                          marker,
                          textAlign: TextAlign.center,
                          style: textStyle.copyWith(
                            color: switch (line.kind) {
                              DiffLineKind.addition => palette.success,
                              DiffLineKind.deletion => palette.danger,
                              _ => muted,
                            },
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                ),
              ],
            ),
          ),
          content,
        ],
      ),
    );
    final tap = onTap;
    if (tap == null) return row;
    if (PlatformFeatures.isDesktop) {
      return _ClickableLine(onTap: tap, child: row);
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: tap,
      child: row,
    );
  }
}

/// A tappable diff line on desktop: the click cursor and a faint tint
/// under the mouse, so the line reads as clickable (to comment on it).
class _ClickableLine extends StatefulWidget {
  const _ClickableLine({required this.onTap, required this.child});

  final VoidCallback onTap;
  final Widget child;

  @override
  State<_ClickableLine> createState() => _ClickableLineState();
}

class _ClickableLineState extends State<_ClickableLine> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final tint = Theme.of(
      context,
    ).colorScheme.onSurface.withValues(alpha: 0.06);
    return MouseRegion(
      key: const ValueKey('diff-line-clickable'),
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(
            color: _hovered ? tint : Colors.transparent,
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

class _TruncatedNotice extends StatelessWidget {
  const _TruncatedNotice({
    required this.palette,
    required this.brightness,
    required this.viewportWidth,
  });

  final AppPalette palette;
  final Brightness brightness;
  final double viewportWidth;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        width: viewportWidth,
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(Icons.warning_amber_rounded, size: 18, color: palette.warning),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Diff cut at ${gitDiffMaxBytes ~/ (1024 * 1024)} MB. '
                'Narrow it down on the host to see the rest.',
                style: TextStyle(
                  color: palette.mutedForegroundFor(brightness),
                  fontSize: 12.5,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
