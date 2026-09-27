import 'dart:async';

import 'package:conduit/features/agent_attention/data/conductore_host_attention_provider.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_controller.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_launcher.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_page.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_presenter.dart';
import 'package:conduit/features/desktop_shell/presentation/chat_view_tab.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/session_navigation/domain/session_view_preferences.dart';
import 'package:conduit/features/session_navigation/presentation/session_view_controller.dart';
import 'package:conduit/features/session_navigation/presentation/session_view_launcher.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:conduit/features/voice/domain/speech_event.dart';
import 'package:conduit/features/voice/presentation/dictation_button.dart';
import 'package:conduit/features/voice/presentation/dictation_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';
import '../voice/fake_speech_recognizer.dart';
import '../voice/fake_tts.dart';
import 'chat_fixtures.dart';

/// Records whether anyone still listens to the recognizer's events.
class _TrackedRecognizer extends FakeSpeechRecognizer {
  final _tracked = StreamController<SpeechEvent>.broadcast(sync: true);

  bool get subscribed => _tracked.hasListener;

  @override
  Stream<SpeechEvent> get events => _tracked.stream;
}

AgentCommandResult ok(String stdout) =>
    AgentCommandResult(stdout: stdout, stderr: '', exitCode: 0);

/// The mic and Talk are in Chat View however it was opened, not only from
/// the terminal (which hands over its own dictation).
void main() {
  final talk = find.byKey(const ValueKey('chat-talk'));
  final mic = find.byType(DictationButton);

  const agent = AgentInfo(
    id: 's-1',
    name: 'api',
    state: AgentAttentionState.working,
    kind: 'claude',
  );

  SavedHost companionHost() => buildHost('h').copyWith(
    agentAttentionEnabled: true,
    agentMonitor: AgentMonitorKind.companion,
  );

  final status = ok(
    '{"version":1,"seq":2,"agents":[{"sessionId":"s-1","name":"api",'
    '"cwd":"/home/a/api","state":"working","kind":"claude","pending":[]}]}',
  );

  /// The workspace of the last [monitor].
  late TerminalWorkspaceController workspace;

  Future<AgentAttentionController> monitor(
    WidgetTester tester,
    SavedHost host,
  ) async {
    workspace = TerminalWorkspaceController(
      ImmediateTerminalRepository(TrackableTerminalSession()),
    );
    final controller = AgentAttentionController(
      workspace: workspace,
      runnerFactory: (_) => ScriptedAgentCommandRunner([status, status]),
      provider: const ConductoreHostAttentionProvider(),
      pollInterval: const Duration(days: 1),
    );
    controller.setAppForeground(false);
    addTearDown(controller.dispose);
    addTearDown(workspace.dispose);
    final session = workspace.open(host);
    await tester.runAsync(session.connect);
    await tester.runAsync(pumpEventQueue);
    return controller;
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i += 1) {
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  Future<void> tapGo(WidgetTester tester, Widget app) async {
    await tester.pumpWidget(app);
    await tester.tap(find.text('go'));
    await settle(tester);
    addTearDown(() => tester.pumpWidget(const SizedBox()));
  }

  Widget goButton(void Function(BuildContext context) onPressed) => MaterialApp(
    home: Builder(
      builder: (context) => TextButton(
        onPressed: () => onPressed(context),
        child: const Text('go'),
      ),
    ),
  );

  void expectVoice() {
    expect(find.byType(ChatViewPage), findsOneWidget);
    expect(mic, findsOneWidget);
    expect(talk, findsOneWidget);
  }

  group('opened without a dictation controller', () {
    testWidgets('home Chat buttons, Needs you and the switcher '
        '(openChatView)', (tester) async {
      final attention = await monitor(tester, companionHost());
      await tapGo(
        tester,
        goButton(
          (context) => unawaited(
            openChatView(
              context: context,
              attention: attention,
              host: companionHost(),
              agent: agent,
              onOpenTerminal: () {},
            ),
          ),
        ),
      );
      expectVoice();
    });

    testWidgets('a session that opens in Chat View (openPreferredChatView)', (
      tester,
    ) async {
      final attention = await monitor(tester, companionHost());
      final views = SessionViewController(
        InMemorySessionViewPreferencesRepository(
          const SessionViewPreferences(defaultView: SessionView.chat),
        ),
      );
      await views.load();
      addTearDown(views.dispose);
      var opened = false;
      await tapGo(
        tester,
        SessionViewScope(
          controller: views,
          child: goButton(
            (context) => unawaited(
              openPreferredChatView(
                context,
                attention: attention,
                workspace: workspace,
                session: workspace.activeSession!,
                onOpenTerminal: (_, _) {},
              ).then((value) => opened = value),
            ),
          ),
        ),
      );
      expect(opened, isTrue);
      expectVoice();
    });

    testWidgets('"Open chat view" for a machine (openChatViewForHost)', (
      tester,
    ) async {
      final attention = await monitor(tester, companionHost());
      await tapGo(
        tester,
        goButton(
          (context) => unawaited(
            openChatViewForHost(
              context: context,
              attention: attention,
              host: companionHost(),
              onOpenTerminal: (_) {},
            ),
          ),
        ),
      );
      expectVoice();
    });

    testWidgets('a desktop shell tab (ChatViewPresenter)', (tester) async {
      final attention = await monitor(tester, companionHost());
      ChatViewRequest? request;
      await tester.pumpWidget(
        ChatViewPresenter(
          present: (presented) {
            request = presented;
            return true;
          },
          child: goButton(
            (context) => unawaited(
              openChatView(
                context: context,
                attention: attention,
                host: companionHost(),
                agent: agent,
                onOpenTerminal: () {},
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pump();
      expect(request, isNotNull);
      expect(request!.dictation, isNull);
      addTearDown(request!.dispose);
      final tab = ChatViewTab(request!);
      await tester.pumpWidget(
        MaterialApp(home: Builder(builder: tab.viewBuilder)),
      );
      await settle(tester);
      addTearDown(() => tester.pumpWidget(const SizedBox()));
      expectVoice();
    });
  });

  Future<ChatViewController> pumpPage(
    WidgetTester tester, {
    DictationController? dictation,
    FakeSpeechRecognizer? speechRecognizer,
  }) async {
    final controller = ChatViewController(
      runner: ScriptedAgentCommandRunner([
        ok(page([userLine('u1', 'hello')])),
      ]),
      sessionId: 's-1',
      pollInterval: const Duration(days: 1),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ChatViewPage(
          controller: controller,
          onOpenTerminal: () {},
          textToSpeech: FakeTts(),
          dictation: dictation,
          speechRecognizer: speechRecognizer,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    return controller;
  }

  testWidgets('the page makes its own dictation and disposes it', (
    tester,
  ) async {
    final recognizer = _TrackedRecognizer();
    await pumpPage(tester, speechRecognizer: recognizer);
    expectVoice();
    final own = tester.widget<DictationButton>(mic).controller;

    await tester.tap(mic);
    await tester.pump();
    expect(own.isActive, isTrue);
    expect(recognizer.starts, hasLength(1));
    expect(recognizer.subscribed, isTrue);

    await tester.pumpWidget(const SizedBox());
    // Disposed while listening: the recognizer is released and nothing
    // listens to it any more.
    expect(recognizer.cancels, 1);
    expect(recognizer.subscribed, isFalse);
    expect(() => own.addListener(() {}), throwsFlutterError);
  });

  testWidgets('without speech on the platform the mic and Talk stay out, '
      'as in the terminal', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await pumpPage(tester);
    expect(find.byType(ChatViewPage), findsOneWidget);
    expect(mic, findsNothing);
    expect(talk, findsNothing);
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });

  group('opened from the terminal', () {
    testWidgets('uses the terminal\'s dictation: no second recognizer', (
      tester,
    ) async {
      final terminalMic = FakeSpeechRecognizer();
      final terminal = DictationController(terminalMic, language: () => '');
      addTearDown(terminal.dispose);
      final unused = FakeSpeechRecognizer();
      await pumpPage(tester, dictation: terminal, speechRecognizer: unused);
      expectVoice();
      expect(tester.widget<DictationButton>(mic).controller, same(terminal));

      await tester.tap(mic);
      await tester.pump();
      expect(terminal.isActive, isTrue);
      expect(terminalMic.starts, hasLength(1));
      expect(unused.starts, isEmpty);

      await tester.pumpWidget(const SizedBox());
      // Not the page's to dispose.
      expect(() => terminal.addListener(() {}), returnsNormally);
    });

    testWidgets('a chat\'s own dictation stops the terminal\'s before it '
        'listens', (tester) async {
      // One platform recognizer, as on the phone.
      final platform = FakeSpeechRecognizer();
      final terminal = DictationController(platform, language: () => '');
      addTearDown(terminal.dispose);
      final finished = <String>[];
      await terminal.start(
        DictationSink(
          onBegin: () {},
          onPartial: (_) {},
          onFinish: finished.add,
          onCancel: () {},
        ),
      );
      platform.emit(const SpeechPartial('half a'));
      expect(terminal.isActive, isTrue);

      await pumpPage(tester, speechRecognizer: platform);
      final own = tester.widget<DictationButton>(mic).controller;
      expect(own, isNot(same(terminal)));
      await tester.tap(mic);
      await tester.pump();

      expect(terminal.isActive, isFalse);
      expect(finished, ['half a'], reason: 'what it heard is kept');
      expect(platform.cancels, 1);
      expect(own.isActive, isTrue);
      expect(platform.starts, hasLength(2));
      await tester.pumpWidget(const SizedBox());
    });
  });
}
