import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/hosts/presentation/home_board_controller.dart'
    show herdrStatusToState;
import 'package:conduit/features/sessions/domain/remote_session_listing.dart';
import 'package:conduit/features/terminal/domain/multiplexer_tabs.dart';
import 'package:flutter/foundation.dart';

/// The companion capability behind pushed Herdr and tmux state
/// (`status --live`, `events --live`; `docs/herdr-live.md`).
const liveCapability = 'live';

/// The companion capability behind agents only Herdr detects
/// (`--herdr-agents`).
const herdrAgentsCapability = 'herdr-agents';

/// The companion capability behind `agents`, `agent-send`, `agent-wait`
/// and `agent-read`.
const agentMessagingCapability = 'agent-messaging';

/// The companion capability behind `config get|set`.
const companionConfigCapability = 'config';

/// Whether [agent] is one only Herdr reports (the companion's
/// `--herdr-agents`): its id is its messaging target, `herdr/<pane>` (or
/// `herdr@<session>/<pane>`), and it has no chat view, approvals or usage.
bool isHerdrOnlyAgent(AgentInfo agent) => _herdrTarget.hasMatch(agent.id);

final _herdrTarget = RegExp(r'^herdr([@#][A-Za-z0-9._-]+)?/');

/// One pushed change: [entity] null means the entity is gone.
@immutable
class LiveChange {
  const LiveChange({
    required this.sequence,
    required this.key,
    required this.entity,
  });

  final int sequence;
  final String key;
  final Map<String, Object?>? entity;
}

/// What one live server says about itself.
enum LiveServerState {
  /// Running and pushed.
  up,

  /// It ran and went away (or refuses connections).
  down,

  /// Not installed, or no server exists.
  none,

  /// Not pushed by choice (tmux: the `tmux-live` setting is off): callers
  /// poll that server themselves.
  off,

  /// The companion could not tell.
  unknown,
}

/// A machine's Herdr servers and tmux server as the companion pushes them:
/// a flat map of entities by key (`srv:`, `ws:`, `tab:`, `pane:`, `tses:`,
/// `twin:`), with the views the home board, the tab strip and the
/// navigator draw.
@immutable
class LiveHostModel {
  const LiveHostModel([this.entities = const {}]);

  /// Replaces everything (a `status --live` reply or a resync snapshot).
  factory LiveHostModel.fromEntities(Map<Object?, Object?> raw) {
    return LiveHostModel({
      for (final MapEntry(:key, :value) in raw.entries)
        if (key is String && value is Map) key: _map(value),
    });
  }

  final Map<String, Map<String, Object?>> entities;

  static Map<String, Object?> _map(Map<Object?, Object?> value) => {
    for (final MapEntry(:key, :value) in value.entries)
      if (key is String) key: value,
  };

  /// [changes] applied in order.
  LiveHostModel apply(Iterable<LiveChange> changes) {
    if (changes.isEmpty) return this;
    final next = Map.of(entities);
    for (final change in changes) {
      final entity = change.entity;
      if (entity == null) {
        next.remove(change.key);
      } else {
        next[change.key] = entity;
      }
    }
    return LiveHostModel(next);
  }

  /// Herdr server id for a `--session` name (empty: the default one).
  static String herdrServerId(String session) =>
      session.isEmpty ? 'herdr' : 'herdr@$session';

  static const tmuxServerId = 'tmux';

  LiveServerState serverState(String serverId) =>
      switch (entities['srv:$serverId']?['state']) {
        'up' => LiveServerState.up,
        'down' => LiveServerState.down,
        'none' => LiveServerState.none,
        'off' => LiveServerState.off,
        _ => LiveServerState.unknown,
      };

  /// Whether the companion reported [serverId] at all yet.
  bool knowsServer(String serverId) => entities.containsKey('srv:$serverId');

  Iterable<Map<String, Object?>> _ofKind(String kind, String server) =>
      entities.values.where((e) => e['kind'] == kind && e['server'] == server);

