import 'dart:convert';

import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';

/// Oldest companion release this app talks to.
const kCompanionMinVersion = '0.2.0';

/// Companion CLI/JSON protocol this app speaks (`version` → `protocol`).
const kCompanionProtocol = 1;

/// Oldest Node.js major the companion runs on (`host/package.json`).
const kCompanionMinNodeMajor = 18;

/// How recent the last hook event must be for the companion to count as
/// active when the daemon itself is not running.
const kCompanionActiveWindow = Duration(hours: 24);

/// Where the companion stands on one machine, as the Agent hooks screen
/// shows it.
enum CompanionState {
  /// `conductore-hostd version` exits 127: nothing on PATH.
  notInstalled,

  /// The CLI answers but `doctor` finds the Claude Code hooks (or the hook
  /// client they point at) missing.
  hooksMissing,

  /// Installed and hooked, but no hook event in the last 24 h and the
  /// daemon is not running (usually: no Claude Code session since install).
  waitingForFirstEvent,

  /// The daemon is running, or a hook event arrived within 24 h.
  active,

  /// The installed version or protocol is older than this app expects.
  outdated,

  /// A command failed in a way that says nothing about the install.
  error;

  String get label => switch (this) {
    CompanionState.notInstalled => 'Not installed',
    CompanionState.hooksMissing => 'Hooks not registered',
    CompanionState.waitingForFirstEvent => 'Waiting for first event',
    CompanionState.active => 'Active',
    CompanionState.outdated => 'Update available',
    CompanionState.error => 'Check failed',
  };

  /// Whether the phone gets approvals and chat from this machine.
  bool get isWorking =>
      this == CompanionState.active ||
      this == CompanionState.waitingForFirstEvent;

  /// Whether an install (or reinstall) would fix this state.
  bool get needsInstall =>
      this == CompanionState.notInstalled ||
      this == CompanionState.hooksMissing ||
      this == CompanionState.outdated;
}

/// One line of `conductore-hostd doctor`.
class CompanionDoctorCheck {
  const CompanionDoctorCheck({
    required this.name,
    required this.ok,
    required this.detail,
    this.reportedOptional = false,
  });

  final String name;
  final bool ok;
  final String detail;

  /// The companion marked the check informative (`optional: true`, e.g. an
  /// agent adapter's own checks).
  final bool reportedOptional;

  /// Checks `doctor` itself does not count against `ok` (see host/lib/cli.js).
  static const optionalNames = {
    'herdr',
    'tmux',
    'daemon',
    'state file',
    'claude',
  };

  /// Other agents' checks (`codex`, `codex hooks`, ...): informative, an
  /// agent the machine lacks is no failure (older companions do not mark
  /// them `optional`).
  static const otherAgents = {'codex', 'gemini', 'cursor'};

  bool get optional =>
      reportedOptional ||
      optionalNames.contains(name) ||
      otherAgents.any((id) => name == id || name.startsWith('$id '));
}

/// The raw outputs one status check collects; [classifyCompanionStatus]
/// turns them into a [CompanionStatus]. Each result is null when the
/// command was not run (or threw; see [connectionError]).
class CompanionProbeResults {
  const CompanionProbeResults({
    this.version,
    this.doctor,
    this.status,
    this.node,
    this.claude,
    this.connectionError,
    this.connectionFailure,
  });

  final AgentCommandResult? version;
  final AgentCommandResult? doctor;
  final AgentCommandResult? status;
  final AgentCommandResult? node;
  final AgentCommandResult? claude;

  /// Set when the host could not be reached at all.
  final String? connectionError;

  /// What was thrown then, for classifying it (see
  /// `classifyConnectionError`).
  final Object? connectionFailure;
}

/// Everything the Agent hooks screen knows about one machine.
class CompanionStatus {
  const CompanionStatus({
    required this.state,
    required this.checkedAt,
    this.message,
    this.errorDetail,
    this.connectionFailure,
    this.installedVersion,
    this.installedProtocol,
    this.nodeVersion,
    this.claudeVersion,
    this.user,
    this.checks = const [],
    this.daemonRunning = false,
    this.agentCount = 0,
    this.liveAgentCount = 0,
    this.lastEventAt,
    this.everSawEvent = false,
  });

  final CompanionState state;
  final DateTime checkedAt;

  /// One sentence explaining [state] to the user.
  final String? message;

  /// stderr or error text for [CompanionState.error] (and failed installs).
  final String? errorDetail;

  /// What was thrown when the machine could not be reached; null when it
  /// answered.
  final Object? connectionFailure;

  final String? installedVersion;
  final int? installedProtocol;

  /// `node --version` without the leading `v`; null when missing.
  final String? nodeVersion;

  /// `claude --version` first line; null when missing.
  final String? claudeVersion;

  /// The remote user `doctor` ran as.
  final String? user;

  final List<CompanionDoctorCheck> checks;
  final bool daemonRunning;

