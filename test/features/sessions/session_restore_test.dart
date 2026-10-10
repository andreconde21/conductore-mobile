import 'dart:async';
import 'dart:convert';

import 'package:conduit/core/app_failure.dart';
import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/core/theme/theme_preferences_repository.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/sessions/data/secure_session_snapshot_repository.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:conduit/features/sessions/domain/session_snapshot.dart';
import 'package:conduit/features/sessions/presentation/session_restore_controller.dart';
import 'package:conduit/features/terminal/domain/ssh_terminal_repository.dart';
import 'package:conduit/features/terminal/domain/ssh_terminal_session.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

/// Connects only when the test says so, recording each attempt.
class ScriptedRepository implements SshTerminalRepository {
  final attempts = <String>[];
  final _pending = <String, Completer<SshTerminalSession>>{};
  final sessions = <String, TrackableTerminalSession>{};

  int get inFlight => _pending.length;

  @override
  Future<SshTerminalSession> connect(
    SavedHost host, {
    required int columns,
    required int rows,
  }) {
    attempts.add(host.id);
    final completer = Completer<SshTerminalSession>();
    _pending[host.id] = completer;
    return completer.future;
  }

  void succeed(String hostId) {
    final session = TrackableTerminalSession();
    sessions[hostId] = session;
    _pending.remove(hostId)!.complete(session);
  }

  void fail(String hostId) {
    _pending.remove(hostId)!.completeError(const AppFailure('unreachable'));
  }
}

SavedHost machine(
  String id, {
  SshAuthMethod auth = SshAuthMethod.password,
  bool tmuxOnConnect = false,
}) => buildHost(id).copyWith(
  name: 'Box $id',
  authMethod: auth,
  startTmuxOnConnect: tmuxOnConnect,
);

ConnectTarget herdr(String workspace, {String label = ''}) =>
    ConnectTarget.herdr(workspaceId: workspace, label: label);

