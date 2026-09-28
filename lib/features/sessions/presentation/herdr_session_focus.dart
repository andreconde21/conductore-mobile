import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:conduit/features/sessions/presentation/terminal_preview.dart';
import 'package:conduit/features/terminal/domain/herdr_keymap.dart';
import 'package:conduit/features/terminal/domain/herdr_remote_control.dart';
import 'package:conduit/features/terminal/presentation/session_input_hold.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:conduit_vt/conduit_vt.dart';
import 'package:flutter/widgets.dart';

/// Keeps the app's Herdr sessions pointed at the right place.
///
/// Herdr has one focused workspace per server, shared by every client
/// attached to it (checked against Herdr 0.9.1 with two clients: focusing
/// a workspace from one moves the other too, and keys typed into either
/// land in the focused workspace). Herdr 0.9.1 has no per-client focus.
/// Two app tabs attached to different workspaces of the same server would
/// therefore both show, and type into, whichever was focused last. This
/// class:
///
/// * remembers which workspace each app session is on, updating it from
///   Herdr when the user leaves the tab (they may have moved around inside
///   Herdr), and focuses it again whenever the session becomes the one in
///   use: a tab switch, a tile tap, the quick switcher, a desktop split
///   pane taking the focus, the app coming back to the foreground, another
///   session of the same server (re)attaching in the background, and
///   before the app types into it (composer, snippets, quick actions);
/// * holds the session's input while that focus is on its way, so nothing
///   typed in the meantime reaches another workspace (see
///   [TerminalSessionController.holdInput]);
/// * gives the other sessions of that server a snapshot of their own
///   screen for their previews ([TerminalSessionController.sharedView]),
///   since their live screen now mirrors the focused workspace;
/// * opens deep links (a notification, the home board, the agent sheet)
///   at the exact workspace, tab and pane of an agent, reusing an open
///   session when there is one;
/// * hands out one [HerdrRemoteControl] per Herdr server for the terminal
///   gestures and the navigator, so they share one command channel and run
///   in order.
///
/// All of the above moves the focus the laptop's Herdr shows too, so it
/// only happens when [mayMoveFocus] says this device may (Settings ›
/// Terminal, off by default). Otherwise the app never moves Herdr's focus
/// on its own:
///
/// * a session attaches without focusing (`herdr` alone, which leaves the
///   focus where it is);
/// * what the app writes (composer, snippets, quick actions, menu
///   answers, image paths) goes to the session's own pane by pane id
///   ([AppInputRouter]), wherever the focus is;
/// * typed keys go out only while Herdr's focus is on the session's own
///   workspace (checked with `herdr workspace list`); otherwise they are
///   held and the session says what Herdr shows instead
///   ([TerminalSessionController.focusElsewhere]) until the user sends
///   them through the composer, takes the focus once ([takeFocusOnce]),
///   keeps the shown workspace ([useShownWorkspace]) or discards them;
/// * previews of sessions whose workspace is not the focused one show that
///   workspace's own screen, read with `herdr pane read` (read-only).
///
/// Hosts that cannot take a background command channel (the local shell,
/// security-key logins where every connection asks for a touch) get no
/// control: gestures fall back to key bindings and nothing re-focuses.
class HerdrSessionFocus implements AppInputRouter {
  HerdrSessionFocus({
    required TerminalWorkspaceController workspace,
    required this.runnerFactory,
    this.reattachRefocusDelay = const Duration(seconds: 2),
    bool watchLifecycle = false,
    bool Function()? mayMoveFocus,
    this.focusCheckFreshness = const Duration(seconds: 3),
    this.refreshInterval,
    DateTime Function()? clock,
  }) : _workspace = workspace,
       _mayMoveFocus = mayMoveFocus ?? _never,
       _clock = clock ?? DateTime.now {
    _active = workspace.activeSession;
    _trackSessions();
    workspace.addListener(_handleWorkspaceChanged);
    if (watchLifecycle) {
      _lifecycle = AppLifecycleListener(
        onResume: () {
          _foreground = true;
          reassertActive();
        },
        onHide: () => _foreground = false,
      );
    }
  }

  /// How often the previews of Herdr sessions the shared focus is not on
  /// are read again (while this device may not move it); null never. The
  /// timer runs only while a Herdr session is open.
  final Duration? refreshInterval;

  static bool _never() => false;

