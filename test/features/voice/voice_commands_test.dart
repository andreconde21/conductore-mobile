import 'package:conduit/features/settings/presentation/settings_catalog.dart';
import 'package:conduit/features/voice/domain/speech_event.dart';
import 'package:conduit/features/voice/domain/voice_commands.dart';
import 'package:conduit/features/voice/domain/voice_preferences.dart';
import 'package:conduit/features/voice/presentation/dictation_controller.dart';
import 'package:conduit/features/voice/presentation/speech_settings_controls.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_speech_recognizer.dart';

/// CON-098: a trailing "send" or "cancel" after a short pause ends a
/// dictation; the word anywhere else is just a word.
void main() {
  group('VoiceCommandWords.trailing', () {
    final words = VoiceCommandWords.defaults;

    test('finds a trailing command and strips it', () {
      expect(words.trailing('fix the bug send'), (
        command: VoiceCommand.send,
        message: 'fix the bug',
      ));
      expect(words.trailing('Fix the bug. Send it.'), (
        command: VoiceCommand.send,
        message: 'Fix the bug.',
      ));
      expect(words.trailing('corrige o teste, enviar'), (
        command: VoiceCommand.send,
        message: 'corrige o teste',
      ));
      expect(words.trailing('never mind cancel'), (
        command: VoiceCommand.cancel,
        message: 'never mind',
      ));
      expect(words.trailing('Cancelar'), (
        command: VoiceCommand.cancel,
        message: '',
      ));
    });

    test('ignores the word anywhere but the end', () {
      expect(words.trailing('send the report to Ana'), isNull);
      expect(words.trailing('sending'), isNull);
      expect(words.trailing(''), isNull);
    });

    test('custom lists and the preference switch', () {
      final custom = VoiceCommandWords.parse(send: 'go, ship it', cancel: '');
      expect(custom.trailing('deploy ship it')?.message, 'deploy');
      expect(custom.trailing('deploy send'), isNull);
      expect(custom.trailing('nope cancel'), isNull);

      expect(VoicePreferences.defaults.voiceCommands, isTrue);
      expect(
        VoicePreferences.defaults.copyWith(voiceCommands: false).commandWords,
        isNull,
      );
      final saved = VoicePreferences.decode(
        VoicePreferences.defaults
            .copyWith(voiceCommands: false, voiceSendWords: 'go')
            .encode(),
      );
      expect(saved.voiceCommands, isFalse);
      expect(saved.voiceSendWords, 'go');
    });

    test('settings search finds the voice commands', () {
      for (final query in ['voice command', 'send', 'enviar', 'cancelar']) {
        expect(
          settingsCatalog
              .where((entry) => entry.matches(query))
              .map((entry) => entry.title),
          contains(voiceCommandsTitle),
          reason: query,
        );
      }
    });
  });

  group('DictationController', () {
    late FakeSpeechRecognizer recognizer;
    late DictationController controller;
    late List<String> log;

    DictationSink sink({bool commands = true}) => DictationSink(
      onBegin: () => log.add('begin'),
      onPartial: (text) => log.add('partial:$text'),
      onFinish: (text) => log.add('finish:$text'),
      onCancel: () => log.add('cancel'),
      onDiscard: () => log.add('discard'),
      onCommand: commands
          ? (command, message) => log.add('${command.name}:$message')
          : null,
    );

    DictationOptions options({bool continuous = false}) => DictationOptions(
      continuous: continuous,
      commands: VoiceCommandWords.defaults,
    );

    setUp(() {
      recognizer = FakeSpeechRecognizer();
      controller = DictationController(recognizer, language: () => '');
      log = [];
    });

    tearDown(() => controller.dispose());

    testWidgets('a command after a pause ends the dictation and sends', (
      tester,
    ) async {
      await controller.start(sink(), options: options());
      recognizer
        ..emit(const SpeechReady())
        ..emit(const SpeechPartial('fix the bug'));
      await tester.pump(const Duration(seconds: 1));
      recognizer.emit(const SpeechPartial('fix the bug send'));
      await tester.pump(const Duration(milliseconds: 1100));

      expect(log.last, 'send:fix the bug');
      expect(controller.status, DictationStatus.idle);
      expect(recognizer.cancels, 1);

      // The recognizer's own result for that session comes late: dropped.
      recognizer.emit(const SpeechResult('fix the bug send'));
      expect(log.last, 'send:fix the bug');
    });

    testWidgets('the word without a pause before it is just a word', (
      tester,
    ) async {
      await controller.start(sink(), options: options());
      recognizer
        ..emit(const SpeechReady())
        ..emit(const SpeechPartial('tell me when to'));
      await tester.pump(const Duration(milliseconds: 300));
      recognizer.emit(const SpeechPartial('tell me when to send'));
      await tester.pump(const Duration(seconds: 2));
      expect(controller.isActive, isTrue);

      recognizer.emit(const SpeechResult('tell me when to send'));
      expect(log.last, 'finish:tell me when to send');
    });

    testWidgets('words after the command keep the dictation going', (
      tester,
    ) async {
      await controller.start(sink(), options: options());
      recognizer
        ..emit(const SpeechReady())
        ..emit(const SpeechPartial('write it'));
      await tester.pump(const Duration(seconds: 1));
      recognizer.emit(const SpeechPartial('write it send'));
      await tester.pump(const Duration(milliseconds: 400));
      recognizer.emit(const SpeechPartial('write it send the file'));
      await tester.pump(const Duration(seconds: 2));
      expect(controller.isActive, isTrue);
      expect(log.where((entry) => entry.startsWith('send:')), isEmpty);
    });

    testWidgets('the final result settles a command already heard', (
      tester,
    ) async {
      await controller.start(sink(), options: options());
      recognizer
        ..emit(const SpeechReady())
        ..emit(const SpeechPartial('never mind'));
      await tester.pump(const Duration(seconds: 1));
      recognizer
        ..emit(const SpeechPartial('never mind cancel'))
        ..emit(const SpeechResult('Never mind. Cancel.'));
      expect(log.last, 'cancel:Never mind.');
      expect(controller.status, DictationStatus.idle);
    });

    testWidgets('continuous: a command as its own phrase sends', (
      tester,
    ) async {
      await controller.start(sink(), options: options(continuous: true));
      recognizer.say('fix the bug');
      recognizer
        ..emit(const SpeechReady())
        ..emit(const SpeechPartial('send it'));
      await tester.pump(const Duration(milliseconds: 1100));
      expect(log.last, 'send:fix the bug');
      expect(controller.status, DictationStatus.idle);
    });

    testWidgets('a sink without onCommand never gets commands', (tester) async {
      await controller.start(sink(commands: false), options: options());
      recognizer
        ..emit(const SpeechReady())
        ..emit(const SpeechPartial('fix the bug'));
      await tester.pump(const Duration(seconds: 1));
      recognizer.emit(const SpeechPartial('fix the bug send'));
      await tester.pump(const Duration(seconds: 2));
      recognizer.emit(const SpeechResult('fix the bug send'));
      expect(log.last, 'finish:fix the bug send');
    });
  });

  group('DictationController.discard (CON-097)', () {
    late FakeSpeechRecognizer recognizer;
    late DictationController controller;
    late List<String> log;

    DictationSink sink(Object target) => DictationSink(
      target: target,
      onBegin: () => log.add('begin'),
      onPartial: (text) => log.add('partial:$text'),
      onFinish: (text) => log.add('finish:$text'),
      onCancel: () => log.add('cancel'),
      onDiscard: () => log.add('discard'),
    );

    setUp(() {
      recognizer = FakeSpeechRecognizer();
      controller = DictationController(recognizer, language: () => '');
      log = [];
    });

    tearDown(() => controller.dispose());

    test('a late final result after a discard reaches no one', () async {
      final field = Object();
      await controller.start(sink(field));
      recognizer
        ..emit(const SpeechReady())
        ..emit(const SpeechPartial('hello'));
      await controller.stop();
      await controller.discard(target: field);
      recognizer.emit(const SpeechResult('hello world'));

      expect(log, ['begin', 'partial:hello', 'discard']);
      expect(controller.status, DictationStatus.idle);
      expect(recognizer.cancels, 1);
    });

    test('the old session\'s words never reach the next session', () async {
      final field = Object();
      await controller.start(sink(field));
      recognizer.emit(const SpeechPartial('hello'));
      await controller.discard(target: field);

      await controller.start(sink(field));
      recognizer.emit(const SpeechResult('hello world'));
      expect(controller.isActive, isTrue, reason: 'stale result dropped');
      recognizer.say('next');
      expect(log.last, 'finish:next');
    });

    test('only the target\'s own session is discarded', () async {
      await controller.start(sink(Object()));
      await controller.discard(target: Object());
      expect(controller.isActive, isTrue);
    });
  });
}
