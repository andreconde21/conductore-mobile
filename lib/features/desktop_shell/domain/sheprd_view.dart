import 'package:conduit/features/desktop_shell/domain/project_layout.dart';
import 'package:conduit/features/desktop_shell/domain/sidebar_tree.dart';
import 'package:flutter/foundation.dart';

/// What sheprd's sidebar shows for an agent once its marks are applied
/// (sheprd's `presence()`), see docs/sheprd-view-sync.md.
enum SheprdPresence {
  blocked,
  unread,
  done,
  working,
  idle;

  static SheprdPresence? parse(Object? raw) {
    for (final value in values) {
      if (value.name == raw) return value;
    }
    return null;
  }

  /// sheprd counts these as needing you.
  bool get needsAttention => this == blocked || this == unread || this == done;

  /// The row's dot: an unread agent shows like a finished one, the dot
  /// sheprd draws for "look at me".
  SidebarDot get dot => switch (this) {
    SheprdPresence.blocked => SidebarDot.needsYou,
    SheprdPresence.unread || SheprdPresence.done => SidebarDot.done,
    SheprdPresence.working => SidebarDot.working,
    SheprdPresence.idle => SidebarDot.idle,
  };
}

/// One agent in sheprd's view: its presence and the hand-set marks.
@immutable
class SheprdAgentView {
  const SheprdAgentView({
    required this.presence,
    this.stateSeq,
    this.unread = false,
    this.dismissed = false,
    this.kept = false,
    this.removed = false,
    this.pending,
  });

  final SheprdPresence presence;

  /// A mark sent from the app that sheprd has not confirmed yet (its view
  /// was not rewritten with it): shown as pending, never as applied.
  final SheprdMark? pending;

  /// Herdr's `state_change_seq` when sheprd last saw the agent.
  final int? stateSeq;
  final bool unread;

  /// Marked inactive until its next state change.
  final bool dismissed;

  /// Pinned to sheprd's active view.
  final bool kept;

  /// Taken out of sheprd's active view by hand, until its next state
  /// change: hidden from "active", still listed in "all".
  final bool removed;

  /// Stays in the active filter: busy, needing you, or kept, unless it was
  /// removed from the active view.
  bool get active => !removed && (kept || presence != SheprdPresence.idle);

  static SheprdAgentView? fromJson(Object? json) {
    if (json is! Map) return null;
    final presence = SheprdPresence.parse(json['presence']);
    if (presence == null) return null;
    final seq = json['state_seq'];
    return SheprdAgentView(
      presence: presence,
      stateSeq: seq is int && seq >= 0 ? seq : null,
      unread: json['unread'] == true,
      dismissed: json['dismissed'] == true,
      kept: json['kept'] == true,
      removed: json['removed'] == true,
    );
  }

  /// Whether this view already shows [mark] applied.
  bool reflects(SheprdMark mark) => switch (mark) {
    SheprdMark.unread => unread || presence == SheprdPresence.unread,
    SheprdMark.read => !unread && presence != SheprdPresence.unread,
    SheprdMark.dismiss => dismissed,
    SheprdMark.keep => kept,
    SheprdMark.unkeep => !kept,
  };

  /// This agent taken out of sheprd's active view ([removed]) or kept in
  /// it, as `remove-active` / `keep-active` leave it.
  SheprdAgentView withActive({required bool removed}) => SheprdAgentView(
    presence: removed && presence == SheprdPresence.unread
        ? SheprdPresence.idle
        : presence,
    stateSeq: stateSeq,
    unread: removed ? false : unread,
    dismissed: removed || dismissed,
    kept: !removed,
    removed: removed,
    pending: pending,
  );

  /// This view with [mark] waiting for sheprd: the marks as they are, the
  /// mark only as [pending].
  SheprdAgentView withPending(SheprdMark mark) => SheprdAgentView(
    presence: presence,
    stateSeq: stateSeq,
    unread: unread,
    dismissed: dismissed,
    kept: kept,
    removed: removed,
    pending: mark,
  );

