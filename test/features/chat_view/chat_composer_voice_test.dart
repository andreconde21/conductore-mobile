import 'package:conduit/features/chat_view/presentation/widgets/chat_composer.dart';
import 'package:conduit/features/voice/presentation/dictation_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../voice/fake_speech_recognizer.dart';

/// André could not find the mic: it hid while the chat could not send,
/// and on phones without a recognizer. Since CON-107 the composer has at
/// most four controls: Stop (only while the agent works), the field, the
/// mic (tap dictates, long-press talks) and Send.
void main() {
  late FakeSpeechRecognizer recognizer;
  late DictationController dictation;
  late int talks;

  setUp(() {
    recognizer = FakeSpeechRecognizer();
    dictation = DictationController(recognizer, language: () => '');
    talks = 0;
  });

  tearDown(() => dictation.dispose());

  Future<void> pump(
    WidgetTester tester, {
    bool enabled = true,
    bool working = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatComposer(
            onSend: (_) async {},
            onInterrupt: () async {},
            enabled: enabled,
            disabledHint: 'No Claude session yet',
            dictation: dictation,
            onTalk: () => talks += 1,
            showInterrupt: working,
            onAttachImage: (_) {},
          ),
        ),
      ),
    );
    await dictation.checkAvailability();
    await tester.pump();
  }

  IconButton button(WidgetTester tester, String key) =>
      tester.widget<IconButton>(find.byKey(ValueKey(key)));

  /// The row's own buttons, not the attach icon inside the field.
  int rowButtons(WidgetTester tester) =>
      find.byType(IconButton).evaluate().length -
      find
          .descendant(
            of: find.byKey(const ValueKey('chat-composer-field')),
            matching: find.byType(IconButton),
          )
          .evaluate()
          .length;

  testWidgets('a disabled composer keeps the mic, disabled', (tester) async {
    await pump(tester, enabled: false);

    expect(find.byKey(const ValueKey('dictation-button')), findsOneWidget);
    expect(button(tester, 'dictation-button').onPressed, isNull);
    expect(button(tester, 'dictation-button').onLongPress, isNull);
    expect(find.byTooltip('No Claude session yet'), findsOneWidget);
  });

  testWidgets('the mic: tap dictates, long-press starts Talk', (tester) async {
    await pump(tester);

    expect(find.byKey(const ValueKey('chat-talk')), findsNothing);
    expect(find.byTooltip('Dictate. Long-press to talk'), findsOneWidget);
    await tester.longPress(find.byKey(const ValueKey('dictation-button')));
    expect(talks, 1);
    expect(recognizer.starts, isEmpty);
    await tester.tap(find.byKey(const ValueKey('dictation-button')));
    await tester.pump();
    expect(recognizer.starts, hasLength(1));
    expect(talks, 1);
  });

  testWidgets('without a recognizer the mic explains itself', (tester) async {
    recognizer.available = false;
    await pump(tester);

    expect(
      find.descendant(
        of: find.byKey(const ValueKey('dictation-button')),
        matching: find.byIcon(Icons.mic_off_rounded),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('dictation-button')));
    await tester.pumpAndSettle();
    expect(find.text('No speech recognizer'), findsOneWidget);
    expect(recognizer.starts, isEmpty);
    expect(talks, 0);
  });

  testWidgets('idle: no Stop, and only the mic and Send beside the field '
      '(no Talk, no expand)', (tester) async {
    await pump(tester);

    expect(find.byKey(const ValueKey('chat-interrupt')), findsNothing);
    expect(find.byTooltip('Interrupt (Esc)'), findsNothing);
    expect(find.byTooltip('Open composer'), findsNothing);
    expect(rowButtons(tester), 2);
    // The image button sits inside the field.
    expect(find.byKey(const ValueKey('chat-attach-image')), findsOneWidget);
  });

  testWidgets('working: Stop shows, four controls in all', (tester) async {
    await pump(tester, working: true);

    expect(find.byKey(const ValueKey('chat-interrupt')), findsOneWidget);
    expect(rowButtons(tester), 3);
  });

  testWidgets('the field grows with the message', (tester) async {
    await pump(tester);
    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('chat-composer-field')),
    );
    expect(field.minLines, 1);
    expect(field.maxLines, greaterThan(4));
  });
}