  final bool Function() _mayMoveFocus;

  /// Whether this device may move Herdr's shared focus on its own (the
  /// setting). Read at each use, so a change applies at once.
  bool get mayMoveFocus => _mayMoveFocus();

  /// How long a check that Herdr shows a session's own workspace lets its
  /// keys through without asking again (a third of it in, it is checked
  /// again in the background).
  final Duration focusCheckFreshness;

  final TerminalWorkspaceController _workspace;
  final AgentCommandRunnerFactory runnerFactory;
  final DateTime Function() _clock;

  /// How long after a (re)connect the exact pane is focused again: the
  /// session's startup command focuses its own workspace as it attaches.
  /// It is also how long a session that attached in the background is
  /// given before its server's focus goes back to the session in use.
  final Duration reattachRefocusDelay;

  final _controls = <String, HerdrRemoteControl>{};

  /// Workspace each app session is on, by the session's host id.
  final _workspaces = <String, String>{};

  /// Sessions whose workspace was closed: no longer pinned to one.
  final _unpinned = <String>{};

  /// The session each Herdr server's focus was last put on by the app.
  final _owners = <String, TerminalSessionController>{};

  /// Focus commands on their way, by session: a claim while one is in
  /// flight rides on it.
  final _inFlight = <TerminalSessionController, Future<bool>>{};

  final _statuses = <TerminalSessionController, TerminalConnectionStatus>{};
  TerminalSessionController? _active;
  AppLifecycleListener? _lifecycle;
  Timer? _refreshTimer;
  bool _foreground = true;

  /// When Herdr was last seen showing each session's own workspace.
  final _verifiedAt = <TerminalSessionController, DateTime>{};

  /// A session's own screen as last seen while Herdr showed it.
  final _ownScreens = <TerminalSessionController, SharedViewSnapshot>{};

  /// The pane a deep link asked for, for the app's writes.
  final _preferredPanes = <TerminalSessionController, String>{};

  /// Focus checks on their way, by server.
  final _checks = <String, Future<_HerdrFocusView?>>{};
  final _timers = <Timer>{};
  bool _disposed = false;

  /// The Herdr server behind [session]: `<saved host id>|<session name>`.
  static String serverKey(TerminalSessionController session) {
    final target = ConnectTarget.fromSessionHostId(session.host.id);
    final herdrSession = target?.kind == ConnectTargetKind.herdr
        ? target!.session
        : '';
    return '${baseHostId(session.host.id)}|$herdrSession';
  }

  /// The Herdr target [session] was opened on, or null for tmux and shells.
  static ConnectTarget? herdrTargetOf(TerminalSessionController session) {
    final target = ConnectTarget.fromSessionHostId(session.host.id);
    return target?.kind == ConnectTargetKind.herdr ? target : null;
  }

  static bool _drivable(SavedHost host) =>
      !host.isLocal && host.authMethod != SshAuthMethod.hardwareKey;

  /// The command channel for [session]'s Herdr server; null when the host
  /// cannot be driven in the background.
  HerdrRemoteControl? controlFor(TerminalSessionController session) {
    if (_disposed || !_drivable(session.host)) {
      return null;
    }
    final key = serverKey(session);
    return _controls[key] ??= HerdrRemoteControl(
      runnerFactory: () => runnerFactory(session.host),
      session: herdrTargetOf(session)?.session ?? '',
    );
  }

  /// When each machine's keymap was last asked for (by saved host id).
  final _keymapAttempts = <String, DateTime>{};

  /// How long a failed keymap read waits before it is tried again.
  static const keymapRetryInterval = Duration(minutes: 5);

  /// Reads the Herdr key bindings of [session]'s machine once (read-only),
  /// for every key-labelled shortcut and key fallback; until then, and when
  /// the read fails, Herdr's defaults apply. Cheap to call on every build.
  void ensureKeymap(TerminalSessionController session) {
    final hostId = baseHostId(session.host.id);
    if (HerdrKeymapCache.instance.has(hostId)) {
      return;
    }
    final control = controlFor(session);
    final last = _keymapAttempts[hostId];
    final now = DateTime.now();
    if (control == null ||
        (last != null && now.difference(last) < keymapRetryInterval)) {
      return;
    }
    _keymapAttempts[hostId] = now;
    unawaited(HerdrKeymapCache.instance.loadWith(hostId, control.readKeymap));
  }

