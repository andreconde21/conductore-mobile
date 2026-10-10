import 'package:conduit/features/desktop_shell/domain/project_tree.dart';
import 'package:conduit/features/desktop_shell/domain/sidebar_tree.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

SidebarNode _tab(String label, String detail) => SidebarNode(
  key: 'm/w/$label/$detail',
  kind: SidebarNodeKind.herdrTab,
  machineId: 'm',
  label: label,
  detail: detail,
  target: MachineTarget(buildHost('m')),
);

void main() {
  AgentRowText of(
    SidebarNode row, {
    String workspace = 'cockpit-board',
    String project = 'Cockpit',
  }) => AgentRowText.of(
    row,
    workspace: workspace,
    projectName: project,
    machine: 'omarchy',
  );

  test('the sidebar text leads; a numeric tab stays as "tab N"', () {
    final text = of(_tab('1', 'DTech presentation and event materials'));
    expect(text.title, 'DTech presentation and event materials');
    expect(text.subtitle, 'tab 1 · cockpit-board · omarchy');
  });

  test('a workspace named like its project is not repeated', () {
    final text = of(_tab('2', 'CI/CD setup'), workspace: 'Cockpit');
    expect(text.subtitle, 'tab 2 · omarchy');
  });

  test('no sidebar text: the tab name leads and is not repeated', () {
    final text = of(_tab('build', ''));
    expect(text.title, 'build');
    expect(text.subtitle, 'cockpit-board · omarchy');
  });

  test('a title equal to the workspace is not said twice', () {
    final text = of(_tab('1', 'Improvise'), workspace: 'improvise');
    expect(text.title, 'Improvise');
    expect(text.subtitle, 'tab 1 · omarchy');
  });

  test('same-named workspaces differ by title', () {
    final a = of(_tab('1', 'Fix login'));
    final b = of(_tab('1', 'Write docs'));
    expect(a.title, isNot(b.title));
  });

  test('a pane row keeps its own title and has no tab name', () {
    final pane = SidebarNode(
      key: 'p',
      kind: SidebarNodeKind.agentPane,
      machineId: 'm',
      label: 'Refactor tests',
      detail: 'working',
      target: MachineTarget(buildHost('m')),
    );
    final text = of(pane);
    expect(text.title, 'Refactor tests');
    expect(text.subtitle, 'cockpit-board · omarchy');
  });

  SidebarNode ws(List<SidebarNode> kids) => SidebarNode(
    key: 'ws',
    kind: SidebarNodeKind.herdrWorkspace,
    machineId: 'm',
    label: 'Projects',
    target: MachineTarget(buildHost('m')),
    children: kids,
  );

  test('a workspace row with one agent shows that agent\'s title', () {
    final tab = _tab('1', 'Fix the login bug');
    final text = AgentRowText.ofEntry(
      ProjectEntry(node: ws([tab]), memberKey: 'm/ws', agentRows: [tab]),
      projectName: 'Other',
      machine: 'omarchy',
    );
    expect(text.title, 'Fix the login bug');
    expect(text.subtitle, 'tab 1 · Projects · omarchy');
  });

  test('a workspace row with no or several agents keeps its name', () {
    final a = _tab('1', 'A');
    final b = _tab('2', 'B');
    final text = AgentRowText.ofEntry(
      ProjectEntry(node: ws([a, b]), memberKey: 'm/ws', agentRows: [a, b]),
      projectName: 'Other',
      machine: 'omarchy',
    );
    expect(text.title, 'Projects');
    expect(text.subtitle, 'omarchy');
  });
}
