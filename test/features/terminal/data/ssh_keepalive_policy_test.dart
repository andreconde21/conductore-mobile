import 'dart:async';
import 'dart:typed_data';

import 'package:conduit/features/terminal/data/ssh_keepalive_policy.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';

/// CON-089: every connection pinged every 10 s, in the background too.
void main() {
  test('the setting in front; slower terminals and quiet side channels in '
      'the background', () {
    final policy = SshKeepalivePolicy();
    expect(
      policy.intervalFor(SshConnectionRole.terminal),
      const Duration(seconds: 30),
    );
    expect(
      policy.intervalFor(SshConnectionRole.side),
      const Duration(seconds: 30),
    );
    policy.background = true;
    expect(
      policy.intervalFor(SshConnectionRole.terminal),
      const Duration(minutes: 2),
    );
    expect(policy.intervalFor(SshConnectionRole.side), isNull);
    policy.foregroundSeconds = 0;
    expect(policy.intervalFor(SshConnectionRole.terminal), isNull);
    policy
      ..background = false
      ..foregroundSeconds = 120;
    expect(
      policy.intervalFor(SshConnectionRole.side),
      const Duration(minutes: 2),
    );
  });

  test('live connections follow changes until they close', () async {
    final policy = SshKeepalivePolicy();
    final terminal = SSHClient(_SilentSocket(), username: 'u');
    final side = SSHClient(_SilentSocket(), username: 'u');
    policy
      ..register(terminal, SshConnectionRole.terminal)
      ..register(side, SshConnectionRole.side);
    expect(terminal.keepAliveInterval, const Duration(seconds: 30));

    policy.background = true;
    expect(terminal.keepAliveInterval, const Duration(minutes: 2));
    expect(side.keepAliveInterval, isNull);

    policy.background = false;
    expect(side.keepAliveInterval, const Duration(seconds: 30));

    side.close();
    await pumpEventQueue();
    expect(policy.trackedCount, 1);
    terminal.close();
    await pumpEventQueue();
    expect(policy.trackedCount, 0);
  });
}

/// A server that never answers: enough for a client that only exists.
class _SilentSocket implements SSHSocket {
  final _in = StreamController<Uint8List>();
  final _out = StreamController<List<int>>();
  final _done = Completer<void>();

  _SilentSocket() {
    _out.stream.listen((_) {});
  }

  @override
  Stream<Uint8List> get stream => _in.stream;

  @override
  StreamSink<List<int>> get sink => _out.sink;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> close() async => destroy();

  @override
  void destroy() {
    if (!_done.isCompleted) _done.complete();
    unawaited(_in.close());
  }
}
