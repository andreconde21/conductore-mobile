import 'dart:io';

import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/terminal/domain/tmux_navigator.dart';
import 'package:flutter_test/flutter_test.dart';

import '../herdr/fake_herdr_runner.dart';

/// `TmuxCommands.listing` as tmux 3.4 printed it on an isolated server with
/// one client attached to `s2` (two sessions, a split window "editor").
final _fixture = File(
  'test/features/terminal/tmux/fixtures/tmux_3.4_listing.txt',
).readAsStringSync();

AgentCommandResult _ok(String stdout) =>
    AgentCommandResult(stdout: stdout, stderr: '', exitCode: 0);

/// The command body after the PATH wrapper, unescaped for readability.
String _body(String command) {
  final start = command.indexOf('exec tmux ');
  expect(start, isNot(-1), reason: command);
  return command
      .substring(start + 'exec '.length, command.length - 1)
      .replaceAll(r"'\''", "'");
}

void main() {
  group('TmuxNavigator.parse', () {
    test('reads clients and panes from real tmux 3.4 output', () {
      final snapshot = TmuxNavigator.parse(_fixture);

      expect(snapshot.clients, const [
        TmuxClient(
          name: '/dev/pts/30',
          sessionName: 's2',
          sessionId: r'$1',
          windowId: '@1',
          paneId: '%1',
          activity: 1790328009,
        ),
      ]);
      expect(snapshot.panes, hasLength(9));
      final claude = snapshot.panes.firstWhere((pane) => pane.paneId == '%7');
      expect(claude.sessionName, 's1');
      expect(claude.windowIndex, 0);
      expect(claude.windowName, 'editor');
      expect(claude.paneIndex, 1);
      expect(claude.current, isTrue);
      expect(claude.title, 'claude: fix auth');
      expect(claude.command, 'bash');
      expect(claude.path, '/tmp/claude-0/tt/a');
      expect(claude.location, 's1 › 0:editor › pane 1');
    });

    test('keeps a separator inside a pane title', () {
      final snapshot = TmuxNavigator.parse(
        'P\t\$0\ts\t@0\t0\t1\t%0\t0\t1\t0\tbash\t/\t'
        'w\ta\tb',
      );
      expect(snapshot.panes.single.title, 'a\tb');
    });

    test('interprets a missing tmux, no server and other failures', () {
      expect(
        TmuxNavigator.interpret(
          const AgentCommandResult(
            stdout: '',
            stderr: 'sh: 1: exec: tmux: not found',
            exitCode: 127,
          ),
        ),
        isA<TmuxNotFound>(),
      );
      expect(
        TmuxNavigator.interpret(
          const AgentCommandResult(
            stdout: '',
            stderr: 'no server running on /tmp/tmux-0/default',
            exitCode: 1,
          ),
        ),
        isA<TmuxNotRunning>(),
      );
      expect(
        TmuxNavigator.interpret(
          const AgentCommandResult(stdout: '', stderr: 'boom', exitCode: 1),
        ),
        isA<TmuxListingFailed>(),
      );
    });
  });

  group('client targeting', () {
    const phone = TmuxClient(
      name: '/dev/pts/4',
      sessionName: 'conduit',
      sessionId: r'$2',
      windowId: '@7',
      paneId: '%11',
      activity: 200,
    );
    const laptopSameSession = TmuxClient(
      name: '/dev/pts/1',
      sessionName: 'conduit',
      sessionId: r'$2',
      windowId: '@3',
      paneId: '%4',
      activity: 100,
    );
    const laptopOther = TmuxClient(
      name: '/dev/pts/2',
      sessionName: 'work',
      sessionId: r'$0',
      windowId: '@1',
      paneId: '%1',
      activity: 900,
    );

    test('picks the most recently active client on the app session', () {
      const snapshot = TmuxSnapshot(
        clients: [laptopSameSession, laptopOther, phone],
      );
      expect(snapshot.clientFor('conduit'), phone);
      expect(
        snapshot.targetFor('conduit'),
        const TmuxTarget(
          clientName: '/dev/pts/4',
          sessionId: r'$2',
          windowId: '@7',
          paneId: '%11',
        ),
      );
    });

    test('falls back to the most recent client of any session', () {
      const snapshot = TmuxSnapshot(clients: [laptopSameSession, laptopOther]);
      expect(snapshot.clientFor('elsewhere'), laptopOther);
    });

    test('without clients, targets the current pane of the session', () {
      const snapshot = TmuxSnapshot(
        panes: [
          TmuxPaneEntry(
            sessionId: r'$2',
            sessionName: 'conduit',
            windowId: '@7',
            windowIndex: 1,
            windowName: 'bash',
            paneId: '%10',
          ),
          TmuxPaneEntry(
            sessionId: r'$2',
            sessionName: 'conduit',
            windowId: '@7',
            windowIndex: 1,
            windowName: 'bash',
            paneId: '%11',
            paneIndex: 1,
            windowActive: true,
            paneActive: true,
          ),
        ],
      );
      expect(
        snapshot.targetFor('conduit'),
        const TmuxTarget(sessionId: r'$2', windowId: '@7', paneId: '%11'),
      );
      expect(snapshot.targetFor('missing'), isNull);
    });
  });

  group('TmuxCommands (verified on tmux 3.4)', () {
    const target = TmuxTarget(
      clientName: '/dev/pts/4',
      sessionId: r'$2',
      windowId: '@7',
      paneId: '%11',
    );

    test('lists clients and panes in one tmux invocation', () {
      final body = _body(TmuxCommands.listing);
      expect(body, startsWith('tmux -u list-clients -F "\$(printf \'C\\t'));
      expect(body, contains("';' list-panes -a -F"));
      expect(body, contains(r'#{pane_current_command}\t'));
    });

    test('quick actions target the client pane, window and tty', () {
      String? body(TmuxQuickAction action) {
        final command = TmuxCommands.action(action, target);
        return command == null ? null : _body(command);
      }

      expect(
        body(TmuxQuickAction.splitRight),
        "tmux -u split-window -h -t '%11' -c '#{pane_current_path}'",
      );
      expect(
        body(TmuxQuickAction.splitDown),
        "tmux -u split-window -v -t '%11' -c '#{pane_current_path}'",
      );
      expect(
        body(TmuxQuickAction.newWindow),
        "tmux -u new-window -a -t '@7' -c '#{pane_current_path}'",
      );
      expect(body(TmuxQuickAction.zoom), "tmux -u resize-pane -Z -t '%11'");
      expect(body(TmuxQuickAction.killPane), "tmux -u kill-pane -t '%11'");
      expect(
        body(TmuxQuickAction.detach),
        "tmux -u detach-client -t '/dev/pts/4'",
      );
    });

    test('detach needs a client', () {
      expect(
        TmuxCommands.action(
          TmuxQuickAction.detach,
          const TmuxTarget(sessionId: r'$2', windowId: '@7', paneId: '%11'),
        ),
        isNull,
      );
    });

    test('window N, neighbour panes and pane focus', () {
      expect(
        _body(TmuxCommands.selectWindow(target, 3)),
        r"tmux -u select-window -t '$2:3'",
      );
      expect(
        _body(TmuxCommands.selectPane(target, 'L')),
        "tmux -u select-pane -L -t '%11'",
      );
      expect(
        _body(TmuxCommands.focusPane('%3', clientName: '/dev/pts/4')),
        "tmux -u switch-client -c '/dev/pts/4' -t '%3'",
      );
      expect(
        _body(TmuxCommands.focusPane('%3')),
        "tmux -u select-window -t '%3' ';' select-pane -t '%3'",
      );
    });
  });

  group('TmuxNavigator over a scripted runner', () {
    FakeHerdrRunner scripted({int actionExit = 0}) =>
        FakeHerdrRunner((command) {
          if (command.contains('list-clients')) {
            return _ok(_fixture);
          }
          return AgentCommandResult(
            stdout: '',
            stderr: actionExit == 0 ? '' : "can't find pane",
            exitCode: actionExit,
          );
        });

    test('a quick action resolves the client, then runs one command', () async {
      final runner = scripted();

      expect(
        await TmuxNavigator.perform(
          runner,
          TmuxQuickAction.splitRight,
          sessionName: 's2',
        ),
        isTrue,
      );
      expect(runner.commands, hasLength(2));
      expect(runner.commands[0], contains('list-clients'));
      expect(
        _body(runner.commands[1]),
        "tmux -u split-window -h -t '%1' -c '#{pane_current_path}'",
      );
    });

    test('a known target skips the listing', () async {
      final runner = scripted();
      const target = TmuxTarget(
        clientName: '/dev/pts/30',
        sessionId: r'$1',
        windowId: '@1',
        paneId: '%1',
      );

      await TmuxNavigator.selectWindow(runner, 2, target: target);
      await TmuxNavigator.focus(
        runner,
        TmuxNavigator.parse(_fixture).panes.first,
        target: target,
      );

      expect(runner.commands.map(_body), [
        r"tmux -u select-window -t '$1:2'",
        "tmux -u switch-client -c '/dev/pts/30' -t '%8'",
      ]);
    });

    test('reports failure so the caller can fall back to keys', () async {
      expect(
        await TmuxNavigator.perform(
          scripted(actionExit: 1),
          TmuxQuickAction.zoom,
          sessionName: 's2',
        ),
        isFalse,
      );
      final noServer = FakeHerdrRunner(
        (_) => const AgentCommandResult(
          stdout: '',
          stderr: 'no server running on /tmp/tmux-0/default',
          exitCode: 1,
        ),
      );
      expect(
        await TmuxNavigator.perform(
          noServer,
          TmuxQuickAction.zoom,
          sessionName: 's2',
        ),
        isFalse,
      );
      expect(noServer.commands, hasLength(1));
    });

    test('deep links select the window and pane of the session', () async {
      final runner = scripted();
      expect(await TmuxNavigator.focusAgentPane(runner, '%7'), isTrue);
      expect(
        _body(runner.commands.single),
        "tmux -u select-window -t '%7' ';' select-pane -t '%7'",
      );
    });
  });

  group('TmuxAgentLocation', () {
    test('reads the companion tmux location', () {
      expect(
        TmuxAgentLocation.parse(tab: 'work:3', pane: '%12'),
        const TmuxAgentLocation(sessionName: 'work', paneId: '%12'),
      );
      expect(
        TmuxAgentLocation.parse(tab: 'work', pane: '%12'),
        const TmuxAgentLocation(sessionName: 'work', paneId: '%12'),
      );
    });

    test('ignores Herdr locations and incomplete ones', () {
      expect(TmuxAgentLocation.parse(tab: 'w1:t1', pane: 'w1:p2'), isNull);
      expect(TmuxAgentLocation.parse(pane: '%12'), isNull);
      expect(TmuxAgentLocation.parse(tab: 'work:1'), isNull);
    });
  });
}
