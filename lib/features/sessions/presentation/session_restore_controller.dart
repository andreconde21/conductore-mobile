import 'dart:async';
import 'dart:convert';

import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:conduit/features/sessions/domain/session_snapshot.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:flutter/foundation.dart';

/// How a session brought back from the last app run gets connected.
enum RestoredSessionMode {
  /// Reattaches on its own: a tmux session or Herdr workspace keeps the
  /// work alive on the machine, so connecting lands where the user was.
  automatic,

  /// Reattachable, but every connection asks for a hardware-key touch, so
  /// it waits for a tap (opening it connects).
  tapToReconnect,

  /// A plain shell (or a shell in a directory): the process died with the
  /// app, so opening it starts a new shell.
  ended,
}

/// Remembers the open sessions between app runs and brings them back.
///
/// Saving: every change of the workspace (open, close, reorder, rename,
/// active tab) is written to [repository], debounced by [saveDebounce] and
/// only when the list actually changed. Local shells are not kept.
///
/// Restoring ([restore], after the app lock): the tiles come back at once,
/// disconnected, in their order and with the same one active. Sessions in
/// tmux or Herdr then reconnect lazily: the active one straight away, the
/// others while the home grid is on screen, at most [maxParallel] at a
/// time, retried with [backoff] and then left for a tap. Sessions on
/// hardware-key machines wait for a tap; plain shells show as ended.
///
/// Mosh sessions are not resumed: see `docs/session-restore.md`. They
/// bootstrap a fresh mosh-server over SSH like any new connection.
///
/// Tabs whose Herdr workspace was closed ([closedWorkspaces], CON-103)
/// keep the time that was first seen. A restored one whose workspace was
/// already gone more than [closeGoneAfter] before, and is found gone
/// again, closes by itself: they are gathered for [autoCloseDelay], then
/// closed together and announced in [autoClosed], which [undoAutoClose]
/// takes back (CON-115).
class SessionRestoreController extends ChangeNotifier {
  SessionRestoreController({
    required TerminalWorkspaceController workspace,
    required this.repository,
    required this.findHost,
    this._ready,
    this._enabled = true,
    this.saveDebounce = const Duration(milliseconds: 600),
    this.maxParallel = 2,
    this.backoff = const [
      Duration(seconds: 3),
      Duration(seconds: 10),
      Duration(seconds: 30),
    ],
    this.closedWorkspaces,
    this.closeGoneAfter = const Duration(hours: 24),
    this.autoCloseDelay = const Duration(seconds: 2),
    DateTime Function()? clock,
  }) : _workspace = workspace,
       _clock = clock ?? DateTime.now {
    workspace.addListener(_handleWorkspaceChanged);
    closedWorkspaces?.addListener(_handleClosedWorkspaces);
  }

  final TerminalWorkspaceController _workspace;
  final SessionSnapshotRepository repository;

  /// Looks up a saved machine by id (after the saved hosts have loaded).
  final Future<SavedHost?> Function(String hostId) findHost;

  /// Completes when [enabled] reflects the saved setting.
  final Future<void>? _ready;

  final Duration saveDebounce;

  /// Restored sessions connecting at the same time, at most.
  final int maxParallel;

  /// Waits between failed reconnects; after the last one the session is
  /// left for a tap.
  final List<Duration> backoff;

  /// The tabs whose Herdr workspace was closed (HerdrSessionFocus).
  final ValueListenable<Set<TerminalSessionController>>? closedWorkspaces;

  /// How long a workspace must have been gone before its restored tab
  /// closes on launch.
  final Duration closeGoneAfter;

  /// How long tabs to close are gathered, so one notice covers them.
  final Duration autoCloseDelay;

  final DateTime Function() _clock;

  /// The last tabs closed for a workspace that no longer exists, for the
  /// home page's notice with Undo.
  final autoClosed = ValueNotifier<AutoClosedTabs?>(null);

  /// When each open tab's workspace was first seen gone, from the saved
  /// list for a restored tab not checked yet, else from this run.
  final _goneSince = <TerminalSessionController, DateTime>{};

  /// Restored tabs whose workspace was already gone in an earlier run and
  /// that have not been checked in this one: the only ones that may close
  /// by themselves.
  final _goneBefore = <TerminalSessionController>{};

  final _toClose = <TerminalSessionController>{};
  Timer? _closeTimer;

  bool _enabled;
  bool _restoring = false;

