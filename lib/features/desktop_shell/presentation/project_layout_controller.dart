import 'dart:async';
import 'dart:convert';

import 'package:conduit/core/theme/theme_controller.dart';
import 'package:conduit/features/agent_attention/data/conductore_host_attention_provider.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/desktop_shell/domain/project_layout.dart';
import 'package:conduit/features/desktop_shell/domain/project_tree.dart';
import 'package:conduit/features/desktop_shell/domain/sidebar_tree.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:conduit/features/usage/domain/usage_summary.dart';
import 'package:flutter/foundation.dart';

/// The companion capability behind `sidebar-layout`: sheprd's
/// `~/.config/herdr/sidebar.toml`, read-only, as JSON.
const sheprdSidebarCapability = 'sheprd-sidebar';

/// The project view's state, shared by the desktop sidebar, the phone home
/// and the agents dashboard (CON-065): the layout (the app's own once
/// edited, else what the machines' sidebar.toml says, so the app and
/// sheprd agree), the view (detailed / compact), the filter (all /
/// active), collapsed projects, and every edit ("Move to project…",
/// "Move to Other", pin, rules, hide). The app's choices live in the
/// synced settings ([ThemeController.projectPrefs]); sidebar.toml is
/// never written.
class ProjectLayoutController extends ChangeNotifier {
  ProjectLayoutController({
    required this.theme,
    this.attention,
    this.refreshEvery = const Duration(minutes: 2),
    this.clock = DateTime.now,
  }) {
    theme.addListener(notifyListeners);
  }

  /// The app's one instance (main wires it); null in tests and builds
  /// without it, where the views fall back to grouping by machine only.
  static ProjectLayoutController? instance;

  final ThemeController theme;
  final AgentAttentionController? attention;
  final Duration refreshEvery;
  final DateTime Function() clock;

  /// sidebar.toml per saved machine id, already localized (`local/` is
  /// that machine).
  final Map<String, ProjectLayout> _machineLayouts = {};
  final Map<String, String> _machineErrors = {};
  final Map<String, DateTime> _fetchedAt = {};
  final Set<String> _inFlight = {};

  /// The names of the projects found from what agents report, as last
  /// built: the first edit of a layout-less view keeps them as projects.
  List<String> _found = const [];
  bool _disposed = false;

  ProjectPrefs get prefs => theme.projectPrefs;

  /// The layout read from the machines (merged), empty when none has one.
  ProjectLayout get machineLayout =>
      ProjectLayout.merge(_machineLayouts.values);

  /// Whether a machine reported a sidebar.toml.
  bool get hasMachineLayout => _machineLayouts.isNotEmpty;

  /// Machines whose sidebar.toml could not be read, with why.
  Map<String, String> get machineErrors => Map.unmodifiable(_machineErrors);

  /// Following the machines' sidebar.toml (nothing edited in the app).
  bool get followsMachines => prefs.layout == null;

  ProjectLayout get layout => prefs.layout ?? machineLayout;

  bool get compact => prefs.compact ?? layout.compact ?? false;
  bool get activeOnly => prefs.activeOnly ?? layout.activeOnly ?? false;
  int get recentHours =>
      prefs.recentHours ??
      layout.recentHours ??
      ProjectPrefs.defaultRecentHours;
  bool get groupByProject => prefs.groupByProject;
  bool get showHidden => prefs.showHidden;

  /// The names a machine goes by in layout keys: its name and its address
  /// (sheprd names machines by their SSH alias).
  static Map<String, Set<String>> aliasesOf(Iterable<SavedHost> hosts) => {
    for (final host in hosts)
      baseHostId(host.id): {
        host.name.toLowerCase(),
        if (host.host.trim().isNotEmpty) host.host.trim().toLowerCase(),
      },
  };

  /// [tree] grouped by project with the current layout.
  List<ProjectGroup> build(
    List<SidebarNode> tree, {
    Map<String, List<AgentInfo>> agentsByMachine = const {},
    Iterable<SavedHost> hosts = const [],
  }) {
    final groups = ProjectTreeBuilder.build(
      tree,
      agentsByMachine: agentsByMachine,
      layout: layout,
      machineAliases: aliasesOf(hosts),
      now: clock(),
      recentHours: recentHours,
    );
    _found = [
      for (final group in groups)
        if (!group.inLayout && !group.isOther) group.name,
    ];
    return groups;
  }

  static String _collapseKey(ProjectGroup group) =>
      group.isOther ? ProjectPrefs.otherKey : group.key;

  bool isCollapsed(ProjectGroup group) {
    final own = prefs.collapsed[_collapseKey(group)];
    if (own != null) return own;
    if (group.isOther) return layout.otherCollapsed;
    return layout.byName(group.name)?.collapsed ?? false;
  }

  /// The entries [group] shows under the current filter.
  List<ProjectEntry> visibleEntries(ProjectGroup group) => [
    for (final entry in group.entries)
      if ((!entry.hidden || showHidden) && (!activeOnly || entry.active)) entry,
  ];