  // --- Herdr ----------------------------------------------------------------

  /// The server's workspaces in Herdr's order, each with its tabs (and
  /// what each tab's focused pane shows).
  List<HerdrWorkspaceInfo> workspaces({
    String server = 'herdr',
    String session = '',
  }) {
    final tabs = herdrTabs(server: server);
    final list = [
      for (final w in _ofKind('workspace', server))
        HerdrWorkspaceInfo(
          id: _s(w['id']),
          label: _s(w['label']).isNotEmpty
              ? _s(w['label'])
              : 'Workspace ${_i(w['number']) ?? ''}'.trim(),
          number: _i(w['number']),
          agentStatus: _s(w['agentStatus']),
          focused: w['focused'] == true,
          tabCount: _i(w['tabCount']) ?? 1,
          activeTabId: _s(w['activeTabId']),
          session: session,
        ),
    ]..sort(_byNumber);
    return [
      for (final w in list)
        w.withTabs(
          tabs.where((tab) => tab.workspaceId == w.id).toList()
            ..sort((a, b) => (a.number ?? 0).compareTo(b.number ?? 0)),
        ),
    ];
  }

  static int _byNumber(HerdrWorkspaceInfo a, HerdrWorkspaceInfo b) {
    final an = a.number;
    final bn = b.number;
    if (an != null && bn != null && an != bn) return an.compareTo(bn);
    return a.id.compareTo(b.id);
  }

  /// Every tab of the server, with what its focused (else first) pane
  /// shows, as `herdr pane list` would give it.
  List<HerdrTabInfo> herdrTabs({String server = 'herdr'}) {
    final panes = _ofKind('pane', server).toList();
    final best = <String, Map<String, Object?>>{};
    for (final pane in panes) {
      final tabId = _s(pane['tabId']);
      if (tabId.isEmpty) continue;
      final seen = best[tabId];
      if (seen == null ||
          (pane['focused'] == true && seen['focused'] != true)) {
        best[tabId] = pane;
      }
    }
    return [
      for (final t in _ofKind('tab', server))
        () {
          final tab = HerdrTabInfo(
            id: _s(t['id']),
            workspaceId: _s(t['workspaceId']),
            label: _s(t['label']),
            number: _i(t['number']),
            agentStatus: _s(t['agentStatus']),
            focused: t['focused'] == true,
            paneCount: _i(t['paneCount']),
          );
          final pane = best[tab.id];
          if (pane == null) return tab;
          return tab.withPane(
            title: _paneTitle(pane),
            agent: _s(pane['agent']),
          );
        }(),
    ];
  }

  static String _paneTitle(Map<String, Object?> pane) {
    final title = _s(pane['title']);
    if (title.isNotEmpty) return title;
    final parts = _s(pane['cwd']).split('/').where((p) => p.isNotEmpty);
    return parts.isEmpty ? '' : parts.last;
  }

  /// The server's agent panes as the Herdr provider lists them (`agent
  /// list`): the pane id is the agent's id.
  List<AgentInfo> herdrAgents({String server = 'herdr'}) {
    return [
      for (final pane in _ofKind('pane', server))
        if (_s(pane['agent']).isNotEmpty)
          AgentInfo(
            id: _s(pane['id']),
            name: _agentName(pane),
            kind: _s(pane['agent']),
            state: _agentState(_s(pane['agentStatus'])),
            workspace: _nonEmpty(pane['workspaceId']),
            tab: _nonEmpty(pane['tabId']),
            pane: _s(pane['id']),
            stateSequence: _i(pane['seq']),
          ),
    ]..sort((a, b) => (a.pane ?? '').compareTo(b.pane ?? ''));
  }

