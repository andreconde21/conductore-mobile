import 'dart:async';

import 'package:conduit/core/presentation/terminal_route.dart';
import 'package:conduit/features/continuity/domain/continuity_preferences.dart';
import 'package:conduit/features/continuity/domain/continuity_record.dart';
import 'package:conduit/features/continuity/domain/continuity_state.dart';
import 'package:conduit/features/continuity/presentation/continuity_controller.dart';
import 'package:conduit/features/continuity/presentation/continuity_places.dart';
import 'package:conduit/features/continuity/presentation/continuity_widgets.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:conduit/features/terminal/presentation/terminal_page.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';
import '../desktop_shell/shell_harness.dart';
import 'continuity_test_support.dart';

void main() {
  final now = DateTime(2026, 9, 28, 12);

  /// Omarchy was in tmux "build" on the workstation a minute ago.
  Map<String, Object?> desktopRecord() => deviceRecord(
    id: 'desk',
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

  Future<(ShellHarness, ContinuityController)> pumpPhone(
    WidgetTester tester,
  ) async {
    late ContinuityController continuity;
    final h = await pumpShell(
      tester,
      size: const Size(420, 900),
      shellMode: false,
      before: (h) {
        continuity = ContinuityController(
          store: InMemoryContinuityStore(
            ContinuityState(
              activeAt: now.subtract(const Duration(hours: 1)),
              remote: desktopRecord(),
            ),
          ),
          sync: FakeContinuityLink(),
          machineFor: (id) => id == null ? null : h.hosts.findById(id),
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

  final banner = find.byKey(const ValueKey('continuity-banner'));

  testWidgets('home offers the desktop\'s place; tapping opens the same '
      'tmux session in the terminal', (tester) async {
    final (h, continuity) = await pumpPhone(tester);

    expect(banner, findsOneWidget);
    expect(
      find.textContaining(
        'Continue from Omarchy: build · Terminal',
        findRichText: true,
      ),
      findsOneWidget,
    );

    await tester.tap(banner);
    await settleShell(tester);

    expect(
      h.workspace.sessions.map((session) => session.host.id),
      contains('workstation#tmux:build'),
    );
    expect(find.byType(TerminalPage), findsOneWidget);
    // Taken: it is not offered again.
    expect(continuity.offer, isNull);
    await finish(tester, continuity);
  });

  testWidgets('dismissed, the banner leaves no space behind', (tester) async {
    final (_, continuity) = await pumpPhone(tester);
    final before = tester.getTopLeft(find.text('SESSIONS')).dy;

    await tester.tap(find.byKey(const ValueKey('continuity-dismiss')));
    await tester.pumpAndSettle();

    expect(banner, findsNothing);
    expect(tester.getTopLeft(find.text('SESSIONS')).dy, lessThan(before));
    await finish(tester, continuity);
  });

  testWidgets('the session menu has "Continue on…"', (tester) async {
    final (h, continuity) = await pumpPhone(tester);
    await h.open(tester, workstation, const ConnectTarget.tmux('main'));
    await tester.longPress(
      find.byKey(const ValueKey('home-session-workstation#tmux:main')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('session-action-continue-on')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('continuity-sheet')), findsOneWidget);
    expect(find.text('build · Terminal'), findsOneWidget);
    await tester.tap(find.text('build · Terminal'));
    await settleShell(tester);
    expect(
      h.workspace.sessions.map((session) => session.host.id),
      contains('workstation#tmux:build'),
    );
    await finish(tester, continuity);
  });

  testWidgets('the phone\'s routes tell continuity where it is', (
    tester,
  ) async {
    final continuity = continuityController(
      link: FakeContinuityLink(),
      clock: () => now,
    );
    await continuity.start();
    final workspace = TerminalWorkspaceController(
      NoNetworkTerminalRepository(),
    );
    final tracker = ContinuityRouteTracker(
      continuity: continuity,
      workspace: workspace,
    );
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        navigatorObservers: [tracker],
        home: const Text('home'),
      ),
    );
    unawaited(
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          settings: chatRouteSettings(
            hostId: 'vtm#herdr:w1',
            agentId: 'agent-7',
          ),
          builder: (_) => const Text('chat'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final place = continuity.context!.place;
    expect(place.view, ContinuityView.chat);
    expect(place.machineId, 'vtm');
    expect(place.agentId, 'agent-7');

    // A dialog over it moves nowhere.
    unawaited(
      showDialog<void>(
        context: navigator.currentContext!,
        builder: (_) => const Text('dialog'),
      ),
    );
    await tester.pumpAndSettle();
    expect(continuity.context!.place.agentId, 'agent-7');

    tracker.dispose();
    await tester.pumpWidget(const SizedBox());
    workspace.dispose();
    continuity.dispose();
  });

  testWidgets('the settings toggles change what is shared', (tester) async {
    final continuity = continuityController(
      link: FakeContinuityLink(),
      clock: () => now,
    );
    await continuity.start();
    await tester.pumpWidget(
      MaterialApp(
        home: Material(child: ContinuitySettingsTiles(controller: continuity)),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('continuity-drafts')));
    await tester.pump();
    expect(continuity.preferences, const ContinuityPreferences(drafts: false));
    await tester.tap(find.byKey(const ValueKey('continuity-scroll')));
    await tester.tap(find.byKey(const ValueKey('continuity-sessions')));
    await tester.pump();
    expect(
      continuity.preferences,
      const ContinuityPreferences(
        sessions: false,
        drafts: false,
        scroll: false,
      ),
    );
    await tester.pumpWidget(const SizedBox());
    continuity.dispose();
  });
}
