import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/chat_view/domain/chat_search_text.dart';
import 'package:conduit/features/chat_view/presentation/chat_forward.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_controller.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_page.dart';
import 'package:conduit/features/chat_view/presentation/widgets/chat_markdown.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';
import 'chat_fixtures.dart';

AgentCommandResult ok(String stdout) =>
    AgentCommandResult(stdout: stdout, stderr: '', exitCode: 0);

SavedHost host(String id, String name) => SavedHost(
  id: id,
  name: name,
  host: '$id.example',
  port: 22,
  username: 'u',
  authMethod: SshAuthMethod.password,
);

void main() {
  final thread = [
    userLine('u1', 'Please check'),
    assistantLine('a1', [
      text('Run **this** and `x`\n- one\n\n```dart\nprint(1);\n```'),
    ]),
    userLine(
      'm1',
      '<teammate-message teammate_id="lead" summary="Heads up">'
          'Deploy is frozen</teammate-message>',
    ),
    assistantLine('a2', [
      toolUse('t1', 'Bash', {'command': 'flutter test'}),
    ]),
    userLine('r1', [toolResult('t1', 'all green')]),
  ];

  late String? clipboard;
  setUp(() {
    clipboard = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard = (call.arguments as Map)['text'] as String?;
          }
          return null;
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null),
  );

  Future<void> pumpPage(
    WidgetTester tester, {
    List<ChatForwardTarget> Function()? forwardTargets,
    ChatForward? onForward,
    Future<bool> Function(String text)? share,
  }) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = ChatViewController(
      runner: ScriptedAgentCommandRunner([ok(page(thread))]),
      sessionId: 's-1',
      pollInterval: const Duration(days: 1),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ChatViewPage(
          controller: controller,
          hostName: 'dev',
          onOpenTerminal: () {},
          forwardTargets: forwardTargets,
          onForward: onForward,
          share: share ?? (_) async => true,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    addTearDown(() => tester.pumpWidget(const SizedBox()));
  }

  Future<void> openMenu(WidgetTester tester, Finder row) async {
    await tester.longPress(row);
    await tester.pumpAndSettle();
  }

  final reply = find.textContaining('Run this and', findRichText: true);

  group('phone', () {
    testWidgets('Copy strips Markdown; Copy as Markdown keeps it', (
      tester,
    ) async {
      await pumpPage(tester);
      await openMenu(tester, reply);
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.text('Select text'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('chat-action-copy')));
      await tester.pumpAndSettle();
      expect(clipboard, 'Run this and x\n\n• one\n\nprint(1);');

      await openMenu(tester, reply);
      await tester.tap(find.byKey(const ValueKey('chat-action-copyMarkdown')));
      await tester.pumpAndSettle();
      expect(clipboard, startsWith('Run **this** and `x`\n- one'));
    });

    testWidgets('a code block copies just its code', (tester) async {
      await pumpPage(tester);
      await tester.tap(find.byKey(const ValueKey('markdown-code-copy')));
      await tester.pump();
      expect(clipboard, 'print(1);');
      expect(find.text('Code copied'), findsOneWidget);
    });

    testWidgets('peer and tool rows have the menu too', (tester) async {
      await pumpPage(tester);
      await openMenu(tester, find.text('Deploy is frozen'));
      await tester.tap(find.byKey(const ValueKey('chat-action-copy')));
      await tester.pumpAndSettle();
      expect(clipboard, 'Heads up\n\nDeploy is frozen');
      // Plain rows have nothing to strip: no "Copy as Markdown".
      await openMenu(tester, find.text('flutter test'));
      expect(
        find.byKey(const ValueKey('chat-action-copyMarkdown')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('chat-action-copy')));
      await tester.pumpAndSettle();
      expect(clipboard, 'Bash: flutter test\n\nall green');
    });

    testWidgets('Quote in reply puts the text in the composer', (tester) async {
      await pumpPage(tester);
      await openMenu(tester, find.text('Please check'));
      await tester.tap(find.byKey(const ValueKey('chat-action-quote')));
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('chat-composer-field')),
      );
      expect(field.controller!.text, '> Please check\n\n');
      expect(field.focusNode!.hasFocus, isTrue);
    });

    testWidgets('Share uses the share sheet, else the clipboard', (
      tester,
    ) async {
      final shared = <String>[];
      var available = true;
      await pumpPage(
        tester,
        share: (text) async {
          shared.add(text);
          return available;
        },
      );
      await openMenu(tester, find.text('Please check'));
      await tester.tap(find.byKey(const ValueKey('chat-action-share')));
      await tester.pumpAndSettle();
      expect(shared, ['Please check']);
      expect(clipboard, isNull);

      available = false;
      await openMenu(tester, find.text('Please check'));
      await tester.tap(find.byKey(const ValueKey('chat-action-share')));
      await tester.pumpAndSettle();
      expect(clipboard, 'Please check');
      expect(find.text('Copied to the clipboard to share'), findsOneWidget);
    });

    testWidgets('Select text opens the message where it can be selected', (
      tester,
    ) async {
      await pumpPage(tester);
      await openMenu(tester, reply);
      await tester.tap(find.byKey(const ValueKey('chat-action-select')));
      await tester.pumpAndSettle();
      final page = find.byKey(const ValueKey('chat-select-text'));
      expect(page, findsOneWidget);
      expect(
        find.descendant(of: page, matching: find.byType(SelectionArea)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: page, matching: find.byType(ChatMarkdown)),
        findsOneWidget,
      );
    });

    testWidgets('Send to another agent picks a session and sends it quoted '
        'with its source', (tester) async {
      final sent = <(String, String, String)>[];
      final vtm = host('vtm', 'VTM');
      await pumpPage(
        tester,
        forwardTargets: () => [
          ChatForwardTarget(
            host: host('dev', 'dev'),
            agent: const AgentInfo(
              id: 's-2',
              name: 'web',
              state: AgentAttentionState.idle,
            ),
          ),
          ChatForwardTarget(
            host: vtm,
            agent: const AgentInfo(
              id: 's-9',
              name: 'infra',
              state: AgentAttentionState.working,
            ),
          ),
        ],
        onForward: (target, prompt) async =>
            sent.add((target.host.id, target.agent.id, prompt)),
      );
      await openMenu(tester, find.text('Please check'));
      await tester.tap(find.byKey(const ValueKey('chat-action-forward')));
      await tester.pumpAndSettle();
      expect(find.text('web'), findsOneWidget);
      expect(find.textContaining('VTM'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('chat-forward-vtm-s-9')));
      await tester.pumpAndSettle();
      expect(sent, [('vtm', 's-9', 'From api on dev:\n> Please check')]);
    });

    testWidgets('with no other agent it says so', (tester) async {
      var forwarded = false;
      await pumpPage(
        tester,
        forwardTargets: () => const [],
        onForward: (_, _) async => forwarded = true,
      );
      await openMenu(tester, find.text('Please check'));
      await tester.tap(find.byKey(const ValueKey('chat-action-forward')));
      await tester.pumpAndSettle();
      expect(find.textContaining('No other agent'), findsOneWidget);
      expect(forwarded, isFalse);
    });

    testWidgets('without the agent monitor there is no Send to agent', (
      tester,
    ) async {
      await pumpPage(tester);
      await openMenu(tester, find.text('Please check'));
      expect(find.byKey(const ValueKey('chat-action-forward')), findsNothing);
    });
  });

  group('desktop', () {
    final linux = TargetPlatformVariant.only(TargetPlatform.linux);

    testWidgets('right-click opens a context menu, not a bottom sheet', (
      tester,
    ) async {
      await pumpPage(tester);
      await tester.tap(
        find.text('Please check'),
        buttons: kSecondaryMouseButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('adaptive-modal-popover')),
        findsOneWidget,
      );
      expect(find.byType(BottomSheet), findsNothing);
      // Selecting is done with the mouse in the thread itself.
      expect(find.byKey(const ValueKey('chat-action-select')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('chat-action-copy')));
      await tester.pumpAndSettle();
      expect(clipboard, 'Please check');
    }, variant: linux);

    testWidgets('hovering shows Copy and the menu button', (tester) async {
      await pumpPage(tester);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(reply));
      await tester.pump();
      expect(find.byKey(const ValueKey('chat-message-hover')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('chat-message-copy')));
      await tester.pump();
      expect(clipboard, startsWith('Run this and x'));
      await tester.tap(find.byKey(const ValueKey('chat-message-more')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('adaptive-modal-popover')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('chat-action-quote')), findsOneWidget);
    }, variant: linux);

    testWidgets('assistant replies are selectable with the mouse', (
      tester,
    ) async {
      await pumpPage(tester);
      expect(
        find.ancestor(of: reply, matching: find.byType(SelectionArea)),
        findsOneWidget,
      );
      expect(
        find.ancestor(
          of: find.text('Please check'),
          matching: find.byType(SelectionArea),
        ),
        findsNothing,
      );
    }, variant: linux);
  });

  group('text helpers', () {
    test('quote and forward prompt', () {
      expect(chatQuote('a\n\nb '), '> a\n>\n> b');
      expect(
        chatForwardPrompt('hi', from: 'api', host: 'VTM'),
        'From api on VTM:\n> hi',
      );
      expect(chatForwardPrompt('hi', from: 'api'), 'From api:\n> hi');
    });

    test('plain inline text matches what the spans show', () {
      const sample =
          'A **bold `code`** _it_ [site](https://x.dev) [bad](ftp://y) '
          'https://z.dev/p.';
      final spans = markdownSpans(sample, const TextStyle(), ThemeData(), []);
      expect(
        markdownPlainInline(sample),
        TextSpan(children: spans).toPlainText(),
      );
    });

    test('Markdown to plain text', () {
      expect(
        markdownToPlainText(
          '# Title\n\nSome *text*\n- a\n- b\n\n| x | y |\n'
          '|---|---|\n| 1 | 2 |',
        ),
        'Title\n\nSome text\n\n• a\n• b\n\nx\ty\n1\t2',
      );
    });
  });
}
