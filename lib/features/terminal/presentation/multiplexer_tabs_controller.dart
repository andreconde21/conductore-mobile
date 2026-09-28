import 'dart:async';

import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/live/domain/live_host_model.dart';
import 'package:conduit/features/live/presentation/live_host_hub.dart';
import 'package:conduit/features/terminal/domain/herdr_remote_control.dart';
import 'package:conduit/features/terminal/domain/multiplexer_tabs.dart';
import 'package:flutter/foundation.dart';

/// Lists and drives the tabs of one multiplexer session.
abstract interface class MultiplexerTabsBackend {
  MultiplexerTabsKind get kind;

  /// Whether tabs can change places (tmux; Herdr has no move command).
  bool get canReorder;

  /// The tabs now, in order; null when they could not be read.
  Future<List<MultiplexerTab>?> list();

  Future<bool> select(MultiplexerTab tab);

  /// A new tab next to [active], in its directory.
  Future<bool> create({MultiplexerTab? active});

  Future<bool> rename(MultiplexerTab tab, String name);

  Future<bool> close(MultiplexerTab tab);

  /// Swaps [tab] and [other]; [active] stays on screen.
  Future<bool> swap(
    MultiplexerTab tab,
    MultiplexerTab other, {
    MultiplexerTab? active,
  });

  Future<void> dispose();
}

/// tmux windows of [sessionName], over its own command channel.
class TmuxTabsBackend implements MultiplexerTabsBackend {
  TmuxTabsBackend({required this.channel, required this.sessionName});

  final SerialCommandChannel channel;
  final String sessionName;

  @override
  MultiplexerTabsKind get kind => MultiplexerTabsKind.tmux;

  @override
  bool get canReorder => true;

  @override
  Future<List<MultiplexerTab>?> list() async {
    final result = await channel.query(TmuxWindowCommands.list(sessionName));
    if (result == null || (result.exitCode != null && result.exitCode != 0)) {
      return null;
    }
    return TmuxWindowCommands.parse(result.stdout);
  }

  @override
  Future<bool> select(MultiplexerTab tab) =>
      channel.run(TmuxWindowCommands.select(tab.id));

  @override
  Future<bool> create({MultiplexerTab? active}) => channel.run(
    TmuxWindowCommands.create(
      afterWindowId: active?.id ?? '',
      sessionName: sessionName,
    ),
  );

  @override
  Future<bool> rename(MultiplexerTab tab, String name) =>
      channel.run(TmuxWindowCommands.rename(tab.id, name));

  @override
  Future<bool> close(MultiplexerTab tab) =>
      channel.run(TmuxWindowCommands.kill(tab.id));

  @override
  Future<bool> swap(
    MultiplexerTab tab,
    MultiplexerTab other, {
    MultiplexerTab? active,
  }) => channel.run(
    TmuxWindowCommands.swap(
      tab.id,
      other.id,
      activeWindowId: (active ?? tab).id,
    ),
  );

  @override
  Future<void> dispose() => channel.close();
}

/// Herdr tabs of the focused workspace, over the session's shared Herdr
/// command channel (which this backend does not own).
class HerdrTabsBackend implements MultiplexerTabsBackend {
  HerdrTabsBackend({required this.control, this.fallbackWorkspaceId});

  final HerdrRemoteControl control;

  /// The workspace the app thinks the session is on, for when Herdr
  /// reports no focused tab.
  final String Function()? fallbackWorkspaceId;

  HerdrCommands get _commands => control.commands;

  @override
  MultiplexerTabsKind get kind => MultiplexerTabsKind.herdr;

  @override
  bool get canReorder => false;

