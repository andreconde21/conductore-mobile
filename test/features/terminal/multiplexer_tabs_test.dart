import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/terminal/domain/herdr_remote_control.dart';
import 'package:conduit/features/terminal/domain/multiplexer_tabs.dart';
import 'package:conduit/features/terminal/presentation/multiplexer_tabs_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'multiplexer_tabs_fakes.dart';

void main() {
  group('tmux windows', () {
    test(
      'parse window lines, skip junk, keep tabs in names, sort by index',
      () {
        final tabs = TmuxWindowCommands.parse(
          [
            tmuxWindowLine('@4', 2, 'logs', activity: 30),
            'garbage line',
            tmuxWindowLine('@1', 0, 'zsh', active: true, activity: 10),
            tmuxWindowLine('@7', 1, 'claude\tcode', bell: true),
            'W\tnot-an-id\t3\t0\t0\t0\t1\tx',
            '',
          ].join('\n'),
        );
        expect([for (final tab in tabs) tab.id], ['@1', '@7', '@4']);
        expect(tabs[0].active, isTrue);
        expect(tabs[0].activity, 10);
        expect(tabs[1].label, 'claude\tcode');
        expect(tabs[1].flagged, isTrue);
        expect(tabs[2].index, 2);
        expect(tabs[2].flagged, isFalse);
      },
    );

    test('commands target window ids and the exact session name', () {
      // An argument as it reads inside the `sh -c '…'` wrapper.
      String q(String value) => "'\\''$value'\\''";
      expect(
        TmuxWindowCommands.list('my sess'),
        contains(
          'list-windows -t ${q('=my sess')} -F "\$(printf ${q('W\\t'
          '#{window_id}\\t#{window_index}\\t#{window_active}\\t'
          '#{window_activity_flag}\\t#{window_bell_flag}\\t'
          '#{window_activity}\\t#{window_name}')})"',
        ),
      );
      expect(
        TmuxWindowCommands.select('@3'),
        endsWith("exec tmux -u select-window -t ${q('@3')}'"),
      );
      expect(
        TmuxWindowCommands.create(afterWindowId: '@3'),
        contains('new-window -a -t ${q('@3')} -c ${q('#{pane_current_path}')}'),
      );
      expect(
        TmuxWindowCommands.create(sessionName: 'work'),
        contains('new-window -t ${q('=work:')} -c'),
      );
      expect(
        TmuxWindowCommands.rename('@3', 'build logs'),
        contains('rename-window -t ${q('@3')} ${q('build logs')}'),
      );
      expect(
        TmuxWindowCommands.kill('@3'),
        endsWith("exec tmux -u kill-window -t ${q('@3')}'"),
      );
      expect(
        TmuxWindowCommands.swap('@3', '@4', activeWindowId: '@1'),
        contains(
          'swap-window -d -s ${q('@3')} -t ${q('@4')} ${q(';')} '
          'select-window -t ${q('@1')}',
        ),
      );
    });
  });

  group('Herdr tabs', () {
    test('the focused workspace\'s tabs from a real `herdr tab list`', () {
      final parsed = parseHerdrWorkspaceTabs(herdrTabList)!;
      expect(parsed.workspaceId, 'w4');
      expect(parsed.knowsActive, isTrue);
      expect(
        [for (final tab in parsed.tabs) tab.label],
        ['Infrastructure', 'review', 'Tab 3'],
      );
      expect([for (final tab in parsed.tabs) tab.active], [false, true, false]);
      expect(parsed.tabs.first.status, AgentAttentionState.needsInput);
      expect(parsed.tabs[1].status, AgentAttentionState.working);
    });

    test('without a focused tab, the fallback workspace, active unknown', () {
      final parsed = parseHerdrWorkspaceTabs(
        herdrTabList.replaceAll('"focused":true', '"focused":false'),
        fallbackWorkspaceId: 'w7',
      )!;
      expect(parsed.workspaceId, 'w7');
      expect(parsed.knowsActive, isFalse);
      expect(parsed.tabs.single.label, 'Main');
      expect(parseHerdrWorkspaceTabs('not json'), isNull);
    });

    test('rename and close commands', () {
      const commands = HerdrCommands();
      expect(
        commands.tabRename('w4:t2', 'code review'),
        contains("tab rename w4:t2 '\\''code review'\\''"),
      );
      expect(commands.tabClose('w4:t2'), contains('tab close w4:t2'));
      expect(
        const HerdrCommands('work').tabClose('w1:t1'),
        contains('--session work tab close w1:t1'),
      );
    });
  });

  group('unread', () {
    MultiplexerTab tab(
      String id, {
      bool active = false,
      int activity = 0,
      AgentAttentionState? status,
      bool flagged = false,
    }) => MultiplexerTab(
      id: id,
      label: id,
      active: active,
      activity: activity,
      status: status,
      flagged: flagged,
    );

    test('new output in a window not on screen, cleared once shown', () {
      final tracker = MultiplexerUnreadTracker();
      var tabs = tracker.apply([
        tab('@1', active: true),
        tab('@2', activity: 5),
      ]);
      expect(tabs[1].unread, isFalse, reason: 'first sight is read');
      tabs = tracker.apply([
        tab('@1', active: true, activity: 9),
        tab('@2', activity: 6),
      ]);
      expect(tabs[0].unread, isFalse);
      expect(tabs[1].unread, isTrue);
      tabs = tracker.apply([tab('@1'), tab('@2', active: true, activity: 6)]);
      expect(tabs[1].unread, isFalse);
      tabs = tracker.apply([tab('@1', active: true), tab('@2', activity: 6)]);
      expect(tabs[1].unread, isFalse);
    });

    test('a Herdr agent that finished or needs the user; tmux flags', () {
      final tracker = MultiplexerUnreadTracker();
      tracker.apply([
        tab('t1', active: true),
        tab('t2', status: AgentAttentionState.working),
        tab('t3', flagged: true),
      ]);
      final tabs = tracker.apply([
        tab('t1', active: true),
        tab('t2', status: AgentAttentionState.finished),
        tab('t3', flagged: true),
      ]);
      expect(tabs[1].unread, isTrue);
      expect(tabs[2].unread, isTrue);
    });
  });

  group('controller over tmux', () {
    late FakeTmux tmux;
    late MultiplexerTabsController controller;
    final keySelects = <int>[];
    var keyCreates = 0;

    setUp(() {
      keySelects.clear();
      keyCreates = 0;
      tmux = FakeTmux(['zsh', 'claude', 'logs'], active: 1);
      controller = MultiplexerTabsController(
        backend: TmuxTabsBackend(
          channel: SerialCommandChannel(runnerFactory: () => tmux),
          sessionName: 'work',
        ),
        keys: MultiplexerTabsKeys(
          select: (tab, position) {
            keySelects.add(tab.index);
            return true;
          },
          create: () {
            keyCreates += 1;
            return true;
          },
        ),
      );
      addTearDown(controller.dispose);
    });

    test('lists the windows, one listing per refresh', () async {
      await controller.refresh();
      expect(controller.loaded, isTrue);
      expect(
        [for (final tab in controller.tabs) tab.label],
        ['zsh', 'claude', 'logs'],
      );
      expect(controller.active?.id, '@1');
      expect(tmux.commands, [TmuxWindowCommands.list('work')]);
    });

    test('select runs select-window, then lists again', () async {
      await controller.refresh();
      tmux.commands.clear();
      await controller.select(controller.tabs[2]);
      expect(tmux.commands, [
        TmuxWindowCommands.select('@2'),
        TmuxWindowCommands.list('work'),
      ]);
      expect(controller.active?.id, '@2');
      expect(keySelects, isEmpty);
    });

    test('a refused select falls back to prefix + index', () async {
      await controller.refresh();
      tmux.failing.add('select-window');
      await controller.select(controller.tabs[2]);
      expect(keySelects, [2]);
    });

    test('next and previous wrap around', () async {
      await controller.refresh();
      await controller.selectAdjacent(1);
      expect(controller.active?.id, '@2');
      await controller.selectAdjacent(1);
      expect(controller.active?.id, '@0');
      await controller.selectAdjacent(-1);
      expect(controller.active?.id, '@2');
    });

    test('new window after the active one; keys when refused', () async {
      await controller.refresh();
      tmux.commands.clear();
      await controller.create();
      expect(
        tmux.commands.first,
        TmuxWindowCommands.create(afterWindowId: '@1'),
      );
      expect(controller.tabs, hasLength(4));
      tmux.failing.add('new-window');
      await controller.create();
      expect(keyCreates, 1);
    });

    test('rename, close', () async {
      await controller.refresh();
      tmux.commands.clear();
      expect(await controller.rename(controller.tabs[0], '  shell '), isTrue);
      expect(tmux.commands.first, TmuxWindowCommands.rename('@0', 'shell'));
      expect(controller.tabs[0].label, 'shell');
      expect(await controller.rename(controller.tabs[0], '   '), isFalse);
      tmux.commands.clear();
      expect(await controller.close(controller.tabs[2]), isTrue);
      expect(tmux.commands.first, TmuxWindowCommands.kill('@2'));
      expect(controller.tabs, hasLength(2));
    });

    test('move and reorder swap neighbours, the active one stays', () async {
      await controller.refresh();
      tmux.commands.clear();
      await controller.move(controller.tabs[0], 1);
      expect(
        tmux.commands.first,
        TmuxWindowCommands.swap('@0', '@1', activeWindowId: '@1'),
      );
      expect([for (final tab in controller.tabs) tab.id], ['@1', '@0', '@2']);
      tmux.commands.clear();
      await controller.reorder(2, 0);
      expect(tmux.commands.take(2), [
        TmuxWindowCommands.swap('@2', '@0', activeWindowId: '@1'),
        TmuxWindowCommands.swap('@2', '@1', activeWindowId: '@1'),
      ]);
      expect([for (final tab in controller.tabs) tab.id], ['@2', '@1', '@0']);
      expect(controller.active?.id, '@1');
    });
  });

  group('controller over Herdr', () {
    test(
      'lists, focuses, renames, closes and makes tabs; no reorder',
      () async {
        final runner = FakeHerdr();
        final control = HerdrRemoteControl(runnerFactory: () => runner);
        final controller = MultiplexerTabsController(
          backend: HerdrTabsBackend(control: control),
          agentStateFor: (tab) =>
              tab.id == 'w4:t3' ? AgentAttentionState.needsInput : null,
        );
        addTearDown(() async {
          controller.dispose();
          await control.close();
        });
        await controller.refresh();
        expect(controller.canReorder, isFalse);
        expect(controller.tabs.map((tab) => tab.label), [
          'Infrastructure',
          'review',
          'Tab 3',
        ]);
        // The companion's agent state is merged in.
        expect(controller.tabs[2].status, AgentAttentionState.needsInput);
        runner.commands.clear();

        await controller.select(controller.tabs[0]);
        expect(runner.commands.first, const HerdrCommands().tabFocus('w4:t1'));
        runner.commands.clear();
        await controller.rename(controller.tabs[0], 'infra');
        expect(
          runner.commands.first,
          const HerdrCommands().tabRename('w4:t1', 'infra'),
        );
        runner.commands.clear();
        await controller.close(controller.tabs[2]);
        expect(runner.commands.first, const HerdrCommands().tabClose('w4:t3'));
        runner.commands.clear();
        await controller.create();
        expect(runner.commands.take(2), [
          const HerdrCommands().paneList,
          const HerdrCommands().tabCreate(workspaceId: 'w4', cwd: '/srv/infra'),
        ]);
        expect(await controller.move(controller.tabs[0], 1), isFalse);
      },
    );

    test('an unfocused workspace takes its active tab from the workspace '
        'list', () async {
      final runner = FakeHerdr(focused: false);
      final control = HerdrRemoteControl(runnerFactory: () => runner);
      final controller = MultiplexerTabsController(
        backend: HerdrTabsBackend(
          control: control,
          fallbackWorkspaceId: () => 'w4',
        ),
      );
      addTearDown(() async {
        controller.dispose();
        await control.close();
      });
      await controller.refresh();
      expect(runner.commands, [
        const HerdrCommands().tabList,
        const HerdrCommands().workspaceList,
      ]);
      expect(controller.active?.id, 'w4:t2');
    });
  });

  test('an open list keeps its 2 s pace when the layout sets its own', () {
    final controller = MultiplexerTabsController(
      backend: TmuxTabsBackend(
        channel: SerialCommandChannel(runnerFactory: () => FakeTmux(['a'])),
        sessionName: 's',
      ),
    );
    addTearDown(controller.dispose);
    controller.setPollInterval(MultiplexerTabsController.compactPollInterval);
    final end = controller.boostPolling();
    // What a rebuild of the page's poller does while the list is open.
    controller.setPollInterval(MultiplexerTabsController.compactPollInterval);
    expect(controller.pollInterval, MultiplexerTabsController.listPollInterval);
    end();
    end();
    expect(
      controller.pollInterval,
      MultiplexerTabsController.compactPollInterval,
    );
  });

  test('the channel reuses one runner for every command', () async {
    var opened = 0;
    final tmux = FakeTmux(['a', 'b']);
    final channel = SerialCommandChannel(
      runnerFactory: () {
        opened += 1;
        return tmux;
      },
    );
    for (var i = 0; i < 3; i += 1) {
      await channel.query(TmuxWindowCommands.list('s'));
    }
    await channel.close();
    expect(opened, 1);
    expect(tmux.closeCount, 1);
    expect(await channel.query('x'), isNull);
  });

  test('AgentCommandResult is used as is', () {
    // Keeps the import honest for the fakes' shared types.
    expect(
      const AgentCommandResult(stdout: '', stderr: '', exitCode: 0).exitCode,
      0,
    );
  });
}
