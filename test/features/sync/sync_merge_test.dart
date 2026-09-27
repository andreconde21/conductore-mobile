import 'package:conduit/features/sync/domain/canonical_json.dart';
import 'package:conduit/features/sync/domain/sync_category.dart';
import 'package:conduit/features/sync/domain/sync_merge.dart';
import 'package:conduit/features/sync/domain/sync_record.dart';
import 'package:flutter_test/flutter_test.dart';

const _all = {...SyncCategory.values};

SyncRecord _rec(
  String key,
  Object? value,
  int time, {
  int c = 1,
  String d = 'other',
}) => SyncRecord(
  key: key,
  value: value,
  clock: SyncClock(time: time, counter: c, device: d),
);

/// The base a device keeps after syncing [records] and applying them.
Map<String, SyncBaseEntry> _base(List<SyncRecord> records) => {
  for (final r in records)
    r.key: SyncBaseEntry(record: r, localHash: valueHash(r.value)),
};

SyncMergeResult _merge({
  Map<String, SyncBaseEntry> base = const {},
  Map<String, Object?> local = const {},
  Map<String, SyncRecord>? remote,
  Set<SyncCategory> enabled = _all,
  Set<SyncCategory> initialized = _all,
  int now = 1000,
}) => mergeSync(
  base: base,
  local: local,
  enabled: enabled,
  initialized: initialized,
  remote: remote,
  deviceId: 'me',
  now: now,
  counter: 0,
);

