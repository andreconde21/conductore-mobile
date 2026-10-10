import 'dart:convert';

import 'package:conduit/core/theme/theme_controller.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/desktop_shell/presentation/project_layout_controller.dart';
import 'package:conduit/features/home_widget/domain/agent_status_snapshot.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

/// The launcher's `project` and `active` columns (contract 3, CON-119):
/// what Dart writes for them in the snapshot.
void main() {
  late ThemeController theme;
  late ProjectLayoutController projects;
  const dev = SavedHost(
    id: 'h1',
    name: 'Dev',
    host: 'dev.tail',
    port: 22,
    username: 'u',
    authMethod: SshAuthMethod.password,
  );

  setUp(() async {
    theme = ThemeController(InMemoryThemePreferences());
    await theme.load();
    projects = ProjectLayoutController(theme: theme);
  });
  tearDown(() => projects.dispose());

  AgentInfo agent(String id, AgentAttentionState state, {String? cwd}) =>
      AgentInfo(id: id, name: 'agent $id', state: state, workspace: cwd);

  void layout() => projects.applyReply(
    dev,
    'noise\n${jsonEncode({
      'ok': true,
      'found': true,
      'layout': {
        'group': [
          {
            'name': 'Storefront',
            'match': ['storefront'],
            'members': <String>[],
          },
        ],
        'recent_hours': 6,
      },
    })}',
  );

  test('the project is the group the project view puts it in; Other is '
      'null', () {
    layout();
    expect(
      projects
          .launcherFacts(
            dev,
            agent('s1', AgentAttentionState.working, cwd: '/home/u/storefront'),
          )
          .project,
      'Storefront',
    );
    expect(
      projects
          .launcherFacts(
            dev,
            agent('s2', AgentAttentionState.idle, cwd: '/home/u/notes'),
          )
          .project,
      isNull,
    );
    // The same as the agents dashboard's grouping.
    final notes = agent('s2', AgentAttentionState.idle, cwd: '/home/u/notes');
    expect(projects.projectOfAgent(dev, live: notes), isNot('Storefront'));
    expect(projects.recentHours, 6);
  });

  test('busy is what the "active" filter keeps whatever the last change', () {
    bool busy(AgentAttentionState state) =>
        projects.launcherFacts(dev, agent('s', state)).busy;
    expect(busy(AgentAttentionState.working), isTrue);
    expect(busy(AgentAttentionState.needsInput), isTrue);
    expect(busy(AgentAttentionState.blocked), isTrue);
    // A finished agent's dot is "done", which the filter keeps.
    expect(busy(AgentAttentionState.finished), isTrue);
    expect(busy(AgentAttentionState.idle), isFalse);
    expect(busy(AgentAttentionState.unknown), isFalse);
  });

  test("with Sync with sheprd, sheprd's active view decides busy", () async {
    await projects.setSheprdSync(true);
    projects.applyViewReply(
      dev,
      'noise\n${jsonEncode({
        'ok': true,
        'found': true,
        'stale': false,
        'view': {
          'version': 1,
          'updated': 1000,
          'source': 'sheprd test',
          'hub': 'dev-box',
          'self': 'dev-box',
          'layout': {'group': <Object>[], 'hidden': <String>[], 'ungrouped': <String>[]},
          'agents': {
            'dev-box/w2:p1': {'presence': 'idle', 'state_seq': 3, 'kept': true},
            'dev-box/w2:p2': {'presence': 'working', 'state_seq': 9, 'removed': true},
          },
          'order': <String>[],
          'focus': null,
        },
      })}',
    );
    expect(projects.sheprdView, isNotNull);
    AgentInfo pane(String id, AgentAttentionState state) =>
        AgentInfo(id: id, name: id, state: state, pane: id, workspace: 'w2');
    // Kept in the active view while idle; taken out of it while working.
    expect(
      projects.launcherFacts(dev, pane('w2:p1', AgentAttentionState.idle)).busy,
      isTrue,
    );
    expect(
      projects
          .launcherFacts(dev, pane('w2:p2', AgentAttentionState.working))
          .busy,
      isFalse,
    );
    // An agent sheprd does not list: its own state.
    expect(
      projects
          .launcherFacts(dev, pane('w2:p9', AgentAttentionState.working))
          .busy,
      isTrue,
    );
  });

  test('the snapshot carries project, busy and the recent hours', () {
    layout();
    final at = DateTime.utc(2026, 10, 10, 12);
    final snapshot = AgentStatusSnapshot.build(
      hosts: [
        (
          hostId: 'h1',
          hostName: 'Dev',
          agents: [
            agent('s1', AgentAttentionState.idle, cwd: '/home/u/storefront'),
            agent('s2', AgentAttentionState.working, cwd: '/home/u/notes'),
          ],
        ),
      ],
      monitoring: true,
      now: at,
      projectOf: (hostId, agent) =>
          hostId == dev.id ? projects.launcherFacts(dev, agent) : null,
      recentHours: projects.recentHours,
    );
    final json = snapshot.toJson();
    expect(json['recentHours'], 6);
    final agents = (json['agents']! as List).cast<Map<String, Object?>>();
    final byId = {for (final agent in agents) agent['agentId']: agent};
    expect(byId['s1']!['project'], 'Storefront');
    expect(byId['s1']!['busy'], isFalse);
    // Other: no project key at all (the native side reads null).
    expect(byId['s2']!.containsKey('project'), isFalse);
    expect(byId['s2']!['busy'], isTrue);
    expect(AgentStatusSnapshot.decode(snapshot.encode()), snapshot);
  });

  test('without a project view the snapshot leaves them out', () {
    final snapshot = AgentStatusSnapshot.build(
      hosts: [
        (
          hostId: 'h1',
          hostName: 'Dev',
          agents: [agent('s1', AgentAttentionState.idle)],
        ),
      ],
      monitoring: true,
      now: DateTime.utc(2026),
    );
    final json = snapshot.toJson();
    expect(json.containsKey('recentHours'), isFalse);
    final entry = (json['agents']! as List).single as Map<String, Object?>;
    expect(entry.containsKey('project'), isFalse);
    expect(entry.containsKey('busy'), isFalse);
  });
}