  /// This agent after [mark], as sheprd will apply it.
  SheprdAgentView after(SheprdMark mark) => switch (mark) {
    SheprdMark.unread => SheprdAgentView(
      presence: SheprdPresence.unread,
      stateSeq: stateSeq,
      unread: true,
      kept: kept,
    ),
    SheprdMark.read => SheprdAgentView(
      presence: presence == SheprdPresence.unread
          ? SheprdPresence.idle
          : presence,
      stateSeq: stateSeq,
      dismissed: dismissed,
      kept: kept,
    ),
    SheprdMark.dismiss => SheprdAgentView(
      presence: presence == SheprdPresence.working
          ? SheprdPresence.working
          : SheprdPresence.idle,
      stateSeq: stateSeq,
      dismissed: true,
      kept: kept,
    ),
    SheprdMark.keep || SheprdMark.unkeep => SheprdAgentView(
      presence: presence,
      stateSeq: stateSeq,
      unread: unread,
      dismissed: dismissed,
      kept: mark == SheprdMark.keep,
    ),
  };

  @override
  bool operator ==(Object other) =>
      other is SheprdAgentView &&
      other.presence == presence &&
      other.stateSeq == stateSeq &&
      other.unread == unread &&
      other.dismissed == dismissed &&
      other.kept == kept &&
      other.removed == removed &&
      other.pending == pending;

  @override
  int get hashCode => Object.hash(
    presence,
    stateSeq,
    unread,
    dismissed,
    kept,
    removed,
    pending,
  );
}

/// A presence change sent back to sheprd (`sheprd-view-update --op`).
enum SheprdMark {
  read,
  unread,
  dismiss,
  keep,
  unkeep;

  String get label => switch (this) {
    SheprdMark.read => 'Mark as read',
    SheprdMark.unread => 'Mark as unread',
    SheprdMark.dismiss => 'Dismiss',
    SheprdMark.keep => 'Keep in active',
    SheprdMark.unkeep => 'Stop keeping',
  };

  /// What can be done to an agent in [view] (null: sheprd does not list
  /// it yet; marks still apply).
  static List<SheprdMark> choicesFor(SheprdAgentView? shown) {
    // A pending mark counts as done here, so the menu offers its undo.
    final pending = shown?.pending;
    final view = pending == null ? shown : shown!.after(pending);
    return _choices(view);
  }

  static List<SheprdMark> _choices(SheprdAgentView? view) => [
    if (view?.presence == SheprdPresence.unread)
      SheprdMark.read
    else
      SheprdMark.unread,
    if (view?.kept ?? false) SheprdMark.unkeep else SheprdMark.keep,
    if (view != null &&
        view.stateSeq != null &&
        !view.dismissed &&
        view.presence != SheprdPresence.idle &&
        view.presence != SheprdPresence.working)
      SheprdMark.dismiss,
  ];
}

/// sheprd's view as one machine's companion reported it (`sheprd-view`):
/// the layout, each agent's presence, the workspace order and the focused
/// agent, keyed the way sheprd's hub names machines.
@immutable
class SheprdView {
  const SheprdView({
    required this.updated,
    required this.self,
    this.hub,
    this.layout = ProjectLayout.empty,
    this.agents = const {},
    this.order = const [],
    this.focus,
    this.stale = false,
    this.updates = 1,
    this.rejected = const {},
  });

  /// The `view-updates.jsonl` line version sheprd applies (contract v2,
  /// CON-101): 2 and up take layout edits.
  final int updates;

  /// v2 lines sheprd refused, by id, with why.
  final Map<String, String> rejected;

  /// sheprd takes layout edits ([SheprdLayoutEdit]).
  bool get takesLayoutEdits => updates >= 2;

  /// Unix seconds of sheprd's last write.
  final int updated;

  /// The machine key the keys use for the machine that reported this
  /// (`local` on the hub).
  final String self;

  /// The hub's own name (its sheprd-msg name).
  final String? hub;
  final ProjectLayout layout;

  /// By `machine/pane_id`.
  final Map<String, SheprdAgentView> agents;

  /// Workspace keys in sheprd's display order.
  final List<String> order;
  final String? focus;

  /// sheprd stopped rewriting it (not running, or its relay is offline).
  final bool stale;

  bool get fromHub => self == 'local';

