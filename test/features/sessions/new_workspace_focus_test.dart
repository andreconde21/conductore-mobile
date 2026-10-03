import 'dart:async';

import 'package:conduit/features/hosts/presentation/hosts_controller.dart';
import 'package:conduit/features/sessions/domain/connect_preferences.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:conduit/features/sessions/presentation/session_connect_flow.dart';
import 'package:conduit/features/terminal/presentation/session_input_hold.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';
import '../terminal/herdr/fake_herdr_server.dart';

/// A Herdr workspace created from the connect picker opens by id, like any
/// workspace: with "Phone may move Herdr focus" off the laptop's view stays
/// where it is and the session offers "Take focus once"; with it on, the
/// new workspace is focused.
void main() {
  late SharedFocusHerdrServer server;
  late TerminalWorkspaceController workspace;
  late SessionConnectFlow flow;
  final host = buildHost('dev');

  void build({required bool mayMoveFocus}) {
    // The laptop's Herdr client is on w3; the phone already has a tab on
    // w1; w4 was just created (without --focus when the setting is off).
    server = SharedFocusHerdrServer(
      workspaces: ['w1', 'w2', 'w3', 'w4'],
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
  }

  tearDown(() async {
    flow.dispose();
    await flow.herdr.dispose();
    workspace.dispose();
  });

  Future<void> settle() async {
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<TerminalSessionController> open(ConnectTarget target) async {
    final session = flow.open(host, target);
    await session.connect();
    await settle();
    return session;
  }

  bool focusCommandSent() =>
      server.herdrArgs.any((args) => args.contains('focus'));

  test('setting off: the new workspace gets its own tab, the laptop keeps '
      'its view, and "Take focus once" lands on it', () async {
    build(mayMoveFocus: false);
    final other = await open(
      const ConnectTarget.herdr(workspaceId: 'w1', label: 'W-w1'),
    );
    final created = await open(
      const ConnectTarget.herdr(workspaceId: 'w4', label: 'api'),
    );

    expect(created, isNot(same(other)));
    expect(workspace.activeSession, same(created));
    expect(created.host.id, 'dev#herdr:w4');
    expect(flow.herdr.workspaceOf(created), 'w4');
    expect(server.focusedWorkspace, 'w3');
    expect(focusCommandSent(), isFalse);

    // Herdr shows the laptop's workspace: keys wait and the session says
    // so (the banner) instead of typing into w3.
    created.sendText('ls');
    await settle();
    expect(created.inputHold.value, isA<InputHoldBlocked>());
    expect(created.focusElsewhere.value, 'Ww3');
    expect(server.typed, isEmpty);

    expect(await flow.herdr.takeFocusOnce(created), isTrue);
    await settle();
    expect(server.focusedWorkspace, 'w4');
    expect(server.typed, {'w4': 'ls'});
  });

  test('setting on: opening it focuses the new workspace', () async {
    build(mayMoveFocus: true);
    await open(const ConnectTarget.herdr(workspaceId: 'w1', label: 'W-w1'));
    final created = await open(
      const ConnectTarget.herdr(workspaceId: 'w4', label: 'api'),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await settle();

    expect(workspace.activeSession, same(created));
    expect(server.focusedWorkspace, 'w4');
    unawaited(created.disconnect());
  });
}
