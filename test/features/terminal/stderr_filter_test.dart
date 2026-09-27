import 'dart:async';

import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/terminal/domain/ssh_terminal_repository.dart';
import 'package:conduit/features/terminal/domain/ssh_terminal_session.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

class _Session implements SshTerminalSession {
  final stdoutCtl = StreamController<List<int>>();
  final stderrCtl = StreamController<List<int>>();
  @override
  Future<void> get done => Completer<void>().future;
  @override
  Stream<List<int>> get stdout => stdoutCtl.stream;
  @override
  Stream<List<int>> get stderr => stderrCtl.stream;
  @override
  Future<void> close() async {}
  @override
  void resize(int c, int r, int pw, int ph) {}
  @override
  Future<void> send(List<int> data) async {}
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

String _screen(TerminalSessionController c) =>
    c.terminal.buffer.lines.toList().map((l) => l.toString()).join('\n');

void main() {
  test('stderr goes through the string-sequence filter too, with its own '
      'state', () async {
    final repo = _Repo();
    final c = TerminalSessionController(host: buildHost('h'), repository: repo);
    addTearDown(c.dispose);
    await c.connect();

    // A DCS split across stderr chunks, with stdout between them.
    repo.session.stderrCtl.add('err \x1bPtmux;HIDDEN'.codeUnits);
    await pumpEventQueue();
    repo.session.stdoutCtl.add('out '.codeUnits);
    await pumpEventQueue();
    repo.session.stderrCtl.add('STILL\x1b\\ shown'.codeUnits);
    await pumpEventQueue();

    final screen = _screen(c);
    expect(screen, contains('err '));
    expect(screen, contains('out '));
    expect(screen, contains(' shown'));
    expect(screen, isNot(contains('HIDDEN')));
    expect(screen, isNot(contains('STILL')));
  });
}
