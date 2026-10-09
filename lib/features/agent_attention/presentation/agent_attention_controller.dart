// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';

import 'package:conduit/core/app_failure.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention_notifier.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention_provider.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/agent_attention/domain/agent_inbox.dart';
import 'package:conduit/features/agent_attention/domain/agent_kinds.dart';
import 'package:conduit/features/agent_attention/domain/agent_notifications.dart';
import 'package:conduit/features/agent_attention/domain/agent_permission_actions.dart';
import 'package:conduit/features/agent_attention/domain/agent_urgent_notifications.dart';
import 'package:conduit/features/agent_attention/domain/approval_rules.dart';
import 'package:conduit/features/agent_attention/domain/launcher_prompt.dart';
import 'package:conduit/features/chat_view/data/conductore_chat_client.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/live/domain/live_host_model.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:flutter/foundation.dart';

/// One waiting permission request with where it waits.
typedef PendingApproval = ({
  String hostId,
  String hostName,
  AgentInfo agent,
  PendingPermissionRequest request,
});

/// Builds a command runner for one host; injected so tests can fake the
/// remote side.
typedef AgentCommandRunnerFactory = AgentCommandRunner Function(SavedHost host);

/// Monitoring status for one host, as shown by the dashboard.
class AgentHostStatus {
  const AgentHostStatus({
    this.loading = false,
    this.agents = const [],
    this.error,
    this.unavailableReason,
    this.updatedAt,
  });

  final bool loading;
  final List<AgentInfo> agents;

  /// Transient fetch error (connection loss, malformed output).
  final String? error;

  /// Set when the provider tooling is missing/too old; polling has stopped.
  final String? unavailableReason;

  final DateTime? updatedAt;
}

/// Watches enabled, connected hosts for agent state changes.
///
/// Polling is deliberately conservative: one in-flight fetch per host
/// (ticks are skipped while a fetch runs), a fixed interval that backs off
/// after consecutive failures, paused while the app is backgrounded,
/// stopped when the session disconnects or closes, and stopped entirely for
/// a host whose provider tooling is missing. Hosts that log in with a
/// hardware key are listed but never polled: every poll would open a new
/// SSH connection and ask for a key touch.
///
/// Each host picks its provider once per connection from its
/// [SavedHost.agentMonitor] setting: Herdr, the Conductore companion, or
/// automatically (the companion when its CLI answers `version`, else
/// Herdr). A provider that supports it is additionally watched through a
/// long-poll while the app is in the foreground, so a permission prompt
/// shows up within a second instead of at the next 15 s poll; the periodic
/// poll keeps running as the fallback (and is all that runs in the
/// background).
///
/// Notifications: one per agent, a summary of what it needs now
/// ([AgentNotificationPolicy]), updated in place as the agent changes and
/// removed once nothing is left for it (answered anywhere, or the agent
/// ended). Pending permission requests show whenever they are seen (the
/// first snapshot included: an unanswered prompt is actionable), with
/// buttons for the first one. Questions, errors and finished turns are
/// edge-triggered on state *transitions* by stable agent identity: the
/// first snapshot after monitoring starts never notifies them, and a
/// provider-reported state sequence counts as a transition too, so an
/// agent that was answered and asked again between two polls still
/// notifies. Only a new need alerts; updates within one are silent. What
/// was notified outlives a reconnect, so reconnecting neither re-alerts
/// nor leaves an answered agent's notification behind. A request that
/// timed out on the host (the agent still waits, now in the terminal)
/// turns the notification into "is waiting for you".
///
/// That is the "Everything" mode. The default "Ongoing + urgent" mode
/// (CON-074) posts one ongoing, silent status notification listing every
/// agent ([AgentStatusSummary], throttled by [AgentStatusThrottle]) and
/// per-agent alerts only for urgent needs ([UrgentNotificationPolicy]);
/// "Urgent only" drops the status notification. Muted agents never notify.
class AgentAttentionController extends ChangeNotifier {
  AgentAttentionController({
    required TerminalWorkspaceController workspace,
    required AgentCommandRunnerFactory runnerFactory,
    required AgentAttentionProvider provider,
    AgentAttentionProvider? companionProvider,
    AgentAttentionNotifier? notifier,
    AgentNotificationPreferencesStore? notificationPreferences,
    Duration pollInterval = const Duration(seconds: 15),
    Duration watchRestartDelay = const Duration(milliseconds: 500),
    AgentStatusThrottle? statusThrottle,
    DateTime Function()? clock,
    this.persistMonitoringEnabled,
  }) : _statusThrottle = statusThrottle ?? AgentStatusThrottle(),
       _clock = clock ?? DateTime.now,
       _workspace = workspace,
       _runnerFactory = runnerFactory,
       _provider = provider,
       _companionProvider = companionProvider,
       _notifier = notifier,
       _notificationStore =
           notificationPreferences ?? MemoryAgentNotificationPreferencesStore(),
       _pollInterval = pollInterval,
       _watchRestartDelay = watchRestartDelay {
    _workspace.addListener(_syncMonitors);
    _syncMonitors();
    unawaited(_loadNotificationPreferences());
  }

  final TerminalWorkspaceController _workspace;
  final AgentCommandRunnerFactory _runnerFactory;

  /// The default (Herdr) provider.
  final AgentAttentionProvider _provider;

  /// The Conductore companion provider, when the app ships one.
  final AgentAttentionProvider? _companionProvider;
  final AgentAttentionNotifier? _notifier;
  final AgentNotificationPreferencesStore _notificationStore;
  AgentNotificationPreferences _notificationPreferences =
      const AgentNotificationPreferences();
  final Duration _pollInterval;

  /// Pause between two long-polls, so a host that answers instantly cannot
  /// spin the loop.
  final Duration _watchRestartDelay;

  final Map<String, _HostMonitor> _monitors = {};

  /// Saves "Monitor coding agents: on" for a saved host id (the app wires
  /// this to the hosts store). Null: [enableMonitoring] only lasts until
  /// the app restarts.
  final Future<void> Function(String savedHostId)? persistMonitoringEnabled;

  /// Saved host ids turned on from the phone this run: open sessions keep
  /// the host they were opened with, so this overrides their stale flag.
  final Set<String> _enabledHostIds = {};

  /// Inbox rows swiped away on this phone; they come back when the agent
  /// changes. Kept here so they survive closing the panel.
  final AgentInboxDismissals inboxDismissals = AgentInboxDismissals();
  final Set<String> _deciding = {};

  /// Per saved host id: its approval rules and auto-approved log, once
  /// loaded (see [loadApprovals]).
  final Map<String, ApprovalsSnapshot> _approvals = {};
  final Set<String> _loadingApprovals = {};

  /// Per agent notification key: what it last notified. Kept across
  /// reconnects (monitors come and go with the session).
  final Map<String, AgentNotice> _notices = {};

  /// Per host: the agent notifications last handed to the platform; null
  /// until the first sync of this run, which always goes out so leftovers
  /// from an earlier run are cleared.
  final Map<String, List<AgentNotification>> _sentNotifications = {};

  /// The agents dashboard's cached headline or summary for an agent
  /// (host id, agent id), shown in its expanded notification. The app
  /// wires it to the digest once that exists.
  String? Function(String hostId, String agentId)? notificationDetail;

  /// The agents dashboard's first stuck flag for an agent (host id, agent
  /// id), for the urgent "looks stuck" alert. The app wires it to the
  /// digest; call [resyncNotifications] when its answer changes.
  String? Function(String hostId, String agentId)? stuckReasonFor;

  /// The saved machine's name for its id (the app wires it to the hosts
  /// store), for the monitor's machine: a session's own host is named
  /// after its Herdr workspace or tmux session too ("dev: lf-seguros-web").
  String? Function(String savedHostId)? machineName;

  final AgentStatusThrottle _statusThrottle;
  final DateTime Function() _clock;
  Timer? _statusTimer;

  /// A monitored machine's companion reported (other) capabilities: the
  /// app pushes its companion settings there (herdr-sidebar, worktree
  /// location).
  void Function(SavedHost host, Set<String> capabilities)?
  onCompanionCapabilities;
  bool _appActive = true;
  bool _longPoll = true;
  bool _disposed = false;

  /// Longest run of skipped ticks after repeated failures (with the default
  /// interval: a poll every 75 s instead of every 15 s).
  static const _maxBackoffTicks = 4;

