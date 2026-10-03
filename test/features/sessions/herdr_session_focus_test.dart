import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:conduit/features/sessions/presentation/herdr_session_focus.dart';
import 'package:conduit/features/terminal/domain/herdr_keymap.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';
import '../terminal/herdr/fake_herdr_server.dart';

void main() {
  late FakeHerdrServer server;
  late TerminalWorkspaceController workspace;
  late HerdrSessionFocus focus;
  final host = buildHost('dev');

  setUp(() {
    server = FakeHerdrServer();
    workspace = TerminalWorkspaceController(NoNetworkTerminalRepository());
    focus = HerdrSessionFocus(
      workspace: workspace,
      runnerFactory: (_) => server.runner(),
      reattachRefocusDelay: Duration.zero,
      mayMoveFocus: () => true,
    );
  });

  tearDown(() async {
    await focus.dispose();
    workspace.dispose();
  });

  TerminalSessionController openTarget(ConnectTarget target, [SavedHost? on]) {
    final base = on ?? host;
    return workspace.open(
      target.apply(base),
      startupCommand: target.startupCommand,
    );
  }

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  group('re-focus on tab switch', () {
    test('focuses each tab\'s workspace when it becomes active', () async {
      final one = openTarget(const ConnectTarget.herdr(workspaceId: 'w1'));
      openTarget(const ConnectTarget.herdr(workspaceId: 'w2'));
      await settle();
      expect(server.focusedWorkspace, 'w2');

      workspace.activate(one);
      await settle();
      expect(server.focusedWorkspace, 'w1');
      expect(server.herdrArgs.last, 'workspace focus w1');
      // One command channel for both tabs: they share a Herdr server.
      expect(server.runnersOpened, 1);
    });

    test(
      'remembers where the user moved inside Herdr before leaving',
      () async {
        final one = openTarget(const ConnectTarget.herdr(workspaceId: 'w1'));
        final two = openTarget(const ConnectTarget.herdr(workspaceId: 'w2'));
        await settle();
        // Inside tab two the user switched Herdr to w3 by hand.
        server.focusedWorkspace = 'w3';

        workspace.activate(one);
        await settle();
        expect(server.focusedWorkspace, 'w1');
        expect(focus.workspaceOf(two), 'w3');

        workspace.activate(two);
        await settle();
        expect(server.focusedWorkspace, 'w3');
      },
    );

    test('leaves tmux and plain shell tabs alone', () async {
      openTarget(const ConnectTarget.herdr(workspaceId: 'w2'));
      await settle();
      server.commands.clear();
      openTarget(const ConnectTarget.tmux('main'));
      workspace.open(host);
      await settle();
      expect(server.commands, isEmpty);
    });

    test('does not open background channels for security-key hosts', () async {
      final keyHost = host.copyWith(
        authMethod: SshAuthMethod.hardwareKey,
        privateKey: 'stub',
      );
      openTarget(const ConnectTarget.herdr(workspaceId: 'w1'), keyHost);
      openTarget(const ConnectTarget.herdr(workspaceId: 'w2'), keyHost);
      await settle();
      expect(server.runnersOpened, 0);
    });

    test('tabs on different Herdr sessions focus their own server', () async {
      final one = openTarget(const ConnectTarget.herdr(workspaceId: 'w1'));
      openTarget(const ConnectTarget.herdr(workspaceId: 'w2', session: 'work'));
      await settle();
      expect(
        server.commands.last,
        contains('--session work workspace focus w2'),
      );

      workspace.activate(one);
      await settle();
      // No read-back across servers: straight to the focus.
      expect(server.herdrArgs.last, 'workspace focus w1');
      expect(server.runnersOpened, 2);
    });
  });

  group('deep links', () {
    test(
      'an open tab on the server is reused and focused on the pane',
      () async {
        final one = openTarget(const ConnectTarget.herdr(workspaceId: 'w1'));
        final two = openTarget(const ConnectTarget.herdr(workspaceId: 'w2'));
        await settle();

        final shown = await focus.openAgentLocation(
          host,
          workspaceId: 'w1',
          tabId: 'w1:t2',
          paneId: 'w1:p4',
        );
        await settle();

        expect(shown, one);
        expect(workspace.activeSession, one);
        expect(server.herdrArgs.last, 'agent focus w1:p4');
        expect(server.focusedPane, 'w1:p4');
        expect(focus.workspaceOf(one), 'w1');
        expect(focus.workspaceOf(two), 'w2');
      },
    );

    // CON-062: re-pointing the open tab of another workspace made that tab
    // show the agent's workspace, and opening its own workspace again then
    // landed on the agent's: the user could not get back to it.
    test(
      'a tab on another workspace is left alone: the agent gets its own',
      () async {
        final one = openTarget(const ConnectTarget.herdr(workspaceId: 'w1'));
        await settle();

        final shown = await focus.openAgentLocation(
          host,
          workspaceId: 'w3',
          paneId: 'w3:p1',
          open: openTarget,
        );
        await settle();

        expect(shown, isNot(one));
        expect(focus.workspaceOf(shown!), 'w3');
        expect(focus.workspaceOf(one), 'w1');
        expect(server.focusedWorkspace, 'w3');

        // Its own workspace is still one tap away.
        workspace.activate(one);
        await settle();
        expect(server.focusedWorkspace, 'w1');
      },
    );

    test(
      'opens a new tab that focuses the exact place before attaching',
      () async {
        final opened = <ConnectTarget>[];
        final shown = await focus.openAgentLocation(
          host,
          workspaceId: 'w2',
          tabId: 'w2:t3',
          paneId: 'w2:p7',
          label: 'api',
          open: (target) {
            opened.add(target);
            return openTarget(target);
          },
        );

        expect(shown, isNotNull);
        expect(opened.single.key, 'herdr:w2');
        expect(
          opened.single.startupCommand,
          'herdr agent focus w2:p7 >/dev/null 2>&1 || '
          'herdr workspace focus w2 >/dev/null 2>&1; herdr',
        );
      },
    );

    test(
      'a dropped tab reconnects and is focused again after attach',
      () async {
        final one = openTarget(const ConnectTarget.herdr(workspaceId: 'w1'));
        await settle();
        expect(one.shouldConnect, isTrue);

        await focus.openAgentLocation(host, workspaceId: 'w1', paneId: 'w1:p2');
        await Future<void>.delayed(const Duration(milliseconds: 10));

        final paneFocuses = server.herdrArgs
            .where((args) => args == 'agent focus w1:p2')
            .length;
        expect(paneFocuses, 2);
      },
    );
  });

  group('keymap', () {
    setUp(HerdrKeymapCache.instance.clear);
    tearDown(HerdrKeymapCache.instance.clear);

    test('is read once per machine over the Herdr channel', () async {
      final one = openTarget(const ConnectTarget.herdr(workspaceId: 'w1'));
      final two = openTarget(const ConnectTarget.herdr(workspaceId: 'w2'));
      focus
        ..ensureKeymap(one)
        ..ensureKeymap(two)
        ..ensureKeymap(one);
      await settle();
      await settle();

      final reads = server.commands.where((c) => c.contains('config.toml'));
      expect(reads, hasLength(1));
      expect(HerdrKeymapCache.instance.has('dev'), isTrue);
    });

    test('security-key hosts keep the defaults without asking', () async {
      final keyHost = host.copyWith(
        authMethod: SshAuthMethod.hardwareKey,
        privateKey: 'stub',
      );
      final session = openTarget(
        const ConnectTarget.herdr(workspaceId: 'w1'),
        keyHost,
      );
      focus.ensureKeymap(session);
      await settle();
      expect(server.runnersOpened, 0);
      expect(HerdrKeymapCache.instance.has('dev'), isFalse);
    });
  });
}
