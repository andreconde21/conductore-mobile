import 'package:conduit/core/presentation/multiplexer_icon.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/hosts/presentation/home_board_controller.dart';
import 'package:conduit/features/session_navigation/presentation/quick_switcher_model.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:conduit/features/sessions/domain/remote_session_listing.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

void main() {
  group('fuzzyScore', () {
    test('matches case-insensitively', () {
      expect(fuzzyScore('cal', 'TheCalendar'), isNotNull);
      expect(fuzzyScore('CAL', 'thecalendar'), isNotNull);
    });

    test('letters in order match, out of order do not', () {
      expect(fuzzyScore('thcal', 'TheCalendar'), isNotNull);
      expect(fuzzyScore('lact', 'TheCalendar'), isNull);
      expect(fuzzyScore('x', ''), isNull);
    });

    test('a substring beats scattered letters, a word start beats the '
        'middle, the whole text beats both', () {
      final exact = fuzzyScore('infra', 'infra')!;
      final start = fuzzyScore('infra', 'Infrastructure')!;
      final word = fuzzyScore('infra', 'my-infra-box')!;
      final middle = fuzzyScore('infra', 'xinfrastructure')!;
      final scattered = fuzzyScore('infra', 'in fresh area')!;
      expect(exact, greaterThan(start));
      expect(start, greaterThan(middle));
      expect(word, greaterThan(middle));
      expect(middle, greaterThan(scattered));
    });
  });

  group('filterSwitcher', () {
    final hostA = buildHost('a');
    final hostB = buildHost('b');
    SwitcherAgentItem agent(String id, {String project = 'proj'}) =>
        SwitcherAgentItem(
          host: hostA,
          machineName: 'Host a',
          agent: AgentInfo(
            id: id,
            name: id,
            state: AgentAttentionState.needsInput,
            project: project,
          ),
        );
    SwitcherWorkspaceItem tmux(SavedHost host, String name) =>
        SwitcherWorkspaceItem(
          host: host,
          kind: MultiplexerKind.tmux,
          id: name,
          label: name,
        );
    SwitcherRecentItem recent(SavedHost host, String name) =>
        SwitcherRecentItem(host: host, target: ConnectTarget.tmux(name));

    test('sections keep their order, NEEDS YOU first, empty ones left '
        'out', () {
      final sections = filterSwitcher([
        recent(hostA, 'old'),
        tmux(hostA, 'work'),
        agent('x'),
      ], '');
      expect(
        [for (final s in sections) s.section],
        [
          SwitcherSection.needsYou,
          SwitcherSection.otherWorkspaces,
          SwitcherSection.recent,
        ],
      );
    });

    test('search matches workspace, machine, project and tmux names', () {
      final items = [
        agent('x', project: 'TheCalendar'),
        tmux(hostA, 'infra'),
        tmux(hostB, 'web'),
        recent(hostB, 'deploy'),
      ];
      List<String> titles(String query) => [
        for (final section in filterSwitcher(items, query))
          for (final item in section.items) item.title,
      ];
      expect(titles('thecal'), ['TheCalendar']);
      expect(titles('INFRA'), ['infra']);
      // The machine name matches every row on it.
      expect(titles('host b'), ['web', 'deploy']);
      // Every word has to match.
      expect(titles('host infra'), ['infra']);
      expect(titles('nothing-like-this'), isEmpty);
    });

    test('best matches first inside a section, given order on ties', () {
      final items = [
        tmux(hostA, 'api-server'),
        tmux(hostA, 'server'),
        tmux(hostA, 'observer'),
        tmux(hostA, 'shell'),
      ];
      final titles = [
        for (final section in filterSwitcher(items, 'server'))
          for (final item in section.items) item.title,
      ];
      expect(titles, ['server', 'api-server', 'observer']);
      final all = [
        for (final section in filterSwitcher(items, ''))
          for (final item in section.items) item.title,
      ];
      expect(all, ['api-server', 'server', 'observer', 'shell']);
    });
  });

  group('buildSwitcherItems', () {
    final host = buildHost('h');

    test('open sessions, then what is not open, then recents not listed '
        'above', () {
      final workspace = TerminalWorkspaceController(
        ImmediateTerminalRepository(TrackableTerminalSession()),
      );
      addTearDown(workspace.dispose);
      workspace
        ..open(const ConnectTarget.tmux('work').apply(host))
        ..open(
          const ConnectTarget.herdr(
            workspaceId: 'w1',
            label: 'Infra',
          ).apply(host),
        );
      const board = HomeBoardState(
        workspaces: [
          HomeBoardWorkspace(
            workspace: HerdrWorkspaceInfo(id: 'w1', label: 'Infra'),
          ),
          HomeBoardWorkspace(
            workspace: HerdrWorkspaceInfo(id: 'w2', label: 'TheCalendar'),
          ),
        ],
        tmux: HomeTmuxStatus.available,
        tmuxSessions: [
          TmuxSessionInfo(name: 'work'),
          TmuxSessionInfo(name: 'scratch'),
        ],
      );
      final items = buildSwitcherItems(
        sessions: workspace.sessions,
        active: workspace.activeSession,
        machines: [host],
        boards: [(host: host, state: board)],
        recents: {
          'h': const [
            ConnectTarget.tmux('work'), // open
            ConnectTarget.tmux('scratch'), // listed as another workspace
            ConnectTarget.herdr(workspaceId: 'w2'), // listed too
            ConnectTarget.tmux('old'),
          ],
        },
      );
      expect(
        [for (final item in items) item.key],
        [
          'session-h#tmux:work',
          'session-h#herdr:w1',
          'workspace-h-herdr-w2',
          'workspace-h-tmux-scratch',
          'recent-h-tmux:old',
        ],
      );
      final open = items.whereType<SwitcherSessionItem>().toList();
      expect(open.last.active, isTrue);
      expect(open.first.title, 'work');
      expect(open.last.title, 'Infra');
      expect(open.first.machineName, 'Host h');
    });

    test('workspaces and sessions are found by the topic, project and '
        'folder of the agents in them', () {
      final workspace = TerminalWorkspaceController(
        ImmediateTerminalRepository(TrackableTerminalSession()),
      );
      addTearDown(workspace.dispose);
      workspace.open(const ConnectTarget.tmux('open-one').apply(host));
      const board = HomeBoardState(
        workspaces: [
          HomeBoardWorkspace(
            workspace: HerdrWorkspaceInfo(id: 'w1', label: 'Main'),
            panes: [
              HomeBoardPane(
                agent: AgentInfo(
                  id: 'p1',
                  name: 'Fixing the login bug',
                  state: AgentAttentionState.working,
                  workspace: 'w1',
                ),
              ),
            ],
          ),
          HomeBoardWorkspace(
            workspace: HerdrWorkspaceInfo(id: 'w2', label: 'Other'),
          ),
        ],
        tmux: HomeTmuxStatus.available,
        tmuxSessions: [
          TmuxSessionInfo(name: 'scratch'),
          TmuxSessionInfo(name: 'idle'),
        ],
      );
      final items = buildSwitcherItems(
        sessions: workspace.sessions,
        machines: [host],
        boards: [(host: host, state: board)],
        agentsByMachine: {
          'h': const [
            // The companion's agents: tmux location, cwd as workspace.
            AgentInfo(
              id: 'c1',
              name: 'Refactor billing',
              state: AgentAttentionState.working,
              workspace: '/home/andre/Projects/TheCalendar',
              tab: 'scratch:1',
            ),
            AgentInfo(
              id: 'c2',
              name: 'Release notes',
              state: AgentAttentionState.idle,
              workspace: '/srv/vale-da-teja',
              project: 'ValeDaTeja',
              tab: 'open-one',
            ),
          ],
        },
      );
      List<String> keys(String query) => [
        for (final section in filterSwitcher(items, query))
          for (final item in section.items) item.key,
      ];
      // Agent topic: a Herdr pane, a companion agent in tmux.
      expect(keys('login bug'), ['workspace-h-herdr-w1']);
      expect(keys('billing'), ['workspace-h-tmux-scratch']);
      // Folder and repo.
      expect(keys('Projects/TheCal'), ['workspace-h-tmux-scratch']);
      expect(keys('thecalendar'), ['workspace-h-tmux-scratch']);
      // Project, on an open session.
      expect(keys('valedateja'), ['session-h#tmux:open-one']);
      expect(keys('vale-da-teja'), ['session-h#tmux:open-one']);
    });

    test('what a waiting agent asks for', () {
      SwitcherAgentItem item(AgentInfo agent) =>
          SwitcherAgentItem(host: host, agent: agent, machineName: 'Host h');
      expect(
        item(
          const AgentInfo(
            id: 'a',
            name: 'a',
            state: AgentAttentionState.blocked,
            pendingRequests: [
              PendingPermissionRequest(
                id: 'r',
                toolName: 'Bash',
                summary: 'rm -rf build',
              ),
            ],
          ),
        ).asks,
        'Approve Bash: rm -rf build',
      );
      expect(
        item(
          const AgentInfo(
            id: 'a',
            name: 'a',
            state: AgentAttentionState.needsInput,
            lastMessage: 'Which database?',
          ),
        ).asks,
        'Which database?',
      );
      expect(
        item(
          const AgentInfo(
            id: 'a',
            name: 'a',
            state: AgentAttentionState.needsInput,
          ),
        ).asks,
        'Needs input',
      );
    });
  });
}
