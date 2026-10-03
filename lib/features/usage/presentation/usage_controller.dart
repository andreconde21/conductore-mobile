// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention_notifier.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/companion_setup/data/companion_commands.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/hosts/presentation/hosts_controller.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:conduit/features/usage/data/usage_preferences.dart';
import 'package:conduit/features/usage/domain/usage_alert.dart';
import 'package:conduit/features/usage/domain/usage_explorer.dart';
import 'package:conduit/features/usage/domain/usage_range.dart';
import 'package:conduit/features/usage/domain/usage_report.dart';
import 'package:conduit/features/usage/domain/usage_summary.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Where [UsageController] finds machines and runs commands.
abstract class UsageHostSource implements Listenable {
  /// The machines to ask for usage, one per machine.
  List<SavedHost> get usageHosts;

  /// Claude limits the agent monitor has for [hostId] (statusline
  /// reports), newest per window.
  List<UsageLimit> liveLimitsFor(String hostId);

  /// A runner for [host]; the caller closes it only when `owned`.
  (AgentCommandRunner, {bool owned}) runnerFor(SavedHost host);
}

/// The app's source: machines the agent monitor watches through the
/// Conductore companion, plus This computer (desktops) through the local
/// runner. Commands ride the monitor's connection when there is one.
class AttentionUsageHostSource implements UsageHostSource {
  AttentionUsageHostSource({required this.attention, this.hosts})
    : _changes = Listenable.merge([attention, ?hosts]);

  final AgentAttentionController attention;
  final HostsController? hosts;
  final Listenable _changes;

  static const companionProviderId = 'conductore';

  @override
  List<SavedHost> get usageHosts {
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
  List<UsageLimit> liveLimitsFor(String hostId) => currentLoginLimits([
    for (final AgentInfo agent
        in attention.statusFor(hostId)?.agents ?? const <AgentInfo>[])
      [
        for (final limit in agent.usage?.limits ?? const <AgentRateLimit>[])
          UsageLimit.fromAgent(limit, reportedAt: _reportedAt(agent)),
      ],
  ]);

  /// When [agent]'s limits were last reported: its statusline record's
  /// time, or its last state change when later (a session at the same
  /// numbers does not stamp a new record) or the companion is older.
  static DateTime? _reportedAt(AgentInfo agent) {
    final reported = agent.usage?.reportedAt;
    final changed = agent.stateChangedAt;
    if (reported == null || changed == null) {
      return reported ?? changed;
    }
    return changed.isAfter(reported) ? changed : reported;
  }

  @override
  (AgentCommandRunner, {bool owned}) runnerFor(SavedHost host) =>
      attention.runnerFor(host);

  @override
  void addListener(VoidCallback listener) => _changes.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      _changes.removeListener(listener);
}

/// One machine's answer to a [UsageController.query].
class UsageQueryResult {
  const UsageQueryResult({
    required this.hostId,
    required this.hostName,
    this.report,
    this.error,
    this.needsUpdate = false,
  });

  final String hostId;
  final String hostName;
  final UsageReport? report;
  final String? error;

  /// No companion, or one without `usage`.
  final bool needsUpdate;
}

/// Usage of every machine, for the home bar, the Agents panel's Usage tab,
/// the widget and the desktop shell.
///
/// Asks each machine's companion (`conductore-hostd usage`) while at least
/// one view shows usage ([attachView]) and the app is in the foreground:
/// right away when the cached reply is older than [interval], then every
/// [interval], or after [partialInterval] while a machine's first scan is
/// still going. Replies are kept, so reopening a view shows the last
/// numbers at once. Claude's limit windows also come from the agent
/// monitor ([UsageHostSource.liveLimitsFor]), which keeps polling in the
/// background: the 80 % alert ([UsagePreferences.alertEnabled]) works from
/// those, once per 5-hour window.
class UsageController extends ChangeNotifier with WidgetsBindingObserver {
  UsageController({
    required UsageHostSource source,
    UsagePreferencesStore? preferences,
    AgentAttentionNotifier? notifier,
    this.interval = const Duration(seconds: 60),
    this.partialInterval = const Duration(seconds: 5),
    this.unavailableRetry = const Duration(minutes: 10),
    this.commandTimeout = const Duration(seconds: 25),
    this.alertPolicy = const UsageAlertPolicy(),
    DateTime Function()? clock,
    bool observeLifecycle = true,
    this.days = 7,
  }) : _source = source,
       _store = preferences ?? MemoryUsagePreferencesStore(),
       _notifier = notifier,
       _clock = clock ?? DateTime.now,
       _observesLifecycle = observeLifecycle {
    _source.addListener(_onSourceChanged);
    if (observeLifecycle) {
      WidgetsBinding.instance.addObserver(this);
    }
    _syncMachines();
    unawaited(_loadPreferences());
  }

