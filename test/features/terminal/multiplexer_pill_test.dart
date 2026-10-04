import 'dart:io';

import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/core/theme/terminal_appearance.dart';
import 'package:conduit/core/theme/terminal_pill_items.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/terminal/domain/herdr_keymap.dart';
import 'package:conduit/features/terminal/domain/herdr_navigator.dart';
import 'package:conduit/features/terminal/presentation/multiplexer_pill_actions.dart';
import 'package:conduit/features/terminal/presentation/terminal_keyboard_bar.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:conduit/features/terminal/presentation/widgets/floating_toolbar.dart';
import 'package:conduit/features/terminal/presentation/widgets/tmux_navigator_sheet.dart';
import 'package:conduit_vt/conduit_vt.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';
import 'herdr/fake_herdr_runner.dart';

const _pill = [
  TerminalPillItem.button(TerminalPillButton.esc),
  TerminalPillItem.button(TerminalPillButton.herdr),
];

/// Herdr 0.9.1 `pane list`: w1:p1 focused in /srv/app.
const _herdrPaneList =
    '{"id":"cli:pane:list","result":{"panes":['
    '{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1",'
    '"cwd":"/srv/app","focused":true}],"type":"pane_list"}}';

AgentCommandResult _herdr(String command) {
  if (command.contains('pane list')) {
    return const AgentCommandResult(
      stdout: _herdrPaneList,
      stderr: '',
      exitCode: 0,
    );
  }
  return FakeHerdrRunner.panesResponse(command);
}

/// tmux 3.4 listing: one client (/dev/pts/30) on session s2, pane %1.
final _tmuxListing = File(
  'test/features/terminal/tmux/fixtures/tmux_3.4_listing.txt',
).readAsStringSync();

AgentCommandResult _tmux(String command) => command.contains('list-clients')
    ? AgentCommandResult(stdout: _tmuxListing, stderr: '', exitCode: 0)
    : const AgentCommandResult(stdout: '', stderr: '', exitCode: 0);

String _tmuxBody(String command) => command
    .substring(command.indexOf('exec tmux ') + 'exec '.length)
    .replaceAll(r"'\''", "'")
    .replaceFirst(RegExp(r"'$"), '');