  static const _decisionTimeout = Duration(seconds: 15);

  @visibleForTesting
  static const hardwareKeyUnavailableReason =
      'Agent monitoring is off for hardware-key logins: each poll would '
      'open a new connection and ask for a key touch. Use a password or '
      'private key for this machine to monitor its agents.';

  /// The default provider (used for hosts that have not resolved theirs).
  AgentAttentionProvider get provider => _provider;

  /// The provider [hostId] resolved to, or the default before its first
  /// poll.
  AgentAttentionProvider providerFor(String hostId) =>
      _monitorFor(hostId)?.provider ?? _provider;

  /// Machines currently monitored, one each (its saved id, whichever of
  /// its sessions are open), in workspace order.
  List<SavedHost> get monitoredHosts {
    final seen = <String>{};
    return [
      for (final session in _workspace.sessions)
        if (_monitors[baseHostId(session.host.id)] case final monitor?
            when seen.add(monitor.host.id))
          monitor.host,
    ];
  }

  bool isMonitoring(String hostId) => _monitors.containsKey(baseHostId(hostId));

  /// The monitor of [hostId]'s machine: every session of a machine (a
  /// shell, each Herdr workspace or tmux session opened) shares one
  /// monitor, one poll loop and one set of agents (CON-079).
  _HostMonitor? _monitorFor(String hostId) => _monitors[baseHostId(hostId)];

  /// Connected SSH machines with agent monitoring off, one session each,
  /// so the Agents panel can offer to turn it on.
  List<SavedHost> get unmonitoredHosts {
    final seen = <String>{};
    return [
      for (final session in _workspace.sessions)
        if (!session.host.isLocal &&
            session.isConnected &&
            !monitoringEnabled(session.host) &&
            seen.add(baseHostId(session.host.id)))
          session.host,
    ];
  }

  /// Whether agent monitoring is on for [host] (its saved setting, or
  /// turned on through [enableMonitoring] since).
  bool monitoringEnabled(SavedHost host) =>
      host.agentAttentionEnabled ||
      _enabledHostIds.contains(baseHostId(host.id));

  /// Turns agent monitoring on for [host]'s machine: its open sessions
  /// start being monitored now, and the setting is saved.
  Future<void> enableMonitoring(SavedHost host) async {
    final savedId = baseHostId(host.id);
    if (_enabledHostIds.add(savedId)) {
      _syncMonitors();
    }
    await persistMonitoringEnabled?.call(savedId);
  }

  /// A runner for extra commands on [host] (the chat view): the monitor's
  /// own connection while [host] is monitored, which the caller must not
  /// close, else a new one the caller owns (`owned`) and closes.
  (AgentCommandRunner, {bool owned}) runnerFor(SavedHost host) {
    final monitor = _monitorFor(host.id);
    if (monitor != null) {
      return (monitor.runner, owned: false);
    }
    return (_runnerFactory(host), owned: true);
  }

  AgentHostStatus? statusFor(String hostId) => _monitorFor(hostId)?.status;

  /// Whether a decision for [requestId] is in flight.
  bool isDeciding(String requestId) => _deciding.contains(requestId);

  /// Whether [hostId] is currently on its long-poll.
  @visibleForTesting
  bool isWatching(String hostId) => _monitorFor(hostId)?.watching ?? false;

  /// Agents needing attention across every monitored host.
  int get attentionCount {
    var count = 0;
    for (final monitor in _monitors.values) {
      for (final agent in monitor.status.agents) {
        if (agent.state.needsAttention) {
          count += 1;
        }
      }
    }
    return count;
  }

  /// Pauses polling while the app is backgrounded and resumes (with an
  /// immediate refresh) when it returns. Known agent states are kept, so
  /// transitions that happened in the background still notify exactly once.
  void setAppActive(bool active) {
    if (_appActive == active || _disposed) {
      return;
    }
    _appActive = active;
    for (final monitor in _monitors.values) {
      if (active) {
        // Hosts marked unavailable stay stopped; a manual refresh or a
        // reconnect gives them another chance.
        if (monitor.status.unavailableReason == null) {
          _startTimer(monitor);
          unawaited(_poll(monitor));
        }
      } else {
        monitor.timer?.cancel();
        monitor.timer = null;
      }
    }
  }

  /// Turns the companion long-poll on or off; off leaves the periodic poll.
  /// The app keeps it on whenever monitoring is active, in the Android
  /// background too (CON-089): it is silent while nothing changes, about
  /// 65 execs an hour per machine against 240 for a 15 s poll, and it
  /// notifies sooner.
  void setLongPoll(bool enabled) {
    if (_longPoll == enabled || _disposed) {
      return;
    }
    _longPoll = enabled;
    if (!enabled) {
      // Loops notice on their next iteration; the in-flight long-poll
      // returns by itself within the provider's timeout.
      return;
    }
    for (final monitor in _monitors.values) {
      if (_shouldWatch(monitor)) {
        unawaited(_watchLoop(monitor));
      }
    }
  }

  /// The app is in the background: the fallback tick (status refresh, and
  /// a poll only while the long-poll is down) slows to
  /// [_backgroundTickInterval].
  void setInBackground(bool background) {
    if (_inBackground == background || _disposed) {
      return;
    }
    _inBackground = background;
    for (final monitor in _monitors.values) {
      if (monitor.timer != null) _startTimer(monitor);
    }
  }

  bool _inBackground = false;

  static const _backgroundTickInterval = Duration(seconds: 60);

  /// The fallback tick's interval now.
  @visibleForTesting
  Duration get tickInterval =>
      !_inBackground || _pollInterval > _backgroundTickInterval
      ? _pollInterval
      : _backgroundTickInterval;

  Future<void> refresh(String hostId) async {
    final monitor = _monitorFor(hostId);
    if (monitor == null || !monitor.pollable) {
      return;
    }
    // A manual refresh gives an unavailable provider another chance and
    // skips any failure backoff.
    monitor.consecutiveFailures = 0;
    monitor.skipTicks = 0;
    if (monitor.status.unavailableReason != null) {
      // The tooling may have been installed since: pick the provider again.
      monitor.provider = null;
      monitor.status = const AgentHostStatus(loading: true);
      if (_appActive) {
        _startTimer(monitor);
      }
    }
    await _poll(monitor);
  }

  /// Sends the provider's focus command for [agent], if there is one.
  Future<void> focusAgent(String hostId, AgentInfo agent) async {
    final monitor = _monitorFor(hostId);
    if (monitor == null) {
      return;
    }
    final command = (monitor.provider ?? _provider).focusCommand(agent);
    if (command == null) {
      return;
    }
    try {
      await monitor.runner.run(command, timeout: const Duration(seconds: 10));
    } catch (_) {
      // Focus is best-effort; the agent may have exited since the last poll.
    }
  }

  /// Answers [request] on [hostId] with [verdict]. Throws an [AppFailure]
  /// when the host is not monitored, its provider cannot decide, or the
  /// host rejected the decision; on success the request is dropped from
  /// the dashboard right away and the host is polled for the new state.
  Future<void> decide(
    String hostId,
    PendingPermissionRequest request,
    PermissionVerdict verdict,
  ) async {
    final monitor = _monitorFor(hostId);
    if (monitor == null) {
      throw const AppFailure('This machine is not being monitored.');
    }
    final provider = monitor.provider ?? await _resolveProvider(monitor);
    try {
      await _sendDecision(
        monitor.runner,
        provider,
        request,
        verdict,
        sessionId: _ownerOf(monitor, request.id),
      );
    } on _RequestGone {
      // Answered elsewhere or timed out: the prompt is in the terminal now.
      if (!_disposed) {
        _removeRequest(monitor, request.id, stillWaiting: true);
        notifyListeners();
        unawaited(_poll(monitor));
      }
      rethrow;
    }
    if (_disposed) {
      return;
    }
    _removeRequest(monitor, request.id);
    notifyListeners();
    unawaited(_poll(monitor));
  }

