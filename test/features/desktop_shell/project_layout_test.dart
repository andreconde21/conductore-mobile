import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/desktop_shell/domain/project_layout.dart';
import 'package:conduit/features/desktop_shell/domain/project_tree.dart';
import 'package:conduit/features/desktop_shell/domain/sidebar_tree.dart';
import 'package:conduit/features/hosts/presentation/home_board_controller.dart';
import 'package:conduit/features/sessions/domain/remote_session_listing.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

/// The companion's `sidebar-layout` reply for sheprd's own file (see
/// host/test/sheprd.test.js).
const _reported = {
  'compact': true,
  'active_only': true,
  'recent_hours': 12,
  'hidden': ['gpu-box/w3:scratch'],
  'ungrouped': ['local/w9:Storefront-old'],
  'group': [
    {
      'name': 'storefront',
      'members': ['local/w1:notes', 'gpu-box/w2:sf'],
      'match': ['storefront'],
    },
    {
      'name': 'TheCalendar',
      'members': <String>[],
      'match': ['cal'],
      'pinned': true,
      'short': 'TC',
    },
  ],
};

ProjectDef _group(
  String name, {
  List<String> members = const [],
  List<String> match = const [],
}) => ProjectDef(name: name, members: members, match: match);

/// A machine node named [name] with Herdr workspaces `(id, label)`.
SidebarNode _herdrMachine(
  String id,
  String name,
  List<(String, String)> workspaces, {
  Map<String, List<AgentInfo>> agents = const {},
}) {
  final host = buildHost(id);
  return SidebarNode(
    key: SidebarKeys.machine(id),
    kind: SidebarNodeKind.machine,
    machineId: id,
    label: name,
    target: MachineTarget(host),
    children: [
      for (final (wsId, label) in workspaces)
        () {
          final panes = [
            for (final agent in agents[wsId] ?? const <AgentInfo>[])
              HomeBoardPane(agent: agent),
          ];
          final workspace = HomeBoardWorkspace(
            workspace: HerdrWorkspaceInfo(id: wsId, label: label),
            panes: panes,
          );
          var dot = SidebarDot.none;
          for (final pane in panes) {
            dot = dot.max(SidebarDot.of(pane.agent.state));
          }
          return SidebarNode(
            key: SidebarKeys.herdrWorkspace(id, wsId),
            kind: SidebarNodeKind.herdrWorkspace,
            machineId: id,
            label: label,
            dot: dot,
            target: HerdrWorkspaceTarget(host, workspace),
            children: [
              for (final pane in panes)
                SidebarNode(
                  key: SidebarKeys.agentPane(id, wsId, null, pane.agent.id),
                  kind: SidebarNodeKind.agentPane,
                  machineId: id,
                  label: pane.agent.name,
                  dot: SidebarDot.of(pane.agent.state),
                  agentKind: 'claude',
                  target: AgentPaneTarget(host, workspace, pane),
                ),
            ],
          );
        }(),
    ],
  );
}

AgentInfo _agent(
  String id,
  AgentAttentionState state, {
  String? workspace,
  String? project,
  DateTime? changed,
}) => AgentInfo(
  id: id,
  name: 'agent $id',
  state: state,
  workspace: workspace,
  project: project,
  stateChangedAt: changed,
);

