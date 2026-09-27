// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';

import 'package:conduit/core/app_failure.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention_notifier.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention_provider.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/agent_attention/domain/agent_inbox.dart';
import 'package:conduit/features/agent_attention/domain/agent_permission_actions.dart';
import 'package:conduit/features/agent_attention/domain/approval_rules.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
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
/// Notifications are edge-triggered on state *transitions* by stable agent
/// identity — the first snapshot after monitoring starts never notifies,
/// and an unchanged state is never re-notified. A provider-reported state
/// sequence counts as a transition too, so an agent that was answered and
/// blocked again between two polls still notifies. Pending permission
/// requests are notified once per request id (including on the first
/// snapshot: an unanswered prompt is actionable whenever it is seen) and
/// the notification is cancelled when the request disappears. The set of
/// notified requests outlives a reconnect, so reconnecting neither
/// re-alerts nor leaves an answered request's notification behind. A
/// request that timed out on the host (the agent still waits, now in the
/// terminal) turns into a plain "needs input" notification.
class AgentAttentionController extends ChangeNotifier {
  AgentAttentionController({
    required TerminalWorkspaceController workspace,
    required AgentCommandRunnerFactory runnerFactory,
    required AgentAttentionProvider provider,
    AgentAttentionProvider? companionProvider,
    AgentAttentionNotifier? notifier,
    Duration pollInterval = const Duration(seconds: 15),
    Duration watchRestartDelay = const Duration(milliseconds: 500),
    this.persistMonitoringEnabled,
  }) : _workspace = workspace,
       _runnerFactory = runnerFactory,
       _provider = provider,
       _companionProvider = companionProvider,
       _notifier = notifier,
       _pollInterval = pollInterval,
       _watchRestartDelay = watchRestartDelay {
    _workspace.addListener(_syncMonitors);
    _syncMonitors();
  }

  final TerminalWorkspaceController _workspace;
  final AgentCommandRunnerFactory _runnerFactory;

  /// The default (Herdr) provider.
  final AgentAttentionProvider _provider;

  /// The Conductore companion provider, when the app ships one.
  final AgentAttentionProvider? _companionProvider;
  final AgentAttentionNotifier? _notifier;
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

  /// Per host: request ids that currently have a permission notification.
  /// Kept across reconnects (monitors come and go with the session).
  final Map<String, Set<String>> _notifiedRequests = {};
  bool _appActive = true;
  bool _foreground = true;
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
      _monitors[hostId]?.provider ?? _provider;

  /// Hosts currently monitored, in workspace order.
  List<SavedHost> get monitoredHosts => [
    for (final session in _workspace.sessions)
      if (_monitors.containsKey(session.host.id)) session.host,
  ];