  /// Completes a notification action tap: answers the request on [host]
  /// (through its monitor when connected, else over a one-off connection)
  /// and updates the agent's notification (the next item, or gone), or
  /// rewrites it to say the decision failed. An answer button answers its
  /// question through the same `decide`; a Reply is typed into the agent
  /// through the companion's `send`, like the Chat View. Never throws.
  ///
  /// Returns null once done, else why it failed. With [reportFailure]
  /// off (the launcher, which shows the reason itself) a failure leaves
  /// the notifications alone, and a request answered elsewhere fails with
  /// [LauncherPrompt.staleError].
  Future<String?> completePermissionAction(
    AgentPermissionAction action,
    SavedHost? host, {
    bool reportFailure = true,
  }) async {
    final notifier = _notifier;
    String? failure;
    final answering = action.verdict == AgentPermissionAction.answerVerdict;
    final replying = action.verdict == AgentPermissionAction.replyVerdict;
    final verdict = answering
        ? PermissionVerdict.allow
        : PermissionVerdict.values
              .where((value) => value.wireName == action.verdict)
              .firstOrNull;
    final hasAgent = action.agentId.isNotEmpty;
    final key = hasAgent
        ? agentNotificationKey(action.hostId, action.agentId)
        : action.notificationId;
    Future<void> failed(String reason) async {
      failure = reason;
      if (!reportFailure) {
        return;
      }
      final body = replying
          ? 'Open Conductore to send it'
                '${host == null ? '' : ' on ${host.name}'}. $reason'
          : 'Open Conductore to answer the request'
                '${host == null ? '' : ' on ${host.name}'}. $reason';
      final title = replying ? 'Reply not sent' : 'Permission decision failed';
      if (!hasAgent) {
        await notifier?.show(
          id: action.notificationId,
          title: 'Permission decision failed',
          body: body,
        );
        return;
      }
      // The agent's one notification says so (a later poll re-lists
      // whatever still waits).
      _sentNotifications.remove(action.hostId);
      await notifier?.showAgent(
        AgentNotification(
          hostId: action.hostId,
          agentId: action.agentId,
          need: AgentNeed.approval,
          title: title,
          text: body,
          lines: [body],
          publicTitle: 'Conductore: ${title.toLowerCase()}',
          alert: true,
          alertKey: 'failed:${action.requestId}',
          open: AgentOpenTarget(hostId: action.hostId, agentId: action.agentId),
        ),
      );
    }

    if (host == null) {
      await failed('The machine is no longer saved.');
      return failure;
    }
    if (replying) {
      await _completeReply(action, host, key, failed);
      return failure;
    }
    if (verdict == null || (answering && action.text.isEmpty)) {
      await failed('Unknown action.');
      return failure;
    }
    final question = answering ? _questionOf(host.id, action) : '';
    if (answering && question.isEmpty) {
      await failed('The question is no longer known.');
      return failure;
    }
    final asked = PendingPermissionRequest(
      id: action.requestId,
      toolName: answering ? PendingPermissionRequest.questionTool : '',
      summary: '',
    );
    final request = answering
        ? asked.withAnswers({question: action.text})
        : asked;
    final monitor = _monitorFor(host.id);
    try {
      if (monitor != null) {
        final provider = monitor.provider ?? await _resolveProvider(monitor);
        try {
          await _sendDecision(
            monitor.runner,
            provider,
            request,
            verdict,
            sessionId: _ownerOf(monitor, action.requestId),
          );
        } on _RequestGone {
          _removeRequest(monitor, action.requestId, stillWaiting: true);
          unawaited(_poll(monitor));
          rethrow;
        }
        _removeRequest(monitor, action.requestId);
        unawaited(_poll(monitor));
      } else {
        final provider = _companionProvider;
        if (provider == null) {
          throw const AppFailure(
            'This build has no Conductore companion support.',
          );
        }
        final runner = _runnerFactory(host);
        try {
          await _sendDecision(runner, provider, request, verdict);
        } finally {
          unawaited(runner.close());
        }
      }
    } catch (error) {
      await failed(switch (error) {
        _RequestGone() when !reportFailure => LauncherPrompt.staleError,
        AppFailure(:final message) when !reportFailure => message,
        _ => error.toString(),
      });
      return failure;
    } finally {
      if (!_disposed) {
        notifyListeners();
      }
    }
    if (monitor != null) {
      // [_removeRequest] re-posted the agent's notification with what is
      // left, or removed it.
      return null;
    }
    // Nothing watches the host: nothing is known to be left.
    _notices.remove(key);
    if (hasAgent) {
      await notifier?.cancelAgent(key: key);
    } else {
      await notifier?.cancel(id: action.notificationId);
    }
    return null;
  }

  /// What the launcher's details sheet may answer for each agent that
  /// needs the user, on every monitored host (CON-082).
  List<LauncherPrompt> get launcherPrompts => [
    for (final monitor in _monitors.values)
      for (final agent in monitor.status.agents)
        ?LauncherPrompt.of(
          hostId: monitor.host.id,
          agent: agent,
          canReply: _canReply(monitor, agent),
        ),
  ];

  /// Completes an answer from the launcher's details sheet (CON-082):
  /// [action] must still match what [LauncherPrompt.of] offers for its
  /// agent now (the same request, one of its options or its reply), else
  /// it fails with [LauncherPrompt.staleError]. Then it goes the way a
  /// notification's button does ([completePermissionAction]), without
  /// touching the notifications on failure. Returns null once done, else
  /// why it failed. Never throws.
  Future<String?> completeLauncherAction(
    AgentPermissionAction action,
    SavedHost? host,
  ) async {
    final monitor = host == null ? null : _monitorFor(host.id);
    if (host == null || monitor == null) {
      return 'Conductore is not monitoring that machine';
    }
    final agent = monitor.status.agents
        .where((agent) => agent.id == action.agentId)
        .firstOrNull;
    final prompt = agent == null
        ? null
        : LauncherPrompt.of(
            hostId: monitor.host.id,
            agent: agent,
            canReply: _canReply(monitor, agent),
          );
    if (prompt == null || prompt.requestId != action.requestId) {
      return LauncherPrompt.staleError;
    }
    final offered =
        prompt.options?.any(
          (option) =>
              option.verdict == action.verdict &&
              (action.verdict != AgentPermissionAction.answerVerdict ||
                  option.label == action.text),
        ) ??
        false;
    final replying = prompt.replyVerdict == action.verdict;
    if (!offered && !replying) {
      return prompt.note ?? LauncherPrompt.staleError;
    }
    if (replying && action.text.trim().isEmpty) {
      return 'Nothing to send';
    }
    return completePermissionAction(
      AgentPermissionAction(
        notificationId: agentNotificationKey(host.id, action.agentId),
        hostId: host.id,
        agentId: action.agentId,
        requestId: action.requestId,
        verdict: action.verdict,
        text: action.text,
        question: action.verdict == AgentPermissionAction.answerVerdict
            ? prompt.answers
            : '',
      ),
      host,
      reportFailure: false,
    );
  }

  /// The question an answer button answers: as the notification carried
  /// it, else the one the monitor still lists for the request.
  String _questionOf(String hostId, AgentPermissionAction action) {
    if (action.question.isNotEmpty) {
      return action.question;
    }
    for (final agent
        in _monitorFor(hostId)?.status.agents ?? const <AgentInfo>[]) {
      for (final request in agent.pendingRequests) {
        if (request.id == action.requestId && request.questions.length == 1) {
          return request.questions.single.question;
        }
      }
    }
    return '';
  }

  /// Types a notification's Reply into its agent through the companion's
  /// `send` (the monitor's connection, else a one-off one). Sent, the
  /// alert goes: the user answered it. The agent's next state notifies as
  /// usual.
  Future<void> _completeReply(
    AgentPermissionAction action,
    SavedHost host,
    String key,
    Future<void> Function(String reason) failed,
  ) async {
    final text = action.text.trim();
    if (text.isEmpty || action.agentId.isEmpty) {
      await failed('Nothing to send.');
      return;
    }
    final monitor = _monitorFor(host.id);
    final runner = monitor?.runner ?? _runnerFactory(host);
    try {
      await ConductoreChatClient(runner).send(action.agentId, text);
    } catch (error) {
      await failed(error.toString());
      return;
    } finally {
      if (monitor == null) unawaited(runner.close());
    }
    // The need stays known (its notice), so the same state never alerts
    // again; Android does not bring back a silent update it no longer
    // shows.
    await _notifier?.cancelAgent(key: key);
    if (monitor != null) unawaited(_poll(monitor));
  }

  /// Settings › Agents › Notifications.
  AgentNotificationPreferences get notificationPreferences =>
      _notificationPreferences;

