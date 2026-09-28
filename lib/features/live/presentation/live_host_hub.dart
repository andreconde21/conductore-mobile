// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';

import 'package:conduit/features/agent_attention/data/conductore_host_attention_provider.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/live/domain/live_host_model.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:flutter/foundation.dart';

/// Whether a machine's companion pushes its Herdr and tmux state.
enum LiveSupport {
  /// Not asked yet (or asking): callers wait before polling.
  unknown,

  /// Pushed: callers stop their own polling and read [LiveHostFeed.model].
  supported,

  /// No companion, or one without `live`: callers poll as before.
  unsupported,
}

/// One machine's pushed Herdr and tmux state (`docs/herdr-live.md`).
///
/// While someone holds it ([acquire]) it asks `status --live` once, then
/// long-polls `events --live --only live`: an idle machine costs about one
/// command a minute however many boards, tab strips and navigators read
/// it. The last [acquire] released closes its connection. An older
/// companion, or none, makes it [LiveSupport.unsupported] for this run,
/// and callers poll as they always did.
class LiveHostFeed extends ChangeNotifier {
  LiveHostFeed({
    required this.host,
    required AgentCommandRunner Function() runnerFactory,
    this.restartDelay = const Duration(milliseconds: 500),
    this.retryDelays = const [
      Duration(seconds: 5),
      Duration(seconds: 15),
      Duration(seconds: 60),
    ],
  }) : _runnerFactory = runnerFactory;

  final SavedHost host;
  final AgentCommandRunner Function() _runnerFactory;

  /// Pause between two long-polls, so a machine that answers at once
  /// cannot spin the loop.
  final Duration restartDelay;

  /// Waits after failures in a row (the last one repeats).
  final List<Duration> retryDelays;

  static const _statusTimeout = Duration(seconds: 15);
  static const _watchTimeout = Duration(seconds: 70);

  /// Failures in a row after which support is asked again from scratch.
  static const _maxFailures = 3;

  LiveSupport _support = LiveSupport.unknown;
  LiveHostModel _model = const LiveHostModel();
  int? _sequence;
  int _holders = 0;
  int _generation = 0;
  bool _running = false;
  bool _disposed = false;
  AgentCommandRunner? _runner;

  LiveSupport get support => _support;
  LiveHostModel get model => _model;

  /// Whether the model reflects the machine (support is known and the
  /// first reply arrived).
  bool get ready => _support == LiveSupport.supported;

  /// Commands run, for the tests' counts.
  @visibleForTesting
  int commands = 0;

  /// Starts (or keeps) the feed; the returned callback lets go.
  VoidCallback acquire() {
    // Asked again after everyone let go (the page came back): a companion
    // installed or updated meanwhile gets its chance.
    if (_holders == 0 && _support == LiveSupport.unsupported && !_running) {
      _support = LiveSupport.unknown;
      _sequence = null;
    }
    _holders += 1;
    if (!_running && _support != LiveSupport.unsupported) {
      unawaited(_loop());
    }
    var released = false;
    return () {
      if (released) return;
      released = true;
      _holders -= 1;
      if (_holders <= 0) {
        _holders = 0;
        _stop();
      }
    };
  }

  void _stop() {
    _generation += 1;
    final runner = _runner;
    _runner = null;
    if (runner != null) unawaited(runner.close().catchError((_) {}));
  }

  Future<void> _loop() async {
    _running = true;
    final generation = _generation;
    var failures = 0;
    try {
      while (!_disposed && _holders > 0 && generation == _generation) {
        try {
          final runner = _runner ??= _runnerFactory();
          if (_sequence == null) {
            await _status(runner);
          } else {
            await _watch(runner);
          }
          failures = 0;
          if (_support == LiveSupport.unsupported) return;
          if (restartDelay > Duration.zero) {
            await Future<void>.delayed(restartDelay);
          }
        } on _Unsupported {
          _setSupport(LiveSupport.unsupported);
          return;
        } catch (_) {
          if (_disposed || generation != _generation) return;
          if (_support == LiveSupport.unknown) {
            // Nothing pushed yet: callers poll rather than wait.
            _setSupport(LiveSupport.unsupported);
            return;
          }
          failures += 1;
          // A broken connection reconnects on the next command.
          final runner = _runner;
          _runner = null;
          if (runner != null) unawaited(runner.close().catchError((_) {}));
          if (failures >= _maxFailures) _sequence = null;
          final wait =
              retryDelays[(failures - 1).clamp(0, retryDelays.length - 1)];
          await Future<void>.delayed(wait);
        }
      }
    } finally {
      _running = false;
      // Taken again while the last poll ran out.
      if (!_disposed && _holders > 0 && _support != LiveSupport.unsupported) {
        unawaited(_loop());
      }
    }
  }

