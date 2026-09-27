// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:conduit/core/telemetry/telemetry.dart';
import 'package:conduit/core/telemetry/telemetry_events.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/agents_digest/data/digest_preferences.dart';
import 'package:conduit/features/agents_digest/domain/agents_digest.dart';
import 'package:conduit/features/companion_setup/data/companion_commands.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/hosts/presentation/hosts_controller.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:flutter/widgets.dart';

/// Where [DigestController] finds machines, runs commands and reads the
/// agent monitor's live agents.
abstract class DigestHostSource implements Listenable {
  /// The machines to ask, one per machine.
  List<SavedHost> get digestHosts;

  /// The monitor's agents on [hostId] (the fallback for a companion
  /// without `digest`, and the live requests the card's buttons answer).
  List<AgentInfo> liveAgentsFor(String hostId);

  /// A runner for [host]; the caller closes it only when `owned`.
  (AgentCommandRunner, {bool owned}) runnerFor(SavedHost host);
}

/// The app's source: machines the agent monitor watches through the
/// Conductore companion, plus This computer on desktops.
class AttentionDigestHostSource implements DigestHostSource {
  AttentionDigestHostSource({required this.attention, this.hosts})
    : _changes = Listenable.merge([attention, ?hosts]);

  final AgentAttentionController attention;
  final HostsController? hosts;
  final Listenable _changes;

  static const companionProviderId = 'conductore';

  @override
  List<SavedHost> get digestHosts {
    final seen = <String>{};
    return [
      for (final host in attention.monitoredHosts)
        if (attention.providerFor(host.id).id == companionProviderId &&
            seen.add(baseHostId(host.id)))
          host,
      if (hosts?.thisComputer case final local?
          when seen.add(baseHostId(local.id)))
        local,
    ];
  }

  @override
  List<AgentInfo> liveAgentsFor(String hostId) =>
      attention.statusFor(hostId)?.agents ?? const [];

  @override
  (AgentCommandRunner, {bool owned}) runnerFor(SavedHost host) =>
      attention.runnerFor(host);

  @override
  void addListener(VoidCallback listener) => _changes.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      _changes.removeListener(listener);
}

/// One machine's part of the dashboard.
@immutable
class MachineDigest {
  const MachineDigest({
    required this.hostId,
    required this.hostName,
    this.report,
    this.error,
    this.needsUpdate = false,
    this.fetchedAt,
  });

  final String hostId;
  final String hostName;
  final DigestReport? report;

  /// The last fetch failed (the previous report, if any, is kept).
  final String? error;

  /// The companion has no `digest`: facts come from the monitor's status,
  /// and the card suggests updating the agent hooks.
  final bool needsUpdate;
  final DateTime? fetchedAt;

  MachineDigest copyWith({
    DigestReport? report,
    String? error,
    bool clearError = false,
    bool? needsUpdate,
    DateTime? fetchedAt,
  }) => MachineDigest(
    hostId: hostId,
    hostName: hostName,
    report: report ?? this.report,
    error: clearError ? null : error ?? this.error,
    needsUpdate: needsUpdate ?? this.needsUpdate,
    fetchedAt: fetchedAt ?? this.fetchedAt,
  );
}

/// The agents dashboard: every agent's facts, stuck flags and summary
/// since the user's last look (`conductore-hostd digest`).
///
/// Costs nothing unless a view shows it ([attachView]) with the app in
/// the foreground: then each machine is asked for its facts at once
/// (free, no Claude) and every [interval]. Summaries cost Claude tokens,
/// so they run only when a view opens (and on a manual [refresh]), only
/// when turned on, and only on machines whose answer marked agents that
/// changed since their last summary; the periodic poll never asks for
/// them. Nothing runs in the background.
class DigestController extends ChangeNotifier with WidgetsBindingObserver {
  DigestController({
    required DigestHostSource source,
    DigestPreferencesStore? preferences,
    String Function()? language,
    this.interval = const Duration(seconds: 60),
    this.factsTimeout = const Duration(seconds: 20),
    this.summaryTimeout = const Duration(seconds: 50),
    this.unavailableRetry = const Duration(minutes: 10),
    DateTime Function()? clock,
    bool observeLifecycle = true,
  }) : _source = source,
       _store = preferences ?? MemoryDigestPreferencesStore(),
       _language = language ?? (() => 'en'),
       _clock = clock ?? DateTime.now,
       _observesLifecycle = observeLifecycle {
    _source.addListener(_onSourceChanged);
    if (observeLifecycle) {
      WidgetsBinding.instance.addObserver(this);
    }
    _syncMachines();
    _loaded = _loadPreferences();
  }

