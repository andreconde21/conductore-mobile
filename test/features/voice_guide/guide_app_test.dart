import 'dart:convert';

import 'package:conduit/core/theme/theme_controller.dart';
import 'package:conduit/features/agent_attention/data/herdr_attention_provider.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/home_widget/domain/agent_status_widget_channel.dart';
import 'package:conduit/features/home_widget/presentation/agent_status_launch_listener.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:conduit/features/voice/domain/speech_event.dart';
import 'package:conduit/features/voice/domain/voice_preferences.dart';
import 'package:conduit/features/voice/presentation/dictation_controller.dart';
import 'package:conduit/features/voice/presentation/read_aloud_controller.dart';
import 'package:conduit/features/voice_guide/data/companion_guide_brain.dart';
import 'package:conduit/features/voice_guide/domain/guide_brain.dart';
import 'package:conduit/features/voice_guide/domain/guide_preferences.dart';
import 'package:conduit/features/voice_guide/presentation/guide_controller.dart';
import 'package:conduit/features/voice_guide/presentation/guide_overlay.dart';
import 'package:conduit/features/voice_guide/presentation/guide_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';
import '../home_widget/fake_agent_status_widget_channel.dart';
import '../voice/fake_speech_recognizer.dart';
import '../voice/fake_tts.dart';
import 'guide_fixtures.dart';

/// Answers `guide` with [reply] per host, recording the command and stdin.
class GuideRunner extends ScriptedAgentCommandRunner
    implements StdinAgentCommandRunner {
  GuideRunner(this.reply) : super(const []);

  final AgentCommandResult reply;
  final calls = <(String, String)>[];

  @override
  Future<AgentCommandResult> runWithStdin(
    String command, {
    required String stdin,
    required Duration timeout,
    Future<void>? cancel,
  }) async {
    calls.add((command, stdin));
    return reply;
  }
}

AgentCommandResult result(String stdout, {int exitCode = 0}) =>
    AgentCommandResult(stdout: stdout, stderr: '', exitCode: exitCode);