  /// The workspace [session] is on, as far as the app knows.
  String? workspaceOf(TerminalSessionController session) {
    final hostId = session.host.id;
    if (_unpinned.contains(hostId)) {
      return null;
    }
    final known = _workspaces[hostId];
    if (known != null) {
      return known;
    }
    final target = herdrTargetOf(session);
    return target == null || target.name.isEmpty ? null : target.name;
  }

  /// Records that [session] now shows [workspaceId] (after a gesture or a
  /// navigator jump moved it).
  void noteWorkspace(TerminalSessionController session, String workspaceId) {
    if (workspaceId.isNotEmpty) {
      _workspaces[session.host.id] = workspaceId;
      _unpinned.remove(session.host.id);
    }
  }

  /// Focuses the active session's workspace again, holding its input until
  /// Herdr confirms. For when the app comes back to the foreground: the
  /// laptop, or another client, may have moved the shared focus meanwhile.
  void reassertActive() {
    final active = _workspace.activeSession;
    if (active == null) return;
    if (mayMoveFocus) {
      _claim(active);
    } else if (herdrTargetOf(active) != null && controlFor(active) != null) {
      unawaited(_checkServer(active));
    }
  }

  /// Wires sessions that just appeared, and notices a Herdr session
  /// finishing its (re)connect: its startup command focuses its own
  /// workspace, which moves every other client of that server with it.
  void _trackSessions() {
    final sessions = _workspace.sessions;
    _statuses.removeWhere((session, _) => !sessions.contains(session));
    _inFlight.removeWhere((session, _) => !sessions.contains(session));
    _owners.removeWhere((_, session) => !sessions.contains(session));
    _verifiedAt.removeWhere((session, _) => !sessions.contains(session));
    _ownScreens.removeWhere((session, _) => !sessions.contains(session));
    _preferredPanes.removeWhere((session, _) => !sessions.contains(session));
    _syncRefreshTimer(sessions);
    for (final session in sessions) {
      if (!_statuses.containsKey(session) && herdrTargetOf(session) != null) {
        session
          ..inputClaimer = _claim
          ..inputCheck = _checkBeforeInput
          ..startupCommandFilter = _filterStartup
          ..appInputRouter = this;
      }
      final before = _statuses[session];
      final now = session.status;
      _statuses[session] = now;
      if (now == TerminalConnectionStatus.connected &&
          before != TerminalConnectionStatus.connected &&
          before != null) {
        _attachedInBackground(session);
      }
    }
  }

  void _handleWorkspaceChanged() {
    final sessions = _workspace.sessions;
    _workspaces.removeWhere(
      (hostId, _) => !sessions.any((session) => session.host.id == hostId),
    );
    _trackSessions();
    final next = _workspace.activeSession;
    final previous = _active;
    if (next == previous) {
      return;
    }
    _active = next;
    if (next == null) {
      return;
    }
    if (mayMoveFocus) {
      unawaited(_refocus(previous, next));
    } else if (herdrTargetOf(next) != null && controlFor(next) != null) {
      // Read-only: where Herdr's focus is, for the banner and previews.
      unawaited(_checkServer(next));
    }
  }

  /// [session] (re)attached its Herdr client, and its startup command
  /// focuses its own workspace. When another session owns that server's
  /// focus and is the one in use, that took the focus away from it: once
  /// the command had time to run, keep a snapshot of [session]'s own
  /// workspace for its preview and give the focus back, holding the
  /// owner's input meanwhile. An owner not in use just hands over.
  void _attachedInBackground(TerminalSessionController session) {
    if (herdrTargetOf(session) == null) return;
    if (!mayMoveFocus) {
      // Its attach left the focus alone; its screen now mirrors it.
      if (controlFor(session) != null) {
        _later(() async => _checkServer(session));
      }
      return;
    }
    final key = serverKey(session);
    final owner = _owners[key];
    if (owner == null || owner == session) {
      return;
    }
    if (owner != _workspace.activeSession || controlFor(owner) == null) {
      _handOver(owner);
      _owners[key] = session;
      session.sharedViewSnapshot = null;
      _markMirrors(session);
      return;
    }
    final done = Completer<bool>();
    owner.holdInput(done.future, label: _labelOf(owner));
    _later(() async {
      if (_owners[serverKey(session)] != owner ||
          !_workspace.sessions.contains(owner)) {
        done.complete(true);
        return;
      }
      if (_workspace.sessions.contains(session)) {
        session.sharedViewSnapshot = SharedViewSnapshot.capture(
          session.terminal,
          label: _labelOf(session),
          at: _clock(),
        );
      }
      done.complete(await _focus(owner));
    });
  }

