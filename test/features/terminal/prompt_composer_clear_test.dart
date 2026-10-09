import 'package:conduit/features/terminal/presentation/widgets/prompt_composer_sheet.dart';
import 'package:conduit/features/voice/domain/speech_event.dart';
import 'package:conduit/features/voice/domain/voice_commands.dart';
import 'package:conduit/features/voice/presentation/dictation_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../voice/fake_speech_recognizer.dart';

/// The expanded composer (Chat View and the terminal's chat mode): a late
/// dictation result never refills a sent draft (CON-097), "… send" sends
/// (CON-098), and Clear empties it with Undo (CON-099).
void main() {
  late FakeSpeechRecognizer recognizer;
  late DictationController dictation;
  late List<String> sent;
  late String draft;

  setUp(() {
    recognizer = FakeSpeechRecognizer();
    dictation = DictationController(
      recognizer,
      language: () => '',
      options: () => DictationOptions(commands: VoiceCommandWords.defaults),
    );
    sent = [];
    draft = '';
  });

  tearDown(() => dictation.dispose());

  Future<void> open(WidgetTester tester, {String initialText = ''}) async {
    tester.view
      ..physicalSize = const Size(360 * 3, 720 * 3)
      ..devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    draft = initialText;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showPromptComposerSheet(
                context: context,
                initialText: initialText,
                onDraftChanged: (value) => draft = value,
                onSend: (text, {required submit}) async => sent.add(text),
                submitEnter: true,
                onSubmitEnterChanged: (_) {},
                isConnected: () => true,
                dictation: dictation,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await dictation.checkAvailability();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  String field(WidgetTester tester) => tester
      .widget<TextField>(
        find.descendant(
          of: find.byType(PromptComposerSheet),
          matching: find.byType(TextField),
        ),
      )
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

  final clear = find.byKey(const ValueKey('composer-clear'));

  testWidgets('a late result after Send does not bring the draft back', (
    tester,
  ) async {
    await open(tester);
    await dictate(tester, 'run the tests');
    expect(draft, 'run the tests');

    await tester.tap(find.text('Insert & Send'));
    await tester.pumpAndSettle();
    expect(sent, ['run the tests']);
    expect(find.byType(PromptComposerSheet), findsNothing);
    expect(draft, isEmpty);

    recognizer.emit(const SpeechResult('run the tests now'));
    await tester.pump(const Duration(seconds: 4));
    expect(draft, isEmpty);
    expect(dictation.isActive, isFalse);
  });

  testWidgets('"… send it" after a pause sends without the words', (
    tester,
  ) async {
    await open(tester);
    await dictate(tester, 'deploy to dev');
    await tester.pump(const Duration(seconds: 1));
    recognizer.emit(const SpeechPartial('deploy to dev send it'));
    await tester.pump(const Duration(milliseconds: 1100));
    await tester.pumpAndSettle();

    expect(sent, ['deploy to dev']);
    expect(draft, isEmpty);
  });

  testWidgets('Clear shows only with text, fits 360 dp, stops dictation, '
      'and Undo brings the draft back', (tester) async {
    await open(tester);
    expect(clear, findsNothing);

    await tester.enterText(find.byType(TextField), 'first line\n');
    await tester.pump();
    expect(clear, findsOneWidget);
    await dictate(tester, 'second line');
    expect(field(tester), 'first line\nsecond line');
    expect(tester.takeException(), isNull);

    await tester.tap(clear);
    await tester.pump();
    expect(field(tester), isEmpty);
    expect(draft, isEmpty);
    expect(dictation.isActive, isFalse);
    expect(clear, findsNothing);
    recognizer.emit(const SpeechResult('second line again'));
    await tester.pump();
    expect(field(tester), isEmpty);

    await tester.tap(find.byKey(const ValueKey('composer-undo-clear')));
    await tester.pump();
    expect(field(tester), 'first line\nsecond line');
    expect(draft, 'first line\nsecond line');
    expect(find.text('Draft cleared'), findsNothing);
  });

  testWidgets('the Undo offer goes after about five seconds', (tester) async {
    await open(tester, initialText: 'fix the tests');
    await tester.tap(clear);
    await tester.pump();
    expect(find.text('Draft cleared'), findsOneWidget);

    await tester.pump(const Duration(seconds: 5));
    expect(find.text('Draft cleared'), findsNothing);
    expect(field(tester), isEmpty);
  });

  testWidgets('typing again retires the Undo offer', (tester) async {
    await open(tester, initialText: 'old');
    await tester.tap(clear);
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'new');
    await tester.pump();
    expect(find.byKey(const ValueKey('composer-undo-clear')), findsNothing);
    expect(field(tester), 'new');
  });
}
