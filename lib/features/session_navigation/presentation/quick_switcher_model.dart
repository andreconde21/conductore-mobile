import 'dart:math' as math;

import 'package:conduit/core/presentation/multiplexer_icon.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/hosts/presentation/home_board_controller.dart';
import 'package:conduit/features/hosts/presentation/widgets/home_session_grid.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:conduit/features/sessions/domain/remote_session_listing.dart';
import 'package:conduit/features/sessions/presentation/session_grid_page.dart'
    show summarizeAgentState;
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';

/// The switcher's sections, in display order: agents waiting on the user
/// always come first.
enum SwitcherSection {
  needsYou('NEEDS YOU'),
  openSessions('OPEN SESSIONS'),
  otherWorkspaces('OTHER WORKSPACES'),
  recent('RECENT');

  const SwitcherSection(this.label);

  final String label;
}

/// One row of the quick switcher.
sealed class SwitcherItem {
  const SwitcherItem();

  SwitcherSection get section;

  /// Stable identity, for widget keys and keyboard focus.
  String get key;

  String get title;

  /// The saved machine's name.
  String get machineName;

  /// What a search matches: workspace, pane title, machine, project and
  /// tmux session names, and the topics, projects and folders of the
  /// agents inside.
  List<String> get searchTerms;
}

/// An agent waiting for input or an approval, on any monitored machine.
class SwitcherAgentItem extends SwitcherItem {
  const SwitcherAgentItem({
    required this.host,
    required this.agent,
    required this.machineName,
    this.machine,
  });

  /// The monitored session host the agent was reported on.
  final SavedHost host;

  /// The saved machine behind [host], when it is known.
  final SavedHost? machine;
  final AgentInfo agent;

  @override
  final String machineName;

  @override
  SwitcherSection get section => SwitcherSection.needsYou;

  @override
  String get key => 'agent-${baseHostId(host.id)}-${agent.id}';

  @override
  String get title => agent.projectLabel ?? agent.name;

  /// What the agent is asking for: the pending approval, else its last
  /// message, else its state.
  String get asks {
    final request = agent.pendingRequests.firstOrNull;
    if (request != null) {
      final summary = request.summary.trim();
      return summary.isEmpty
          ? 'Approve ${request.toolName}'
          : 'Approve ${request.toolName}: $summary';
    }
    final message = agent.lastMessage?.trim() ?? '';
    return message.isNotEmpty ? message : agent.state.label;
  }

  @override
  List<String> get searchTerms => [
    agent.name,
    ?agent.projectLabel,
    ?agent.workspace,
    ?agent.tab,
    machineName,
    host.name,
  ];
}

/// A session open in the app.
class SwitcherSessionItem extends SwitcherItem {
  const SwitcherSessionItem({
    required this.session,
    required this.info,
    this.active = false,
    this.agentTerms = const [],
  });

  final TerminalSessionController session;
  final HomeSessionInfo info;

  /// Topics, projects and folders of the agents inside it (searchable).
  final List<String> agentTerms;

  /// The session on screen in the terminal.
  final bool active;

  @override
  SwitcherSection get section => SwitcherSection.openSessions;

  @override
  String get key => 'session-${session.host.id}';

  @override
  String get title {
    final custom = session.customTitle?.trim() ?? '';
    if (custom.isNotEmpty) return custom;
    if (info.targetLabel.isNotEmpty) return info.targetLabel;
    return session.title;
  }

  @override
  String get machineName =>
      info.machineName.isNotEmpty ? info.machineName : session.host.name;

  @override
  List<String> get searchTerms => [
    title,
    session.title,
    session.terminalTitle,
    info.targetLabel,
    machineName,
    ?HomeSessionInfo.tmuxSessionOf(session),
    ?ConnectTarget.fromSessionHostId(session.host.id)?.name,
    ...agentTerms,
  ];
}

/// A Herdr workspace or tmux session on a machine that is not open.
class SwitcherWorkspaceItem extends SwitcherItem {
  const SwitcherWorkspaceItem({
    required this.host,
    required this.kind,
    required this.id,
    required this.label,
    this.details = '',
    this.attention,
    this.paneTitles = const [],
    this.agentTerms = const [],
  });

  /// The saved machine.
  final SavedHost host;
  final MultiplexerKind kind;

  /// The Herdr workspace id, or the tmux session name.
  final String id;
  final String label;

