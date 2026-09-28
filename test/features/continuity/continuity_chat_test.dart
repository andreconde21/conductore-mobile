import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_controller.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_page.dart';
import 'package:conduit/features/continuity/domain/continuity_record.dart';
import 'package:conduit/features/continuity/domain/continuity_state.dart';
import 'package:conduit/features/continuity/presentation/continuity_controller.dart';
import 'package:conduit/features/continuity/presentation/continuity_scope.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';
import '../chat_view/chat_fixtures.dart';
import 'continuity_test_support.dart';

AgentCommandResult _ok(String stdout) =>
    AgentCommandResult(stdout: stdout, stderr: '', exitCode: 0);

Map<String, Object?> _message(int i) =>
    assistantLine('a$i', [text('Message number $i\nline two\nline three')]);

void main() {
  final now = DateTime(2026, 9, 28, 12);
  final history = [for (var i = 0; i < 40; i++) _message(i)];

  /// A draft of the chat's session ('s-1') on the desktop.
  Map<String, Object?> deskDraft(String text) => deviceRecord(
    id: 'desk',
    activeAt: now,
    drafts: {
      's-1': ContinuityDraft(
        text: text,
        at: now.subtract(const Duration(minutes: 1)),
      ),
    },
  );

  Future<ContinuityController> pumpChat(
    WidgetTester tester, {
    ContinuityState state = const ContinuityState(),
    void Function(ContinuityController controller)? before,
  }) async {
    final continuity = continuityController(
      link: FakeContinuityLink(),
      clock: () => now,
      store: InMemoryContinuityStore(state),
    );
    await continuity.start();
    before?.call(continuity);
    final chat = ChatViewController(
      runner: ScriptedAgentCommandRunner([_ok(page(history))]),
      sessionId: 's-1',
      pollInterval: const Duration(days: 1),
    );
    await tester.pumpWidget(
      ContinuityScope(
        controller: continuity,
        child: MaterialApp(
          home: ChatViewPage(controller: chat, onOpenTerminal: () {}),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    return continuity;
  }

  /// Takes the page down and stops continuity's timers.
  Future<void> finish(WidgetTester tester) async {
    final continuity = ContinuityScope.maybeOf(
      tester.element(find.byType(ChatViewPage)),
    )!;
    await tester.pumpWidget(const SizedBox());
    continuity.dispose();
  }

  String composerText(WidgetTester tester) => tester
      .widget<TextField>(find.byKey(const ValueKey('chat-composer-field')))
      .controller!
      .text;

  testWidgets('a draft typed on the desktop fills the empty composer, with '
      'where it comes from', (tester) async {
    await pumpChat(
      tester,
      state: ContinuityState(remote: deskDraft('continue the refactor')),
    );
    await tester.pump();

    expect(composerText(tester), 'continue the refactor');
    expect(find.text('Draft from Omarchy'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('a different local draft is kept and both are offered', (
    tester,
  ) async {
    await pumpChat(
      tester,
      state: ContinuityState(
        drafts: {
          's-1': ContinuityDraft(
            text: 'my own words',
            at: now.subtract(const Duration(minutes: 10)),
          ),
        },
        remote: deskDraft('their words'),
      ),
    );
    await tester.pump();

    // Never replaced silently.
    expect(composerText(tester), 'my own words');
    expect(find.text('Omarchy has a different draft'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('continuity-draft-append')));
    await tester.pump();
    expect(composerText(tester), 'my own words\n\ntheir words');
    expect(find.text('Omarchy has a different draft'), findsNothing);
    await finish(tester);
  });

  testWidgets('"Keep mine" keeps the local draft and stops offering', (
    tester,
  ) async {
    final continuity = await pumpChat(
      tester,
      state: ContinuityState(
        drafts: {
          's-1': ContinuityDraft(
            text: 'mine',
            at: now.subtract(const Duration(minutes: 10)),
          ),
        },
        remote: deskDraft('theirs'),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('continuity-draft-mine')));
    await tester.pump();

    expect(composerText(tester), 'mine');
    expect(find.text('Omarchy has a different draft'), findsNothing);
    expect(
      continuity.resolveDraftFor('s-1', 'mine').runtimeType.toString(),
      'DraftKeep',
    );
    await finish(tester);
  });

  testWidgets('what is typed becomes this device\'s draft', (tester) async {
    final continuity = await pumpChat(tester);
    await tester.enterText(
      find.byKey(const ValueKey('chat-composer-field')),
      'typed on the phone',
    );
    await tester.pump();
    expect(continuity.draftFor('s-1'), 'typed on the phone');
    await finish(tester);
  });

  testWidgets('opened from another device, the thread scrolls to where it '
      'was reading', (tester) async {
    await pumpChat(
      tester,
      before: (continuity) => continuity.expectArrival(
        ContinuityContext(
          place: chatPlace(agent: 's-1'),
          at: now,
          anchor: 'a5#0',
        ),
      ),
    );
    await tester.pumpAndSettle();

    final row = find.byKey(const ValueKey('a5#0'));
    expect(row, findsOneWidget);
    final thread = tester.getRect(find.byKey(const ValueKey('chat-thread')));
    final rect = tester.getRect(row);
    expect(rect.overlaps(thread), isTrue);
    // It was the newest message on the other screen: it sits low here too.
    expect(rect.center.dy, greaterThan(thread.center.dy));
    // The newest message is off screen.
    expect(find.byKey(const ValueKey('a39#0')), findsNothing);
    await finish(tester);
  });

  testWidgets('reading further up tells continuity which message', (
    tester,
  ) async {
    final continuity = await pumpChat(
      tester,
      before: (continuity) => continuity.reportPlace(chatPlace(agent: 's-1')),
    );
    await tester.drag(
      find.byKey(const ValueKey('chat-thread')),
      const Offset(0, 600),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
    final anchor = continuity.context!.anchor;
    expect(anchor, isNotNull);
    expect(find.byKey(ValueKey<String>(anchor!)), findsOneWidget);

    await tester.drag(
      find.byKey(const ValueKey('chat-thread')),
      const Offset(0, -2000),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
    expect(continuity.context!.anchor, isNull);
    await finish(tester);
  });
}
