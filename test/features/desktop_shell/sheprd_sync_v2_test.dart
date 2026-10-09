import 'dart:convert';

import 'package:conduit/core/theme/theme_controller.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/desktop_shell/domain/project_layout.dart';
import 'package:conduit/features/desktop_shell/domain/project_tree.dart';
import 'package:conduit/features/desktop_shell/domain/sheprd_view.dart';
import 'package:conduit/features/desktop_shell/domain/sidebar_tree.dart';
import 'package:conduit/features/desktop_shell/presentation/project_layout_controller.dart';
import 'package:conduit/features/desktop_shell/presentation/widgets/project_view.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/hosts/presentation/home_board_controller.dart';
import 'package:conduit/features/sessions/domain/remote_session_listing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

// Contract v2 (CON-101): layout edits from the app go back to sheprd.

SavedHost _host(String id, String name) => SavedHost(
  id: id,
  name: name,
  host: '$name.tail',
  port: 22,
  username: 'u',
  authMethod: SshAuthMethod.password,
);

SidebarNode _machine(
  SavedHost host,
  Map<(String, String), List<AgentInfo>> workspaces,
) => SidebarNode(
  key: SidebarKeys.machine(host.id),
  kind: SidebarNodeKind.machine,
  machineId: host.id,
  label: host.name,
  target: MachineTarget(host),
  children: [
    for (final MapEntry(key: (wsId, label), value: agents)
        in workspaces.entries)
      () {
        final workspace = HomeBoardWorkspace(
          workspace: HerdrWorkspaceInfo(id: wsId, label: label),
          panes: [for (final agent in agents) HomeBoardPane(agent: agent)],
        );
        return SidebarNode(
          key: SidebarKeys.herdrWorkspace(host.id, wsId),
          kind: SidebarNodeKind.herdrWorkspace,
          machineId: host.id,
          label: label,
          target: HerdrWorkspaceTarget(host, workspace),
          children: [
            for (final pane in workspace.panes)
              SidebarNode(
                key: SidebarKeys.agentPane(host.id, wsId, null, pane.agent.id),
                kind: SidebarNodeKind.agentPane,
                machineId: host.id,
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

AgentInfo _agent(String pane, AgentAttentionState state, {int? seq}) =>
    AgentInfo(
      id: pane,
      name: 'agent $pane',
      state: state,
      pane: pane,
      workspace: pane.split(':').first,
      stateSequence: seq,
    );

const _storefront = {
  'name': 'Storefront',
  'members': ['local/w1:notes', 'dev-box/w2:sf'],
  'match': ['shop'],
};

/// A `sheprd-view` reply; [updates] 2 is a sheprd that takes layout edits.
String _reply(
  String self, {
  int updated = 1000,
  int? updates = 2,
  List<Map<String, Object?>> groups = const [_storefront],
  List<String> hidden = const [],
  List<String> ungrouped = const [],
  Map<String, Object?> agents = const {},
  List<Map<String, Object?>> rejected = const [],
}) => jsonEncode({
  'ok': true,
  'found': true,
  'stale': false,
  'view': {
    'version': 1,
    'updated': updated,
    'hub': 'laptop',
    'self': self,
    'updates': ?updates,
    'rejected': rejected,
    'layout': {'hidden': hidden, 'ungrouped': ungrouped, 'group': groups},
    'agents': agents,
  },
});

/// Splits [command] into words like sh does, for the quoting the app
/// uses (single quotes, backslash escapes, double quotes).
List<String> _words(String command) {
  final words = <String>[];
  final word = StringBuffer();
  var inWord = false;
  for (var i = 0; i < command.length; i++) {
    final c = command[i];
    if (c == "'") {
      final close = command.indexOf("'", i + 1);
      word.write(command.substring(i + 1, close));
      i = close;
      inWord = true;
    } else if (c == '"') {
      final close = command.indexOf('"', i + 1);
      word.write(command.substring(i + 1, close));
      i = close;
      inWord = true;
    } else if (c == '\\') {
      word.write(command[++i]);
      inWord = true;
    } else if (c == ' ') {
      if (inWord) words.add(word.toString());
      word.clear();
      inWord = false;
    } else {
      word.write(c);
      inWord = true;
    }
  }
  if (inWord) words.add(word.toString());
  return words;
}

/// The ops a `sheprd-view-update --json '…'` command carries.
List<Map<String, Object?>> _ops(String command) {
  final outer = _words(command);
  final inner = _words(outer[outer.indexOf('-c') + 1]);
  final json = inner[inner.indexOf('--json') + 1];
  return [
    for (final op in jsonDecode(json) as List)
      (op as Map).cast<String, Object?>(),
  ];
}

void main() {
  group('SheprdLayoutEdit', () {
    const layout = ProjectLayout(
      groups: [
        ProjectDef(name: 'Pinned', pinned: true),
        ProjectDef(name: 'A', members: ['dev/w1:a', 'dev/w2:b'], match: ['a']),
        ProjectDef(name: 'B', short: 'BB'),
      ],
      hidden: ['dev/w9:old'],
    );
    const view = SheprdView(updated: 1, self: 'local', layout: layout);

    test('the wire form uses sheprd\'s names for keys, never for projects', () {
      String back(String key) => ProjectKeys.renamed(key, {'dev': 'dev-box'});
      expect(const SheprdLayoutEdit.assign('dev/w1:a', 'B').toJson(back), {
        'op': 'assign',
        'workspace': 'dev-box/w1:a',
        'project': 'B',
      });
      expect(
        const SheprdLayoutEdit.moveMember(
          'dev/w2:b',
          'dev/w1:a',
          project: 'A',
          inView: ['dev/w1:a', 'dev/w2:b'],
        ).toJson(back),
        {
          'op': 'member-move',
          'workspace': 'dev-box/w2:b',
          'before': 'dev-box/w1:a',
        },
      );
      expect(const SheprdLayoutEdit.moveProject('A', '').toJson(back), {
        'op': 'project-move',
        'project': 'A',
        'before': '',
      });
      expect(
        const SheprdLayoutEdit.delete('A', members: ['dev/w1:a']).toJson(back),
        {
          'op': 'project-delete',
          'project': 'A',
          'members': ['dev-box/w1:a'],
        },
      );
      expect(const SheprdLayoutEdit.removeActive('dev/w1:p1', 7).toJson(back), {
        'op': 'remove-active',
        'agent': 'dev-box/w1:p1',
        'state_seq': 7,
      });
      expect(
        const SheprdLayoutEdit.hide('dev/w9:old', hidden: false).toJson(back),
        {'op': 'show', 'workspace': 'dev-box/w9:old'},
      );
    });

    test(
      'each op shows before sheprd applies it, and is then seen applied',
      () {
        for (final edit in const [
          SheprdLayoutEdit.assign('dev/w1:a', 'B'),
          SheprdLayoutEdit.assign('dev/w1:a', ''),
          SheprdLayoutEdit.assign('dev/w3:c', 'New'),
          SheprdLayoutEdit.hide('dev/w1:a', hidden: true),
          SheprdLayoutEdit.hide('dev/w9:old', hidden: false),
          SheprdLayoutEdit.createProject('C', match: ['c']),
          SheprdLayoutEdit.rename('A', 'Alpha'),
          SheprdLayoutEdit.pin('B', pinned: true),
          SheprdLayoutEdit.rules('A', ['x', 'y'], was: ['a']),
          SheprdLayoutEdit.short('B', ''),
          SheprdLayoutEdit.short('A', 'Al'),
          SheprdLayoutEdit.delete('B'),
          SheprdLayoutEdit.moveProject('B', 'A'),
          SheprdLayoutEdit.moveProject('A', ''),
          SheprdLayoutEdit.moveMember(
            'dev/w2:b',
            'dev/w1:a',
            project: 'A',
            inView: ['dev/w1:a', 'dev/w2:b'],
          ),
          SheprdLayoutEdit.removeActive('dev/w1:p1', 3),
          SheprdLayoutEdit.keepActive('dev/w1:p1'),
        ]) {
          expect(edit.reflectedIn(view), isFalse, reason: '$edit before');
          expect(edit.reflectedIn(edit.applyTo(view)), isTrue, reason: '$edit');
        }
      },
    );

    test('pinned projects stay above; member order sticks', () {
      expect(layout.moveGroup('A', 'Pinned'), layout);
      expect(
        [for (final g in layout.moveGroup('B', 'A').groups) g.name],
        ['Pinned', 'B', 'A'],
      );
      expect(
        [for (final g in layout.moveGroup('A', '').groups) g.name],
        ['Pinned', 'B', 'A'],
      );
      final moved = layout.moveMember(
        'A',
        ['dev/w1:a', 'dev/w2:b', 'dev/w4:matched'],
        'dev/w4:matched',
        'dev/w1:a',
      );
      expect(moved.byName('A')!.members, [
        'dev/w4:matched',
        'dev/w1:a',
        'dev/w2:b',
      ]);
      expect(layout.setShort('B', ' ').byName('B')!.short, isNull);
    });

    test(
      'a v2 reply carries `updates` and `rejected`; v1 means marks only',
      () {
        final v2 = SheprdView.fromReply(
          jsonDecode(
            _reply(
              'local',
              rejected: [
                {'id': 'c-1-aaaa', 'why': 'name taken'},
              ],
            ),
          ),
        )!;
        expect(v2.takesLayoutEdits, isTrue);
        expect(v2.rejected, {'c-1-aaaa': 'name taken'});
        final v1 = SheprdView.fromReply(
          jsonDecode(_reply('local', updates: null)),
        )!;
        expect(v1.takesLayoutEdits, isFalse);
      },
    );
  });

  group('Sync with sheprd v2', () {
    late ThemeController theme;
    late ProjectLayoutController controller;
    final laptop = _host('h1', 'Laptop');
    final dev = _host('h2', 'Dev');
    final sent = <(String, String)>[];
    var next = 0;

    setUp(() async {
      theme = ThemeController(InMemoryThemePreferences());
      await theme.load();
      next = 0;
      controller =
          ProjectLayoutController(
              theme: theme,
              markTimeout: const Duration(milliseconds: 80),
            )
            ..editCapable = ((_) => true)
            ..sheprdRunner = (host, command) async {
              sent.add((host.name, command));
              if (!command.contains('--json')) {
                return '{"ok":true,"id":"c-1-abcd"}';
              }
              final ids = [for (final _ in _ops(command)) 'c-${++next}-abcd'];
              return jsonEncode({'ok': true, 'ids': ids});
            };
      sent.clear();
    });
    tearDown(() => controller.dispose());

    List<SidebarNode> tree() => [
      _machine(laptop, {
        ('w1', 'notes'): [_agent('w1:p1', AgentAttentionState.idle)],
      }),
      _machine(dev, {
        ('w2', 'sf'): [_agent('w2:p1', AgentAttentionState.finished, seq: 41)],
        ('w9', 'misc'): [_agent('w9:p1', AgentAttentionState.idle)],
      }),
    ];

    List<ProjectGroup> groups() =>
        controller.build(tree(), hosts: [laptop, dev]);
    ProjectGroup project(String name) =>
        groups().firstWhere((g) => g.name == name);
    ProjectEntry entry(String label) => groups()
        .expand((g) => g.entries)
        .firstWhere((e) => e.node.label == label);

    Future<void> sync({int? updates = 2}) async {
      await controller.setSheprdSync(true);
      controller
        ..applyViewReply(laptop, _reply('local', updates: updates))
        ..applyViewReply(dev, _reply('dev-box', updates: updates));
    }

    test('an older sheprd keeps layout edits paused, naming the version '
        'needed; so does a companion without sheprd-view-2', () async {
      await sync(updates: null);
      expect(controller.mirroring, isTrue);
      expect(controller.canEditLayout, isFalse);
      expect(controller.sheprdEditsPaused, contains('sheprd ≥ 0.9.4'));
      await controller.moveTo(entry('misc'), 'Storefront');
      expect(sent, isEmpty);
      final items = projectGroupMenuItems<ProjectGroupAction>(
        project('Storefront'),
        value: (a) => a,
        editable: controller.canEditLayout,
        controller: controller,
      );
      expect((items.single as PopupMenuItem).enabled, isFalse);

      controller
        ..editCapable = ((_) => false)
        ..applyViewReply(laptop, _reply('local', updated: 1001));
      expect(controller.canEditLayout, isFalse);
      expect(controller.sheprdEditsPaused, contains('companion'));
      // The app's own layout was never touched.
      expect(theme.projectPrefs.layout, isNull);
    });

    test('move to a project goes to sheprd with its names, shows at once, '
        'and a newer view confirms it', () async {
      await sync();
      expect(controller.canEditLayout, isTrue);
      expect(controller.sheprdEditsPaused, isNull);
      await controller.moveTo(entry('misc'), 'Storefront');
      // Through the hub's companion, in sheprd's names.
      expect(sent.single.$1, 'Laptop');
      expect(sent.single.$2, contains('sheprd-view-update --json '));
      expect(_ops(sent.single.$2), [
        {
          'op': 'assign',
          'workspace': 'dev-box/w9:misc',
          'project': 'Storefront',
        },
      ]);
      // Pending: shown in its new place, with a spinner on the project.
      expect([
        for (final e in project('Storefront').entries) e.node.label,
      ], contains('misc'));
      expect(controller.groupPending(project('Storefront')), isTrue);
      expect(theme.projectPrefs.layout, isNull, reason: 'the app layout waits');

      // A newer view that does not show it yet: still pending.
      controller.applyViewReply(laptop, _reply('local', updated: 1001));
      expect(controller.pendingEdits, hasLength(1));
      controller.applyViewReply(
        laptop,
        _reply(
          'local',
          updated: 1002,
          groups: [
            {
              ..._storefront,
              'members': ['local/w1:notes', 'dev-box/w2:sf', 'dev-box/w9:misc'],
            },
          ],
        ),
      );
      expect(controller.pendingEdits, isEmpty);
      expect(controller.groupPending(project('Storefront')), isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(controller.markNotice, isNull);
    });

    test('unconfirmed edits are reverted after the timeout; refused ones '
        'at once, with sheprd\'s reason', () async {
      await sync();
      await controller.toggleHidden(entry('misc'));
      expect(_ops(sent.last.$2).single['op'], 'hide');
      expect(entry('misc').hidden, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(entry('misc').hidden, isFalse);
      expect(controller.markNotice, contains("sheprd didn't apply this"));
      controller.clearMarkNotice();

      expect(
        await controller.renameProject(project('Storefront'), 'Shop'),
        isTrue,
      );
      expect(_ops(sent.last.$2).single, {
        'op': 'project-rename',
        'project': 'Storefront',
        'to': 'Shop',
      });
      expect(groups().map((g) => g.name), contains('Shop'));
      final id = 'c-$next-abcd';
      controller.applyViewReply(
        laptop,
        _reply(
          'local',
          updated: 1001,
          rejected: [
            {'id': id, 'why': 'renamed or deleted meanwhile'},
          ],
        ),
      );
      expect(controller.pendingEdits, isEmpty);
      expect(groups().map((g) => g.name), contains('Storefront'));
      expect(
        controller.markNotice,
        "sheprd refused rename Storefront to Shop: renamed or deleted meanwhile",
      );
    });

    test(
      'project edits: a found project is created first; rules and '
      'delete carry what sheprd showed, to catch edits made meanwhile',
      () async {
        await sync();
        // A project found from what the agents report, not in sheprd's file.
        const found = ProjectGroup(key: 'repo-x', name: 'repo-x', members: []);
        await controller.setPinned(found, true);
        expect(_ops(sent.last.$2), [
          {
            'op': 'project-create',
            'project': found.name,
            'match': [found.name.toLowerCase()],
          },
          {'op': 'project-pin', 'project': found.name, 'pinned': true},
        ]);

        await controller.setRules(project('Storefront'), ['Shop, Store ', '']);
        expect(_ops(sent.last.$2).single, {
          'op': 'project-rules',
          'project': 'Storefront',
          'match': ['shop', 'store'],
          'was': ['shop'],
        });
        await controller.setShort(project('Storefront'), 'SF');
        expect(_ops(sent.last.$2).single['short'], 'SF');
        await controller.removeProject(project('Storefront'));
        expect(_ops(sent.last.$2).single, {
          'op': 'project-delete',
          'project': 'Storefront',
          'members': ['local/w1:notes', 'dev-box/w2:sf'],
        });
        expect(groups().any((g) => g.name == 'Storefront'), isFalse);
        await controller.addProject('Infra', rules: ['infra']);
        expect(_ops(sent.last.$2).single, {
          'op': 'project-create',
          'project': 'Infra',
          'match': ['infra'],
        });
      },
    );

    test(
      'reorder: workspaces in a project, projects among their pin',
      () async {
        await sync();
        controller.applyViewReply(
          laptop,
          _reply(
            'local',
            updated: 1001,
            groups: [
              _storefront,
              {
                'name': 'Other things',
                'match': ['misc'],
              },
            ],
          ),
        );
        final store = project('Storefront');
        final sf = store.entries.firstWhere((e) => e.node.label == 'sf');
        expect(ProjectLayoutController.canMoveEntry(store, sf, 1), isFalse);
        await controller.moveEntry(store, sf, -1);
        expect(_ops(sent.last.$2).single, {
          'op': 'member-move',
          'workspace': 'dev-box/w2:sf',
          'before': 'local/w1:notes',
        });
        expect(
          [for (final e in project('Storefront').entries) e.node.label],
          ['sf', 'notes'],
        );

        expect(controller.canMoveProject(project('Storefront'), -1), isFalse);
        await controller.moveProject(project('Storefront'), 1);
        expect(_ops(sent.last.$2).single, {
          'op': 'project-move',
          'project': 'Storefront',
          'before': '',
        });
        expect(controller.layout.groups.map((g) => g.name), [
          'Other things',
          'Storefront',
        ]);
      },
    );

    testWidgets('a row offers moves and "remove from active" with a v2 '
        'sheprd; remove carries the state seq', (tester) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(() => sync());
      controller.applyViewReply(
        laptop,
        _reply(
          'local',
          updated: 1001,
          agents: {
            'dev-box/w2:p1': {'presence': 'done', 'state_seq': 41},
          },
        ),
      );
      final store = project('Storefront');
      final sf = store.entries.firstWhere((e) => e.node.label == 'sf');
      final row = sf.agentRows.single;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showProjectEntrySheet(
                  context,
                  controller,
                  sf,
                  project: store,
                  row: row,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Mark as unread'), findsOneWidget);
      expect(find.byKey(const ValueKey('project-entry-move')), findsOneWidget);
      expect(find.text('Move up'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('project-entry-removeActive')),
      );
      await tester.pump();
      await tester.pump();
      expect(_ops(sent.last.$2).single, {
        'op': 'remove-active',
        'agent': 'dev-box/w2:p1',
        'state_seq': 41,
      });
      final shown = project(
        'Storefront',
      ).entries.firstWhere((e) => e.node.label == 'sf').sheprdOf(row)!;
      expect(shown.removed, isTrue);
      expect(controller.groupPending(project('Storefront')), isTrue);
      // Past the (test) timeout the pending edit is dropped.
      await tester.pump(const Duration(milliseconds: 200));
      expect(controller.pendingEdits, isEmpty);
    });

    test('off: the same actions edit the app\'s own layout', () async {
      await controller.addProject('Mine', rules: ['misc']);
      await controller.addProject('Second', rules: ['notes']);
      await controller.renameProject(project('Mine'), 'Mine2');
      await controller.setShort(project('Mine2'), 'M2');
      await controller.moveProject(project('Mine2'), 1);
      expect(sent, isEmpty);
      final own = theme.projectPrefs.layout!;
      expect(own.groups.map((g) => g.name), ['Second', 'Mine2']);
      expect(own.byName('Mine2')!.short, 'M2');
    });
  });
}