  /// Agents the companion reports (including ended ones not yet pruned).
  final int agentCount;

  /// Agents not in the `ended` state.
  final int liveAgentCount;

  /// Newest agent `updatedAt`.
  final DateTime? lastEventAt;

  /// Whether the companion has ever recorded a hook event.
  final bool everSawEvent;

  bool get nodeFound => nodeVersion != null;

  bool get nodeSupported {
    final major = int.tryParse((nodeVersion ?? '').split('.').first);
    return major != null && major >= kCompanionMinNodeMajor;
  }

  bool get claudeFound => claudeVersion != null;
}

/// Compares dotted numeric versions (`0.1.10` > `0.1.9`); a pre-release or
/// build suffix (`-rc1`, `+3`) is ignored. Returns <0, 0 or >0.
int compareCompanionVersions(String a, String b) {
  List<int> parts(String v) => v
      .trim()
      .replaceFirst(RegExp(r'^v'), '')
      .split(RegExp(r'[-+]'))
      .first
      .split('.')
      .map((p) => int.tryParse(p) ?? 0)
      .toList();
  final pa = parts(a);
  final pb = parts(b);
  for (var i = 0; i < pa.length || i < pb.length; i++) {
    final x = i < pa.length ? pa[i] : 0;
    final y = i < pb.length ? pb[i] : 0;
    if (x != y) return x.compareTo(y);
  }
  return 0;
}

Map<String, Object?>? _jsonObject(String? text) {
  if (text == null) return null;
  final trimmed = text.trim();
  if (trimmed.isEmpty) return null;
  // The first line is the document; anything after it is noise.
  for (final candidate in [trimmed, trimmed.split('\n').first]) {
    try {
      final decoded = jsonDecode(candidate);
      if (decoded is Map<String, Object?>) return decoded;
    } on FormatException {
      continue;
    }
  }
  return null;
}

String _describe(AgentCommandResult result) {
  final parts = [
    result.stderr.trim(),
    // A companion error is `{"error": "..."}` on stdout.
    (_jsonObject(result.stdout)?['error'] as String?) ?? result.stdout.trim(),
  ].where((part) => part.isNotEmpty);
  final text = parts.join('\n');
  final code = result.exitCode;
  return text.isEmpty
      ? 'exit ${code ?? 'unknown'} with no output'
      : (code == null ? text : '$text (exit $code)');
}

String? _firstLine(AgentCommandResult? result) {
  if (result == null || result.exitCode != 0) return null;
  final line = result.stdout.trim().split('\n').first.trim();
  return line.isEmpty ? null : line;
}

/// Parses `conductore-hostd doctor` output into checks; empty when it is not
/// the expected JSON.
List<CompanionDoctorCheck> parseDoctorChecks(String stdout) {
  final raw = _jsonObject(stdout)?['checks'];
  if (raw is! List) return const [];
  return [
    for (final check in raw)
      if (check is Map<String, Object?>)
        CompanionDoctorCheck(
          name: check['name']?.toString() ?? '?',
          ok: check['ok'] == true,
          detail: check['detail']?.toString() ?? '',
          reportedOptional: check['optional'] == true,
        ),
  ];
}

