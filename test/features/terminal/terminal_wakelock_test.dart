import 'package:conduit/core/theme/theme_controller.dart';
import 'package:conduit/features/terminal/presentation/terminal_page.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

import '../../support/test_doubles.dart';

/// Records what the page asks of the wakelock.
class _RecordingWakelock extends WakelockPlusPlatformInterface {
  bool held = false;

  @override
  Future<void> toggle({required bool enable}) async => held = enable;

  @override
  Future<bool> get enabled async => held;
}

/// CON-089: the wakelock was enabled for the page's whole life, so the
/// screen never slept on desktop (the shell mounts the page at start-up)
/// and stayed on whenever the terminal was anywhere in the route stack.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _RecordingWakelock wakelock;
  late ThemeController theme;
  late TerminalWorkspaceController workspace;
  final navigator = GlobalKey<NavigatorState>();

  setUp(() async {
    wakelock = _RecordingWakelock();
    WakelockPlusPlatformInterface.instance = wakelock;
    theme = ThemeController(InMemoryThemePreferences());
    await theme.load();
    workspace = TerminalWorkspaceController(
      ImmediateTerminalRepository(TrackableTerminalSession()),
    );
  });

  tearDown(() => workspace.dispose());

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: TerminalPage(
          workspace: workspace,
          themeController: theme,
          sftpRepository: NoNetworkSftpRepository(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> connect(WidgetTester tester) async {
    final session = workspace.open(buildHost('h'));
    await tester.runAsync(session.connect);
    await tester.pump();
  }

  testWidgets('held only while a connected terminal is in front', (
    tester,
  ) async {
    await pumpPage(tester);
    expect(wakelock.held, isFalse, reason: 'no session yet');

    await connect(tester);
    expect(wakelock.held, isTrue);

    // A route over the terminal (Chat View, SFTP, Settings).
    navigator.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const Text('over')),
    );
    await tester.pumpAndSettle();
    expect(wakelock.held, isFalse);

    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(wakelock.held, isTrue);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(wakelock.held, isFalse, reason: 'app in the background');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(wakelock.held, isTrue);

    await theme.setKeepScreenOn(false);
    await tester.pump();
    expect(wakelock.held, isFalse, reason: 'the setting is off');

    await tester.pumpWidget(const SizedBox());
  });

  test('the setting defaults on for phones and off for desktop', () async {
    expect(theme.keepScreenOn, isTrue);
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    expect(theme.keepScreenOn, isFalse);
    await theme.setKeepScreenOn(true);
    expect(theme.keepScreenOn, isTrue);
  });
}
