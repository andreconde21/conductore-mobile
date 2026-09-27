import 'package:conduit/features/chat_view/domain/markdown_table.dart';
import 'package:conduit/features/chat_view/presentation/widgets/chat_markdown.dart';
import 'package:conduit/features/voice/domain/speech_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

MarkdownTable parse(String text) {
  final lines = text.split('\n');
  final result = MarkdownTables.tryParse(lines, 0);
  expect(result, isNotNull, reason: text);
  return result!.$1;
}

void main() {
  group('parsing', () {
    test('header, alignment and body rows', () {
      final table = parse(
        '| Name | Count | Note |\n'
        '|:-----|:-----:|-----:|\n'
        '| a | 1 | x |\n'
        '| b | 2 | y |',
      );
      expect(table.headers, ['Name', 'Count', 'Note']);
      expect(table.aligns, [
        MarkdownTableAlign.start,
        MarkdownTableAlign.center,
        MarkdownTableAlign.end,
      ]);
      expect(table.rows, [
        ['a', '1', 'x'],
        ['b', '2', 'y'],
      ]);
    });

    test('missing outer pipes and trailing pipe', () {
      final table = parse('a | b\n--- | ---\n1 | 2\n| 3 | 4');
      expect(table.headers, ['a', 'b']);
      expect(table.rows, [
        ['1', '2'],
        ['3', '4'],
      ]);
    });

    test('uneven rows are padded or cut to the header', () {
      final table = parse(
        '| a | b | c |\n|---|---|---|\n| 1 |\n| 1 | 2 | 3 | 4 |',
      );
      expect(table.rows, [
        ['1', '', ''],
        ['1', '2', '3'],
      ]);
    });

    test('escaped pipes and pipes in code stay in the cell', () {
      final table = parse(
        '| expr | means |\n|---|---|\n| `a | b` | or \\| pipe |',
      );
      expect(table.rows.single, ['`a | b`', 'or | pipe']);
    });

    test('ends at a blank line or a line without pipes', () {
      final lines = '| a |\n|---|\n| 1 |\n\n| 2 |'.split('\n');
      final (table, span) = MarkdownTables.tryParse(lines, 0)!;
      expect(table.rows, hasLength(1));
      expect(span, 3);
      final (_, span2) = MarkdownTables.tryParse(
        '| a |\n|---|\nplain'.split('\n'),
        0,
      )!;
      expect(span2, 2);
    });

    test('pipes without a delimiter row are not a table', () {
      expect(MarkdownTables.tryParse(['| a | b |', '| 1 | 2 |'], 0), isNull);
      expect(MarkdownTables.tryParse(['a | b', 'text'], 0), isNull);
      expect(MarkdownTables.tryParse(['just text', '---'], 0), isNull);
    });
  });

  test('read aloud says the shape, not the cells', () {
    expect(
      SpeechText.fromMarkdown(
        'Results:\n\n| a | b |\n|---|---|\n| secret | 2 |\n| x | 3 |\n\nDone',
      ),
      'Results: Table with 2 rows. Done.',
    );
  });

  Future<void> pump(WidgetTester tester, String markdown, double width) async {
    tester.view.physicalSize = Size(width, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: ChatMarkdown(markdown)),
        ),
      ),
    );
  }

  testWidgets('renders a real table with a bold header and inline Markdown', (
    tester,
  ) async {
    await pump(
      tester,
      '| Name | Status |\n|---|:-:|\n| **api** | `ok` |\n| [docs](https://x.dev) | 2 |',
      800,
    );
    expect(find.byKey(const ValueKey('markdown-table')), findsOneWidget);
    expect(find.byKey(const ValueKey('markdown-table-scroll')), findsNothing);
    Text textOf(String value) => tester.widget<Text>(
      find.byWidgetPredicate(
        (w) => w is Text && (w.textSpan?.toPlainText() ?? w.data) == value,
      ),
    );
    final header = textOf('Name');
    expect(header.style?.fontWeight, FontWeight.w700);
    expect(find.text('api', findRichText: true), findsOneWidget);
    final status = textOf('2');
    expect(status.textAlign, TextAlign.center);
    expect(find.textContaining('|'), findsNothing);
  });

  testWidgets('a wide table scrolls sideways instead of squashing', (
    tester,
  ) async {
    final header = List.generate(8, (i) => 'Column number $i').join(' | ');
    final delimiter = List.filled(8, '---').join(' | ');
    final row = List.generate(8, (i) => 'value $i with words').join(' | ');
    await pump(tester, '| $header |\n| $delimiter |\n| $row |', 360);
    expect(find.byKey(const ValueKey('markdown-table-scroll')), findsOneWidget);
    final cell = tester.getSize(
      find
          .ancestor(
            of: find.text('value 0 with words', findRichText: true),
            matching: find.byType(Padding),
          )
          .first,
    );
    expect(cell.width, greaterThanOrEqualTo(MarkdownTableView.minColumn));
    await tester.drag(
      find.byKey(const ValueKey('markdown-table-scroll')),
      const Offset(-400, 0),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.text('Column number 0', findRichText: true)).dx,
      lessThan(0),
    );
  });

  testWidgets('tapping opens the table full screen', (tester) async {
    await pump(tester, '| a | b |\n|---|---|\n| 1 | 2 |', 600);
    await tester.tap(find.byKey(const ValueKey('markdown-table-expand')));
    await tester.pumpAndSettle();
    expect(find.text('Table · 1 row'), findsOneWidget);
    expect(find.byKey(const ValueKey('markdown-table-full')), findsOneWidget);
  });

  testWidgets('the expand control sits below the table, over no cell', (
    tester,
  ) async {
    await pump(
      tester,
      '| Name | Kind | Size |\n|---|---|---|\n| a.txt | file | 12 KB |',
      600,
    );
    final table = tester.getRect(find.byKey(const ValueKey('markdown-table')));
    final expand = tester.getRect(
      find.byKey(const ValueKey('markdown-table-expand')),
    );
    final lastHeader = tester.getRect(find.text('Size', findRichText: true));
    expect(expand.top, greaterThanOrEqualTo(table.bottom));
    expect(expand.overlaps(lastHeader), isFalse);
    expect(expand.right, lessThanOrEqualTo(table.right + 0.5));
  });

  group('desktop', () {
    const desktops = TargetPlatformVariant({
      TargetPlatform.linux,
      TargetPlatform.windows,
      TargetPlatform.macOS,
    });

    testWidgets(
      'a click on the table does not open it; the button opens a dialog',
      (tester) async {
        await pump(tester, '| a | b |\n|---|---|\n| 1 | 2 |', 900);
        await tester.tap(find.text('1', findRichText: true));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('markdown-table-full')), findsNothing);
        await tester.tap(find.byKey(const ValueKey('markdown-table-expand')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('desktop-page-frame')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('markdown-table-full')),
          findsOneWidget,
        );
      },
      variant: desktops,
    );

    testWidgets('a wide table shows its scrollbar', (tester) async {
      final header = List.generate(8, (i) => 'Column number $i').join(' | ');
      final delimiter = List.filled(8, '---').join(' | ');
      final row = List.generate(8, (i) => 'value $i with words').join(' | ');
      await pump(tester, '| $header |\n| $delimiter |\n| $row |', 360);
      final bar = tester.widget<Scrollbar>(
        find.byKey(const ValueKey('markdown-table-scrollbar')),
      );
      expect(bar.thumbVisibility, isTrue);
    }, variant: desktops);
  });

  testWidgets('phone: a tap on the table opens it full screen, no scrollbar', (
    tester,
  ) async {
    final header = List.generate(8, (i) => 'Column number $i').join(' | ');
    final delimiter = List.filled(8, '---').join(' | ');
    final row = List.generate(8, (i) => 'value $i with words').join(' | ');
    await pump(tester, '| $header |\n| $delimiter |\n| $row |', 360);
    expect(
      find.byKey(const ValueKey('markdown-table-scrollbar')),
      findsNothing,
    );
    await pump(tester, '| a | b |\n|---|---|\n| 1 | 2 |', 360);
    await tester.tap(find.text('1', findRichText: true));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('markdown-table-full')), findsOneWidget);
    expect(find.byKey(const ValueKey('desktop-page-frame')), findsNothing);
  });
}
