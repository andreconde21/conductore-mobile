import 'package:conduit/core/theme/theme_controller.dart';
import 'package:conduit/features/app_lock/presentation/app_lock_controller.dart';
import 'package:conduit/features/app_lock/presentation/lock_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

void main() {
  late ThemeController theme;
  late AppLockController lock;

  setUp(() async {
    theme = ThemeController(InMemoryThemePreferences());
    await theme.load();
    lock = AppLockController(AlwaysAuthenticates());
  });

  Future<void> pumpLock(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: LockPage(controller: lock, themeController: theme),
      ),
    );
    await tester.pump();
  }

  final unlock = find.byKey(const ValueKey('lock-unlock'));

  testWidgets(
    'desktop: the Unlock button has the focus, so Enter unlocks (A-066)',
    (tester) async {
      await pumpLock(tester);
      expect(tester.widget<ButtonStyleButton>(unlock).autofocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(lock.status, AppLockStatus.unlocked);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.linux,
      TargetPlatform.windows,
      TargetPlatform.macOS,
    }),
  );

  testWidgets('phone: the Unlock button does not take the focus', (
    tester,
  ) async {
    await pumpLock(tester);
    expect(tester.widget<ButtonStyleButton>(unlock).autofocus, isFalse);
  });
}