  @override
  Future<List<MultiplexerTab>?> list() async {
    final result = await control.query(_commands.tabList);
    if (result == null || !HerdrRemoteControl.succeeded(result)) return null;
    final parsed = parseHerdrWorkspaceTabs(
      result.stdout,
      fallbackWorkspaceId: fallbackWorkspaceId?.call() ?? '',
    );
    if (parsed == null) return null;
    if (parsed.knowsActive) return parsed.tabs;
    // Not the focused workspace: its own active tab.
    final workspaces = await control.workspaces();
    final activeId = workspaces
        ?.where((workspace) => workspace.id == parsed.workspaceId)
        .firstOrNull
        ?.activeTabId;
    return [
      for (final tab in parsed.tabs) tab.copyWith(active: tab.id == activeId),
    ];
  }

  @override
  Future<bool> select(MultiplexerTab tab) => control.focusTab(tab.id);

  @override
  Future<bool> create({MultiplexerTab? active}) =>
      control.createPane(HerdrNewPane.newTab);

  @override
  Future<bool> rename(MultiplexerTab tab, String name) =>
      control.run(_commands.tabRename(tab.id, name));

  @override
  Future<bool> close(MultiplexerTab tab) =>
      control.run(_commands.tabClose(tab.id));

  @override
  Future<bool> swap(
    MultiplexerTab tab,
    MultiplexerTab other, {
    MultiplexerTab? active,
  }) async => false;

  @override
  Future<void> dispose() async {}
}

/// Key fallbacks for when the command channel refuses an action (typed
/// into the session: the prefix and a digit, Herdr's bindings). Each
/// returns whether it sent anything.
class MultiplexerTabsKeys {
  const MultiplexerTabsKeys({this.select, this.create});

  /// Tab [tab], the [position]th (1-based) in the strip.
  final bool Function(MultiplexerTab tab, int position)? select;
  final bool Function()? create;
}

/// Where a tab strip reads its tabs when the machine's companion pushes
/// them: the feed, and this session's tabs in its model (null while the
/// model does not know the session).
class MultiplexerLiveTabs {
  const MultiplexerLiveTabs({
    required this.feed,
    required this.read,
    this.server,
  });

  final LiveHostFeed feed;
  final List<MultiplexerTab>? Function(LiveHostModel model) read;

  /// The live server these tabs come from; when the companion does not
  /// push it (tmux with `tmux-live` off), the strip polls instead.
  final String? server;

  bool covers(LiveHostModel model) =>
      server == null || model.serverState(server!) != LiveServerState.off;
}

/// The live tab list of one multiplexer session, for the tab strip.
///
/// Polls every [pollInterval] while [setVisible] says the strip is on
/// screen, and at once after every action; one fetch at a time over the
/// backend's command channel (no new connection per poll). With [live] on
/// a machine whose companion pushes Herdr and tmux, it polls nothing and
/// redraws from the pushed model; actions still go through the backend.
class MultiplexerTabsController extends ChangeNotifier {
  MultiplexerTabsController({
    required this.backend,
    this.initialPollInterval = const Duration(seconds: 2),
    this.agentStateFor,
    this.keys = const MultiplexerTabsKeys(),
    this.live,
  });

  final MultiplexerTabsBackend backend;

  /// The machine's pushed feed, when the app has one.
  final MultiplexerLiveTabs? live;
  VoidCallback? _releaseFeed;

  /// Whether the tabs come from the pushed model.
  bool get pushed => live?.feed.support == LiveSupport.supported;

  /// How often the tabs are listed while visible, until [setPollInterval].
  final Duration initialPollInterval;

  /// The strip's pace, and the open list's.
  static const listPollInterval = Duration(seconds: 2);

  /// The phone's compact label: it only names the current tab, and every
  /// action (and a lifted finger) lists at once anyway.
  static const compactPollInterval = Duration(seconds: 5);

  /// The companion's most urgent agent state for a tab, merged into the
  /// multiplexer's own status.
  final AgentAttentionState? Function(MultiplexerTab tab)? agentStateFor;
  final MultiplexerTabsKeys keys;

  final _unread = MultiplexerUnreadTracker();
  late Duration _pollInterval = initialPollInterval;

  /// Open tab lists that asked for [listPollInterval] ([boostPolling]).
  int _boosts = 0;

