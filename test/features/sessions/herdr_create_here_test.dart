import 'package:conduit/features/hosts/presentation/hosts_controller.dart';
import 'package:conduit/features/sessions/domain/connect_preferences.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:conduit/features/sessions/presentation/session_connect_flow.dart';
import 'package:conduit/features/terminal/domain/herdr_remote_control.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';
import '../terminal/herdr/fake_herdr_server.dart';

/// Split, new tab and new workspace from the phone act where the session
/// is (its own pane and workspace), never on the workspace Herdr's shared
/// focus shows (the laptop's); they take that focus only when the phone
/// may move it.
void main() {
  late SharedFocusHerdrServer server;
  late TerminalWorkspaceController workspace;
  late SessionConnectFlow flow;
  final host = buildHost('dev');

  Future<TerminalSessionController> phoneOnW1({
    required bool mayMoveFocus,
  }) async {
    // The laptop's Herdr client is on w3.
    server = SharedFocusHerdrServer(
      workspaces: ['w1', 'w2', 'w3'],
      focusedWorkspace: 'w3',
    );
    workspace = TerminalWorkspaceController(server.clients);
    flow = SessionConnectFlow(
      hostsController: HostsController(FakeHostsRepository()),
      workspace: workspace,
      runnerFactory: (_) => server.runner(),
      preferences: InMemoryConnectPreferencesRepository(),
      mayMoveHerdrFocus: () => mayMoveFocus,
    );
    final session = flow.open(
      host,
      const ConnectTarget.herdr(workspaceId: 'w1', label: 'W-w1'),
    );
    await session.connect();
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    return session;
  }

  tearDown(() async {
    flow.dispose();
    await flow.herdr.dispose();
    workspace.dispose();
  });

  List<String> createCommands() => [
    for (final args in server.herdrArgs)
      if (args.contains(' split ') ||
          args.contains('create') ||
          args.startsWith('pane split'))
        args,
  ];

  group('setting off (the default)', () {
    test('split and new tab land in w1 without moving the laptop', () async {
      final phone = await phoneOnW1(mayMoveFocus: false);
      expect(server.focusedWorkspace, 'w3');

      expect(await phone.herdrPaneCreator!(HerdrNewPane.splitRight), isTrue);
      expect(await phone.herdrPaneCreator!(HerdrNewPane.newTab), isTrue);

      expect(server.created, ['split w1:p1', 'tab w1']);
      expect(server.focusedWorkspace, 'w3');
      expect(createCommands(), hasLength(2));
      expect(createCommands(), everyElement(contains('--no-focus')));
    });

    test('a new workspace opens in its own app tab, unfocused', () async {
      final phone = await phoneOnW1(mayMoveFocus: false);

      expect(await phone.herdrPaneCreator!(HerdrNewPane.newWorkspace), isTrue);

      expect(server.created, ['workspace w4']);
      expect(server.focusedWorkspace, 'w3');
      expect(workspace.activeSession?.host.id, 'dev#herdr:w4');
      expect(workspace.sessions, contains(phone));
    });
  });

  test('setting on: still in w1, and focused there', () async {
    final phone = await phoneOnW1(mayMoveFocus: true);

    expect(await phone.herdrPaneCreator!(HerdrNewPane.splitDown), isTrue);
    expect(await phone.herdrPaneCreator!(HerdrNewPane.newTab), isTrue);

    expect(server.created, ['split w1:p1', 'tab w1']);
    expect(server.created.where((made) => made.contains('w3')), isEmpty);
    expect(createCommands(), hasLength(2));
    expect(createCommands(), everyElement(contains('--focus')));
  });
}
