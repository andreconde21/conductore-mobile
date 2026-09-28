import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/core/theme/app_theme.dart';
import 'package:conduit/features/hosts/domain/multiplexer_prefix_key.dart';
import 'package:conduit/features/snippets/domain/terminal_snippet.dart';
import 'package:conduit/features/terminal/presentation/widgets/herdr_navigator_sheet.dart';
import 'package:conduit/features/terminal/presentation/widgets/recent_directories_sheet.dart';
import 'package:conduit/features/terminal/presentation/widgets/tmux_navigator_sheet.dart';
import 'package:conduit/features/terminal/presentation/widgets/toolbar_snippet_palette.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The terminal's sheets on desktop: the navigators and "cd to…" fill
/// their panel instead of a draggable 60-72% sheet, and the snippet
/// palette filters and picks from the keyboard. Phones keep the sheets.
void main() {
  const palette = AppPalette.catppuccin;
  const brightness = Brightness.dark;
  const desktops = TargetPlatformVariant({
    TargetPlatform.linux,
    TargetPlatform.windows,
    TargetPlatform.macOS,
  });

  Future<void> open(
    WidgetTester tester,
    Future<void> Function(BuildContext context) show,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(brightness: brightness, palette: palette),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => show(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  final sheets = <String, Future<void> Function(BuildContext)>{
    'tmux navigator': (context) => showTmuxNavigatorSheet(
      context: context,
      palette: palette,
      brightness: brightness,
      hostPrefix: MultiplexerPrefixKey.controlB,
      sessionName: 'main',
    ),
    'Herdr navigator': (context) => showHerdrNavigatorSheet(
      context: context,
      palette: palette,
      brightness: brightness,
      hostPrefix: MultiplexerPrefixKey.controlB,
    ),
    'recent directories': (context) => showRecentDirectoriesSheet(
      context: context,
      hostName: 'devbox',
      directories: const ['/srv/app', '/tmp'],
      actions: const [RecentDirectoryAction.cd],
    ),
  };

  DraggableScrollableSheet sheet(WidgetTester tester) => tester
      .widget<DraggableScrollableSheet>(find.byType(DraggableScrollableSheet));

  for (final MapEntry(key: name, value: show) in sheets.entries) {
    testWidgets('desktop: the $name fills its panel', (tester) async {
      await open(tester, show);
      expect(find.byType(BottomSheet), findsNothing);
      expect(sheet(tester).initialChildSize, 1.0);
      expect(sheet(tester).minChildSize, 1.0);
      expect(sheet(tester).maxChildSize, 1.0);
    }, variant: desktops);

    testWidgets('phone: the $name stays a draggable bottom sheet', (
      tester,
    ) async {
      await open(tester, show);
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(sheet(tester).initialChildSize, lessThan(1.0));
      expect(sheet(tester).maxChildSize, lessThan(1.0));
    });
  }

  group('snippet palette', () {
    late List<String> picked;

    Future<void> openPalette(WidgetTester tester) async {
      picked = [];
      await open(
        tester,
        (context) => showToolbarSnippetPalette(
          context: context,
          palette: palette,
          brightness: brightness,
          hostSnippets: const [
            TerminalSnippet(id: 'h', label: 'Deploy', text: 'make deploy'),
          ],
          globalSnippets: const [
            TerminalSnippet(id: 'g', label: 'Git status', text: 'git status'),
          ],
          onQuickPrompt: (prompt) => picked.add(prompt.label),
          onSnippet: (snippet) => picked.add(snippet.label),
        ),
      );
    }

    final filter = find.byKey(const ValueKey('snippet-palette-filter'));

    testWidgets('desktop: filters and picks with the arrows and Enter', (
      tester,
    ) async {
      await openPalette(tester);
      expect(filter, findsOneWidget);
      expect(
        tester.widget<TextField>(filter).focusNode?.hasFocus ?? true,
        isTrue,
      );
      await tester.enterText(filter, 'git');
      await tester.pump();
      expect(find.text('Deploy'), findsNothing);
      expect(find.text('Git status'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(picked, ['Git status']);
      expect(filter, findsNothing);
    }, variant: desktops);

    testWidgets('desktop: Down then Enter runs the second row', (tester) async {
      await openPalette(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(picked, [ToolbarQuickPrompt.values[1].label]);
    }, variant: desktops);

    testWidgets('phone: chips and rows, no filter', (tester) async {
      await openPalette(tester);
      expect(filter, findsNothing);
      expect(find.byType(ActionChip), findsWidgets);
      await tester.tap(find.text('Deploy'));
      await tester.pumpAndSettle();
      expect(picked, ['Deploy']);
    });
  });
}
