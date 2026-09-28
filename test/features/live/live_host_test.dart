import 'dart:async';
import 'dart:convert';

import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/hosts/presentation/home_board_controller.dart';
import 'package:conduit/features/live/domain/live_host_model.dart';
import 'package:conduit/features/live/presentation/live_host_hub.dart';
import 'package:conduit/features/terminal/domain/multiplexer_tabs.dart';
import 'package:conduit/features/terminal/presentation/multiplexer_tabs_controller.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';
import '../hosts/home_board_fakes.dart';

/// A companion that pushes: `status --live` answers [LiveFixtures.status],
/// `events --live` hands out the queued lines (else waits and times out).
class LiveCompanion implements AgentCommandRunner {
  LiveCompanion({this.status = LiveFixtures.status});

  final String status;
  final List<String> commands = [];
  final List<Completer<String>> _waiting = [];
  final List<String> queued = [];
  int seq = 7;

  void push(String line) {
    if (_waiting.isNotEmpty) {
      _waiting.removeAt(0).complete('$line\n');
    } else {
      queued.add(line);
    }
  }

  @override
  Future<AgentCommandResult> run(
    String command, {
    required Duration timeout,
  }) async {
    commands.add(command);
    if (command.contains('status --live')) {
      return AgentCommandResult(stdout: status, stderr: '', exitCode: 0);
    }
    if (command.contains('events') && command.contains('--live')) {
      if (queued.isNotEmpty) {
        return AgentCommandResult(
          stdout: '${queued.removeAt(0)}\n',
          stderr: '',
          exitCode: 0,
        );
      }
      final waiter = Completer<String>();
      _waiting.add(waiter);
      final out = await waiter.future.timeout(
        const Duration(seconds: 55),
        onTimeout: () => '{"type":"timeout","seq":$seq}\n',
      );
      _waiting.remove(waiter);
      return AgentCommandResult(stdout: out, stderr: '', exitCode: 0);
    }
    return const AgentCommandResult(stdout: '', stderr: '', exitCode: 0);
  }

  @override
  Future<void> close() async {}
}

String liveLine(int seq, String key, Map<String, Object?>? entity) =>
    jsonEncode({'seq': seq, 'type': 'live', 'key': key, 'entity': entity});

