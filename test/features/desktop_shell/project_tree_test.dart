import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/desktop_shell/domain/project_tree.dart';
import 'package:conduit/features/desktop_shell/domain/sidebar_tree.dart';
import 'package:conduit/features/desktop_shell/presentation/widgets/project_sidebar.dart';
import 'package:conduit/features/sessions/domain/remote_session_listing.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

SidebarNode _machine(String id, List<String> tmux) {
  final host = buildHost(id);
  return SidebarNode(
    key: SidebarKeys.machine(id),
    kind: SidebarNodeKind.machine,
    machineId: id,
    label: id,
    target: MachineTarget(host),
    children: [
      for (final name in tmux)
        SidebarNode(
          key: SidebarKeys.tmuxSession(id, name),
          kind: SidebarNodeKind.tmuxSession,
          machineId: id,
          label: name,
          target: TmuxSessionTarget(host, TmuxSessionInfo(name: name)),
        ),
    ],
  );
}

AgentInfo _agent(
  String id,
  String tab,
  AgentAttentionState state, {
  String? project,
  String? workspace,
}) => AgentInfo(
  id: id,
  name: id,
  state: state,
  tab: tab,
  project: project,
  workspace: workspace,
);

void main() {
  test('rows group by the project their agents report, across machines', () {
    final projects = ProjectTreeBuilder.build(
      [
        _machine('omarchy', ['vtm', 'scratch']),
        _machine('dev-central', ['visit', 'infra']),
      ],
      agentsByMachine: {
        'omarchy': [
          _agent(
            'a1',
            'vtm:0',
            AgentAttentionState.needsInput,
            workspace: '/home/andre/src/VisitTomar',
          ),
        ],
        'dev-central': [
          _agent(
            'a2',
            'visit',
            AgentAttentionState.working,
            project: 'VisitTomar',
            workspace: '/root/Projects/VisitTomar',
          ),
          _agent(
            'a3',
            'visit:1',
            AgentAttentionState.finished,
            project: 'VisitTomar',
          ),
        ],
      },
    );
    // Needs-you first, then by name.
    expect(projects.map((p) => p.name), ['VisitTomar', 'infra', 'scratch']);
    final vtm = projects.first;
    expect(vtm.members.map((node) => node.label), ['vtm', 'visit']);
    expect(vtm.machineIds, {'omarchy', 'dev-central'});
    expect((vtm.needsYou, vtm.working, vtm.done), (1, 1, 1));
    expect(vtm.dot, SidebarDot.needsYou);
    expect(vtm.locations, [
      const ProjectLocation('omarchy', '/home/andre/src/VisitTomar'),
      const ProjectLocation('dev-central', '/root/Projects/VisitTomar'),
    ]);
    // Rows without agents are their own project, with no location.
    expect(projects[1].locations, isEmpty);
    expect(projects[1].dot, SidebarDot.none);
  });

  test('monograms take the first letters of the words', () {
    expect(ProjectIcon.monogram('VisitTomar'), 'VT');
    expect(ProjectIcon.monogram('conductore-mobile'), 'CM');
    expect(ProjectIcon.monogram('api'), 'A');
    expect(ProjectIcon.monogram('--'), '?');
  });
}