  final DigestHostSource _source;
  final DigestPreferencesStore _store;
  final String Function() _language;
  final DateTime Function() _clock;
  final bool _observesLifecycle;

  /// How often the facts are asked again while a view shows them.
  final Duration interval;
  final Duration factsTimeout;

  /// A summary run: the companion's own 30 s cap plus the SSH round trip.
  final Duration summaryTimeout;

  /// How long a machine whose companion lacks `digest` waits before the
  /// next try (it may have been updated).
  final Duration unavailableRetry;

  final Map<String, MachineDigest> _machines = {};
  final Map<String, SavedHost> _hosts = {};
  final Set<String> _inFlight = {};
  final Set<String> _summarizing = {};
  late final Future<void> _loaded;
  DigestPreferences _preferences = const DigestPreferences();
  int _views = 0;
  bool _appActive = true;
  bool _disposed = false;
  Timer? _timer;

  /// The window start fixed while a view is open: "since last check"
  /// means the check before this one.
  DateTime? _openSince;
  DateTime? _openedAt;

  DigestPreferences get preferences => _preferences;

  bool get isVisible => _views > 0 && _appActive;

  /// Whether facts are being fetched and nothing has arrived yet.
  bool get isLoading =>
      _inFlight.isNotEmpty && !_machines.values.any((m) => m.report != null);

  /// Whether a summary run is going on somewhere.
  bool get isSummarizing => _summarizing.isNotEmpty;

  List<MachineDigest> get machines => [
    for (final host in _hosts.values) ?_machines[host.id],
  ];

  /// Machines whose companion predates `digest`.
  List<MachineDigest> get outdated => [
    for (final machine in machines)
      if (machine.needsUpdate) machine,
  ];

  /// The start of the counted window.
  DateTime get since =>
      _openSince ?? _preferences.window.since(_clock(), _preferences.lastSeen);

  /// Every machine's agents in sections.
  /// The cached summary (else headline) of [agentId] on [hostId] from the
  /// companion's digest, for the agent's notification; null when the
  /// digest has not answered for it (the live-status fallback does not
  /// count: it only repeats the agent's message).
  String? cachedLineFor(String hostId, String agentId) {
    final base = baseHostId(hostId);
    for (final machine in machines) {
      final report = machine.report;
      if (report == null || report.fromStatus) {
        continue;
      }
      for (final agent in report.agents) {
        if (agent.sessionId == agentId &&
            !agent.fromStatus &&
            baseHostId(agent.hostId) == base) {
          return agent.summary ?? agent.headline;
        }
      }
    }
    return null;
  }

  DigestOverview get overview => DigestOverview([
    for (final machine in machines) ...?machine.report?.agents,
  ], since: since);

  /// Tokens and estimated cost of today's summary calls, every machine.
  ({int tokens, double costUsd}) get summaryUsageToday {
    var tokens = 0;
    var cost = 0.0;
    for (final machine in machines) {
      tokens += machine.report?.tokensToday ?? 0;
      cost += machine.report?.costTodayUsd ?? 0;
    }
    return (tokens: tokens, costUsd: cost);
  }

  /// Call when a view shows the dashboard; call the returned function when
  /// it goes away. The first view counts as one look (telemetry, and the
  /// next "since last check" starts here).
  VoidCallback attachView() {
    _views++;
    if (_views == 1) {
      Telemetry.instance.track(const TelemetryEvent.digestOpened());
      _openedAt = _clock();
      _openSince = null;
      scheduleMicrotask(() async {
        await _loaded;
        if (_disposed || _views == 0) return;
        _openSince = _preferences.window.since(
          _openedAt!,
          _preferences.lastSeen,
        );
        notifyListeners();
        unawaited(_pollAll(force: true, summaries: true));
      });
    }
    var detached = false;
    return () {
      if (detached) return;
      detached = true;
      _views--;
      if (_views == 0) {
        _timer?.cancel();
        _timer = null;
        final opened = _openedAt;
        _openSince = null;
        _openedAt = null;
        // Views detach while the tree is torn down: not in this frame.
        if (opened != null && !_disposed) {
          scheduleMicrotask(() {
            if (!_disposed) {
              unawaited(_save(_preferences.copyWith(lastSeen: opened)));
            }
          });
        }
      }
    };
  }

