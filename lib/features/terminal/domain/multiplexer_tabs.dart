import 'dart:async';

import 'package:conduit/core/app_failure.dart';
import 'package:conduit/features/agent_attention/data/remote_tool_command.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/hosts/presentation/home_board_controller.dart'
    show herdrStatusToState;
import 'package:conduit/features/sessions/domain/remote_session_listing.dart';
import 'package:flutter/foundation.dart';

/// Which multiplexer a session's tabs come from.
enum MultiplexerTabsKind { herdr, tmux }

/// One tab of the multiplexer inside a session: a Herdr tab of the focused
/// workspace, or a tmux window of the attached session.
@immutable
class MultiplexerTab {
  const MultiplexerTab({
    required this.id,
    required this.label,
    this.index = 0,
    this.active = false,
    this.activity = 0,
    this.flagged = false,
    this.status,
    this.unread = false,
  });

  /// Herdr's tab id (`w1:t2`) or tmux's window id (`@3`).
  final String id;

  final String label;

  /// tmux's window index; Herdr's tab number. Shown next to the label for
  /// tmux, where it is what `prefix` + digit selects.
  final int index;

  /// The tab on screen.
  final bool active;

  /// tmux `#{window_activity}`: epoch seconds of the last output in the
  /// window (tmux keeps it without `monitor-activity`). 0 for Herdr.
  final int activity;

  /// tmux's activity or bell flag was raised.
  final bool flagged;

  /// The most urgent agent state in the tab (Herdr's own tab status and
  /// the companion's agents), or null.
  final AgentAttentionState? status;

  /// Something happened in the tab since it was last on screen: new
  /// output (tmux) or an agent that finished or needs the user (Herdr).
  final bool unread;

  MultiplexerTab copyWith({
    bool? active,
    AgentAttentionState? status,
    bool? unread,
    String? label,
  }) => MultiplexerTab(
    id: id,
    label: label ?? this.label,
    index: index,
    active: active ?? this.active,
    activity: activity,
    flagged: flagged,
    status: status ?? this.status,
    unread: unread ?? this.unread,
  );

  @override
  bool operator ==(Object other) =>
      other is MultiplexerTab &&
      other.id == id &&
      other.label == label &&
      other.index == index &&
      other.active == active &&
      other.activity == activity &&
      other.flagged == flagged &&
      other.status == status &&
      other.unread == unread;

  @override
  int get hashCode =>
      Object.hash(id, label, index, active, activity, flagged, status, unread);

  @override
  String toString() => 'MultiplexerTab($id $label${active ? ' *' : ''})';
}

/// tmux commands for the window strip, wrapped for a non-interactive SSH
/// shell. Checked against tmux 3.4 on an isolated server: window ids
/// (`@3`) are unique on the server, so every action targets them; `-t
/// '=name'` matches the session name exactly; `window_activity` advances
/// on output even without `monitor-activity`.
abstract final class TmuxWindowCommands {
  /// Tab, passed through by `tmux -u` on every version ([parse] also reads
  /// the `_` that tmux 3.3+ prints for it to a non-UTF-8 client).
  static const separator = '\t';

  static String _tmux(String args) => remoteToolCommand('tmux', '-u $args');

  static String _q(String value) => shellQuoteArgument(value);

  static const _fields = [
    '#{window_id}',
    '#{window_index}',
    '#{window_active}',
    '#{window_activity_flag}',
    '#{window_bell_flag}',
    '#{window_activity}',
    // Free text last: a stray separator in it is folded back in.
    '#{window_name}',
  ];

  /// `tmux list-windows -t '=<session>' -F …`, one line per window tagged
  /// `W`. printf turns the `\t` into real tabs, which tmux passes through.
  static String list(String sessionName) => _tmux(
    'list-windows -t ${_q('=$sessionName')} '
    '-F "\$(printf \'W\\t${_fields.join(r'\t')}\')"',
  );

  static String select(String windowId) =>
      _tmux('select-window -t ${_q(windowId)}');

