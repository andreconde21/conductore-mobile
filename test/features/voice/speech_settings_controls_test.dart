import 'package:conduit/core/theme/theme_controller.dart';
import 'package:conduit/core/theme/theme_preferences_repository.dart';
import 'package:conduit/features/voice/domain/text_to_speech.dart';
import 'package:conduit/features/voice/presentation/speech_settings_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';
import 'fake_tts.dart';

void main() {
  late ThemeController settings;
  late ThemePreferencesRepository repository;
  late FakeTts tts;

  setUp(() async {
    repository = ThemePreferencesRepository(InMemorySecureStorage());
    settings = ThemeController(repository);
    await settings.load();
    await settings.setSpeechLanguage('pt-PT');
    tts = FakeTts()
      ..installedVoices = const [
        TtsVoice(id: 'pt-pt-x-sfs-local', locale: 'pt-PT', quality: 400),
      ];
  });

  Future<void> pump(WidgetTester tester, SpeechSettingsPart part) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SpeechSettingsControls(
              controller: settings,
              part: part,
              textToSpeech: tts,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('continuous dictation settings persist', (tester) async {
    await pump(tester, SpeechSettingsPart.dictation);
    // Reading aloud is under Advanced, voice commands on their own page.
    expect(find.text('Read replies aloud by default'), findsNothing);
    expect(find.byKey(const ValueKey('speech-voice-commands')), findsNothing);
    expect(find.text('Keep listening until I tap stop'), findsOneWidget);
    expect(find.text('8 s'), findsOneWidget);
    expect(find.text('5 min'), findsOneWidget);

    final silence = find.descendant(
      of: find.byKey(const ValueKey('speech-silence')),
      matching: find.byType(Slider),
    );
    await tester.drag(silence, const Offset(-2000, 0));
    await tester.pumpAndSettle();
    expect(settings.voice.dictationSilenceSeconds, 3);

    await tester.tap(find.text('Keep listening until I tap stop'));
    await tester.pumpAndSettle();
    expect(settings.voice.continuousDictation, isFalse);
    expect(find.byKey(const ValueKey('speech-silence')), findsNothing);

    final reloaded = ThemeController(repository);
    await reloaded.load();
    expect(reloaded.voice.continuousDictation, isFalse);
    expect(reloaded.voice.dictationSilenceSeconds, 3);
  });

  testWidgets('read-aloud default, voice, speed and the sample', (
    tester,
  ) async {
    await pump(tester, SpeechSettingsPart.advanced);
    // Chat View's ⋮ has How much to read (CON-108).
    expect(find.text('How much to read'), findsNothing);
    expect(find.text('Keep listening until I tap stop'), findsNothing);
    await tester.tap(find.text('Read replies aloud by default'));
    await tester.pumpAndSettle();
    expect(settings.voice.readAloudByDefault, isTrue);
    expect(find.text('Same as dictation'), findsOneWidget);
    expect(find.byKey(const ValueKey('speech-talk-send')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('speech-tts-voice')));
    await tester.pumpAndSettle();
    expect(tts.voiceQueries, ['pt-PT'], reason: 'follows dictation language');
    await tester.tap(find.text('pt-pt-x-sfs-local'));
    await tester.pumpAndSettle();
    expect(tts.voicesUsed.last, 'pt-pt-x-sfs-local', reason: 'previewed');
    await tester.tap(find.text('Use'));
    await tester.pumpAndSettle();
    expect(settings.voice.ttsVoice, 'pt-pt-x-sfs-local');

    final speed = find.descendant(
      of: find.byKey(const ValueKey('speech-rate')),
      matching: find.byType(Slider),
    );
    await tester.drag(speed, const Offset(2000, 0));
    await tester.pumpAndSettle();
    expect(settings.voice.ttsRate, 2.0);

    await tester.tap(find.byKey(const ValueKey('speech-test')));
    await tester.pumpAndSettle();
    expect(tts.spoken.last, 'É assim que as respostas do agente vão soar.');
    expect(tts.rate, 2.0);

    // Picking a reading language resets the voice (voices are per
    // language).
    await tester.tap(find.byKey(const ValueKey('speech-tts-language')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('English (UK)'));
    await tester.tap(find.text('Use'));
    await tester.pumpAndSettle();
    expect(settings.voice.ttsLanguage, 'en-GB');
    expect(settings.voice.ttsVoice, '');
  });
}