  /// Pauses polling while the app is in the background.
  void setAppActive(bool active) {
    if (_appActive == active || _disposed) return;
    _appActive = active;
    if (active && _views > 0) {
      unawaited(_pollAll(force: true));
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      setAppActive(state == AppLifecycleState.resumed);

  /// Asks every machine now, summaries included (pull to refresh).
  Future<void> refresh() => _pollAll(force: true, summaries: true);

  /// Everything so far counts as seen: the window starts now.
  Future<void> markAllSeen() async {
    final now = _clock();
    _openSince = now;
    await _save(
      _preferences.copyWith(lastSeen: now, window: DigestWindow.sinceLastCheck),
    );
    await _pollAll(force: true);
  }

  Future<void> setWindow(DigestWindow window) async {
    await _save(_preferences.copyWith(window: window));
    if (_views > 0) {
      _openSince = window.since(_openedAt ?? _clock(), _preferences.lastSeen);
      notifyListeners();
      await _pollAll(force: true);
    }
  }

  Future<void> setSummariesEnabled(bool enabled) =>
      _save(_preferences.copyWith(summariesEnabled: enabled));

  Future<void> setThresholds(DigestThresholds thresholds) =>
      _save(_preferences.copyWith(thresholds: thresholds));

  /// The voice guide's "catch me up": fresh facts (and summaries, when on;
  /// the user asked), then the spoken overview.
  Future<String> catchUp(String languageCode) async {
    await _loaded;
    await _pollAll(force: true, summaries: true);
    return catchUpSpeech(overview, languageCode);
  }

  Future<void> _loadPreferences() async {
    final loaded = await _store.load();
    if (_disposed) return;
    _preferences = loaded;
    notifyListeners();
  }

  Future<void> _save(DigestPreferences next) async {
    _preferences = next;
    if (!_disposed) notifyListeners();
    try {
      await _store.save(next);
    } on Object {
      // Kept for this run; storage is best effort.
    }
  }

  void _onSourceChanged() {
    if (_disposed) return;
    final added = _syncMachines();
    if (isVisible) {
      for (final host in added) {
        unawaited(_fetch(host, summaries: true));
      }
    }
  }

  /// Follows the source's machines. A machine on the status fallback gets
  /// the monitor's latest agents. Returns the hosts that are new.
  List<SavedHost> _syncMachines() {
    final hosts = _source.digestHosts;
    final ids = {for (final host in hosts) host.id};
    var changed = false;
    final added = <SavedHost>[];
    for (final id in _hosts.keys.toList()) {
      if (!ids.contains(id)) {
        _hosts.remove(id);
        _machines.remove(id);
        changed = true;
      }
    }
    for (final host in hosts) {
      final known = _machines[host.id];
      if (known == null) {
        added.add(host);
        _machines[host.id] = MachineDigest(
          hostId: host.id,
          hostName: host.name,
        );
        changed = true;
      } else if (known.needsUpdate) {
        _machines[host.id] = known.copyWith(report: _fromStatus(host));
        changed = true;
      }
      _hosts[host.id] = host;
    }
    if (changed) notifyListeners();
    return added;
  }

  DigestReport _fromStatus(SavedHost host) => digestFromStatus(
    hostId: host.id,
    hostName: host.name,
    agents: _source.liveAgentsFor(host.id),
  );

  void _schedule() {
    _timer?.cancel();
    _timer = null;
    if (!isVisible || _disposed) return;
    _timer = Timer(interval, () {
      _timer = null;
      unawaited(_pollAll());
    });
  }

  Future<void> _pollAll({bool force = false, bool summaries = false}) async {
    if (_disposed) return;
    final now = _clock();
    await Future.wait([
      for (final host in _hosts.values.toList())
        if (force || _due(_machines[host.id], now))
          _fetch(host, summaries: summaries),
    ]);
    if (!_disposed) _schedule();
  }

  bool _due(MachineDigest? machine, DateTime now) {
    final at = machine?.fetchedAt;
    if (machine == null || at == null) return true;
    final age = now.difference(at);
    if (machine.needsUpdate) return age >= unavailableRetry;
    return age >= interval - const Duration(seconds: 1);
  }

  String _arguments({required bool summaries}) {
    final since = this.since.millisecondsSinceEpoch;
    final thresholds = _preferences.thresholds.arguments;
    return [
      'digest --since $since',
      '--lang ${_language().startsWith('pt') ? 'pt' : 'en'}',
      if (summaries) '--summaries',
      if (thresholds.isNotEmpty) thresholds,
    ].join(' ');
  }

  /// Facts first; then, when [summaries] is asked for, turned on and the
  /// answer marked agents to summarise, the summary run.
  Future<void> _fetch(SavedHost host, {bool summaries = false}) async {
    if (_disposed || !_inFlight.add(host.id)) return;
    notifyListeners();
    AgentCommandRunner? runner;
    var owned = false;
    try {
      final (r, owned: o) = _source.runnerFor(host);
      runner = r;
      owned = o;
      final report = await _run(r, host, summaries: false);
      if (report == null || _disposed) return;
      if (summaries &&
          _preferences.summariesEnabled &&
          report.hasPendingSummaries &&
          _summarizing.add(host.id)) {
        notifyListeners();
        try {
          await _run(r, host, summaries: true);
        } finally {
          _summarizing.remove(host.id);
        }
      }
    } on Object catch (error) {
      _update(
        host,
        (machine) => machine.copyWith(
          error: _firstLine('$error') ?? 'Unreachable',
          fetchedAt: _clock(),
        ),
      );
    } finally {
      _inFlight.remove(host.id);
      if (owned) unawaited(runner?.close());
      if (!_disposed) notifyListeners();
    }
  }

  /// One `digest` call; the report it stored, or null when the machine
  /// has no `digest` (then the status fallback is stored).
  Future<DigestReport?> _run(
    AgentCommandRunner runner,
    SavedHost host, {
    required bool summaries,
  }) async {
    final result = await runner.run(
      CompanionCommands.hostdCommand(_arguments(summaries: summaries)),
      timeout: summaries ? summaryTimeout : factsTimeout,
    );
    final report = parseDigestReport(
      result.stdout,
      hostId: host.id,
      hostName: host.name,
    );
    if (report != null) {
      _update(
        host,
        (machine) => machine.copyWith(
          report: report,
          clearError: true,
          needsUpdate: false,
          fetchedAt: _clock(),
        ),
      );
      return report;
    }
    // An older companion does not know the command (or there is none).
    final output = '${result.stdout}\n${result.stderr}';
    final missing =
        result.exitCode == 127 ||
        output.contains('unknown command') ||
        output.contains('not found');
    _update(
      host,
      (machine) => missing
          ? machine.copyWith(
              report: _fromStatus(host),
              needsUpdate: true,
              clearError: true,
              fetchedAt: _clock(),
            )
          : machine.copyWith(
              error: _firstLine(output) ?? 'No digest reply',
              fetchedAt: _clock(),
            ),
    );
    return null;
  }

  void _update(SavedHost host, MachineDigest Function(MachineDigest) change) {
    final machine = _machines[host.id];
    if (_disposed || machine == null) return;
    _machines[host.id] = change(machine);
    notifyListeners();
  }

  static String? _firstLine(String text) {
    for (final line in text.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isNotEmpty) {
        return trimmed.length > 160 ? '${trimmed.substring(0, 160)}…' : trimmed;
      }
    }
    return null;
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _source.removeListener(_onSourceChanged);
    if (_observesLifecycle) {
      WidgetsBinding.instance.removeObserver(this);
    }
    super.dispose();
  }
}

/// Makes the app's [DigestController] available to the home page, the
/// desktop shell and Settings.
class DigestScope extends InheritedWidget {
  const DigestScope({
    required this.controller,
    required super.child,
    super.key,
  });

  final DigestController controller;

  static DigestController? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<DigestScope>()?.controller;

  @override
  bool updateShouldNotify(DigestScope oldWidget) =>
      oldWidget.controller != controller;
}
