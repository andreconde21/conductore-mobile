import 'package:conduit/features/chat_view/domain/chat_items.dart';
import 'package:conduit/features/chat_view/presentation/chat_search.dart';
import 'package:conduit/features/chat_view/presentation/widgets/chat_find_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../screenshots/screenshot_harness.dart';

const _field = ValueKey('chat-find-field');
const _count = ValueKey('chat-find-count');

Future<ChatSearch> _pump(
  WidgetTester tester, {
  required double width,
  required int matches,
  bool searchingEarlier = false,
}) async {
  tester.view.physicalSize = Size(width, 400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final search = ChatSearch()
    ..open()
    ..query = 'overdue'
    ..update(
      1,
      () => [
        for (var i = 0; i < matches; i++)
          ChatUserMessage('m$i', text: 'overdue todos'),
      ],
    )
    ..searchingEarlier = searchingEarlier;
  final controller = TextEditingController(text: 'overdue');
  addTearDown(controller.dispose);
  final focus = FocusNode();
  addTearDown(focus.dispose);
  await tester.pumpWidget(
    shotApp(
      systemBars: false,
      home: Scaffold(
        body: ChatFindBar(
          search: search,
          controller: controller,
          focusNode: focus,
          onOlder: () {},
          onNewer: () {},
          onClose: () {},
        ),
      ),
    ),
  );
  return search;
}

void main() {
  setUpAll(loadShotFonts);

  for (final width in [320.0, 411.0, 1280.0]) {
    testWidgets('the count keeps clear of the field at $width dp', (
      tester,
    ) async {
      await _pump(tester, width: width, matches: 7);
      expect(tester.takeException(), isNull);
      expect(find.text('7 of 7'), findsOneWidget);
      final field = tester.getRect(find.byKey(_field));
      final count = tester.getRect(find.byKey(_count));
      final older = tester.getRect(
        find.byKey(const ValueKey('chat-find-older')),
      );
      expect(count.left - field.right, greaterThanOrEqualTo(8));
      expect(count.right, lessThanOrEqualTo(older.left));
      expect(
        tester
            .renderObject<RenderParagraph>(find.byKey(_count))
            .didExceedMaxLines,
        isFalse,
      );
      // Centred on the field's line.
      expect(count.center.dy, moreOrLessEquals(field.center.dy, epsilon: 2));
      expect(field.width, greaterThan(width < 400 ? 90 : 200));
    });

    testWidgets('a long state never overlaps at $width dp', (tester) async {
      await _pump(tester, width: width, matches: 0, searchingEarlier: true);
      expect(tester.takeException(), isNull);
      final field = tester.getRect(find.byKey(_field));
      final count = tester.getRect(find.byKey(_count));
      final older = tester.getRect(
        find.byKey(const ValueKey('chat-find-older')),
      );
      expect(count.left, greaterThan(field.right));
      expect(count.right, lessThanOrEqualTo(older.left));
      // With the spinner too, at 320 dp the query keeps a few letters.
      expect(field.width, greaterThan(width < 400 ? 50 : 100));
    });
  }
}
