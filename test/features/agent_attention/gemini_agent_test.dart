import 'dart:convert';
import 'dart:io';

import 'package:conduit/features/agent_attention/data/conductore_host_attention_provider.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention_notifier.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/agent_attention/domain/agent_kinds.dart';
import 'package:conduit/features/agent_attention/domain/agent_notifications.dart';
import 'package:conduit/features/agent_attention/presentation/agent_notification_settings.dart';
import 'package:conduit/features/agent_attention/presentation/widgets/agent_inbox_widgets.dart';
import 'package:conduit/features/agent_attention/presentation/widgets/approval_widgets.dart';
import 'package:conduit/features/chat_view/domain/chat_items.dart';
import 'package:conduit/features/chat_view/domain/chat_transcript.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_controller.dart';
import 'package:conduit/features/chat_view/presentation/widgets/chat_thread_items.dart';
import 'package:conduit/features/session_navigation/domain/session_view_preferences.dart';
import 'package:conduit/features/usage/domain/usage_report.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

/// Gemini CLI (CON-072): its sessions show on the dashboard, in
/// notifications and in Chat View; its permission prompts are only shown
/// ("Answer in the terminal"), never answered from the phone. The status
/// line and the chat page are what the companion's Gemini adapter makes of
/// a real Gemini CLI 0.62.0 session (host/test/gemini-adapter.test.js keeps
/// the chat page so).
void main() {
  const geminiCaps =
      '{"label":"Gemini CLI","events":"hooks","approvals":"observe",'
      '"always":false,"questions":false,"plans":false,"chat":"items",'
      '"send":"pane","interrupt":"pane","liveUsage":false,"limits":false,'
      '"history":true,"brain":false,"brainSchema":false,"accounts":"show",'
      '"facts":"partial","undo":true}';
  // A prompt as the daemon reports it while Gemini waits in the terminal.
  const status =
      '{"version":1,"seq":4,"adapters":{"gemini":$geminiCaps},'
      '"agents":[{"sessionId":"6cc5de7a","kind":"gemini","name":"proj",'
      '"state":"needs_permission","cwd":"/work/proj","pending":[{'
      '"id":"0ad306a77193","toolName":"Write","summary":"/work/proj/hello.txt",'
      '"toolInput":{"file_path":"/work/proj/hello.txt","content":"hello"},'
      '"createdAt":1791137880500,"toolKind":"write","answerable":false,'
      '"risk":{"level":"low","reason":"Write inside the repo"},'
      '"batchable":true,"suggestedRules":["Write(/work/proj/**)"],'
      '"repo":"/work/proj"}]}]}';

  group('status', () {
    test('a Gemini prompt is terminal-only: never batched or trusted', () {
      final snapshot = ConductoreHostAttentionProvider.parseSnapshot(status);
      final agent = snapshot.agents.single;
      expect(agent.kind, 'gemini');
      final request = agent.pendingRequests.single;
      expect(request.terminalOnly, isTrue);
      expect(request.batchable, isFalse);
      expect(request.trustable, isFalse);
      expect(request.toolName, 'Write');
      final caps = snapshot.kinds!.of('gemini');
      expect(caps.label, 'Gemini CLI');
      expect(caps.answersApprovals, isFalse);
      expect(supportsChatView(agent, snapshot.kinds!), isTrue);
      // Every other companion request stays answerable.
      final claude = ConductoreHostAttentionProvider.parseSnapshot(
        status.replaceAll('"answerable":false,', ''),
      ).agents.single.pendingRequests.single;
      expect(claude.terminalOnly, isFalse);
      expect(claude.batchable, isTrue);
    });

    test('Gemini CLI is named where the agent must be', () {
      expect(otherAgentKindName('gemini'), 'Gemini CLI');
      expect(AgentKindStyle.of('gemini').label, 'Gemini CLI');
    });
  });

  group('notifications', () {
    final agent = ConductoreHostAttentionProvider.parseSnapshot(
      status,
    ).agents.single;

    test('say Gemini CLI and "in the terminal", without buttons', () {
      final n = AgentNotificationPolicy.build(
        hostId: 'h',
        hostName: 'VTM',
        agent: agent,
        need: AgentNeed.approval,
        alert: true,
        preferences: const AgentNotificationPreferences(),
        open: const AgentOpenTarget(hostId: 'h', agentId: '6cc5de7a'),
      );
      expect(n.title, 'proj (Gemini CLI) · VTM needs you');
      expect(
        n.text,
        'Approve Write in the terminal: /work/proj/hello.txt · Low risk',
      );
      expect(n.action, isNull);
      expect(n.reviewAll, isFalse);
    });
  });

  group('approval cards', () {
    Future<void> pump(WidgetTester tester, Widget child) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    );

    testWidgets('the dashboard card reads "Answer in the terminal"', (
      tester,
    ) async {
      final request = ConductoreHostAttentionProvider.parseSnapshot(
        status,
      ).agents.single.pendingRequests.single;
      final decided = <PermissionVerdict>[];
      await pump(
        tester,
        PendingRequestCard(
          request: request,
          busy: false,
          onDecide: decided.add,
          onAnswer: (_) {},
          onTrust: () {},
        ),
      );
      expect(
        find.byKey(const ValueKey('answer-in-terminal-0ad306a77193')),
        findsOneWidget,
      );
      expect(find.textContaining(TerminalOnlyNote.text), findsOneWidget);
      for (final label in ['Allow', 'Deny', 'Always', 'Trust…']) {
        expect(find.text(label), findsNothing, reason: label);
      }
      expect(find.byType(ApprovalButtons), findsNothing);
      // What it wants to do is still shown.
      expect(find.text('/work/proj/hello.txt'), findsOneWidget);
      expect(decided, isEmpty);
    });

    testWidgets('so does the Chat View card', (tester) async {
      final request = ConductoreHostAttentionProvider.parseSnapshot(
        status,
      ).agents.single.pendingRequests.single;
      await pump(
        tester,
        ChatApprovalCard(
          request: request,
          busy: false,
          onDecide: (_) {},
          onTrust: () {},
        ),
      );
      expect(
        find.byKey(const ValueKey('chat-answer-in-terminal-0ad306a77193')),
        findsOneWidget,
      );
      expect(find.text('Write is waiting for approval'), findsOneWidget);
      expect(find.text('Allow'), findsNothing);
      expect(find.text('Deny'), findsNothing);
    });

    testWidgets('an answerable request keeps its buttons', (tester) async {
      await pump(
        tester,
        PendingRequestCard(
          request: const PendingPermissionRequest(
            id: 'r',
            toolName: 'Bash',
            summary: 'ls',
          ),
          busy: false,
          onDecide: (_) {},
          onAnswer: (_) {},
        ),
      );
      expect(find.text('Allow'), findsOneWidget);
      expect(find.byType(TerminalOnlyNote), findsNothing);
    });
  });

  group('Chat View', () {
    final real =
        jsonDecode(
              File(
                'test/fixtures/agent_adapters/gemini_chat_page.json',
              ).readAsStringSync(),
            )
            as Map<String, Object?>;

    test('the real Gemini page parses as a neutral transcript page', () {
      final page = TranscriptParser.parsePage(jsonEncode(real));
      expect(page.isNeutral, isTrue);
      expect(page.neutralItems, hasLength(16));
      expect(page.cursor, real['cursor']);
    });

    test('shows the session as the terminal did: the refused write, the '
        'cancel, the todos, the thought', () async {
      final runner = ScriptedAgentCommandRunner([
        AgentCommandResult(stdout: jsonEncode(real), stderr: '', exitCode: 0),
      ]);
      final controller = ChatViewController(
        runner: runner,
        sessionId: real['sessionId']! as String,
        pollInterval: const Duration(days: 1),
        tailBytes: 1000,
      );
      addTearDown(controller.dispose);
      await controller.refresh();
      final items = controller.items;
      expect(items.whereType<ChatUserMessage>().map((m) => m.text), [
        'SHELLME',
        'WRITEME',
        'README',
        'TODOME',
        'THINKME',
      ]);
      final calls = items.whereType<ChatToolCall>().toList();
      expect(calls, hasLength(3));
      final refused = calls.where((c) => c.result?.isError ?? false).single;
      expect(refused.result!.content, contains('User denied'));
      expect(items.whereType<ChatThinking>(), hasLength(1));
      expect(
        items.whereType<ChatAssistantText>().last.text,
        'The answer is **42**.',
      );
      expect(controller.name, 'proj');
    });
  });

  test('usage: the Gemini section, tokens only', () {
    final report = parseUsageReport(
      jsonEncode({
        'schema': 3,
        'machine': 'm',
        'today': '2026-10-04',
        'from': '2026-10-01',
        'claude': {'present': false},
        'codex': {'present': false},
        'gemini': {
          'present': true,
          'limits': <Object?>[],
          'costSource': 'none',
          'active': {'model': 'gemini-2.5-flash', 'at': 1},
          'today': {
            'input': 6400,
            'output': 440,
            'cacheRead': 3200,
            'tokens': 10040,
            'messages': 8,
            'costUsd': 0,
          },
          'range': {
            'input': 6400,
            'output': 440,
            'cacheRead': 3200,
            'tokens': 10040,
            'messages': 8,
            'costUsd': 0,
          },
          'rows': [
            {
              'date': '2026-10-04',
              'project': 'proj',
              'model': 'gemini-2.5-flash',
              'input': 6400,
              'output': 440,
              'cacheWrite': 0,
              'cacheRead': 3200,
              'messages': 8,
              'costUsd': 0,
            },
          ],
        },
      }),
    )!;
    expect(report.gemini.present, isTrue);
    expect(report.gemini.agent, UsageAgent.gemini);
    expect(report.gemini.activeModel, 'gemini-2.5-flash');
    expect(report.gemini.limits, isEmpty);
    expect(report.gemini.costReported, isFalse);
    expect(report.gemini.rows.single.model, 'gemini-2.5-flash');
    expect(report.agents.map((s) => s.agent), contains(UsageAgent.gemini));
    // A companion without the adapter: absent.
    expect(
      parseUsageReport(
        jsonEncode({'schema': 3, 'machine': 'm', 'today': 't', 'from': 'f'}),
      )!.gemini.present,
      isFalse,
    );
  });
}