void main() {
  group('CompanionGuideBrain', () {
    test('the request goes on stdin, never in the command line', () async {
      final runner = GuideRunner(
        result(
          '{"schema":1,"action":{"action":"home","target":"","text":"","minutes":0,"speak":"Home."}}',
        ),
      );
      final brain = CompanionGuideBrain(
        candidates: () => [buildHost('vtm')],
        runnerFor: (_) => (runner, owned: true),
      );
      final reply = await brain.ask('secret-word-4412 go home', {'lang': 'en'});
      expect((reply as GuideBrainAction).action, 'home');
      final (command, stdin) = runner.calls.single;
      expect(command, contains('guide --timeout-ms 15000'));
      expect(command, isNot(contains('secret-word-4412')));
      expect(jsonDecode(stdin), {
        'utterance': 'secret-word-4412 go home',
        'context': {'lang': 'en'},
      });
      expect(runner.closeCount, 1, reason: 'an owned runner is closed');
    });

    test(
      'an older companion is skipped for the next machine, and remembered',
      () async {
        final old = GuideRunner(
          result('{"error":"unknown command guide"}', exitCode: 1),
        );
        final current = GuideRunner(
          result('{"schema":1,"error":"busy","message":"x"}'),
        );
        final brain = CompanionGuideBrain(
          candidates: () => [buildHost('old'), buildHost('new')],
          runnerFor: (host) => (host.id == 'old' ? old : current, owned: false),
        );
        expect(
          ((await brain.ask('hi', const {})) as GuideBrainFailed).reason,
          'busy',
        );
        await brain.ask('again', const {});
        expect(old.calls, hasLength(1));
        expect(current.calls, hasLength(2));
        expect(old.closeCount, 0, reason: "the monitor's runner stays open");
      },
    );

    test('no machine at all, or none new enough', () async {
      final none = CompanionGuideBrain(
        candidates: () => const <SavedHost>[],
        runnerFor: (_) => throw StateError('never'),
      );
      expect(
        ((await none.ask('hi', const {})) as GuideBrainFailed).reason,
        GuideBrainFailed.noBrain,
      );
      final old = CompanionGuideBrain(
        candidates: () => [buildHost('old')],
        runnerFor: (_) => (
          GuideRunner(result('{"error":"unknown command guide"}', exitCode: 1)),
          owned: true,
        ),
      );
      expect(
        ((await old.ask('hi', const {})) as GuideBrainFailed).reason,
        GuideBrainFailed.outdated,
      );
    });
  });

  test('guide settings live in the voice preferences JSON', () {
    const prefs = VoicePreferences(
      guide: GuidePreferences(
        brainHostId: 'vtm',
        confirm: GuideConfirm.skipLowRisk,
        language: 'pt-PT',
        headsetWake: true,
      ),
    );
    final back = VoicePreferences.decode(prefs.encode());
    expect(back.guide, prefs.guide);
    expect(VoicePreferences.decode('{}').guide, GuidePreferences.defaults);
    expect(
      VoicePreferences.decode(
        '{"guide":{"confirm":"nonsense","enabled":1}}',
      ).guide,
      GuidePreferences.defaults,
    );
  });

  testWidgets('the Voice guide tile launch starts the guide', (tester) async {
    final workspace = TerminalWorkspaceController(
      ImmediateTerminalRepository(TrackableTerminalSession()),
    );
    final attention = AgentAttentionController(
      workspace: workspace,
      runnerFactory: (_) => ScriptedAgentCommandRunner(const []),
      provider: const HerdrAttentionProvider(),
      pollInterval: const Duration(days: 1),
    );
    addTearDown(() {
      attention.dispose();
      workspace.dispose();
    });
    var started = 0;
    final channel = FakeAgentStatusWidgetChannel()
      ..pendingTarget = AgentStatusLaunchTarget.guide;
    await tester.pumpWidget(
      MaterialApp(
        home: AgentStatusLaunchListener(
          channel: channel,
          agentAttention: attention,
          workspace: workspace,
          onGuide: () => started += 1,
          child: const Scaffold(body: Text('home')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(started, 1);
    expect(find.byType(BottomSheet), findsNothing);
  });

  testWidgets(
    'settings: turning options on saves them',
    (tester) async {
      final theme = ThemeController(InMemoryThemePreferences());
      await theme.load();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListenableBuilder(
              listenable: theme,
              builder: (context, _) =>
                  ListView(children: [GuideSettingsControls(theme: theme)]),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('guide-headset')));
      await tester.pumpAndSettle();
      expect(theme.voice.guide.headsetWake, isTrue);
      await tester.tap(find.text(GuideConfirm.skipLowRisk.label));
      await tester.pumpAndSettle();
      expect(theme.voice.guide.confirm, GuideConfirm.skipLowRisk);
      await tester.tap(find.byKey(const ValueKey('guide-language')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Português (Portugal)'));
      await tester.pumpAndSettle();
      expect(theme.voice.guide.language, 'pt-PT');
      await tester.tap(find.byKey(const ValueKey('guide-enabled')));
      await tester.pumpAndSettle();
      expect(theme.voice.guide.enabled, isFalse);
      expect(find.byKey(const ValueKey('guide-headset')), findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets('the overlay shows what was heard and stops the guide', (
    tester,
  ) async {
    final mic = FakeSpeechRecognizer();
    final dictation = DictationController(mic, language: () => 'en-US');
    final speaker = ReadAloudController(
      tts: FakeTts(),
      preferences: () => VoicePreferences.defaults,
    );
    final guide = GuideController(
      dictation: dictation,
      speaker: speaker,
      world: fleet,
      approvals: FakeApprovals(),
      navigator: FakeNavigator(fleet().screen),
      messenger: FakeMessenger(),
      preferences: () => GuidePreferences.defaults,
      speechLanguage: () => 'en-US',
    );
    addTearDown(() {
      guide.dispose();
      speaker.dispose();
      dictation.dispose();
    });
    // Where the app puts it: above the navigator, outside its Overlay.
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => Stack(
          children: [
            ?child,
            GuideOverlay(controller: guide),
          ],
        ),
        home: const Scaffold(body: Text('home')),
      ),
    );
    expect(find.byKey(const ValueKey('guide-overlay')), findsNothing);
    guide.start();
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.text('Listening…'), findsOneWidget);
    mic.emit(const SpeechPartial('open api'));
    await tester.pump();
    expect(find.text('open api'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('guide-stop')));
    await tester.pump();
    expect(guide.phase, GuidePhase.off);
    expect(find.byKey(const ValueKey('guide-overlay')), findsNothing);
  });
}
