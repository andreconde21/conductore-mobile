import 'dart:convert';
import 'dart:io';

import 'package:conduit/core/theme/terminal_pill_items.dart';
import 'package:conduit/core/theme/theme_controller.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:conduit/features/terminal/domain/herdr_keymap.dart';
import 'package:conduit/features/terminal/presentation/terminal_page.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

import '../../support/test_doubles.dart';

class _NoopWakelock extends WakelockPlusPlatformInterface {
  @override
  Future<void> toggle({required bool enable}) async {}

  @override
  Future<bool> get enabled async => false;
}

/// What a Mosh session types before it closes (Close, Reconnect, the
/// pill's reconnect): never Ctrl-D into a multiplexer's focused pane.
void main() {
  WakelockPlusPlatformInterface.instance = _NoopWakelock();

  final devCentral = HerdrKeymap.parseConfig(
    File(
      'test/features/terminal/herdr/fixtures/herdr_config_dev_central.toml',
    ).readAsStringSync(),
  );

  setUp(HerdrKeymapCache.instance.clear);
  tearDown(HerdrKeymapCache.instance.clear);

  SavedHost mosh(ConnectTarget? target, {MultiplexerPrefixKey? prefix}) {
    final host = buildHost('m').copyWith(
      useMosh: true,
      tmuxPrefixKey: prefix ?? MultiplexerPrefixKey.controlB,
    );
    return target == null ? host : target.apply(host);
  }

  const herdr = ConnectTarget.herdr(workspaceId: 'w1');
  const ctrlD = [0x04];

  /// Everything the remote got after connecting (the Herdr attach typed
  /// on connect is not part of closing).
  List<List<int>> closingBytes(
    TrackableTerminalSession remote,
    int sentBeforeClose,
  ) => remote.sent.sublist(sentBeforeClose);

  /// Runs a close on real time (the graceful close waits up to 1.5 s for
  /// the remote to end, and the session was connected on real time too).
  Future<void> runOut(
    WidgetTester tester,
    Future<void> Function() close,
  ) async {
    await tester.runAsync(close);
  }

  group('keystrokes by what the session attached', () {
    test('Herdr with the machine\'s default keymap: prefix, q', () {
      HerdrKeymapCache.instance.put('m', HerdrKeymap.hostDefaults);
      final controller = TerminalSessionController(
        host: mosh(herdr),
        repository: ImmediateTerminalRepository(TrackableTerminalSession()),
      );
      addTearDown(controller.dispose);
      final keys = controller.moshCloseKeystrokes();
      expect(keys, isA<MoshCloseHerdr>());
      expect((keys as MoshCloseHerdr).detach, [0x02, 0x71]);
    });

    test('Herdr with a custom keymap: Ctrl+Space, d', () {
      HerdrKeymapCache.instance.put('m', devCentral);
      final controller = TerminalSessionController(
        host: mosh(herdr),
        repository: ImmediateTerminalRepository(TrackableTerminalSession()),
      );
      addTearDown(controller.dispose);
      expect((controller.moshCloseKeystrokes() as MoshCloseHerdr).detach, [
        0x00,
        0x64,
      ]);
    });

    test('Herdr whose keymap was not read yet: nothing', () {
      final controller = TerminalSessionController(
        host: mosh(herdr),
        repository: ImmediateTerminalRepository(TrackableTerminalSession()),
      );
      addTearDown(controller.dispose);
      expect(controller.moshCloseKeystrokes(), isA<MoshCloseNothing>());
    });

    test('Herdr started by a startup command on a plain host: its detach', () {
      HerdrKeymapCache.instance.put('m', HerdrKeymap.hostDefaults);
      final controller = TerminalSessionController(
        host: mosh(null),
        repository: ImmediateTerminalRepository(TrackableTerminalSession()),
        startupCommand: 'herdr workspace focus w1 >/dev/null 2>&1; herdr',
      );
      addTearDown(controller.dispose);
      expect(controller.moshCloseKeystrokes(), isA<MoshCloseHerdr>());
    });

    test('tmux: its detach with the host prefix', () {
      final controller = TerminalSessionController(
        host: mosh(
          const ConnectTarget.tmux('main'),
          prefix: MultiplexerPrefixKey.controlA,
        ),
        repository: ImmediateTerminalRepository(TrackableTerminalSession()),
      );
      addTearDown(controller.dispose);
      expect((controller.moshCloseKeystrokes() as MoshCloseTmux).detach, [
        0x01,
        0x64,
      ]);
    });

    test('a plain shell: Ctrl-D', () {
      final controller = TerminalSessionController(
        host: mosh(null),
        repository: ImmediateTerminalRepository(TrackableTerminalSession()),
      );
      addTearDown(controller.dispose);
      expect(controller.moshCloseKeystrokes(), isA<MoshCloseShell>());
    });
  });

  group('on Close and Reconnect', () {
    Future<(TerminalWorkspaceController, TerminalSessionController)> open(
      WidgetTester tester,
      SavedHost host,
      FreshTerminalRepository repository,
    ) async {
      final workspace = TerminalWorkspaceController(repository);
      addTearDown(workspace.dispose);
      final session = workspace.open(host);
      await tester.runAsync(session.connect);
      return (workspace, session);
    }

    final cases = <String, (SavedHost Function(), void Function(), List<int>)>{
      'Herdr, default keymap': (
        () => mosh(herdr),
        () => HerdrKeymapCache.instance.put('m', HerdrKeymap.hostDefaults),
        [0x02, 0x71],
      ),
      'Herdr, custom keymap': (
        () => mosh(herdr),
        () => HerdrKeymapCache.instance.put('m', devCentral),
        [0x00, 0x64],
      ),
      'tmux': (
        () => mosh(const ConnectTarget.tmux('main')),
        () {},
        [0x02, 0x64],
      ),
      'plain shell': (() => mosh(null), () {}, ctrlD),
    };

    for (final MapEntry(key: name, value: (host, keymap, first))
        in cases.entries) {
      if (name != 'plain shell') {
        testWidgets('$name: Close', (tester) async {
          keymap();
          final repository = FreshTerminalRepository();
          final (workspace, _) = await open(tester, host(), repository);
          final remote = repository.sessions.single;
          final before = remote.sent.length;

          await runOut(
            tester,
            () => workspace.close(workspace.sessions.single),
          );

          final sent = closingBytes(remote, before);
          expect(sent.first, first);
          expect(
            sent.expand((bytes) => bytes),
            isNot(contains(0x04)),
            reason: 'no Ctrl-D',
          );
        });
      }

      testWidgets('$name: Reconnect', (tester) async {
        keymap();
        final repository = FreshTerminalRepository();
        final (_, session) = await open(tester, host(), repository);
        final remote = repository.sessions.single;
        final before = remote.sent.length;

        await runOut(tester, session.disconnect);
        await tester.runAsync(session.connect);

        expect(closingBytes(remote, before).first, first);
        expect(repository.sessions, hasLength(2));
        expect(session.isConnected, isTrue);
      });
    }

    testWidgets('plain shell: Close sends Ctrl-D', (tester) async {
      final repository = FreshTerminalRepository();
      final (workspace, _) = await open(tester, mosh(null), repository);
      final remote = repository.sessions.single;
      final before = remote.sent.length;
      await runOut(tester, () => workspace.close(workspace.sessions.single));
      expect(closingBytes(remote, before), [ctrlD]);
    });

    testWidgets('tmux: detach, then exit for its shell', (tester) async {
      final repository = FreshTerminalRepository();
      final (workspace, _) = await open(
        tester,
        mosh(const ConnectTarget.tmux('main')),
        repository,
      );
      final remote = repository.sessions.single;
      final before = remote.sent.length;
      await runOut(tester, () => workspace.close(workspace.sessions.single));
      expect(closingBytes(remote, before), [
        [0x02, 0x64],
        utf8.encode('exit\r'),
      ]);
    });

    testWidgets('Herdr: only the detach, never "exit" after it', (
      tester,
    ) async {
      HerdrKeymapCache.instance.put('m', devCentral);
      final repository = FreshTerminalRepository();
      final (workspace, _) = await open(tester, mosh(herdr), repository);
      final remote = repository.sessions.single;
      final before = remote.sent.length;
      await runOut(tester, () => workspace.close(workspace.sessions.single));
      expect(closingBytes(remote, before), [
        [0x00, 0x64],
      ]);
    });

    testWidgets('Herdr before its keymap is read: nothing is typed', (
      tester,
    ) async {
      final repository = FreshTerminalRepository();
      final (workspace, _) = await open(tester, mosh(herdr), repository);
      final remote = repository.sessions.single;
      final before = remote.sent.length;
      await runOut(tester, () => workspace.close(workspace.sessions.single));
      expect(closingBytes(remote, before), isEmpty);
      expect(remote.closeCount, 1);
    });

    testWidgets('an SSH session types nothing before closing', (tester) async {
      HerdrKeymapCache.instance.put('m', HerdrKeymap.hostDefaults);
      final repository = FreshTerminalRepository();
      final (workspace, _) = await open(
        tester,
        mosh(herdr).copyWith(useMosh: false),
        repository,
      );
      final remote = repository.sessions.single;
      final before = remote.sent.length;
      await runOut(tester, () => workspace.close(workspace.sessions.single));
      expect(closingBytes(remote, before), isEmpty);
    });
  });

  for (final viaMenu in [false, true]) {
    testWidgets(
      viaMenu
          ? 'the ⋮ menu\'s Reconnect detaches Herdr cleanly'
          : 'the pill\'s ^L key (long-press) reconnects and detaches Herdr '
                'cleanly',
      (tester) async {
        HerdrKeymapCache.instance.put('m', devCentral);
        final themeController = ThemeController(InMemoryThemePreferences());
        await themeController.load();
        if (!viaMenu) {
          // Not on the pill by default since CON-106.
          await themeController.setTerminalPillItems(const [
            TerminalPillItem.button(TerminalPillButton.reconnect),
          ]);
        }
        final repository = FreshTerminalRepository();
        final workspace = TerminalWorkspaceController(repository);
        final session = workspace.open(mosh(herdr));
        await tester.runAsync(session.connect);
        await tester.pumpWidget(
          MaterialApp(
            home: TerminalPage(
              workspace: workspace,
              themeController: themeController,
              sftpRepository: NoNetworkSftpRepository(),
            ),
          ),
        );
        await tester.pump();
        final remote = repository.sessions.single;
        final before = remote.sent.length;

        if (viaMenu) {
          await tester.tap(find.byTooltip('More'));
          await tester.pumpAndSettle();
          await tester.tap(
            find.byKey(const ValueKey('terminal-menu-reconnect')),
          );
        } else {
          await tester.longPress(find.byKey(const ValueKey('toolbar-redraw')));
        }
        // The close waits (on real time) for the remote, then reconnects.
        for (var i = 0; i < 12 && repository.sessions.length < 2; i++) {
          await tester.runAsync(pumpEventQueue);
          await tester.pump(const Duration(milliseconds: 200));
        }

        expect(closingBytes(remote, before).first, [0x00, 0x64]);
        expect(
          closingBytes(remote, before).expand((bytes) => bytes),
          isNot(contains(0x04)),
        );
        expect(repository.sessions, hasLength(2));

        await tester.pumpWidget(const SizedBox());
        workspace.dispose();
        await tester.pump(const Duration(seconds: 1));
      },
    );
  }
}
