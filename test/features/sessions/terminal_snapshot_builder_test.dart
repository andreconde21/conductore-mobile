import 'package:conduit/features/sessions/presentation/live_terminal_preview.dart';
import 'package:conduit_vt/conduit_vt.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('captures again on a tick only after the terminal printed', (
    tester,
  ) async {
    final terminal = Terminal();
    final ticks = ValueNotifier<int>(0);
    addTearDown(ticks.dispose);
    var builds = 0;
    await tester.pumpWidget(
      PreviewClock(
        ticks: ticks,
        child: TerminalSnapshotBuilder(
          terminal: terminal,
          builder: (context) {
            builds += 1;
            return const SizedBox();
          },
        ),
      ),
    );
    expect(builds, 1);
    // Quiet terminal: ticks cost nothing.
    for (var i = 0; i < 5; i++) {
      ticks.value += 1;
      await tester.pump();
    }
    expect(builds, 1);
    // Output alone waits for the tick.
    terminal.write('hello\r\n');
    await tester.pump();
    expect(builds, 1);
    ticks.value += 1;
    await tester.pump();
    expect(builds, 2);
    ticks.value += 1;
    await tester.pump();
    expect(builds, 2);
  });

  testWidgets('without a clock it builds with its parent', (tester) async {
    final terminal = Terminal();
    var builds = 0;
    Widget child() => TerminalSnapshotBuilder(
      terminal: terminal,
      builder: (context) {
        builds += 1;
        return const SizedBox();
      },
    );
    await tester.pumpWidget(child());
    await tester.pumpWidget(child());
    expect(builds, 2);
  });
}
