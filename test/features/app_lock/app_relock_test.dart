import 'dart:async';

import 'package:conduit/features/app_lock/domain/app_lock_preferences.dart';
import 'package:conduit/features/app_lock/presentation/app_lock_controller.dart';
import 'package:conduit/features/app_lock/presentation/app_lock_gate.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

class _MemoryPreferences implements AppLockPreferences {
  RelockDelay stored = RelockDelay.standard;

  @override
  Future<RelockDelay> loadRelockDelay() async => stored;

  @override
  Future<void> saveRelockDelay(RelockDelay delay) async => stored = delay;
}

void main() {
  group('AppLockController re-lock', () {
    late DateTime now;
    late AppLockController controller;

    setUp(() async {
      now = DateTime(2026, 9, 27, 12);
      controller = AppLockController(AlwaysAuthenticates(), clock: () => now);
      await controller.unlock();
    });

    test('locks again after a minute in the background by default', () {
      expect(controller.relockDelay, RelockDelay.oneMinute);
      controller.appBackgrounded();
      now = now.add(const Duration(seconds: 61));
      controller.appResumed();
      expect(controller.isUnlocked, isFalse);
    });

    test('a short trip away keeps it unlocked', () {
      controller.appBackgrounded();
      now = now.add(const Duration(seconds: 30));
      controller.appResumed();
      expect(controller.isUnlocked, isTrue);
    });

    test('counts from when it first left the screen', () {
      controller.appBackgrounded(); // hidden
      now = now.add(const Duration(seconds: 50));
      controller.appBackgrounded(); // then paused
      now = now.add(const Duration(seconds: 20));
      controller.appResumed();
      expect(controller.isUnlocked, isFalse);
    });

    test('follows the chosen delay, and never when told so', () async {
      await controller.setRelockDelay(RelockDelay.never);
      controller.appBackgrounded();
      now = now.add(const Duration(days: 1));
      controller.appResumed();
      expect(controller.isUnlocked, isTrue);

      await controller.setRelockDelay(RelockDelay.immediately);
      controller.appBackgrounded();
      controller.appResumed();
      expect(controller.isUnlocked, isFalse);
    });

    test('not after "Continue without auth"', () async {
      final unavailable = AppLockController(
        UnavailableAuthenticator(),
        clock: () => now,
      );
      await unavailable.unlock();
      unavailable.continueWithoutAuth();
      unavailable.appBackgrounded();
      now = now.add(const Duration(minutes: 10));
      unavailable.appResumed();
      expect(unavailable.isUnlocked, isTrue);
    });

    test('never on a platform without the app lock', () {
      final disabled = AppLockController(
        AlwaysAuthenticates(),
        enabled: false,
        clock: () => now,
      );
      disabled.appBackgrounded();
      now = now.add(const Duration(minutes: 10));
      disabled.appResumed();
      expect(disabled.isUnlocked, isTrue);
    });

    test('the delay is saved and read back', () async {
      final preferences = _MemoryPreferences();
      final first = AppLockController(
        AlwaysAuthenticates(),
        preferences: preferences,
      );
      await first.setRelockDelay(RelockDelay.fifteenMinutes);
      final second = AppLockController(
        AlwaysAuthenticates(),
        preferences: preferences,
      );
      await second.loadPreferences();
      expect(second.relockDelay, RelockDelay.fifteenMinutes);
    });
  });

  testWidgets('AppLockGate covers pushed routes when the app locks again', (
    tester,
  ) async {
    var now = DateTime(2026, 9, 27, 12);
    final controller = AppLockController(
      AlwaysAuthenticates(),
      clock: () => now,
    );
    await controller.unlock();
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        builder: (context, child) => AppLockGate(
          controller: controller,
          lockPage: (_) => const Scaffold(body: Text('Locked')),
          child: child!,
        ),
        home: const Scaffold(body: Text('Home')),
      ),
    );
    unawaited(
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Terminal')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Terminal'), findsOneWidget);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    now = now.add(const Duration(minutes: 2));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(controller.isUnlocked, isFalse);
    expect(find.text('Locked'), findsOneWidget);
    expect(find.text('Terminal'), findsNothing);

    await controller.unlock();
    await tester.pumpAndSettle();
    // Back where the user was.
    expect(find.text('Terminal'), findsOneWidget);
    expect(find.text('Locked'), findsNothing);
  });
}