void main() {
  final status = jsonDecode(LiveFixtures.status) as Map<String, Object?>;
  final model = LiveHostModel.fromEntities(
    (status['live']! as Map<String, Object?>)['entities']! as Map,
  );

  group('LiveHostModel', () {
    test('workspaces in Herdr order, with their tabs and what they show', () {
      final workspaces = model.workspaces();
      expect(workspaces.map((w) => w.label), ['Infrastructure', 'TheCalendar']);
      expect(workspaces.first.tabs.map((t) => t.label), ['main', 'review']);
      expect(workspaces.first.tabs.first.paneTitle, 'Deploying images');
      expect(workspaces.first.tabs.first.paneAgent, 'claude');
      expect(workspaces.first.focused, isTrue);
    });

    test('agent panes with their kinds and states', () {
      final agents = {for (final a in model.herdrAgents()) a.pane: a};
      expect(agents['w1:p2']!.state, AgentAttentionState.needsInput);
      expect(agents['w1:p1']!.state, AgentAttentionState.working);
      expect(agents['w2:p1']!.kind, 'codex');
      expect(agents['w2:p1']!.state, AgentAttentionState.finished);
      expect(agents['w2:p1']!.name, 'Nightly E2E');
      expect(agents['w2:p1']!.stateSequence, 1);
    });

    test("the strip shows the focused tab's workspace, the active tab on", () {
      final tabs = model.herdrStripTabs()!;
      expect(tabs.map((t) => t.label), ['main', 'review']);
      expect(tabs.first.active, isTrue);
      expect(tabs[1].status, AgentAttentionState.needsInput);
    });

    test('tmux sessions and windows', () {
      expect(model.tmuxSessions().single.name, 'main');
      expect(model.tmuxSessions().single.attachedClients, 1);
      final windows = model.tmuxWindows('main')!;
      expect(windows.map((w) => w.label), ['zsh', 'claude']);
      expect(windows[1].active, isTrue);
      expect(windows[1].id, '@2');
      expect(model.tmuxWindows('nope'), isNull);
    });

    test('a tmux server not pushed by choice reads as off', () {
      final off = LiveHostModel.fromEntities(
        ((jsonDecode(LiveFixtures.statusTmuxOff)
                    as Map<String, Object?>)['live']!
                as Map<String, Object?>)['entities']!
            as Map,
      );
      expect(off.serverState('tmux'), LiveServerState.off);
      expect(off.tmuxSessions(), isEmpty);
      expect(off.serverState('herdr'), LiveServerState.up);
    });

    test('changes apply in order; null removes', () {
      final next = model.apply([
        const LiveChange(sequence: 8, key: 'pane:herdr:w2:p1', entity: null),
        const LiveChange(
          sequence: 9,
          key: 'srv:herdr',
          entity: {'kind': 'server', 'id': 'herdr', 'state': 'down'},
        ),
      ]);
      expect(next.herdrAgents().map((a) => a.pane), ['w1:p1', 'w1:p2']);
      expect(next.serverState('herdr'), LiveServerState.down);
      expect(model.serverState('herdr'), LiveServerState.up);
    });

    test('Herdr-only agents are told apart by their target id', () {
      AgentInfo agent(String id) =>
          AgentInfo(id: id, name: 'x', state: AgentAttentionState.idle);
      expect(isHerdrOnlyAgent(agent('herdr/w1:p2')), isTrue);
      expect(isHerdrOnlyAgent(agent('herdr@work/w3:p1')), isTrue);
      expect(isHerdrOnlyAgent(agent('4f0c-uuid')), isFalse);
      expect(isHerdrOnlyAgent(agent('w1:p2')), isFalse);
    });
  });

  group('parseLiveEvents', () {
    test('live lines, a snapshot replacing what came before, a timeout', () {
      final parsed = parseLiveEvents(
        [
          liveLine(8, 'pane:herdr:w1:p1', {'kind': 'pane', 'id': 'w1:p1'}),
          '{"seq":9,"type":"change","sessionId":"s-1","agent":{}}',
          '{"type":"snapshot","seq":12,"agents":[],"live":{"entities":{}}}',
          liveLine(13, 'srv:tmux', null),
          'not json',
        ].join('\n'),
      );
      expect(parsed.snapshotSequence, 12);
      expect(parsed.snapshot!.entities, isEmpty);
      expect(parsed.changes.single.key, 'srv:tmux');
      expect(parsed.changes.single.entity, isNull);
      expect(
        parseLiveEvents('{"type":"timeout","seq":40}').timeoutSequence,
        40,
      );
    });
  });

  group('LiveHostFeed', () {
    test('status, then long-polls that apply pushed changes', () {
      fakeAsync((async) {
        final companion = LiveCompanion();
        final feed = LiveHostFeed(
          host: buildHost('m'),
          runnerFactory: () => companion,
        );
        final release = feed.acquire();
        async.flushMicrotasks();
        expect(feed.support, LiveSupport.supported);
        expect(feed.model.workspaces(), hasLength(2));
        companion.push(liveLine(8, 'ws:herdr:w2', null));
        async.elapse(const Duration(seconds: 1));
        expect(feed.model.workspaces(), hasLength(1));
        // A quiet minute costs one long-poll.
        final before = companion.commands.length;
        async.elapse(const Duration(minutes: 1));
        expect(companion.commands.length - before, lessThanOrEqualTo(2));
        expect(
          companion.commands.last,
          contains('events --since 8 --timeout 55 --live --only live'),
        );
        release();
        async.elapse(const Duration(minutes: 2));
        final after = companion.commands.length;
        async.elapse(const Duration(minutes: 5));
        expect(companion.commands.length, after, reason: 'released: silent');
        feed.dispose();
      });
    });

    test('an older companion (no live block) is unsupported: callers poll', () {
      fakeAsync((async) {
        final companion = LiveCompanion(
          status: '{"version":1,"seq":3,"agents":[]}',
        );
        final feed = LiveHostFeed(
          host: buildHost('m'),
          runnerFactory: () => companion,
        );
        feed.acquire();
        async.flushMicrotasks();
        expect(feed.support, LiveSupport.unsupported);
        async.elapse(const Duration(minutes: 1));
        expect(companion.commands, hasLength(1));
        feed.dispose();
      });
    });
  });

  group('home board', () {
    test('draws the pushed model and runs no herdr or tmux command', () {
      fakeAsync((async) {
        final companion = LiveCompanion();
        final hub = LiveHostHub(runnerFactory: (_) => companion);
        final board = HomeBoardController(
          runnerFactory: (_) => companion,
          liveFeed: hub.feedFor,
        )..selectHost(buildHost('m'), connectedBefore: true);
        board.setVisible(true);
        async.elapse(const Duration(seconds: 1));
        expect(board.live, isTrue);
        expect(board.state.phase, HomeBoardPhase.ready);
        expect(board.state.workspaces.map((w) => w.label), [
          'Infrastructure',
          'TheCalendar',
        ]);
        expect(board.state.attentionCount, 1);
        expect(board.state.tmuxSessions.single.name, 'main');
        async.elapse(const Duration(minutes: 2));
        expect(
          companion.commands.where(
            (c) => c.contains('herdr ') || c.contains('tmux list'),
          ),
          isEmpty,
        );
        // Herdr stops: the board says so, pushed.
        companion.push(
          liveLine(9, 'srv:herdr', {
            'kind': 'server',
            'id': 'herdr',
            'state': 'down',
          }),
        );
        async.elapse(const Duration(seconds: 1));
        expect(board.state.phase, HomeBoardPhase.notRunning);
        board.dispose();
        hub.dispose();
      });
    });

    test('tmux-live off (the default): Herdr pushed, tmux listed by the board, '
        'backing off while quiet', () {
      fakeAsync((async) {
        final companion = _TmuxOffCompanion();
        final hub = LiveHostHub(runnerFactory: (_) => companion);
        final board = HomeBoardController(
          runnerFactory: (_) => companion,
          liveFeed: hub.feedFor,
        )..selectHost(buildHost('m'), connectedBefore: true);
        board.setVisible(true);
        async.elapse(const Duration(seconds: 1));
        expect(board.live, isTrue);
        expect(board.state.phase, HomeBoardPhase.ready);
        expect(board.state.workspaces, hasLength(2));
        expect(board.state.tmuxSessions.map((s) => s.name), ['main', 'build']);
        int tmuxPolls() =>
            companion.commands.where((c) => c.contains('tmux list')).length;
        async.elapse(const Duration(minutes: 2));
        final settled = tmuxPolls();
        async.elapse(const Duration(minutes: 1));
        // 12 a minute at 5 s, 3 once quiet (20 s).
        final perMinute = tmuxPolls() - settled;
        expect(perMinute, lessThanOrEqualTo(4));
        expect(companion.commands.where((c) => c.contains('herdr ')), isEmpty);
        board.dispose();
        hub.dispose();
      });
    });

    test('an older companion: the board polls as before', () {
      fakeAsync((async) {
        final runner = HerdrFakeRunner(tmuxSessions: TmuxFixtures.sessions);
        final hub = LiveHostHub(runnerFactory: (_) => runner);
        final board = HomeBoardController(
          runnerFactory: (_) => runner,
          liveFeed: hub.feedFor,
        )..selectHost(buildHost('m'), connectedBefore: true);
        board.setVisible(true);
        async.elapse(const Duration(seconds: 1));
        expect(board.live, isFalse);
        expect(board.state.phase, HomeBoardPhase.ready);
        expect(
          runner.commands.where((c) => c.contains('workspace list')),
          isNotEmpty,
        );
        board.dispose();
        hub.dispose();
      });
    });
  });

  group('tab strip', () {
    test('tmux not pushed (tmux-live off): the strip polls tmux itself', () {
      fakeAsync((async) {
        final companion = LiveCompanion(status: LiveFixtures.statusTmuxOff);
        final feed = LiveHostFeed(
          host: buildHost('m'),
          runnerFactory: () => companion,
        );
        final backend = _CountingBackend();
        final tabs = MultiplexerTabsController(
          backend: backend,
          live: MultiplexerLiveTabs(
            feed: feed,
            read: (model) => model.tmuxWindows('main'),
            server: LiveHostModel.tmuxServerId,
          ),
        )..setVisible(true);
        async.elapse(const Duration(seconds: 10));
        expect(backend.lists, greaterThanOrEqualTo(4));
        tabs.dispose();
        feed.dispose();
      });
    });

    test('pushed windows replace the 2 s poll', () {
      fakeAsync((async) {
        final companion = LiveCompanion();
        final feed = LiveHostFeed(
          host: buildHost('m'),
          runnerFactory: () => companion,
        );
        final backend = _CountingBackend();
        final tabs = MultiplexerTabsController(
          backend: backend,
          live: MultiplexerLiveTabs(
            feed: feed,
            read: (model) => model.tmuxWindows('main'),
          ),
        )..setVisible(true);
        async.elapse(const Duration(seconds: 1));
        expect(tabs.tabs.map((t) => t.label), ['zsh', 'claude']);
        expect(tabs.active?.label, 'claude');
        companion.push(
          liveLine(8, r'twin:tmux:$0:@3', {
            'kind': 'tmuxWindow',
            'server': 'tmux',
            'id': '@3',
            'sessionId': r'$0',
            'session': 'main',
            'index': 2,
            'name': 'logs',
            'active': false,
          }),
        );
        async.elapse(const Duration(minutes: 1));
        expect(tabs.tabs.map((t) => t.label), ['zsh', 'claude', 'logs']);
        expect(backend.lists, 0);
        tabs.dispose();
        feed.dispose();
      });
    });
  });
}

