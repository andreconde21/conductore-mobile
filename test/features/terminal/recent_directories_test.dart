import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/sessions/domain/connect_preferences.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:conduit/features/sessions/presentation/connect_picker_sheet.dart';
import 'package:conduit/features/terminal/data/secure_recent_directories_store.dart';
import 'package:conduit/features/terminal/domain/recent_directories.dart';
import 'package:conduit/features/terminal/presentation/recent_directories_controller.dart';
import 'package:conduit/features/terminal/presentation/recent_directory_tracker.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:conduit/features/terminal/presentation/widgets/recent_directories_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  group('recent directory rules', () {
    test('normalizes absolute paths and rejects the rest', () {
      expect(normalizeRecentDirectory(' /srv/app/ '), '/srv/app');
      expect(normalizeRecentDirectory('/'), '/');
      expect(normalizeRecentDirectory('~/x'), isNull);
      expect(normalizeRecentDirectory('relative'), isNull);
      expect(normalizeRecentDirectory('/a\nb'), isNull);
    });

    test('push promotes, dedupes and caps; no-promote keeps order', () {
      var list = <String>[];
      for (var i = 0; i < 25; i++) {
        list = pushRecentDirectory(list, '/d$i');
      }
      expect(list, hasLength(maxRecentDirectories));
      expect(list.first, '/d24');
      expect(list.last, '/d5');
      list = pushRecentDirectory(list, '/d10/');
      expect(list.first, '/d10');
      expect(list.where((d) => d == '/d10'), hasLength(1));
      expect(pushRecentDirectory(list, '/d20', promote: false), same(list));
      expect(pushRecentDirectory(list, '/new', promote: false).first, '/new');
      expect(pushRecentDirectory(list, 'bad'), same(list));
    });

    test('parses OSC 7 reports', () {
      expect(
        parseOsc7Directory(['file://devbox/home/andre/My%20App']),
        '/home/andre/My App',
      );
      expect(parseOsc7Directory(['file:///tmp/']), '/tmp');
      expect(parseOsc7Directory(['file://h/a', 'b']), '/a;b');
      expect(parseOsc7Directory(['kitty-shell-cwd://h/srv']), '/srv');
      expect(parseOsc7Directory(['http://h/x']), isNull);
      expect(parseOsc7Directory([]), isNull);
    });

    test('builds commands with safe quoting', () {
      expect(cdCommand('/srv/app'), 'cd /srv/app');
      expect(cdCommand("/home/a/it's here"), r"cd '/home/a/it'\''s here'");
      expect(tmuxNewWindowCommand('/a b'), "new-window -c '/a b'");
      expect(
        herdrNewTabArguments('/home/a/Projects/Foo'),
        'tab create --cwd /home/a/Projects/Foo --label Foo --focus',
      );
      // In the session's own workspace, without moving Herdr's focus.
      expect(
        herdrNewTabArguments('/srv/api', workspaceId: 'w1', focus: false),
        'tab create --workspace w1 --cwd /srv/api --label api --no-focus',
      );
      expect(directoryBasename('/'), '/');
    });
  });

  test(
    'the secure store round-trips per host and tolerates bad data',
    () async {
      final storage = InMemorySecureStorage();
      final store = SecureRecentDirectoriesStore(storage);
      expect(await store.read('a'), isEmpty);
      await store.write('a', ['/x', '/y']);
      await store.write('b', ['/z']);
      expect(await store.read('a'), ['/x', '/y']);
      expect(await store.read('b'), ['/z']);
      await store.write('a', []);
      expect(await store.read('a'), isEmpty);
      await storage.write(key: 'conduit.recent_directories.v1', value: '{bad');
      expect(await store.read('b'), isEmpty);
    },
  );

  test('the controller serializes writes and notifies', () async {
    final store = InMemoryRecentDirectoriesStore()
      ..directories['h'] = ['/old', 'junk'];
    final controller = RecentDirectoriesController(store);
    addTearDown(controller.dispose);
    var notified = 0;
    controller.addListener(() => notified++);

    await Future.wait([
      controller.record('h', '/one'),
      controller.record('h', '/two'),
      controller.record('h', '/old', promote: false),
    ]);
    expect(controller.directoriesFor('h'), ['/two', '/one', '/old']);
    expect(store.directories['h'], ['/two', '/one', '/old']);
    expect(notified, 2);

    await controller.remove('h', '/one');
    expect(store.directories['h'], ['/two', '/old']);
  });

  group('RecentDirectoryTracker', () {
    test('records OSC 7 reports under the saved host id', () async {
      final workspace = TerminalWorkspaceController(
        ImmediateTerminalRepository(TrackableTerminalSession()),
      );
      addTearDown(workspace.dispose);
      final directories = RecentDirectoriesController(
        InMemoryRecentDirectoriesStore(),
      );
      final tracker = RecentDirectoryTracker(
        workspace: workspace,
        directories: directories,
      );
      addTearDown(tracker.dispose);
      final session = workspace.open(
        const ConnectTarget.herdr(workspaceId: 'w1').apply(buildHost('box')),
      );

      session.terminal.write('\x1b]7;file://box/srv/api\x07');
      session.terminal.write('\x1b]7;file://box/srv/api\x07');
      await _settle();
      await _settle();

      expect(session.workingDirectory, '/srv/api');
      expect(directories.directoriesFor('box'), ['/srv/api']);
    });

    test('reads the tmux pane path when a tmux session disconnects', () async {
      final workspace = TerminalWorkspaceController(
        ImmediateTerminalRepository(TrackableTerminalSession()),
      );
      addTearDown(workspace.dispose);
      final directories = RecentDirectoriesController(
        InMemoryRecentDirectoriesStore(),
      );
      final runner = ScriptedAgentCommandRunner([
        const AgentCommandResult(
          stdout: '/home/u/Projects/Foo\n',
          stderr: '',
          exitCode: 0,
        ),
      ]);
      final tracker = RecentDirectoryTracker(
        workspace: workspace,
        directories: directories,
        runnerFactory: (_) => runner,
      );
      addTearDown(tracker.dispose);
      final session = workspace.open(
        const ConnectTarget.tmux('work').apply(buildHost('box')),
      );
      await session.connect();
      expect(session.isConnected, isTrue);

      await session.disconnect();
      for (var i = 0; i < 5; i++) {
        await _settle();
      }

      expect(runner.commands.single, contains('display-message -p -t work:'));
      expect(runner.commands.single, contains('#{pane_current_path}'));
      expect(runner.closeCount, 1);
      expect(directories.directoriesFor('box'), ['/home/u/Projects/Foo']);
    });

    test('skips the tmux lookup for plain shells and security keys', () async {
      final workspace = TerminalWorkspaceController(
        ImmediateTerminalRepository(TrackableTerminalSession()),
      );
      addTearDown(workspace.dispose);
      var runs = 0;
      final tracker = RecentDirectoryTracker(
        workspace: workspace,
        directories: RecentDirectoriesController(
          InMemoryRecentDirectoriesStore(),
        ),
        runnerFactory: (_) {
          runs++;
          return ScriptedAgentCommandRunner(const []);
        },
      );
      addTearDown(tracker.dispose);
      final plain = workspace.open(buildHost('plain'));
      final keyed = workspace.open(
        const ConnectTarget.tmux('t').apply(
          buildHost('keyed').copyWith(authMethod: SshAuthMethod.hardwareKey),
        ),
      );
      await plain.connect();
      await keyed.connect();
      await workspace.closeAll();
      await _settle();
      expect(runs, 0);
    });
  });

  test('session controller ignores repeated OSC 7 reports', () async {
    final controller = TerminalSessionController(
      host: buildHost('x'),
      repository: ImmediateTerminalRepository(TrackableTerminalSession()),
    );
    addTearDown(controller.dispose);
    final reports = <String>[];
    controller.workingDirectoryReports.listen(reports.add);
    controller.terminal.write('\x1b]7;file://x/a\x1b\\');
    controller.terminal.write('\x1b]7;file://x/a\x07');
    controller.terminal.write('\x1b]7;file://x/b\x07');
    await _settle();
    expect(reports, ['/a', '/b']);
  });

  group('directory connect target', () {
    test('opens a plain shell that starts in the directory', () {
      const target = ConnectTarget.directory('/srv/my app');
      expect(target.key, 'dir:/srv/my app');
      expect(target.title, 'my app');
      expect(target.startupCommand, "cd '/srv/my app'");
      final host = target.apply(
        buildHost('h').copyWith(startTmuxOnConnect: true),
      );
      expect(host.id, 'h#dir:/srv/my app');
      expect(host.startTmuxOnConnect, isFalse);
      expect(ConnectTarget.fromSessionHostId(host.id), target);
      expect(ConnectTarget.fromJson(target.toJson()), target);
      expect(ConnectTarget.fromJson({'kind': 'directory', 'name': ''}), isNull);
    });

    test('is remembered as the last choice but not as a recent', () {
      final preferences = const ConnectPreferences().withChoice(
        const ConnectTarget.directory('/srv'),
        remember: true,
      );
      expect(preferences.lastTarget, const ConnectTarget.directory('/srv'));
      expect(preferences.recents, isEmpty);
    });
  });

  testWidgets('the connect picker lists recent dirs and opens one', (
    tester,
  ) async {
    final picked = <ConnectPickerResult>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConnectPickerSheet(
            host: buildHost('h'),
            runner: ScriptedAgentCommandRunner(const [
              AgentCommandResult(stdout: '', stderr: '', exitCode: 1),
            ]),
            initialTab: ConnectPickerTab.recent,
            recentDirectories: const ['/home/u/Projects/Foo', '/srv'],
            onPicked: picked.add,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('RECENT DIRS'), findsOneWidget);
    await tester.tap(find.text('Foo'));
    await tester.pump();
    expect(
      picked.single.target,
      const ConnectTarget.directory('/home/u/Projects/Foo'),
    );
  });

  testWidgets('the cd to sheet runs the default action on tap and offers '
      'the others in the menu', (tester) async {
    RecentDirectoryPick? pick;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => pick = await showRecentDirectoriesSheet(
              context: context,
              hostName: 'box',
              directories: const ['/srv/api', '/tmp'],
              actions: const [
                RecentDirectoryAction.tmuxWindow,
                RecentDirectoryAction.cd,
              ],
            ),
            child: const Text('go'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('api'));
    await tester.pumpAndSettle();
    expect(
      pick,
      const RecentDirectoryPick('/srv/api', RecentDirectoryAction.tmuxWindow),
    );

    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('More').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('cd here'));
    await tester.pumpAndSettle();
    expect(pick, const RecentDirectoryPick('/tmp', RecentDirectoryAction.cd));
  });

  testWidgets('the cd to sheet explains an empty list', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: RecentDirectoriesSheet(
            hostName: 'box',
            directories: [],
            actions: [RecentDirectoryAction.cd],
          ),
        ),
      ),
    );
    expect(find.textContaining('No directories yet'), findsOneWidget);
  });
}
