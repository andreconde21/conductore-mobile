import 'package:conduit/features/voice/domain/speech_event.dart';
import 'package:conduit/features/voice/presentation/dictation_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_speech_recognizer.dart';

void main() {
  testWidgets(
    'a single phrase whose result never comes still ends after stop',
    (tester) async {
      final mic = FakeSpeechRecognizer();
      final dictation = DictationController(mic, language: () => 'en-US');
      addTearDown(dictation.dispose);
      String? finished;
      await dictation.start(
        DictationSink(
          onBegin: () {},
          onPartial: (_) {},
          onFinish: (text) => finished = text,
          onCancel: () {},
        ),
      );
      mic
        ..emit(const SpeechReady())
        ..emit(const SpeechPartial('open api'));
      await dictation.stop();
      expect(dictation.status, DictationStatus.finishing);
      await tester.pump(const Duration(seconds: 4));
      expect(dictation.status, DictationStatus.idle);
      expect(finished, 'open api');
    },
  );
}
