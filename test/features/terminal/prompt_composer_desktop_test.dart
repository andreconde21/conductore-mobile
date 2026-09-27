import 'package:conduit/features/terminal/presentation/widgets/prompt_composer_sheet.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The composer on desktop: Ctrl/Cmd+Enter sends, and the Paste, Select
/// all and Clear buttons (the keyboard's job there) are gone. Phones keep
/// the buttons and Enter-only-newline.
void main() {
  const desktops = TargetPlatformVariant({
    TargetPlatform.linux,
    TargetPlatform.windows,
    TargetPlatform.macOS,
  });

  late List<String> sent;

  Future<void> open(WidgetTester tester) async {
    sent = [];
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showPromptComposerSheet(
                context: context,
                initialText: 'fix the tests',
                onDraftChanged: (_) {},
                onSend: (text, {required submit}) async => sent.add(text),
                submitEnter: true,
                onSubmitEnterChanged: (_) {},
                isConnected: () => true,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('desktop: Ctrl/Cmd+Enter sends, no duplicate edit buttons', (
    tester,
  ) async {
    await open(tester);
    expect(find.byTooltip('Paste clipboard'), findsNothing);
    expect(find.byTooltip('Select all'), findsNothing);
    expect(find.byTooltip('Clear draft'), findsNothing);
    final mac = defaultTargetPlatform == TargetPlatform.macOS;
    expect(find.byTooltip(mac ? 'Cmd+Enter' : 'Ctrl+Enter'), findsOneWidget);

    await tester.tap(find.byType(TextField));
    await tester.pump();
    final modifier = mac
        ? LogicalKeyboardKey.metaLeft
        : LogicalKeyboardKey.controlLeft;
    await tester.sendKeyDownEvent(modifier);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(modifier);
    await tester.pumpAndSettle();
    expect(sent, ['fix the tests']);
    expect(find.byType(PromptComposerSheet), findsNothing);
  }, variant: desktops);

  testWidgets('phone: the edit buttons stay, Ctrl+Enter does not send', (
    tester,
  ) async {
    await open(tester);
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.byTooltip('Paste clipboard'), findsOneWidget);
    expect(find.byTooltip('Select all'), findsOneWidget);
    expect(find.byTooltip('Clear draft'), findsOneWidget);
    expect(find.byTooltip('Ctrl+Enter'), findsNothing);

    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(sent, isEmpty);
  });
}
