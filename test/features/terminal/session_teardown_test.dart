import 'dart:async';

import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/terminal/domain/ssh_terminal_repository.dart';
import 'package:conduit/features/terminal/domain/ssh_terminal_session.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

/// Like DartSshTerminalSession: `done` is the shell channel; the SSH
/// client stays open until close().
class _Session implements SshTerminalSession {
  final shellExited = Completer<void>();
  final stdoutCtl = StreamController<List<int>>();
  int closeCount = 0;
  @override
  Future<void> get done => shellExited.future;
  @override
  Stream<List<int>> get stdout => stdoutCtl.stream;
  @override
  Stream<List<int>> get stderr => const Stream.empty();
  @override
  Future<void> close() async => closeCount++;
  @override
  void resize(int c, int r, int pw, int ph) {}
  @override
  Future<void> send(List<int> data) async {}
}

class _Repo implements SshTerminalRepository {
  final sessions = <_Session>[];
  @override
  Future<SshTerminalSession> connect(
    SavedHost host, {
    required int columns,
    required int rows,
  }) async {
    final s = _Session();
    sessions.add(s);
    return s;
  }
}

String _screen(TerminalSessionController c) =>
    c.terminal.buffer.lines.toList().map((l) => l.toString()).join('\n');

void main() {
  test('a remote shell exit closes the session before Reconnect', () async {
    final repo = _Repo();
    final c = TerminalSessionController(host: buildHost('h'), repository: repo);
    await c.connect();
    expect(c.isConnected, isTrue);

    repo.sessions.first.shellExited.complete();
    await pumpEventQueue();
    expect(c.status, TerminalConnectionStatus.disconnected);
    expect(repo.sessions.first.closeCount, 1);

    await c.disconnect();
    await c.connect();
    expect(repo.sessions, hasLength(2));
    expect(repo.sessions.first.closeCount, 1);

    // The old session's output never reaches the new terminal.
    repo.sessions.first.stdoutCtl.add('GHOST'.codeUnits);
    await pumpEventQueue();
    expect(_screen(c), isNot(contains('GHOST')));
    c.dispose();
  });

  test('a stream error closes the session and silences its output', () async {
    final repo = _Repo();
    final c = TerminalSessionController(host: buildHost('h'), repository: repo);
    await c.connect();

    repo.sessions.first.stdoutCtl.addError(StateError('boom'));
    await pumpEventQueue();
    expect(c.status, TerminalConnectionStatus.failed);
    expect(repo.sessions.first.closeCount, 1);

    await c.connect();
    expect(c.isConnected, isTrue);
    repo.sessions.first.stdoutCtl.add('GHOST'.codeUnits);
    await pumpEventQueue();
    expect(_screen(c), isNot(contains('GHOST')));

    c.dispose();
    await pumpEventQueue();
    expect(repo.sessions.last.closeCount, 1);
  });
}
