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
import 'package:conduit/features/sync/data/app_settings_codec.dart';
import 'package:flutter/material.dart';
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

/// A machine with Herdr workspaces `(id, label)`, each holding agents
/// whose pane ids are `<workspace>:<pane>`.
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

/// A `sheprd-view` reply, as the companion prints it.
String _reply(
  String self, {
  int updated = 1000,
  Map<String, Object?> agents = const {},
  List<String> order = const [],
  bool stale = false,
}) =>
    'noise\n${jsonEncode({
      'ok': true,
      'found': true,
      'path': '~/.local/state/sheprd/view.json',
      'stale': stale,
      'view': {
        'version': 1,
        'updated': updated,
        'source': 'sheprd test',
        'hub': 'laptop',
        'self': self,
        'layout': {
          'active_only': true,
          'hidden': ['dev-box/w3:scratch'],
          'ungrouped': <String>[],
          'group': [
            {
              'name': 'Storefront',
              'members': ['local/w1:notes', 'dev-box/w2:sf'],
              'match': <String>[],
            },
          ],
        },
        'agents': agents,
        'order': order,
        'focus': null,
      },
    })}';

void main() {
  group('SheprdView', () {
    test('reads a v1 reply and refuses anything else', () {
      final view = SheprdView.fromReply(
        jsonDecode(
          _reply(
            'dev-box',
            agents: {
              'dev-box/w2:p1': {
                'presence': 'unread',
                'state_seq': 41,
                'unread': true,
              },
              'dev-box/w2:p2': {'presence': 'asleep'},
            },
          ).split('\n').last,
        ),
      )!;
      expect(view.self, 'dev-box');
      expect(view.fromHub, isFalse);
      expect(view.hub, 'laptop');
      expect(view.layout.groups.single.members, [
        'local/w1:notes',
        'dev-box/w2:sf',
      ]);
      expect(view.agents.keys, ['dev-box/w2:p1']);
      expect(view.agents['dev-box/w2:p1']!.stateSeq, 41);

      expect(SheprdView.fromReply({'found': false}), isNull);
      expect(
        SheprdView.fromReply({
          'found': true,
          'view': {'version': 2, 'updated': 1, 'self': 'x'},
        }),
        isNull,
      );
      expect(SheprdView.fromReply({'found': true, 'error': 'bad'}), isNull);
    });

    test('marks change presence like sheprd applies them', () {
      const done = SheprdAgentView(presence: SheprdPresence.done, stateSeq: 4);
      expect(done.after(SheprdMark.dismiss).presence, SheprdPresence.idle);
      expect(done.after(SheprdMark.dismiss).dismissed, isTrue);
      expect(done.after(SheprdMark.unread).presence, SheprdPresence.unread);
      expect(
        done.after(SheprdMark.unread).after(SheprdMark.read).presence,
        SheprdPresence.idle,
      );
      expect(done.after(SheprdMark.keep).kept, isTrue);
      expect(done.after(SheprdMark.keep).active, isTrue);
      expect(SheprdMark.choicesFor(done), [
        SheprdMark.unread,
        SheprdMark.keep,
        SheprdMark.dismiss,
      ]);
      expect(
        SheprdMark.choicesFor(
          done.after(SheprdMark.unread).after(SheprdMark.keep),
        ),
        [SheprdMark.read, SheprdMark.unkeep, SheprdMark.dismiss],
      );
      expect(SheprdMark.choicesFor(null), [SheprdMark.unread, SheprdMark.keep]);
    });
  });

  group('Sync with sheprd', () {
    late ThemeController theme;
    late ProjectLayoutController controller;
    final laptop = _host('h1', 'Laptop');
    final dev = _host('h2', 'Dev');
    final sent = <(String, String)>[];

    setUp(() async {
      theme = ThemeController(InMemoryThemePreferences());
      await theme.load();
      controller =
          ProjectLayoutController(
              theme: theme,
              markTimeout: const Duration(milliseconds: 80),
            )
            ..sheprdRunner = (host, command) async {
              sent.add((host.name, command));
              return '{"ok":true,"id":"c-1-abcd"}';
            };
      sent.clear();
    });
    tearDown(() => controller.dispose());

    List<SidebarNode> tree() => [
      _machine(laptop, {
        ('w1', 'notes'): [_agent('w1:p1', AgentAttentionState.idle)],
      }),
      _machine(dev, {
        ('w2', 'sf'): [
          _agent('w2:p1', AgentAttentionState.finished, seq: 41),
          _agent('w2:p2', AgentAttentionState.idle, seq: 3),
          _agent('w2:p3', AgentAttentionState.finished, seq: 9),
        ],
        ('w9', 'misc'): [_agent('w9:p1', AgentAttentionState.idle)],
      }),
    ];

    test(
      'off by default: nothing changes, and it syncs as a setting',
      () async {
        expect(controller.sheprdSync, isFalse);
        controller.applyViewReply(dev, _reply('dev-box'));
        expect(controller.sheprdView, isNull);
        expect(controller.layout, ProjectLayout.empty);
        final groups = controller.build(tree(), hosts: [laptop, dev]);
        expect(
          groups.every((g) => g.entries.every((e) => e.sheprd.isEmpty)),
          isTrue,
        );

        await controller.setSheprdSync(true);
        final json = AppSettingsCodec.encode(theme);
        expect((json['projects'] as Map)['sheprdSync'], isTrue);
        final other = ThemeController(InMemoryThemePreferences());
        await other.load();
        await AppSettingsCodec.apply(other, json);
        expect(other.projectPrefs.sheprdSync, isTrue);
      },
    );

    test("mirrors sheprd's view with the app's machine names; edits pause, "
        'and turning it off brings the own layout back', () async {
      await controller.addProject('Mine', rules: ['misc']);
      final own = theme.projectPrefs.layout;
      expect(own!.byName('Mine'), isNotNull);

      await controller.setSheprdSync(true);
      // Each machine's copy says which of sheprd's names is that machine.
      controller
        ..applyViewReply(
          laptop,
          _reply(
            'local',
            agents: {
              'dev-box/w2:p1': {
                'presence': 'unread',
                'state_seq': 41,
                'unread': true,
              },
              'dev-box/w2:p2': {
                'presence': 'idle',
                'state_seq': 3,
                'kept': true,
              },
              'dev-box/w2:p3': {
                'presence': 'idle',
                'state_seq': 9,
                'dismissed': true,
              },
            },
            order: ['dev-box/w2:sf', 'local/w1:notes'],
          ),
        )
        ..applyViewReply(dev, _reply('dev-box', updated: 990));
      expect(controller.layout.groups.single.name, 'Storefront');
      expect(controller.layout.groups.single.members, [
        'laptop/w1:notes',
        'dev/w2:sf',
      ]);
      expect(controller.layout.hidden, ['dev/w3:scratch']);
      expect(controller.canEditLayout, isFalse);

      final groups = controller.build(tree(), hosts: [laptop, dev]);
      final store = groups.firstWhere((g) => g.name == 'Storefront');
      // sheprd's order: sf before notes.
      expect([for (final e in store.entries) e.node.label], ['sf', 'notes']);
      final sf = store.entries.first;
      final rows = {for (final row in sf.agentRows) row.label: row};
      expect(sf.dotOf(rows['agent w2:p1']!), SidebarDot.done);
      expect(sf.sheprdOf(rows['agent w2:p2']!)!.kept, isTrue);
      // Dismissed: no longer done, so it is not counted.
      expect(sf.dotOf(rows['agent w2:p3']!), SidebarDot.idle);
      expect(store.done, 1);
      expect(sf.active, isTrue);
      expect(sf.sheprdKeys[rows['agent w2:p1']!.key], 'dev/w2:p1');

      // Edits are ignored while synced.
      await controller.addProject('Ignored');
      await controller.moveTo(sf, 'Elsewhere');
      expect(theme.projectPrefs.layout, own);
      expect(controller.layout.byName('Ignored'), isNull);

      // Off: the app's own layout, as it was.
      await controller.setSheprdSync(false);
      expect(controller.layout, own);
      expect(controller.canEditLayout, isTrue);
      expect(controller.sheprdView, isNull);
    });

    test('marks go back with sheprd\'s names, through the agent\'s machine, '
        'and show at once', () async {
      await controller.setSheprdSync(true);
      controller
        ..applyViewReply(
          laptop,
          _reply(
            'local',
            agents: {
              'dev-box/w2:p1': {'presence': 'done', 'state_seq': 41},
            },
          ),
        )
        ..applyViewReply(dev, _reply('dev-box'));
      ProjectEntry sf() => controller
          .build(tree(), hosts: [laptop, dev])
          .firstWhere((g) => g.name == 'Storefront')
          .entries
          .firstWhere((e) => e.node.label == 'sf');
      SidebarNode row(String pane) =>
          sf().agentRows.firstWhere((r) => r.label == 'agent $pane');

      expect(
        await controller.mark(sf(), row('w2:p1'), SheprdMark.dismiss),
        isNull,
      );
      expect(sent.single.$1, 'Dev');
      expect(
        sent.single.$2,
        allOf(
          contains('sheprd-view-update --op dismiss --agent '),
          contains('dev-box/w2:p1'),
          contains(' --state-seq 41'),
        ),
      );
      // Pending, not applied: the dot and the marks stay sheprd's.
      expect(sf().dotOf(row('w2:p1')), SidebarDot.done);
      expect(sf().sheprdOf(row('w2:p1'))!.dismissed, isFalse);
      expect(sf().sheprdOf(row('w2:p1'))!.pending, SheprdMark.dismiss);

      // An agent sheprd has not listed yet: the live sequence, and the mark
      // is pending too.
      expect(
        await controller.mark(sf(), row('w2:p3'), SheprdMark.keep),
        isNull,
      );
      expect(
        sent.last.$2,
        allOf(contains('--op keep --agent'), contains('dev-box/w2:p3')),
      );
      expect(sent.last.$2, isNot(contains('--state-seq')));
      expect(sf().sheprdOf(row('w2:p3'))!.kept, isFalse);
      expect(sf().sheprdOf(row('w2:p3'))!.pending, SheprdMark.keep);

      // The companion's refusal comes back as the message.
      controller.sheprdRunner = (host, command) async =>
          '{"error":"view-updates.jsonl is full: sheprd is not reading it"}';
      expect(
        await controller.mark(sf(), row('w2:p1'), SheprdMark.unread),
        contains('is full'),
      );
    });

    test('a stale view still mirrors, and says so', () async {
      await controller.setSheprdSync(true);
      controller.applyViewReply(dev, _reply('dev-box', stale: true));
      expect(controller.sheprdView!.stale, isTrue);
      // Without the hub's copy, `local` is the machine named like the hub.
      expect(controller.layout.groups.single.members, [
        'laptop/w1:notes',
        'dev/w2:sf',
      ]);
    });

    testWidgets('a row offers sheprd\'s marks instead of project edits, '
        'and they go back', (tester) async {
      Future<ProjectEntryAction?> sheet(
        ProjectEntry entry,
        ProjectGroup project, {
        SidebarNode? row,
      }) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showProjectEntrySheet(
                    context,
                    controller,
                    entry,
                    project: project,
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
        return null;
      }

      ProjectGroup store() => controller
          .build(tree(), hosts: [laptop, dev])
          .firstWhere((g) => g.name == 'Storefront');

      // Off: the app's own project edits.
      var project = controller.build(tree(), hosts: [laptop, dev]).first;
      await sheet(project.entries.first, project);
      expect(find.byKey(const ValueKey('project-entry-move')), findsOneWidget);
      expect(find.text('Mark as unread'), findsNothing);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      await tester.runAsync(() => controller.setSheprdSync(true));
      controller
        ..applyViewReply(
          laptop,
          _reply(
            'local',
            agents: {
              'dev-box/w2:p1': {'presence': 'done', 'state_seq': 41},
            },
          ),
        )
        ..applyViewReply(dev, _reply('dev-box'));
      project = store();
      final sf = project.entries.firstWhere((e) => e.node.label == 'sf');
      final row = sf.agentRows.firstWhere((r) => r.label == 'agent w2:p1');
      expect(
        projectGroupMenuItems<ProjectGroupAction>(
          project,
          value: (a) => a,
          editable: controller.canEditLayout,
        ),
        isEmpty,
      );
      await sheet(sf, project, row: row);
      expect(find.byKey(const ValueKey('project-entry-move')), findsNothing);
      expect(find.text('Mark as unread'), findsOneWidget);
      expect(find.text('Keep in active'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('project-entry-dismiss')));
      // The mark is sent at once; its 80 ms timeout runs on the test clock.
      await tester.pump();
      await tester.pump();
      expect(sent.single.$2, contains('--op dismiss'));
      expect(
        store().entries
            .firstWhere((e) => e.node.label == 'sf')
            .sheprdOf(row)!
            .pending,
        SheprdMark.dismiss,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListenableBuilder(
              listenable: controller,
              builder: (context, _) =>
                  ProjectViewBar(controller: controller, needsYou: 0),
            ),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('project-mark-notice')), findsNothing);
      // Unconfirmed past the timeout (2 minutes in the app).
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byKey(const ValueKey('project-mark-notice')), findsOneWidget);
      expect(find.textContaining("sheprd didn't apply this"), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('project-mark-notice-close')));
      await tester.pump();
      expect(controller.markNotice, isNull);
    });

    test('a pending mark is confirmed only by a newer view that shows it, '
        'and dropped with a notice when sheprd never does', () async {
      await controller.setSheprdSync(true);
      Map<String, Object?> agent({bool dismissed = false}) => {
        'dev-box/w2:p1': {
          'presence': dismissed ? 'idle' : 'done',
          'state_seq': 41,
          'dismissed': dismissed,
        },
      };
      controller
        ..applyViewReply(laptop, _reply('local', agents: agent()))
        ..applyViewReply(dev, _reply('dev-box'));
      ProjectEntry sf() => controller
          .build(tree(), hosts: [laptop, dev])
          .firstWhere((g) => g.name == 'Storefront')
          .entries
          .firstWhere((e) => e.node.label == 'sf');
      SidebarNode row() =>
          sf().agentRows.firstWhere((r) => r.label == 'agent w2:p1');
      SheprdAgentView view() => sf().sheprdOf(row())!;

      expect(await controller.mark(sf(), row(), SheprdMark.dismiss), isNull);
      expect(view().pending, SheprdMark.dismiss);
      // The menu already offers what comes after it.
      expect(
        SheprdMark.choicesFor(view()),
        isNot(contains(SheprdMark.dismiss)),
      );

      // A newer view without the mark: still pending.
      controller.applyViewReply(
        laptop,
        _reply('local', updated: 1010, agents: agent()),
      );
      expect(view().pending, SheprdMark.dismiss);
      // A newer view with it: applied, no longer pending, no notice later.
      controller.applyViewReply(
        laptop,
        _reply('local', updated: 1020, agents: agent(dismissed: true)),
      );
      expect(view().pending, isNull);
      expect(view().dismissed, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(controller.markNotice, isNull);

      // Never confirmed: reverted after the timeout, with the notice.
      expect(await controller.mark(sf(), row(), SheprdMark.keep), isNull);
      expect(view().pending, SheprdMark.keep);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(view().pending, isNull);
      expect(view().kept, isFalse);
      expect(controller.markNotice, contains("sheprd didn't apply this"));
      controller.clearMarkNotice();
      expect(controller.markNotice, isNull);
    });

    testWidgets('synced with no view.json anywhere: the app keeps its own '
        'layout and says how to share sheprd\'s view', (tester) async {
      await tester.runAsync(() => controller.addProject('Mine', rules: ['sf']));
      final own = controller.layout;
      await tester.runAsync(() => controller.setSheprdSync(true));
      // Nothing heard yet: no notice.
      expect(controller.sheprdNotSharing, isNull);
      controller
        ..applyViewReply(laptop, '{"ok":true,"found":false}')
        ..applyViewReply(dev, '{"ok":true,"found":false}');
      expect(controller.mirroring, isFalse);
      expect(controller.layout, own);
      expect(controller.canEditLayout, isTrue);
      expect(controller.sheprdNotSharing, contains('share_view = true'));
      final groups = controller.build(tree(), hosts: [laptop, dev]);
      expect(groups.first.name, 'Mine');
      expect(
        groups.every((g) => g.entries.every((e) => e.sheprd.isEmpty)),
        isTrue,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListenableBuilder(
              listenable: controller,
              builder: (context, _) =>
                  ProjectViewBar(controller: controller, needsYou: 0),
            ),
          ),
        ),
      );
      expect(
        find.textContaining("sheprd isn't sharing its view yet"),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('project-mark-notice-close')),
        findsNothing,
      );

      // Once a machine shares it, the view mirrors sheprd.
      controller.applyViewReply(dev, _reply('dev-box'));
      expect(controller.mirroring, isTrue);
      expect(controller.sheprdNotSharing, isNull);
      expect(controller.layout.groups.single.name, 'Storefront');
    });

    test(
      'removed from the active view: hidden in active, listed in all',
      () async {
        await controller.setSheprdSync(true);
        controller.applyViewReply(
          dev,
          _reply(
            'dev-box',
            agents: {
              'dev-box/w2:p1': {
                'presence': 'done',
                'state_seq': 41,
                'removed': true,
              },
              'dev-box/w2:p2': {'presence': 'working', 'state_seq': 3},
            },
          ),
        );
        ProjectEntry sf() => controller
            .build(tree(), hosts: [laptop, dev])
            .firstWhere((g) => g.name == 'Storefront')
            .entries
            .firstWhere((e) => e.node.label == 'sf');
        SidebarNode row(String pane) =>
            sf().agentRows.firstWhere((r) => r.label == 'agent $pane');
        expect(sf().sheprdOf(row('w2:p1'))!.removed, isTrue);
        expect(sf().sheprdOf(row('w2:p1'))!.active, isFalse);

        await controller.setActiveOnly(true);
        expect(controller.removedFromActive(sf(), row('w2:p1')), isTrue);
        expect(controller.removedFromActive(sf(), row('w2:p2')), isFalse);
        await controller.setActiveOnly(false);
        expect(controller.removedFromActive(sf(), row('w2:p1')), isFalse);

        // Only removed agents left: the workspace drops out of "active".
        controller.applyViewReply(
          dev,
          _reply(
            'dev-box',
            updated: 1001,
            agents: {
              'dev-box/w2:p1': {'presence': 'done', 'removed': true},
              'dev-box/w2:p2': {'presence': 'idle', 'removed': true},
              'dev-box/w2:p3': {'presence': 'idle'},
            },
          ),
        );
        expect(sf().active, isFalse);
      },
    );

    test('the hint names the sheprd release with view sharing', () {
      expect(
        ProjectLayoutController.sheprdNotSharingText,
        contains(
          "set share_view = true in sheprd's sidebar.toml "
          '(sheprd ≥ 0.9.3-15)',
        ),
      );
    });
  });
}
