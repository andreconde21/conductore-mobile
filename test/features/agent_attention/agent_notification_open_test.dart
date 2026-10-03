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

    // CON-062: the open tab of another workspace was re-pointed at the
    // agent's: it showed the wrong workspace, and its own was lost.
    test('lands on the pane in a tab of its own and asks for the terminal; '
        'the open tab of another workspace stays there', () async {
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

      expect(shown, isNot(herdrTab));
      expect(workspace.activeSession, shown);
      expect(flow.herdr.workspaceOf(shown!), 'w3');
      expect(flow.herdr.workspaceOf(herdrTab), 'w1');
      // Its attach focuses the exact pane.
      expect(shown.startupCommand, contains('herdr agent focus w3:p2'));
      expect(requests, 1);
    });

    test('with the focus setting off: never moves Herdr\'s focus, shows '
        'the agent\'s own screen with "Show here", and the other workspace '
        'still opens', () async {
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

      expect(shown, isNot(herdrTab));
      expect(workspace.activeSession, shown);
      expect(flow.herdr.workspaceOf(shown!), 'w3');
      expect(flow.herdr.workspaceOf(herdrTab), 'w1');
      expect(server.herdrArgs.where((args) => args.contains('focus')), isEmpty);
      // Not the live screen, which mirrors whatever Herdr shows.
      expect(flow.herdr.agentViews.value, contains(shown));
      expect(shown.sharedView.value, isNotNull);

      // "Show here": the user asked, so the focus moves once, to the pane.
      expect(await flow.herdr.takeFocusOnce(shown), isTrue);
      expect(server.focusedWorkspace, 'w3');
      expect(server.focusedPane, 'w3:p2');
      expect(flow.herdr.agentViews.value, isNot(contains(shown)));

      // The other workspace's tab still opens on its workspace.
      expect(
        flow.open(host, const ConnectTarget.herdr(workspaceId: 'w1')),
        herdrTab,
      );
      expect(workspace.activeSession, herdrTab);
      expect(flow.herdr.workspaceOf(herdrTab), 'w1');
    });

    test('opening a workspace whose tab drifted elsewhere puts it back '
        '(CON-062)', () async {
      final herdrTab = workspace.open(
        const ConnectTarget.herdr(workspaceId: 'w1').apply(host),
      );
      // The user went to w2 inside that tab's Herdr.
      flow.herdr.noteWorkspace(herdrTab, 'w2');
      workspace.open(host);
      await Future<void>.delayed(Duration.zero);

      expect(
        flow.open(host, const ConnectTarget.herdr(workspaceId: 'w1')),
        herdrTab,
      );
      await Future<void>.delayed(Duration.zero);
      expect(flow.herdr.workspaceOf(herdrTab), 'w1');
      expect(server.focusedWorkspace, 'w1');
    });

    test('an agent handed out with a session\'s host (as the agent monitors '
        'list them) opens on its machine, and the other workspaces still '
        'open there (CON-056)', () async {
      mayMove = false;
      final repository = FakeHostsRepository()..persisted = [host];
      final hosts = HostsController(repository);
      await hosts.load();
      await flow.herdr.dispose();
      flow = SessionConnectFlow(
        hostsController: hosts,
        workspace: workspace,
        runnerFactory: (_) => server.runner(),
        preferences: InMemoryConnectPreferencesRepository(),
        mayMoveHerdrFocus: () => mayMove,
      );
      final herdrTab = workspace.open(
        const ConnectTarget.herdr(workspaceId: 'w1').apply(host),
      );

      final shown = await flow.openAgent(
        herdrTab.host,
        const AgentInfo(
          id: 'w1:p2',
          name: '',
          state: AgentAttentionState.unknown,
          workspace: 'w1',
          tab: 'w1:t1',
          pane: 'w1:p2',
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(shown, herdrTab);
      expect(workspace.sessions, [herdrTab]);
      expect(repository.persisted.map((saved) => saved.id), ['h']);

      // Another workspace, from the same session's host: its place parses
      // (no id derived from a derived id, pinned to workspace "w1#herdr").
      final other = await flow.openAgentLocation(
        herdrTab.host,
        workspaceId: 'w3',
        label: 'three',
      );
      expect(other, isNotNull);
      for (final session in workspace.sessions) {
        expect(baseHostId(session.host.id), 'h');
        expect(
          ConnectTarget.idSeparator.allMatches(session.host.id),
          hasLength(1),
        );
      }
      expect(flow.herdr.workspaceOf(other!), 'w3');
      expect(repository.persisted.map((saved) => saved.id), ['h']);
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
