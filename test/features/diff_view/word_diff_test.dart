import 'package:conduit/features/diff_view/domain/unified_diff.dart';
import 'package:conduit/features/diff_view/domain/word_diff.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('marks only the tokens that differ between a pair', () {
    final (old, fresh) = wordDiffPair(
      "runApp(const App(title: 'Old'));",
      "runApp(const App(title: 'New'));",
    );
    expect(old, [
      const WordDiffSpan("runApp(const App(title: '"),
      const WordDiffSpan('Old', changed: true),
      const WordDiffSpan("'));"),
    ]);
    expect(fresh, [
      const WordDiffSpan("runApp(const App(title: '"),
      const WordDiffSpan('New', changed: true),
      const WordDiffSpan("'));"),
    ]);
  });

  test('identical lines have no changed spans', () {
    final (old, fresh) = wordDiffPair('same', 'same');
    expect(old.single.changed, isFalse);
    expect(fresh.single.changed, isFalse);
  });

  test('pairs the i-th deletion with the i-th addition of a block', () {
    final hunk = UnifiedDiff.parse('''
diff --git a/x b/x
--- a/x
+++ b/x
@@ -1,3 +1,3 @@
-alpha one
-beta two
+alpha uno
+beta two
+gamma three
 context
''').files.single.hunks.single;
    final spans = wordDiffHunk(hunk);
    expect(spans.keys, unorderedEquals([0, 1, 2, 3]));
    expect(spans[0]!.where((span) => span.changed).map((s) => s.text), ['one']);
    expect(spans[2]!.where((span) => span.changed).map((s) => s.text), ['uno']);
    // "beta two" is unchanged on both sides.
    expect(spans[1]!.any((span) => span.changed), isFalse);
    expect(spans[3]!.any((span) => span.changed), isFalse);
    // The unpaired addition renders plain.
    expect(spans.containsKey(4), isFalse);
  });

  test('skips lines above the length cap', () {
    final long = 'x' * (wordDiffMaxLineLength + 1);
    final hunk = DiffHunk(
      header: '@@ -1 +1 @@',
      oldStart: 1,
      oldCount: 1,
      newStart: 1,
      newCount: 1,
      lines: [
        DiffLine(kind: DiffLineKind.deletion, text: long, oldLineNumber: 1),
        DiffLine(
          kind: DiffLineKind.addition,
          text: '${long}y',
          newLineNumber: 1,
        ),
      ],
    );
    expect(wordDiffHunk(hunk), isEmpty);
  });

  test('tokenizes words, whitespace runs and punctuation separately', () {
    expect(tokenizeForWordDiff('a_b  (c)'), ['a_b', '  ', '(', 'c', ')']);
  });
}