  /// The inputClaimer of every Herdr session: before the app types into
  /// [session], make sure its server's focus is on its workspace.
  void _claim(TerminalSessionController session) {
    if (_disposed || !mayMoveFocus || _inFlight.containsKey(session)) return;
    if (herdrTargetOf(session) == null || controlFor(session) == null) return;
    final owner = _owners[serverKey(session)];
    if (owner != null && owner != session) {
      _handOver(owner);
    }
    _owners[serverKey(session)] = session;
    session.sharedViewSnapshot = null;
    unawaited(_focus(session));
  }

  /// [from] stops owning its server's focus: its previews keep what it
  /// shows now (its own workspace, until the focus moves).
  void _handOver(TerminalSessionController from) {
    if (!_workspace.sessions.contains(from)) return;
    from.sharedViewSnapshot = SharedViewSnapshot.capture(
      from.terminal,
      label: _labelOf(from),
      at: _clock(),
    );
  }

  /// Every Herdr session on [owner]'s server but [owner] mirrors [owner]'s
  /// workspace from now on: the ones without a snapshot get an empty one,
  /// so their preview says so rather than showing [owner]'s screen.
  void _markMirrors(TerminalSessionController owner) {
    final key = serverKey(owner);
    for (final session in _workspace.sessions) {
      if (session == owner ||
          herdrTargetOf(session) == null ||
          serverKey(session) != key ||
          session.sharedView.value != null) {
        continue;
      }
      session.sharedViewSnapshot = SharedViewSnapshot(
        preview: StyledTerminalPreview.empty,
        capturedAt: _clock(),
        label: _labelOf(session),
      );
    }
  }

  /// Focuses [session]'s workspace and holds its input until Herdr
  /// confirms. True when Herdr focused it.
  Future<bool> _focus(TerminalSessionController session) {
    final running = _inFlight[session];
    if (running != null) return running;
    final control = controlFor(session);
    final workspaceId = workspaceOf(session);
    if (control == null || workspaceId == null) {
      return Future.value(false);
    }
    final label = _labelOf(session);
    final result = control.focusWorkspaceOutcome(workspaceId).then((outcome) {
      if (outcome == HerdrFocusOutcome.missing &&
          workspaceOf(session) == workspaceId) {
        // Closed in Herdr: the session shows whatever Herdr falls back to
        // and is no longer pinned (the input held so far is still
        // dropped, it was meant for the closed workspace).
        _unpinned.add(session.host.id);
      }
      return outcome == HerdrFocusOutcome.focused;
    });
    _inFlight[session] = result;
    session.holdInput(result, label: label);
    _markMirrors(session);
    unawaited(
      result.whenComplete(() {
        if (identical(_inFlight[session], result)) _inFlight.remove(session);
      }),
    );
    return result;
  }

  /// What the input hint calls [session]'s place: its Herdr label when it
  /// is still on the workspace it was opened on, else the workspace id.
  String _labelOf(TerminalSessionController session) {
    final target = _workspace.targetOf(session);
    final workspaceId = workspaceOf(session) ?? '';
    if (target.kind == ConnectTargetKind.herdr &&
        (workspaceId.isEmpty || workspaceId == target.name)) {
      return target.title;
    }
    return workspaceId;
  }

  Future<void> _refocus(
    TerminalSessionController? previous,
    TerminalSessionController next,
  ) async {
    final target = herdrTargetOf(next);
    final control = target == null ? null : controlFor(next);
    if (target == null || control == null) {
      return;
    }
    final workspaceId = workspaceOf(next);
    if (workspaceId == null) {
      return;
    }
    final key = serverKey(next);
    final owner = _owners[key];
    final samePrevious =
        previous != null &&
        _workspace.sessions.contains(previous) &&
        herdrTargetOf(previous) != null &&
        serverKey(previous) == key;
    if (owner != null && owner != next) {
      _handOver(owner);
    }
    _owners[key] = next;
    next.sharedViewSnapshot = null;
    Future<String?>? remembered;
    if (samePrevious && owner == previous) {
      // Learn where the tab we are leaving ended up before moving Herdr.
      // The control runs commands in order, so this reads the old focus.
      remembered = control.focusedWorkspaceId();
    }
    final focus = _focus(next);
    final leftOn = await remembered;
    await focus;
    if (leftOn != null &&
        previous != null &&
        leftOn != workspaceOf(previous) &&
        !_pinnedByAnother(previous, leftOn)) {
      noteWorkspace(previous, leftOn);
    }
  }