  /// How often the tabs are listed while visible: the pace the layout set,
  /// or [listPollInterval] while a tab list is open.
  Duration get pollInterval => _boosts > 0 && listPollInterval < _pollInterval
      ? listPollInterval
      : _pollInterval;

  /// The layout's pace (the strip wants 2 s, the phone's compact label is
  /// fine with 5 s). An open list's [boostPolling] stays in force over it.
  void setPollInterval(Duration interval) {
    if (interval == _pollInterval || _disposed) return;
    _repace(() => _pollInterval = interval);
  }

  /// Polls at [listPollInterval] until the returned callback runs (an open
  /// tab list); calls nest.
  VoidCallback boostPolling() {
    _repace(() => _boosts += 1);
    var ended = false;
    return () {
      if (ended) return;
      ended = true;
      _repace(() => _boosts -= 1);
    };
  }

  void _repace(VoidCallback change) {
    final before = pollInterval;
    change();
    if (_disposed || !_visible || pollInterval == before || _usesFeed) return;
    _timer?.cancel();
    _timer = Timer.periodic(pollInterval, (_) => unawaited(refresh()));
  }

  List<MultiplexerTab> _tabs = const [];
  bool _loaded = false;
  bool _visible = false;
  bool _fetching = false;
  bool _again = false;
  bool _disposed = false;
  Timer? _timer;
  Timer? _soon;

  MultiplexerTabsKind get kind => backend.kind;
  bool get canReorder => backend.canReorder;
  List<MultiplexerTab> get tabs => _tabs;

  /// Whether a listing has arrived.
  bool get loaded => _loaded;

  MultiplexerTab? get active => _tabs.where((tab) => tab.active).firstOrNull;

  void setVisible(bool visible) {
    if (_disposed || visible == _visible) return;
    _visible = visible;
    _timer?.cancel();
    _timer = null;
    if (visible) {
      if (_attachFeed()) return;
      _timer = Timer.periodic(pollInterval, (_) => unawaited(refresh()));
      unawaited(refresh());
    } else {
      _detachFeed();
    }
  }

  /// Whether the strip listens to the feed rather than polling (its
  /// support may still be unknown).
  bool get _usesFeed =>
      _releaseFeed != null && live?.feed.support != LiveSupport.unsupported;

  bool _attachFeed() {
    final live = this.live;
    if (live == null || live.feed.support == LiveSupport.unsupported) {
      return false;
    }
    live.feed.addListener(_onFeed);
    _releaseFeed = live.feed.acquire();
    _onFeed();
    return true;
  }

  void _detachFeed() {
    live?.feed.removeListener(_onFeed);
    _releaseFeed?.call();
    _releaseFeed = null;
  }

  void _onFeed() {
    final live = this.live;
    if (_disposed || live == null || _releaseFeed == null) return;
    switch (live.feed.support) {
      case LiveSupport.unknown:
        return;
      case LiveSupport.supported when !live.covers(live.feed.model):
      case LiveSupport.unsupported:
        // No push here (or not for this multiplexer): poll as before.
        _detachFeed();
        if (_visible) {
          _timer?.cancel();
          _timer = Timer.periodic(pollInterval, (_) => unawaited(refresh()));
          unawaited(refresh());
        }
      case LiveSupport.supported:
        final tabs = live.read(live.feed.model);
        if (tabs != null) _publish(tabs);
    }
  }

  /// Lists the tabs now (or right after the fetch in flight). Pushed tabs
  /// are current already: nothing runs.
  Future<void> refresh() async {
    if (_disposed) return;
    if (_usesFeed) {
      _onFeed();
      return;
    }
    if (_fetching) {
      _again = true;
      return;
    }
    _fetching = true;
    try {
      do {
        _again = false;
        final listed = await backend.list();
        if (_disposed) return;
        if (listed != null) _publish(listed);
      } while (_again && !_disposed);
    } finally {
      _fetching = false;
    }
  }

