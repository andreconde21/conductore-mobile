import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/desktop_shell/domain/project_layout.dart';
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

/// One workspace, tmux session or open session in a project, with the
/// agent rows the detailed view lists under the project.
@immutable
class ProjectEntry {
  const ProjectEntry({
    required this.node,
    required this.memberKey,
    this.agentRows = const [],
    this.active = true,
    this.hidden = false,
  });

  /// The machine-tree row (opens and drags like in the Machines tab).
  final SidebarNode node;

  /// Its key in the project layout (`machine/<id>:<label>`, see
  /// [ProjectKeys]).
  final String memberKey;

  /// Its agents' rows (panes, or a tab holding one agent), for the
  /// detailed view; empty when the row is the only thing to show.
  final List<SidebarNode> agentRows;

  /// Working, waiting, finished, open in the app, or changed state within
  /// the recent hours: kept by the "active" filter.
  final bool active;

  /// In the layout's hidden list (shown only with "show hidden").
  final bool hidden;

  SidebarDot get dot => node.dot;

  @override
  String toString() => 'ProjectEntry($memberKey)';
}

/// One project of the Projects view: its workspaces, tmux sessions and
/// open sessions on every machine, and how its agents are doing. "Other"
/// is a project too ([isOther]), always last.
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
    this.entries = const [],
    this.agents = const [],
    this.pinned = false,
    this.isOther = false,
    this.inLayout = false,
    this.short,
  });

  /// The key of "Other".
  static const otherKey = '\u0000other';

  /// The name, lower-cased: projects of the same name on several machines
  /// are one.
  final String key;
  final String name;

  /// Machine-tree rows (workspaces, tmux sessions, open sessions), each
  /// still opening and dragging like in the Machines tab. The rows of
  /// [entries] that are not hidden.
  final List<SidebarNode> members;
  final int needsYou;
  final int working;
  final int done;

  /// Where the repo is on each machine that has it, when an agent said.
  final List<ProjectLocation> locations;

  /// Every row of the project in display order, hidden ones included.
  final List<ProjectEntry> entries;

  /// Its agents, with the machine each runs on.
  final List<(String machineId, AgentInfo agent)> agents;
  final bool pinned;
  final bool isOther;

  /// Defined in the project layout (sheprd's sidebar.toml or the app's
  /// own), as opposed to found from what the agents report.
  final bool inLayout;

  /// The layout's own two-letter tag, if it set one.
  final String? short;

  /// Two letters for tight spots (sheprd's rail tag).
  String get tag => projectTag(name, short);

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

