import 'dart:async';

import 'package:conduit/features/continuity/domain/continuity_record.dart';
import 'package:conduit/features/continuity/domain/continuity_state.dart';
import 'package:conduit/features/continuity/presentation/continuity_controller.dart';
import 'package:conduit/features/desktop_shell/presentation/desktop_home.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../desktop_shell/shell_harness.dart';
import 'continuity_test_support.dart';

void main() {
  final now = DateTime(2026, 9, 28, 12);

  /// The phone was in tmux "build" on the workstation a minute ago.
  Map<String, Object?> phoneRecord() => deviceRecord(
    id: 'phone',
    name: 'Phone',
    desktop: false,
    activeAt: now.subtract(const Duration(minutes: 1)),
    context: ContinuityContext(
      place: const ContinuityPlace(
        machineId: 'workstation',
        machineName: 'workstation',
        target: ConnectTarget.tmux('build'),
      ),
      at: now.subtract(const Duration(minutes: 2)),
    ),
  );

  Future<(ShellHarness, ContinuityController)> pump(WidgetTester tester) async {
    late ContinuityController continuity;
    final h = await pumpShell(
      tester,
      size: const Size(1600, 1000),
      before: (h) {
        continuity = ContinuityController(
          store: InMemoryContinuityStore(
            ContinuityState(
              activeAt: now.subtract(const Duration(hours: 1)),
              remote: phoneRecord(),
            ),
          ),
          sync: FakeContinuityLink(deviceId: 'desk', deviceName: 'Omarchy'),
          machineFor: (id) => id == null ? null : h.hosts.findById(id),
          desktop: true,
          now: () => now,
          observeLifecycle: false,
        );
        h.continuity = continuity;
      },
    );
    await continuity.start();
    await settleShell(tester);
    return (h, continuity);
  }

  Future<void> finish(WidgetTester tester, ContinuityController c) async {
    await tearDownShell(tester);
    c.dispose();
  }

  testWidgets('the desktop shows the phone\'s place as a toast', (
    tester,
  ) async {
    final (_, continuity) = await pump(tester);

    expect(find.byKey(const ValueKey('continuity-toast')), findsOneWidget);
    expect(
      find.textContaining('Phone: build · Terminal', findRichText: true),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('continuity-dismiss')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('continuity-toast')), findsNothing);
    await finish(tester, continuity);
  });

  testWidgets('the palette continues from the phone into the same tmux '
      'session, and the desktop then reports where it is', (tester) async {
    final (h, continuity) = await pump(tester);

    unawaited(
      tester.state<DesktopHomeState>(find.byType(DesktopHome)).openPalette(),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('command-palette-search')),
      '>continue',
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('palette-command:continue-on')),
      findsOneWidget,
    );
    final entry = find.byKey(const ValueKey('palette-continuity:phone'));
    expect(
      find.descendant(
        of: entry,
        matching: find.textContaining(
          'Continue from Phone: build · Terminal',
          findRichText: true,
        ),
      ),
      findsOneWidget,
    );

    await tester.tap(entry);
    await settleShell(tester);

    expect(
      h.workspace.sessions.map((session) => session.host.id),
      contains('workstation#tmux:build'),
    );
    final here = continuity.context!.place;
    expect(here.machineId, 'workstation');
    expect(here.target, const ConnectTarget.tmux('build'));
    // Now at the phone's place: nothing left to offer.
    expect(continuity.offer, isNull);
    await finish(tester, continuity);
  });
}