void main() {
  late ScriptedRepository repository;
  late TerminalWorkspaceController workspace;
  late InMemorySessionSnapshotRepository store;
  late Map<String, SavedHost> hosts;
  late SessionRestoreController restore;
  var disposed = false;

  /// Lets a settled connect return: its last await resumes on the real
  /// event loop (a root-zone future), outside the test's fake time.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
  }

  /// Ends a widget test: drops the controllers (and their timers) before
  /// the framework checks for pending timers.
  Future<void> finish(WidgetTester tester) async {
    restore.dispose();
    workspace.dispose();
    disposed = true;
    await tester.pump(const Duration(minutes: 1));
  }

  SessionRestoreController build({bool enabled = true}) =>
      SessionRestoreController(
        workspace: workspace,
        repository: store,
        findHost: (id) async => hosts[id],
        enabled: enabled,
      );

  TerminalSessionController openTarget(SavedHost host, ConnectTarget target) =>
      workspace.open(
        target.apply(host),
        startupCommand: target.startupCommand,
        target: target,
      );

  setUp(() {
    repository = ScriptedRepository();
    workspace = TerminalWorkspaceController(repository);
    store = InMemorySessionSnapshotRepository();
    hosts = {
      'a': machine('a'),
      'b': machine('b', tmuxOnConnect: true),
      'key': machine('key', auth: SshAuthMethod.hardwareKey),
    };
    restore = build();
    disposed = false;
  });

  tearDown(() {
    if (disposed) return;
    restore.dispose();
    workspace.dispose();
  });

  group('snapshot', () {
    test('round-trips through JSON without secrets', () {
      final snapshot = SessionSnapshot(
        entries: [
          SessionSnapshotEntry(
            hostId: 'a',
            target: herdr('w1', label: 'api'),
            customTitle: 'Backend',
            title: 'Backend',
          ),
          const SessionSnapshotEntry(
            hostId: 'b',
            target: ConnectTarget.tmux('main'),
          ),
          const SessionSnapshotEntry(
            hostId: 'a',
            target: ConnectTarget.shell(),
          ),
        ],
        activeIndex: 1,
      );
      final encoded = jsonEncode(snapshot.toJson());
      expect(SessionSnapshot.fromJson(jsonDecode(encoded)), snapshot);
      expect(encoded, isNot(contains('pw')));
      expect(snapshot.entries.first.sessionHostId, 'a#herdr:w1');
      expect(snapshot.entries.last.sessionHostId, 'a');
    });

    test('drops damaged entries and clamps the active index', () {
      final snapshot = SessionSnapshot.fromJson({
        'version': SessionSnapshot.version,
        'active': 7,
        'sessions': [
          {'hostId': '', 'target': const ConnectTarget.shell().toJson()},
          {'hostId': 'a', 'target': 'nope'},
          {'hostId': 'a', 'target': const ConnectTarget.tmux('x').toJson()},
        ],
      });
      expect(snapshot.entries.single.target, const ConnectTarget.tmux('x'));
      expect(snapshot.activeIndex, 0);
      expect(SessionSnapshot.fromJson({'version': 99}), SessionSnapshot.empty);
    });

    test('secure repository round trip, and clear on an empty list', () async {
      FlutterSecureStorage.setMockInitialValues({});
      const storage = FlutterSecureStorage();
      const secure = SecureSessionSnapshotRepository(storage);
      final snapshot = SessionSnapshot(
        entries: [SessionSnapshotEntry(hostId: 'a', target: herdr('w1'))],
      );
      await secure.save(snapshot);
      expect(await secure.load(), snapshot);
      await secure.save(SessionSnapshot.empty);
      expect(
        await storage.read(key: SecureSessionSnapshotRepository.storageKey),
        isNull,
      );
      await storage.write(
        key: SecureSessionSnapshotRepository.storageKey,
        value: '{broken',
      );
      expect(await secure.load(), SessionSnapshot.empty);
    });
  });

  test('the restore setting defaults on and persists', () async {
    final repository = ThemePreferencesRepository(InMemorySecureStorage());
    expect((await repository.load()).restoreSessionsOnLaunch, isTrue);
    await repository.save(
      const ThemePreferences(
        themeMode: ThemeMode.dark,
        palette: AppPalette.everforest,
        restoreSessionsOnLaunch: false,
      ),
    );
    expect((await repository.load()).restoreSessionsOnLaunch, isFalse);
  });

  group('saving', () {
    testWidgets('open, rename, reorder and close are saved, debounced', (
      tester,
    ) async {
      await restore.restore();
      openTarget(hosts['a']!, herdr('w1', label: 'api'));
      final tmux = openTarget(hosts['b']!, const ConnectTarget.tmux('main'));
      workspace.open(
        hosts['a']!.copyWith(id: 'local-1', isLocal: true, name: 'Local'),
      );
      expect(store.saves, 0);
      await tester.pump(const Duration(seconds: 1));
      expect(store.saves, 1);
      expect(store.stored.entries.map((e) => e.sessionHostId), [
        'a#herdr:w1',
        'b#tmux:main',
      ]);
      expect(store.stored.entries.first.target.label, 'api');

      tmux.rename('Work');
      workspace.move(1, 0);
      await tester.pump(const Duration(seconds: 1));
      expect(store.saves, 2);
      expect(store.stored.entries.first.customTitle, 'Work');
      expect(store.stored.entries.first.hostId, 'b');

      // A status change alone does not rewrite the same list.
      workspace.activate(tmux);
      await tester.pump(const Duration(seconds: 1));
      final saves = store.saves;
      workspace.notifyListeners();
      await tester.pump(const Duration(seconds: 1));
      expect(store.saves, saves);

      await workspace.close(tmux);
      await tester.pump(const Duration(seconds: 1));
      expect(store.stored.entries.single.sessionHostId, 'a#herdr:w1');
      await finish(tester);
    });

    testWidgets('nothing is saved before the saved list was read', (
      tester,
    ) async {
      store.stored = SessionSnapshot(
        entries: [SessionSnapshotEntry(hostId: 'a', target: herdr('w1'))],
      );
      openTarget(hosts['b']!, const ConnectTarget.tmux('x'));
      await tester.pump(const Duration(seconds: 1));
      expect(store.saves, 0);
      await finish(tester);
    });
  });

  group('restoring', () {
    setUp(() {
      store.stored = SessionSnapshot(
        entries: [
          SessionSnapshotEntry(
            hostId: 'a',
            target: herdr('w1', label: 'api'),
          ),
          const SessionSnapshotEntry(
            hostId: 'b',
            target: ConnectTarget.tmux('main'),
            customTitle: 'Main',
          ),
          SessionSnapshotEntry(hostId: 'a', target: herdr('w2')),
          SessionSnapshotEntry(hostId: 'a', target: herdr('w3')),
          const SessionSnapshotEntry(
            hostId: 'gone',
            target: ConnectTarget.shell(),
          ),
        ],
        activeIndex: 2,
      );
    });

    testWidgets('tiles come back in order, with the active one in front', (
      tester,
    ) async {
      await restore.restore();
      expect(workspace.sessions.map((s) => s.host.id), [
        'a#herdr:w1',
        'b#tmux:main',
        'a#herdr:w2',
        'a#herdr:w3',
      ]);
      expect(workspace.activeSession!.host.id, 'a#herdr:w2');
      expect(workspace.sessions[1].title, 'Main');
      expect(workspace.sessions.first.host.name, 'Box a: api');
      expect(restore.noteFor(workspace.sessions.first), 'Reconnecting…');
      await tester.pump();
      // Only the active one connects while the home grid is not showing.
      expect(repository.attempts, ['a#herdr:w2']);
      await finish(tester);
    });

    testWidgets('others reconnect on the home grid, two at a time', (
      tester,
    ) async {
      await restore.restore();
      await tester.pump();
      restore.setHomeVisible(true);
      await tester.pump();
      expect(repository.attempts, ['a#herdr:w2', 'a#herdr:w1']);
      expect(repository.inFlight, 2);

      repository.succeed('a#herdr:w2');
      await tester.pump();
      expect(repository.attempts.last, 'b#tmux:main');
      expect(restore.noteFor(workspace.activeSession!), isNull);

      repository.succeed('a#herdr:w1');
      await tester.pump();
      expect(repository.attempts.last, 'a#herdr:w3');
      repository.succeed('b#tmux:main');
      repository.succeed('a#herdr:w3');
      await tester.pump();
      expect(repository.attempts, hasLength(4));
      expect(workspace.sessions.every((s) => s.isConnected), isTrue);
      await finish(tester);
    });

    testWidgets('a failing session backs off, then waits for a tap', (
      tester,
    ) async {
      store.stored = SessionSnapshot(
        entries: [SessionSnapshotEntry(hostId: 'a', target: herdr('w1'))],
      );
      await restore.restore();
      await tester.pump();
      final session = workspace.activeSession!;
      for (final wait in restore.backoff) {
        repository.fail('a#herdr:w1');
        await settle(tester);
        expect(restore.noteFor(session), 'Reconnecting…');
        final before = repository.attempts.length;
        await tester.pump(wait - const Duration(milliseconds: 1));
        expect(repository.attempts.length, before);
        await tester.pump(const Duration(milliseconds: 1));
        await tester.pump();
        expect(repository.attempts.length, before + 1);
      }
      repository.fail('a#herdr:w1');
      await settle(tester);
      await tester.pump(const Duration(minutes: 5));
      expect(repository.attempts, hasLength(restore.backoff.length + 1));
      expect(restore.noteFor(session), 'Tap to reconnect');
      await finish(tester);
    });

    testWidgets('Herdr and tmux reattach with their startup commands', (
      tester,
    ) async {
      await restore.restore();
      restore.setHomeVisible(true);
      await tester.pump();
      repository.succeed('a#herdr:w2');
      repository.succeed('a#herdr:w1');
      await tester.pump();
      repository.succeed('b#tmux:main');
      await tester.pump();

      String typed(String id) =>
          repository.sessions[id]!.sent.map(utf8.decode).join();
      expect(
        typed('a#herdr:w1'),
        'herdr workspace focus w1 >/dev/null 2>&1; herdr\r',
      );
      expect(typed('b#tmux:main'), 'tmux new-session -A -s main\r');
      await finish(tester);
    });

    testWidgets('plain shells come back ended and never auto-connect', (
      tester,
    ) async {
      store.stored = const SessionSnapshot(
        entries: [
          SessionSnapshotEntry(hostId: 'a', target: ConnectTarget.shell()),
          SessionSnapshotEntry(
            hostId: 'a',
            target: ConnectTarget.directory('/srv'),
          ),
          // A machine that starts tmux on connect reattaches even as a shell.
          SessionSnapshotEntry(hostId: 'b', target: ConnectTarget.shell()),
        ],
      );
      await restore.restore();
      restore.setHomeVisible(true);
      await tester.pump();
      final [shell, directory, tmux] = workspace.sessions;
      expect(restore.modeOf(shell), RestoredSessionMode.ended);
      expect(restore.modeOf(directory), RestoredSessionMode.ended);
      expect(restore.noteFor(shell), 'Shell ended · tap to start a new one');
      expect(restore.modeOf(tmux), RestoredSessionMode.automatic);
      expect(repository.attempts, ['b']);

      // Dismissing is closing the tile.
      await workspace.close(shell);
      expect(restore.modeOf(shell), isNull);
      expect(workspace.sessions, hasLength(2));
      await finish(tester);
    });

    testWidgets('hardware-key machines wait for a tap', (tester) async {
      store.stored = SessionSnapshot(
        entries: [SessionSnapshotEntry(hostId: 'key', target: herdr('w1'))],
      );
      await restore.restore();
      restore.setHomeVisible(true);
      await tester.pump(const Duration(seconds: 5));
      final session = workspace.activeSession!;
      expect(repository.attempts, isEmpty);
      expect(restore.modeOf(session), RestoredSessionMode.tapToReconnect);
      expect(restore.noteFor(session), 'Tap to reconnect');
      expect(session.status, TerminalConnectionStatus.idle);

      // Opening it (the terminal page connects it) clears the note.
      unawaited(session.connect());
      repository.succeed('key#herdr:w1');
      await tester.pump();
      expect(restore.noteFor(session), isNull);
      expect(restore.modeOf(session), isNull);
      await finish(tester);
    });

    testWidgets('with the setting off nothing comes back', (tester) async {
      restore.dispose();
      restore = build(enabled: false);
      await restore.restore();
      await tester.pump(const Duration(seconds: 1));
      expect(workspace.sessions, isEmpty);
      expect(store.stored, SessionSnapshot.empty);

      openTarget(hosts['a']!, herdr('w9'));
      await tester.pump(const Duration(seconds: 1));
      expect(store.saves, 0);

      restore.enabled = true;
      await tester.pump(const Duration(seconds: 1));
      expect(store.stored.entries.single.sessionHostId, 'a#herdr:w9');
      restore.enabled = false;
      await tester.pump();
      expect(store.stored, SessionSnapshot.empty);
      await finish(tester);
    });

    testWidgets('a session the user reopened first is not duplicated', (
      tester,
    ) async {
      final mine = openTarget(hosts['a']!, herdr('w3'));
      await restore.restore();
      expect(workspace.sessions, hasLength(4));
      expect(workspace.activeSession, mine);
      expect(restore.modeOf(mine), isNull);
      await finish(tester);
    });

    testWidgets('the list survives a lock and comes back on unlock', (
      tester,
    ) async {
      await restore.restore();
      await tester.pump(const Duration(seconds: 1));
      await restore.holdForLock();
      await workspace.closeAll();
      await tester.pump(const Duration(seconds: 1));
      expect(store.stored.entries, hasLength(4));
      expect(store.stored.activeIndex, 2);

      await restore.restore();
      expect(workspace.sessions, hasLength(4));
      expect(workspace.activeSession!.host.id, 'a#herdr:w2');
      await finish(tester);
    });
  });

  group('tabs for workspaces gone over a day (CON-115)', () {
    late ValueNotifier<Set<TerminalSessionController>> closed;
    late DateTime now;
    final launch = DateTime.utc(2026, 10, 10, 12);

    setUp(() {
      closed = ValueNotifier(const {});
      now = launch;
      restore.dispose();
      restore = SessionRestoreController(
        workspace: workspace,
        repository: store,
        findHost: (id) async => hosts[id],
        closedWorkspaces: closed,
        clock: () => now,
      );
      store.stored = SessionSnapshot(
        entries: [
          SessionSnapshotEntry(
            hostId: 'a',
            target: herdr('w1', label: 'api'),
            customTitle: 'API',
            // Found gone two days ago.
            workspaceGoneAt: launch.subtract(const Duration(days: 2)),
          ),
          SessionSnapshotEntry(
            hostId: 'a',
            target: herdr('w2'),
            // Found gone two hours ago: still young.
            workspaceGoneAt: launch.subtract(const Duration(hours: 2)),
          ),
          SessionSnapshotEntry(hostId: 'a', target: herdr('w3')),
          SessionSnapshotEntry(
            hostId: 'a',
            target: herdr('w4'),
            workspaceGoneAt: launch.subtract(const Duration(days: 3)),
          ),
        ],
        activeIndex: 2,
      );
    });

    tearDown(() => closed.dispose());

    TerminalSessionController tab(String id) =>
        workspace.sessions.firstWhere((s) => s.host.id == 'a#herdr:$id');

    test('the gone time round-trips through JSON', () {
      final entry = SessionSnapshotEntry(
        hostId: 'a',
        target: herdr('w1'),
        workspaceGoneAt: launch,
      );
      final back = SessionSnapshotEntry.fromJson(
        jsonDecode(jsonEncode(entry.toJson())),
      );
      expect(back, entry);
      expect(back!.workspaceGoneAt, launch);
      expect(
        SessionSnapshotEntry.fromJson(
          jsonDecode(jsonEncode(store.stored.entries[2].toJson())),
        )!.workspaceGoneAt,
        isNull,
      );
    });

    testWidgets('a tab gone over a day closes on launch, with Undo', (
      tester,
    ) async {
      await restore.restore();
      final active = workspace.activeSession;
      // Herdr says w1 and w2 are gone; w4's workspace exists again.
      closed.value = {tab('w1'), tab('w2')};
      await tester.pump(const Duration(seconds: 1));
      expect(workspace.sessions, hasLength(4));
      await tester.pump(const Duration(seconds: 2));

      expect(workspace.sessions.map((s) => s.host.id), [
        'a#herdr:w2',
        'a#herdr:w3',
        'a#herdr:w4',
      ]);
      expect(workspace.activeSession, active);
      final notice = restore.autoClosed.value!;
      expect(
        notice.message,
        'Closed 1 tab for a workspace that no longer exists',
      );
      expect(notice.tabs.single.index, 0);

      // Younger: the CON-103 notice stays, and so does its time.
      await tester.pump(const Duration(seconds: 1));
      expect(
        store.stored.entries.first.workspaceGoneAt,
        launch.subtract(const Duration(hours: 2)),
      );

      now = launch.add(const Duration(minutes: 1));
      await restore.undoAutoClose(notice);
      expect(workspace.sessions.map((s) => s.host.id), [
        'a#herdr:w1',
        'a#herdr:w2',
        'a#herdr:w3',
        'a#herdr:w4',
      ]);
      expect(workspace.sessions.first.title, 'API');
      expect(workspace.activeSession, active);
      expect(restore.autoClosed.value, isNull);

      // Brought back: open for the rest of this run, gone from now on.
      closed.value = {tab('w1'), tab('w2')};
      await tester.pump(const Duration(seconds: 3));
      expect(workspace.sessions, hasLength(4));
      expect(
        store.stored.entries.first.workspaceGoneAt,
        launch.add(const Duration(minutes: 1)),
      );
      await finish(tester);
    });

    testWidgets('several close together under one notice', (tester) async {
      await restore.restore();
      closed.value = {tab('w1')};
      await tester.pump(const Duration(seconds: 1));
      closed.value = {tab('w1'), tab('w4')};
      await tester.pump(const Duration(seconds: 2));

      expect(workspace.sessions.map((s) => s.host.id), [
        'a#herdr:w2',
        'a#herdr:w3',
      ]);
      expect(
        restore.autoClosed.value!.message,
        'Closed 2 tabs for workspaces that no longer exist',
      );
      await restore.undoAutoClose(restore.autoClosed.value!);
      expect(workspace.sessions.map((s) => s.host.id), [
        'a#herdr:w1',
        'a#herdr:w2',
        'a#herdr:w3',
        'a#herdr:w4',
      ]);
      await finish(tester);
    });

    testWidgets('a tab whose workspace exists is never closed', (tester) async {
      await restore.restore();
      // w4 was saved as gone three days ago, but Herdr has it now; another
      // tab's change must not close it.
      closed.value = {tab('w2')};
      await tester.pump(const Duration(seconds: 5));
      // Nor does a tab that was kept on a workspace again before the
      // gathered close runs.
      closed.value = {tab('w1')};
      closed.value = const {};
      await tester.pump(const Duration(seconds: 5));

      expect(workspace.sessions, hasLength(4));
      expect(restore.autoClosed.value, isNull);
      await finish(tester);
    });

    testWidgets('a workspace found gone in this run is timed, not closed', (
      tester,
    ) async {
      await restore.restore();
      now = launch.add(const Duration(hours: 1));
      closed.value = {tab('w3')};
      await tester.pump(const Duration(seconds: 1));
      expect(
        store.stored.entries[2].workspaceGoneAt,
        launch.add(const Duration(hours: 1)),
      );

      // A day later, still running: only a launch closes it.
      now = launch.add(const Duration(days: 2));
      // Another check finds it gone again.
      closed.value = {tab('w3')};
      await tester.pump(const Duration(seconds: 5));
      expect(workspace.sessions, hasLength(4));

      // Kept on what Herdr shows: no longer gone.
      closed.value = const {};
      await tester.pump(const Duration(seconds: 1));
      expect(store.stored.entries[2].workspaceGoneAt, isNull);
      await finish(tester);
    });
  });
}