  /// Tabs, panes or windows and last activity, as the home board says.
  final String details;

  /// The most urgent state of its agents.
  final AgentAttentionState? attention;

  /// Titles of the agent panes inside it (searchable).
  final List<String> paneTitles;

  /// Topics, projects and folders of the agents inside it (searchable).
  final List<String> agentTerms;

  @override
  SwitcherSection get section => SwitcherSection.otherWorkspaces;

  @override
  String get key => 'workspace-${host.id}-${kind.name}-$id';

  @override
  String get title => label;

  @override
  String get machineName => host.name;

  @override
  List<String> get searchTerms => [
    label,
    id,
    machineName,
    ...paneTitles,
    ...agentTerms,
  ];
}

/// A target picked recently in the connect picker.
class SwitcherRecentItem extends SwitcherItem {
  const SwitcherRecentItem({required this.host, required this.target});

  /// The saved machine.
  final SavedHost host;
  final ConnectTarget target;

  @override
  SwitcherSection get section => SwitcherSection.recent;

  @override
  String get key => 'recent-${host.id}-${target.key}';

  @override
  String get title => target.title;

  @override
  String get machineName => host.name;

  MultiplexerKind? get multiplexer => switch (target.kind) {
    ConnectTargetKind.herdr => MultiplexerKind.herdr,
    ConnectTargetKind.tmux => MultiplexerKind.tmux,
    _ => null,
  };

  @override
  List<String> get searchTerms => [target.title, target.name, machineName];
}

/// How well [query] matches [text], case-insensitively: a substring scores
/// high (more at the start of a word, most for the whole text), letters in
/// order ("thcal" in "TheCalendar") score lower, the tighter the better.
/// Null when it does not match.
int? fuzzyScore(String query, String text) {
  final q = query.toLowerCase();
  final t = text.toLowerCase();
  if (q.isEmpty) return 0;
  if (t.isEmpty) return null;
  final index = t.indexOf(q);
  if (index >= 0) {
    var score = 1000 - math.min<int>(index, 200);
    if (index == 0 || !_isWordChar(t.codeUnitAt(index - 1))) score += 300;
    if (q.length == t.length) score += 200;
    return score;
  }
  var score = 400;
  var from = 0;
  var previous = -2;
  for (var i = 0; i < q.length; i += 1) {
    final found = t.indexOf(q[i], from);
    if (found == -1) return null;
    if (found == previous + 1) {
      score += 8;
    } else {
      score -= math.min<int>(found - from, 20);
    }
    if (found == 0 || !_isWordChar(t.codeUnitAt(found - 1))) score += 6;
    previous = found;
    from = found + 1;
  }
  return math.max<int>(1, score);
}

bool _isWordChar(int unit) =>
    (unit >= 0x30 && unit <= 0x39) ||
    (unit >= 0x61 && unit <= 0x7a) ||
    unit > 0x7f;

/// [item]'s score for [query]: every word of the query has to match one of
/// its [SwitcherItem.searchTerms]. Null when some word does not.
int? switcherMatch(SwitcherItem item, String query) {
  final words = query.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
  var total = 0;
  for (final word in words) {
    int? best;
    for (final term in item.searchTerms) {
      final score = fuzzyScore(word, term);
      if (score != null && (best == null || score > best)) best = score;
    }
    if (best == null) return null;
    total += best;
  }
  return total;
}

/// One visible section and its rows.
typedef SwitcherSectionItems = ({
  SwitcherSection section,
  List<SwitcherItem> items,
});

/// [items] grouped into their sections, in section order, keeping only
/// what [query] matches (best matches first inside a section; the given
/// order otherwise). Empty sections are left out.
List<SwitcherSectionItems> filterSwitcher(
  List<SwitcherItem> items,
  String query,
) {
  final searching = query.trim().isNotEmpty;
  final result = <SwitcherSectionItems>[];
  for (final section in SwitcherSection.values) {
    final scored = <(SwitcherItem, int)>[];
    for (final item in items) {
      if (item.section != section) continue;
      final score = searching ? switcherMatch(item, query) : 0;
      if (score != null) scored.add((item, score));
    }
    if (scored.isEmpty) continue;
    if (searching) {
      // List.sort is not stable: tie-break on the given order.
      final order = {for (final (i, entry) in scored.indexed) entry.$1: i};
      scored.sort((a, b) {
        final byScore = b.$2.compareTo(a.$2);
        return byScore != 0 ? byScore : order[a.$1]!.compareTo(order[b.$1]!);
      });
    }
    result.add((
      section: section,
      items: [for (final (item, _) in scored) item],
    ));
  }
  return result;
}