  /// Whether another open session of [session]'s server is pinned to
  /// [workspaceId]: then Herdr being there says nothing about where the
  /// user took [session] (that session's attach, or a switch to it, put it
  /// there).
  bool _pinnedByAnother(TerminalSessionController session, String workspaceId) {
    final key = serverKey(session);
    for (final other in _workspace.sessions) {
      if (other != session &&
          herdrTargetOf(other) != null &&
          serverKey(other) == key &&
          workspaceOf(other) == workspaceId) {
        return true;
      }
    }
    return false;
  }

  /// Opens the app at an agent's exact place on [host]: its workspace, tab
  /// and pane in the default Herdr session.
  ///
  /// Reuses an open Herdr session on that server (the one already on the
  /// workspace if any), reconnecting it when it dropped; otherwise opens a
  /// new one whose attach command focuses the place first. Returns the
  /// session to show, or null when [open] is null and nothing was open.
  Future<TerminalSessionController?> openAgentLocation(
    SavedHost host, {
    required String workspaceId,
    String tabId = '',
    String paneId = '',
    String label = '',
    TerminalSessionController Function(ConnectTarget target)? open,
  }) async {
    final existing = _herdrSessionFor(host, workspaceId);
    if (existing != null) {
      // Recorded first, so the switch-over focuses the right workspace.
      noteWorkspace(existing, workspaceId);
      if (paneId.isNotEmpty) _preferredPanes[existing] = paneId;
      _workspace.activate(existing);
      final control = controlFor(existing);
      final reconnect = existing.shouldConnect;
      if (reconnect) {
        unawaited(existing.connect());
      }
      if (control != null && mayMoveFocus) {
        // Not awaited: the caller shows the terminal straight away.
        unawaited(
          control.focusLocation(
            workspaceId: workspaceId,
            tabId: tabId,
            paneId: paneId,
          ),
        );
        if (reconnect) {
          _later(
            () => control.focusLocation(
              workspaceId: workspaceId,
              tabId: tabId,
              paneId: paneId,
            ),
          );
        }
      }
      return existing;
    }
    if (open == null || workspaceId.isEmpty) {
      return null;
    }
    // One app tab per workspace: the pane (or tab) only steers this attach.
    return open(
      ConnectTarget.herdr(
        workspaceId: workspaceId,
        label: label,
        tabId: paneId.isEmpty ? tabId : '',
        paneId: paneId,
      ),
    );
  }

  /// An open Herdr session on [host]'s default server, preferring one that
  /// is on [workspaceId].
  TerminalSessionController? _herdrSessionFor(
    SavedHost host,
    String workspaceId,
  ) {
    TerminalSessionController? any;
    for (final session in _workspace.sessions) {
      if (baseHostId(session.host.id) != host.id) {
        continue;
      }
      final target = herdrTargetOf(session);
      if (target == null || target.session.isNotEmpty) {
        continue;
      }
      if (workspaceId.isNotEmpty && workspaceOf(session) == workspaceId) {
        return session;
      }
      any ??= session;
    }
    return any;
  }

  void _later(Future<void> Function() action) {
    late final Timer timer;
    timer = Timer(reattachRefocusDelay, () {
      _timers.remove(timer);
      if (!_disposed) {
        unawaited(action());
      }
    });
    _timers.add(timer);
  }

  // ---------------------------------------------------------------------
  // When this device may not move Herdr's focus.

  String _filterStartup(String command) =>
      mayMoveFocus ? command : ConnectTarget.withoutHerdrFocus(command);

