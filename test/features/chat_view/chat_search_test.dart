import 'package:conduit/core/theme/theme_controller.dart';
import 'package:conduit/core/theme/theme_preferences_repository.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_controller.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_page.dart';
import 'package:conduit/features/voice/domain/voice_preferences.dart';
import 'package:conduit/features/voice/presentation/voice_settings_scope.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';
import 'chat_fixtures.dart';

AgentCommandResult ok(String stdout) =>
    AgentCommandResult(stdout: stdout, stderr: '', exitCode: 0);

const _current = Color(0xFFFF9800);
const _match = Color(0x80FFC107);

/// The texts marked in the thread with [color], in tree order.
List<String> marks(WidgetTester tester, Color color) {
  final found = <String>[];
  void visit(InlineSpan span) {
    if (span is TextSpan) {
      if (span.style?.backgroundColor == color && span.text != null) {
        found.add(span.text!);
      }
      span.children?.forEach(visit);
    }
  }

  for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
    visit(rich.text);
  }
  return found;
}

/// The row [text] is in, for telling which match is the current one.
Future<void> expectCurrentIn(WidgetTester tester, String text) async {
  final rich = tester
      .widgetList<RichText>(find.byType(RichText))
      .where((r) => r.text.toPlainText().contains(text));
  expect(rich, isNotEmpty, reason: '$text is on screen');
  var current = false;
  void visit(InlineSpan span) {
    if (span is TextSpan) {
      if (span.style?.backgroundColor == _current) current = true;
      span.children?.forEach(visit);
    }
  }

  for (final r in rich) {
    visit(r.text);
  }
  expect(current, isTrue, reason: 'the current match is in "$text"');
}

