import 'dart:convert';

import 'package:conduit/core/theme/theme_controller.dart';
import 'package:conduit/features/agent_attention/data/conductore_host_attention_provider.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_sheet.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_controller.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_page.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:conduit/features/voice/domain/voice_preferences.dart';
import 'package:conduit/features/voice/presentation/voice_settings_scope.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';
import 'review_fakes.dart';

/// The monitor's companion: `status` with (or without) the snapshots
/// capability, and Review's commands through [FakeReviewRunner].
class _Companion implements AgentCommandRunner {
  _Companion({this.snapshots = true});

  final bool snapshots;
  final review = FakeReviewRunner();
  String state = 'waiting_input';
  String lastEvent = 'Stop';

  @override
  Future<AgentCommandResult> run(
    String command, {
    required Duration timeout,
  }) async {
    if (command.contains('hostd status')) {
      return FakeReviewRunner.ok({
        'version': 1,
        'seq': 3,
        'capabilities': ['smart-approvals', if (snapshots) 'snapshots'],
        'agents': [
          {
            'sessionId': FakeReviewRunner.sessionId,
            'name': 'api',
            'cwd': '/home/a/api',
            'state': state,
            'updatedAt': 1790000003000,
            'pending': <Object>[],
          },
        ],
      });
    }
    if (command.contains('hostd transcript')) {
      return AgentCommandResult(
        stdout: jsonEncode({
          'sessionId': FakeReviewRunner.sessionId,
          'agent': {'name': 'api', 'state': state, 'lastEvent': lastEvent},
          'offset': 0,
          'size': 0,
          'start': 0,
          'entries': <Object>[],
        }),
        stderr: '',
        exitCode: 0,
      );
    }
    return review.run(command, timeout: timeout);
  }

  @override
  Future<void> close() async {}
}

void main() {
  SavedHost host() => buildHost('h').copyWith(
    agentAttentionEnabled: true,
    agentMonitor: AgentMonitorKind.companion,
  );

  Future<AgentAttentionController> start(
    WidgetTester tester,
    _Companion companion,
  ) async {
    final workspace = TerminalWorkspaceController(
      ImmediateTerminalRepository(TrackableTerminalSession()),
    );
    final controller = AgentAttentionController(
      workspace: workspace,
      runnerFactory: (_) => companion,
      provider: const ConductoreHostAttentionProvider(),
      companionProvider: const ConductoreHostAttentionProvider(),
      pollInterval: const Duration(days: 1),
    );
    controller.setLongPoll(false);
    addTearDown(controller.dispose);
    addTearDown(workspace.dispose);
    final session = workspace.open(host());
    await tester.runAsync(session.connect);
    await tester.runAsync(pumpEventQueue);
    return controller;
  }

  testWidgets('the capability is read from status', (tester) async {
    final with_ = await start(tester, _Companion());
    expect(with_.supportsSnapshots(host().id), isTrue);
    final without = await start(tester, _Companion(snapshots: false));
    expect(without.supportsSnapshots(host().id), isFalse);
  });

  Future<void> reviewFromInbox(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final attention = await start(tester, _Companion());
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentAttentionSheet(
            controller: attention,
            onOpenAgent: (host, agent) {},
          ),
        ),
      ),
    );
    await tester.pump();
    final review = find.byWidgetPredicate(
      (w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('agent-review-'),
    );
    expect(review, findsOneWidget);
    await tester.tap(review);
    await tester.runAsync(pumpEventQueue);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('review-page')), findsOneWidget);
    expect(find.text('a.dart'), findsOneWidget);
  }

  testWidgets('the inbox offers Review for an agent between turns', (
    tester,
  ) async {
    await reviewFromInbox(tester);
    // Phones: a full page, not the desktop dialog.
    expect(find.byKey(const ValueKey('desktop-page-frame')), findsNothing);
  });

  testWidgets(
    'desktop: Review opens as a dialog over the window',
    (tester) async {
      await reviewFromInbox(tester);
      expect(find.byKey(const ValueKey('desktop-page-frame')), findsOneWidget);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.linux,
      TargetPlatform.windows,
      TargetPlatform.macOS,
    }),
  );

  testWidgets('Chat View: a Review button, and Review after each turn', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final companion = _Companion()..state = 'working';
    final attention = await start(tester, companion);
    final settings = ThemeController(InMemoryThemePreferences());
    await settings.load();
    await settings.setVoice(
      settings.voice.copyWith(reviewOpens: ReviewOpens.afterEachTurn),
    );
    final chat = ChatViewController(
      runner: companion,
      sessionId: FakeReviewRunner.sessionId,
      pollInterval: const Duration(days: 1),
    );
    await tester.pumpWidget(
      VoiceSettingsScope(
        settings: settings,
        child: MaterialApp(
          home: ChatViewPage(
            controller: chat,
            onOpenTerminal: () {},
            attention: attention,
            hostId: host().id,
          ),
        ),
      ),
    );
    await tester.runAsync(pumpEventQueue);
    await tester.pump();
    expect(find.byKey(const ValueKey('chat-review')), findsOneWidget);
    expect(find.byKey(const ValueKey('review-page')), findsNothing);

    // The turn ends (Stop): Review opens by itself.
    companion
      ..state = 'waiting_input'
      ..lastEvent = 'Stop';
    await tester.runAsync(chat.refresh);
    await tester.pump();
    await tester.runAsync(pumpEventQueue);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('review-page')), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    // A question mid-turn does not.
    companion
      ..state = 'working'
      ..lastEvent = 'PreToolUse';
    await tester.runAsync(chat.refresh);
    await tester.pump();
    companion
      ..state = 'waiting_input'
      ..lastEvent = 'PreToolUse';
    await tester.runAsync(chat.refresh);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('review-page')), findsNothing);

    // On demand: the button.
    await tester.tap(find.byKey(const ValueKey('chat-review')));
    await tester.runAsync(pumpEventQueue);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('review-page')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
