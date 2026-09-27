import 'package:conduit/features/snippets/domain/terminal_snippet.dart';
import 'package:conduit/features/snippets/presentation/snippet_editor.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const desktops = TargetPlatformVariant({
    TargetPlatform.linux,
    TargetPlatform.windows,
    TargetPlatform.macOS,
  });

  late TerminalSnippet? result;
  late bool closed;

  Future<void> open(WidgetTester tester) async {
    result = null;
    closed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showSnippetDialog(context: context);
              closed = true;
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Finder field(String label) => find.widgetWithText(TextField, label);

  testWidgets('desktop: Enter in the name saves once there is a command', (
    tester,
  ) async {
    await open(tester);
    await tester.enterText(field('Command or text'), 'ls -la');
    await tester.enterText(field('Name'), 'List');
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pumpAndSettle();
    expect(closed, isTrue);
    expect(result?.label, 'List');
    expect(result?.text, 'ls -la');
  }, variant: desktops);

  testWidgets('desktop: Ctrl/Cmd+Enter saves from the command', (tester) async {
    await open(tester);
    await tester.enterText(field('Name'), 'List');
    await tester.enterText(field('Command or text'), 'ls');
    final modifier = defaultTargetPlatform == TargetPlatform.macOS
        ? LogicalKeyboardKey.metaLeft
        : LogicalKeyboardKey.controlLeft;
    await tester.sendKeyDownEvent(modifier);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(modifier);
    await tester.pumpAndSettle();
    expect(result?.text, 'ls');
  }, variant: desktops);

  testWidgets('phone: Enter in the name only moves on', (tester) async {
    await open(tester);
    await tester.enterText(field('Command or text'), 'ls -la');
    await tester.enterText(field('Name'), 'List');
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pumpAndSettle();
    expect(closed, isFalse);
    expect(find.text('Add snippet'), findsOneWidget);
  });
}
