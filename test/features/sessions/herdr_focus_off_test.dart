import 'dart:async';
import 'dart:convert';

import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:conduit/features/sessions/presentation/herdr_session_focus.dart';
import 'package:conduit/features/terminal/domain/ssh_terminal_session.dart';
import 'package:conduit/features/terminal/presentation/session_input_hold.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:conduit_vt/conduit_vt.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';
import '../terminal/herdr/fake_herdr_server.dart';

/// "Phone may move Herdr focus" off (the default): the app never moves
/// Herdr's shared focus on its own, so the laptop's Herdr stays where it
/// is. App writes go to the session's own pane by id; typed keys go out
/// only while Herdr shows the session's own workspace.
void main() {
  late SharedFocusHerdrServer server;
  late TerminalWorkspaceController workspace;
  late HerdrSessionFocus focus;
  final host = buildHost('dev');

  HerdrSessionFocus build({bool watchLifecycle = false}) => HerdrSessionFocus(
    workspace: workspace,
    runnerFactory: (_) => server.runner(),
    reattachRefocusDelay: Duration.zero,
    watchLifecycle: watchLifecycle,
  );

  setUp(() {
    // The laptop's Herdr client is on w3.
    server = SharedFocusHerdrServer(
      workspaces: ['w1', 'w2', 'w3'],
      focusedWorkspace: 'w3',
    );
    workspace = TerminalWorkspaceController(server.clients);
    focus = build();
  });

  tearDown(() async {
    await focus.dispose();
    workspace.dispose();
  });

  Future<void> settle() async {
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

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

  bool focusCommandSent() =>
      server.herdrArgs.any((args) => args.contains('focus'));

  test('the setting is off unless the app says otherwise', () {
    expect(focus.mayMoveFocus, isFalse);
  });

  test('attaching, switching, coming back and reattaching never move the '
      'focus', () async {
    await focus.dispose();
    focus = build(watchLifecycle: true);
    final one = await attach('w1');
    final two = await attach('w2');
    workspace.activate(one);
    await settle();
    workspace.activate(two);
    await settle();
    focus.reassertActive(); // What the app coming back does.
    await settle();
    await one.disconnect();
    await one.connect(); // A reattach in the background.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await settle();
    one.claimInput();
    await settle();

    expect(server.focusedWorkspace, 'w3');
    expect(focusCommandSent(), isFalse);
    // The startup command attached without focusing.
    expect(server.events.where((event) => event.contains('attach')), [
      'attach',
      'attach',
      'attach',
    ]);
  });

  test('the startup command is a plain attach', () {
    const target = ConnectTarget.herdr(workspaceId: 'w1', tabId: 'w1:t2');
    expect(target.startupCommand, contains('tab focus'));
    expect(ConnectTarget.withoutHerdrFocus(target.startupCommand!), 'herdr');
    const named = ConnectTarget.herdr(workspaceId: 'w1', session: 'work');
    expect(
      ConnectTarget.withoutHerdrFocus(named.startupCommand!),
      'herdr --session work',
    );
    expect(ConnectTarget.withoutHerdrFocus('cd /tmp'), 'cd /tmp');
  });

  group('app writes go to the session\'s own pane', () {
    test('a composer send reaches its pane, not the focused one', () async {
      final one = await attach('w1');
      await one.sendComposed('fix the tests', submit: true);
      await Future<void>.delayed(
        TerminalSessionController.composedEnterDelay * 2,
      );

      expect(server.events, contains('pane w1:p1: fix the tests'));
      expect(server.events, contains('keys w1:p1: enter'));
      expect(server.typed, isEmpty);
      expect(server.focusedWorkspace, 'w3');
      expect(focusCommandSent(), isFalse);
    });

    test('an agent gets it through agent prompt', () async {
      server.agentPanes.add('w2:p1');
      final two = await attach('w2');
      await two.sendAppText('review this', submit: true);
      expect(server.events.last, 'prompt w2:p1: review this');
    });

    test('snippets, quick actions, image paths and menu answers', () async {
      final one = await attach('w1');
      await one.sendAppText('/tmp/shot.png', paste: true);
      await one.sendAppKeys([TerminalKey.arrowDown, TerminalKey.enter]);
      expect(server.events, contains('pane w1:p1: /tmp/shot.png'));
      expect(server.events.last, 'keys w1:p1: down enter');
      expect(server.typed, isEmpty);
    });

    test(
      'with no pane to send to it falls back to the held terminal',
      () async {
        final one = await attach('w1');
        server.workspaces.remove('w1'); // Gone: no pane in it.
        await one.sendAppText('ls');
        await settle();
        expect(server.typed, isEmpty);
        expect(one.inputHold.value, isA<InputHoldBlocked>());
      },
    );
  });

  group('typed keys', () {
    test(
      'go straight out while Herdr shows the session\'s workspace',
      () async {
        server.focusFromElsewhere('w1');
        final one = await attach('w1');
        one.sendText('l');
        await settle();
        one.sendText('s');
        await settle();
        expect(server.typed, {'w1': 'ls'});
        expect(one.focusElsewhere.value, isNull);
      },
    );

    test('are held, not sent, while Herdr shows another workspace', () async {
      final one = await attach('w1');
      one.sendText('yes');
      await settle();

      expect(server.typed, isEmpty);
      final hold = one.inputHold.value;
      expect(hold, isA<InputHoldBlocked>());
      expect(hold!.label, 'Ww3');
      expect((hold as InputHoldBlocked).queued, 3);
      expect(one.focusElsewhere.value, 'Ww3');
      // More keys join the held ones.
      one.sendText('!');
      expect((one.inputHold.value! as InputHoldBlocked).queued, 4);
      expect(focusCommandSent(), isFalse);
    });

    test('"Take focus once" moves it this once and sends them', () async {
      final one = await attach('w1');
      one.sendText('ls');
      await settle();
      expect(await focus.takeFocusOnce(one), isTrue);
      await settle();

      expect(server.focusedWorkspace, 'w1');
      expect(server.herdrArgs.where((a) => a.contains('focus')), [
        'workspace focus w1',
      ]);
      expect(server.typed, {'w1': 'ls'});
      expect(one.inputHold.value, isNull);
    });

    test('"Discard" drops them; "Type in composer" hands them over', () async {
      final one = await attach('w1');
      one.sendText('abc');
      await settle();
      one.discardHeldInput();
      expect(one.inputHold.value, isNull);

      one.sendText('def\r');
      await settle();
      expect(one.takeHeldText(), 'def');
      expect(server.typed, isEmpty);
    });

    test(
      '"Use … here" keeps the session on the workspace Herdr shows',
      () async {
        final one = await attach('w1');
        one.sendText('pwd');
        await settle();
        expect(await focus.useShownWorkspace(one), isTrue);
        await settle();
        expect(focus.workspaceOf(one), 'w3');
        expect(server.typed, {'w3': 'pwd'});
        expect(focusCommandSent(), isFalse);
      },
    );

    test('a stale check is repeated before keys go out', () async {
      await focus.dispose();
      focus = HerdrSessionFocus(
        workspace: workspace,
        runnerFactory: (_) => server.runner(),
        focusCheckFreshness: Duration.zero,
      );
      server.focusFromElsewhere('w1');
      final one = await attach('w1');
      one.sendText('a');
      await settle();
      server.focusFromElsewhere('w2'); // The laptop moved on.
      one.sendText('b');
      await settle();
      expect(server.typed, {'w1': 'a'});
      expect(one.inputHold.value, isA<InputHoldBlocked>());
    });
  });

  test('previews of sessions Herdr does not show come from their own '
      'pane, read-only', () async {
    server.focusFromElsewhere('w1');
    final one = await attach('w1');
    final two = await attach('w2');
    workspace.activate(one);
    await settle();

    expect(one.sharedView.value, isNull);
    final shared = two.sharedView.value!;
    expect(shared.preview.lines.join('\n'), contains('screen of w2'));
    expect(focusCommandSent(), isFalse);
    expect(
      server.herdrArgs.any((a) => a.startsWith('pane read w2:p1')),
      isTrue,
    );
  });

  testWidgets('the setting can be turned on at run time', (tester) async {
    var may = false;
    await focus.dispose();
    focus = HerdrSessionFocus(
      workspace: workspace,
      runnerFactory: (_) => server.runner(),
      reattachRefocusDelay: Duration.zero,
      mayMoveFocus: () => may,
    );
    late TerminalSessionController one;
    await tester.runAsync(() async {
      one = await attach('w1');
      await attach('w2');
      may = true;
      workspace.activate(one);
      await settle();
    });
    expect(server.focusedWorkspace, 'w1');
  });

  test(
    'the terminal\'s answers to the remote program are never held',
    () async {
      final remote = _ScriptedSession();
      final session = TerminalSessionController(
        host: host,
        repository: ImmediateTerminalRepository(remote),
      )..inputCheck = (_) => Future.value(InputHoldDecision.block);
      addTearDown(session.dispose);
      await session.connect();

      session.sendText('ls'); // Typed: held.
      await settle();
      remote.output.add(utf8.encode('\x1b[c')); // The client asks for DA1.
      await settle();

      expect(session.inputHold.value, isA<InputHoldBlocked>());
      final sent = remote.sent.map(utf8.decode).toList();
      expect(sent, hasLength(1));
      expect(sent.single, startsWith('\x1b[?'));
    },
  );
}

class _ScriptedSession implements SshTerminalSession {
  final output = StreamController<List<int>>();
  final sent = <List<int>>[];

  @override
  Future<void> get done => Completer<void>().future;

  @override
  Stream<List<int>> get stderr => const Stream.empty();

  @override
  Stream<List<int>> get stdout => output.stream;

  @override
  Future<void> close() async {}

  @override
  void resize(int columns, int rows, int pixelWidth, int pixelHeight) {}

  @override
  Future<void> send(List<int> data) async => sent.add(data);
}