  /// Groups the view lists: Other and (with the active filter) projects
  /// with nothing to show are left out, like in sheprd.
  List<ProjectGroup> visibleGroups(List<ProjectGroup> groups) => [
    for (final group in groups)
      if (visibleEntries(group).isNotEmpty || (!group.isOther && !activeOnly))
        group,
  ];

  /// Agents needing you across [groups], hidden rows left out.
  static int needsYouCount(List<ProjectGroup> groups) =>
      groups.fold(0, (sum, group) => sum + group.needsYou);

  // View choices.

  Future<void> _setPrefs(ProjectPrefs next) => theme.setProjectPrefs(next);

  Future<void> toggleCollapsed(ProjectGroup group) => _setPrefs(
    prefs.copyWith(
      collapsed: {...prefs.collapsed, _collapseKey(group): !isCollapsed(group)},
    ),
  );

  Future<void> setCompact(bool compact) =>
      _setPrefs(prefs.copyWith(compact: compact));

  Future<void> setActiveOnly(bool activeOnly) =>
      _setPrefs(prefs.copyWith(activeOnly: activeOnly));

  Future<void> setRecentHours(int hours) =>
      _setPrefs(prefs.copyWith(recentHours: hours.clamp(1, 24 * 30)));

  Future<void> setGroupByProject(bool on) =>
      _setPrefs(prefs.copyWith(groupByProject: on));

  Future<void> setShowHidden(bool on) =>
      _setPrefs(prefs.copyWith(showHidden: on));

  // Layout edits: the app's own layout from here on.

  /// The layout edits start from: the app's own, else the machines', else
  /// the projects found from the agents (each with its name as a rule, so
  /// they keep their workspaces).
  ProjectLayout get _editable {
    final own = prefs.layout;
    if (own != null) return own;
    final machines = machineLayout;
    if (machines.groups.isNotEmpty) return machines;
    var layout = machines;
    for (final name in _found) {
      layout = layout.add(name, rules: [name]);
    }
    return layout;
  }

  Future<void> _editLayout(ProjectLayout Function(ProjectLayout) edit) =>
      _setPrefs(prefs.copyWith(layout: edit(_editable)));

  /// "Move to project…" ([project] made when missing) and "Move to Other"
  /// (an empty [project]).
  Future<void> moveTo(ProjectEntry entry, String project) =>
      _editLayout((layout) => layout.assign(entry.memberKey, project));

  Future<void> toggleHidden(ProjectEntry entry) =>
      _editLayout((layout) => layout.toggleHidden(entry.memberKey));

  /// [edit] on [group]'s own entry in the layout (made for a project
  /// found from the agents).
  Future<void> _editProject(
    ProjectGroup group,
    ProjectLayout Function(ProjectLayout layout, String name) edit,
  ) => _editLayout((layout) {
    final withGroup = layout.add(group.name);
    return edit(withGroup, withGroup.byName(group.name)!.name);
  });

  Future<void> setPinned(ProjectGroup group, bool pinned) =>
      _editProject(group, (layout, name) => layout.setPinned(name, pinned));

  Future<void> setRules(ProjectGroup group, List<String> rules) =>
      _editProject(group, (layout, name) => layout.setRules(name, rules));

  Future<void> addProject(String name, {List<String> rules = const []}) =>
      _editLayout((layout) => layout.add(name, rules: rules));

  Future<void> removeProject(ProjectGroup group) => _editLayout((layout) {
    final def = layout.byName(group.name);
    return def == null ? layout : layout.remove(def.name);
  });

  /// Back to the machines' sidebar.toml: drops what was edited in the app.
  Future<void> followMachineLayout() =>
      _setPrefs(prefs.copyWith(clearLayout: true));

  /// Project names to offer in "Move to project…": the layout's, then
  /// those found from the agents.
  List<String> get projectNames => {
    for (final index in layout.displayOrder) layout.groups[index].name,
    ..._found,
  }.toList();

  /// The project of one agent seen without the machine tree (the agents
  /// dashboard): its Herdr workspace or tmux session on machine [host] as
  /// the layout places it (listed, else caught by a rule on its repo or
  /// folder), else Other. With no layout projects, the repo it reports
  /// (CON-032), else Other. Returns the project's name; Other is
  /// [ProjectGroup.otherKey].
  String projectOfAgent(SavedHost host, {AgentInfo? live, String? project}) {
    final layout = this.layout;
    final repo = project ?? live?.projectLabel;
    final names = aliasesOf([host]).values.single;
    final workspace = live?.workspace?.trim() ?? '';
    final tab = live?.tab?.trim() ?? '';
    final keys = [
      for (final name in names) ...[
        if (RegExp(r'^w[A-Za-z0-9]+$').hasMatch(workspace))
          ProjectKeys.herdr(name, workspace, ''),
        if (tab.isNotEmpty && !RegExp(r'^w[A-Za-z0-9]+$').hasMatch(workspace))
          ProjectKeys.named(name, tab.split(':').first),
      ],
    ];
    if (keys.any(layout.isUngrouped)) return ProjectGroup.otherKey;
    if (layout.groups.isEmpty) return repo ?? ProjectGroup.otherKey;
    for (final key in keys) {
      final explicit = layout.explicitGroup(key);
      if (explicit != null) return layout.groups[explicit].name;
    }
    final index = layout.groupOf('', [
      ?repo,
      if (workspace.startsWith('/') || workspace.startsWith('~')) workspace,
    ]);
    return index == null ? ProjectGroup.otherKey : layout.groups[index].name;
  }