  /// A new window right after [afterWindowId] (or at the end of
  /// [sessionName]), in the directory of that window's active pane.
  static String create({String afterWindowId = '', String sessionName = ''}) {
    const cwd = "'#{pane_current_path}'";
    if (afterWindowId.isNotEmpty) {
      return _tmux('new-window -a -t ${_q(afterWindowId)} -c $cwd');
    }
    return _tmux('new-window -t ${_q('=$sessionName:')} -c $cwd');
  }

  static String rename(String windowId, String name) =>
      _tmux('rename-window -t ${_q(windowId)} ${_q(name)}');

  static String kill(String windowId) =>
      _tmux('kill-window -t ${_q(windowId)}');

  /// Swaps two windows' places. `swap-window` moves the session's current
  /// window along (with or without `-d`), so [activeWindowId] is selected
  /// again in the same command.
  static String swap(
    String windowId,
    String otherId, {
    required String activeWindowId,
  }) => _tmux(
    'swap-window -d -s ${_q(windowId)} -t ${_q(otherId)} '
    "';' select-window -t ${_q(activeWindowId)}",
  );

  /// Parses [list] output; lines that do not fit are skipped. Sorted by
  /// window index.
  static List<MultiplexerTab> parse(String raw) {
    final tabs = <MultiplexerTab>[];
    for (final line in raw.split('\n')) {
      final mangled = line.contains(separator)
          ? null
          : _mangledWindow.firstMatch(line);
      final fields = mangled != null
          ? ['W', for (var i = 1; i <= 7; i++) mangled[i]!]
          : line.split(separator);
      if (fields.length < 8 || fields.first != 'W') continue;
      final id = fields[1].trim();
      if (!id.startsWith('@')) continue;
      tabs.add(
        MultiplexerTab(
          id: id,
          index: int.tryParse(fields[2].trim()) ?? 0,
          active: fields[3].trim() == '1',
          flagged: fields[4].trim() == '1' || fields[5].trim() == '1',
          activity: int.tryParse(fields[6].trim()) ?? 0,
          label: fields.sublist(7).join(separator).trim(),
        ),
      );
    }
    tabs.sort((a, b) => a.index.compareTo(b.index));
    return tabs;
  }

  /// A `W` line with its tabs printed as `_`: the fixed fields lead, so
  /// the window name (last) comes back whole.
  static final _mangledWindow = RegExp(
    r'^W_(@\d+)_(\d+)_([01])_([01])_([01])_(\d+)_(.*)$',
  );
}

/// What `herdr tab list` says about one workspace's tabs.
class HerdrWorkspaceTabs {
  const HerdrWorkspaceTabs({
    required this.workspaceId,
    required this.tabs,
    this.knowsActive = false,
  });

  final String workspaceId;
  final List<MultiplexerTab> tabs;

  /// Whether one of [tabs] is marked active from Herdr's focus. False when
  /// the workspace is not the focused one; the caller then asks
  /// `herdr workspace list` for its active tab.
  final bool knowsActive;
}

/// Reads the tabs of the workspace a Herdr session shows from `herdr tab
/// list` (Herdr 0.9.1: `{"result":{"tabs":[{"tab_id","workspace_id",
/// "label","number","agent_status","focused"}]}}`).
///
/// The workspace is the one holding Herdr's focused tab (what the attached
/// client shows), else [fallbackWorkspaceId]. Tabs keep Herdr's order
/// (`number`); the status comes from `agent_status`.
HerdrWorkspaceTabs? parseHerdrWorkspaceTabs(
  String raw, {
  String fallbackWorkspaceId = '',
}) {
  final List<HerdrTabInfo> all;
  try {
    all = RemoteSessionListing.parseHerdrTabs(raw);
  } on FormatException {
    return null;
  }
  if (all.isEmpty) return null;
  final focused = all.where((tab) => tab.focused).firstOrNull;
  final workspaceId = focused?.workspaceId ?? fallbackWorkspaceId;
  if (workspaceId.isEmpty) return null;
  final inWorkspace = [
    for (final (order, tab) in all.indexed)
      if (tab.workspaceId == workspaceId) (order, tab),
  ];
  inWorkspace.sort((a, b) {
    final an = a.$2.number;
    final bn = b.$2.number;
    if (an != null && bn != null && an != bn) return an.compareTo(bn);
    return a.$1.compareTo(b.$1);
  });
  return HerdrWorkspaceTabs(
    workspaceId: workspaceId,
    knowsActive: focused != null,
    tabs: [
      for (final (i, (_, tab)) in inWorkspace.indexed)
        MultiplexerTab(
          id: tab.id,
          label: tab.displayLabel(i + 1),
          index: tab.number ?? i + 1,
          active: tab.focused,
          status: herdrStatusToState(tab.agentStatus),
        ),
    ],
  );
}

