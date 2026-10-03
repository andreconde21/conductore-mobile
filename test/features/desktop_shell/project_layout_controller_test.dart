import 'dart:convert';

import 'package:conduit/core/theme/theme_controller.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/desktop_shell/domain/project_layout.dart';
import 'package:conduit/features/desktop_shell/domain/project_tree.dart';
import 'package:conduit/features/desktop_shell/domain/sidebar_tree.dart';
import 'package:conduit/features/desktop_shell/presentation/project_layout_controller.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/sessions/domain/remote_session_listing.dart';
import 'package:conduit/features/usage/domain/usage_report.dart';
import 'package:conduit/features/usage/domain/usage_summary.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

SavedHost _host(String id, String name) => SavedHost(
  id: id,
  name: name,
  host: '$name.tail',
  port: 22,
  username: 'u',
  authMethod: SshAuthMethod.password,
);

/// A machine with tmux sessions `name → agent project`.
SidebarNode _machine(SavedHost host, List<String> sessions) => SidebarNode(
  key: SidebarKeys.machine(host.id),
  kind: SidebarNodeKind.machine,
  machineId: host.id,
  label: host.name,
  target: MachineTarget(host),
  children: [
    for (final name in sessions)
      SidebarNode(
        key: SidebarKeys.tmuxSession(host.id, name),
        kind: SidebarNodeKind.tmuxSession,
        machineId: host.id,
        label: name,
        target: TmuxSessionTarget(host, TmuxSessionInfo(name: name)),
      ),
  ],
);

