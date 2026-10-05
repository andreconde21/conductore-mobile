import 'dart:async';

import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/terminal/domain/mosh_server_cleanup.dart';
import 'package:flutter/foundation.dart';

/// A mosh-server this device started, as remembered between app runs.
@immutable
class MoshServerLedgerEntry {
  const MoshServerLedgerEntry({
    required this.machine,
    required this.pid,
    required this.port,
    required this.seenAt,
  });

  /// [MoshServerLedger.machineOf] the machine it runs on.
  final String machine;
  final int pid;
  final int port;

  /// When a client of this device last used it (its start, or the close).
  final DateTime seenAt;

  MoshServerHandle get handle => MoshServerHandle(port: port, pid: pid);

  Map<String, Object?> toJson() => {
    'machine': machine,
    'pid': pid,
    'port': port,
    'seenAt': seenAt.toUtc().toIso8601String(),
  };

  static MoshServerLedgerEntry? fromJson(Object? json) {
    if (json is! Map) return null;
    final machine = json['machine'];
    final pid = json['pid'];
    final port = json['port'];
    final seenAt = DateTime.tryParse('${json['seenAt']}');
    if (machine is! String || pid is! int || port is! int || seenAt == null) {
      return null;
    }
    return MoshServerLedgerEntry(
      machine: machine,
      pid: pid,
      port: port,
      seenAt: seenAt,
    );
  }
}

/// Where the ledger is kept between app runs.
abstract interface class MoshServerLedgerStore {
  Future<List<MoshServerLedgerEntry>> load();

  Future<void> save(List<MoshServerLedgerEntry> entries);
}

/// A [MoshServerLedgerStore] that lives only as long as the app run.
class InMemoryMoshServerLedgerStore implements MoshServerLedgerStore {
  final entries = <MoshServerLedgerEntry>[];

  @override
  Future<List<MoshServerLedgerEntry>> load() async => List.of(entries);

  @override
  Future<void> save(List<MoshServerLedgerEntry> entries) async {
    this.entries
      ..clear()
      ..addAll(entries);
  }
}

/// The mosh-servers this device started and has not seen end, so a later
/// connection to the same machine can end the ones nobody uses any more.
///
/// A server's client can go away without ending it: the app is killed in
/// the background (iOS does that), quits, or loses the network while it
/// closes the session. dart_mosh cannot resume a session from a new
/// client, so such a server is never used again. Each one is [record]ed
/// when it starts and [forget]ten once it is known to have ended; one
/// [release]d by its client stays until then. [abandoned] lists, for a
/// machine, the ones no session of this app run holds: the next
/// mosh-server bootstrap on that machine ends them first.
class MoshServerLedger {
  MoshServerLedger(this._store, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final MoshServerLedgerStore _store;
  final DateTime Function() _clock;

  /// Servers older than this are dropped unseen: mosh-server has ended on
  /// its own by then ([moshServerNetworkTimeout] without a client), and
  /// the pid may have been reused.
  static final keptFor = moshServerNetworkTimeout * 2;

  /// At most this many are kept per machine (the newest).
  static const maxPerMachine = 64;

  /// Held by a session of this app run: never [abandoned].
  final _live = <(String, int)>{};

  Future<List<MoshServerLedgerEntry>>? _entries;
  Future<void> _writes = Future.value();

  /// Who and where a server runs: the user it was started as, on which
  /// host and SSH port.
  static String machineOf(SavedHost host) =>
      '${host.username}@${host.host.trim().toLowerCase()}:${host.port}';

  Future<List<MoshServerLedgerEntry>> _load() => _entries ??= () async {
    try {
      return await _store.load();
    } catch (_) {
      return <MoshServerLedgerEntry>[];
    }
  }();

  /// Runs [change] on the entries, one change at a time, and saves them.
  Future<void> _update(void Function(List<MoshServerLedgerEntry>) change) {
    final next = _writes.then((_) async {
      final entries = await _load();
      change(entries);
      final cutoff = _clock().subtract(keptFor);
      entries.removeWhere((entry) => entry.seenAt.isBefore(cutoff));
      final perMachine = <String, int>{};
      for (var i = entries.length - 1; i >= 0; i--) {
        final count = perMachine[entries[i].machine] =
            (perMachine[entries[i].machine] ?? 0) + 1;
        if (count > maxPerMachine) entries.removeAt(i);
      }
      try {
        await _store.save(List.of(entries));
      } catch (_) {
        // Best effort: the safety net is mosh-server's own timeout.
      }
    });
    _writes = next.catchError((Object _) {});
    return _writes;
  }

  /// A session of this run started [handle] on [machine].
  Future<void> record(String machine, MoshServerHandle handle) {
    final pid = handle.pid;
    if (pid == null) return Future.value();
    _live.add((machine, pid));
    return _update((entries) {
      entries
        ..removeWhere((entry) => entry.machine == machine && entry.pid == pid)
        ..add(
          MoshServerLedgerEntry(
            machine: machine,
            pid: pid,
            port: handle.port,
            seenAt: _clock(),
          ),
        );
    });
  }

  /// Its session let go of [pid] on [machine] without seeing it end.
  Future<void> release(String machine, int pid) {
    _live.remove((machine, pid));
    return _update((entries) {
      final index = entries.indexWhere(
        (entry) => entry.machine == machine && entry.pid == pid,
      );
      if (index == -1) return;
      final entry = entries[index];
      entries[index] = MoshServerLedgerEntry(
        machine: machine,
        pid: pid,
        port: entry.port,
        seenAt: _clock(),
      );
    });
  }

  /// [pids] on [machine] have ended (or were just told to).
  Future<void> forget(String machine, Iterable<int> pids) {
    final ended = pids.toSet();
    if (ended.isEmpty) return Future.value();
    _live.removeAll([for (final pid in ended) (machine, pid)]);
    return _update(
      (entries) => entries.removeWhere(
        (entry) => entry.machine == machine && ended.contains(entry.pid),
      ),
    );
  }

  /// The servers on [machine] no session of this run holds.
  Future<List<MoshServerHandle>> abandoned(String machine) async {
    await _writes;
    final cutoff = _clock().subtract(keptFor);
    return [
      for (final entry in await _load())
        if (entry.machine == machine &&
            !_live.contains((machine, entry.pid)) &&
            !entry.seenAt.isBefore(cutoff))
          entry.handle,
    ];
  }
}