/// The saved machine's name for a (possibly derived) session host.
String _machineNameOf(SavedHost host, Map<String, SavedHost> machines) {
  final saved = machines[baseHostId(host.id)];
  if (saved != null) return saved.name;
  if (host.isLocal) return 'This device';
  final cut = host.name.lastIndexOf(': ');
  return ConnectTarget.keyFromSessionHostId(host.id) != null && cut > 0
      ? host.name.substring(0, cut)
      : host.name;
}

/// One machine's home board: its Herdr workspaces and tmux sessions.
typedef SwitcherBoard = ({SavedHost host, HomeBoardState state});

/// Every agent [attention] reports, by saved machine id.
Map<String, List<AgentInfo>> _agentsOf(AgentAttentionController? attention) {
  final result = <String, List<AgentInfo>>{};
  if (attention == null) return result;
  for (final host in attention.monitoredHosts) {
    final agents = attention.statusFor(host.id)?.agents;
    if (agents == null || agents.isEmpty) continue;
    (result[baseHostId(host.id)] ??= []).addAll(agents);
  }
  return result;
}

/// The agents of [machineAgents] running in Herdr workspace [id] (with
/// the board's own [panes]), or in tmux session [tmux].
Iterable<AgentInfo> _agentsIn(
  List<AgentInfo> machineAgents, {
  String? herdr,
  String? tmux,
  List<HomeBoardPane> panes = const [],
}) => [
  for (final pane in panes) pane.agent,
  for (final agent in machineAgents)
    if ((herdr != null && agent.workspace == herdr) ||
        (tmux != null &&
            (agent.tab == tmux || (agent.tab?.startsWith('$tmux:') ?? false))))
      agent,
];

/// What [agents] add to a search of the place they run in: their topics,
/// projects and folders.
List<String> _agentTerms(Iterable<AgentInfo> agents) => {
  for (final agent in agents) ...[
    agent.name,
    ?agent.projectLabel,
    if (agent.workspace case final path? when path.contains('/')) path,
  ],
}.toList();