void main() {
  late ThemeController theme;
  late ProjectLayoutController controller;
  final dev = _host('h1', 'Dev');
  final box = _host('h2', 'Box');

  setUp(() async {
    theme = ThemeController(InMemoryThemePreferences());
    await theme.load();
    controller = ProjectLayoutController(theme: theme);
  });
  tearDown(() => controller.dispose());

  String reply(Object layout) =>
      'noise\n${jsonEncode({'ok': true, 'found': true, 'layout': layout})}';

  test("follows the machines' sidebar.toml until edited in the app", () async {
    controller.applyReply(
      dev,
      reply({
        'group': [
          {
            'name': 'api',
            'match': ['api'],
            'members': ['local/notes'],
          },
        ],
        'compact': true,
        'recent_hours': 6,
      }),
    );
    expect(controller.hasMachineLayout, isTrue);
    expect(controller.followsMachines, isTrue);
    expect(controller.compact, isTrue);
    expect(controller.recentHours, 6);
    // local/ is the machine that reported it.
    expect(controller.layout.groups.single.members, ['dev/notes']);

    final tree = [
      _machine(dev, ['notes', 'api-server', 'misc']),
      _machine(box, ['api-web']),
    ];
    var groups = controller.build(tree, hosts: [dev, box]);
    expect(groups.map((g) => g.name), ['api', 'Other']);
    expect(groups.first.members.map((n) => n.label), [
      'notes',
      'api-server',
      'api-web',
    ]);

    // Move to Other: the app's own layout from now on; the rule no longer
    // catches it.
    final apiWeb = groups.first.entries.last;
    await controller.moveTo(apiWeb, '');
    expect(controller.followsMachines, isFalse);
    groups = controller.build(tree, hosts: [dev, box]);
    expect(groups.last.members.map((n) => n.label), ['misc', 'api-web']);
    // The view setting of the file still applies; the app's wins once set.
    await controller.setCompact(false);
    expect(controller.compact, isFalse);

    // A new sidebar.toml no longer changes the edited layout...
    controller.applyReply(dev, reply({'group': <Object>[]}));
    expect(controller.layout.groups.single.name, 'api');
    // ...until the app follows the machines again.
    await controller.followMachineLayout();
    expect(controller.layout.groups, isEmpty);
  });

  test('a reply without a file, or with an unreadable one, drops it', () {
    controller.applyReply(
      dev,
      reply({
        'group': [
          {'name': 'x'},
        ],
      }),
    );
    expect(controller.hasMachineLayout, isTrue);
    controller.applyReply(
      dev,
      jsonEncode({'ok': true, 'found': true, 'error': 'line 2: bad'}),
    );
    expect(controller.hasMachineLayout, isFalse);
    expect(controller.machineErrors, {'h1': 'line 2: bad'});
    controller.applyReply(dev, jsonEncode({'ok': true, 'found': false}));
    expect(controller.machineErrors, isEmpty);
    controller.applyReply(dev, 'not json');
    expect(controller.hasMachineLayout, isFalse);
  });

  test('the first edit keeps the projects found from the agents', () async {
    final tree = [
      _machine(dev, ['api-1', 'api-2', 'web']),
    ];
    final agents = {
      'h1': [
        const AgentInfo(
          id: 'a1',
          name: 'a1',
          state: AgentAttentionState.working,
          tab: 'api-1',
          project: 'api',
        ),
        const AgentInfo(
          id: 'a2',
          name: 'a2',
          state: AgentAttentionState.idle,
          tab: 'api-2',
          project: 'api',
        ),
      ],
    };
    var groups = controller.build(tree, agentsByMachine: agents, hosts: [dev]);
    // Found from the agents, else the row's own name (CON-032).
    expect(groups.map((g) => g.name), ['api', 'web']);
    expect(controller.projectNames, ['api', 'web']);
    await controller.moveTo(groups.last.entries.single, 'Frontend');
    groups = controller.build(tree, agentsByMachine: agents, hosts: [dev]);
    expect(groups.map((g) => g.name), ['api', 'web', 'Frontend']);
    expect(groups[1].members, isEmpty);
    expect(groups.first.members.map((n) => n.label), ['api-1', 'api-2']);
    expect(controller.layout.groups.first.match, ['api']);

    await controller.setPinned(groups.last, true);
    groups = controller.build(tree, agentsByMachine: agents, hosts: [dev]);
    expect(groups.first.name, 'Frontend');
  });

  test('collapsed state, filter and Other', () async {
    final tree = [
      _machine(dev, ['a']),
    ];
    await controller.addProject('zzz');
    final groups = controller.build(tree, hosts: [dev]);
    expect(groups.map((g) => g.name), ['zzz', 'Other']);
    final other = groups.last;
    expect(other.isOther, isTrue);
    expect(controller.isCollapsed(other), isFalse);
    await controller.toggleCollapsed(other);
    expect(controller.isCollapsed(other), isTrue);
    expect(theme.projectPrefs.collapsed, {ProjectPrefs.otherKey: true});
    // Nothing active: the active view leaves both out.
    expect(controller.visibleGroups(groups), hasLength(2));
    await controller.setActiveOnly(true);
    expect(controller.visibleGroups(groups), isEmpty);
  });

  test("today's tokens per project from the usage reports", () async {
    await controller.addProject('Shop', rules: ['shop']);
    final tree = [
      _machine(dev, ['api']),
    ];
    final groups = controller.build(
      tree,
      agentsByMachine: {
        'h1': [
          const AgentInfo(
            id: 'a',
            name: 'a',
            state: AgentAttentionState.working,
            tab: 'api',
            project: 'Api',
          ),
        ],
      },
      hosts: [dev],
    );
    // The api session is in no project: Other holds its agent.
    expect(groups.map((g) => g.name), ['Shop', 'Other']);
    UsageRow row(String date, String project, int tokens) => UsageRow(
      date: date,
      project: project,
      model: 'm',
      totals: UsageTotals(input: tokens, output: 1, cacheRead: 1000000),
    );
    final usage = UsageSummary([
      MachineUsage(
        hostId: 'h1',
        hostName: 'Dev',
        report: UsageReport(
          machine: 'dev',
          today: '2026-10-03',
          from: '2026-09-27',
          claude: UsageSection(
            agent: UsageAgent.claude,
            present: true,
            rows: [
              row('2026-10-03', 'Api', 99),
              row('2026-10-03', 'webshop', 9),
              row('2026-10-02', 'webshop', 500),
            ],
          ),
          codex: const UsageSection(agent: UsageAgent.codex, present: false),
        ),
      ),
    ]);
    expect(controller.tokensToday(groups, usage), {
      ProjectGroup.otherKey: 100,
      'shop': 10,
    });
    expect(formatProjectTokens(1234567), '1.2M');
    expect(formatProjectTokens(340000), '340k');
  });
}