  /// Saving starts once the saved list has been read, so an early change
  /// cannot overwrite it with an empty one.
  bool _restored = false;
  bool _homeVisible = false;
  bool _disposed = false;
  Timer? _saveTimer;
  String? _lastSaved;

  final _restoredSessions = <TerminalSessionController, _RestoredSession>{};
  final _queue = <TerminalSessionController>[];

  /// Restored sessions this controller started connecting.
  final _started = <TerminalSessionController>{};

  /// Of [_started], the ones still connecting. Counted from the sessions'
  /// own state, so a slot frees the moment a connection settles.
  int get _inFlight => _started
      .where((session) => session.status == TerminalConnectionStatus.connecting)
      .length;
  bool _pumpScheduled = false;

  /// Whether the setting "Restore sessions on launch" is on. Turning it
  /// off forgets the saved list; turning it on saves the current one.
  bool get enabled => _enabled;
  set enabled(bool value) {
    if (value == _enabled) return;
    _enabled = value;
    _saveTimer?.cancel();
    if (!value) {
      _lastSaved = null;
      unawaited(repository.clear());
    } else if (_restored) {
      unawaited(flush());
    }
  }

  /// How [session] came back from the last run, or null when it was opened
  /// in this run or has connected since.
  RestoredSessionMode? modeOf(TerminalSessionController session) =>
      _restoredSessions[session]?.mode;

  /// The line a restored session's tile shows while it is not connected,
  /// or null to show the usual connection state.
  String? noteFor(TerminalSessionController session) {
    final restored = _restoredSessions[session];
    if (restored == null ||
        session.status == TerminalConnectionStatus.connected) {
      return null;
    }
    return switch (restored.mode) {
      RestoredSessionMode.ended => 'Shell ended · tap to start a new one',
      RestoredSessionMode.tapToReconnect => 'Tap to reconnect',
      RestoredSessionMode.automatic =>
        restored.gaveUp && session.status != TerminalConnectionStatus.connecting
            ? 'Tap to reconnect'
            : 'Reconnecting…',
    };
  }

  /// Whether the home grid is on screen (and the app in front): the other
  /// restored sessions reconnect only then.
  void setHomeVisible(bool visible) {
    if (visible == _homeVisible) return;
    _homeVisible = visible;
    if (visible) _schedulePump();
  }

  /// Brings back the sessions of the last run. Safe to call on every home
  /// page start: it runs once until [holdForLock].
  Future<void> restore() async {
    if (_restoring || _restored || _disposed) return;
    _restoring = true;
    try {
      await _ready;
      if (_disposed) return;
      if (!_enabled) {
        await repository.clear();
        return;
      }
      final snapshot = await repository.load();
      if (_disposed || snapshot.isEmpty) return;
      await _reopen(snapshot);
    } finally {
      _restoring = false;
      _restored = true;
      if (!_disposed) {
        _scheduleSave();
        notifyListeners();
      }
    }
  }

  Future<void> _reopen(SessionSnapshot snapshot) async {
    final alreadyActive = _workspace.activeSession;
    TerminalSessionController? active;
    final automatic = <TerminalSessionController>[];
    for (final (index, entry) in snapshot.entries.indexed) {
      final host = await findHost(entry.hostId);
      if (_disposed) return;
      if (host == null || host.isLocal) continue;
      final sessionHost = entry.target.apply(host);
      final existing = _workspace.sessions
          .where((session) => session.host.id == sessionHost.id)
          .firstOrNull;
      if (existing != null) {
        if (index == snapshot.activeIndex) active = existing;
        continue;
      }
      final (session, mode) = _open(host, entry);
      if (entry.workspaceGoneAt case final gone?) {
        _goneSince[session] = gone;
        _goneBefore.add(session);
      }
      if (mode == RestoredSessionMode.automatic) automatic.add(session);
      if (index == snapshot.activeIndex) active = session;
    }
    final front = alreadyActive ?? active;
    if (front != null) _workspace.activate(front);
    // The active session first, then the tab order.
    if (automatic.remove(front)) automatic.insert(0, front!);
    _queue.addAll(automatic);
    _schedulePump();
  }

  /// Opens [entry] as a restored tab, disconnected.
  (TerminalSessionController, RestoredSessionMode) _open(
    SavedHost host,
    SessionSnapshotEntry entry,
  ) {
    final session = _workspace.open(
      entry.target.apply(host),
      startupCommand: entry.target.startupCommand,
      target: entry.target,
    );
    if (entry.customTitle != null) session.rename(entry.customTitle);
    // Opening the terminal on one restored tab must not connect them all.
    _workspace.holdUntilActive(session);
    final mode = modeFor(host, entry.target);
    _restoredSessions[session] = _RestoredSession(mode);
    return (session, mode);
  }

