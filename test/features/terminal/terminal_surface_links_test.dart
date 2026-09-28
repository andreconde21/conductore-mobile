import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:conduit/features/terminal/presentation/widgets/terminal_surface.dart';
import 'package:conduit_vt/conduit_vt.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

void main() {
  late TerminalSessionController session;
  late List<String> links;
  late List<String> paths;
  late List<(String, String)> longPresses;
  late bool longPressResult;
  late List<String> opened;

  Future<void> pumpSurface(
    WidgetTester tester, {
    bool withLinkOpen = false,
  }) async {
    opened = [];
    session = TerminalSessionController(
      host: buildHost('links'),
      repository: ImmediateTerminalRepository(TrackableTerminalSession()),
    );
    addTearDown(session.dispose);
    links = [];
    paths = [];
    longPresses = [];
    longPressResult = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 700,
            height: 400,
            child: TerminalSurface(
              session: session,
              palette: AppPalette.catppuccin,
              brightness: Brightness.dark,
              fontFamily: 'monospace',
              fontSize: 14,
              predictiveEchoEnabled: false,
              terminalMouseInput: false,
              focusNode: null,
              tmuxScrollMode: false,
              onExitTmuxScrollMode: () {},
              onPathTap: paths.add,
              onLinkTap: links.add,
              onLinkLongPress: (url, line) async {
                longPresses.add((url, line));
                return longPressResult;
              },
              onLinkOpen: withLinkOpen ? opened.add : null,
            ),
          ),
        ),
      ),
    );
    session.terminal.write(
      'docs at https://example.com/guide now\r\n'
      'error in /etc/nginx/nginx.conf\r\n'
      r'$ ',
    );
    await tester.pump();
  }

  Offset cellCenter(WidgetTester tester, int column, int row) {
    final state = tester.state<TerminalViewState>(find.byType(TerminalView));
    final render = state.renderTerminal;
    final cell = render.cellSize;
    final origin = render.getOffset(CellOffset(column, row));
    return render.localToGlobal(
      origin + Offset(cell.width / 2, cell.height / 2),
    );
  }

  TerminalController controllerOf(WidgetTester tester) =>
      tester.widget<TerminalView>(find.byType(TerminalView)).controller!;

  testWidgets('a tap on a link reports the link, a tap on a path the path', (
    tester,
  ) async {
    await pumpSurface(tester);

    await tester.tapAt(cellCenter(tester, 12, 0));
    await tester.pump(const Duration(milliseconds: 400));
    expect(links, ['https://example.com/guide']);
    expect(paths, isEmpty);

    await tester.tapAt(cellCenter(tester, 12, 1));
    await tester.pump(const Duration(milliseconds: 400));
    expect(paths, ['/etc/nginx/nginx.conf']);
    expect(links, hasLength(1));

    // Plain words do nothing.
    await tester.tapAt(cellCenter(tester, 1, 0));
    await tester.pump(const Duration(milliseconds: 400));
    expect(links, hasLength(1));
    expect(paths, hasLength(1));
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('a long press on a link opens the menu callback and keeps the '
      'word selection unless an action was taken', (tester) async {
    await pumpSurface(tester);

    await tester.longPressAt(cellCenter(tester, 18, 0));
    await tester.pump();
    expect(longPresses, [
      ('https://example.com/guide', 'docs at https://example.com/guide now'),
    ]);
    expect(controllerOf(tester).selection, isNotNull);
    expect(links, isEmpty);

    // A tap clears the selection (and its toolbar) first.
    await tester.tapAt(cellCenter(tester, 1, 1));
    await tester.pump(const Duration(milliseconds: 400));
    expect(controllerOf(tester).selection, isNull);

    longPressResult = true;
    await tester.longPressAt(cellCenter(tester, 18, 0));
    await tester.pump();
    expect(longPresses, hasLength(2));
    expect(controllerOf(tester).selection, isNull);
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('a long press elsewhere only selects', (tester) async {
    await pumpSurface(tester);

    await tester.longPressAt(cellCenter(tester, 1, 0));
    await tester.pump();
    expect(longPresses, isEmpty);
    expect(controllerOf(tester).selection, isNotNull);
    await tester.pump(const Duration(milliseconds: 300));
  });

  const desktops = TargetPlatformVariant({
    TargetPlatform.linux,
    TargetPlatform.windows,
    TargetPlatform.macOS,
  });

  Future<void> rightClick(WidgetTester tester, Offset at) async {
    await tester.tapAt(
      at,
      buttons: kSecondaryButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
  }

  final menu = find.byKey(const ValueKey('terminal-context-menu'));

  testWidgets('desktop: right-click offers Copy, Paste and Select all', (
    tester,
  ) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await pumpSurface(tester);
    await rightClick(tester, cellCenter(tester, 1, 1));
    expect(menu, findsOneWidget);
    // Nothing selected yet: Copy is off.
    expect(
      tester
          .widget<ListTile>(find.byKey(const ValueKey('terminal-menu-copy')))
          .enabled,
      isFalse,
    );
    await tester.tap(find.byKey(const ValueKey('terminal-menu-select-all')));
    await tester.pumpAndSettle();
    expect(controllerOf(tester).selection, isNotNull);

    await rightClick(tester, cellCenter(tester, 20, 4));
    await tester.tap(find.byKey(const ValueKey('terminal-menu-copy')));
    await tester.pumpAndSettle();
    expect(copied, contains('docs at https://example.com/guide now'));
    expect(controllerOf(tester).selection, isNull);
  }, variant: desktops);

  testWidgets('desktop: no menu while the program reports the mouse', (
    tester,
  ) async {
    await pumpSurface(tester);
    session.terminal.write('\x1b[?1000h');
    await tester.pump();
    await rightClick(tester, cellCenter(tester, 1, 1));
    expect(menu, findsNothing);
  }, variant: desktops);

  testWidgets('phone: right-click opens no menu', (tester) async {
    await pumpSurface(tester);
    await rightClick(tester, cellCenter(tester, 1, 1));
    expect(menu, findsNothing);
  });

  MouseCursor cursorOf(WidgetTester tester) =>
      tester.widget<TerminalView>(find.byType(TerminalView)).mouseCursor;

  testWidgets(
    'desktop: a hand cursor over links; Ctrl/Cmd+click opens, a plain '
    'click does not',
    (tester) async {
      await pumpSurface(tester, withLinkOpen: true);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: cellCenter(tester, 1, 1));
      await tester.pump();
      expect(cursorOf(tester), SystemMouseCursors.text);
      await mouse.moveTo(cellCenter(tester, 12, 0));
      await tester.pump();
      expect(cursorOf(tester), SystemMouseCursors.click);
      await mouse.removePointer();

      await tester.tapAt(cellCenter(tester, 12, 0));
      await tester.pump(const Duration(milliseconds: 400));
      expect(opened, isEmpty);
      expect(links, isEmpty);

      final modifier = defaultTargetPlatform == TargetPlatform.macOS
          ? LogicalKeyboardKey.metaLeft
          : LogicalKeyboardKey.controlLeft;
      await tester.sendKeyDownEvent(modifier);
      await tester.tapAt(cellCenter(tester, 12, 0));
      await tester.sendKeyUpEvent(modifier);
      await tester.pump(const Duration(milliseconds: 400));
      expect(opened, ['https://example.com/guide']);
      expect(links, isEmpty);
    },
    variant: desktops,
  );

  testWidgets('phone: a tap on a link still reports it with onLinkOpen set', (
    tester,
  ) async {
    await pumpSurface(tester, withLinkOpen: true);
    await tester.tapAt(cellCenter(tester, 12, 0));
    await tester.pump(const Duration(milliseconds: 400));
    expect(links, ['https://example.com/guide']);
    expect(opened, isEmpty);
    expect(cursorOf(tester), SystemMouseCursors.text);
  });
}
