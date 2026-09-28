import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention_notifier.dart';
import 'package:conduit/features/agent_attention/presentation/agent_notification_open_listener.dart';
import 'package:conduit/features/hosts/presentation/hosts_controller.dart';
import 'package:conduit/features/sessions/domain/connect_preferences.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:conduit/features/sessions/presentation/session_connect_flow.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';
import '../terminal/herdr/fake_herdr_server.dart';

class _FakeOpenSource implements AgentOpenRequestSource {
  AgentOpenTarget? pending;
  void Function()? listener;

  @override
  Future<AgentOpenTarget?> consume() async {
    final target = pending;
    pending = null;
    return target;
  }

  @override
  void setListener(void Function()? listener) => this.listener = listener;
}

void main() {
  test('open targets survive the platform map', () {
    const target = AgentOpenTarget(
      hostId: 'h',
      agentId: 'w1:p2',
      workspaceId: 'w1',
      tabId: 'w1:t1',
      paneId: 'w1:p2',
    );
    final arguments = target.toArguments();
    expect(arguments['openHostId'], 'h');
    expect(
      AgentOpenTarget.fromMap({
        for (final entry in arguments.entries)
          entry.key.substring(4, 5).toLowerCase() + entry.key.substring(5):
              entry.value,
      }),
      target,
    );
    expect(AgentOpenTarget.fromMap({'hostId': ''}), isNull);
    expect(AgentOpenTarget.fromMap(null), isNull);
  });

  testWidgets('a tap waiting at mount and a later one both open the agent', (
    tester,
  ) async {
    final source = _FakeOpenSource()
      ..pending = const AgentOpenTarget(
        hostId: 'h',
        workspaceId: 'w1',
        tabId: 'w1:t2',
        paneId: 'w1:p4',
      );
    final opened = <(String, AgentInfo)>[];
    await tester.pumpWidget(
      AgentNotificationOpenListener(
        source: source,
        findHost: (hostId) async => hostId == 'h' ? buildHost('h') : null,
        onOpen: (host, agent) async => opened.add((host.id, agent)),
        child: const SizedBox(),
      ),
    );
    await tester.pump();

    expect(opened, hasLength(1));
    expect(opened.single.$2.workspace, 'w1');
    expect(opened.single.$2.tab, 'w1:t2');
    expect(opened.single.$2.pane, 'w1:p4');

    source.pending = const AgentOpenTarget(hostId: 'gone');
    source.listener!();
    await tester.pump();
    expect(opened, hasLength(1));

    await tester.pumpWidget(const SizedBox());
    expect(source.listener, isNull);
  });

  group('SessionConnectFlow.openAgent', () {
    late FakeHerdrServer server;
    late TerminalWorkspaceController workspace;
    late SessionConnectFlow flow;
    final host = buildHost('h');
    // "Phone may move Herdr focus"; off for the one test that says so.
    var mayMove = true;

    setUp(() {
      mayMove = true;
      server = FakeHerdrServer();
      workspace = TerminalWorkspaceController(NoNetworkTerminalRepository());
      flow = SessionConnectFlow(
        hostsController: HostsController(
          FakeHostsRepository()..persisted = [host],
        ),
        workspace: workspace,
        runnerFactory: (_) => server.runner(),
        preferences: InMemoryConnectPreferencesRepository(),
        mayMoveHerdrFocus: () => mayMove,
      );
    });

    tearDown(() async {
      await flow.herdr.dispose();
      workspace.dispose();
    });

    test('lands on the pane in the open Herdr tab and asks for the '
        'terminal', () async {
      final herdrTab = workspace.open(
        const ConnectTarget.herdr(workspaceId: 'w1').apply(host),
      );
      workspace.open(host);
      var requests = 0;
      flow.terminalRequests.addListener(() => requests += 1);

      final shown = await flow.openAgent(
        host,
        const AgentInfo(
          id: 'w3:p2',
          name: '',
          state: AgentAttentionState.unknown,
          workspace: 'w3',
          tab: 'w3:t1',
          pane: 'w3:p2',
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(shown, herdrTab);
      expect(workspace.activeSession, herdrTab);
      expect(server.focusedPane, 'w3:p2');
      expect(requests, 1);
    });

    test('with the focus setting off it opens the tab without moving '
        'Herdr\'s focus', () async {
      mayMove = false;
      final herdrTab = workspace.open(
        const ConnectTarget.herdr(workspaceId: 'w1').apply(host),
      );
      workspace.open(host);

      final shown = await flow.openAgent(
        host,
        const AgentInfo(
          id: 'w3:p2',
          name: '',
          state: AgentAttentionState.unknown,
          workspace: 'w3',
          tab: 'w3:t1',
          pane: 'w3:p2',
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(shown, herdrTab);
      expect(workspace.activeSession, herdrTab);
      expect(flow.herdr.workspaceOf(herdrTab), 'w3');
      expect(server.herdrArgs.where((args) => args.contains('focus')), isEmpty);
    });

    test('without a Herdr location it activates the host\'s tab', () async {
      final plain = workspace.open(host);
      workspace.open(buildHost('other'));

      final shown = await flow.openAgent(
        host,
        const AgentInfo(id: 'a', name: '', state: AgentAttentionState.unknown),
      );

      expect(shown, plain);
      expect(workspace.activeSession, plain);
      expect(server.commands, isEmpty);
    });
  });
}