  final UsageHostSource _source;
  final UsagePreferencesStore _store;
  final AgentAttentionNotifier? _notifier;
  final DateTime Function() _clock;
  final bool _observesLifecycle;

  final Duration interval;
  final Duration partialInterval;

  /// How long a machine without a usable companion is left alone.
  final Duration unavailableRetry;
  final Duration commandTimeout;
  final UsageAlertPolicy alertPolicy;

  /// Days of history asked for.
  final int days;

  final Map<String, MachineUsage> _machines = {};
  final Map<String, SavedHost> _hosts = {};
  final Set<String> _inFlight = {};
  UsagePreferences _preferences = const UsagePreferences();
  bool _preferencesLoaded = false;
  int _views = 0;
  bool _appActive = true;
  bool _disposed = false;
  Timer? _timer;

  /// Usage across machines, in source order.
  UsageSummary get summary =>
      UsageSummary([for (final host in _hosts.values) ?_machines[host.id]]);

  UsagePreferences get preferences => _preferences;

  /// Whether a view is showing usage (and polling runs).
  bool get isVisible => _views > 0 && _appActive;

  /// Whether a fetch is running and nothing has arrived yet.
  bool get isLoading =>
      _inFlight.isNotEmpty && !_machines.values.any((m) => m.report != null);

  bool isFetching(String hostId) => _inFlight.contains(hostId);

  /// The saved machine behind [hostId], while it is asked for usage.
  SavedHost? hostFor(String hostId) => _hosts[hostId];

  /// Today on the machines (`YYYY-MM-DD`): the latest any report gave,
  /// else this device's date.
  String get today {
    String? latest;
    for (final machine in _machines.values) {
      final day = machine.report?.today;
      if (day != null &&
          parseUsageDate(day) != null &&
          (latest == null || day.compareTo(latest) > 0)) {
        latest = day;
      }
    }
    return latest ?? formatUsageDate(_clock());
  }

  /// Runs `conductore-hostd <arguments>` (a `usage` command, see
  /// [companionUsageArguments]) on every machine at once, for the usage
  /// explorer. The poll's replies are left alone.
  Future<List<UsageQueryResult>> query(String arguments) async {
    if (_disposed) {
      return const [];
    }
    return Future.wait([
      for (final host in _hosts.values.toList()) _query(host, arguments),
    ]);
  }

  Future<UsageQueryResult> _query(SavedHost host, String arguments) async {
    AgentCommandRunner? runner;
    var owned = false;
    try {
      final (r, owned: o) = _source.runnerFor(host);
      runner = r;
      owned = o;
      final result = await r.run(
        CompanionCommands.hostdCommand(arguments),
        timeout: commandTimeout,
      );
      final report = result.exitCode == null || result.exitCode == 0
          ? parseUsageReport(result.stdout)
          : null;
      if (report != null) {
        return UsageQueryResult(
          hostId: host.id,
          hostName: host.name,
          report: report,
        );
      }
      final output = '${result.stdout}\n${result.stderr}';
      final missing =
          result.exitCode == 127 ||
          output.contains('unknown command') ||
          output.contains('not found');
      return UsageQueryResult(
        hostId: host.id,
        hostName: host.name,
        needsUpdate: missing,
        error: missing ? null : _firstLine(output) ?? 'No usage reply',
      );
    } on Object catch (error) {
      return UsageQueryResult(
        hostId: host.id,
        hostName: host.name,
        error: _firstLine('$error') ?? 'Unreachable',
      );
    } finally {
      if (owned) {
        unawaited(runner?.close());
      }
    }
  }

  /// Remembers the usage explorer's range and measure on this device.
  Future<void> setExplorerPreferences({
    UsageRangePreset? range,
    UsageDateRange? custom,
    UsageMetric? metric,
  }) => _savePreferences(
    _preferences.copyWith(
      explorerRange: range,
      explorerCustom: custom,
      explorerMetric: metric,
    ),
  );

