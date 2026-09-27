import 'dart:async';

import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';

/// A command runner for [host] that asks [attention] for a connection on
/// every command, so a chat kept open across a reconnect follows the
/// monitor's new connection instead of holding the one it closed.
///
/// While [host] is not monitored it uses a connection of its own, made on
/// first use and closed by [close]; the monitor's is never closed here.
class AttentionHostRunner implements StdinAgentCommandRunner {
  AttentionHostRunner(this._attention, this.host);

  final AgentAttentionController _attention;
  final SavedHost host;
  AgentCommandRunner? _own;
  bool _closed = false;

  AgentCommandRunner get _current {
    if (_attention.isMonitoring(host.id)) {
      final (runner, :owned) = _attention.runnerFor(host);
      if (!owned) return runner;
      // The monitor stopped in between: keep what we were given.
      if (_own == null) return _own = runner;
      unawaited(runner.close());
      return _own!;
    }
    return _own ??= _attention.runnerFor(host).$1;
  }

  @override
  Future<AgentCommandResult> run(String command, {required Duration timeout}) {
    if (_closed) throw StateError('The runner is closed.');
    return _current.run(command, timeout: timeout);
  }

  @override
  Future<AgentCommandResult> runWithStdin(
    String command, {
    required String stdin,
    required Duration timeout,
    Future<void>? cancel,
  }) {
    if (_closed) throw StateError('The runner is closed.');
    final runner = _current;
    if (runner is! StdinAgentCommandRunner) {
      throw UnsupportedError('This connection cannot pass standard input.');
    }
    return runner.runWithStdin(
      command,
      stdin: stdin,
      timeout: timeout,
      cancel: cancel,
    );
  }

  @override
  Future<void> close() async {
    _closed = true;
    final own = _own;
    _own = null;
    await own?.close();
  }
}
