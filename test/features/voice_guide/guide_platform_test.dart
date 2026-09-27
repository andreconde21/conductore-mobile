import 'package:conduit/core/platform_features.dart';
import 'package:conduit/features/agent_attention/data/herdr_attention_provider.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:conduit/features/voice/data/platform_speech_recognizer.dart';
import 'package:conduit/features/voice/data/platform_text_to_speech.dart';
import 'package:conduit/features/voice/domain/speech_event.dart';
import 'package:conduit/features/voice/domain/text_to_speech.dart';
import 'package:conduit/features/voice/presentation/voice_services.dart';
import 'package:conduit/features/voice_guide/domain/approval_actions.dart';
import 'package:conduit/features/voice_guide/presentation/app_guide.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    test('${platform.name}: the guide gets the one recognizer and voice', () {
      debugDefaultTargetPlatformOverride = platform;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      expect(PlatformFeatures.dictation, isTrue);
      expect(PlatformFeatures.textToSpeech, isTrue);
      final voice = VoiceServices.platform();
      expect(voice.recognizer, isA<PlatformSpeechRecognizer>());
      expect(voice.tts, isA<PlatformTextToSpeech>());
    });
  }

  // The native bridges (Kotlin and Swift) keep one sink and replace it on
  // every listen; a cancel drops it. However many recognizers or voices
  // listen in Dart, the platform must see one listen, and no cancel while
  // any of them still listens.
  test('speech events: one platform listen for every listener', () async {
    var listens = 0;
    var cancels = 0;
    MockStreamHandlerEventSink? sink;
    messenger.setMockStreamHandler(
      const EventChannel('conduit/speech_events'),
      MockStreamHandler.inline(
        onListen: (_, events) {
          listens += 1;
          sink = events;
        },
        onCancel: (_) {
          cancels += 1;
          sink = null;
        },
      ),
    );
    addTearDown(
      () => messenger.setMockStreamHandler(
        const EventChannel('conduit/speech_events'),
        null,
      ),
    );
    final chat = <SpeechEvent>[];
    final guide = <SpeechEvent>[];
    final a = PlatformSpeechRecognizer().events.listen(chat.add);
    final b = PlatformSpeechRecognizer().events.listen(guide.add);
    await pumpEventQueue();
    expect(listens, 1);
    sink!.success({'type': 'partial', 'text': 'open api'});
    await pumpEventQueue();
    expect(chat, hasLength(1));
    expect(guide, hasLength(1));
    // The chat closes: the guide still hears.
    await a.cancel();
    await pumpEventQueue();
    expect(cancels, 0);
    sink!.success({'type': 'partial', 'text': 'approve'});
    await pumpEventQueue();
    expect(guide, hasLength(2));
    await b.cancel();
    await pumpEventQueue();
    expect(cancels, 1);
    // A later listener starts it again.
    final c = PlatformSpeechRecognizer().events.listen((_) {});
    await pumpEventQueue();
    expect(listens, 2);
    await c.cancel();
  });

  test('tts events: one platform listen for every listener', () async {
    var listens = 0;
    MockStreamHandlerEventSink? sink;
    messenger.setMockStreamHandler(
      const EventChannel('conduit/tts_events'),
      MockStreamHandler.inline(
        onListen: (_, events) {
          listens += 1;
          sink = events;
        },
      ),
    );
    addTearDown(
      () => messenger.setMockStreamHandler(
        const EventChannel('conduit/tts_events'),
        null,
      ),
    );
    final chat = <TtsEvent>[];
    final guide = <TtsEvent>[];
    final a = PlatformTextToSpeech().events.listen(chat.add);
    final b = PlatformTextToSpeech().events.listen(guide.add);
    await pumpEventQueue();
    expect(listens, 1);
    sink!.success({'type': 'done', 'id': 'read-aloud-1'});
    await pumpEventQueue();
    expect(chat.single, isA<TtsDone>());
    expect(guide.single, isA<TtsDone>());
    await a.cancel();
    await b.cancel();
  });

  test('risk labels from the companion drive the guide', () {
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
    final actions = attentionApprovalActions(attention);
    PendingPermissionRequest request(PermissionRiskLevel? level) =>
        PendingPermissionRequest(
          id: 'r',
          toolName: 'Bash',
          summary: 'x',
          risk: level == null ? null : PermissionRisk(level, ''),
        );
    expect(
      actions.riskOf('vtm', request(PermissionRiskLevel.low)),
      ApprovalRisk.low,
    );
    expect(
      actions.riskOf('vtm', request(PermissionRiskLevel.high)),
      ApprovalRisk.high,
    );
    expect(actions.riskOf('vtm', request(null)), ApprovalRisk.unknown);
    // Not connected, or no capability: nothing batched or trusted there.
    expect(actions.supportsTrust, isFalse);
    expect(actions.canTrust('vtm'), isFalse);
  });
}
