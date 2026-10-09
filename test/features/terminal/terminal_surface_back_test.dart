import 'dart:async';

import 'package:conduit/core/presentation/edge_swipe_back.dart';
import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:conduit/features/terminal/presentation/widgets/terminal_surface.dart';
import 'package:conduit_vt/conduit_vt.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

/// Back on a phone's terminal page while text is selected (CON-093): the
/// selection's handles can sit in the left strip where a swipe goes back,
/// so a selection holds the page and back clears it first.
void main() {
  late TerminalSessionController session;
  late FocusNode focusNode;

  Future<void> pumpPushedSurface(WidgetTester tester) async {
    session = TerminalSessionController(
      host: buildHost('back'),
      repository: ImmediateTerminalRepository(TrackableTerminalSession()),
    );
    addTearDown(session.dispose);
    focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        theme: ThemeData(pageTransitionsTheme: appPageTransitionsTheme),
        home: const Scaffold(body: Text('home')),
        onGenerateRoute: (_) => MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            body: TerminalSurface(
              session: session,
              palette: AppPalette.catppuccin,
              brightness: Brightness.dark,
              fontFamily: 'monospace',
              fontSize: 14,
              predictiveEchoEnabled: false,
              terminalMouseInput: false,
              focusNode: focusNode,
              tmuxScrollMode: false,
              onExitTmuxScrollMode: () {},
              onPathTap: (_) {},
              onLinkTap: (_) {},
            ),
          ),
        ),
      ),
    );
    unawaited(navigatorKey.currentState!.pushNamed<void>('terminal'));
    await tester.pumpAndSettle();
    session.terminal.write('selected words here\r\n');
    await tester.pump();
  }

  TerminalController controllerOf(WidgetTester tester) =>
      tester.widget<TerminalView>(find.byType(TerminalView)).controller!;

  Offset firstCell(WidgetTester tester) {
    final state = tester.state<TerminalViewState>(find.byType(TerminalView));
    final render = state.renderTerminal;
    final cell = render.cellSize;
    return render.localToGlobal(
      render.getOffset(const CellOffset(0, 0)) +
          Offset(cell.width / 2, cell.height / 2),
    );
  }

  Future<void> select(WidgetTester tester) async {
    await tester.longPressAt(firstCell(tester));
    await tester.pumpAndSettle();
    expect(controllerOf(tester).selection, isNotNull);
  }

  testWidgets('back clears a selection first, then leaves the page', (
    tester,
  ) async {
    await pumpPushedSurface(tester);
    await select(tester);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(TerminalSurface), findsOneWidget);
    expect(controllerOf(tester).selection, isNull);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(TerminalSurface), findsNothing);
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('an edge swipe does not leave while text is selected', (
    tester,
  ) async {
    await pumpPushedSurface(tester);
    await select(tester);

    await tester.dragFrom(const Offset(4, 300), const Offset(300, 0));
    await tester.pumpAndSettle();
    expect(find.byType(TerminalSurface), findsOneWidget);

    controllerOf(tester).clearSelection();
    await tester.pump();
    await tester.dragFrom(const Offset(4, 300), const Offset(300, 0));
    await tester.pumpAndSettle();
    expect(find.byType(TerminalSurface), findsNothing);
  });
}