  /// [TerminalSessionController.inputCheck]: typed keys go straight out
  /// while Herdr was seen on the session's own workspace recently; else
  /// they wait for a check, and stay held when Herdr shows another one.
  Future<InputHoldDecision>? _checkBeforeInput(
    TerminalSessionController session,
  ) {
    if (_disposed || mayMoveFocus || workspaceOf(session) == null) {
      return null;
    }
    if (controlFor(session) == null) {
      return null;
    }
    final at = _verifiedAt[session];
    if (at != null) {
      final age = _clock().difference(at);
      if (age < focusCheckFreshness) {
        if (age > focusCheckFreshness ~/ 3) {
          unawaited(_checkServer(session));
        }
        return null;
      }
    }
    return _checkServer(session).then(
      (view) => view != null && view.focusedId == workspaceOf(session)
          ? InputHoldDecision.send
          : InputHoldDecision.block,
    );
  }

  /// Moves Herdr's focus to [session]'s workspace this one time (the user
  /// asked, from the banner or a split pane's cover), then sends what was
  /// held. True when Herdr focused it.
  Future<bool> takeFocusOnce(TerminalSessionController session) async {
    final control = controlFor(session);
    final workspaceId = workspaceOf(session);
    if (control == null || workspaceId == null) return false;
    final outcome = await control.focusWorkspaceOutcome(workspaceId);
    if (outcome != HerdrFocusOutcome.focused) {
      if (outcome == HerdrFocusOutcome.missing) {
        _unpinned.add(session.host.id);
      }
      return false;
    }
    _applyFocus(serverKey(session), workspaceId, const {});
    session.releaseHeldInput();
    return true;
  }

  /// Keeps [session] on the workspace Herdr shows now (the user moved
  /// there inside this session's own Herdr), then sends what was held.
  Future<bool> useShownWorkspace(TerminalSessionController session) async {
    final view = await _checkServer(session);
    final shown = view?.focusedId;
    if (shown == null) return false;
    noteWorkspace(session, shown);
    _applyFocus(serverKey(session), shown, {shown: view!.focusedLabel});
    session.releaseHeldInput();
    return true;
  }

  /// Where [session]'s Herdr server has its focus now (read-only); updates
  /// every session of that server with it. Null when it could not be read.
  Future<_HerdrFocusView?> _checkServer(TerminalSessionController session) {
    final key = serverKey(session);
    final running = _checks[key];
    if (running != null) return running;
    final control = controlFor(session);
    if (control == null) return Future.value();
    final check = control.workspaces().then((items) {
      if (items == null || _disposed) return null;
      final focused = items.where((item) => item.focused).firstOrNull;
      _applyFocus(key, focused?.id, {
        for (final item in items) item.id: item.label,
      });
      return _HerdrFocusView(focused?.id, focused?.label ?? '');
    });
    _checks[key] = check;
    unawaited(
      check.whenComplete(() {
        if (identical(_checks[key], check)) unawaited(_checks.remove(key));
      }),
    );
    return check;
  }

  /// Herdr's focus on server [key] is on [focusedId]: the session on that
  /// workspace previews live and takes keys; the others say what Herdr
  /// shows instead, and preview their own workspace.
  void _applyFocus(String key, String? focusedId, Map<String, String> labels) {
    final now = _clock();
    for (final session in _workspace.sessions) {
      if (herdrTargetOf(session) == null || serverKey(session) != key) {
        continue;
      }
      final own = workspaceOf(session);
      if (own != null && own == focusedId) {
        _verifiedAt[session] = now;
        session
          ..focusElsewhereLabel = null
          ..sharedViewSnapshot = null;
        if (session.isConnected) {
          _ownScreens[session] = SharedViewSnapshot.capture(
            session.terminal,
            label: _labelOf(session),
            at: now,
          );
        }
        continue;
      }
      _verifiedAt.remove(session);
      session
        ..focusElsewhereLabel = focusedId == null
            ? ''
            : labels[focusedId] ?? focusedId
        ..sharedViewSnapshot =
            session.sharedView.value ??
            _ownScreens[session] ??
            SharedViewSnapshot(
              preview: StyledTerminalPreview.empty,
              capturedAt: now,
              label: _labelOf(session),
            );
      unawaited(_readPreview(session));
    }
  }

  void _syncRefreshTimer(List<TerminalSessionController> sessions) {
    final interval = refreshInterval;
    final wanted =
        interval != null &&
        !_disposed &&
        sessions.any((session) => herdrTargetOf(session) != null);
    if (!wanted) {
      _refreshTimer?.cancel();
      _refreshTimer = null;
    } else {
      _refreshTimer ??= Timer.periodic(interval, (_) => _refreshAll());
    }
  }

