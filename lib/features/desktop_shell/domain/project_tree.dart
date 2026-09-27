import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/desktop_shell/domain/sidebar_tree.dart';
import 'package:flutter/foundation.dart';

/// Where a project's repo lives on a machine (an agent's working
/// directory there).
@immutable
class ProjectLocation {
  const ProjectLocation(this.machineId, this.path);

  final String machineId;
  final String path;

  @override
  bool operator ==(Object other) =>
      other is ProjectLocation &&
      other.machineId == machineId &&
      other.path == path;

  @override
  int get hashCode => Object.hash(machineId, path);

  @override
  String toString() => 'ProjectLocation($machineId, $path)';
}

/// One project (repo) of the Projects tab: its workspaces, tmux sessions
/// and open sessions on every machine, and how its agents are doing.
@immutable
class ProjectGroup {
  const ProjectGroup({
    required this.key,
    required this.name,
    required this.members,
    this.needsYou = 0,
    this.working = 0,
    this.done = 0,
    this.locations = const [],
  });

  /// The name, lower-cased: projects of the same name on several machines
  /// are one.
  final String key;
  final String name;

  /// Machine-tree rows (workspaces, tmux sessions, open sessions), each
  /// still opening and dragging like in the Machines tab.
  final List<SidebarNode> members;
  final int needsYou;
  final int working;
  final int done;

  /// Where the repo is on each machine that has it, when an agent said.
  final List<ProjectLocation> locations;

  /// The most urgent state in the project.
  SidebarDot get dot => needsYou > 0
      ? SidebarDot.needsYou
      : working > 0
      ? SidebarDot.working
      : done > 0
      ? SidebarDot.done
      : SidebarDot.none;

  /// The machines it is on.
  Set<String> get machineIds => {for (final node in members) node.machineId};

  @override
  String toString() => 'ProjectGroup($name, ${members.length} rows)';
}

/// Groups the machine tree by project: every workspace, tmux session and
/// open session goes under the project its agents report (the git repo's
/// name from the companion, or the basename of their working directory),
/// else under its own name. The same name on several machines is one
/// project.
abstract final class ProjectTreeBuilder {
  static List<ProjectGroup> build(
    List<SidebarNode> tree, {
    Map<String, List<AgentInfo>> agentsByMachine = const {},
  }) {
    final groups = <String, _Group>{};
    for (final machine in tree) {
      final agents = agentsByMachine[machine.machineId] ?? const [];
      for (final node in machine.children) {
        final nodeAgents = _agentsOf(node, agents);
        final name = _projectName(node, nodeAgents);
        final group = groups.putIfAbsent(
          name.toLowerCase(),
          () => _Group(name),
        );
        group.members.add(node);
        final panes = [
          for (final row in node.descendantsAndSelf)
            if (row.kind == SidebarNodeKind.agentPane) row,
        ];
        if (panes.isNotEmpty) {
          for (final pane in panes) {
            group.count(pane.key, pane.dot);
          }
        } else if (nodeAgents.isNotEmpty) {
          for (final agent in nodeAgents) {
            group.count(
              '${machine.machineId}/${agent.id}',
              SidebarDot.of(agent.state),
            );
          }
        } else {
          group.count(node.key, node.dot);
        }
        for (final agent in nodeAgents) {
          final path = _pathOf(agent);
          if (path != null) {
            group.locations.add(ProjectLocation(machine.machineId, path));
          }
        }
      }
    }
    final result = [
      for (final group in groups.values)
        ProjectGroup(
          key: group.name.toLowerCase(),
          name: group.name,
          members: group.members,
          needsYou: group.dots.values
              .where((dot) => dot == SidebarDot.needsYou)
              .length,
          working: group.dots.values
              .where((dot) => dot == SidebarDot.working)
              .length,
          done: group.dots.values.where((dot) => dot == SidebarDot.done).length,
          locations: group.locations.toList(),
        ),
    ];
    result.sort((a, b) {
      final byDot = b.dot.index.compareTo(a.dot.index);
      if (byDot != 0) return byDot;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return result;
  }

  /// The agents working in [node]: its panes' agents, and the companion's
  /// agents reported in that Herdr workspace or tmux session.
  static List<AgentInfo> _agentsOf(SidebarNode node, List<AgentInfo> agents) {
    switch (node.target) {
      case HerdrWorkspaceTarget(:final workspace):
        final byId = <String, AgentInfo>{
          for (final pane in workspace.panes) pane.agent.id: pane.agent,
          for (final agent in agents)
            if (agent.workspace == workspace.id) agent.id: agent,
        };
        return byId.values.toList();
      case TmuxSessionTarget(:final session):
        return [
          for (final agent in agents)
            if (agent.tab == session.name ||
                (agent.tab?.startsWith('${session.name}:') ?? false))
              agent,
        ];
      default:
        return const [];
    }
  }

  /// The project most of [agents] report, else the row's own name.
  static String _projectName(SidebarNode node, List<AgentInfo> agents) {
    final votes = <String, int>{};
    for (final agent in agents) {
      final project = agent.projectLabel?.trim();
      if (project == null || project.isEmpty) continue;
      votes[project] = (votes[project] ?? 0) + 1;
    }
    if (votes.isEmpty) return node.label;
    return votes.entries.reduce((a, b) => b.value > a.value ? b : a).key;
  }

  /// The agent's working directory, when the companion reported one.
  static String? _pathOf(AgentInfo agent) {
    final raw = agent.workspace?.trim();
    if (raw == null || raw.isEmpty) return null;
    return raw.startsWith('/') || raw.startsWith('~') ? raw : null;
  }
}

class _Group {
  _Group(this.name);

  final String name;
  final members = <SidebarNode>[];

  /// The state of each agent (or row) in it, by key: one agent counts once.
  final dots = <String, SidebarDot>{};
  final locations = <ProjectLocation>{};

  void count(String key, SidebarDot dot) {
    if (dot == SidebarDot.none) return;
    dots[key] = dot;
  }
}