/// Turns one probe's raw outputs into a status. Pure, so every state can be
/// tested from scripted command results.
CompanionStatus classifyCompanionStatus(
  CompanionProbeResults probe, {
  required DateTime now,
}) {
  final nodeLine = _firstLine(probe.node);
  final nodeVersion = nodeLine?.replaceFirst(RegExp(r'^v'), '');
  final claudeVersion = _firstLine(probe.claude);

  CompanionStatus build(
    CompanionState state,
    String message, {
    String? errorDetail,
    Object? connectionFailure,
    String? installedVersion,
    int? installedProtocol,
    List<CompanionDoctorCheck> checks = const [],
    String? user,
    bool daemonRunning = false,
    int agentCount = 0,
    int liveAgentCount = 0,
    DateTime? lastEventAt,
    bool everSawEvent = false,
  }) => CompanionStatus(
    state: state,
    checkedAt: now,
    message: message,
    errorDetail: errorDetail,
    connectionFailure: connectionFailure,
    installedVersion: installedVersion,
    installedProtocol: installedProtocol,
    nodeVersion: nodeVersion,
    claudeVersion: claudeVersion,
    user: user,
    checks: checks,
    daemonRunning: daemonRunning,
    agentCount: agentCount,
    liveAgentCount: liveAgentCount,
    lastEventAt: lastEventAt,
    everSawEvent: everSawEvent,
  );

  if (probe.connectionError != null) {
    return build(
      CompanionState.error,
      'Could not reach the machine.',
      errorDetail: probe.connectionError,
      connectionFailure: probe.connectionFailure,
    );
  }
  final version = probe.version;
  if (version == null) {
    return build(CompanionState.error, 'The companion check did not run.');
  }
  if (version.exitCode == 127) {
    // `#!/usr/bin/env node` also exits 127 when node is missing, with
    // env's complaint on stderr: installed, but cannot start.
    final stderr = version.stderr;
    if (RegExp(
      r'env:.*node|node: not found|node: No such file',
    ).hasMatch(stderr)) {
      return build(
        CompanionState.error,
        'The companion is installed but Node.js is not on the SSH PATH, '
        'so it cannot start from the phone.',
        errorDetail: stderr.trim(),
      );
    }
    return build(
      CompanionState.notInstalled,
      'conductore-hostd was not found on this machine.',
    );
  }
  final versionJson = _jsonObject(version.stdout);
  if (version.exitCode != 0 || versionJson == null) {
    return build(
      CompanionState.error,
      'conductore-hostd version failed.',
      errorDetail: _describe(version),
    );
  }
  final installedVersion = versionJson['version']?.toString();
  final protocolValue = versionJson['protocol'];
  final installedProtocol = protocolValue is num
      ? protocolValue.toInt()
      : int.tryParse('$protocolValue');

  final doctor = probe.doctor;
  final doctorJson = doctor == null ? null : _jsonObject(doctor.stdout);
  final checks = doctor == null
      ? const <CompanionDoctorCheck>[]
      : parseDoctorChecks(doctor.stdout);
  final user = doctorJson?['user']?.toString();

  if (installedVersion == null ||
      installedProtocol == null ||
      installedProtocol < kCompanionProtocol ||
      compareCompanionVersions(installedVersion, kCompanionMinVersion) < 0) {
    return build(
      CompanionState.outdated,
      'This machine runs companion ${installedVersion ?? 'unknown'} '
      '(protocol ${installedProtocol ?? '?'}); the app needs '
      '$kCompanionMinVersion or newer (protocol $kCompanionProtocol).',
      installedVersion: installedVersion,
      installedProtocol: installedProtocol,
      checks: checks,
      user: user,
    );
  }

  if (doctor == null || doctorJson == null || checks.isEmpty) {
    return build(
      CompanionState.error,
      'conductore-hostd doctor failed.',
      errorDetail: doctor == null ? null : _describe(doctor),
      installedVersion: installedVersion,
      installedProtocol: installedProtocol,
    );
  }

  bool failed(String name) => checks.any((c) => c.name == name && !c.ok);
  if (failed('hooks registered') ||
      failed('hook client') ||
      failed('settings.json')) {
    final hooks = checks.where((c) => c.name == 'hooks registered').firstOrNull;
    return build(
      CompanionState.hooksMissing,
      'The companion is installed but Claude Code does not call it'
      '${hooks != null && !hooks.ok ? ' (${hooks.detail})' : ''}.',
      installedVersion: installedVersion,
      installedProtocol: installedProtocol,
      checks: checks,
      user: user,
    );
  }

  final daemonRunning = checks.any((c) => c.name == 'daemon' && c.ok);
  final statusJson = probe.status == null
      ? null
      : _jsonObject(probe.status!.stdout);
  final agents = statusJson?['agents'];
  final agentList = agents is List
      ? agents.whereType<Map<String, Object?>>().toList()
      : const <Map<String, Object?>>[];
  DateTime? lastEventAt;
  var live = 0;
  for (final agent in agentList) {
    if (agent['state'] != 'ended') live += 1;
    final updated = agent['updatedAt'];
    if (updated is num) {
      final at = DateTime.fromMillisecondsSinceEpoch(updated.toInt());
      if (lastEventAt == null || at.isAfter(lastEventAt)) lastEventAt = at;
    }
  }
  final seq = statusJson?['seq'];
  final everSawEvent =
      agentList.isNotEmpty ||
      (seq is num && seq > 0) ||
      (statusJson != null && statusJson['source'] != 'none');
  final recent =
      lastEventAt != null &&
      now.difference(lastEventAt) <= kCompanionActiveWindow;

  if (daemonRunning || recent) {
    return build(
      CompanionState.active,
      daemonRunning
          ? 'The daemon is running and receiving Claude Code hook events.'
          : 'Hook events are arriving; the daemon starts on the next one.',
      installedVersion: installedVersion,
      installedProtocol: installedProtocol,
      checks: checks,
      user: user,
      daemonRunning: daemonRunning,
      agentCount: agentList.length,
      liveAgentCount: live,
      lastEventAt: lastEventAt,
      everSawEvent: everSawEvent,
    );
  }
  return build(
    CompanionState.waitingForFirstEvent,
    everSawEvent
        ? 'Installed and hooked; no Claude Code activity in the last 24 hours.'
        : 'Installed and hooked. The first Claude Code event (starting or '
              'using a session) starts the daemon.',
    installedVersion: installedVersion,
    installedProtocol: installedProtocol,
    checks: checks,
    user: user,
    agentCount: agentList.length,
    liveAgentCount: live,
    lastEventAt: lastEventAt,
    everSawEvent: everSawEvent,
  );
}