  /// Every server's focus again, and the previews of the sessions it is
  /// not on (while the app is in the foreground).
  void _refreshAll() {
    if (_disposed || mayMoveFocus || !_foreground) return;
    final seen = <String>{};
    for (final session in _workspace.sessions) {
      if (herdrTargetOf(session) == null ||
          !session.isConnected ||
          controlFor(session) == null ||
          !seen.add(serverKey(session))) {
        continue;
      }
      unawaited(_checkServer(session));
    }
  }

  /// The pane the app writes to for [session]: the pane a deep link asked
  /// for while it is still in the session's workspace, else the pane that
  /// workspace has focused in its active tab (each workspace remembers its
  /// own, whatever the server's focus). Read-only.
  Future<_HerdrPane?> _paneFor(TerminalSessionController session) async {
    final control = controlFor(session);
    final workspaceId = workspaceOf(session);
    if (control == null || workspaceId == null) return null;
    final list = await control.query(control.commands.paneList);
    if (list == null || !HerdrRemoteControl.succeeded(list)) return null;
    final panes = _HerdrPane.parseList(
      list.stdout,
    ).where((pane) => pane.workspaceId == workspaceId).toList();
    if (panes.isEmpty) return null;
    final preferred = _preferredPanes[session];
    final asked = panes.where((pane) => pane.id == preferred).firstOrNull;
    if (asked != null) return asked;
    final workspaces = await control.workspaces();
    final activeTab =
        workspaces
            ?.where((item) => item.id == workspaceId)
            .firstOrNull
            ?.activeTabId ??
        '';
    final inTab = panes.where((pane) => pane.tabId == activeTab).toList();
    final probe = (inTab.isEmpty ? panes : inTab).first;
    final layout = await control.query(control.commands.paneLayout(probe.id));
    final focusedId = layout == null || !HerdrRemoteControl.succeeded(layout)
        ? null
        : _HerdrPane.focusedInLayout(layout.stdout);
    final pane = panes.where((pane) => pane.id == focusedId).firstOrNull;
    if (pane == null) return probe;
    return pane.withSize(_HerdrPane.sizeInLayout(layout!.stdout, pane.id));
  }

  /// Reads what [session]'s own workspace shows (`herdr pane read`, with
  /// colours) for its preview, without moving any focus.
  Future<void> _readPreview(TerminalSessionController session) async {
    final control = controlFor(session);
    if (control == null) return;
    final pane = await _paneFor(session);
    if (pane == null) return;
    final read = await control.query(control.commands.paneReadVisible(pane.id));
    if (read == null ||
        !HerdrRemoteControl.succeeded(read) ||
        _disposed ||
        !_workspace.sessions.contains(session) ||
        session.focusElsewhere.value == null) {
      return;
    }
    final screen = Terminal(maxLines: 200)
      ..resize(math.max(20, pane.columns), math.max(4, pane.rows));
    screen.write(read.stdout.replaceAll('\r\n', '\n').replaceAll('\n', '\r\n'));
    session.sharedViewSnapshot = SharedViewSnapshot.capture(
      screen,
      label: _labelOf(session),
      at: _clock(),
    );
  }

  static const _herdrKeys = {
    TerminalKey.enter: 'enter',
    TerminalKey.escape: 'esc',
    TerminalKey.tab: 'tab',
    TerminalKey.backspace: 'backspace',
    TerminalKey.arrowUp: 'up',
    TerminalKey.arrowDown: 'down',
    TerminalKey.arrowLeft: 'left',
    TerminalKey.arrowRight: 'right',
  };

  /// [AppInputRouter]: while this device may not move Herdr's focus, the
  /// app's writes go to the session's own pane by id. An agent's prompt
  /// goes through `herdr agent prompt` (Herdr's own submit).
  @override
  Future<bool> sendText(
    TerminalSessionController session,
    String text, {
    required bool submit,
  }) async {
    if (mayMoveFocus || _disposed) return false;
    final control = controlFor(session);
    final pane = control == null ? null : await _paneFor(session);
    if (control == null || pane == null) return false;
    if (submit && text.isNotEmpty && pane.hasAgent) {
      if (await control.run(control.commands.agentPrompt(pane.id, text))) {
        return true;
      }
    }
    if (text.isNotEmpty &&
        !await control.run(control.commands.paneSendText(pane.id, text))) {
      return false;
    }
    if (submit) {
      if (text.isNotEmpty) {
        // Enter as its own keypress, as the terminal path does.
        await Future<void>.delayed(
          TerminalSessionController.composedEnterDelay,
        );
      }
      await control.run(control.commands.paneSendKeys(pane.id, ['enter']));
    }
    return true;
  }

