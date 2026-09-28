// Startup benchmark: runs the real main() against a secure storage that
// behaves like Android's (one worker thread answers every call in turn,
// plus a hop each way), and reports when the user's theme shows, when the
// home page has its machines, and how many reads stood in the way.
//
// The storage timings are a model (4 ms of worker time per call, 2 ms of
// channel hops), so the numbers compare startup orderings, not devices.
import 'dart:convert';

import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/main.dart' as app;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'perf_probe.dart';

const _workerMs = 4;
const _hopMs = 2;

class _ModelStorage {
  _ModelStorage(this.values);

  final Map<String, String> values;
  final List<({String key, int issued, int done})> reads = [];
  var _tail = Future<void>.value();
  int now = 0;

  Future<Object?> handle(MethodCall call) async {
    final key = (call.arguments as Map?)?['key'] as String?;
    final issued = now;
    await Future<void>.delayed(const Duration(milliseconds: _hopMs ~/ 2));
    final slot = _tail.then(
      (_) => Future<void>.delayed(const Duration(milliseconds: _workerMs)),
    );
    _tail = slot;
    await slot;
    await Future<void>.delayed(const Duration(milliseconds: _hopMs ~/ 2));
    switch (call.method) {
      case 'read':
        reads.add((key: key ?? '', issued: issued, done: now));
        return values[key];
      case 'write':
        values[key!] = (call.arguments as Map)['value'] as String;
        return null;
      case 'delete':
        values.remove(key);
        return null;
      case 'containsKey':
        return values.containsKey(key);
      case 'readAll':
        return values;
    }
    return null;
  }
}

void main() {
  testWidgets('startup: theme, lock page and home with machines', (
    tester,
  ) async {
    final hosts = [
      for (var i = 0; i < 5; i++)
        SavedHost(
          id: 'host-$i',
          name: 'Machine $i',
          host: '192.0.2.${i + 1}',
          port: 22,
          username: 'dev',
          authMethod: SshAuthMethod.password,
        ).toJson(),
    ];
    final storage = _ModelStorage({
      'conduit.saved_hosts.v1': jsonEncode(hosts),
      'conductore.palette.v2': 'tokyo-night',
    });
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      storage.handle,
    );
    // No device authentication: the lock page offers "Continue without
    // auth", which stands in for a successful unlock.
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/local_auth'),
      (call) async => call.method == 'isDeviceSupported' ? false : null,
    );

    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final mainWatch = Stopwatch()..start();
    app.main();
    final mainUs = mainWatch.elapsedMicroseconds;
    final firstFrameWatch = Stopwatch()..start();
    await tester.pump();
    final firstFrameUs = firstFrameWatch.elapsedMicroseconds;
    final initialTheme = tester
        .widget<MaterialApp>(find.byType(MaterialApp))
        .theme;

    int? themeAt;
    Future<void> step() async {
      await tester.pump(const Duration(milliseconds: 1));
      storage.now += 1;
      if (themeAt == null &&
          !identical(
            tester.widget<MaterialApp>(find.byType(MaterialApp)).theme,
            initialTheme,
          )) {
        themeAt = storage.now;
      }
    }

    while (storage.now < 800) {
      await step();
    }
    final readsBeforeUnlock = storage.reads.length;
    final drainedAt = storage.reads
        .map((r) => r.done)
        .fold(0, (a, b) => a > b ? a : b);

    await tester.tap(find.text('Continue without auth'));
    final unlockAt = storage.now;
    while (storage.now < unlockAt + 800) {
      await step();
    }
    // The hosts controller has its machines once the last of its reads is
    // back (the list, then its sort mode and manual order).
    final hostsReads = storage.reads.where(
      (r) =>
          r.key.startsWith('conduit.saved_hosts') ||
          r.key.startsWith('conduit.host_list_'),
    );
    final homeAt = hostsReads.isEmpty
        ? null
        : hostsReads.map((r) => r.done).reduce((a, b) => a > b ? a : b) -
              unlockAt;
    final keyCounts = <String, int>{};
    for (final read in storage.reads) {
      keyCounts[read.key] = (keyCounts[read.key] ?? 0) + 1;
    }
    final duplicates = keyCounts.values
        .where((n) => n > 1)
        .fold(0, (a, n) => a + n - 1);

    perfReport('startup', {
      'main_sync_ms': (mainUs / 1000).toStringAsFixed(1),
      'first_frame_build_ms': (firstFrameUs / 1000).toStringAsFixed(1),
      'theme_applied_model_ms': themeAt ?? -1,
      'reads_before_unlock': readsBeforeUnlock,
      'startup_reads_drained_model_ms': drainedAt,
      'hosts_loaded_after_unlock_model_ms': homeAt ?? -1,
      'reads_total_2s': storage.reads.length,
      'duplicate_reads': duplicates,
    });
    // Before: the theme's 30 reads one after another (180 ms in this
    // model), the hosts' three in turn behind the rest (32 ms), and the
    // trusted keys read twice.
    // Guards against falling back to one read after another (180 ms in
    // this model), not an exact budget: every new setting adds a read.
    expect(themeAt, lessThan(180));
    expect(homeAt, lessThanOrEqualTo(20));
    expect(duplicates, 0);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  });
}