/// Groups the machine tree by project, sheprd's way. With a [ProjectLayout]
/// that names projects, a row goes to the project listing it, else to the
/// first whose rule is a substring of its name, folders or reported repo,
/// else to Other (and a row moved to Other stays there). With none, a row
/// goes under the project its agents report (the git repo's name from the
/// companion, or the basename of their working directory), else to Other.
/// The same name on several machines is one project; layout projects come
/// in the layout's order (pinned first), found ones by urgency, then Other.
abstract final class ProjectTreeBuilder {
  static List<ProjectGroup> build(
    List<SidebarNode> tree, {
    Map<String, List<AgentInfo>> agentsByMachine = const {},
    ProjectLayout layout = ProjectLayout.empty,
    Map<String, Set<String>> machineAliases = const {},
    DateTime? now,
    int recentHours = ProjectPrefs.defaultRecentHours,
  }) {
    final clock = now ?? DateTime.now();
    final recent = Duration(hours: recentHours);
    final byLayout = layout.groups.isNotEmpty;
    final groups = <String, _Group>{};
    if (byLayout) {
      for (final index in layout.displayOrder) {
        final def = layout.groups[index];
        groups[def.name.toLowerCase()] = _Group(
          def.name,
          def: def,
          rank: index,
        );
      }
    }
    final other = _Group('Other', other: true);
    for (final machine in tree) {
      final agents = agentsByMachine[machine.machineId] ?? const [];
      final names = <String>{
        machine.label.toLowerCase(),
        for (final alias
            in machineAliases[machine.machineId] ?? const <String>{})
          if (alias.trim().isNotEmpty) alias.trim().toLowerCase(),
      };
      for (final node in machine.children) {
        final nodeAgents = _agentsOf(node, agents);
        final keys = [for (final name in names) _memberKey(name, node)];
        final haystack = [
          node.label,
          for (final agent in nodeAgents) ...[
            ?_pathOf(agent),
            ?agent.projectLabel,
          ],
        ];
        final _Group group;
        var rank = 1 << 30;
        if (byLayout) {
          final index = _groupOf(layout, keys, haystack);
          if (index == null) {
            group = other;
          } else {
            group = groups[layout.groups[index].name.toLowerCase()]!;
            for (final key in keys) {
              final at = layout.memberRank(index, key);
              if (at < rank) rank = at;
            }
          }
        } else {
          final name =
              layout.ungrouped.any(
                (entry) => keys.any((key) => ProjectKeys.same(entry, key)),
              )
              ? null
              : _projectName(nodeAgents);
          group = name == null
              ? other
              : groups.putIfAbsent(name.toLowerCase(), () => _Group(name));
        }
        final hidden = keys.any(layout.isHidden);
        final agentRows = _agentRows(node);
        final active = _isActive(node, nodeAgents, agentRows, clock, recent);
        group.entries.add((
          rank,
          ProjectEntry(
            node: node,
            memberKey: keys.first,
            agentRows: agentRows,
            active: active,
            hidden: hidden,
          ),
        ));
        if (hidden) continue;
        for (final agent in nodeAgents) {
          group.agents.add((machine.machineId, agent));
        }
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
    final found =
        [
          for (final group in groups.values)
            if (group.def == null) group.build(),
        ]..sort((a, b) {
          final byDot = b.dot.index.compareTo(a.dot.index);
          if (byDot != 0) return byDot;
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        });
    return [
      for (final group in groups.values)
        if (group.def != null) group.build(),
      ...found,
      if (other.entries.isNotEmpty) other.build(),
    ];
  }

  /// [node]'s key in the layout as machine [machine] names it.
  static String _memberKey(String machine, SidebarNode node) =>
      switch (node.target) {
        HerdrWorkspaceTarget(:final workspace) => ProjectKeys.herdr(
          machine,
          workspace.id,
          workspace.label,
        ),
        _ => ProjectKeys.named(machine, node.label),
      };

  /// [ProjectLayout.groupOf] for a row known by several keys (one per
  /// name of its machine).
  static int? _groupOf(
    ProjectLayout layout,
    List<String> keys,
    List<String> haystack,
  ) {
    if (keys.any(layout.isUngrouped)) return null;
    for (final key in keys) {
      final explicit = layout.explicitGroup(key);
      if (explicit != null) return explicit;
    }
    return layout.groupOf(keys.first, haystack);
  }

  /// The rows the detailed view lists for [node]'s agents: its panes, and
  /// tabs that carry their single agent themselves.
  static List<SidebarNode> _agentRows(SidebarNode node) => [
    for (final row in node.descendantsAndSelf)
      if (row != node &&
          (row.kind == SidebarNodeKind.agentPane ||
              (row.kind == SidebarNodeKind.herdrTab &&
                  row.children.isEmpty &&
                  row.agentKind != null &&
                  row.dot != SidebarDot.none)))
        row,
  ];

  static bool _isActive(
    SidebarNode node,
    List<AgentInfo> agents,
    List<SidebarNode> agentRows,
    DateTime now,
    Duration recent,
  ) {
    bool busy(SidebarDot dot) =>
        dot == SidebarDot.needsYou ||
        dot == SidebarDot.working ||
        dot == SidebarDot.done;
    if (node.openInApp || busy(node.dot)) return true;
    if (agentRows.any((row) => busy(row.dot))) return true;
    for (final agent in agents) {
      if (agent.state.needsAttention ||
          agent.state == AgentAttentionState.working) {
        return true;
      }
      final at = agent.stateChangedAt;
      if (at != null && now.difference(at) < recent) return true;
    }
    return false;
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

  /// The project most of [agents] report, if any does.
  static String? _projectName(List<AgentInfo> agents) {
    final votes = <String, int>{};
    for (final agent in agents) {
      final project = agent.projectLabel?.trim();
      if (project == null || project.isEmpty) continue;
      votes[project] = (votes[project] ?? 0) + 1;
    }
    if (votes.isEmpty) return null;
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
  _Group(this.name, {this.def, this.rank = 0, this.other = false});

  final String name;
  final ProjectDef? def;
  final int rank;
  final bool other;

  /// (rank in the layout's members, entry), sorted stably at the end.
  final entries = <(int, ProjectEntry)>[];
  final agents = <(String, AgentInfo)>[];

  /// The state of each agent (or row) in it, by key: one agent counts once.
  final dots = <String, SidebarDot>{};
  final locations = <ProjectLocation>{};

  void count(String key, SidebarDot dot) {
    if (dot == SidebarDot.none) return;
    dots[key] = dot;
  }

  ProjectGroup build() {
    final ranked =
        [
          for (final (index, (rank, entry)) in entries.indexed)
            (rank, index, entry),
        ]..sort((a, b) {
          final byRank = a.$1.compareTo(b.$1);
          return byRank != 0 ? byRank : a.$2.compareTo(b.$2);
        });
    final ordered = [for (final item in ranked) item.$3];
    return ProjectGroup(
      key: other ? ProjectGroup.otherKey : name.toLowerCase(),
      name: name,
      members: [
        for (final entry in ordered)
          if (!entry.hidden) entry.node,
      ],
      entries: ordered,
      agents: agents,
      needsYou: dots.values.where((dot) => dot == SidebarDot.needsYou).length,
      working: dots.values.where((dot) => dot == SidebarDot.working).length,
      done: dots.values.where((dot) => dot == SidebarDot.done).length,
      locations: locations.toList(),
      pinned: def?.pinned ?? false,
      isOther: other,
      inLayout: def != null,
      short: def?.short,
    );
  }
}
