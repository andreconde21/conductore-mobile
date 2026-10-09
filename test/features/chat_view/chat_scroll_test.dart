import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_controller.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';
import 'chat_fixtures.dart';

AgentCommandResult ok(String stdout) =>
    AgentCommandResult(stdout: stdout, stderr: '', exitCode: 0);

Map<String, Object?> message(int i) =>
    assistantLine('a$i', [text('Message number $i\nline two\nline three')]);

void main() {
  final history = [for (var i = 0; i < 30; i++) message(i)];

  Future<ChatViewController> pumpPage(
    WidgetTester tester,
    List<Object> script,
  ) async {
    final controller = ChatViewController(
      runner: ScriptedAgentCommandRunner(script),
      sessionId: 's-1',
      pollInterval: const Duration(days: 1),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ChatViewPage(controller: controller, onOpenTerminal: () {}),
      ),
    );
    await tester.pump();
    await tester.pump();
    addTearDown(() => tester.pumpWidget(const SizedBox()));
    return controller;
  }

  /// The id of the first message row fully on screen.
  String visibleRow(WidgetTester tester) {
    for (var i = 0; i < 40; i++) {
      final row = find.byKey(ValueKey('a$i#0'));
      if (row.evaluate().isNotEmpty && tester.getTopLeft(row).dy > 100) {
        return 'a$i#0';
      }
    }
    throw StateError('no message row on screen');
  }

  ScrollPosition position(WidgetTester tester) => tester
      .state<ScrollableState>(
        find.descendant(
          of: find.byKey(const ValueKey('chat-thread')),
          matching: find.byType(Scrollable),
        ),
      )
      .position;

  testWidgets('scrolled up, new messages never move the view; the pill '
      'counts them and jumps to the bottom', (tester) async {
    final chat = await pumpPage(tester, [
      ok(page(history)),
      ok(page([for (var i = 30; i < 34; i++) message(i)], offset: 200)),
      ok(
        page(
          [userLine('u9', 'next')],
          offset: 300,
          state: 'needs_permission',
          pending: [
            {'id': 'req-1', 'toolName': 'Bash', 'summary': 'rm -rf build'},
          ],
        ),
      ),
    ]);
    await tester.drag(
      find.byKey(const ValueKey('chat-thread')),
      const Offset(0, 500),
    );
    await tester.pumpAndSettle();
    final row = visibleRow(tester);
    final before = tester.getTopLeft(find.byKey(ValueKey(row)));

    await chat.refresh();
    await tester.pump();
    expect(tester.getTopLeft(find.byKey(ValueKey(row))), before);
    expect(find.text('New messages (4)'), findsOneWidget);

    await chat.refresh();
    await tester.pump();
    expect(tester.getTopLeft(find.byKey(ValueKey(row))), before);
    // One more message and one approval: the pill names the approval.
    expect(find.text('Approval waiting'), findsOneWidget);
    expect(find.text('Allow Bash?'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('chat-new-messages')));
    await tester.pumpAndSettle();
    expect(position(tester).pixels, 0);
    expect(find.byKey(const ValueKey('chat-new-messages')), findsNothing);
    expect(find.text('Allow Bash?'), findsOneWidget);
  });

  testWidgets('at the bottom, new messages show at once', (tester) async {
    final chat = await pumpPage(tester, [
      ok(page(history)),
      ok(page([message(30)], offset: 200)),
    ]);
    await chat.refresh();
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('a30#0')), findsOneWidget);
    expect(position(tester).pixels, 0);
    expect(find.byKey(const ValueKey('chat-new-messages')), findsNothing);
  });

  testWidgets('the working row appearing or ending does not move a '
      'scrolled-up view', (tester) async {
    final chat = await pumpPage(tester, [
      ok(page([...history, userLine('u1', 'go')], state: 'working')),
      ok(page([], offset: 200)),
      ok(page([message(40)], offset: 300, state: 'working')),
    ]);
    expect(find.byKey(const ValueKey('chat-working-indicator')), findsOne);
    await tester.drag(
      find.byKey(const ValueKey('chat-thread')),
      const Offset(0, 500),
    );
    await tester.pump(const Duration(seconds: 1));
    final row = visibleRow(tester);
    final before = tester.getTopLeft(find.byKey(ValueKey(row)));

    await chat.refresh(); // Work finished.
    await tester.pump();
    expect(tester.getTopLeft(find.byKey(ValueKey(row))), before);
    await tester.pump(const Duration(seconds: 1)); // Timer ticks.
    expect(tester.getTopLeft(find.byKey(ValueKey(row))), before);
  });
}
