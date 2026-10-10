import 'dart:async';

import 'package:conduit/features/app_lock/domain/app_authenticator.dart';
import 'package:conduit/features/app_lock/domain/app_lock_preferences.dart';
import 'package:conduit/features/app_lock/presentation/app_lock_controller.dart';
import 'package:conduit/features/app_lock/presentation/app_lock_gate.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

class _MemoryPreferences implements AppLockPreferences {
  RelockDelay stored = RelockDelay.standard;
  AppUnlockStamp? stamp;

  @override
  Future<RelockDelay> loadRelockDelay() async => stored;

  @override
  Future<void> saveRelockDelay(RelockDelay delay) async => stored = delay;

  @override
  Future<AppUnlockStamp?> loadUnlockStamp() async => stamp;

  @override
  Future<void> saveUnlockStamp(AppUnlockStamp? value) async => stamp = value;
}

/// Counts the fingerprint, face or PIN prompts.
class _CountingAuthenticator extends AlwaysAuthenticates {
  int prompts = 0;

  @override
  Future<AppAuthenticationResult> authenticate() async {
    prompts += 1;
    return super.authenticate();
  }
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

    test('actions from outside the app need the app lock open', () async {
      final locked = AppLockController(AlwaysAuthenticates(), clock: () => now);
      expect(locked.admitsActions(), isFalse);
      expect(locked.actionState.value.locked, isTrue);

      // Unlocked and on screen.
      expect(controller.admitsActions(), isTrue);
      expect(
        controller.actionState.value,
        const AppLockActionState(locked: false),
      );

      // In the background, within the delay: still open; past it, the
      // action is refused and the app locks there and then, not only on
      // its return.
      controller.appBackgrounded();
      expect(
        controller.actionState.value.relockAt,
        now.add(const Duration(minutes: 1)),
      );
      now = now.add(const Duration(seconds: 30));
      expect(controller.admitsActions(), isTrue);
      now = now.add(const Duration(seconds: 31));
      expect(controller.admitsActions(), isFalse);
      expect(controller.isUnlocked, isFalse);
      expect(controller.actionState.value.locked, isTrue);
      expect(controller.actionState.value.relockAt, isNull);
    });

    test('back on screen, the re-lock deadline goes', () {
      controller.appBackgrounded();
      expect(controller.actionState.value.relockAt, isNotNull);
      controller.appResumed();
      expect(
        controller.actionState.value,
        const AppLockActionState(locked: false),
      );
    });

    test('a platform without an app lock always admits actions', () {
      final none = AppLockController(AlwaysAuthenticates(), enabled: false);
      expect(none.admitsActions(), isTrue);
      expect(none.actionState.value.locked, isFalse);
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

  group('longer delays last across restarts (CON-118)', () {
    late DateTime now;
    late Duration uptime;
    late _MemoryPreferences preferences;
    late _CountingAuthenticator authenticator;

    setUp(() {
      now = DateTime(2026, 10, 10, 9);
      uptime = const Duration(hours: 30);
      preferences = _MemoryPreferences()..stored = RelockDelay.eightHours;
      authenticator = _CountingAuthenticator();
    });

    /// An app start: a new controller over the same saved preferences, the
    /// way the lock page opens it.
    Future<AppLockController> start() async {
      final controller = AppLockController(
        authenticator,
        preferences: preferences,
        clock: () => now,
        uptime: () async => uptime,
      );
      unawaited(controller.loadPreferences());
      await controller.unlock();
      // The stamp is saved in the background.
      await pumpEventQueue();
      return controller;
    }

    void advance(Duration by) {
      now = now.add(by);
      uptime += by;
    }

    test('8 hours: a restart within them opens without asking', () async {
      final first = await start();
      expect(first.isUnlocked, isTrue);
      expect(authenticator.prompts, 1);

      advance(const Duration(hours: 7, minutes: 59));
      final second = await start();
      expect(second.isUnlocked, isTrue);
      expect(authenticator.prompts, 1);
      // Background actions follow the same window: from the first unlock.
      expect(second.actionState.value.relockAt, DateTime(2026, 10, 10, 17));
      expect(second.admitsActions(), isTrue);
    });

    test('8 hours: after them, a restart asks', () async {
      await start();
      advance(const Duration(hours: 8));
      final later = await start();
      expect(later.isUnlocked, isTrue);
      expect(authenticator.prompts, 2);
    });

    test('a clock moved back counts as expired', () async {
      await start();
      now = now.subtract(const Duration(hours: 1));
      uptime += const Duration(minutes: 5);
      await start();
      expect(authenticator.prompts, 2);
    });

    test('a reboot counts as expired', () async {
      await start();
      // Rebooted an hour later: the time since boot starts again.
      advance(const Duration(hours: 1));
      uptime = const Duration(minutes: 3);
      await start();
      expect(authenticator.prompts, 2);

      // Even once the new boot has been up longer than the old one was.
      advance(const Duration(hours: 1));
      uptime = const Duration(hours: 40);
      await start();
      expect(authenticator.prompts, 3);
    });

    test('without a time since boot, only the clock is checked', () {
      final stamp = AppUnlockStamp(at: DateTime.utc(2026, 10, 10, 9));
      const day = Duration(days: 1);
      expect(stamp.holdsAt(DateTime.utc(2026, 10, 10, 20), day), isTrue);
      expect(stamp.holdsAt(DateTime.utc(2026, 10, 11, 9), day), isFalse);
      expect(stamp.holdsAt(DateTime.utc(2026, 10, 10, 8), day), isFalse);
      expect(
        AppUnlockStamp.fromJson(stamp.toJson())!.at,
        DateTime.utc(2026, 10, 10, 9),
      );
    });

    test(
      'Lock now, or a delay of 15 minutes or less, asks on restart',
      () async {
        final first = await start();
        first.lock();
        await pumpEventQueue();
        expect(preferences.stamp, isNull);
        await start();
        expect(authenticator.prompts, 2);

        preferences.stored = RelockDelay.fifteenMinutes;
        advance(const Duration(minutes: 1));
        await start();
        expect(authenticator.prompts, 3);
      },
    );

    test(
      'in the same run it counts from the unlock, not the time away',
      () async {
        final controller = await start();
        advance(const Duration(hours: 7));
        controller
          ..appBackgrounded()
          ..appResumed();
        expect(controller.isUnlocked, isTrue);

        advance(const Duration(hours: 1));
        expect(controller.admitsActions(), isFalse);
        expect(controller.isUnlocked, isFalse);
      },
    );
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