  /// Call when a widget that shows usage appears; call the returned
  /// function when it goes away. Polling runs while any view is attached.
  /// With [refresh] (the usage screen, the accounts card) every machine is
  /// asked now, cswap included ([refresh]), whatever the cached replies'
  /// age: a view opened to look at the numbers never starts on old ones.
  VoidCallback attachView({bool refresh = false}) {
    _views++;
    if (refresh) {
      scheduleMicrotask(() {
        if (!_disposed && _views > 0) {
          unawaited(this.refresh());
        }
      });
    } else if (_views == 1) {
      // Views attach while they build: start after this frame's work.
      scheduleMicrotask(() {
        if (!_disposed && _views > 0 && _timer == null && _inFlight.isEmpty) {
          _reschedule(immediate: true);
        }
      });
    }
    var detached = false;
    return () {
      if (detached) {
        return;
      }
      detached = true;
      _views--;
      if (_views == 0) {
        _timer?.cancel();
        _timer = null;
      }
    };
  }

  /// Pauses polling while the app is in the background.
  void setAppActive(bool active) {
    if (_appActive == active || _disposed) {
      return;
    }
    _appActive = active;
    if (active) {
      _reschedule(immediate: true);
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      setAppActive(state == AppLifecycleState.resumed);

  /// Asks every machine now (pull to refresh, the Usage tab's button,
  /// a usage screen opening), and the companion asks cswap again rather
  /// than answer from its 60 s cache (`usage --fresh`).
  Future<void> refresh() => _pollAll(force: true, fresh: true);

  Future<void> setAlertEnabled(bool enabled) async {
    // Turning it on while already past the threshold alerts right away;
    // turning it off forgets nothing (the window stays alerted).
    await _savePreferences(_preferences.copyWith(alertEnabled: enabled));
    _evaluateAlert();
  }

  /// Makes account [slot] (or, with [best], the one cswap finds has the
  /// most headroom) the Claude account for new sessions on [hostId]
  /// (`cswap switch` through the companion), then asks that machine for
  /// usage again. Callers confirm first.
  Future<UsageAccountSwitchResult> switchAccount(
    String hostId, {
    int? slot,
    bool best = false,
  }) async {
    final host = _hosts[hostId];
    if (host == null || _disposed) {
      return const UsageAccountSwitchResult.failed('Machine not found');
    }
    assert(best || slot != null, 'a slot or best');
    AgentCommandRunner? runner;
    var owned = false;
    try {
      final (r, owned: o) = _source.runnerFor(host);
      runner = r;
      owned = o;
      final result = await r.run(
        CompanionCommands.hostdCommand(
          best ? 'cswap-switch --best' : 'cswap-switch $slot',
        ),
        timeout: commandTimeout,
      );
      return parseAccountSwitchResult(result.stdout);
    } on Object catch (error) {
      return UsageAccountSwitchResult.failed(
        _firstLine('$error') ?? 'Unreachable',
      );
    } finally {
      if (owned) {
        unawaited(runner?.close());
      }
      // The companion forgot its account cache: show the new state.
      if (!_disposed) {
        unawaited(_fetch(host));
      }
    }
  }

  Future<void> setBarCollapsed(bool collapsed) =>
      _savePreferences(_preferences.copyWith(barCollapsed: collapsed));

  Future<void> _loadPreferences() async {
    final loaded = await _store.load();
    if (_disposed) {
      return;
    }
    _preferences = loaded;
    _preferencesLoaded = true;
    notifyListeners();
    _evaluateAlert();
  }

  Future<void> _savePreferences(UsagePreferences next) async {
    _preferences = next;
    if (!_disposed) {
      notifyListeners();
    }
    try {
      await _store.save(next);
    } on Object {
      // Kept for this run; storage is best effort.
    }
  }

  void _onSourceChanged() {
    if (_disposed) {
      return;
    }
    final added = _syncMachines();
    if (isVisible) {
      for (final host in added) {
        unawaited(_fetch(host));
      }
    }
  }

  /// Follows the source's machine list and live limits. Returns the hosts
  /// that are new.
  List<SavedHost> _syncMachines() {
    final hosts = _source.usageHosts;
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
      final live = _source.liveLimitsFor(host.id);
      final known = _machines[host.id];
      if (known == null) {
        added.add(host);
        _machines[host.id] = MachineUsage(
          hostId: host.id,
          hostName: host.name,
          liveLimits: live,
        );
        changed = true;
      } else if (known.hostName != host.name ||
          !listEquals(known.liveLimits, live)) {
        _machines[host.id] = known.copyWith(
          hostName: host.name,
          liveLimits: live,
        );
        changed = true;
      }
      _hosts[host.id] = host;
    }
    if (changed) {
      notifyListeners();
      _evaluateAlert();
    }
    return added;
  }

  void _reschedule({bool immediate = false}) {
    _timer?.cancel();
    _timer = null;
    if (!isVisible || _disposed) {
      return;
    }
    if (immediate) {
      // Cached replies younger than the interval are shown as they are.
      final now = _clock();
      final stale = _machines.values.any(
        (m) =>
            m.fetchedAt == null ||
            now.difference(m.fetchedAt!) >= interval ||
            (m.report?.partial ?? false),
      );
      if (stale) {
        unawaited(_pollAll());
        return;
      }
    }
    final partial = _machines.values.any((m) => m.report?.partial ?? false);
    _timer = Timer(partial ? partialInterval : interval, () {
      _timer = null;
      unawaited(_pollAll());
    });
  }

  Future<void> _pollAll({bool force = false, bool fresh = false}) async {
    if (_disposed) {
      return;
    }
    final now = _clock();
    await Future.wait([
      for (final host in _hosts.values.toList())
        if (force || _due(_machines[host.id], now)) _fetch(host, fresh: fresh),
    ]);
    if (!_disposed) {
      _reschedule();
    }
  }

  bool _due(MachineUsage? machine, DateTime now) {
    if (machine == null || machine.fetchedAt == null) {
      return true;
    }
    final age = now.difference(machine.fetchedAt!);
    if (machine.needsUpdate) {
      return age >= unavailableRetry;
    }
    if (machine.report?.partial ?? false) {
      return age >= partialInterval;
    }
    // A little slack so a timer firing a hair early still polls.
    return age >= interval - const Duration(seconds: 1);
  }

  Future<void> _fetch(SavedHost host, {bool fresh = false}) async {
    if (_disposed || !_inFlight.add(host.id)) {
      return;
    }
    notifyListeners();
    AgentCommandRunner? runner;
    var owned = false;
    try {
      final (r, owned: o) = _source.runnerFor(host);
      runner = r;
      owned = o;
      final result = await r.run(
        CompanionCommands.hostdCommand(
          companionUsageArguments(days: days, fresh: fresh),
        ),
        timeout: commandTimeout,
      );
      // Some runners report no exit status: the reply itself decides.
      final report = result.exitCode == null || result.exitCode == 0
          ? parseUsageReport(result.stdout)
          : null;
      _update(host, (machine) {
        if (report != null) {
          return machine.copyWith(
            report: report,
            clearError: true,
            needsUpdate: false,
            fetchedAt: _clock(),
          );
        }
        // An older companion does not know the command; no companion at
        // all is "command not found" (127).
        final output = '${result.stdout}\n${result.stderr}';
        final missing =
            result.exitCode == 127 ||
            output.contains('unknown command') ||
            output.contains('not found');
        return machine.copyWith(
          error: missing ? null : _firstLine(output) ?? 'No usage reply',
          needsUpdate: missing,
          fetchedAt: _clock(),
        );
      });
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
      if (owned) {
        unawaited(runner?.close());
      }
      if (!_disposed) {
        notifyListeners();
      }
    }
  }

  void _update(SavedHost host, MachineUsage Function(MachineUsage) change) {
    final machine = _machines[host.id];
    if (_disposed || machine == null) {
      return;
    }
    _machines[host.id] = change(machine);
    _evaluateAlert();
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

  void _evaluateAlert() {
    if (!_preferencesLoaded || !_preferences.alertEnabled || _disposed) {
      return;
    }
    final alert = alertPolicy.evaluate(
      fiveHour: summary.fiveHour,
      now: _clock(),
      alerted: _preferences.alertedWindow,
    );
    if (alert == null) {
      return;
    }
    unawaited(
      _savePreferences(_preferences.copyWith(alertedWindow: alert.window)),
    );
    final notifier = _notifier;
    if (notifier != null) {
      unawaited(
        notifier
            .show(
              id: UsageAlert.notificationId,
              title: alert.title,
              body: alert.body,
            )
            .catchError((Object _) {}),
      );
    }
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
