import 'dart:async';

import 'package:conduit/core/theme/terminal_appearance.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:conduit/features/terminal/domain/network_connectivity.dart';
import 'package:conduit/features/terminal/domain/ssh_terminal_repository.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:flutter/foundation.dart';

class TerminalWorkspaceController extends ChangeNotifier {
  TerminalWorkspaceController(this._repository, [this._connectivity]);

  final SshTerminalRepository _repository;
  final NetworkConnectivity? _connectivity;

  final List<TerminalSessionController> _sessions = [];

  /// The connect target each session was opened with, when the caller
  /// passed one (it keeps the Herdr label, which the derived id drops).
  final Map<TerminalSessionController, ConnectTarget> _targets = {};

  /// Sessions the terminal page must not connect while they sit in a
  /// background tab (restored sessions: each connect may ask for a
  /// hardware-key touch or start a new shell).
  final Set<TerminalSessionController> _heldUntilActive = {};
  int _activeIndex = 0;
  TerminalEnterSequence _enterSequence = TerminalEnterSequence.cr;

  List<TerminalSessionController> get sessions => List.unmodifiable(_sessions);

  TerminalSessionController? get activeSession {
    if (_sessions.isEmpty) {
      return null;
    }
    return _sessions[_activeIndex.clamp(0, _sessions.length - 1)];
  }

  bool get hasSessions => _sessions.isNotEmpty;

  int get liveSessionCount => _sessions
      .where(
        (session) =>
            session.status == TerminalConnectionStatus.connecting ||
            session.status == TerminalConnectionStatus.connected,
      )
      .length;

  bool get hasLiveSessions => liveSessionCount > 0;

  void setEnterSequence(TerminalEnterSequence sequence) {
    _enterSequence = sequence;
    for (final session in _sessions) {
      session.enterSequence = sequence;
    }
  }

  /// Opens (or activates) the session for [host]. [startupCommand] is typed
  /// into the shell once connected; it only applies to a newly created
  /// session. [target] records what the session attaches to, for the list
  /// kept between app runs.
  TerminalSessionController open(
    SavedHost host, {
    String? startupCommand,
    ConnectTarget? target,
  }) {
    final existingIndex = _sessions.indexWhere(
      (session) => session.host.id == host.id,
    );
    if (existingIndex != -1) {
      _activeIndex = existingIndex;
      notifyListeners();
      return _sessions[existingIndex];
    }

    final session = TerminalSessionController(
      host: host,
      repository: _repository,
      connectivity: _connectivity,
      startupCommand: startupCommand,
      predictiveEchoEnabled: host.predictiveEchoEnabled,
      enterSequence: _enterSequence,
    );
    session.addListener(notifyListeners);
    if (target != null) _targets[session] = target;
    _sessions.add(session);
    _activeIndex = _sessions.length - 1;
    notifyListeners();
    return session;
  }

  /// What [session] attaches to: the target it was opened with, else the
  /// one encoded in its host id, else a plain shell.
  ConnectTarget targetOf(TerminalSessionController session) =>
      _targets[session] ??
      ConnectTarget.fromSessionHostId(session.host.id) ??
      const ConnectTarget.shell();

  /// Keeps [session] from connecting on its own until it is the active tab
  /// (or [release]d).
  void holdUntilActive(TerminalSessionController session) {
    if (_sessions.contains(session)) _heldUntilActive.add(session);
  }

  void release(TerminalSessionController session) {
    _heldUntilActive.remove(session);
  }

  /// Whether the terminal page may connect [session] as soon as its view
  /// is built: always for the active tab, and for every tab not held.
  bool mayAutoConnect(TerminalSessionController session) =>
      session == activeSession || !_heldUntilActive.contains(session);

  /// Moves the session at [from] to [to] (both indexes into [sessions]),
  /// keeping the same session active.
  void move(int from, int to) {
    if (from < 0 ||
        from >= _sessions.length ||
        to < 0 ||
        to >= _sessions.length ||
        from == to) {
      return;
    }
    final active = activeSession;
    final session = _sessions.removeAt(from);
    _sessions.insert(to, session);
    _activeIndex = active == null ? 0 : _sessions.indexOf(active);
    notifyListeners();
  }

  void activate(TerminalSessionController session) {
    final index = _sessions.indexOf(session);
    if (index == -1 || index == _activeIndex) {
      return;
    }
    _activeIndex = index;
    notifyListeners();
  }

  Future<void> close(TerminalSessionController session) async {
    final index = _sessions.indexOf(session);
    if (index == -1) {
      return;
    }

    _sessions.removeAt(index);
    _targets.remove(session);
    _heldUntilActive.remove(session);
    if (_sessions.isEmpty) {
      _activeIndex = 0;
    } else if (_activeIndex >= _sessions.length) {
      _activeIndex = _sessions.length - 1;
    } else if (index < _activeIndex) {
      _activeIndex -= 1;
    }
    notifyListeners();

    session.removeListener(notifyListeners);
    await session.disconnect();
    session.dispose();
  }

  Future<void> closeAll() async {
    final sessions = List<TerminalSessionController>.from(_sessions);
    _sessions.clear();
    _targets.clear();
    _heldUntilActive.clear();
    _activeIndex = 0;
    notifyListeners();

    for (final session in sessions) {
      session.removeListener(notifyListeners);
      await session.disconnect();
      session.dispose();
    }
  }

  /// Disconnects every session at once, for at most [timeout] (the app is
  /// quitting): each Mosh session's close ends its mosh-server. The
  /// sessions stay open, for the next run to restore.
  Future<void> disconnectAll({
    Duration timeout = const Duration(milliseconds: 2500),
  }) async {
    try {
      await Future.wait([
        for (final session in List.of(_sessions)) session.disconnect(),
      ]).timeout(timeout);
    } on TimeoutException {
      // Quit anyway: the next connection there ends what is left.
    }
  }

  @override
  void dispose() {
    for (final session in _sessions) {
      session.removeListener(notifyListeners);
      session.dispose();
    }
    _sessions.clear();
    super.dispose();
  }
}
