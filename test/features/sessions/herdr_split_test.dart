import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
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

/// CON-095: two agents side by side in Herdr's own split (one workspace,
/// one tab, panes w1:p1 and w1:p2). A phone-sized Herdr client shows only
/// the focused pane, so opening the other half must not land on the one
/// Herdr has focused.
void main() {
  late SharedFocusHerdrServer server;
  late TerminalWorkspaceController workspace;
  late SessionConnectFlow flow;
  var mayMove = false;
  final host = buildHost('dev');

  AgentInfo agent(String pane) => AgentInfo(
    id: pane,
    name: pane,
    state: AgentAttentionState.needsInput,
    workspace: 'w1',
    tab: 'w1:t1',
    pane: pane,
  );

  setUp(() {
    mayMove = false;
    server = SharedFocusHerdrServer(workspaces: ['w1', 'w2'])
      ..splits['w1'] = ['w1:p2']
      ..agentPanes.addAll({'w1:p1', 'w1:p2'});
    // The laptop shows the split with its left half focused.
    server.focusPaneFromElsewhere('w1:p1');
    workspace = TerminalWorkspaceController(server.clients);
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
    flow.dispose();
    await flow.herdr.dispose();
    workspace.dispose();
  });

  Future<void> settle() async {
    for (var i = 0; i < 12; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<TerminalSessionController> open(String pane) async {
    final session = (await flow.openAgent(host, agent(pane)))!;
    if (session.shouldConnect) await session.connect();
    await settle();
    return session;
  }

  bool agentView(TerminalSessionController session) =>
      flow.herdr.agentViews.value.contains(session);

  String preview(TerminalSessionController session) =>
      session.sharedView.value?.preview.lines.join('\n') ?? '';

  group('"Phone may move Herdr focus" off', () {
    test('each half opens on its own pane', () async {
      final left = await open('w1:p1');
      expect(left.host.id, 'dev#herdr:w1');
      expect(agentView(left), isFalse, reason: 'Herdr shows w1:p1: live');
      expect(left.focusElsewhere.value, isNull);

      final unwatch = left.watchSharedView();
      addTearDown(unwatch);
      final right = await open('w1:p2');
      await settle();

      // One app tab per workspace, now at the right half.
      expect(right, left);
      expect(workspace.sessions, hasLength(1));
      // Not the live screen, which shows w1:p1: its own pane, read-only.
      expect(agentView(right), isTrue);
      expect(right.focusElsewhere.value, 'another pane of Ww1');
      expect(preview(right), contains('screen of w1 (w1:p2)'));

      // Typed keys never reach the left half; the composer reaches the
      // right one.
      right.sendText('y');
      await settle();
      expect(server.typedPanes, isEmpty);
      expect(right.inputHold.value, isA<InputHoldBlocked>());
      await right.sendComposed('go on', submit: true);
      await Future<void>.delayed(
        TerminalSessionController.composedEnterDelay * 2,
      );
      expect(server.events, contains('prompt w1:p2: go on'));
      expect(server.paneTyped.containsKey('w1:p1'), isFalse);

      // Nothing moved the laptop's focus.
      expect(server.focusedPaneOf('w1'), 'w1:p1');
      expect(server.herdrArgs.where((args) => args.contains('focus')), isEmpty);

      // "Take focus once" shows the right half here and sends the key.
      expect(await flow.herdr.takeFocusOnce(right), isTrue);
      await settle();
      expect(server.focusedPaneOf('w1'), 'w1:p2');
      expect(server.typedPanes, {'w1:p2': 'y'});
      expect(agentView(right), isFalse);
      expect(right.focusElsewhere.value, isNull);

      // The left half again: now it is the one Herdr does not show.
      await open('w1:p1');
      expect(agentView(left), isTrue);
      expect(left.focusElsewhere.value, 'another pane of Ww1');
      expect(preview(left), contains('screen of w1 (w1:p1)'));
    });

    test('the half Herdr already shows opens live', () async {
      server.focusPaneFromElsewhere('w1:p2');
      final right = await open('w1:p2');
      expect(agentView(right), isFalse);
      expect(right.focusElsewhere.value, isNull);
      right.sendText('x');
      await settle();
      expect(server.typedPanes, {'w1:p2': 'x'});
    });

    test('opening the workspace itself shows what Herdr shows', () async {
      final session = await open('w1:p2');
      expect(agentView(session), isTrue);
      final opened = await flow.openAgentLocation(
        host,
        workspaceId: 'w1',
        label: 'Ww1',
      );
      await settle();
      expect(opened, session);
      expect(ConnectTarget.fromSessionHostId(opened!.host.id)?.name, 'w1');
      expect(agentView(session), isFalse);
      expect(session.focusElsewhere.value, isNull);
    });
  });

  test('"Phone may move Herdr focus" on: each open focuses its pane', () async {
    mayMove = true;
    final left = await open('w1:p1');
    expect(server.focusedPaneOf('w1'), 'w1:p1');
    final right = await open('w1:p2');
    expect(right, left);
    expect(server.focusedPaneOf('w1'), 'w1:p2');
    await open('w1:p1');
    expect(server.focusedPaneOf('w1'), 'w1:p1');
    expect(agentView(left), isFalse);
  });

  group('tmux', () {
    late _SplitTmux tmux;

    setUp(() async {
      await flow.herdr.dispose();
      flow.dispose();
      // Window work:2 split into %12 (left) and %13 (right).
      tmux = _SplitTmux(window: 'work:2', panes: ['%12', '%13']);
      flow = SessionConnectFlow(
        hostsController: HostsController(
          FakeHostsRepository()..persisted = [host],
        ),
        workspace: workspace,
        runnerFactory: (_) => tmux,
        preferences: InMemoryConnectPreferencesRepository(),
      );
    });

    AgentInfo tmuxAgent(String pane) => AgentInfo(
      id: pane,
      name: pane,
      state: AgentAttentionState.needsInput,
      workspace: '/srv/api',
      tab: 'work:2',
      pane: pane,
    );

    test('each pane of a split opens selected', () async {
      final left = await flow.openAgent(host, tmuxAgent('%12'));
      await settle();
      expect(tmux.activePane, '%12');
      final right = await flow.openAgent(host, tmuxAgent('%13'));
      await settle();
      // The tab attached to the tmux session, now on the right pane.
      expect(right, left);
      expect(right!.host.id, 'dev#tmux:work');
      expect(tmux.activePane, '%13');
      await flow.openAgent(host, tmuxAgent('%12'));
      await settle();
      expect(tmux.activePane, '%12');
    });
  });
}

/// One tmux window split into [panes], the last one active:
/// `select-pane -t %N` makes that pane the active one, which an attached
/// client shows and types into.
class _SplitTmux implements AgentCommandRunner {
  _SplitTmux({required this.window, required this.panes})
    : activePane = panes.last;

  final String window;
  final List<String> panes;
  String activePane;

  static final _selectPane = RegExp(r'select-pane -t [^%]*(%\d+)');

  @override
  Future<AgentCommandResult> run(
    String command, {
    required Duration timeout,
  }) async {
    final pane = _selectPane.firstMatch(command)?.group(1);
    if (pane != null && panes.contains(pane)) {
      activePane = pane;
      return const AgentCommandResult(stdout: '', stderr: '', exitCode: 0);
    }
    return const AgentCommandResult(
      stdout: '',
      stderr: "can't find pane",
      exitCode: 1,
    );
  }

  @override
  Future<void> close() async {}
}