SavedHost _tmuxHost() => buildHost(
  'tmux-host',
).copyWith(startTmuxOnConnect: true, tmuxSessionName: 's2');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<FakeHerdrRunner> runners;

  Future<_RecordingController> pumpPill(
    WidgetTester tester, {
    SavedHost? host,
    AgentCommandResult Function(String command)? respond,
    bool withRunner = true,
  }) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    HerdrPaneListingCache.instance.clear();
    HerdrKeymapCache.instance.clear();
    TmuxListingCache.instance.clear();
    runners = [];
    final controller = _RecordingController(host: host);
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              Expanded(
                child: Focus(
                  focusNode: focusNode,
                  child: const SizedBox.expand(),
                ),
              ),
              TerminalKeyboardBar(
                controller: controller,
                focusNode: focusNode,
                palette: AppPalette.catppuccin,
                brightness: Brightness.dark,
                rows: const [],
                globalSnippets: const [],
                fullscreen: false,
                onToggleFullscreen: () {},
                onEnterTmuxScrollMode: () {},
                onExitTmuxScrollMode: () {},
                tmuxPrefixKey: MultiplexerPrefixKey.controlB,
                tmuxScrollMode: false,
              ).withToolbarStyle(
                TerminalToolbarStyle.floatingPill,
                pillItems: _pill,
                runnerFactory: withRunner
                    ? (host) {
                        final runner = FakeHerdrRunner(respond ?? _herdr);
                        runners.add(runner);
                        return runner;
                      }
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
    return controller;
  }

  Future<void> tapPillButton(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('toolbar-herdr')));
    await tester.pumpAndSettle();
  }

  group('Herdr: new pane in one tap', () {
    testWidgets('the navigator opens with split, tab and workspace first', (
      tester,
    ) async {
      await pumpPill(tester);
      // The pill carries the official Herdr logo.
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('toolbar-herdr')),
          matching: find.byKey(const ValueKey('multiplexer-icon-herdr')),
        ),
        findsOneWidget,
      );
      await tapPillButton(tester);

      for (final key in [
        'herdr-new-splitRight',
        'herdr-new-splitDown',
        'herdr-new-newTab',
        'herdr-new-newWorkspace',
      ]) {
        expect(find.byKey(ValueKey(key)), findsOneWidget);
      }
      // Above the pane list.
      expect(
        tester
            .getTopLeft(find.byKey(const ValueKey('herdr-new-splitRight')))
            .dy,
        lessThan(tester.getTopLeft(find.text('reviewer')).dy),
      );
    });

    testWidgets('Split right splits the focused pane in its directory', (
      tester,
    ) async {
      final controller = await pumpPill(tester);
      await tapPillButton(tester);
      await tester.tap(find.byKey(const ValueKey('herdr-new-splitRight')));
      await tester.pumpAndSettle();

      final commands = runners.single.commands;
      expect(commands[commands.length - 2], contains('exec herdr pane list'));
      expect(
        commands.last,
        contains(
          'exec herdr pane split w1:p1 --direction right --cwd '
          "'\\''/srv/app'\\'' --focus",
        ),
      );
      expect(runners.single.closed, isTrue);
      expect(controller.sentText, isEmpty);
      expect(controller.sentControlKeys, isEmpty);
    });

    testWidgets('New tab opens in the focused workspace and directory', (
      tester,
    ) async {
      await pumpPill(tester);
      await tapPillButton(tester);
      await tester.tap(find.byKey(const ValueKey('herdr-new-newTab')));
      await tester.pumpAndSettle();

      expect(
        runners.single.commands.last,
        contains(
          "exec herdr tab create --workspace w1 --cwd '\\''/srv/app'\\'' "
          '--focus',
        ),
      );
    });

    testWidgets('without a command channel the machine binding is typed', (
      tester,
    ) async {
      final controller = await pumpPill(tester, withRunner: false);
      await tapPillButton(tester);
      await tester.tap(find.byKey(const ValueKey('herdr-new-splitDown')));
      await tester.pumpAndSettle();

      // Herdr's default split_horizontal: prefix -.
      expect(controller.sentControlKeys, [TerminalKey.keyB]);
      expect(controller.sentText, ['-']);
    });

    testWidgets('when Herdr rejects it, the key binding is typed', (
      tester,
    ) async {
      final controller = await pumpPill(
        tester,
        respond: (command) => command.contains('workspace create')
            ? const AgentCommandResult(
                stdout: '{"error":{"code":"x"}}',
                stderr: '',
                exitCode: 1,
              )
            : _herdr(command),
      );
      await tapPillButton(tester);
      await tester.tap(find.byKey(const ValueKey('herdr-new-newWorkspace')));
      await tester.pumpAndSettle();

      expect(controller.sentControlKeys, [TerminalKey.keyB]);
      expect(controller.sentText, ['N']);
    });

    testWidgets('long-press on the Herdr button offers the same four', (
      tester,
    ) async {
      await pumpPill(tester);
      await tester.longPress(find.byKey(const ValueKey('toolbar-herdr')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('herdr-navigator')), findsNothing);
      for (final label in [
        'Split right',
        'Split down',
        'New tab',
        'New workspace',
      ]) {
        expect(find.text(label), findsOneWidget);
      }
      await tester.tap(find.text('New workspace'));
      await tester.pumpAndSettle();

      expect(runners.single.commands, [
        contains('exec herdr pane list'),
        contains(
          "exec herdr workspace create --cwd '\\''/srv/app'\\'' --focus",
        ),
      ]);
      expect(runners.single.closed, isTrue);
    });
  });

  group('tmux navigator', () {
    test('tmux sessions get the tmux navigator; Herdr and shells Herdr', () {
      expect(pillMultiplexerOf(_tmuxHost()), PillMultiplexer.tmux);
      expect(pillMultiplexerOf(buildHost('plain')), PillMultiplexer.herdr);
      expect(
        pillMultiplexerOf(
          buildHost(
            'h#herdr:w1',
          ).copyWith(startTmuxOnConnect: true, tmuxSessionName: 'x'),
        ),
        PillMultiplexer.herdr,
      );
      expect(tmuxSessionNameOf(_tmuxHost()), 's2');
    });

    testWidgets('the pill shows the tmux mark and lists session › window › '
        'pane with the app client current', (tester) async {
      await pumpPill(tester, host: _tmuxHost(), respond: _tmux);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('toolbar-herdr')),
          matching: find.byKey(const ValueKey('multiplexer-icon-tmux')),
        ),
        findsOneWidget,
      );
      await tapPillButton(tester);

      expect(find.byKey(const ValueKey('tmux-navigator')), findsOneWidget);
      expect(find.text('tmux · s2'), findsOneWidget);
      expect(find.text('0: editor'), findsOneWidget);
      // s2 comes after the eight panes of s1.
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('tmux-pane-%1')),
        200,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('tmux-navigator')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('tmux-pane-%1')),
          matching: find.text('Current'),
        ),
        findsOneWidget,
      );
      expect(find.text('Current'), findsOneWidget);
      expect(runners.single.commands.single, contains('list-clients'));
    });

    testWidgets('tapping a pane switches the app client to it', (tester) async {
      final controller = await pumpPill(
        tester,
        host: _tmuxHost(),
        respond: _tmux,
      );
      await tapPillButton(tester);
      await tester.tap(find.byKey(const ValueKey('tmux-pane-%7')));
      await tester.pumpAndSettle();

      expect(
        _tmuxBody(runners.single.commands.last),
        "tmux -u switch-client -c '/dev/pts/30' -t '%7'",
      );
      expect(controller.sentText, isEmpty);
    });

    const expected = {
      'splitRight': "tmux -u split-window -h -t '%1' -c '#{pane_current_path}'",
      'splitDown': "tmux -u split-window -v -t '%1' -c '#{pane_current_path}'",
      'newWindow': "tmux -u new-window -a -t '@1' -c '#{pane_current_path}'",
      'zoom': "tmux -u resize-pane -Z -t '%1'",
      'detach': "tmux -u detach-client -t '/dev/pts/30'",
    };
    for (final MapEntry(key: action, value: command) in expected.entries) {
      testWidgets('$action runs `$command`', (tester) async {
        await pumpPill(tester, host: _tmuxHost(), respond: _tmux);
        await tapPillButton(tester);
        await tester.tap(find.byKey(ValueKey('tmux-quick-$action')));
        await tester.pumpAndSettle();

        // The sheet's listing resolved the client: one more command only.
        expect(runners.single.commands, hasLength(2));
        expect(_tmuxBody(runners.single.commands.last), command);
      });
    }

    testWidgets('kill pane asks first', (tester) async {
      await pumpPill(tester, host: _tmuxHost(), respond: _tmux);
      await tapPillButton(tester);
      await tester.tap(find.byKey(const ValueKey('tmux-quick-killPane')));
      await tester.pumpAndSettle();
      expect(runners.single.commands, hasLength(1));

      await tester.tap(find.byKey(const ValueKey('herdr-confirm')));
      await tester.pumpAndSettle();
      expect(
        _tmuxBody(runners.single.commands.last),
        "tmux -u kill-pane -t '%1'",
      );
    });

    testWidgets('window buttons select that window of the app session', (
      tester,
    ) async {
      await pumpPill(tester, host: _tmuxHost(), respond: _tmux);
      await tapPillButton(tester);
      await tester.tap(find.byKey(const ValueKey('tmux-window-3')));
      await tester.pumpAndSettle();

      expect(
        _tmuxBody(runners.single.commands.last),
        r"tmux -u select-window -t '$1:3'",
      );
    });

    testWidgets('without tmux on PATH, actions fall back to prefix keys', (
      tester,
    ) async {
      final controller = await pumpPill(
        tester,
        host: _tmuxHost(),
        respond: (_) => const AgentCommandResult(
          stdout: '',
          stderr: 'sh: 1: exec: tmux: not found',
          exitCode: 127,
        ),
      );
      await tapPillButton(tester);
      expect(find.byKey(const ValueKey('tmux-not-found')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('tmux-quick-splitRight')));
      await tester.pumpAndSettle();
      expect(controller.sentControlKeys, [TerminalKey.keyB]);
      expect(controller.sentText, ['%']);

      await tapPillButton(tester);
      await tester.tap(find.byKey(const ValueKey('tmux-window-2')));
      await tester.pumpAndSettle();
      expect(controller.sentControlKeys, [TerminalKey.keyB, TerminalKey.keyB]);
      expect(controller.sentText, ['%', '2']);
    });

    testWidgets('long-press offers split right, split down and new window', (
      tester,
    ) async {
      await pumpPill(tester, host: _tmuxHost(), respond: _tmux);
      await tester.longPress(find.byKey(const ValueKey('toolbar-herdr')));
      await tester.pumpAndSettle();

      expect(find.text('Split right'), findsOneWidget);
      expect(find.text('Split down'), findsOneWidget);
      expect(find.text('New window'), findsOneWidget);
      expect(find.text('New tab'), findsNothing);
      await tester.tap(find.text('New window'));
      await tester.pumpAndSettle();

      expect(runners.single.commands, hasLength(2));
      expect(runners.single.commands.first, contains('list-clients'));
      expect(
        _tmuxBody(runners.single.commands.last),
        "tmux -u new-window -a -t '@1' -c '#{pane_current_path}'",
      );
    });
  });
}

class _RecordingController extends TerminalSessionController {
  _RecordingController({SavedHost? host})
    : super(
        host: host ?? buildHost('toolbar'),
        repository: NoNetworkTerminalRepository(),
      );

  final List<TerminalKey> sentControlKeys = <TerminalKey>[];
  final List<String> sentText = <String>[];

  @override
  void sendKey(TerminalKey key) => keyboard.clearModifiers();

  @override
  void sendControl(TerminalKey key) {
    sentControlKeys.add(key);
    keyboard.clearModifiers();
  }

  @override
  void sendText(String text) {
    sentText.add(text);
    keyboard.clearModifiers();
  }
}
