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
  });

  final SheprdPresence presence;

  /// Herdr's `state_change_seq` when sheprd last saw the agent.
  final int? stateSeq;
  final bool unread;

  /// Marked inactive until its next state change.
  final bool dismissed;

  /// Pinned to sheprd's active view.
  final bool kept;

  /// Stays in the active filter: busy, needing you, or kept.
  bool get active => kept || presence != SheprdPresence.idle;

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
    );
  }

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
      other.kept == kept;

  @override
  int get hashCode => Object.hash(presence, stateSeq, unread, dismissed, kept);
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
  static List<SheprdMark> choicesFor(SheprdAgentView? view) => [
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
  });

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
    return SheprdView(
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
  );

  SheprdView withAgent(String key, SheprdAgentView agent) => SheprdView(
    updated: updated,
    self: self,
    hub: hub,
    layout: layout,
    agents: {...agents, key: agent},
    order: order,
    focus: focus,
    stale: stale,
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
      other.stale == stale;

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
  );
}