  /// Reads one `sheprd-view` reply; null without a usable view.
  static SheprdView? fromReply(Object? reply) {
    if (reply is! Map || reply['found'] != true) return null;
    final view = reply['view'];
    if (view is! Map || view['version'] != 1) return null;
    final updated = view['updated'];
    final self = view['self'];
    if (updated is! int || self is! String || self.isEmpty) return null;
    final agents = <String, SheprdAgentView>{};
    final rawAgents = view['agents'];
    if (rawAgents is Map) {
      for (final MapEntry(:key, :value) in rawAgents.entries) {
        if (key is! String || !key.contains('/')) continue;
        if (SheprdAgentView.fromJson(value) case final agent?) {
          agents[key] = agent;
        }
      }
    }
    final hub = view['hub'];
    final focus = view['focus'];
    final updates = view['updates'];
    return SheprdView(
      updates: updates is int && updates >= 1 ? updates : 1,
      rejected: {
        if (view['rejected'] case final List<Object?> rejected)
          for (final item in rejected)
            if (item case {'id': final String id}) id: '${item['why'] ?? ''}',
      },
      updated: updated,
      self: self.toLowerCase(),
      hub: hub is String && hub.isNotEmpty ? hub.toLowerCase() : null,
      layout: ProjectLayout.fromJson(view['layout']),
      agents: agents,
      order: [
        if (view['order'] case final List<Object?> order)
          for (final key in order)
            if (key is String && key.isNotEmpty) key,
      ],
      focus: focus is String ? focus : null,
      stale: reply['stale'] == true,
    );
  }

  /// This view with machine names changed by [names] (sheprd's name →
  /// the app's), in every key.
  SheprdView renamed(Map<String, String> names) => SheprdView(
    updated: updated,
    self: names[self] ?? self,
    hub: hub,
    layout: layout.renamed(names),
    agents: {
      for (final MapEntry(:key, :value) in agents.entries)
        ProjectKeys.renamed(key, names): value,
    },
    order: [for (final key in order) ProjectKeys.renamed(key, names)],
    focus: focus == null ? null : ProjectKeys.renamed(focus!, names),
    stale: stale,
    updates: updates,
    rejected: rejected,
  );

  SheprdView withAgent(String key, SheprdAgentView agent) =>
      copyWith(agents: {...agents, key: agent});

  SheprdView copyWith({
    ProjectLayout? layout,
    Map<String, SheprdAgentView>? agents,
  }) => SheprdView(
    updated: updated,
    self: self,
    hub: hub,
    layout: layout ?? this.layout,
    agents: agents ?? this.agents,
    order: order,
    focus: focus,
    stale: stale,
    updates: updates,
    rejected: rejected,
  );

  @override
  bool operator ==(Object other) =>
      other is SheprdView &&
      other.updated == updated &&
      other.self == self &&
      other.hub == hub &&
      other.layout == layout &&
      mapEquals(other.agents, agents) &&
      listEquals(other.order, order) &&
      other.focus == focus &&
      other.stale == stale &&
      other.updates == updates &&
      mapEquals(other.rejected, rejected);

  @override
  int get hashCode => Object.hash(
    updated,
    self,
    hub,
    layout,
    Object.hashAll(agents.keys),
    Object.hashAll(order),
    focus,
    stale,
    updates,
    Object.hashAll(rejected.keys),
  );
}

/// The ops of contract v2 (CON-101), by their wire name.
enum SheprdEditOp {
  assign('assign'),
  hide('hide'),
  show('show'),
  projectCreate('project-create'),
  projectRename('project-rename'),
  projectPin('project-pin'),
  projectRules('project-rules'),
  projectShort('project-short'),
  projectDelete('project-delete'),
  projectMove('project-move'),
  memberMove('member-move'),
  removeActive('remove-active'),
  keepActive('keep-active');

  const SheprdEditOp(this.wire);
  final String wire;
}

/// One layout edit sent to sheprd while synced (contract v2,
/// docs/sheprd-view-sync.md): its fields in the app's machine names,
/// how it shows before sheprd applies it ([applyTo]) and how a newer view
/// shows it applied ([reflectedIn]).
@immutable
class SheprdLayoutEdit {
  const SheprdLayoutEdit._(
    this.op, {
    this.workspace,
    this.project,
    this.to,
    this.pinned,
    this.match,
    this.was,
    this.short,
    this.members,
    this.before,
    this.agent,
    this.stateSeq,
    this.inView,
  });

  /// "Move to project…" ([project] made when missing), or to Other ('').
  const SheprdLayoutEdit.assign(String workspace, String project)
    : this._(SheprdEditOp.assign, workspace: workspace, project: project);

  const SheprdLayoutEdit.hide(String workspace, {required bool hidden})
    : this._(
        hidden ? SheprdEditOp.hide : SheprdEditOp.show,
        workspace: workspace,
      );

