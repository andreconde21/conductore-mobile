import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/desktop_shell/domain/project_layout.dart';
import 'package:conduit/features/desktop_shell/domain/sheprd_view.dart';
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
    this.sheprd = const {},
    this.sheprdKeys = const {},
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

  /// With "Sync with sheprd": sheprd's view of the agents in this row, by
  /// the agent row's key ([node]'s own key for a row that is its only
  /// agent).
  final Map<String, SheprdAgentView> sheprd;

  /// The same agents' keys as sheprd names them (`machine/pane_id`, with
  /// the app's machine names), for marks sent back.
  final Map<String, String> sheprdKeys;

  /// sheprd's view of [row] (one of [agentRows], or [node]), if synced.
  SheprdAgentView? sheprdOf(SidebarNode row) => sheprd[row.key];

  /// [row]'s dot: sheprd's presence when synced, else its own.
  SidebarDot dotOf(SidebarNode row) => sheprd[row.key]?.presence.dot ?? row.dot;

  /// The row's dot: its agents' presence in sheprd when synced.
  SidebarDot get dot {
    if (sheprd.isEmpty) return node.dot;
    var dot = SidebarDot.none;
    for (final view in sheprd.values) {
      dot = dot.max(view.presence.dot);
    }
    return dot;
  }

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
/// else to Other (and a row moved to Other stays there). With none (CON-032),
/// a row goes under the project its agents report (the git repo's name from
/// the companion, or the basename of their working directory), else under
/// its own name; only rows moved to Other go there.
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
    Map<String, SheprdAgentView>? sheprd,
    List<String> order = const [],
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
            ?agent.repoLabel,
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
          final placed = _orderOf(order, keys);
          if (placed != null) rank = placed;
        } else {
          final name = keys.any(layout.isUngrouped)
              ? null
              : _projectName(nodeAgents) ?? node.label;
          group = name == null
              ? other
              : groups.putIfAbsent(name.toLowerCase(), () => _Group(name));
        }
        final hidden = keys.any(layout.isHidden);
        final agentRows = _agentRows(node);
        final views = <String, SheprdAgentView>{};
        final viewKeys = <String, String>{};
        if (sheprd != null) {
          for (final (rowKey, paneId) in _panesOf(node, agentRows)) {
            for (final name in names) {
              final key = '$name/$paneId';
              final view = sheprd[key];
              if (view == null) continue;
              views[rowKey] = view;
              viewKeys[rowKey] = key;
              break;
            }
            viewKeys.putIfAbsent(rowKey, () => '${names.first}/$paneId');
          }
        }
        final active = views.isEmpty
            ? _isActive(node, nodeAgents, agentRows, clock, recent)
            : node.openInApp ||
                  views.values.any((view) => view.active) ||
                  nodeAgents.any(
                    (agent) =>
                        agent.stateChangedAt != null &&
                        clock.difference(agent.stateChangedAt!) < recent,
                  );
        group.entries.add((
          rank,
          ProjectEntry(
            node: node,
            memberKey: keys.first,
            agentRows: agentRows,
            active: active,
            hidden: hidden,
            sheprd: views,
            sheprdKeys: viewKeys,
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
            group.count(pane.key, views[pane.key]?.presence.dot ?? pane.dot);
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

  /// Where sheprd's [order] puts a row known by [keys], if it lists it.
  static int? _orderOf(List<String> order, List<String> keys) {
    for (var i = 0; i < order.length; i++) {
      if (keys.any((key) => ProjectKeys.same(order[i], key))) return i;
    }
    return null;
  }

  /// The Herdr panes of [node]'s agent rows as (row key, pane id); a
  /// workspace row whose only agent it is stands for that agent itself.
  static List<(String, String)> _panesOf(
    SidebarNode node,
    List<SidebarNode> agentRows,
  ) {
    String? paneOf(SidebarNode row) => switch (row.target) {
      AgentPaneTarget(:final pane) => pane.agent.pane ?? pane.agent.id,
      _ => null,
    };
    final panes = [
      for (final row in agentRows)
        if (paneOf(row) case final pane?) (row.key, pane),
    ];
    if (panes.isNotEmpty) return panes;
    if (node.target case HerdrWorkspaceTarget(
      :final workspace,
    ) when workspace.panes.length == 1) {
      final agent = workspace.panes.single.agent;
      return [(node.key, agent.pane ?? agent.id)];
    }
    return panes;
  }

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
      final project = agent.repoLabel?.trim();
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

/// What an agent row of the project view says (CON-104): the text
/// Herdr's sidebar shows for the pane as the title, then the tab name,
/// workspace and machine as the secondary line.
@immutable
class AgentRowText {
  const AgentRowText({required this.title, required this.subtitle});

  /// Prominent: the pane's terminal title, else the row's own name.
  final String title;

  /// Tab name · workspace · machine; empty parts and repeats dropped.
  final String subtitle;

  /// The one-line (compact) row of [entry]'s workspace: with a single
  /// agent it carries that agent's text, else the workspace name and machine.
  factory AgentRowText.ofEntry(
    ProjectEntry entry, {
    required String projectName,
    required String machine,
  }) {
    final node = entry.node;
    if (entry.agentRows.length == 1) {
      return AgentRowText.of(
        entry.agentRows.single,
        workspace: node.label,
        projectName: projectName,
        machine: machine,
      );
    }
    return AgentRowText(
      title: node.label,
      subtitle: [if (machine.isNotEmpty) machine].join(' · '),
    );
  }

  /// [row] is one of [ProjectEntry.agentRows]; [workspace] is the entry's
  /// workspace row. A workspace named like its [projectName] is not
  /// repeated; a title equal to the workspace or tab name is not repeated.
  factory AgentRowText.of(
    SidebarNode row, {
    required String workspace,
    required String projectName,
    required String machine,
  }) {
    final isTab = row.kind == SidebarNodeKind.herdrTab;
    final sidebarText = isTab ? row.detail.trim() : '';
    // A tab row's own name is the tab label; a pane row's label already is
    // the pane title, so it has no tab name to show.
    final tab = isTab ? row.label.trim() : '';
    final title = sidebarText.isNotEmpty ? sidebarText : row.label.trim();
    bool same(String a, String b) => a.toLowerCase() == b.toLowerCase();
    final parts = <String>[
      if (tab.isNotEmpty && !same(tab, title))
        RegExp(r'^\d+$').hasMatch(tab) ? 'tab $tab' : tab,
      if (workspace.isNotEmpty &&
          !same(workspace, projectName) &&
          !same(workspace, title))
        workspace,
      if (machine.isNotEmpty) machine,
    ];
    return AgentRowText(title: title, subtitle: parts.join(' · '));
  }
}
