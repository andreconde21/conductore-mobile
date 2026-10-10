import 'package:conduit/core/platform_features.dart';
import 'package:conduit/core/theme/theme_controller.dart';
import 'package:conduit/features/chat_view/domain/chat_items.dart';
import 'package:conduit/features/settings/presentation/settings_catalog.dart';
import 'package:conduit/features/settings/presentation/settings_page.dart';
import 'package:conduit/features/settings/presentation/settings_services.dart';
import 'package:conduit/features/voice/data/platform_speech_recognizer.dart';
import 'package:conduit/features/voice/data/platform_text_to_speech.dart';
import 'package:conduit/features/voice/domain/speech_event.dart';
import 'package:conduit/features/voice/domain/speech_recognizer.dart';
import 'package:conduit/features/voice/domain/text_to_speech.dart';
import 'package:conduit/features/voice/domain/voice_preferences.dart';
import 'package:conduit/features/voice/presentation/read_aloud_controller.dart';
import 'package:conduit/features/voice/presentation/speech_settings_controls.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';
import 'fake_tts.dart';

/// Voice on iOS: the platform gating, and the channel contract of
/// ios/Runner/SpeechRecognitionBridge.swift and TextToSpeechBridge.swift
/// (the maps below are exactly what the Swift bridges emit).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PlatformFeatures', () {
    testWidgets(
      'iOS has dictation, read-aloud and Talk but no restart beeps',
      (tester) async {
        expect(PlatformFeatures.dictation, isTrue);
        expect(PlatformFeatures.textToSpeech, isTrue);
        expect(PlatformFeatures.muteRestartBeeps, isFalse);
        // Still Android-only.
        expect(PlatformFeatures.shareTarget, isFalse);
        expect(PlatformFeatures.backgroundKeepalive, isFalse);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'Android keeps every voice feature',
      (tester) async {
        expect(PlatformFeatures.dictation, isTrue);
        expect(PlatformFeatures.textToSpeech, isTrue);
        expect(PlatformFeatures.muteRestartBeeps, isTrue);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'desktops have no voice',
      (tester) async {
        expect(PlatformFeatures.dictation, isFalse);
        expect(PlatformFeatures.textToSpeech, isFalse);
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.linux,
        TargetPlatform.macOS,
        TargetPlatform.windows,
      }),
    );
  });

  group('Settings on iOS', () {
    testWidgets('Chat & voice shows the speech settings', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final theme = ThemeController(InMemoryThemePreferences());
      await theme.load();
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsSectionPage(
            section: SettingsSection.chatVoice,
            services: SettingsServices(theme: theme),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Keep listening until I tap stop'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('settings-voice-commands')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('settings-voice-guide')),
        findsOneWidget,
      );
      expect(find.textContaining('not available on this device'), findsNothing);
      debugDefaultTargetPlatformOverride = null;
    });

    for (final (platform, beeps) in [
      (TargetPlatform.iOS, false),
      (TargetPlatform.android, true),
    ]) {
      testWidgets(
        'the restart beeps switch shows on ${platform.name}: $beeps',
        (tester) async {
          debugDefaultTargetPlatformOverride = platform;
          addTearDown(() => debugDefaultTargetPlatformOverride = null);
          final theme = ThemeController(InMemoryThemePreferences());
          await theme.load();
          tester.view.physicalSize = const Size(800, 2400);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: SingleChildScrollView(
                  child: Column(
                    children: [
                      SpeechSettingsControls(
                        controller: theme,
                        part: SpeechSettingsPart.dictation,
                      ),
                      SpeechSettingsControls(
                        controller: theme,
                        part: SpeechSettingsPart.advanced,
                        textToSpeech: FakeTts(),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text('Keep listening until I tap stop'), findsOneWidget);
          expect(
            find.text('Silence beeps between phrases'),
            beeps ? findsOneWidget : findsNothing,
          );
          debugDefaultTargetPlatformOverride = null;
        },
      );
    }
  });

  group('conduit/tts contract', () {
    const methods = MethodChannel('conduit/tts');
    const eventChannel = EventChannel('conduit/tts_events');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late List<MethodCall> calls;
    late MockStreamHandlerEventSink? sink;

    setUp(() {
      calls = [];
      sink = null;
      messenger.setMockMethodCallHandler(methods, (call) async {
        calls.add(call);
        return switch (call.method) {
          'isAvailable' || 'isInteractive' => true,
          'voices' => [
            {
              'id': 'com.apple.voice.enhanced.pt-PT.Joana',
              'name': 'Joana',
              'locale': 'pt-PT',
              'quality': 2,
            },
          ],
          _ => null,
        };
      });
      messenger.setMockStreamHandler(
        eventChannel,
        MockStreamHandler.inline(
          onListen: (_, eventSink) => sink = eventSink,
          onCancel: (_) => sink = null,
        ),
      );
    });

    tearDown(() {
      messenger.setMockMethodCallHandler(methods, null);
      messenger.setMockStreamHandler(eventChannel, null);
    });

    test('parses every event the Swift bridge emits', () async {
      final tts = PlatformTextToSpeech();
      final received = <TtsEvent>[];
      final subscription = tts.events.listen(received.add);
      await pumpEventQueue();
      sink!
        ..success({'type': 'start', 'id': 'u1'})
        ..success({'type': 'paused', 'id': 'u1', 'offset': 17})
        ..success({'type': 'stopped', 'id': 'u1'})
        ..success({'type': 'resumed'})
        ..success({'type': 'done', 'id': 'u1'})
        ..success({'type': 'interrupted'})
        ..success({
          'type': 'error',
          'id': 'u2',
          'message': 'Could not speak (audio busy).',
        });
      await pumpEventQueue();
      expect(received, [
        isA<TtsStarted>().having((e) => e.id, 'id', 'u1'),
        isA<TtsPaused>()
            .having((e) => e.id, 'id', 'u1')
            .having((e) => e.offset, 'offset', 17),
        isA<TtsStopped>().having((e) => e.id, 'id', 'u1'),
        isA<TtsResumed>(),
        isA<TtsDone>().having((e) => e.id, 'id', 'u1'),
        isA<TtsInterrupted>(),
        isA<TtsFailed>()
            .having((e) => e.id, 'id', 'u2')
            .having((e) => e.message, 'message', contains('busy')),
      ]);
      await subscription.cancel();
    });

    test('sends the Android argument maps and reads iOS voices', () async {
      final tts = PlatformTextToSpeech();
      expect(await tts.isAvailable(), isTrue);
      final voices = await tts.voices(language: 'pt-PT');
      expect(voices.single.id, 'com.apple.voice.enhanced.pt-PT.Joana');
      expect(voices.single.locale, 'pt-PT');
      expect(voices.single.quality, 2);
      await tts.setRate(1.5);
      await tts.setPitch(0.8);
      await tts.speak('Olá.', id: 'u1', language: 'pt-PT');
      await tts.stop();
      expect(calls.map((c) => c.method), [
        'isAvailable',
        'voices',
        'setRate',
        'setPitch',
        'speak',
        'stop',
      ]);
      expect(calls[1].arguments, {'language': 'pt-PT'});
      expect(calls[2].arguments, {'rate': 1.5});
      expect(calls[3].arguments, {'pitch': 0.8});
      expect(calls[4].arguments, {
        'text': 'Olá.',
        'id': 'u1',
        'language': 'pt-PT',
        'voice': null,
      });
    });

    test(
      'a call pausing iOS read-aloud resumes from the cut sentence',
      () async {
        final tts = PlatformTextToSpeech();
        final controller = ReadAloudController(
          tts: tts,
          preferences: () => VoicePreferences.defaults,
          enabled: true,
        );
        addTearDown(controller.dispose);
        const text = 'One is done. Two is next. Three last.';
        ChatUserMessage prompt() => const ChatUserMessage('u1', text: 'go');
        controller.observe([prompt()], const [], 'working');
        controller.observe(
          [prompt(), const ChatAssistantText('a', text: text)],
          const [],
          'waiting_input',
        );
        await pumpEventQueue();
        final speaks = calls.where((c) => c.method == 'speak').toList();
        expect(speaks, hasLength(1));
        final id = (speaks.single.arguments as Map)['id'] as String;
        expect((speaks.single.arguments as Map)['text'], text);

        // What TextToSpeechBridge.swift sends for a call arriving in the
        // middle of "Two is next" and ending with shouldResume.
        sink!
          ..success({'type': 'start', 'id': id})
          ..success({'type': 'paused', 'id': id, 'offset': 17})
          ..success({'type': 'stopped', 'id': id});
        await pumpEventQueue();
        expect(controller.busy, isTrue, reason: 'the reply is kept');
        expect(calls.where((c) => c.method == 'speak'), hasLength(1));

        sink!.success({'type': 'resumed'});
        await pumpEventQueue();
        final resumed = calls.where((c) => c.method == 'speak').toList();
        expect(resumed, hasLength(2));
        expect(
          (resumed.last.arguments as Map)['text'],
          'Two is next. Three last.',
        );
      },
    );
  });

  group('conduit/speech contract', () {
    const methods = MethodChannel('conduit/speech');
    const eventChannel = EventChannel('conduit/speech_events');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late List<MethodCall> calls;
    late MockStreamHandlerEventSink? sink;

    setUp(() {
      calls = [];
      sink = null;
      messenger.setMockMethodCallHandler(methods, (call) async {
        calls.add(call);
        return switch (call.method) {
          'isAvailable' || 'hasPermission' || 'openSettings' => true,
          'requestPermission' => false,
          _ => null,
        };
      });
      messenger.setMockStreamHandler(
        eventChannel,
        MockStreamHandler.inline(
          onListen: (_, eventSink) => sink = eventSink,
          onCancel: (_) => sink = null,
        ),
      );
    });

    tearDown(() {
      messenger.setMockMethodCallHandler(methods, null);
      messenger.setMockStreamHandler(eventChannel, null);
    });

    test('parses every event the Swift bridge emits', () async {
      final recognizer = PlatformSpeechRecognizer();
      final received = <SpeechEvent>[];
      final subscription = recognizer.events.listen(received.add);
      await pumpEventQueue();
      sink!
        ..success({'type': 'status', 'value': 'ready'})
        ..success({'type': 'level', 'value': 0.42})
        ..success({'type': 'status', 'value': 'listening'})
        ..success({'type': 'partial', 'text': 'olá'})
        ..success({'type': 'status', 'value': 'ended'})
        ..success({'type': 'result', 'text': 'Olá.'})
        ..success({
          'type': 'error',
          'code': 6,
          'message': 'No speech was heard.',
        })
        ..success({
          'type': 'error',
          'code': 9,
          'message': 'Microphone or speech recognition permission denied.',
        })
        ..success({
          'type': 'error',
          'code': 1000,
          'message':
              'Speech recognition is not available. Turn on Dictation in '
              'Settings.',
        });
      await pumpEventQueue();
      expect(received, [
        isA<SpeechReady>(),
        isA<SpeechLevel>().having((e) => e.value, 'value', 0.42),
        isA<SpeechListening>(),
        isA<SpeechPartial>().having((e) => e.text, 'text', 'olá'),
        isA<SpeechEnded>(),
        isA<SpeechResult>().having((e) => e.text, 'text', 'Olá.'),
        isA<SpeechError>().having((e) => e.isQuiet, 'isQuiet', isTrue),
        isA<SpeechError>().having(
          (e) => e.code,
          'code',
          SpeechError.insufficientPermissions,
        ),
        isA<SpeechError>().having((e) => e.code, 'code', 1000),
      ]);
      await subscription.cancel();
    });

    test('sends the Android argument maps', () async {
      final recognizer = PlatformSpeechRecognizer();
      expect(await recognizer.isAvailable(), isTrue);
      expect(await recognizer.hasPermission(), isTrue);
      expect(await recognizer.requestPermission(), isFalse);
      expect(await recognizer.openSettings(), isTrue);
      await recognizer.start(
        language: 'pt-PT',
        options: const SpeechListenOptions(
          continuous: true,
          restart: true,
          completeSilenceMillis: 4000,
        ),
      );
      await recognizer.stop();
      await recognizer.cancel();
      expect(calls.map((c) => c.method), [
        'isAvailable',
        'hasPermission',
        'requestPermission',
        'openSettings',
        'start',
        'stop',
        'cancel',
      ]);
      expect(calls[4].arguments, {
        'language': 'pt-PT',
        'continuous': true,
        'restart': true,
        'muteBeeps': false,
        'completeSilenceMillis': 4000,
      });
    });
  });
}
