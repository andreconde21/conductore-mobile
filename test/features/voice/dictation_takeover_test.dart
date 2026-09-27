import 'package:conduit/features/voice/domain/speech_event.dart';
import 'package:conduit/features/voice/presentation/dictation_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_speech_recognizer.dart';

DictationSink _sink({
  void Function(String)? onFinish,
  void Function(String)? onTakenOver,
}) => DictationSink(
  onBegin: () {},
  onPartial: (_) {},
  onFinish: onFinish ?? (_) {},
  onCancel: () {},
  onTakenOver: onTakenOver,
);

void main() {
  test('a text field taken over keeps what it heard through onFinish; a '
      'sink that asks is told it was taken over instead', () async {
    final mic = FakeSpeechRecognizer();
    final field = DictationController(mic, language: () => 'en-US');
    final talk = DictationController(mic, language: () => 'en-US');
    final other = DictationController(mic, language: () => 'en-US');
    addTearDown(field.dispose);
    addTearDown(talk.dispose);
    addTearDown(other.dispose);

    final finished = <String>[];
    await field.start(_sink(onFinish: finished.add));
    mic.emit(const SpeechPartial('hello'));
    await other.start(_sink());
    expect(finished, ['hello']);

    final talkFinished = <String>[];
    final takenOver = <String>[];
    await talk.start(
      _sink(onFinish: talkFinished.add, onTakenOver: takenOver.add),
    );
    mic.emit(const SpeechPartial('delete the'));
    await other.start(_sink());
    expect(takenOver, ['delete the']);
    expect(talkFinished, isEmpty);
  });

  test('a start that was overtaken while the other session closed does not '
      'listen as well', () async {
    final mic = FakeSpeechRecognizer();
    final first = DictationController(mic, language: () => 'en-US');
    final second = DictationController(mic, language: () => 'en-US');
    addTearDown(first.dispose);
    addTearDown(second.dispose);

    late DictationSink relisten;
    // Like a loop that listens again as soon as it is cut off.
    relisten = _sink(onFinish: (_) => first.start(relisten));
    await first.start(relisten);
    expect(first.isActive, isTrue);

    await second.start(_sink());
    await pumpEventQueue();
    expect(
      first.isActive && second.isActive,
      isFalse,
      reason: 'only one controller may listen at a time',
    );
    expect(first.isActive, isTrue, reason: 'the last to start keeps it');
  });
}
