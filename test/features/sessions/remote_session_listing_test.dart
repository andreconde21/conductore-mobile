import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/sessions/domain/remote_session_listing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('tmux listing', () {
    test('parses tab-separated sessions', () {
      final sessions = RemoteSessionListing.parseTmuxSessions(
        'root\t0\t1\t1790229500\n'
        'work session\t2\t4\t1790229600\n'
        '\n'
        'bare\n',
      );

      expect(sessions, hasLength(3));
      expect(sessions[0].name, 'root');
      expect(sessions[0].isAttached, isFalse);
      expect(sessions[0].windows, 1);
      expect(
        sessions[0].lastActivity,
        DateTime.fromMillisecondsSinceEpoch(1790229500 * 1000, isUtc: true),
      );
      expect(sessions[1].name, 'work session');
      expect(sessions[1].attachedClients, 2);
      expect(sessions[1].isAttached, isTrue);
      expect(sessions[1].windows, 4);
      expect(sessions[2].name, 'bare');
      expect(sessions[2].lastActivity, isNull);
    });

    test('treats a missing tmux server as an empty list', () {
      final listing = RemoteSessionListing.interpretTmux(
        const AgentCommandResult(
          stdout: '',
          stderr: 'no server running on /tmp/tmux-0/default',
          exitCode: 1,
        ),
      );
      expect(listing, isA<RemoteListingAvailable<TmuxSessionInfo>>());
      expect(
        (listing as RemoteListingAvailable<TmuxSessionInfo>).items,
        isEmpty,
      );
    });

    test('detects tmux not being installed', () {
      expect(
        RemoteSessionListing.interpretTmux(
          const AgentCommandResult(
            stdout: '',
            stderr: 'sh: 1: tmux: not found',
            exitCode: 127,
          ),
        ),
        isA<RemoteListingNotInstalled<TmuxSessionInfo>>(),
      );
    });

    test('reports other failures', () {
      final listing = RemoteSessionListing.interpretTmux(
        const AgentCommandResult(stdout: '', stderr: 'boom', exitCode: 3),
      );
      expect(listing, isA<RemoteListingFailed<TmuxSessionInfo>>());
      expect((listing as RemoteListingFailed<TmuxSessionInfo>).message, 'boom');
    });

    test('the tmux command produces one tab-separated line per session', () {
      expect(
        RemoteSessionListing.tmuxListCommand,
        startsWith('tmux -u list-sessions -F'),
      );
      expect(
        RemoteSessionListing.tmuxListCommand,
        contains(r'\t#{session_attached}'),
      );
    });
  });

  group('Herdr listing', () {
    // Captured from `herdr workspace list` on Herdr 0.9.1.
    const workspaceList =
        '{"id":"cli:workspace:list","result":{"type":"workspace_list",'
        '"workspaces":[{"active_tab_id":"w4:t4","agent_status":"idle",'
        '"focused":false,"label":"Infrastructure","number":1,"pane_count":1,'
        '"tab_count":2,"workspace_id":"w4"},{"active_tab_id":"wX:t1",'
        '"agent_status":"working","focused":true,"label":"Conductore-Mobile",'
        '"number":11,"pane_count":1,"tab_count":1,"workspace_id":"wX"}]}}';

    // Captured from `herdr tab list` on Herdr 0.9.1.
    const tabList =
        '{"id":"cli:tab:list","result":{"tabs":[{"agent_status":"idle",'
        '"focused":false,"label":"Infrastructure","number":4,"pane_count":1,'
        '"tab_id":"w4:t4","workspace_id":"w4"},{"agent_status":"blocked",'
        '"focused":false,"label":"Deploy","number":1,"pane_count":1,'
        '"tab_id":"w4:t1","workspace_id":"w4"},{"agent_status":"working",'
        '"focused":true,"label":"1","number":1,"pane_count":1,'
        '"tab_id":"wX:t1","workspace_id":"wX"}],"type":"tab_list"}}';

    test('parses the 0.9.1 workspace envelope', () {
      final workspaces = RemoteSessionListing.parseHerdrWorkspaces(
        workspaceList,
      );
      expect(workspaces, hasLength(2));
      expect(workspaces[0].id, 'w4');
      expect(workspaces[0].label, 'Infrastructure');
      expect(workspaces[0].number, 1);
      expect(workspaces[0].tabCount, 2);
      expect(workspaces[0].activeTabId, 'w4:t4');
      expect(workspaces[0].agentStatus, 'idle');
      expect(workspaces[0].focused, isFalse);
      expect(workspaces[1].id, 'wX');
      expect(workspaces[1].agentStatus, 'working');
      expect(workspaces[1].focused, isTrue);
    });

    test('accepts bare arrays and objects', () {
      expect(
        RemoteSessionListing.parseHerdrWorkspaces(
          '[{"workspace_id":"w1","label":"A"}]',
        ).single.label,
        'A',
      );
      expect(
        RemoteSessionListing.parseHerdrWorkspaces(
          '{"workspaces":[{"workspace_id":"w1"}]}',
        ).single.label,
        // Never the id.
        'Workspace',
      );
      expect(RemoteSessionListing.parseHerdrWorkspaces(''), isEmpty);
      expect(
        () => RemoteSessionListing.parseHerdrWorkspaces('not json'),
        throwsFormatException,
      );
    });

    test('parses tabs and attaches them to workspaces in number order', () {
      final workspaces = RemoteSessionListing.attachTabs(
        RemoteSessionListing.parseHerdrWorkspaces(workspaceList),
        RemoteSessionListing.parseHerdrTabs(tabList),
      );
      expect(workspaces[0].tabs.map((tab) => tab.id), ['w4:t1', 'w4:t4']);
      expect(workspaces[0].tabs.first.label, 'Deploy');
      expect(workspaces[0].tabs.first.agentStatus, 'blocked');
      expect(workspaces[1].tabs.map((tab) => tab.id), ['wX:t1']);
    });

    test('interprets not installed, not running and failures', () {
      expect(
        RemoteSessionListing.interpretHerdrWorkspaces(
          const AgentCommandResult(
            stdout: '',
            stderr: 'sh: herdr: command not found',
            exitCode: 127,
          ),
        ),
        isA<RemoteListingNotInstalled<HerdrWorkspaceInfo>>(),
      );
      expect(
        RemoteSessionListing.interpretHerdrWorkspaces(
          const AgentCommandResult(
            stdout:
                '{"error":{"code":"server_not_running","message":"no server"}}',
            stderr: '',
            exitCode: 1,
          ),
        ),
        isA<RemoteListingNotRunning<HerdrWorkspaceInfo>>(),
      );
      final failed = RemoteSessionListing.interpretHerdrWorkspaces(
        const AgentCommandResult(stdout: '', stderr: 'bad', exitCode: 1),
      );
      expect(failed, isA<RemoteListingFailed<HerdrWorkspaceInfo>>());
      expect(
        (failed as RemoteListingFailed<HerdrWorkspaceInfo>).message,
        'bad',
      );
      final available = RemoteSessionListing.interpretHerdrWorkspaces(
        const AgentCommandResult(
          stdout: workspaceList,
          stderr: '',
          exitCode: 0,
        ),
      );
      expect(available, isA<RemoteListingAvailable<HerdrWorkspaceInfo>>());
    });

    test('the herdr commands go through the PATH wrapper', () {
      expect(
        RemoteSessionListing.herdrWorkspaceListCommand,
        allOf(startsWith("sh -c '"), contains('exec herdr workspace list')),
      );
      expect(
        RemoteSessionListing.herdrTabListCommand,
        contains('exec herdr tab list'),
      );
    });
  });

  group('Herdr sessions', () {
    test('parses herdr session list --json from Herdr 0.9.1', () {
      final sessions = RemoteSessionListing.parseHerdrSessions(
        '{"sessions":[{"default":true,"name":"default","running":true,'
        '"session_dir":"/root/.config/herdr",'
        '"socket_path":"/root/.config/herdr/herdr.sock"},'
        '{"default":false,"name":"work","running":false}]}',
      );
      expect(sessions, const [
        HerdrSessionInfo(name: 'default', isDefault: true, running: true),
        HerdrSessionInfo(name: 'work'),
      ]);
      expect(sessions!.first.cliName, isEmpty);
      expect(sessions.last.cliName, 'work');
    });

    test('anything else means the session list is unknown', () {
      expect(RemoteSessionListing.parseHerdrSessions('usage: herdr'), isNull);
      expect(
        RemoteSessionListing.parseHerdrSessions('{"result":{"workspaces":[]}}'),
        isNull,
      );
    });

    test('lists a named session with --session', () {
      expect(
        RemoteSessionListing.herdrWorkspaceListFor('work'),
        contains('exec herdr --session work workspace list'),
      );
      expect(
        RemoteSessionListing.herdrWorkspaceListFor(''),
        RemoteSessionListing.herdrWorkspaceListCommand,
      );
    });
  });
}