  /// Saves [preferences] and re-posts every agent's notification with them
  /// (turning an event off removes its notifications).
  Future<void> setNotificationPreferences(
    AgentNotificationPreferences preferences,
  ) async {
    if (preferences == _notificationPreferences) {
      return;
    }
    final modeChanged = preferences.mode != _notificationPreferences.mode;
    _notificationPreferences = preferences;
    notifyListeners();
    if (modeChanged) {
      // Another mode posts other notifications; what was notified stays
      // known, so the same need does not alert again.
      _sentNotifications.clear();
    }
    await resyncNotifications();
    await _notificationStore.save(preferences);
  }

  /// Whether [agentId] on [hostId] is muted on this device.
  bool isAgentMuted(String hostId, String agentId) =>
      _notificationPreferences.isMuted(hostId, agentId);

  /// Mutes (or unmutes) one agent's notifications on this device: its
  /// alerts go now and never come back while muted. The ongoing status
  /// still lists it.
  Future<void> setAgentMuted(
    String hostId,
    String agentId, {
    required bool muted,
  }) => setNotificationPreferences(
    _notificationPreferences.withMuted(hostId, agentId, muted: muted),
  );

  /// Brings every agent notification and the ongoing status in line with
  /// what is known now (no state counts as newly entered).
  Future<void> resyncNotifications() async {
    for (final monitor in _monitors.values.toList()) {
      // Before its first snapshot a host has nothing to say yet (and an
      // empty list would clear what an earlier run left showing).
      if (monitor.sawInitialSnapshot) {
        await _syncNotifications(monitor, entered: const {});
      }
    }
    _syncStatus();
  }

  Future<void> _loadNotificationPreferences() async {
    final loaded = await _notificationStore.load();
    if (_disposed || loaded == _notificationPreferences) {
      return;
    }
    _notificationPreferences = loaded;
    notifyListeners();
    await resyncNotifications();
  }

  // --- smart approvals ------------------------------------------------------
  //
  // Risk labels, approval rules, time-boxed trust, "approve all safe" and
  // the auto-approved log, on hosts whose companion reports the
  // `smart-approvals` capability. The voice guide uses the same calls:
  // [approveRequest], [approveAllLowRisk] and [trustRequest].

  /// Whether [hostId]'s companion keeps approval rules and rates requests.
  bool supportsSmartApprovals(String hostId) {
    final monitor = _monitorFor(hostId);
    return monitor != null &&
        monitor.provider is SmartApprovalsProvider &&
        (monitor.capabilities?.contains(smartApprovalsCapability) ?? false);
  }

  /// Whether [hostId]'s companion snapshots each agent turn (Review mode
  /// and "Undo this turn"; capability `snapshots`).
  bool supportsSnapshots(String hostId) =>
      _monitorFor(hostId)?.capabilities?.contains(snapshotsCapability) ?? false;

  /// Whether [hostId]'s companion reported [capability] (`status`).
  bool companionSupports(String hostId, String capability) =>
      _monitorFor(hostId)?.capabilities?.contains(capability) ?? false;

  /// What [hostId]'s companion reported it supports; null while unknown
  /// (no monitor, or no report yet).
  Set<String>? companionCapabilities(String hostId) =>
      _monitorFor(hostId)?.capabilities;

  /// What each agent kind on [hostId] supports: the companion's report,
  /// else what companions before agent adapters implied (Claude Code only).
  AgentKindCatalog agentKinds(String hostId) =>
      _monitorFor(hostId)?.kinds ?? AgentKindCatalog.legacy;

  /// Every waiting request on the monitored hosts, oldest first.
  List<PendingApproval> get pendingApprovals {
    final all = <PendingApproval>[
      for (final monitor in _monitors.values)
        for (final agent in monitor.status.agents)
          for (final request in agent.pendingRequests)
            (
              hostId: monitor.host.id,
              hostName: monitor.host.name,
              agent: agent,
              request: request,
            ),
    ];
    all.sort((a, b) {
      final at = a.request.createdAt;
      final bt = b.request.createdAt;
      if (at == null || bt == null) {
        return at == null ? (bt == null ? 0 : 1) : -1;
      }
      return at.compareTo(bt);
    });
    return all;
  }

  /// The waiting requests "Approve all safe" would take: rated low by a
  /// companion that can answer them in a batch.
  List<PendingApproval> get lowRiskPending => [
    for (final pending in pendingApprovals)
      if (pending.request.batchable && supportsSmartApprovals(pending.hostId))
        pending,
  ];

  /// The rules and auto-approved log last loaded for [hostId].
  ApprovalsSnapshot? approvalsFor(String hostId) => _approvals[hostId];

  /// Whether [loadApprovals] runs for [hostId].
  bool isLoadingApprovals(String hostId) => _loadingApprovals.contains(hostId);

  /// Answers one request with "allow" (voice: "approve this").
  Future<void> approveRequest(
    String hostId,
    PendingPermissionRequest request,
  ) => decide(hostId, request, PermissionVerdict.allow);

  /// Allows every waiting low-risk request, on [hostId] or on every host
  /// (voice: "approve all safe"). With [only], just those (the list the
  /// user confirmed); the companion re-checks each and skips anything not
  /// rated low. Hosts without smart approvals are left alone.
  Future<BatchApprovalResult> approveAllLowRisk({
    String? hostId,
    List<PendingApproval>? only,
  }) async {
    final chosen = only ?? lowRiskPending;
    // One batch per host; per agent where the companion checks that each
    // request is that agent's ([requestOwnerCapability]).
    final batches = <(String, String?), List<String>>{};
    for (final pending in chosen) {
      if (hostId != null && pending.hostId != hostId) {
        continue;
      }
      final owner = companionSupports(pending.hostId, requestOwnerCapability)
          ? pending.agent.id
          : null;
      batches
          .putIfAbsent((pending.hostId, owner), () => [])
          .add(pending.request.id);
    }
    var result = const BatchApprovalResult();
    Object? firstError;
    for (final MapEntry(key: (host, owner), value: ids) in batches.entries) {
      final monitor = _monitorFor(host);
      if (monitor == null) {
        continue;
      }
      final provider = _smartOf(monitor.provider);
      if (provider == null) {
        continue;
      }
      for (final id in ids) {
        _deciding.add(id);
      }
      notifyListeners();
      try {
        final stdout = await _runChecked(
          monitor.runner,
          provider.approveLowCommand(ids, sessionId: owner),
        );
        final batch = provider.parseBatch(stdout);
        result = result.merge(batch);
        for (final id in batch.approved) {
          _removeRequest(monitor, id);
        }
      } catch (error) {
        firstError ??= error;
      } finally {
        for (final id in ids) {
          _deciding.remove(id);
        }
      }
      if (!_disposed) {
        notifyListeners();
        unawaited(_poll(monitor));
      }
    }
    if (firstError != null && result.approved.isEmpty) {
      throw firstError;
    }
    return result;
  }

  /// Saves a rule from [request] and allows it (voice: "trust this for N
  /// minutes"). Without [rule], the companion saves one for exactly this
  /// call (never broader than what was asked); the scope's repo is the
  /// request's. Also allows other waiting requests
  /// the rule covers. High-risk requests are refused by the companion.
  Future<TrustResult> trustRequest(
    String hostId,
    PendingPermissionRequest request, {
    TrustDuration duration = const TrustDuration.minutes(60),
    ApprovalScopeKind scope = ApprovalScopeKind.repo,
    String? rule,
    String source = 'trust',
  }) async {
    final monitor = _monitorFor(hostId);
    final provider = _smartOf(monitor?.provider);
    if (monitor == null || provider == null) {
      throw const AppFailure(
        'Trust needs the Conductore companion with approval rules on this '
        'machine.',
      );
    }
    final draft = ApprovalRuleDraft(
      rule: rule ?? '',
      // The companion fills in the request's repo (else the agent's cwd)
      // and session.
      scope: scope == ApprovalScopeKind.repo && request.repo != null
          ? ApprovalScope.repo(request.repo!)
          : ApprovalScope.ofKind(scope),
      duration: duration,
    );
    if (!_deciding.add(request.id)) {
      throw const AppFailure('This request is already being answered.');
    }
    notifyListeners();
    final TrustResult result;
    try {
      final stdout = await _runChecked(
        monitor.runner,
        provider.trustCommand(
          request,
          draft,
          source: source,
          sessionId: _ownerOf(monitor, request.id),
        ),
      );
      result = provider.parseTrust(stdout);
    } on _RequestGone {
      if (!_disposed) {
        _removeRequest(monitor, request.id, stillWaiting: true);
        unawaited(_poll(monitor));
      }
      rethrow;
    } finally {
      _deciding.remove(request.id);
      if (!_disposed) {
        notifyListeners();
      }
    }
    if (_disposed) {
      return result;
    }
    for (final id in result.approved) {
      _removeRequest(monitor, id);
    }
    notifyListeners();
    unawaited(_poll(monitor));
    unawaited(loadApprovals(monitor.host).catchError((_) => null));
    return result;
  }