  /// A refresh shortly after something outside the strip may have moved
  /// the multiplexer (a swipe, keys typed into the session).
  void refreshSoon([Duration delay = const Duration(milliseconds: 250)]) {
    if (_disposed || !_visible || _usesFeed) return;
    _soon?.cancel();
    _soon = Timer(delay, () => unawaited(refresh()));
  }

  void _publish(List<MultiplexerTab> listed) {
    final merged = [
      for (final tab in listed) tab.copyWith(status: _urgent(tab)),
    ];
    final next = _unread.apply(merged);
    if (_loaded && listEquals(next, _tabs)) return;
    _tabs = List.unmodifiable(next);
    _loaded = true;
    notifyListeners();
  }

  AgentAttentionState? _urgent(MultiplexerTab tab) {
    final agent = agentStateFor?.call(tab);
    final own = tab.status;
    if (agent == null) return own;
    if (own == null) return agent;
    return _rank(agent) < _rank(own) ? agent : own;
  }

  static int _rank(AgentAttentionState state) => switch (state) {
    AgentAttentionState.needsInput => 0,
    AgentAttentionState.blocked => 1,
    AgentAttentionState.working => 2,
    AgentAttentionState.finished => 3,
    AgentAttentionState.idle => 4,
    AgentAttentionState.unknown => 5,
  };

  void _showActive(String id) {
    _tabs = List.unmodifiable([
      for (final tab in _tabs)
        tab.copyWith(active: tab.id == id, unread: tab.id == id ? false : null),
    ]);
    notifyListeners();
  }

  /// Shows [tab]: the CLI, else the keys.
  Future<void> select(MultiplexerTab tab) async {
    final position = _tabs.indexWhere((other) => other.id == tab.id) + 1;
    _showActive(tab.id);
    if (!await backend.select(tab)) {
      keys.select?.call(tab, position);
    }
    await refresh();
  }

  /// The tab [delta] places from the active one, wrapping around.
  Future<void> selectAdjacent(int delta) async {
    if (_tabs.length < 2) return;
    final current = _tabs.indexWhere((tab) => tab.active);
    final next = ((current == -1 ? 0 : current) + delta) % _tabs.length;
    await select(_tabs[next < 0 ? next + _tabs.length : next]);
  }

  Future<void> create() async {
    if (!await backend.create(active: active)) {
      keys.create?.call();
    }
    await refresh();
  }

  Future<bool> rename(MultiplexerTab tab, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return false;
    final ok = await backend.rename(tab, trimmed);
    await refresh();
    return ok;
  }

  Future<bool> close(MultiplexerTab tab) async {
    final ok = await backend.close(tab);
    await refresh();
    return ok;
  }

  /// Moves [tab] one place left (-1) or right (1).
  Future<bool> move(MultiplexerTab tab, int delta) async {
    final from = _tabs.indexWhere((other) => other.id == tab.id);
    return reorder(from, from + delta);
  }

  /// Moves the tab at [from] to [to] (indexes into [tabs]) by swapping it
  /// with each neighbour on the way, the active tab staying on screen.
  Future<bool> reorder(int from, int to) async {
    if (!canReorder ||
        from < 0 ||
        from >= _tabs.length ||
        to < 0 ||
        to >= _tabs.length ||
        from == to) {
      return false;
    }
    final order = List.of(_tabs);
    final moving = order[from];
    final active = this.active;
    final step = to > from ? 1 : -1;
    var ok = true;
    for (var i = from; i != to && ok; i += step) {
      ok = await backend.swap(moving, order[i + step], active: active);
      if (ok) {
        order[i] = order[i + step];
        order[i + step] = moving;
      }
    }
    if (_disposed) return ok;
    _tabs = List.unmodifiable(order);
    notifyListeners();
    await refresh();
    return ok;
  }

  @override
  void dispose() {
    _disposed = true;
    _detachFeed();
    _timer?.cancel();
    _soon?.cancel();
    unawaited(backend.dispose());
    super.dispose();
  }
}