  const SheprdLayoutEdit.createProject(String project, {List<String>? match})
    : this._(SheprdEditOp.projectCreate, project: project, match: match);

  const SheprdLayoutEdit.rename(String project, String to)
    : this._(SheprdEditOp.projectRename, project: project, to: to);

  const SheprdLayoutEdit.pin(String project, {required bool pinned})
    : this._(SheprdEditOp.projectPin, project: project, pinned: pinned);

  const SheprdLayoutEdit.rules(
    String project,
    List<String> match, {
    List<String>? was,
  }) : this._(
         SheprdEditOp.projectRules,
         project: project,
         match: match,
         was: was,
       );

  const SheprdLayoutEdit.short(String project, String short)
    : this._(SheprdEditOp.projectShort, project: project, short: short);

  const SheprdLayoutEdit.delete(String project, {List<String>? members})
    : this._(SheprdEditOp.projectDelete, project: project, members: members);

  /// Project [project] right before [before], or last of its kind ('').
  const SheprdLayoutEdit.moveProject(String project, String before)
    : this._(SheprdEditOp.projectMove, project: project, before: before);

  /// Workspace [workspace] right before [before] (or last, '') in its
  /// project, [project], whose workspaces show as [inView].
  const SheprdLayoutEdit.moveMember(
    String workspace,
    String before, {
    required String project,
    required List<String> inView,
  }) : this._(
         SheprdEditOp.memberMove,
         workspace: workspace,
         before: before,
         project: project,
         inView: inView,
       );

  const SheprdLayoutEdit.removeActive(String agent, int stateSeq)
    : this._(SheprdEditOp.removeActive, agent: agent, stateSeq: stateSeq);

  const SheprdLayoutEdit.keepActive(String agent)
    : this._(SheprdEditOp.keepActive, agent: agent);

  final SheprdEditOp op;
  final String? workspace;
  final String? project;
  final String? to;
  final bool? pinned;
  final List<String>? match;
  final List<String>? was;
  final String? short;
  final List<String>? members;
  final String? before;
  final String? agent;
  final int? stateSeq;

  /// For [SheprdEditOp.memberMove]: the project's workspaces as shown, to
  /// show the move before sheprd applies it. Not sent.
  final List<String>? inView;

  /// The op as sheprd-view-update `--json` takes it, keys turned into
  /// sheprd's names by [key].
  Map<String, Object?> toJson(String Function(String key) key) => {
    'op': op.wire,
    if (workspace != null) 'workspace': key(workspace!),
    if (op != SheprdEditOp.memberMove && project != null) 'project': project,
    'to': ?to,
    'pinned': ?pinned,
    'match': ?match,
    'was': ?was,
    'short': ?short,
    if (members != null) 'members': [for (final m in members!) key(m)],
    if (before != null)
      'before': op == SheprdEditOp.memberMove && before!.isNotEmpty
          ? key(before!)
          : before,
    if (agent != null) 'agent': key(agent!),
    'state_seq': ?stateSeq,
  };

  /// What the user sees in a notice ("sheprd didn't apply this: …").
  String get label => switch (op) {
    SheprdEditOp.assign =>
      project!.isEmpty ? 'move to Other' : 'move to $project',
    SheprdEditOp.hide => 'hide',
    SheprdEditOp.show => 'show again',
    SheprdEditOp.projectCreate => 'new project $project',
    SheprdEditOp.projectRename => 'rename $project to $to',
    SheprdEditOp.projectPin => pinned! ? 'pin $project' : 'unpin $project',
    SheprdEditOp.projectRules => "$project's rules",
    SheprdEditOp.projectShort => "$project's tag",
    SheprdEditOp.projectDelete => 'delete $project',
    SheprdEditOp.projectMove => 'move $project',
    SheprdEditOp.memberMove => 'reorder',
    SheprdEditOp.removeActive => 'remove from active',
    SheprdEditOp.keepActive => 'keep active',
  };

  ProjectDef? _exact(ProjectLayout layout, String name) =>
      layout.groups.where((group) => group.name == name).firstOrNull;