  /// Loads [host]'s rules and auto-approved log (over the monitor's
  /// connection, else a one-off one). Returns null when the machine has no
  /// companion that keeps rules; throws an [AppFailure] when it failed.
  Future<ApprovalsSnapshot?> loadApprovals(SavedHost host) async {
    final provider = _smartProvider(host);
    if (provider == null) {
      return null;
    }
    if (!_loadingApprovals.add(host.id)) {
      return _approvals[host.id];
    }
    notifyListeners();
    try {
      final stdout = await _withRunner(
        host,
        (runner) => _runChecked(runner, provider.approvalsCommand()),
      );
      final snapshot = provider.parseApprovals(stdout);
      if (!_disposed) {
        _approvals[host.id] = snapshot;
      }
      return snapshot;
    } finally {
      _loadingApprovals.remove(host.id);
      if (!_disposed) {
        notifyListeners();
      }
    }
  }

  /// Saves a rule on [host] (Settings › Agents › Approval rules). Waiting
  /// requests it covers are answered by the companion.
  Future<TrustResult> addRule(SavedHost host, ApprovalRuleDraft draft) =>
      _ruleChange(host, (provider) => provider.addRuleCommand(draft));

  /// Changes a rule's pattern, scope or duration on [host].
  Future<TrustResult> editRule(
    SavedHost host,
    String ruleId,
    ApprovalRuleDraft draft,
  ) => _ruleChange(host, (provider) => provider.editRuleCommand(ruleId, draft));

  /// Revokes a rule or trust on [host] (also the audit list's "Undo").
  Future<void> removeRule(SavedHost host, String ruleId) async {
    final provider = _requireSmart(host);
    await _withRunner(
      host,
      (runner) => _runChecked(runner, provider.removeRuleCommand(ruleId)),
    );
    final cached = _approvals[host.id];
    if (cached != null && !_disposed) {
      _approvals[host.id] = cached.copyWith(
        rules: [
          for (final rule in cached.rules)
            if (rule.id != ruleId) rule,
        ],
      );
      notifyListeners();
    }
    unawaited(loadApprovals(host).catchError((_) => null));
  }

  Future<TrustResult> _ruleChange(
    SavedHost host,
    String Function(SmartApprovalsProvider provider) command,
  ) async {
    final provider = _requireSmart(host);
    final stdout = await _withRunner(
      host,
      (runner) => _runChecked(runner, command(provider)),
    );
    final result = provider.parseRuleReply(stdout);
    final monitor = _monitorFor(host.id);
    if (monitor != null && !_disposed) {
      for (final id in result.approved) {
        _removeRequest(monitor, id);
      }
      unawaited(_poll(monitor));
    }
    unawaited(loadApprovals(host).catchError((_) => null));
    return result;
  }

  static SmartApprovalsProvider? _smartOf(AgentAttentionProvider? provider) =>
      switch (provider) {
        final SmartApprovalsProvider smart => smart,
        _ => null,
      };

  /// The monitor's provider when it resolved one (a Herdr host has none),
  /// else the companion.
  SmartApprovalsProvider? _smartProvider(SavedHost host) {
    final resolved = _monitorFor(host.id)?.provider;
    return _smartOf(resolved ?? _companionProvider);
  }

  SmartApprovalsProvider _requireSmart(SavedHost host) {
    final provider = _smartProvider(host);
    if (provider == null) {
      throw const AppFailure(
        'Approval rules need the Conductore companion on this machine.',
      );
    }
    return provider;
  }

  Future<T> _withRunner<T>(
    SavedHost host,
    Future<T> Function(AgentCommandRunner runner) body,
  ) async {
    final (runner, :owned) = runnerFor(host);
    try {
      return await body(runner);
    } finally {
      if (owned) {
        unawaited(runner.close());
      }
    }
  }

  /// Runs a companion command; its stdout, or an [AppFailure] (a
  /// [_RequestGone] for requests answered elsewhere).
  Future<String> _runChecked(AgentCommandRunner runner, String command) async {
    final result = await runner.run(command, timeout: _decisionTimeout);
    if (result.exitCode == 127) {
      throw const AppFailure(
        'The Conductore companion is not installed on this machine.',
      );
    }
    if (result.exitCode != null && result.exitCode != 0) {
      final reason = _errorText(
        result.stdout.trim().isNotEmpty ? result.stdout : result.stderr,
      );
      if (reason.startsWith('unknown request') ||
          reason.startsWith('request expired')) {
        throw _RequestGone(reason);
      }
      if (reason.startsWith('unknown command')) {
        throw AppFailure(
          'Update the Conductore companion on this machine to use '
          'approval rules.',
          reason,
        );
      }
      throw AppFailure('The companion refused.', reason);
    }
    return result.stdout;
  }

  /// The agent [requestId] is pending for, when [monitor]'s companion
  /// checks ownership ([requestOwnerCapability]); else null (older
  /// companions get the command they know).
  String? _ownerOf(_HostMonitor monitor, String requestId) {
    if (!(monitor.capabilities?.contains(requestOwnerCapability) ?? false)) {
      return null;
    }
    for (final agent in monitor.status.agents) {
      if (agent.pendingRequests.any((r) => r.id == requestId)) return agent.id;
    }
    return null;
  }

  Future<void> _sendDecision(
    AgentCommandRunner runner,
    AgentAttentionProvider provider,
    PendingPermissionRequest request,
    PermissionVerdict verdict, {
    String? sessionId,
  }) async {
    final command = provider.decideCommand(
      request,
      verdict,
      sessionId: sessionId,
    );
    if (command == null && request.isQuestion) {
      throw AppFailure(
        request.answerable
            ? 'Pick an answer to the question.'
            : 'Update the Conductore companion on this machine to answer '
                  'questions from the phone, or answer it in the terminal.',
      );
    }
    if (command == null) {
      throw AppFailure(
        '${provider.label} cannot answer permission requests from the phone.',
      );
    }
    if (!_deciding.add(request.id)) {
      throw const AppFailure('This request is already being answered.');
    }
    notifyListeners();
    try {
      final result = await runner.run(command, timeout: _decisionTimeout);
      if (result.exitCode != null && result.exitCode != 0) {
        final reason = _errorText(
          result.stdout.trim().isNotEmpty ? result.stdout : result.stderr,
        );
        if (reason.startsWith('unknown request') ||
            reason.startsWith('request expired')) {
          throw _RequestGone(reason);
        }
        throw AppFailure('The decision was not accepted.', reason);
      }
    } finally {
      _deciding.remove(request.id);
    }
  }

