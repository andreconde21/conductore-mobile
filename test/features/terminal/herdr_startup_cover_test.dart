import 'dart:async';
import 'dart:convert';

import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:conduit/features/terminal/domain/ssh_terminal_repository.dart';
import 'package:conduit/features/terminal/domain/ssh_terminal_session.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:conduit/features/terminal/presentation/widgets/terminal_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

class _Session implements SshTerminalSession {
  final stdoutCtl = StreamController<List<int>>();
  final sent = <String>[];
  @override
  Future<void> get done => Completer<void>().future;
  @override
  Stream<List<int>> get stdout => stdoutCtl.stream;
  @override
  Stream<List<int>> get stderr => const Stream.empty();
  @override
  Future<void> close() async {}
  @override
  void resize(int c, int r, int pw, int ph) {}
  @override
  Future<void> send(List<int> data) async => sent.add(utf8.decode(data));
}

class _Repo implements SshTerminalRepository {
  final session = _Session();
  @override
  Future<SshTerminalSession> connect(
    SavedHost host, {
    required int columns,
    required int rows,
  }) async => session;
}

/// What a login shell shows once the attach is typed: the prompt and the
/// echoed command (CON-058: André saw the Herdr calls there).
const _echo = 'dev@box:~\$ herdr workspace focus w2 >/dev/null 2>&1; herdr\r\n';

void main() {
  const target = ConnectTarget.herdr(workspaceId: 'w2');

  TerminalSessionController herdrSession(_Repo repo) =>
      TerminalSessionController(
        host: target.apply(buildHost('h')),
        repository: repo,
        startupCommand: target.startupCommand,
      );

  test('the shell is covered from the typed attach until Herdr takes the '
      'alternate screen', () async {
    final repo = _Repo();
    final session = herdrSession(repo);
    addTearDown(session.dispose);

    expect(session.startupCover.value, isFalse);
    await session.connect();
    expect(repo.session.sent.single, startsWith('herdr workspace focus w2'));
    expect(session.startupCover.value, isTrue);

    repo.session.stdoutCtl.add(utf8.encode(_echo));
    await pumpEventQueue();
    expect(session.startupCover.value, isTrue);

    repo.session.stdoutCtl.add(utf8.encode('\x1b[?1049h\x1b[2JHerdr'));
    await pumpEventQueue();
    expect(session.startupCover.value, isFalse);
  });

  test('over Mosh, Herdr turning on mouse reports lifts it', () async {
    // mosh-server redraws the screen itself and never passes the
    // alternate screen on; the mouse mode it does.
    final repo = _Repo();
    final session = herdrSession(repo);
    addTearDown(session.dispose);
    await session.connect();

    repo.session.stdoutCtl.add(utf8.encode('\x1b[?1000h\x1b[?1006h\x1b[H'));
    await pumpEventQueue();
    expect(session.startupCover.value, isFalse);
  });

  test('a shell, tmux or a cd is never covered', () async {
    for (final startup in [null, 'cd /srv', 'tmux new-session -A -s main']) {
      final repo = _Repo();
      final session = TerminalSessionController(
        host: buildHost('h'),
        repository: repo,
        startupCommand: startup,
      );
      addTearDown(session.dispose);
      await session.connect();
      expect(session.startupCover.value, isFalse, reason: '$startup');
    }
  });

  test('disconnecting drops the cover', () async {
    final repo = _Repo();
    final session = herdrSession(repo);
    addTearDown(session.dispose);
    await session.connect();
    expect(session.startupCover.value, isTrue);
    await session.disconnect();
    expect(session.startupCover.value, isFalse);
  });

  Widget surface(TerminalSessionController session) => MaterialApp(
    home: Scaffold(
      body: TerminalSurface(
        session: session,
        palette: AppPalette.catppuccin,
        brightness: Brightness.dark,
        fontFamily: 'monospace',
        fontSize: 12,
        predictiveEchoEnabled: false,
        terminalMouseInput: false,
        focusNode: null,
        tmuxScrollMode: false,
        onExitTmuxScrollMode: () {},
      ),
    ),
  );

  final cover = find.byKey(const ValueKey('terminal-startup-cover'));

  testWidgets('the terminal view hides the typed attach behind it', (
    tester,
  ) async {
    final repo = _Repo();
    final session = herdrSession(repo);
    addTearDown(session.dispose);
    await tester.pumpWidget(surface(session));
    await tester.pump();
    expect(cover, findsOneWidget);
    expect(find.text('Opening Herdr…'), findsOneWidget);

    repo.session.stdoutCtl.add(utf8.encode('$_echo\x1b[?1049hHerdr'));
    await tester.pump();
    await tester.pump();
    expect(cover, findsNothing);
  });

  testWidgets('a Herdr that does not start shows the shell after a while', (
    tester,
  ) async {
    final repo = _Repo();
    final session = herdrSession(repo);
    addTearDown(session.dispose);
    await tester.pumpWidget(surface(session));
    await tester.pump();
    repo.session.stdoutCtl.add(utf8.encode('herdr: command not found\r\n'));
    await tester.pump();
    expect(cover, findsOneWidget);

    await tester.pump(TerminalSessionController.startupCoverTimeout);
    await tester.pump();
    expect(cover, findsNothing);
    expect(session.startupCover.value, isFalse);
  });

  testWidgets('a covered session nobody shows holds no timer', (tester) async {
    // The app keeps sessions whose view is gone (another tab, the home
    // board): a timer of theirs would outlive every widget.
    final repo = _Repo();
    final session = herdrSession(repo);
    addTearDown(session.dispose);
    await tester.pumpWidget(surface(session));
    await tester.pump();
    expect(cover, findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    expect(session.startupCover.value, isTrue);
  });
}