  void _handleClosedWorkspaces() {
    if (_disposed) return;
    final closed = closedWorkspaces!.value;
    final now = _clock();
    var changed = false;
    for (final session in closed) {
      final since = _goneSince[session];
      if (_goneBefore.remove(session) &&
          since != null &&
          now.difference(since) > closeGoneAfter) {
        _toClose.add(session);
      } else if (since == null) {
        _goneSince[session] = now;
        changed = true;
      }
    }
    // Kept on a workspace again (Keep what Herdr shows): no longer gone.
    _goneSince.removeWhere((session, _) {
      final kept = !closed.contains(session) && !_goneBefore.contains(session);
      changed |= kept;
      return kept;
    });
    if (changed) _scheduleSave();
    if (_toClose.isNotEmpty) {
      _closeTimer ??= Timer(autoCloseDelay, () => unawaited(_closeGone()));
    }
  }

  /// Closes the gathered tabs whose workspace is still gone.
  Future<void> _closeGone() async {
    _closeTimer = null;
    final closed = closedWorkspaces?.value ?? const {};
    final sessions = _workspace.sessions;
    final tabs = <AutoClosedTab>[];
    for (final (index, session) in sessions.indexed) {
      if (!_toClose.contains(session) || !closed.contains(session)) continue;
      tabs.add(
        AutoClosedTab(
          index: index,
          entry: SessionSnapshotEntry(
            hostId: baseHostId(session.host.id),
            target: _workspace.targetOf(session),
            customTitle: session.customTitle,
            title: session.title,
            workspaceGoneAt: _goneSince[session],
          ),
        ),
      );
    }
    _toClose.clear();
    if (tabs.isEmpty || _disposed) return;
    for (final tab in tabs) {
      final session = sessions[tab.index];
      await _workspace.close(session);
    }
    if (_disposed) return;
    autoClosed.value = AutoClosedTabs(tabs);
  }

  /// Brings back [closed] (the notice's Undo) where they were, without
  /// changing the tab in front. They stay open for the rest of this run;
  /// their workspace counts as gone from now on.
  Future<void> undoAutoClose(AutoClosedTabs closed) async {
    if (identical(autoClosed.value, closed)) autoClosed.value = null;
    final front = _workspace.activeSession;
    final now = _clock();
    for (final tab in closed.tabs) {
      final host = await findHost(tab.entry.hostId);
      if (_disposed) return;
      if (host == null) continue;
      final existing = _workspace.sessions.any(
        (session) => session.host.id == tab.entry.target.apply(host).id,
      );
      if (existing) continue;
      final (session, mode) = _open(host, tab.entry);
      _goneSince[session] = now;
      _workspace.move(
        _workspace.sessions.length - 1,
        tab.index.clamp(0, _workspace.sessions.length - 1),
      );
      if (mode == RestoredSessionMode.automatic) _queue.add(session);
    }
    if (front != null) _workspace.activate(front);
    _scheduleSave();
    _schedulePump();
  }

  /// How a session to [target] on [host] is brought back.
  static RestoredSessionMode modeFor(SavedHost host, ConnectTarget target) {
    final reattaches = switch (target.kind) {
      ConnectTargetKind.herdr || ConnectTargetKind.tmux => true,
      ConnectTargetKind.shell => host.startTmuxOnConnect,
      ConnectTargetKind.directory => false,
    };
    if (!reattaches) return RestoredSessionMode.ended;
    return host.authMethod == SshAuthMethod.hardwareKey
        ? RestoredSessionMode.tapToReconnect
        : RestoredSessionMode.automatic;
  }

  /// Keeps the saved list through a lock: the lock closes every session,
  /// and unlocking brings them back like an app start.
  Future<void> holdForLock() async {
    _saveTimer?.cancel();
    await flush();
    _restored = false;
    _forget((_, _) => true);
  }

  void _forget(
    bool Function(TerminalSessionController, _RestoredSession) test,
  ) {
    _restoredSessions.removeWhere((session, restored) {
      if (!test(session, restored)) return false;
      restored.retry?.cancel();
      _workspace.release(session);
      return true;
    });
    _queue.removeWhere((session) => !_restoredSessions.containsKey(session));
  }