  /// The `error` of a `{"error": "..."}` reply, else the first line.
  static String _errorText(String text) {
    final trimmed = text.trim();
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map && decoded['error'] is String) {
        return decoded['error'] as String;
      }
    } catch (_) {
      // Not JSON.
    }
    final line = trimmed.split('\n').first;
    return line.length > 200 ? line.substring(0, 200) : line;
  }

  /// Drops [requestId] from the host's dashboard state and updates its
  /// agent's notification (the host confirmed the decision; the next poll
  /// agrees).
  /// With [stillWaiting] the request is gone but the agent still waits for
  /// an answer in the terminal, so it stays "needs input".
  void _removeRequest(
    _HostMonitor monitor,
    String requestId, {
    bool stillWaiting = false,
  }) {
    final agents = [
      for (final agent in monitor.status.agents)
        if (agent.pendingRequests.any((request) => request.id == requestId))
          agent.copyWith(
            state: agent.pendingRequests.length > 1 || stillWaiting
                ? agent.state
                : AgentAttentionState.working,
            pendingRequests: [
              for (final request in agent.pendingRequests)
                if (request.id != requestId) request,
            ],
          )
        else
          agent,
    ];
    monitor.status = AgentHostStatus(
      agents: agents,
      updatedAt: monitor.status.updatedAt,
    );
    unawaited(_syncNotifications(monitor, entered: const {}));
    _syncStatus();
  }

  void _syncMonitors() {
    if (_disposed) {
      return;
    }
    // One monitor per machine: its sessions (a shell, each Herdr
    // workspace or tmux session opened) all show the same agents.
    final wanted = <String, List<TerminalSessionController>>{};
    for (final session in _workspace.sessions) {
      if (monitoringEnabled(session.host) &&
          !session.host.isLocal &&
          session.isConnected) {
        (wanted[baseHostId(session.host.id)] ??= []).add(session);
      }
    }

    for (final machineId in _monitors.keys.toList()) {
      if (!wanted.containsKey(machineId)) {
        _stopMonitor(machineId);
      }
    }
    for (final MapEntry(key: machineId, value: sessions) in wanted.entries) {
      final monitor = _monitors[machineId];
      if (monitor == null) {
        _startMonitor(machineId, sessions.first);
      } else if (!sessions.contains(monitor.session)) {
        // Its session closed while another of the machine is open: the
        // monitor follows that one and keeps what it knows.
        monitor.session.removeListener(_syncMonitors);
        monitor.session = sessions.first;
        monitor.session.addListener(_syncMonitors);
      }
    }
    // Sessions notify for much that changes nothing here (a title, a
    // rename): only a change in the hosts listed is worth a rebuild.
    final hosts = [...monitoredHosts, null, ...unmonitoredHosts];
    if (listEquals(hosts, _listedHosts)) {
      return;
    }
    _listedHosts = hosts;
    notifyListeners();
  }

  /// [monitoredHosts] and [unmonitoredHosts] as last notified.
  List<SavedHost?>? _listedHosts;

  void _startMonitor(String machineId, TerminalSessionController session) {
    final host = _machineHost(machineId, session.host);
    final monitor = _HostMonitor(
      host: host,
      session: session,
      runner: _runnerFactory(host),
    );
    _monitors[machineId] = monitor;
    // React to this session disconnecting even when the workspace itself
    // does not notify.
    session.addListener(_syncMonitors);
    if (session.host.authMethod == SshAuthMethod.hardwareKey) {
      monitor.pollable = false;
      monitor.status = AgentHostStatus(
        unavailableReason: hardwareKeyUnavailableReason,
        updatedAt: DateTime.now(),
      );
      return;
    }
    if (_appActive) {
      _startTimer(monitor);
      unawaited(_poll(monitor));
    }
  }

  /// The machine a session runs on, under its saved id and name: a Herdr
  /// workspace's session is "dev: lf-seguros-web" under `dev#herdr:w8`.
  SavedHost _machineHost(String machineId, SavedHost sessionHost) {
    if (sessionHost.id == machineId) return sessionHost;
    final target = ConnectTarget.fromSessionHostId(sessionHost.id);
    final suffix = target == null ? null : ': ${target.title}';
    final name =
        machineName?.call(machineId) ??
        (suffix != null && sessionHost.name.endsWith(suffix)
            ? sessionHost.name.substring(
                0,
                sessionHost.name.length - suffix.length,
              )
            : sessionHost.name);
    return sessionHost.copyWith(id: machineId, name: name);
  }

  void _stopMonitor(String hostId) {
    final monitor = _monitors.remove(hostId);
    if (monitor == null) {
      return;
    }
    monitor.session.removeListener(_syncMonitors);
    monitor.timer?.cancel();
    monitor.timer = null;
    unawaited(monitor.runner.close());
    _syncStatus();
  }

  void _startTimer(_HostMonitor monitor) {
    monitor.timer?.cancel();
    monitor.timer = Timer.periodic(tickInterval, (_) => _onTick(monitor));
  }

  void _onTick(_HostMonitor monitor) {
    // Refreshes an unchanged status now and then (the platform drops one
    // nobody refreshed), even while the long-poll has nothing new.
    _syncStatus();
    if (monitor.skipTicks > 0) {
      monitor.skipTicks -= 1;
      return;
    }
    if (monitor.watching && _longPoll) {
      // The long-poll delivers changes as they happen; the periodic poll is
      // only the fallback while it is not running.
      return;
    }
    unawaited(_poll(monitor));
  }

  /// Polls [hostId] immediately, ignoring any failure backoff.
  @visibleForTesting
  Future<void> pollNow(String hostId) async {
    final monitor = _monitorFor(hostId);
    if (monitor != null) {
      await _poll(monitor);
    }
  }

  /// Simulates one periodic tick for [hostId], honoring the failure backoff.
  @visibleForTesting
  Future<void> tickNow(String hostId) async {
    final monitor = _monitorFor(hostId);
    if (monitor == null) {
      return;
    }
    if (monitor.skipTicks > 0) {
      monitor.skipTicks -= 1;
      return;
    }
    await _poll(monitor);
  }

  /// Picks the provider for [monitor] from the host setting, probing the
  /// companion when the setting is automatic. Cached for the life of the
  /// connection.
  Future<AgentAttentionProvider> _resolveProvider(_HostMonitor monitor) async {
    final cached = monitor.provider;
    if (cached != null) {
      return cached;
    }
    final companion = _companionProvider;
    final resolved = switch (monitor.host.agentMonitor) {
      AgentMonitorKind.herdr => _provider,
      AgentMonitorKind.companion => companion ?? _provider,
      AgentMonitorKind.auto =>
        companion != null && await companion.isAvailable(monitor.runner)
            ? companion
            : _provider,
    };
    // Another resolution may have finished while probing.
    return monitor.provider ??= resolved;
  }

  Future<void> _poll(_HostMonitor monitor) async {
    if (_disposed ||
        monitor.fetching ||
        !monitor.pollable ||
        !_monitors.containsKey(monitor.host.id)) {
      return;
    }
    if (!monitor.session.isConnected) {
      _syncMonitors();
      return;
    }
    monitor.fetching = true;
    final watchGeneration = monitor.watchGeneration;
    final before = _MonitorView.of(monitor);
    try {
      final provider = await _resolveProvider(monitor);
      final snapshot = await provider.fetchAgents(monitor.runner);
      if (_disposed || !_monitors.containsKey(monitor.host.id)) {
        return;
      }
      final sequence = snapshot.sequence;
      final lastSequence = monitor.lastSequence;
      final overtaken =
          monitor.watchGeneration != watchGeneration &&
          sequence != null &&
          lastSequence != null &&
          sequence < lastSequence;
      // A status is authoritative (the host's counter may even have gone
      // back after a reset), unless a long-poll delivered newer changes
      // while it was in flight.
      if (!overtaken) {
        await _applySnapshot(monitor, snapshot);
      }
      monitor.consecutiveFailures = 0;
      monitor.skipTicks = 0;
      if (_shouldWatch(monitor)) {
        unawaited(_watchLoop(monitor));
      }
    } on AgentProviderUnavailable catch (unavailable) {
      monitor.status = AgentHostStatus(
        unavailableReason: unavailable.message,
        updatedAt: DateTime.now(),
      );
      // No point polling a machine without the tooling; a manual refresh or
      // reconnect starts over.
      monitor.timer?.cancel();
      monitor.timer = null;
    } catch (error) {
      monitor.status = AgentHostStatus(
        agents: monitor.status.agents,
        error: error.toString(),
        updatedAt: DateTime.now(),
      );
      // Each failure typically means a reconnect attempt on the next poll;
      // stretch the interval so a flaky link is not hammered.
      monitor.consecutiveFailures += 1;
      monitor.skipTicks = monitor.consecutiveFailures.clamp(
        0,
        _maxBackoffTicks,
      );
    } finally {
      monitor.fetching = false;
      // A poll that found what was already shown (the usual 15 s tick)
      // rebuilds nothing: the dashboard, home and widget listen here.
      if (!_disposed && _MonitorView.of(monitor) != before) {
        notifyListeners();
      }
    }
  }

  bool _shouldWatch(_HostMonitor monitor) {
    return !_disposed &&
        _appActive &&
        _longPoll &&
        !monitor.watching &&
        monitor.pollable &&
        monitor.status.unavailableReason == null &&
        monitor.status.error == null &&
        (monitor.provider?.supportsWatch ?? false) &&
        _monitors.containsKey(monitor.host.id) &&
        monitor.session.isConnected;
  }

  /// Long-polls the host for changes until the long-poll is turned off,
  /// the host disconnects, or a poll fails (the periodic poll then takes
  /// over with its backoff, and its next success restarts the loop).
  Future<void> _watchLoop(_HostMonitor monitor) async {
    if (monitor.watching) {
      return;
    }
    monitor.watching = true;
    try {
      while (true) {
        final provider = monitor.provider;
        if (_disposed ||
            !_appActive ||
            !_longPoll ||
            provider == null ||
            !provider.supportsWatch ||
            !_monitors.containsKey(monitor.host.id) ||
            !monitor.session.isConnected) {
          return;
        }
        try {
          final batch = await provider.watchAgents(
            monitor.runner,
            since: monitor.lastSequence,
          );
          if (_disposed || !_monitors.containsKey(monitor.host.id)) {
            return;
          }
          if (batch != null && await _applyBatch(monitor, batch)) {
            monitor.consecutiveFailures = 0;
            monitor.skipTicks = 0;
            notifyListeners();
          }
        } on AgentProviderUnavailable catch (unavailable) {
          monitor.status = AgentHostStatus(
            unavailableReason: unavailable.message,
            updatedAt: DateTime.now(),
          );
          monitor.timer?.cancel();
          monitor.timer = null;
          notifyListeners();
          return;
        } catch (error) {
          if (_disposed || !_monitors.containsKey(monitor.host.id)) {
            return;
          }
          monitor.status = AgentHostStatus(
            agents: monitor.status.agents,
            error: error.toString(),
            updatedAt: DateTime.now(),
          );
          monitor.consecutiveFailures += 1;
          monitor.skipTicks = monitor.consecutiveFailures.clamp(
            0,
            _maxBackoffTicks,
          );
          notifyListeners();
          return;
        }
        if (_watchRestartDelay > Duration.zero) {
          await Future<void>.delayed(_watchRestartDelay);
        }
      }
    } finally {
      monitor.watching = false;
    }
  }

  /// Applies a long-poll result on top of the host's current agents:
  /// a snapshot replaces them, then every change newer than the last
  /// applied sequence replaces (or removes) its agent. Returns whether
  /// anything was applied.
  Future<bool> _applyBatch(_HostMonitor monitor, AgentChangeBatch batch) async {
    var sequence = monitor.lastSequence;
    final byId = <String, AgentInfo>{};
    var changed = false;
    final snapshot = batch.snapshot;
    if (snapshot != null) {
      // The host could not serve our cursor: this is the whole truth.
      for (final agent in snapshot.agents) {
        byId[agent.id] = agent;
      }
      sequence = snapshot.sequence;
      changed = true;
    } else {
      for (final agent in monitor.status.agents) {
        byId[agent.id] = agent;
      }
    }
    for (final change in batch.changes) {
      if (sequence != null && change.sequence <= sequence) {
        // Already covered by a status poll that overtook this long-poll.
        continue;
      }
      final agent = change.agent;
      if (agent == null) {
        byId.remove(change.agentId);
      } else {
        byId[change.agentId] = agent;
      }
      sequence = change.sequence;
      changed = true;
    }
    if (!changed) {
      return false;
    }
    monitor.watchGeneration += 1;
    final agents = byId.values.toList()
      ..sort((a, b) {
        // Newest first, like `status`.
        final at = a.stateChangedAt;
        final bt = b.stateChangedAt;
        if (at == null || bt == null) {
          return at == null ? (bt == null ? 0 : 1) : -1;
        }
        return bt.compareTo(at);
      });
    await _applySnapshot(
      monitor,
      AgentAttentionSnapshot(agents: agents, sequence: sequence),
    );
    return true;
  }

  Future<void> _applySnapshot(
    _HostMonitor monitor,
    AgentAttentionSnapshot snapshot,
  ) async {
    monitor.lastSequence = snapshot.sequence ?? monitor.lastSequence;
    final previousStates = monitor.lastStates;
    final notify = monitor.sawInitialSnapshot;
    // Commit the new states before notifying so a throwing notifier can
    // never cause the same transition to notify twice on the next poll.
    monitor.lastStates = {
      for (final agent in snapshot.agents)
        agent.id: (
          state: agent.state,
          sequence: agent.stateSequence,
          hadPending: agent.pendingRequests.isNotEmpty,
        ),
    };
    monitor.sawInitialSnapshot = true;
    monitor.status = AgentHostStatus(
      agents: snapshot.agents,
      updatedAt: DateTime.now(),
    );
    if (snapshot.capabilities case final capabilities?) {
      final changed = !setEquals(monitor.capabilities, capabilities);
      monitor.capabilities = capabilities;
      if (changed) onCompanionCapabilities?.call(monitor.host, capabilities);
    }
    // Only full `status` replies carry it; a resync keeps the last one.
    if (snapshot.kinds case final kinds?) monitor.kinds = kinds;
    _noticeAutoApprovals(monitor, snapshot.agents);
    await _syncNotifications(
      monitor,
      previousStates: previousStates,
      initial: !notify,
      entered: {
        if (notify)
          for (final agent in snapshot.agents)
            if (previousStates[agent.id] == null ||
                _isTransition(previousStates[agent.id]!, agent))
              agent.id,
      },
    );
    _syncStatus();
  }

  /// Brings the host's agent notifications in line with its agents: one
  /// per agent that needs something ([AgentNotificationPolicy]), none for
  /// the rest. [entered] lists the agents whose state is new since
  /// [previousStates] (the last snapshot; the current marks when only a
  /// local change is applied).
  Future<void> _syncNotifications(
    _HostMonitor monitor, {
    required Set<String> entered,
    Map<String, _AgentMark>? previousStates,
    bool initial = false,
  }) async {
    final notifier = _notifier;
    if (notifier == null || _disposed) {
      return;
    }
    final host = monitor.host;
    final preferences = _notificationPreferences;
    final urgent = preferences.mode.urgentOnlyAlerts;
    final previous = previousStates ?? monitor.lastStates;
    final companion = monitor.provider?.id == companionProviderId;
    final notifications = <AgentNotification>[];
    final keys = <String>{};
    for (final agent in monitor.status.agents) {
      final key = agentNotificationKey(host.id, agent.id);
      keys.add(key);
      final notice = _notices[key];
      final isEntered = entered.contains(agent.id);
      // The companion reports a session that ended as finished; a
      // Herdr-only agent's finished is a turn that ended.
      final ended =
          companion &&
          agent.state == AgentAttentionState.finished &&
          !isHerdrOnlyAgent(agent);
      final stuck = urgent ? stuckReasonFor?.call(host.id, agent.id) : null;
      final need = preferences.isMuted(host.id, agent.id)
          ? null
          : urgent
          ? UrgentNotificationPolicy.needFor(
              agent: agent,
              previous: notice,
              entered: isEntered,
              previousState: previous[agent.id]?.state,
              ended: ended,
              companion: companion && !isHerdrOnlyAgent(agent),
              initial: initial,
              level: host.agentNotifyLevel,
              preferences: preferences,
              stuckReason: stuck,
            )
          : AgentNotificationPolicy.needFor(
              agent: agent,
              previous: notice,
              entered: isEntered,
              previousState: previous[agent.id]?.state,
              ended: ended,
              initial: initial,
              level: host.agentNotifyLevel,
              preferences: preferences,
            );
      if (need == null) {
        _notices.remove(key);
        continue;
      }
      final requestIds = need == AgentNeed.approval
          ? {for (final request in agent.pendingRequests) request.id}
          : const <String>{};
      final alert =
          (urgent
          ? UrgentNotificationPolicy.shouldAlert
          : AgentNotificationPolicy.shouldAlert)(
            previous: notice,
            need: need,
            requestIds: requestIds,
            entered: isEntered,
            quietUpdates: preferences.quietUpdates,
            initial: initial,
          );
      _notices[key] = AgentNotice(need: need, requestIds: requestIds);
      final open = openTargetFor(host.id, agent);
      final detail = notificationDetail?.call(host.id, agent.id);
      notifications.add(
        urgent
            ? UrgentNotificationPolicy.build(
                hostId: host.id,
                hostName: host.name,
                agent: agent,
                need: need,
                alert: alert,
                preferences: preferences,
                open: open,
                canReply: _canReply(monitor, agent),
                detail: detail,
                stuckReason: stuck,
              )
            : AgentNotificationPolicy.build(
                hostId: host.id,
                hostName: host.name,
                agent: agent,
                need: need,
                alert: alert,
                preferences: preferences,
                open: open,
                detail: detail,
              ),
      );
    }
    // Agents gone from the host have ended.
    final prefix = agentNotificationKey(host.id, '');
    _notices.removeWhere(
      (key, _) => key.startsWith(prefix) && !keys.contains(key),
    );
    // Compared without the alert flag: an unchanged list is not re-posted
    // (that would reorder the shade), and an unchanged need never alerts.
    final quiet = [
      for (final notification in notifications)
        notification.copyWith(alert: false),
    ];
    if (listEquals(_sentNotifications[host.id], quiet)) {
      return;
    }
    // Commit before posting so a throwing notifier cannot alert twice.
    _sentNotifications[host.id] = quiet;
    await notifier.showAgents(hostId: host.id, notifications: notifications);
  }

  /// Whether a notification's Reply can type into [agent]: a companion
  /// agent whose kind takes prompts (`send`), not waiting on a permission
  /// prompt (the companion refuses to type then). The companion types it
  /// into the agent's own pane by id, so Herdr's shared focus never moves.
  bool _canReply(_HostMonitor monitor, AgentInfo agent) =>
      monitor.provider?.id == companionProviderId &&
      !isHerdrOnlyAgent(agent) &&
      agent.pendingRequests.isEmpty &&
      (monitor.kinds ?? AgentKindCatalog.legacy).of(agent.kind).send != null;

  /// Posts (throttled) or clears the ongoing status notification of the
  /// "Ongoing + urgent" mode, across every monitored host.
  void _syncStatus() {
    final notifier = _notifier;
    if (notifier == null || _disposed) {
      return;
    }
    final now = _clock();
    final status = _notificationPreferences.mode.showsOngoing
        ? AgentStatusSummary.build(now: now, [
            for (final monitor in _monitors.values)
              for (final agent in monitor.status.agents)
                if (!(monitor.provider?.id == companionProviderId &&
                    agent.state == AgentAttentionState.finished &&
                    !isHerdrOnlyAgent(agent)))
                  (
                    machineId: monitor.host.id,
                    hostName: monitor.host.name,
                    agent: agent,
                    companion:
                        monitor.provider?.id == companionProviderId &&
                        !isHerdrOnlyAgent(agent),
                    detail: notificationDetail?.call(monitor.host.id, agent.id),
                    stuck: stuckReasonFor?.call(monitor.host.id, agent.id),
                  ),
          ])
        : null;
    final offer = _statusThrottle.offer(status, now);
    if (offer.retryAfter case final wait?) {
      _statusTimer ??= Timer(wait, () {
        _statusTimer = null;
        _syncStatus();
      });
      return;
    }
    if (!offer.post) {
      return;
    }
    _statusTimer?.cancel();
    _statusTimer = null;
    _statusThrottle.posted(status, now);
    unawaited(notifier.showStatus(status).catchError((_) {}));
  }

  /// The companion provider's id: it reports an ended session as
  /// [AgentAttentionState.finished].
  static const companionProviderId = 'conductore';

  /// A rule answered something since the last look: refresh the
  /// auto-approved list if one was loaded (the inbox shows it).
  void _noticeAutoApprovals(_HostMonitor monitor, List<AgentInfo> agents) {
    DateTime? latest;
    for (final agent in agents) {
      final at = agent.lastAutoApprovedAt;
      if (at != null && (latest == null || at.isAfter(latest))) {
        latest = at;
      }
    }
    final seen = monitor.lastAutoApprovedAt;
    monitor.lastAutoApprovedAt = latest ?? seen;
    if (latest == null ||
        seen == null ||
        !latest.isAfter(seen) ||
        !_approvals.containsKey(monitor.host.id)) {
      return;
    }
    unawaited(loadApprovals(monitor.host).catchError((_) => null));
  }

  /// Where tapping [agent]'s notification should land: the agent's Herdr
  /// workspace, tab and pane when the provider reports them.
  static AgentOpenTarget openTargetFor(String hostId, AgentInfo agent) {
    return AgentOpenTarget(
      hostId: hostId,
      agentId: agent.id,
      workspaceId: agent.workspace ?? '',
      tabId: agent.tab ?? '',
      paneId: agent.pane ?? '',
    );
  }

  /// A state change, or the same state reached again (the provider bumped
  /// its sequence, e.g. blocked → answered → blocked again within one poll
  /// interval).
  static bool _isTransition(_AgentMark previous, AgentInfo agent) {
    if (previous.state != agent.state) {
      return true;
    }
    if (previous.hadPending && agent.pendingRequests.isEmpty) {
      // The permission request went away but the agent still waits: it
      // timed out on the host and the prompt is now in the terminal.
      return true;
    }
    final sequence = agent.stateSequence;
    return sequence != null &&
        previous.sequence != null &&
        sequence != previous.sequence;
  }

  @override
  void dispose() {
    _disposed = true;
    _statusTimer?.cancel();
    inboxDismissals.dispose();
    _workspace.removeListener(_syncMonitors);
    for (final hostId in _monitors.keys.toList()) {
      _stopMonitor(hostId);
    }
    super.dispose();
  }
}

