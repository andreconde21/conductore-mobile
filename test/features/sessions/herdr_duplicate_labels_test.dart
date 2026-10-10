import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_launcher.dart';
import 'package:conduit/features/session_navigation/presentation/session_view_launcher.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:conduit/features/sessions/presentation/herdr_session_focus.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';
import '../terminal/herdr/fake_herdr_server.dart';

/// CON-103: on development-central six Herdr workspaces are labelled
/// "Projects". Opening one agent must land on its own pane, and Chat View
/// must open the agent the terminal shows, whatever the labels.
void main() {
  late SharedFocusHerdrServer server;
  late TerminalWorkspaceController workspace;
  late HerdrSessionFocus focus;
  final host = buildHost('dev');

  setUp(() {
    server = SharedFocusHerdrServer(
      workspaces: ['w12', 'w1C', 'w1D'],
      focusedWorkspace: 'w1C',
      labels: {'w12': 'Projects', 'w1C': 'Projects', 'w1D': 'Projects'},
    )..agentPanes.addAll(['w12:p1', 'w1C:p1', 'w1D:p1']);
    workspace = TerminalWorkspaceController(server.clients);
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

  Future<void> settle() async {
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  TerminalSessionController open(ConnectTarget target) => workspace.open(
    target.apply(host),
    startupCommand: target.startupCommand,
    target: target,
  );

  AgentInfo claude(String workspaceId) => AgentInfo(
    id: 'claude-$workspaceId',
    name: 'Projects',
    kind: 'claude',
    state: AgentAttentionState.needsInput,
    workspace: workspaceId,
    tab: '$workspaceId:t1',
    pane: '$workspaceId:p1',
  );

  test('opening an agent lands on its own pane, not on another workspace '
      'with the same label', () async {
    final other = open(
      const ConnectTarget.herdr(workspaceId: 'w1D', label: 'Projects'),
    );
    await other.connect();
    await settle();

    final shown = await focus.openAgentLocation(
      host,
      workspaceId: 'w12',
      tabId: 'w12:t1',
      paneId: 'w12:p1',
      label: 'Projects',
      open: open,
    );
    await shown!.connect();
    await settle();

    expect(shown, isNot(other));
    expect(shown.host.id, '${host.id}#herdr:w12');
    expect(focus.workspaceOf(shown), 'w12');
    expect(focus.workspaceOf(other), 'w1D');
    expect(server.focusedWorkspace, 'w12');
    expect(server.focusedPaneOf('w12'), 'w12:p1');

    // The same open again reuses that tab, never the other "Projects" one.
    final again = await focus.openAgentLocation(
      host,
      workspaceId: 'w12',
      paneId: 'w12:p1',
      label: 'Projects',
      open: open,
    );
    expect(again, shown);
    expect(workspace.sessions, hasLength(2));
  });

  test('Chat View from a tab whose workspace was closed opens the agent '
      'it shows, without a picker', () async {
    // A tab restored for a workspace Herdr no longer has (the old "DTech"
    // workspace): focusing it fails, so it mirrors Herdr's focus.
    final stale = open(
      const ConnectTarget.herdr(workspaceId: 'wE', label: 'DTech'),
    );
    await stale.connect();
    await settle();
    expect(focus.isUnpinned(stale), isTrue);
    server.focusPaneFromElsewhere('w1D:p1');

    final agents = [claude('w12'), claude('w1C'), claude('w1D')];
    // Before CON-103: the gone workspace's id, so no agent matched and
    // Chat View asked which session to open.
    expect(
      resolveChatAgent(
        stale.host,
        agents,
        location: ChatSessionLocation(
          herdrWorkspaceId: focus.workspaceOf(stale) ?? '',
        ),
      ),
      isA<ChatAgentAmbiguous>().having((m) => m.elsewhere, 'elsewhere', true),
    );

    final location = await chatSessionLocation(stale, focus);
    expect(location.herdrWorkspaceId, 'w1D');
    expect(location.herdrPaneId, 'w1D:p1');
    final match = resolveChatAgent(stale.host, agents, location: location);
    expect(
      match,
      isA<ChatAgentMatched>().having((m) => m.agent.pane, 'pane', 'w1D:p1'),
    );
  });

  test('a pinned tab keeps its own workspace for Chat View', () async {
    final pinned = open(
      const ConnectTarget.herdr(workspaceId: 'w12', label: 'Projects'),
    );
    await pinned.connect();
    await settle();
    server.focusPaneFromElsewhere('w1D:p1');

    final location = await chatSessionLocation(pinned, focus);
    expect(location.herdrWorkspaceId, 'w12');
    expect(location.herdrPaneId, isEmpty);
  });

  group('a tab whose workspace was closed', () {
    Future<TerminalSessionController> openStale() async {
      final stale = open(
        const ConnectTarget.herdr(workspaceId: 'wE', label: 'DTech'),
      );
      await stale.connect();
      await settle();
      return stale;
    }

    test('says so instead of silently mirroring Herdr', () async {
      final stale = await openStale();
      expect(focus.closedWorkspaces.value, {stale});

      // Kept on a workspace by hand: no longer closed.
      server.focusPaneFromElsewhere('w1D:p1');
      expect(await focus.useShownWorkspace(stale), isTrue);
      expect(focus.workspaceOf(stale), 'w1D');
      expect(focus.closedWorkspaces.value, isEmpty);
    });

    test('is not pinned to whatever Herdr showed when it is left', () async {
      final stale = await openStale();
      // The laptop moves Herdr to another "Projects" workspace; the stale
      // tab only mirrored it, the user never went there.
      server.focusPaneFromElsewhere('w1D:p1');
      final other = open(
        const ConnectTarget.herdr(workspaceId: 'w12', label: 'Projects'),
      );
      await other.connect();
      await settle();

      expect(focus.workspaceOf(stale), isNull);
      expect(focus.closedWorkspaces.value, {stale});

      // Coming back to it moves Herdr nowhere.
      server.commands.clear();
      workspace.activate(stale);
      await settle();
      expect(
        server.herdrArgs.where((args) => args.contains('focus')),
        isEmpty,
      );
    });

    test('is noticed while this device may not move the focus', () async {
      await focus.dispose();
      focus = HerdrSessionFocus(
        workspace: workspace,
        runnerFactory: (_) => server.runner(),
        reattachRefocusDelay: Duration.zero,
      );
      final stale = await openStale();
      workspace.activate(stale);
      await settle();
      expect(focus.closedWorkspaces.value, {stale});
      expect(focus.workspaceOf(stale), isNull);
    });
  });
}