  // sidebar.toml from the machines.

  /// Asks every machine whose companion can tell for its sidebar.toml,
  /// at most every [refreshEvery] (or now with [force]).
  Future<void> refresh({bool force = false}) async {
    final attention = this.attention;
    if (attention == null) return;
    final now = clock();
    final seen = <String>{};
    final pending = <Future<void>>[];
    for (final host in attention.monitoredHosts) {
      final id = baseHostId(host.id);
      if (!seen.add(id)) continue;
      if (!attention.companionSupports(host.id, sheprdSidebarCapability)) {
        continue;
      }
      final last = _fetchedAt[id];
      if (!force && last != null && now.difference(last) < refreshEvery) {
        continue;
      }
      if (_inFlight.contains(id)) continue;
      pending.add(_fetch(attention, host, id));
    }
    await Future.wait(pending);
  }

  Future<void> _fetch(
    AgentAttentionController attention,
    SavedHost host,
    String id,
  ) async {
    _inFlight.add(id);
    _fetchedAt[id] = clock();
    final (runner, :owned) = attention.runnerFor(host);
    try {
      final result = await runner.run(
        ConductoreHostAttentionProvider.remoteCommand('sidebar-layout'),
        timeout: const Duration(seconds: 15),
      );
      applyReply(host, result.stdout);
    } catch (_) {
      // Unreachable now: the next refresh asks again.
    } finally {
      _inFlight.remove(id);
      if (owned) unawaited(runner.close());
    }
  }

  /// Takes one `sidebar-layout` reply from [host].
  @visibleForTesting
  void applyReply(SavedHost host, String stdout) {
    final id = baseHostId(host.id);
    Object? decoded;
    try {
      final lines = stdout.trim().split('\n');
      decoded = jsonDecode(lines.last);
    } catch (_) {
      return;
    }
    if (decoded is! Map) return;
    final before = (_machineLayouts[id], _machineErrors[id]);
    _machineErrors.remove(id);
    if (decoded['found'] != true) {
      _machineLayouts.remove(id);
    } else if (decoded['error'] is String) {
      _machineLayouts.remove(id);
      _machineErrors[id] = decoded['error'] as String;
    } else {
      _machineLayouts[id] = ProjectLayout.fromJson(
        decoded['layout'],
      ).localized(host.name.toLowerCase());
    }
    if (before != (_machineLayouts[id], _machineErrors[id]) && !_disposed) {
      notifyListeners();
    }
  }

  // Per-project usage.

  /// Today's tokens per project key (input, output and cache writes; cache
  /// reads left out, like sheprd), from the usage reports the app already
  /// has: each report row's repo goes to the project whose agents report
  /// it, else whose rule catches it, else Other. Empty without reports.
  Map<String, int> tokensToday(List<ProjectGroup> groups, UsageSummary usage) {
    final byRepo = <String, String>{};
    for (final group in groups) {
      for (final (_, agent) in group.agents) {
        final repo = agent.projectLabel?.toLowerCase();
        if (repo != null) byRepo.putIfAbsent(repo, () => group.key);
      }
    }
    final layout = this.layout;
    final keys = {for (final group in groups) group.key};
    final result = <String, int>{};
    for (final machine in usage.machines) {
      final report = machine.report;
      if (report == null) continue;
      for (final row in [...report.claude.rows, ...report.codex.rows]) {
        if (row.date != report.today || row.hour != null) continue;
        final repo = row.project.toLowerCase();
        var key = byRepo[repo];
        if (key == null && layout.groups.isNotEmpty) {
          final index = layout.groupOf('', [row.project]);
          if (index != null) key = layout.groups[index].name.toLowerCase();
        }
        key ??= keys.contains(repo) ? repo : ProjectGroup.otherKey;
        final totals = row.totals;
        result[key] =
            (result[key] ?? 0) +
            totals.input +
            totals.output +
            totals.cacheWrite;
      }
    }
    return result;
  }

  @override
  void dispose() {
    _disposed = true;
    theme.removeListener(notifyListeners);
    super.dispose();
  }
}

/// "1.2M" / "340k" / "900", like sheprd.
String formatProjectTokens(int tokens) {
  if (tokens < 1000) return '$tokens';
  if (tokens < 1000000) return '${tokens ~/ 1000}k';
  return '${(tokens / 1000000).toStringAsFixed(1)}M';
}