  @override
  Future<bool> sendKeys(
    TerminalSessionController session,
    List<TerminalKey> keys,
  ) async {
    if (mayMoveFocus || _disposed) return false;
    final names = [for (final key in keys) _herdrKeys[key]];
    if (names.contains(null)) return false;
    final control = controlFor(session);
    final pane = control == null ? null : await _paneFor(session);
    if (control == null || pane == null) return false;
    return control.run(
      control.commands.paneSendKeys(pane.id, names.cast<String>()),
    );
  }

  @visibleForTesting
  Iterable<HerdrRemoteControl> get controls => _controls.values;

  Future<void> dispose() async {
    _disposed = true;
    _lifecycle?.dispose();
    _refreshTimer?.cancel();
    _workspace.removeListener(_handleWorkspaceChanged);
    for (final session in _statuses.keys) {
      if (session.inputClaimer == _claim) session.inputClaimer = null;
      if (session.appInputRouter == this) {
        session
          ..appInputRouter = null
          ..inputCheck = null
          ..startupCommandFilter = null;
      }
    }
    for (final timer in _timers) {
      timer.cancel();
    }
    _timers.clear();
    final controls = List.of(_controls.values);
    _controls.clear();
    for (final control in controls) {
      await control.close();
    }
  }
}

/// Where a Herdr server's focus is: [focusedId] null when nothing is.
class _HerdrFocusView {
  const _HerdrFocusView(this.focusedId, this.focusedLabel);

  final String? focusedId;
  final String focusedLabel;
}

/// One pane of `herdr pane list`.
class _HerdrPane {
  const _HerdrPane({
    required this.id,
    required this.workspaceId,
    required this.tabId,
    required this.hasAgent,
    this.columns = 80,
    this.rows = 24,
  });

  final String id;
  final String workspaceId;
  final String tabId;
  final bool hasAgent;
  final int columns;
  final int rows;

  _HerdrPane withSize(({int columns, int rows})? size) => size == null
      ? this
      : _HerdrPane(
          id: id,
          workspaceId: workspaceId,
          tabId: tabId,
          hasAgent: hasAgent,
          columns: size.columns,
          rows: size.rows,
        );

  static Object? _result(String raw) {
    try {
      final decoded = jsonDecode(raw.trim());
      return decoded is Map ? decoded['result'] ?? decoded : null;
    } catch (_) {
      return null;
    }
  }

  static List<_HerdrPane> parseList(String raw) {
    final result = _result(raw);
    final panes = result is Map ? result['panes'] : null;
    if (panes is! List) return const [];
    String text(Map<Object?, Object?> pane, String key) {
      final value = pane[key];
      return value is String ? value : '';
    }

    return [
      for (final pane in panes)
        if (pane is Map && text(pane, 'pane_id').isNotEmpty)
          _HerdrPane(
            id: text(pane, 'pane_id'),
            workspaceId: text(pane, 'workspace_id'),
            tabId: text(pane, 'tab_id'),
            hasAgent: text(pane, 'agent').isNotEmpty,
          ),
    ];
  }

  static Map<Object?, Object?>? _layout(String raw) {
    final result = _result(raw);
    final layout = result is Map ? result['layout'] : null;
    return layout is Map ? layout : null;
  }

  /// `focused_pane_id` of `herdr pane layout`: the pane its tab focuses.
  static String? focusedInLayout(String raw) {
    final id = _layout(raw)?['focused_pane_id'];
    return id is String && id.isNotEmpty ? id : null;
  }

  static ({int columns, int rows})? sizeInLayout(String raw, String paneId) {
    final panes = _layout(raw)?['panes'];
    if (panes is! List) return null;
    for (final pane in panes) {
      if (pane is Map && pane['pane_id'] == paneId) {
        final rect = pane['rect'];
        if (rect is Map && rect['width'] is int && rect['height'] is int) {
          return (columns: rect['width'] as int, rows: rect['height'] as int);
        }
      }
    }
    return null;
  }
}