class _HostMonitor {
  _HostMonitor({
    required this.host,
    required this.session,
    required this.runner,
  });

  /// The machine, under its saved id.
  final SavedHost host;

  /// The open session of the machine the monitor follows (any one).
  TerminalSessionController session;
  final AgentCommandRunner runner;

  Timer? timer;
  bool fetching = false;

  /// Set while the long-poll loop runs.
  bool watching = false;

  /// Provider picked for this connection; null until the first poll.
  AgentAttentionProvider? provider;

  /// False for hosts that are listed but must never be polled.
  bool pollable = true;
  bool sawInitialSnapshot = false;
  int consecutiveFailures = 0;
  int skipTicks = 0;
  int? lastSequence;

  /// The companion's reported features (from `status`); null until known.
  Set<String>? capabilities;

  /// What each agent kind supports (`status` → `adapters`); null until a
  /// companion reported it.
  AgentKindCatalog? kinds;

  /// Newest `lastAutoApprovedAt` seen among the host's agents.
  DateTime? lastAutoApprovedAt;

  /// Bumped whenever a long-poll result is applied, so a status poll that
  /// was in flight meanwhile can tell it may be older.
  int watchGeneration = 0;
  Map<String, _AgentMark> lastStates = const {};
  AgentHostStatus status = const AgentHostStatus(loading: true);
}

