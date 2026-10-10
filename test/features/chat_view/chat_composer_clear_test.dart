import 'package:conduit/features/chat_view/presentation/widgets/chat_composer.dart';
import 'package:conduit/features/voice/domain/speech_event.dart';
import 'package:conduit/features/voice/domain/voice_commands.dart';
import 'package:conduit/features/voice/presentation/dictation_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../voice/fake_speech_recognizer.dart';

/// Chat View's composer: dictated text never comes back after a send
/// (CON-097), "… send" sends (CON-098), and the × clears with Undo
/// (CON-099).
void main() {
  late FakeSpeechRecognizer recognizer;
  late DictationController dictation;
  late List<String> sent;

  setUp(() {
    recognizer = FakeSpeechRecognizer();
    dictation = DictationController(
      recognizer,
      language: () => '',
      options: () => DictationOptions(commands: VoiceCommandWords.defaults),
    );
    sent = [];
  });

  tearDown(() => dictation.dispose());

  Future<void> pump(WidgetTester tester) async {
    tester.view
      ..physicalSize = const Size(360 * 3, 720 * 3)
      ..devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: ChatComposer(
              onSend: (text) async => sent.add(text),
              onInterrupt: () async {},
              dictation: dictation,
              onTalk: () {},
            ),
          ),
        ),
      ),
    );
    await dictation.checkAvailability();
    await tester.pump();
  }

  String field(WidgetTester tester) => tester
      .widget<TextField>(find.byKey(const ValueKey('chat-composer-field')))
      .controller!
      .text;

  Future<void> dictate(WidgetTester tester, String words) async {
    await tester.tap(find.byKey(const ValueKey('dictation-button')));
    await tester.pump();
    recognizer
      ..emit(const SpeechReady())
      ..emit(SpeechPartial(words));
    await tester.pump();
  }

  testWidgets('a late result after Send does not refill the field', (
    tester,
  ) async {
    await pump(tester);
    await dictate(tester, 'hello there');
    expect(field(tester), 'hello there');

    await tester.tap(find.byTooltip('Send'));
    await tester.pump();
    expect(sent, ['hello there']);
    expect(field(tester), isEmpty);
    expect(dictation.isActive, isFalse);
    expect(recognizer.cancels, 1);

    recognizer
      ..emit(const SpeechPartial('hello there friend'))
      ..emit(const SpeechResult('hello there friend'));
    await tester.pump();
    expect(field(tester), isEmpty);
  });

  testWidgets('a late result after Send while finishing stays out', (
    tester,
  ) async {
    await pump(tester);
    await dictate(tester, 'run the tests');
    // André stops dictating, then sends before the final result arrives.
    await tester.tap(find.byKey(const ValueKey('dictation-button')));
    await tester.pump();
    expect(dictation.status, DictationStatus.finishing);

    await tester.tap(find.byTooltip('Send'));
    await tester.pump();
    recognizer.emit(const SpeechResult('run the tests'));
    await tester.pump(const Duration(seconds: 4));
    expect(sent, ['run the tests']);
    expect(field(tester), isEmpty);
  });

  testWidgets('"… send" after a pause sends without the word', (tester) async {
    await pump(tester);
    await dictate(tester, 'fix the bug');
    await tester.pump(const Duration(seconds: 1));
    recognizer.emit(const SpeechPartial('fix the bug send'));
    await tester.pump(const Duration(milliseconds: 1100));

    expect(sent, ['fix the bug']);
    expect(field(tester), isEmpty);
    recognizer.emit(const SpeechResult('fix the bug send'));
    await tester.pump();
    expect(field(tester), isEmpty);
  });

  testWidgets('"cancel" discards the message, with Undo', (tester) async {
    await pump(tester);
    await dictate(tester, 'never mind');
    await tester.pump(const Duration(seconds: 1));
    recognizer.emit(const SpeechPartial('never mind cancel'));
    await tester.pump(const Duration(milliseconds: 1100));

    expect(sent, isEmpty);
    expect(field(tester), isEmpty);
    expect(find.text('Message cleared'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Undo'));
    await tester.pump();
    expect(field(tester), 'never mind');
  });

  testWidgets('the × shows for a multi-line message, clears it, and Undo '
      'brings it back', (tester) async {
    await pump(tester);
    final clear = find.byKey(const ValueKey('chat-composer-clear'));
    await tester.enterText(
      find.byKey(const ValueKey('chat-composer-field')),
      'short',
    );
    await tester.pump();
    expect(clear, findsNothing);

    await tester.enterText(
      find.byKey(const ValueKey('chat-composer-field')),
      'first line\nsecond line',
    );
    await tester.pump();
    expect(clear, findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(clear);
    await tester.pump();
    expect(field(tester), isEmpty);
    expect(clear, findsNothing);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Undo'));
    await tester.pump();
    expect(field(tester), 'first line\nsecond line');
  });

  testWidgets('the × stops a dictation into the field', (tester) async {
    await pump(tester);
    await tester.enterText(
      find.byKey(const ValueKey('chat-composer-field')),
      'first line\n',
    );
    await dictate(tester, 'and more');
    expect(field(tester), 'first line\nand more');

    await tester.tap(find.byKey(const ValueKey('chat-composer-clear')));
    await tester.pump();
    expect(dictation.isActive, isFalse);
    recognizer.emit(const SpeechResult('and more words'));
    await tester.pump();
    expect(field(tester), isEmpty);
  });
}