void main() {
  group('ProjectLayout', () {
    test('reads the companion reply and puts pinned projects first', () {
      final layout = ProjectLayout.fromJson(_reported);
      expect(layout.compact, isTrue);
      expect(layout.activeOnly, isTrue);
      expect(layout.recentHours, 12);
      expect(layout.groups.map((g) => g.name), ['storefront', 'TheCalendar']);
      expect(layout.displayOrder, [1, 0]);
      expect(layout.groups[1].tag, 'TC');
      expect(ProjectLayout.fromJson(layout.toJson()), layout);
    });

    test('keys: the workspace id wins over the label; old label-only '
        'entries still match', () {
      expect(ProjectKeys.same('dev/w1:api', 'dev/w1:renamed'), isTrue);
      expect(ProjectKeys.same('dev/w1:api', 'dev/w2:api'), isFalse);
      expect(ProjectKeys.same('dev/api', 'dev/w2:api'), isTrue);
      expect(ProjectKeys.same('dev/w2:api', 'dev/api'), isTrue);
      expect(ProjectKeys.same('DEV/api', 'dev/api'), isTrue);
      expect(ProjectKeys.same('box/api', 'dev/api'), isFalse);
      expect(ProjectKeys.same('dev/notes', 'dev/notes'), isTrue);
    });

    test('explicit membership beats rules; rules match name or folder', () {
      final layout = ProjectLayout(
        groups: [
          _group('A', match: ['store']),
          _group('B', members: ['gpu-box/w1:Storefront']),
        ],
      );
      expect(layout.groupOf('gpu-box/w1:Storefront', ['Storefront']), 1);
      expect(layout.groupOf('local/w5:Storefront', ['Storefront']), 0);
      expect(layout.groupOf('local/w6:notes', ['notes']), isNull);
      expect(
        layout.groupOf('gpu-box/w7:sf', ['sf', '/home/me/code/Storefront']),
        0,
      );
    });

    test('moving to Other beats the rules until moved back', () {
      var layout = ProjectLayout(
        groups: [
          _group('A', match: ['store']),
        ],
      );
      const key = 'local/w1:Storefront';
      expect(layout.groupOf(key, ['Storefront']), 0);
      layout = layout.assign(key, '');
      expect(layout.groupOf(key, ['Storefront']), isNull);
      layout = layout.assign(key, 'a');
      expect(layout.ungrouped, isEmpty);
      expect(layout.groups.single.members, [key]);
      expect(layout.groupOf(key, ['Storefront']), 0);
    });

    test('assign moves between projects and creates missing ones', () {
      var layout = ProjectLayout(
        groups: [
          _group('A', members: ['local/x']),
        ],
      );
      layout = layout.assign('local/x', 'b');
      expect(layout.groups[0].members, isEmpty);
      expect(layout.groups[1].name, 'b');
      expect(layout.groups[1].members, ['local/x']);
      layout = layout.assign('local/x', 'A');
      expect(layout.groups[0].members, ['local/x']);
      expect(layout.groups[1].members, isEmpty);
    });

    test('pin, rules, rename, remove, hide', () {
      var layout = const ProjectLayout().add('api', rules: ['API', ' ', 'api']);
      expect(layout.groups.single.match, ['api']);
      layout = layout.setPinned('api', true).rename('api', 'Backend');
      expect(layout.groups.single.name, 'Backend');
      expect(layout.groups.single.pinned, isTrue);
      expect(
        layout.add('other').rename('other', 'backend').byName('other'),
        isNotNull,
      );
      layout = layout.toggleHidden('dev/w1:x');
      expect(layout.isHidden('dev/w1:y'), isTrue);
      expect(layout.toggleHidden('dev/w1:x').hidden, isEmpty);
      expect(layout.remove('Backend').groups, isEmpty);
    });

    test("sheprd's local/ is the machine that holds the file; machines "
        'merge by project name', () {
      final dev = ProjectLayout.fromJson(_reported).localized('dev');
      expect(dev.groups[0].members, ['dev/w1:notes', 'gpu-box/w2:sf']);
      expect(dev.ungrouped, ['dev/w9:Storefront-old']);
      final box = ProjectLayout(
        groups: [
          const ProjectDef(
            name: 'Storefront',
            pinned: true,
            members: ['box/w4:shop'],
            match: ['shop'],
          ),
          _group('infra'),
        ],
        hidden: const ['box/w8:tmp'],
        recentHours: 48,
      );
      final merged = ProjectLayout.merge([dev, box]);
      expect(merged.groups.map((g) => g.name), [
        'storefront',
        'TheCalendar',
        'infra',
      ]);
      expect(merged.groups[0].pinned, isTrue);
      expect(merged.groups[0].members, [
        'dev/w1:notes',
        'gpu-box/w2:sf',
        'box/w4:shop',
      ]);
      expect(merged.groups[0].match, ['storefront', 'shop']);
      expect(merged.hidden, ['gpu-box/w3:scratch', 'box/w8:tmp']);
      expect(merged.recentHours, 12);
    });

    test('rail tags', () {
      expect(projectTag('TheCalendar'), 'TC');
      expect(projectTag('Outsmartis ops'), 'OO');
      expect(projectTag('Infrastructure'), 'In');
      expect(projectTag('LF'), 'LF');
      expect(projectTag('VTM'), 'VT');
      expect(projectTag('Anything', 'op'), 'op');
    });

    test('prefs round-trip, defaults left out', () {
      expect(ProjectPrefs.defaults.toJson(), isEmpty);
      final prefs = ProjectPrefs(
        layout: ProjectLayout.fromJson(_reported),
        compact: false,
        activeOnly: true,
        recentHours: 6,
        collapsed: const {'storefront': true, ProjectPrefs.otherKey: false},
        groupByProject: true,
      );
      expect(ProjectPrefs.fromJson(prefs.toJson()), prefs);
      expect(ProjectPrefs.fromJson('junk'), ProjectPrefs.defaults);
    });
  });

  group('ProjectTreeBuilder with a layout', () {
    final now = DateTime.utc(2026, 10, 3, 12);
    List<SidebarNode> tree() => [
      _herdrMachine(
        'm1',
        'dev',
        [
          ('w1', 'notes'),
          ('w2', 'storefront-api'),
          ('w3', 'scratch'),
          ('w9', 'misc'),
        ],
        agents: {
          'w2': [_agent('a1', AgentAttentionState.needsInput)],
          'w9': [
            _agent(
              'a9',
              AgentAttentionState.idle,
              changed: now.subtract(const Duration(hours: 30)),
            ),
          ],
        },
      ),
      _herdrMachine(
        'm2',
        'gpu-box',
        [('w2', 'sf'), ('w3', 'scratch'), ('w5', 'cal-web')],
        agents: {
          'w5': [
            _agent(
              'a5',
              AgentAttentionState.idle,
              changed: now.subtract(const Duration(hours: 2)),
            ),
          ],
        },
      ),
    ];

    test('groups every machine into the layout projects, pinned first, '
        'then Other', () {
      final layout = ProjectLayout.fromJson(_reported).localized('dev');
      final projects = ProjectTreeBuilder.build(
        tree(),
        layout: layout,
        now: now,
      );
      expect(projects.map((p) => p.name), [
        'TheCalendar',
        'storefront',
        'Other',
      ]);
      final calendar = projects[0];
      expect(calendar.pinned, isTrue);
      expect(calendar.inLayout, isTrue);
      expect(calendar.members.map((n) => n.label), ['cal-web']);
      // Explicit members first, in member order, then rule matches.
      final store = projects[1];
      expect(store.members.map((n) => '${n.machineId}:${n.label}'), [
        'm1:notes',
        'm2:sf',
        'm1:storefront-api',
      ]);
      expect(store.needsYou, 1);
      expect(store.dot, SidebarDot.needsYou);
      expect(store.agents.single.$1, 'm1');
      // Hidden rows stay in entries only.
      final other = projects[2];
      expect(other.isOther, isTrue);
      expect(other.key, ProjectGroup.otherKey);
      expect(other.members.map((n) => '${n.machineId}:${n.label}'), [
        'm1:scratch',
        'm1:misc',
      ]);
      expect(other.entries.where((e) => e.hidden).map((e) => e.memberKey), [
        'gpu-box/w3:scratch',
      ]);
    });

    test('active: busy, or changed state within the recent hours', () {
      final projects = ProjectTreeBuilder.build(
        tree(),
        layout: ProjectLayout(
          groups: [
            _group('cal', match: ['cal']),
          ],
        ),
        now: now,
        recentHours: 12,
      );
      final byLabel = {
        for (final project in projects)
          for (final entry in project.entries) entry.node.label: entry,
      };
      expect(byLabel['storefront-api']!.active, isTrue);
      expect(byLabel['cal-web']!.active, isTrue);
      expect(byLabel['misc']!.active, isFalse);
      expect(byLabel['notes']!.active, isFalse);
      // The detailed view's agent rows.
      expect(byLabel['cal-web']!.agentRows.map((n) => n.label), ['agent a5']);
    });

    test("a machine's other names match its layout keys", () {
      final layout = ProjectLayout(
        groups: [
          _group('box', members: ['gpu/w5:cal-web']),
        ],
      );
      final projects = ProjectTreeBuilder.build(
        tree(),
        layout: layout,
        machineAliases: const {
          'm2': {'gpu'},
        },
        now: now,
      );
      expect(projects.first.members.map((n) => n.label), ['cal-web']);
    });

    test('without layout projects, rows moved to Other leave their found '
        'project', () {
      List<SidebarNode> repoTree() => [
        _herdrMachine(
          'm1',
          'dev',
          [('w1', 'api'), ('w2', 'api-2')],
          agents: {
            'w1': [_agent('a1', AgentAttentionState.working, project: 'Api')],
            'w2': [_agent('a2', AgentAttentionState.working, project: 'Api')],
          },
        ),
      ];
      final found = ProjectTreeBuilder.build(repoTree(), now: now);
      expect(found.single.name, 'Api');
      expect(found.single.inLayout, isFalse);
      final moved = ProjectTreeBuilder.build(
        repoTree(),
        layout: const ProjectLayout(ungrouped: ['dev/w2:api-2']),
        now: now,
      );
      expect(moved.map((p) => p.name), ['Api', 'Other']);
      expect(moved.last.members.single.label, 'api-2');
    });
  });
}