  /// Writes a pending change now (the app is going to the background).
  Future<void> flush() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    if (!_restored || !_enabled || _disposed) return;
    final snapshot = currentSnapshot();
    final encoded = jsonEncode(snapshot.toJson());
    if (encoded == _lastSaved) return;
    _lastSaved = encoded;
    await repository.save(snapshot);
  }

  /// The workspace as it would be saved now.
  SessionSnapshot currentSnapshot() {
    final active = _workspace.activeSession;
    final entries = <SessionSnapshotEntry>[];
    var activeIndex = 0;
    for (final session in _workspace.sessions) {
      if (session.host.isLocal) continue;
      if (session == active) activeIndex = entries.length;
      entries.add(
        SessionSnapshotEntry(
          hostId: baseHostId(session.host.id),
          target: _workspace.targetOf(session),
          customTitle: session.customTitle,
          title: session.title,
          workspaceGoneAt: _goneSince[session],
        ),
      );
    }
    return SessionSnapshot(entries: entries, activeIndex: activeIndex);
  }

  void _handleWorkspaceChanged() {
    if (_disposed) return;
    final open = _workspace.sessions.toSet();
    _goneSince.removeWhere((session, _) => !open.contains(session));
    _goneBefore.retainWhere(open.contains);
    _toClose.retainWhere(open.contains);
    _forget(
      (session, _) =>
          !open.contains(session) ||
          session.status == TerminalConnectionStatus.connected,
    );
    _scheduleSave();
    _schedulePump();
  }

  void _scheduleSave() {
    if (!_restored || !_enabled || _disposed) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(saveDebounce, () => unawaited(flush()));
  }

  void _schedulePump() {
    if (_pumpScheduled || _disposed || _queue.isEmpty) return;
    _pumpScheduled = true;
    scheduleMicrotask(() {
      _pumpScheduled = false;
      _pump();
    });
  }

  void _pump() {
    if (_disposed) return;
    final active = _workspace.activeSession;
    var inFlight = _inFlight;
    for (final session in List.of(_queue)) {
      if (inFlight >= maxParallel) return;
      final restored = _restoredSessions[session];
      if (restored == null || restored.gaveUp) {
        _queue.remove(session);
        continue;
      }
      if (restored.waiting || _started.contains(session)) continue;
      if (!session.shouldConnect) {
        // Something else (opening the terminal) is connecting it.
        continue;
      }
      if (!_homeVisible && session != active) continue;
      inFlight += 1;
      unawaited(_reconnect(session, restored));
    }
  }

  Future<void> _reconnect(
    TerminalSessionController session,
    _RestoredSession restored,
  ) async {
    _started.add(session);
    try {
      await session.connect();
    } finally {
      _started.remove(session);
    }
    if (_disposed) return;
    if (session.isConnected || !_restoredSessions.containsKey(session)) {
      _schedulePump();
      return;
    }
    restored.failures += 1;
    if (restored.failures > backoff.length) {
      restored.gaveUp = true;
      _queue.remove(session);
      notifyListeners();
    } else {
      restored.waiting = true;
      restored.retry = Timer(backoff[restored.failures - 1], () {
        restored.waiting = false;
        _schedulePump();
      });
    }
    _schedulePump();
  }

  @override
  void dispose() {
    _disposed = true;
    _saveTimer?.cancel();
    _closeTimer?.cancel();
    closedWorkspaces?.removeListener(_handleClosedWorkspaces);
    autoClosed.dispose();
    _forget((_, _) => true);
    _workspace.removeListener(_handleWorkspaceChanged);
    super.dispose();
  }
}

/// A tab closed because its Herdr workspace no longer exists: where it was
/// and how to reopen it.
@immutable
class AutoClosedTab {
  const AutoClosedTab({required this.index, required this.entry});

  /// Its place in the tab order when it closed.
  final int index;
  final SessionSnapshotEntry entry;
}

/// The tabs one launch closed together, for one notice.
@immutable
class AutoClosedTabs {
  const AutoClosedTabs(this.tabs);

  final List<AutoClosedTab> tabs;

  /// "Closed 3 tabs for workspaces that no longer exist".
  String get message => tabs.length == 1
      ? 'Closed 1 tab for a workspace that no longer exists'
      : 'Closed ${tabs.length} tabs for workspaces that no longer exist';
}

class _RestoredSession {
  _RestoredSession(this.mode);

  final RestoredSessionMode mode;
  int failures = 0;
  bool waiting = false;
  bool gaveUp = false;
  Timer? retry;
}