  Future<void> _status(AgentCommandRunner runner) async {
    commands += 1;
    final result = await runner.run(
      ConductoreHostAttentionProvider.remoteCommand('status --live'),
      timeout: _statusTimeout,
    );
    if (result.exitCode == 127) throw const _Unsupported();
    if (result.exitCode != null && result.exitCode != 0) {
      throw StateError('status failed');
    }
    final Object? reply;
    try {
      reply = jsonDecode(result.stdout.trim());
    } catch (_) {
      throw StateError('status is not JSON');
    }
    if (reply is! Map) throw StateError('status is not an object');
    final live = reply['live'];
    if (live is! Map) {
      // A companion without the bridge answers without `live`.
      throw const _Unsupported();
    }
    final entities = live['entities'];
    _model = LiveHostModel.fromEntities(entities is Map ? entities : const {});
    final seq = reply['seq'];
    _sequence = seq is int ? seq : 0;
    _setSupport(LiveSupport.supported, force: true);
  }

  Future<void> _watch(AgentCommandRunner runner) async {
    commands += 1;
    final timeout = ConductoreHostAttentionProvider.watchTimeout.inSeconds;
    final result = await runner.run(
      ConductoreHostAttentionProvider.remoteCommand(
        'events --since $_sequence --timeout $timeout --live --only live',
      ),
      timeout: _watchTimeout,
    );
    if (result.exitCode == 127) throw const _Unsupported();
    if (result.exitCode != null && result.exitCode != 0) {
      throw StateError('events failed');
    }
    final parsed = parseLiveEvents(result.stdout);
    var model = parsed.snapshot ?? _model;
    var sequence = parsed.snapshotSequence ?? _sequence;
    final fresh = [
      for (final change in parsed.changes)
        if (sequence == null || change.sequence > sequence) change,
    ];
    model = model.apply(fresh);
    for (final change in fresh) {
      sequence = change.sequence;
    }
    // Nothing this feed asked for happened up to there.
    if (parsed.timeoutSequence case final seen?
        when sequence == null || seen > sequence) {
      sequence = seen;
    }
    _sequence = sequence;
    if (parsed.snapshot != null || fresh.isNotEmpty) {
      _model = model;
      notifyListeners();
    }
  }

  void _setSupport(LiveSupport support, {bool force = false}) {
    if (_support == support && !force) return;
    _support = support;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _stop();
    super.dispose();
  }
}

class _Unsupported implements Exception {
  const _Unsupported();
}

/// What one `events --live` reply carries.
typedef LiveEvents = ({
  LiveHostModel? snapshot,
  int? snapshotSequence,
  List<LiveChange> changes,
  int? timeoutSequence,
});

/// Parses `events --live` output: `live` lines, a `snapshot` line (with its
/// `live` block) replacing everything before it, a `timeout` line. Agent
/// lines and unknown types are skipped.
LiveEvents parseLiveEvents(String raw) {
  LiveHostModel? snapshot;
  int? snapshotSequence;
  int? timeoutSequence;
  var changes = <LiveChange>[];
  for (final line in const LineSplitter().convert(raw)) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    final Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } catch (_) {
      continue;
    }
    if (decoded is! Map) continue;
    final seq = decoded['seq'];
    switch (decoded['type']) {
      case 'live':
        final key = decoded['key'];
        final entity = decoded['entity'];
        if (key is String && seq is int) {
          changes.add(
            LiveChange(
              sequence: seq,
              key: key,
              entity: entity is Map
                  ? {
                      for (final MapEntry(:key, :value) in entity.entries)
                        if (key is String) key: value,
                    }
                  : null,
            ),
          );
        }
      case 'snapshot':
        final live = decoded['live'];
        final entities = live is Map ? live['entities'] : null;
        snapshot = LiveHostModel.fromEntities(
          entities is Map ? entities : const {},
        );
        snapshotSequence = seq is int ? seq : null;
        changes = [];
      case 'timeout':
        if (seq is int) timeoutSequence = seq;
      default:
        break;
    }
  }
  return (
    snapshot: snapshot,
    snapshotSequence: snapshotSequence,
    changes: changes,
    timeoutSequence: timeoutSequence,
  );
}

/// One [LiveHostFeed] per machine, shared by the home board, the tab strips
/// and the navigator.
class LiveHostHub {
  LiveHostHub({required AgentCommandRunnerFactory runnerFactory})
    : _runnerFactory = runnerFactory;

  final AgentCommandRunnerFactory _runnerFactory;
  final Map<String, LiveHostFeed> _feeds = {};

  /// The feed of [host] (local machines have none).
  LiveHostFeed? feedFor(SavedHost host) {
    if (host.isLocal) return null;
    // Sessions carry their target in the id; the machine is the key.
    return _feeds.putIfAbsent(
      baseHostId(host.id),
      () => LiveHostFeed(host: host, runnerFactory: () => _runnerFactory(host)),
    );
  }

  /// The feed of [hostId] if one exists.
  LiveHostFeed? operator [](String hostId) => _feeds[baseHostId(hostId)];

  void dispose() {
    for (final feed in _feeds.values) {
      feed.dispose();
    }
    _feeds.clear();
  }
}
