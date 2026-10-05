import 'package:conduit/features/terminal/presentation/terminal_background_keepalive.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late List<String> calls;
  late BackgroundKeepaliveSync sync;

  setUp(() {
    calls = [];
    sync = BackgroundKeepaliveSync(
      start: (count) async => calls.add('start $count'),
      stop: () async => calls.add('stop'),
    );
  });

  test('a fresh engine stops a service left from before (CON-089)', () {
    expect(calls, ['stop']);
  });

  test('runs only in the background with live sessions', () async {
    calls.clear();
    sync.sync(sessionCount: 2, lifecycle: AppLifecycleState.resumed);
    expect(calls, isEmpty);
    sync.sync(sessionCount: 2, lifecycle: AppLifecycleState.paused);
    sync.sync(sessionCount: 2, lifecycle: AppLifecycleState.paused);
    sync.sync(sessionCount: 1, lifecycle: AppLifecycleState.paused);
    // The last session closing in the background stops it.
    sync.sync(sessionCount: 0, lifecycle: AppLifecycleState.paused);
    sync.sync(sessionCount: 0, lifecycle: AppLifecycleState.resumed);
    expect(calls, ['start 2', 'start 1', 'stop']);
  });

  test('a refused start is retried on the next change', () async {
    final failing = BackgroundKeepaliveSync(
      start: (count) async => throw StateError('refused'),
      stop: () async {},
    );
    failing.sync(sessionCount: 1, lifecycle: AppLifecycleState.paused);
    await Future<void>.delayed(Duration.zero);
    expect(failing.running, isFalse);
  });
}
