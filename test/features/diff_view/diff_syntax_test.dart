import 'package:conduit/features/diff_view/domain/unified_diff.dart';
import 'package:conduit/features/diff_view/domain/word_diff.dart';
import 'package:conduit/features/diff_view/presentation/diff_syntax.dart';
import 'package:conduit/features/diff_view/presentation/diff_view_rows.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('languages by extension; plain text has none', () {
    expect(DiffSyntax.languageFor('lib/a.dart'), 'dart');
    expect(DiffSyntax.languageFor('src/x.ts'), 'typescript');
    expect(DiffSyntax.languageFor('notes.txt'), isNull);
  });

  test('a line is split into coloured runs that cover it exactly', () {
    const line = "final name = 'conductore'; // hi";
    final runs = DiffSyntax.highlight(line, 'dart', Brightness.dark)!;
    expect(runs.map((r) => r.text).join(), line);
    expect(runs.where((r) => r.style?.color != null), isNotEmpty);
    expect(DiffSyntax.highlight('x' * 700, 'dart', Brightness.dark), isNull);
  });

  test('word-diff marks are laid over the colours', () {
    const syntax = [
      (text: 'final ', style: TextStyle(color: Color(0xff0000ff))),
      (text: 'a = 2;', style: null),
    ];
    final runs = DiffSyntax.merge(syntax, const [
      WordDiffSpan('final a = '),
      WordDiffSpan('2', changed: true),
      WordDiffSpan(';'),
    ]);
    expect(runs.map((r) => r.text).join(), 'final a = 2;');
    expect(
      [
        for (final r in runs)
          if (r.changed) r.text,
      ],
      ['2'],
    );
    expect(runs.first.style?.color, const Color(0xff0000ff));
  });

  test('rows can leave out file headers and know their hunk offsets', () {
    final diff = UnifiedDiff.parse(
      'diff --git a/a.dart b/a.dart\n--- a/a.dart\n+++ b/a.dart\n'
      '@@ -1 +1 @@\n-a\n+b\n@@ -10 +10 @@\n-c\n+d\n',
    );
    final rows = DiffRows.build(
      diff,
      isCollapsed: (_) => false,
      fileHeaders: false,
    );
    expect(rows.rows.whereType<DiffFileHeaderRow>(), isEmpty);
    expect(rows.hunkOffsets, [0, diffHunkHeaderHeight + 2 * diffLineHeight]);
  });
}