  static String _agentName(Map<String, Object?> pane) {
    final name = _s(pane['name']);
    if (name.isNotEmpty) return name;
    final title = _s(pane['title']);
    if (title.isNotEmpty) return title;
    final kind = _s(pane['agent']);
    final folder = _s(
      pane['cwd'],
    ).split('/').where((p) => p.isNotEmpty).lastOrNull;
    return folder == null ? kind : '$kind in $folder';
  }

  /// Herdr's agent status as the Herdr provider maps it.
  static AgentAttentionState _agentState(String raw) => switch (raw
      .toLowerCase()) {
    'working' || 'running' || 'busy' => AgentAttentionState.working,
    'blocked' || 'waiting' || 'needs_input' => AgentAttentionState.needsInput,
    'done' || 'finished' => AgentAttentionState.finished,
    'idle' || 'ready' => AgentAttentionState.idle,
    _ => AgentAttentionState.unknown,
  };

  /// The tabs of the workspace a Herdr session shows, for the tab strip:
  /// the workspace of Herdr's focused tab, else [fallbackWorkspaceId]; like
  /// `herdr tab list` read by [parseHerdrWorkspaceTabs]. Null when there is
  /// nothing to show.
  List<MultiplexerTab>? herdrStripTabs({
    String server = 'herdr',
    String fallbackWorkspaceId = '',
  }) {
    final all = herdrTabs(server: server);
    if (all.isEmpty) return null;
    final focused = all.where((tab) => tab.focused).firstOrNull;
    final workspaceId = focused?.workspaceId ?? fallbackWorkspaceId;
    if (workspaceId.isEmpty) return null;
    final activeId = focused != null
        ? focused.id
        : _s(entities['ws:$server:$workspaceId']?['activeTabId']);
    final inWorkspace =
        all.where((tab) => tab.workspaceId == workspaceId).toList()
          ..sort((a, b) => (a.number ?? 0).compareTo(b.number ?? 0));
    return [
      for (final (i, tab) in inWorkspace.indexed)
        MultiplexerTab(
          id: tab.id,
          label: tab.displayLabel(i + 1),
          index: tab.number ?? i + 1,
          active: tab.id == activeId,
          status: herdrStatusToState(tab.agentStatus),
        ),
    ];
  }

  // --- tmux -----------------------------------------------------------------

  /// The tmux sessions, as `tmux list-sessions` lists them (by name).
  List<TmuxSessionInfo> tmuxSessions() {
    return [
      for (final s in _ofKind('tmuxSession', tmuxServerId))
        TmuxSessionInfo(
          name: _s(s['name']),
          attachedClients: _i(s['attached']) ?? 0,
          windows: _i(s['windows']) ?? 1,
          lastActivity: switch (_i(s['activity'])) {
            final seconds? when seconds > 0 =>
              DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true),
            _ => null,
          },
        ),
    ]..sort((a, b) => a.name.compareTo(b.name));
  }

  /// The windows of tmux session [sessionName] for the tab strip, by
  /// index; null when the session is not known.
  List<MultiplexerTab>? tmuxWindows(String sessionName) {
    final session = _ofKind(
      'tmuxSession',
      tmuxServerId,
    ).where((s) => s['name'] == sessionName).firstOrNull;
    if (session == null) return null;
    final id = session['id'];
    return [
      for (final w in _ofKind('tmuxWindow', tmuxServerId))
        if (w['sessionId'] == id)
          MultiplexerTab(
            id: _s(w['id']),
            label: _s(w['name']),
            index: _i(w['index']) ?? 0,
            active: w['active'] == true,
            flagged: w['activityFlag'] == true || w['bellFlag'] == true,
            activity: _i(w['activity']) ?? 0,
          ),
    ]..sort((a, b) => a.index.compareTo(b.index));
  }

  static String _s(Object? value) => value is String ? value : '';

  static String? _nonEmpty(Object? value) =>
      value is String && value.isNotEmpty ? value : null;

  static int? _i(Object? value) => switch (value) {
    final int v => v,
    final num v => v.toInt(),
    _ => null,
  };
}
