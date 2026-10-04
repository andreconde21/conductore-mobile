import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/hosts/presentation/hosts_controller.dart';
import 'package:conduit/features/sessions/domain/connect_preferences.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:conduit/features/sessions/presentation/session_connect_flow.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';
import '../terminal/herdr/fake_herdr_runner.dart';

/// A companion (`conductore-hostd`) agent in tmux session `work`, window 2,
/// pane %12. Its `workspace` is the cwd, which is not a Herdr workspace.
const _agent = AgentInfo(
  id: 'session-uuid',
  name: 'api',
  state: AgentAttentionState.needsInput,
  workspace: '/srv/api',
  tab: 'work:2',
  pane: '%12',
);

void main() {
  late TerminalWorkspaceController workspace;
  late SessionConnectFlow flow;
  late List<FakeHerdrRunner> runners;
  final host = buildHost('h');

  setUp(() {
    runners = [];
    workspace = TerminalWorkspaceController(NoNetworkTerminalRepository());
    flow = SessionConnectFlow(
      hostsController: HostsController(
        FakeHostsRepository()..persisted = [host],
      ),
      workspace: workspace,
      runnerFactory: (_) {
        final runner = FakeHerdrRunner(FakeHerdrRunner.panesResponse);
        runners.add(runner);
        return runner;
      },
      preferences: InMemoryConnectPreferencesRepository(),
    );
  });

  tearDown(() async {
    await flow.herdr.dispose();
    workspace.dispose();
  });

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  /// The tmux command after the PATH wrapper, unescaped.
  String body(String command) => command
      .substring(command.indexOf('exec tmux ') + 'exec '.length)
      .replaceAll(r"'\''", "'")
      .replaceFirst(RegExp(r"'$"), '');

  test('activates the tab attached to the agent\'s tmux session, then '
      'selects its window and pane', () async {
    final tmuxTab = workspace.open(
      const ConnectTarget.tmux('work').apply(host),
    );
    workspace.open(const ConnectTarget.tmux('other').apply(host));
    workspace.open(const ConnectTarget.herdr(workspaceId: 'w1').apply(host));
    var requests = 0;
    flow.terminalRequests.addListener(() => requests += 1);

    final shown = await flow.openAgent(host, _agent);
    await settle();

    expect(shown, tmuxTab);
    expect(workspace.activeSession, tmuxTab);
    expect(requests, 1);
    // (The Herdr tab has its own focus channel.)
    final tmuxRunners = runners
        .where((runner) => runner.commands.any((c) => c.contains('tmux')))
        .toList();
    expect(tmuxRunners, hasLength(1));
    expect(
      body(tmuxRunners.single.commands.single),
      "tmux -u select-window -t '%12' ';' select-pane -t '%12'",
    );
    expect(tmuxRunners.single.closed, isTrue);
    // Never the Herdr path, which would have taken the cwd for a workspace.
    expect(
      workspace.sessions.where(
        (session) => session.host.id.contains('/srv/api'),
      ),
      isEmpty,
    );
  });

  test('a host that starts tmux on connect counts when its session '
      'matches', () async {
    final attached = workspace.open(
      host.copyWith(startTmuxOnConnect: true, tmuxSessionName: 'work'),
    );
    workspace.open(buildHost('other'));

    final shown = await flow.openAgent(host, _agent);

    expect(shown, attached);
    expect(workspace.activeSession, attached);
  });

  test('with no tab on that session it opens one on the tmux target', () async {
    workspace.open(host);

    final shown = await flow.openAgent(host, _agent);
    await settle();

    expect(shown, isNotNull);
    expect(shown!.host.id, 'h#tmux:work');
    expect(shown.host.startTmuxOnConnect, isTrue);
    expect(shown.host.tmuxSessionName, 'work');
    expect(workspace.activeSession, shown);
    expect(
      body(runners.single.commands.single),
      "tmux -u select-window -t '%12' ';' select-pane -t '%12'",
    );
  });

  test('security-key hosts switch tabs without a background channel', () async {
    final keyHost = host.copyWith(authMethod: SshAuthMethod.hardwareKey);
    final tmuxTab = workspace.open(
      const ConnectTarget.tmux('work').apply(keyHost),
    );

    final shown = await flow.openAgent(keyHost, _agent);

    expect(shown, tmuxTab);
    expect(runners, isEmpty);
  });

  test('Herdr locations still take the Herdr path', () async {
    await flow.openAgent(
      host,
      const AgentInfo(
        id: 'w1:p2',
        name: '',
        state: AgentAttentionState.unknown,
        workspace: 'w1',
        tab: 'w1:t1',
        pane: 'w1:p2',
      ),
    );

    expect(workspace.activeSession?.host.id, startsWith('h#herdr'));
  });
}
