import 'dart:async';

import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/hosts/presentation/hosts_controller.dart';
import 'package:conduit/features/sessions/domain/connect_preferences.dart';
import 'package:conduit/features/sessions/presentation/session_connect_flow.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';
import '../terminal/herdr/fake_herdr_runner.dart';

/// Saving the host list takes until [release] (Android's encrypted
/// storage can take a while).
class _SlowHostsRepository extends FakeHostsRepository {
  final release = Completer<void>();

  @override
  Future<void> saveHosts(List<SavedHost> hosts) async {
    await release.future;
    await super.saveHosts(hosts);
  }
}

void main() {
  final host = buildHost('h');
  late _SlowHostsRepository repository;
  late TerminalWorkspaceController workspace;
  late SessionConnectFlow flow;

  setUp(() {
    repository = _SlowHostsRepository()..persisted = [host];
    workspace = TerminalWorkspaceController(NoNetworkTerminalRepository());
    flow = SessionConnectFlow(
      hostsController: HostsController(repository),
      workspace: workspace,
      runnerFactory: (_) => FakeHerdrRunner(FakeHerdrRunner.panesResponse),
      preferences: InMemoryConnectPreferencesRepository(),
    );
  });

  tearDown(() async {
    if (!repository.release.isCompleted) repository.release.complete();
    await flow.herdr.dispose();
    workspace.dispose();
  });

  // CON-058: opening a workspace waited for the host list to be saved
  // (its "last connected" stamp) before the terminal showed.
  test('a Herdr workspace opens before the host list is saved', () async {
    await flow.hostsController.load();
    final session = await flow
        .openAgentLocation(host, workspaceId: 'w2')
        .timeout(const Duration(seconds: 1));
    expect(session, isNotNull);
    expect(workspace.sessions, [session]);

    repository.release.complete();
    await pumpEventQueue();
    expect(repository.persisted.single.lastConnectedAt, isNotNull);
  });

  test('a tmux agent opens before the host list is saved', () async {
    await flow.hostsController.load();
    final session = await flow
        .openAgent(
          host,
          const AgentInfo(
            id: 'a',
            name: 'api',
            state: AgentAttentionState.needsInput,
            workspace: '/srv/api',
            tab: 'work:2',
            pane: '%12',
          ),
        )
        .timeout(const Duration(seconds: 1));
    expect(session, isNotNull);
  });
}