void main() {
  final hostA = SyncKeys.host('a');
  final theme = SyncKeys.setting('themeMode');

  test('the first push stamps every local record', () {
    final result = _merge(
      local: {
        hostA: {'name': 'A'},
        theme: 'dark',
      },
      initialized: {},
    );
    expect(result.pushNeeded, isTrue);
    expect(result.toApply, isEmpty);
    expect(result.merged[hostA]!.clock.device, 'me');
    expect(result.merged[hostA]!.clock.time, 1000);
    expect(result.localEdits, {hostA, theme});
  });

  test('nothing changed means nothing to push or apply', () {
    final synced = [
      _rec(hostA, {'name': 'A'}, 500),
    ];
    final result = _merge(
      base: _base(synced),
      local: {
        hostA: {'name': 'A'},
      },
      remote: {for (final r in synced) r.key: r},
    );
    expect(result.pushNeeded, isFalse);
    expect(result.toApply, isEmpty);
    expect(result.conflicts, isEmpty);
  });

  test('a local edit is pushed and a remote edit is applied', () {
    final synced = [
      _rec(hostA, {'name': 'A'}, 500),
      _rec(theme, 'dark', 500),
    ];
    final result = _merge(
      base: _base(synced),
      local: {
        hostA: {'name': 'A2'},
        theme: 'dark',
      },
      remote: {hostA: synced[0], theme: _rec(theme, 'light', 800)},
    );
    expect(result.merged[hostA]!.value, {'name': 'A2'});
    expect(result.merged[hostA]!.clock.device, 'me');
    expect(result.toApply, {theme: 'light'});
    expect(result.pushNeeded, isTrue);
    expect(result.conflicts, isEmpty);
  });

  test('a local delete becomes a tombstone that wins over the older copy', () {
    final synced = [
      _rec(hostA, {'name': 'A'}, 500),
    ];
    final result = _merge(base: _base(synced), remote: {hostA: synced.single});
    expect(result.merged[hostA]!.deleted, isTrue);
    expect(result.pushNeeded, isTrue);
    expect(result.toApply, isEmpty);
  });

  test('a remote tombstone deletes the local copy', () {
    final synced = [
      _rec(hostA, {'name': 'A'}, 500),
    ];
    final result = _merge(
      base: _base(synced),
      local: {
        hostA: {'name': 'A'},
      },
      remote: {hostA: _rec(hostA, null, 900)},
    );
    expect(result.toApply, {hostA: null});
    expect(result.pushNeeded, isFalse);
  });

  test('an edit after a remote delete brings the item back', () {
    final synced = [
      _rec(hostA, {'name': 'A'}, 500),
    ];
    final result = _merge(
      base: _base(synced),
      local: {
        hostA: {'name': 'A edited'},
      },
      remote: {hostA: _rec(hostA, null, 900)},
    );
    expect(result.merged[hostA]!.value, {'name': 'A edited'});
    expect(result.conflicts.single.keptLocal, isTrue);
    expect(result.conflicts.single.lostValue, isNull);
  });

  test('concurrent edits: the newer wins and the loser is kept', () {
    final synced = [
      _rec(hostA, {'name': 'A'}, 500),
    ];
    final result = _merge(
      base: _base(synced),
      local: {
        hostA: {'name': 'mine'},
      },
      remote: {
        hostA: _rec(hostA, {'name': 'theirs'}, 2000),
      },
    );
    expect(result.merged[hostA]!.value, {'name': 'theirs'});
    expect(result.toApply, {
      hostA: {'name': 'theirs'},
    });
    final conflict = result.conflicts.single;
    expect(conflict.kind, SyncConflictKind.concurrentEdit);
    expect(conflict.keptLocal, isFalse);
    expect(conflict.lostValue, {'name': 'mine'});
    expect(conflict.remoteDevice, 'other');
  });

  test('concurrent edits: a newer local edit wins and is pushed', () {
    final synced = [
      _rec(hostA, {'name': 'A'}, 500),
    ];
    final result = _merge(
      base: _base(synced),
      local: {
        hostA: {'name': 'mine'},
      },
      remote: {
        hostA: _rec(hostA, {'name': 'theirs'}, 700),
      },
    );
    expect(result.merged[hostA]!.value, {'name': 'mine'});
    expect(result.toApply, isEmpty);
    expect(result.pushNeeded, isTrue);
    expect(result.conflicts.single.keptLocal, isTrue);
    expect(result.conflicts.single.lostValue, {'name': 'theirs'});
  });

  test('equal times fall to the Lamport counter, then the device id', () {
    final a = _rec(hostA, 1, 100, c: 5, d: 'a');
    final b = _rec(hostA, 2, 100, c: 6, d: 'a');
    final c = _rec(hostA, 3, 100, c: 6, d: 'b');
    expect(SyncRecord.newer(a, b), same(b));
    expect(SyncRecord.newer(b, c), same(c));
    expect(SyncRecord.newer(c, b), same(c));
  });

  test('an edit beats the version it replaces even if the clock went back', () {
    final synced = [
      _rec(hostA, {'name': 'A'}, 5000, d: 'me'),
    ];
    final result = _merge(
      base: _base(synced),
      local: {
        hostA: {'name': 'B'},
      },
      remote: {hostA: synced.single},
    );
    expect(result.merged[hostA]!.clock.time, 5001);
    expect(result.merged[hostA]!.value, {'name': 'B'});
  });

  test('the Lamport counter moves past every counter seen', () {
    final result = _merge(
      local: {hostA: 1},
      remote: {theme: _rec(theme, 'dark', 10, c: 41)},
    );
    expect(result.merged[hostA]!.clock.counter, 42);
    expect(result.counter, 42);
  });

  test('disabled categories pass through untouched', () {
    final synced = [_rec(theme, 'dark', 500)];
    final result = _merge(
      base: _base(synced),
      local: {hostA: 1},
      remote: {theme: _rec(theme, 'light', 900)},
      enabled: {SyncCategory.machines},
    );
    expect(result.merged[theme]!.value, 'light');
    expect(result.toApply.containsKey(theme), isFalse);
  });

  test('records from a newer app are kept and never applied', () {
    final future = _rec('widget:clock', {'x': 1}, 500);
    final result = _merge(base: _base([future]), remote: {future.key: future});
    expect(result.merged[future.key], same(future));
    expect(result.toApply, isEmpty);
    expect(result.pushNeeded, isFalse);
  });

  test('first sync against a hub: the hub wins, local extras are added', () {
    final hostB = SyncKeys.host('b');
    final result = _merge(
      local: {
        hostA: {'name': 'mine'},
        hostB: {'name': 'only here'},
      },
      remote: {
        hostA: _rec(hostA, {'name': 'hub'}, 10),
      },
      initialized: {},
    );
    expect(result.toApply, {
      hostA: {'name': 'hub'},
    });
    expect(result.merged[hostB]!.value, {'name': 'only here'});
    expect(result.merged[hostB]!.clock, SyncClock.unknown);
    expect(result.pushNeeded, isTrue);
    final conflict = result.conflicts.single;
    expect(conflict.kind, SyncConflictKind.firstSync);
    expect(conflict.lostValue, {'name': 'mine'});
  });

  test('a category turned on again takes the stored copy over local', () {
    final stored = _rec(theme, 'light', 500);
    final result = _merge(
      base: {theme: SyncBaseEntry(record: stored)},
      local: {theme: 'dark'},
      remote: {theme: stored},
    );
    expect(result.toApply, {theme: 'light'});
    expect(result.pushNeeded, isFalse);
  });

  test('tombstones older than their lifetime are dropped', () {
    const day = 24 * 60 * 60 * 1000;
    final old = _rec(hostA, null, 1);
    final result = _merge(
      base: {hostA: SyncBaseEntry(record: old)},
      remote: {hostA: old},
      now: 200 * day,
    );
    expect(result.merged.containsKey(hostA), isFalse);
    expect(result.pushNeeded, isTrue);
  });

  test('document JSON round trip keeps records and refuses newer formats', () {
    final doc = SyncDocument(
      records: {
        hostA: _rec(hostA, {'name': 'A'}, 5),
        theme: _rec(theme, null, 6),
      },
      revision: 7,
      vaultId: 'v',
      deviceId: 'me',
    );
    final back = SyncDocument.fromJson(doc.toJson());
    expect(back.revision, 7);
    expect(back.vaultId, 'v');
    expect(back.records[hostA]!.value, {'name': 'A'});
    expect(back.records[theme]!.deleted, isTrue);
    expect(
      () => SyncDocument.fromJson({...doc.toJson(), 'version': 2}),
      throwsA(isA<SyncFormatException>()),
    );
    expect(
      () => SyncDocument.fromJson({'format': 'x'}),
      throwsA(isA<SyncFormatException>()),
    );
  });

  test('canonical JSON ignores key order', () {
    expect(
      valueHash({
        'a': 1,
        'b': [
          1,
          {'y': 1, 'x': 2},
        ],
      }),
      valueHash({
        'b': [
          1,
          {'x': 2, 'y': 1},
        ],
        'a': 1,
      }),
    );
    expect(valueHash({'a': 1}), isNot(valueHash({'a': 2})));
  });

  group('a category turned back on', () {
    // Synced as 'dark' at t=100, then the category was turned off here.
    final synced = _rec(theme, 'dark', 100);
    Map<String, SyncBaseEntry> paused(SyncRecord hub) => {
      theme: SyncBaseEntry(
        record: hub,
        localHash: valueHash('dark'),
        pausedClock: synced.clock,
      ),
    };

    test('keeps an edit made here when the hub did not change', () {
      final result = _merge(
        base: paused(synced),
        local: {theme: 'light'},
        remote: {theme: synced},
      );
      expect(result.merged[theme]!.value, 'light');
      expect(result.toApply, isEmpty);
      expect(result.conflicts, isEmpty);
    });

    test('takes a change made elsewhere when nothing changed here', () {
      final hub = _rec(theme, 'system', 200);
      final result = _merge(
        base: paused(hub),
        local: {theme: 'dark'},
        remote: {theme: hub},
      );
      expect(result.toApply, {theme: 'system'});
      expect(result.conflicts, isEmpty);
    });

    test('both changed: the hub wins and this edit stays restorable', () {
      final hub = _rec(theme, 'system', 200);
      final result = _merge(
        base: paused(hub),
        local: {theme: 'light'},
        remote: {theme: hub},
        now: 5000,
      );
      expect(result.toApply, {theme: 'system'});
      final conflict = result.conflicts.single;
      expect(conflict.kind, SyncConflictKind.concurrentEdit);
      expect(conflict.keptLocal, isFalse);
      expect(conflict.lostValue, 'light');
    });

    test('the paused clock survives the saved base', () {
      final entry = paused(synced)[theme]!;
      final back = SyncBaseEntry.fromJson(entry.toJson())!;
      expect(back.pausedClock, synced.clock);
      expect(back.localHash, entry.localHash);
    });
  });
}