/// Remembers what each tab looked like when it was last on screen, and
/// marks the others that changed since as unread: new output in a tmux
/// window, an agent in a Herdr tab that finished or needs the user.
class MultiplexerUnreadTracker {
  final _seenActivity = <String, int>{};
  final _seenStatus = <String, AgentAttentionState?>{};
  final _known = <String>{};

  static bool _notable(AgentAttentionState? state) =>
      state == AgentAttentionState.finished ||
      state == AgentAttentionState.needsInput ||
      state == AgentAttentionState.blocked;

  List<MultiplexerTab> apply(List<MultiplexerTab> tabs) {
    final result = <MultiplexerTab>[];
    for (final tab in tabs) {
      final first = _known.add(tab.id);
      if (tab.active || first) {
        // On screen (or never seen before): what it shows now is read.
        _seenActivity[tab.id] = tab.activity;
        _seenStatus[tab.id] = tab.status;
        result.add(tab.copyWith(unread: tab.active ? false : tab.flagged));
        continue;
      }
      final newOutput = tab.activity > (_seenActivity[tab.id] ?? 0);
      final newState =
          tab.status != _seenStatus[tab.id] && _notable(tab.status);
      result.add(tab.copyWith(unread: tab.flagged || newOutput || newState));
    }
    _known.retainAll({for (final tab in tabs) tab.id});
    return result;
  }
}

/// A command channel to one machine: one runner opened on first use, kept
/// for [idleTimeout] so a burst of polls and taps shares one connection,
/// commands run one at a time in order.
class SerialCommandChannel {
  SerialCommandChannel({
    required this.runnerFactory,
    this.idleTimeout = const Duration(minutes: 2),
  });

  static const timeout = Duration(seconds: 10);

  final AgentCommandRunner Function() runnerFactory;
  final Duration idleTimeout;

  AgentCommandRunner? _runner;
  Timer? _idle;
  Future<void> _queue = Future<void>.value();
  bool _closed = false;

  /// Runs [command]; null when the channel failed or is closed.
  Future<AgentCommandResult?> query(String command) {
    final completer = Completer<AgentCommandResult?>();
    _queue = _queue.then((_) async => completer.complete(await _run(command)));
    return completer.future;
  }

  /// Runs [command]; true when it exited 0.
  Future<bool> run(String command) async {
    final result = await query(command);
    return result != null && (result.exitCode == null || result.exitCode == 0);
  }

  Future<AgentCommandResult?> _run(String command) async {
    if (_closed) return null;
    _idle?.cancel();
    try {
      final runner = _runner ??= runnerFactory();
      return await runner.run(command, timeout: timeout);
    } on AppFailure {
      await _drop();
      return null;
    } catch (_) {
      await _drop();
      return null;
    } finally {
      if (!_closed) _idle = Timer(idleTimeout, () => unawaited(_drop()));
    }
  }

  Future<void> _drop() async {
    final runner = _runner;
    _runner = null;
    if (runner == null) return;
    try {
      await runner.close();
    } catch (_) {
      // Already gone.
    }
  }

  Future<void> close() async {
    _closed = true;
    _idle?.cancel();
    await _queue;
    await _drop();
  }
}