void main() {
  final count = find.byKey(const ValueKey('chat-find-count'));
  final field = find.byKey(const ValueKey('chat-find-field'));

  Future<ScriptedAgentCommandRunner> pumpPage(
    WidgetTester tester,
    List<Object> script, {
    Size size = const Size(800, 2400),
    ThemeController? settings,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final runner = ScriptedAgentCommandRunner(script);
    final controller = ChatViewController(
      runner: runner,
      sessionId: 's-1',
      pollInterval: const Duration(days: 1),
    );
    final app = MaterialApp(
      home: ChatViewPage(
        controller: controller,
        hostName: 'dev',
        onOpenTerminal: () {},
      ),
    );
    await tester.pumpWidget(
      settings == null
          ? app
          : VoiceSettingsScope(settings: settings, child: app),
    );
    await tester.pump();
    await tester.pump();
    addTearDown(() => tester.pumpWidget(const SizedBox()));
    return runner;
  }

  Future<void> search(WidgetTester tester, String query) async {
    // Find in conversation is in the ⋮ menu (CON-107).
    await tester.tap(find.byKey(const ValueKey('chat-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chat-search')));
    await tester.pumpAndSettle();
    await tester.enterText(field, query);
    await tester.pumpAndSettle();
  }

  final thread = [
    userLine('u1', 'Where is the needle?'),
    assistantLine('a1', [text('The **needle** is in `hay`.')]),
    userLine('u2', 'Thanks'),
    assistantLine('a2', [text('Another NEEDLE here, and a needle.')]),
  ];

  testWidgets('counts matches, marks them and starts at the newest', (
    tester,
  ) async {
    await pumpPage(tester, [ok(page(thread))]);
    await search(tester, 'needle');
    expect(tester.widget<Text>(count).data, '4 of 4');
    // Case-insensitive, inside Markdown too.
    expect(marks(tester, _current), ['needle']);
    expect(
      marks(tester, _match),
      unorderedEquals(['needle', 'needle', 'NEEDLE']),
    );
    await expectCurrentIn(tester, 'and a needle.');
  });

  testWidgets('older / newer walk the matches and wrap', (tester) async {
    await pumpPage(tester, [ok(page(thread))]);
    await search(tester, 'needle');
    final older = find.byKey(const ValueKey('chat-find-older'));
    final newer = find.byKey(const ValueKey('chat-find-newer'));
    await tester.tap(older);
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(count).data, '3 of 4');
    expect(marks(tester, _current), ['NEEDLE']);
    await tester.tap(older);
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(count).data, '2 of 4');
    await expectCurrentIn(tester, 'is in hay');
    await tester.tap(older);
    await tester.pumpAndSettle();
    await expectCurrentIn(tester, 'Where is the needle?');
    // Past the oldest (nothing older to load): back to the newest.
    await tester.tap(older);
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(count).data, '4 of 4');
    await tester.tap(newer);
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(count).data, '1 of 4');
  });

  testWidgets('Ctrl+F and Cmd+F open it; Enter, Shift+Enter, Esc', (
    tester,
  ) async {
    await pumpPage(tester, [ok(page(thread))]);
    final bar = find.byKey(const ValueKey('chat-find-bar'));
    expect(bar, findsNothing);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(bar, findsOneWidget);
    await tester.enterText(field, 'needle');
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(count).data, '3 of 4');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(count).data, '4 of 4');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(bar, findsNothing);
    expect(marks(tester, _current), isEmpty);
    expect(marks(tester, _match), isEmpty);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(bar, findsOneWidget);
  });

  testWidgets('matches inside collapsed tool groups open the group', (
    tester,
  ) async {
    await pumpPage(tester, [
      ok(
        page([
          userLine('u1', 'run the checks'),
          assistantLine('a1', [
            toolUse('t1', 'Bash', {'command': 'flutter analyze'}),
            toolUse('t2', 'Bash', {'command': 'flutter test'}),
          ]),
          userLine('r1', [
            toolResult('t1', 'No issues found'),
            toolResult('t2', 'line 1\nline 2\nsecret haystack line\nline 4'),
          ]),
          assistantLine('a2', [text('Done.')]),
        ]),
      ),
    ]);
    // Tool activity is Collapsed by default.
    expect(find.text('Ran 2 commands'), findsOneWidget);
    expect(find.text('flutter test'), findsNothing);
    await search(tester, 'haystack');
    expect(tester.widget<Text>(count).data, '1 of 1');
    expect(find.text('flutter test'), findsOneWidget);
    expect(marks(tester, _current), ['haystack']);
    await tester.tap(find.byKey(const ValueKey('chat-find-close')));
    await tester.pumpAndSettle();
    expect(find.text('flutter test'), findsNothing);
  });

  testWidgets('peer messages and user prompts are searched and marked', (
    tester,
  ) async {
    await pumpPage(tester, [
      ok(
        page([
          userLine(
            'm1',
            '<teammate-message teammate_id="lead" summary="Heads up">'
                'The deploy window is frozen</teammate-message>',
          ),
          userLine('u1', 'is the window open?'),
        ]),
      ),
    ]);
    await search(tester, 'window');
    expect(tester.widget<Text>(count).data, '2 of 2');
    expect(marks(tester, _current), ['window']);
    expect(marks(tester, _match), ['window']);
  });

  testWidgets('scrolls to a match that is off screen', (tester) async {
    await pumpPage(tester, [
      ok(
        page([
          userLine('u0', 'the needle is here'),
          for (var i = 1; i <= 40; i++)
            assistantLine('a$i', [text('Filler paragraph number $i.')]),
        ]),
      ),
    ], size: const Size(800, 600));
    final old = find.textContaining('needle is here', findRichText: true);
    expect(old, findsNothing);
    await search(tester, 'needle');
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(old, findsOneWidget);
    final rect = tester.getRect(old);
    expect(rect.top, greaterThanOrEqualTo(0));
    expect(rect.bottom, lessThanOrEqualTo(600));
  });

  testWidgets('past the oldest loaded match it loads earlier messages', (
    tester,
  ) async {
    final runner = await pumpPage(tester, [
      ok(page([userLine('u2', 'nothing here')], start: 500)),
      ok(
        page([
          userLine('u1', 'the old needle'),
          assistantLine('a1', [text('ok')]),
        ], offset: 500),
      ),
    ]);
    await search(tester, 'needle');
    expect(tester.widget<Text>(count).data, 'None loaded');
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('chat-find-older')))
          .tooltip,
      'Search earlier messages',
    );
    await tester.tap(find.byKey(const ValueKey('chat-find-older')));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(runner.commands.last, contains('--before 500'));
    expect(tester.widget<Text>(count).data, '1 of 1');
    expect(marks(tester, _current), ['needle']);
  });

  testWidgets('says so when nothing earlier matches', (tester) async {
    await pumpPage(tester, [
      ok(page([userLine('u2', 'nothing here')], start: 500)),
      ok(page([userLine('u1', 'nor here')], offset: 500)),
    ]);
    await search(tester, 'needle');
    await tester.tap(find.byKey(const ValueKey('chat-find-older')));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(tester.widget<Text>(count).data, 'No matches');
    expect(find.byKey(const ValueKey('chat-find-note')), findsOneWidget);
  });

  for (final mode in [ToolActivity.all, ToolActivity.hidden]) {
    testWidgets('Tool activity ${mode.label}: searches what is shown', (
      tester,
    ) async {
      final settings = ThemeController(
        ThemePreferencesRepository(InMemorySecureStorage()),
      );
      await tester.runAsync(settings.load);
      await tester.runAsync(
        () => settings.setVoice(settings.voice.copyWith(toolActivity: mode)),
      );
      await pumpPage(tester, [
        ok(
          page([
            userLine('u1', 'check the haystack'),
            assistantLine('a1', [
              toolUse('t1', 'Bash', {'command': 'grep haystack'}),
              toolUse('t2', 'Bash', {'command': 'ls'}),
            ]),
            userLine('r1', [
              toolResult('t1', 'no haystack'),
              toolResult('t2', 'haystack.txt', error: true),
            ]),
          ]),
        ),
      ], settings: settings);
      await search(tester, 'haystack');
      // Hidden keeps only the failed call; All shows both.
      expect(
        tester.widget<Text>(count).data,
        mode == ToolActivity.all ? '4 of 4' : '2 of 2',
      );
      expect(marks(tester, _current), ['haystack']);
    });
  }
}