  bool isMonitoring(String hostId) => _monitors.containsKey(hostId);

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
    final monitor = _monitors[host.id];
    if (monitor != null) {
      return (monitor.runner, owned: false);
    }
    return (_runnerFactory(host), owned: true);
  }

  AgentHostStatus? statusFor(String hostId) => _monitors[hostId]?.status;

  /// Whether a decision for [requestId] is in flight.
  bool isDeciding(String requestId) => _deciding.contains(requestId);

  /// Whether [hostId] is currently on its long-poll (foreground only).
  @visibleForTesting
  bool isWatching(String hostId) => _monitors[hostId]?.watching ?? false;

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

  /// Switches between the long-poll (foreground) and periodic polling
  /// only (background). On Android polling itself stays active in the
  /// background (see [setAppActive]); the long-poll is foreground-only so
  /// a backgrounded app does not hold an exec channel open for minutes.
  void setAppForeground(bool foreground) {
    if (_foreground == foreground || _disposed) {
      return;
    }
    _foreground = foreground;
    if (!foreground) {
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

  Future<void> refresh(String hostId) async {
    final monitor = _monitors[hostId];
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
    final monitor = _monitors[hostId];
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
    final monitor = _monitors[hostId];
    if (monitor == null) {
      throw const AppFailure('This machine is not being monitored.');
    }
    final provider = monitor.provider ?? await _resolveProvider(monitor);
    try {
      await _sendDecision(monitor.runner, provider, request, verdict);
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
  /// and dismisses the notification, or rewrites it to say the decision
  /// failed. Never throws.
  Future<void> completePermissionAction(
    AgentPermissionAction action,
    SavedHost? host,
  ) async {
    final notifier = _notifier;
    final verdict = PermissionVerdict.values
        .where((value) => value.wireName == action.verdict)
        .firstOrNull;
    final notificationId = action.notificationId.isNotEmpty
        ? action.notificationId
        : permissionNotificationId(action.hostId, action.requestId);
    Future<void> failed(String reason) async {
      await notifier?.show(
        id: notificationId,
        title: 'Permission decision failed',
        body:
            'Open Conductore to answer the request'
            '${host == null ? '' : ' on ${host.name}'}. $reason',
      );
    }

    if (host == null) {
      await failed('The machine is no longer saved.');
      return;
    }
    if (verdict == null) {
      await failed('Unknown action.');
      return;
    }
    final request = PendingPermissionRequest(
      id: action.requestId,
      toolName: '',
      summary: '',
    );
    final monitor = _monitors[host.id];
    try {
      if (monitor != null) {
        final provider = monitor.provider ?? await _resolveProvider(monitor);
        try {
          await _sendDecision(monitor.runner, provider, request, verdict);
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
      _notifiedRequests[host.id]?.remove(action.requestId);
      await failed(error.toString());
      return;
    } finally {
      if (!_disposed) {
        notifyListeners();
      }
    }
    _notifiedRequests[host.id]?.remove(action.requestId);
    await notifier?.cancel(id: notificationId);
  }

  /// "Claude needs permission: Bash · High risk".
  static String permissionNotificationTitle(PendingPermissionRequest request) {
    final risk = request.risk;
    return 'Claude needs permission: ${request.toolName}'
        '${risk == null ? '' : ' · ${risk.level.label}'}';
  }

  /// The request, the risk reason on its own line, and the machine.
  static String permissionNotificationBody(
    PendingPermissionRequest request,
    String hostName,
  ) {
    final reason = request.risk?.reason ?? '';
    return '${request.summary} (on $hostName)'
        '${reason.isEmpty ? '' : '\n$reason'}';
  }

  /// Notification id for one pending request (stable per request, so a
  /// re-seen request replaces instead of stacking).
  static String permissionNotificationId(String hostId, String requestId) =>
      '$hostId:perm:$requestId';

  // --- smart approvals ------------------------------------------------------
  //
  // Risk labels, approval rules, time-boxed trust, "approve all safe" and
  // the auto-approved log, on hosts whose companion reports the
  // `smart-approvals` capability. The voice guide uses the same calls:
  // [approveRequest], [approveAllLowRisk] and [trustRequest].

  /// Whether [hostId]'s companion keeps approval rules and rates requests.
  bool supportsSmartApprovals(String hostId) {
    final monitor = _monitors[hostId];
    return monitor != null &&
        monitor.provider is SmartApprovalsProvider &&
        (monitor.capabilities?.contains(smartApprovalsCapability) ?? false);
  }

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
    final byHost = <String, List<String>>{};
    for (final pending in chosen) {
      if (hostId != null && pending.hostId != hostId) {
        continue;
      }
      byHost.putIfAbsent(pending.hostId, () => []).add(pending.request.id);
    }
    var result = const BatchApprovalResult();
    Object? firstError;
    for (final MapEntry(key: host, value: ids) in byHost.entries) {
      final monitor = _monitors[host];
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
          provider.approveLowCommand(ids),
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
  /// minutes"). Without [rule], the companion's first suggestion; the
  /// scope's repo is the request's. Also allows other waiting requests
  /// the rule covers. High-risk requests are refused by the companion.
  Future<TrustResult> trustRequest(
    String hostId,
    PendingPermissionRequest request, {
    TrustDuration duration = const TrustDuration.minutes(60),
    ApprovalScopeKind scope = ApprovalScopeKind.repo,
    String? rule,
    String source = 'trust',
  }) async {
    final monitor = _monitors[hostId];
    final provider = _smartOf(monitor?.provider);
    if (monitor == null || provider == null) {
      throw const AppFailure(
        'Trust needs the Conductore companion with approval rules on this '
        'machine.',
      );
    }
    final draft = ApprovalRuleDraft(
      rule:
          rule ??
          request.suggestedRules.firstOrNull ??
          (request.toolName.isEmpty ? 'tool' : request.toolName),
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
        provider.trustCommand(request, draft, source: source),
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
    final monitor = _monitors[host.id];
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
    final resolved = _monitors[host.id]?.provider;
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

  Future<void> _sendDecision(
    AgentCommandRunner runner,
    AgentAttentionProvider provider,
    PendingPermissionRequest request,
    PermissionVerdict verdict,
  ) async {
    final command = provider.decideCommand(request, verdict);
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

  /// Drops [requestId] from the host's dashboard state and cancels its
  /// notification (the host confirmed the decision; the next poll agrees).
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
    if (_notifiedFor(monitor.host.id).remove(requestId)) {
      unawaited(
        _notifier?.cancel(
              id: permissionNotificationId(monitor.host.id, requestId),
            ) ??
            Future<void>.value(),
      );
    }
  }

  Set<String> _notifiedFor(String hostId) =>
      _notifiedRequests.putIfAbsent(hostId, () => <String>{});

  void _syncMonitors() {
    if (_disposed) {
      return;
    }
    final wanted = <String, TerminalSessionController>{
      for (final session in _workspace.sessions)
        if (monitoringEnabled(session.host) &&
            !session.host.isLocal &&
            session.isConnected)
          session.host.id: session,
    };

    for (final hostId in _monitors.keys.toList()) {
      if (!wanted.containsKey(hostId)) {
        _stopMonitor(hostId);
      }
    }
    for (final MapEntry(key: hostId, value: session) in wanted.entries) {
      if (!_monitors.containsKey(hostId)) {
        _startMonitor(session);
      }
    }
    notifyListeners();
  }

  void _startMonitor(TerminalSessionController session) {
    final monitor = _HostMonitor(
      host: session.host,
      session: session,
      runner: _runnerFactory(session.host),
    );
    _monitors[session.host.id] = monitor;
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

  void _stopMonitor(String hostId) {
    final monitor = _monitors.remove(hostId);
    if (monitor == null) {
      return;
    }
    monitor.session.removeListener(_syncMonitors);
    monitor.timer?.cancel();
    monitor.timer = null;
    unawaited(monitor.runner.close());
  }

  void _startTimer(_HostMonitor monitor) {
    monitor.timer?.cancel();
    monitor.timer = Timer.periodic(_pollInterval, (_) => _onTick(monitor));
  }

  void _onTick(_HostMonitor monitor) {
    if (monitor.skipTicks > 0) {
      monitor.skipTicks -= 1;
      return;
    }
    if (monitor.watching && _foreground) {
      // The long-poll delivers changes as they happen; the periodic poll is
      // only the fallback while it is not running.
      return;
    }
    unawaited(_poll(monitor));
  }

  /// Polls [hostId] immediately, ignoring any failure backoff.
  @visibleForTesting
  Future<void> pollNow(String hostId) async {
    final monitor = _monitors[hostId];
    if (monitor != null) {
      await _poll(monitor);
    }
  }

  /// Simulates one periodic tick for [hostId], honoring the failure backoff.
  @visibleForTesting
  Future<void> tickNow(String hostId) async {
    final monitor = _monitors[hostId];
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
      if (!_disposed) {
        notifyListeners();
      }
    }
  }

  bool _shouldWatch(_HostMonitor monitor) {
    return !_disposed &&
        _appActive &&
        _foreground &&
        !monitor.watching &&
        monitor.pollable &&
        monitor.status.unavailableReason == null &&
        monitor.status.error == null &&
        (monitor.provider?.supportsWatch ?? false) &&
        _monitors.containsKey(monitor.host.id) &&
        monitor.session.isConnected;
  }

  /// Long-polls the host for changes until the app leaves the foreground,
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
            !_foreground ||
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
      monitor.capabilities = capabilities;
    }
    _noticeAutoApprovals(monitor, snapshot.agents);
    if (notify) {
      await _notifyTransitions(monitor, snapshot, previousStates);
    }
    await _syncPermissionNotifications(monitor, snapshot);
  }

  Future<void> _notifyTransitions(
    _HostMonitor monitor,
    AgentAttentionSnapshot snapshot,
    Map<String, _AgentMark> previousStates,
  ) async {
    final notifier = _notifier;
    if (notifier == null) {
      return;
    }
    final host = monitor.host;
    for (final agent in snapshot.agents) {
      final previous = previousStates[agent.id];
      if (previous != null && !_isTransition(previous, agent)) {
        continue;
      }
      // Loud: an agent waiting on a human (a pending permission request
      // gets its own actionable notification). Quiet unless the level is
      // "All": a finished agent. Everything else only updates the inbox.
      final level = host.agentNotifyLevel;
      final needsInput =
          agent.state.needsAttention &&
          level.notifiesApprovalsAndErrors &&
          agent.pendingRequests.isEmpty;
      final finished =
          agent.state == AgentAttentionState.finished && level.notifiesFinished;
      if (!needsInput && !finished) {
        continue;
      }
      await notifier.show(
        id: '${host.id}:${agent.id}',
        title: needsInput ? 'Agent needs input' : 'Agent finished',
        body: _withMessage('${agent.name} on ${host.name}', agent),
        open: openTargetFor(host.id, agent),
      );
    }
  }

  /// Posts one actionable notification per new pending request and cancels
  /// the ones whose request is gone (answered elsewhere, or the agent
  /// exited).
  Future<void> _syncPermissionNotifications(
    _HostMonitor monitor,
    AgentAttentionSnapshot snapshot,
  ) async {
    final notifier = _notifier;
    if (notifier == null) {
      return;
    }
    final host = monitor.host;
    final notified = _notifiedFor(host.id);
    final seen = <String>{};
    for (final agent in snapshot.agents) {
      for (final request in agent.pendingRequests) {
        seen.add(request.id);
        if (!host.agentNotifyLevel.notifiesApprovalsAndErrors ||
            notified.contains(request.id)) {
          continue;
        }
        // Commit before showing so a throwing notifier cannot re-notify.
        notified.add(request.id);
        // The generic "needs input" notification for this agent (if any)
        // is superseded by the actionable one.
        await notifier.cancel(id: '${host.id}:${agent.id}');
        await notifier.showPermissionRequest(
          id: permissionNotificationId(host.id, request.id),
          title: permissionNotificationTitle(request),
          body: _withMessage(
            permissionNotificationBody(request, host.name),
            agent,
          ),
          hostId: host.id,
          requestId: request.id,
          open: openTargetFor(host.id, agent),
        );
      }
    }
    for (final requestId in notified.toList()) {
      if (!seen.contains(requestId)) {
        notified.remove(requestId);
        await notifier.cancel(id: permissionNotificationId(host.id, requestId));
      }
    }
  }

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

  /// Longest agent message put into a notification body.
  static const _notificationMessageLength = 300;

  /// Appends the agent's last message (if any) on its own line.
  static String _withMessage(String body, AgentInfo agent) {
    final message = agent.lastMessage?.trim();
    if (message == null || message.isEmpty) {
      return body;
    }
    final capped = message.length > _notificationMessageLength
        ? '${message.substring(0, _notificationMessageLength)}…'
        : message;
    return '$body\n$capped';
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

  final SavedHost host;
  final TerminalSessionController session;
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

  /// Newest `lastAutoApprovedAt` seen among the host's agents.
  DateTime? lastAutoApprovedAt;

  /// Bumped whenever a long-poll result is applied, so a status poll that
  /// was in flight meanwhile can tell it may be older.
  int watchGeneration = 0;
  Map<String, _AgentMark> lastStates = const {};
  AgentHostStatus status = const AgentHostStatus(loading: true);
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
