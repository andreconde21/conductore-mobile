import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/features/terminal/presentation/widgets/toolbar_snippet_palette.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // One mic (CON-106): dictation starts from the chat line's mic, not
  // from the quick prompt palette.
  testWidgets('the palette has quick prompts and no mic', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ToolbarSnippetPalette(
            palette: AppPalette.catppuccin,
            brightness: Brightness.dark,
            hostSnippets: const [],
            globalSnippets: const [],
            onQuickPrompt: (_) {},
            onSnippet: (_) {},
          ),
        ),
      ),
    );

    expect(find.text('/clear'), findsOneWidget);
    expect(find.byKey(const ValueKey('palette-dictate')), findsNothing);
    expect(find.byIcon(Icons.mic_none_rounded), findsNothing);
  });
}