/// Everything the switcher lists, section by section:
///
/// * agents needing input or an approval on every monitored machine, one
///   row per agent session, approvals first, then the newest;
/// * the open sessions, in tab order;
/// * Herdr workspaces and tmux sessions on the home boards' machines that
///   no open session shows;
/// * recent connect-picker targets that are neither open nor listed above.
///
/// Sessions and workspaces are also found by the topics, projects and
/// folders of the agents in them: [agentsByMachine] (every agent per
/// saved machine id), read from [attention] when not given.
List<SwitcherItem> buildSwitcherItems({
  required List<TerminalSessionController> sessions,
  TerminalSessionController? active,
  AgentAttentionController? attention,
  List<SavedHost> machines = const [],
  List<SwitcherBoard> boards = const [],
  Map<String, List<ConnectTarget>> recents = const {},
  Map<String, List<AgentInfo>>? agentsByMachine,
}) {
  final boardStates = {for (final board in boards) board.host.id: board.state};
  final byId = {for (final machine in machines) machine.id: machine};
  final allAgents = agentsByMachine ?? _agentsOf(attention);

  final agents = <SwitcherAgentItem>[];
  if (attention != null) {
    final seen = <String>{};
    for (final host in attention.monitoredHosts) {
      for (final agent
          in attention.statusFor(host.id)?.agents ?? const <AgentInfo>[]) {
        if (!agent.state.needsAttention && agent.pendingRequests.isEmpty) {
          continue;
        }
        if (!seen.add('${baseHostId(host.id)}/${agent.id}')) continue;
        agents.add(
          SwitcherAgentItem(
            host: host,
            machine: byId[baseHostId(host.id)],
            agent: agent,
            machineName: _machineNameOf(host, byId),
          ),
        );
      }
    }
    agents.sort((a, b) {
      final approvals = (b.agent.pendingRequests.isNotEmpty ? 1 : 0).compareTo(
        a.agent.pendingRequests.isNotEmpty ? 1 : 0,
      );
      if (approvals != 0) return approvals;
      final at = a.agent.stateChangedAt;
      final bt = b.agent.stateChangedAt;
      if (at == null) return bt == null ? 0 : 1;
      if (bt == null) return -1;
      return bt.compareTo(at);
    });
  }

  final open = <SwitcherSessionItem>[];
  for (final session in sessions) {
    final machine = baseHostId(session.host.id);
    final workspaces = boardStates[machine]?.workspaces ?? const [];
    final target = ConnectTarget.fromSessionHostId(session.host.id);
    final herdr = target?.kind == ConnectTargetKind.herdr && target!.name != ''
        ? target.name
        : null;
    open.add(
      SwitcherSessionItem(
        session: session,
        active: session == active,
        info: HomeSessionInfo.of(
          session,
          workspaces: workspaces,
          agentState: summarizeAgentState(
            attention?.statusFor(session.host.id),
            session.host.id,
          ),
          machineName: _machineNameOf(session.host, byId),
        ),
        agentTerms: _agentTerms(
          _agentsIn(
            allAgents[machine] ?? const [],
            herdr: herdr,
            tmux: HomeSessionInfo.tmuxSessionOf(session),
            panes:
                workspaces.where((w) => w.id == herdr).firstOrNull?.panes ??
                const [],
          ),
        ),
      ),
    );
  }

  // What each machine already has open.
  final openHerdr = <String, Set<String>>{};
  final openTmux = <String, Set<String>>{};
  final openKeys = <String, Set<String>>{};
  for (final session in sessions) {
    final machine = baseHostId(session.host.id);
    final target = ConnectTarget.fromSessionHostId(session.host.id);
    openKeys.putIfAbsent(machine, () => {}).add(target?.key ?? 'shell');
    if (target?.kind == ConnectTargetKind.herdr && target!.name.isNotEmpty) {
      openHerdr.putIfAbsent(machine, () => {}).add(target.name);
    }
    final tmux = HomeSessionInfo.tmuxSessionOf(session);
    if (tmux != null) openTmux.putIfAbsent(machine, () => {}).add(tmux);
  }

  final others = <SwitcherWorkspaceItem>[];
  final listedHerdr = <String, Set<String>>{};
  final listedTmux = <String, Set<String>>{};
  for (final (:host, :state) in boards) {
    for (final workspace in state.workspaces) {
      if (openHerdr[host.id]?.contains(workspace.id) ?? false) continue;
      listedHerdr.putIfAbsent(host.id, () => {}).add(workspace.id);
      others.add(
        SwitcherWorkspaceItem(
          host: host,
          kind: MultiplexerKind.herdr,
          id: workspace.id,
          label: workspace.label,
          details: herdrDetails(workspace),
          attention: workspace.summary,
          paneTitles: [for (final pane in workspace.panes) pane.title],
          agentTerms: _agentTerms(
            _agentsIn(
              allAgents[host.id] ?? const [],
              herdr: workspace.id,
              panes: workspace.panes,
            ),
          ),
        ),
      );
    }
    for (final TmuxSessionInfo tmux in state.tmuxSessions) {
      if (openTmux[host.id]?.contains(tmux.name) ?? false) continue;
      listedTmux.putIfAbsent(host.id, () => {}).add(tmux.name);
      others.add(
        SwitcherWorkspaceItem(
          host: host,
          kind: MultiplexerKind.tmux,
          id: tmux.name,
          label: tmux.name,
          details: tmuxDetails(tmux),
          agentTerms: _agentTerms(
            _agentsIn(allAgents[host.id] ?? const [], tmux: tmux.name),
          ),
        ),
      );
    }
  }

  final recent = <SwitcherRecentItem>[];
  for (final machine in machines) {
    for (final target in recents[machine.id] ?? const <ConnectTarget>[]) {
      if (openKeys[machine.id]?.contains(target.key) ?? false) continue;
      final listed = switch (target.kind) {
        ConnectTargetKind.herdr =>
          (listedHerdr[machine.id]?.contains(target.name) ?? false) ||
              (openHerdr[machine.id]?.contains(target.name) ?? false),
        ConnectTargetKind.tmux =>
          (listedTmux[machine.id]?.contains(target.name) ?? false) ||
              (openTmux[machine.id]?.contains(target.name) ?? false),
        _ => false,
      };
      if (listed) continue;
      recent.add(SwitcherRecentItem(host: machine, target: target));
    }
  }

  return [...agents, ...open, ...others, ...recent];
}
