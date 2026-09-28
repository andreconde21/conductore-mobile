import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:conduit/features/sessions/presentation/herdr_session_focus.dart';
import 'package:conduit/features/sessions/presentation/live_terminal_preview.dart';
import 'package:conduit/features/terminal/presentation/session_input_hold.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:conduit_vt/conduit_vt.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';
import '../terminal/herdr/fake_herdr_server.dart';

/// CON-054: every client of one Herdr server shares its focus, so the app
/// must put that focus on a session's workspace before the session takes
/// input, and must never let input reach another workspace.
void main() {
  late SharedFocusHerdrServer server;
  late TerminalWorkspaceController workspace;
  late HerdrSessionFocus focus;
  final host = buildHost('dev');

  setUp(() {
    server = SharedFocusHerdrServer(workspaces: ['w1', 'w2', 'w3']);
    workspace = TerminalWorkspaceController(server.clients);
    focus = HerdrSessionFocus(
      workspace: workspace,
      runnerFactory: (_) => server.runner(),
      reattachRefocusDelay: Duration.zero,
    );
  });

  tearDown(() async {
    await focus.dispose();
    workspace.dispose();
  });

  Future<void> settle() async {
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// Opens and connects an app session on Herdr workspace [id].
  Future<TerminalSessionController> attach(String id) async {
    final target = ConnectTarget.herdr(workspaceId: id, label: 'W-$id');
    final session = workspace.open(
      target.apply(host),
      startupCommand: target.startupCommand,
      target: target,
    );
    await session.connect();
    await settle();
    return session;
  }

  test('reproduces the bug without the app: typing follows the last '
      'focus', () async {
    // The raw shared-focus model the fix works around: two clients, and
    // the second attach moves the first one too.
    final one = await attach('w1');
    await attach('w2');
    await focus.dispose();
    server.focusFromElsewhere('w2');
    one.sendText('ls');
    await settle();
    expect(server.typed, {'w2': 'ls'});
  });

  group('switching sessions', () {
    test('focuses the workspace before any input goes out', () async {
      final one = await attach('w1');
      await attach('w2');
      expect(server.focusedWorkspace, 'w2');
      server.events.clear();

      server.holdFocus();
      workspace.activate(one);
      one.sendText('ls');
      await settle();
      // The focus is on its way: nothing was typed anywhere yet.
      expect(server.typed, isEmpty);
      expect(one.inputHold.value, isA<InputHoldSwitching>());
      expect((one.inputHold.value! as InputHoldSwitching).label, 'W-w1');

      server.releaseFocus();
      await settle();
      expect(server.events, ['focus w1', 'type w1: ls']);
      expect(one.inputHold.value, isNull);
    });

    test('input queued during quick back-and-forth lands in each '
        'session\'s own workspace', () async {
      final one = await attach('w1');
      final two = await attach('w2');

      server.holdFocus();
      workspace.activate(one);
      one.sendText('a');
      await settle();
      server.releaseFocus();
      await settle();

      server.holdFocus();
      workspace.activate(two);
      two.sendText('b');
      one.sendText('c'); // A stray key from the tab being left.
      await settle();
      server.releaseFocus();
      await settle();

      // The stray key went out while Herdr was still on one's workspace.
      expect(server.typed['w1'], 'ac');
      expect(server.typed['w2'], 'b');
    });

    test('a focus Herdr refuses drops held input and says so', () async {
      final one = await attach('w1');
      final gone = await attach('w3');
      workspace.activate(one);
      await settle();
      // w3 was closed in Herdr (from the laptop).
      server.workspaces.remove('w3');
      server.events.clear();

      workspace.activate(gone);
      gone.sendText('rm -rf build');
      await settle();

      expect(server.typed.values.join(), isNot(contains('rm')));
      final state = gone.inputHold.value;
      expect(state, isA<InputHoldFailed>());
      expect((state! as InputHoldFailed).dropped, 'rm -rf build'.length);
      // The closed workspace is forgotten: the session is no longer pinned.
      expect(focus.workspaceOf(gone), isNull);
    });

    test('a tab left where another session attached does not learn that '
        'workspace', () async {
      final one = await attach('w1');
      final two = await attach('w2');
      workspace.activate(one);
      await settle();
      // Two's own attach (a reconnect) put Herdr on w2 behind one's back,
      // and one is left right away.
      server.focusFromElsewhere('w2');
      workspace.activate(two);
      await settle();
      expect(focus.workspaceOf(one), 'w1');
    });
  });

  group('app-initiated writes', () {
    test('a composer send takes the focus back first', () async {
      final one = await attach('w1');
      server.events.clear();
      // The laptop's Herdr client moved the shared focus meanwhile.
      server.focusFromElsewhere('w3');

      await one.sendComposed('fix the tests', submit: true);
      await settle();

      expect(server.typed['w3'], isNull);
      expect(server.events.first, 'focus w3 (elsewhere)');
      expect(server.events[1], 'focus w1');
      expect(server.typed['w1'], contains('fix the tests'));
    });

    test('snippets, quick actions and prompt answers claim before '
        'typing', () async {
      final one = await attach('w1');
      server.focusFromElsewhere('w2');

      one
        ..claimInput()
        ..sendKey(TerminalKey.enter);
      await settle();

      expect(server.typed['w2'], isNull);
      expect(server.typed['w1'], isNotNull);
    });
  });

  test('a session attaching in the background gives the focus back to '
      'the one in use', () async {
    final one = await attach('w1');
    final two = await attach('w2');
    workspace.activate(one);
    await settle();
    await two.disconnect();
    server.events.clear();

    // Two reconnects in the background: its startup focuses w2.
    await two.connect();
    one.sendText('x');
    await settle();

    expect(server.events.first, 'focus w2 (attach)');
    expect(server.focusedWorkspace, 'w1');
    expect(server.typed, {'w1': 'x'});
    // Two's preview keeps its own screen from its attach.
    expect(two.sharedView.value, isNotNull);
  });

  group('previews', () {
    test('the session in use previews live; the others keep their own '
        'last screen', () async {
      final one = await attach('w1');
      one.terminal.write('one on w1');
      final two = await attach('w2');
      two.terminal.write('two on w2');

      workspace.activate(one);
      await settle();
      // Two's client now mirrors w1.
      two.terminal.write('\r\nmirrored w1');

      expect(one.sharedView.value, isNull);
      final shared = two.sharedView.value!;
      expect(shared.preview.lines.join('\n'), contains('two on w2'));
      expect(shared.preview.lines.join('\n'), isNot(contains('mirrored')));
      expect(shared.label, 'W-w2');

      workspace.activate(two);
      await settle();
      expect(two.sharedView.value, isNull);
      expect(
        one.sharedView.value!.preview.lines.join('\n'),
        contains('one on w1'),
      );
    });

    testWidgets('rendering previews never sends a Herdr command', (
      tester,
    ) async {
      late TerminalSessionController one;
      late TerminalSessionController two;
      await tester.runAsync(() async {
        one = await attach('w1');
        two = await attach('w2');
        workspace.activate(one);
        await settle();
      });
      final before = List.of(server.commands);
      final clock = ChangeNotifier();
      addTearDown(clock.dispose);

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: PreviewClock(
            ticks: clock,
            child: Column(
              children: [
                for (final session in [one, two])
                  Expanded(
                    child: SessionPreviewBuilder(
                      session: session,
                      builder: (context, preview, shared) =>
                          Text(shared == null ? 'live' : 'snapshot'),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
      two.terminal.write('more output');
      clock.notifyListeners();
      await tester.pump();

      expect(find.text('live'), findsOneWidget);
      expect(find.text('snapshot'), findsOneWidget);
      expect(server.commands, before);
    });
  });

  testWidgets('the app coming back re-focuses the session in use', (
    tester,
  ) async {
    await focus.dispose();
    focus = HerdrSessionFocus(
      workspace: workspace,
      runnerFactory: (_) => server.runner(),
      reattachRefocusDelay: Duration.zero,
      watchLifecycle: true,
    );
    await tester.runAsync(() async {
      await attach('w1');
      await settle();
    });
    server.focusFromElsewhere('w2');

    await tester.runAsync(() async {
      for (final state in const [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await settle();
    });

    expect(server.focusedWorkspace, 'w1');
    expect(server.events.last, 'focus w1');
  });
}