class _CountingBackend implements MultiplexerTabsBackend {
  int lists = 0;

  @override
  MultiplexerTabsKind get kind => MultiplexerTabsKind.tmux;

  @override
  bool get canReorder => true;

  @override
  Future<List<MultiplexerTab>?> list() async {
    lists += 1;
    return const [];
  }

  @override
  Future<bool> select(MultiplexerTab tab) async => true;

  @override
  Future<bool> create({MultiplexerTab? active}) async => true;

  @override
  Future<bool> rename(MultiplexerTab tab, String name) async => true;

  @override
  Future<bool> close(MultiplexerTab tab) async => true;

  @override
  Future<bool> swap(
    MultiplexerTab tab,
    MultiplexerTab other, {
    MultiplexerTab? active,
  }) async => true;

  @override
  Future<void> dispose() async {}
}

/// A companion with `tmux-live` off that answers the board's own tmux
/// listing like tmux would.
class _TmuxOffCompanion extends LiveCompanion {
  _TmuxOffCompanion() : super(status: LiveFixtures.statusTmuxOff);

  @override
  Future<AgentCommandResult> run(String command, {required Duration timeout}) {
    if (command.contains('tmux list-sessions')) {
      commands.add(command);
      return Future.value(
        const AgentCommandResult(
          stdout: TmuxFixtures.sessions,
          stderr: '',
          exitCode: 0,
        ),
      );
    }
    return super.run(command, timeout: timeout);
  }
}