  /// [view] as it will look once sheprd applies this.
  SheprdView applyTo(SheprdView view) {
    final layout = view.layout;
    final name = project ?? '';
    ProjectLayout next() => switch (op) {
      SheprdEditOp.assign => layout.assign(workspace!, name),
      SheprdEditOp.hide =>
        layout.isHidden(workspace!) ? layout : layout.toggleHidden(workspace!),
      SheprdEditOp.show =>
        layout.isHidden(workspace!) ? layout.toggleHidden(workspace!) : layout,
      SheprdEditOp.projectCreate =>
        layout.byName(name) != null
            ? layout
            : layout.add(name, rules: match ?? const []),
      SheprdEditOp.projectRename => layout.rename(name, to!),
      SheprdEditOp.projectPin => layout.setPinned(name, pinned!),
      SheprdEditOp.projectRules => layout.setRules(name, match!),
      SheprdEditOp.projectShort => layout.setShort(name, short!),
      SheprdEditOp.projectDelete => layout.remove(name),
      SheprdEditOp.projectMove => layout.moveGroup(name, before!),
      SheprdEditOp.memberMove => layout.moveMember(
        name,
        inView!,
        workspace!,
        before!,
      ),
      SheprdEditOp.removeActive || SheprdEditOp.keepActive => layout,
    };
    if (agent case final key?) {
      final shown =
          view.agents[key] ??
          const SheprdAgentView(presence: SheprdPresence.idle);
      return view.withAgent(
        key,
        shown.withActive(removed: op == SheprdEditOp.removeActive),
      );
    }
    return view.copyWith(layout: next());
  }

  /// Whether [view] (sheprd's, newer than the sending) shows this applied.
  bool reflectedIn(SheprdView view) {
    final layout = view.layout;
    final name = project ?? '';
    bool listed(List<String> keys, String key) =>
        keys.any((entry) => ProjectKeys.same(entry, key));
    switch (op) {
      case SheprdEditOp.assign:
        return name.isEmpty
            ? layout.isUngrouped(workspace!)
            : listed(layout.byName(name)?.members ?? const [], workspace!);
      case SheprdEditOp.hide:
        return layout.isHidden(workspace!);
      case SheprdEditOp.show:
        return !layout.isHidden(workspace!);
      case SheprdEditOp.projectCreate:
        return layout.byName(name) != null;
      case SheprdEditOp.projectRename:
        return _exact(layout, to!) != null && _exact(layout, name) == null ||
            name == to;
      case SheprdEditOp.projectPin:
        return _exact(layout, name)?.pinned == pinned;
      case SheprdEditOp.projectRules:
        final now = _exact(layout, name)?.match;
        return now != null &&
            setEquals(
              {for (final r in now) r.toLowerCase()},
              {for (final r in match!) r.toLowerCase()},
            );
      case SheprdEditOp.projectShort:
        final group = _exact(layout, name);
        return group != null && (group.short ?? '') == short!.trim();
      case SheprdEditOp.projectDelete:
        return _exact(layout, name) == null;
      case SheprdEditOp.projectMove:
        final order = [
          for (final i in layout.displayOrder) layout.groups[i].name,
        ];
        final at = order.indexOf(name);
        if (at < 0) return false;
        if (before!.isEmpty) {
          final pin = _exact(layout, name)!.pinned;
          return at == order.length - 1 ||
              _exact(layout, order[at + 1])!.pinned != pin;
        }
        return at + 1 < order.length && order[at + 1] == before;
      case SheprdEditOp.memberMove:
        final members = layout.byName(name)?.members ?? const <String>[];
        final at = members.indexWhere((m) => ProjectKeys.same(m, workspace!));
        if (at < 0) return false;
        if (before!.isEmpty) return at == members.length - 1;
        return at + 1 < members.length &&
            ProjectKeys.same(members[at + 1], before!);
      case SheprdEditOp.removeActive:
        return view.agents[agent]?.removed ?? false;
      case SheprdEditOp.keepActive:
        final shown = view.agents[agent];
        return shown != null && shown.kept && !shown.removed;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is SheprdLayoutEdit &&
      other.op == op &&
      other.workspace == workspace &&
      other.project == project &&
      other.to == to &&
      other.pinned == pinned &&
      listEquals(other.match, match) &&
      listEquals(other.was, was) &&
      other.short == short &&
      listEquals(other.members, members) &&
      other.before == before &&
      other.agent == agent &&
      other.stateSeq == stateSeq;

  @override
  int get hashCode => Object.hash(op, workspace, project, to, before, agent);

  @override
  String toString() =>
      'SheprdLayoutEdit(${op.wire}, ${project ?? workspace ?? agent})';
}