/// What listeners see of one monitor, to tell a poll that changed
/// something from one that did not ([AgentHostStatus.updatedAt] aside).
@immutable
class _MonitorView {
  const _MonitorView(
    this.agents,
    this.loading,
    this.error,
    this.unavailableReason,
    this.provider,
    this.capabilities,
    this.kinds,
  );

  factory _MonitorView.of(_HostMonitor monitor) => _MonitorView(
    monitor.status.agents,
    monitor.status.loading,
    monitor.status.error,
    monitor.status.unavailableReason,
    monitor.provider,
    monitor.capabilities,
    monitor.kinds,
  );

  final List<AgentInfo> agents;
  final bool loading;
  final String? error;
  final String? unavailableReason;
  final AgentAttentionProvider? provider;
  final Set<String>? capabilities;
  final AgentKindCatalog? kinds;

  @override
  bool operator ==(Object other) =>
      other is _MonitorView &&
      other.kinds == kinds &&
      listEquals(other.agents, agents) &&
      other.loading == loading &&
      other.error == error &&
      other.unavailableReason == unavailableReason &&
      identical(other.provider, provider) &&
      setEquals(other.capabilities, capabilities);

  @override
  int get hashCode => Object.hash(
    Object.hashAll(agents),
    loading,
    error,
    unavailableReason,
    provider,
    capabilities?.length,
  );
}

typedef _AgentMark = ({
  AgentAttentionState state,
  int? sequence,
  bool hadPending,
});

/// The host no longer knows the request (answered elsewhere, timed out,
/// or its hook exited): the prompt, if any, is waiting in the terminal.
class _RequestGone extends AppFailure {
  const _RequestGone(String reason)
    : super(
        'This request was already answered or timed out. If the agent '
        'still waits, answer it in the terminal.',
        reason,
      );
}
