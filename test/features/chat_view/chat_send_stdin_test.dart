import 'dart:convert';

import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/chat_view/data/conductore_chat_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records what `send` runs; answers like the companion.
class _Runner implements AgentCommandRunner {
  final List<String> commands = [];

  @override
  Future<AgentCommandResult> run(
    String command, {
    required Duration timeout,
  }) async {
    commands.add(command);
    return const AgentCommandResult(
      stdout: '{"ok":true}',
      stderr: '',
      exitCode: 0,
    );
  }

  @override
  Future<void> close() async {}
}

class _StdinRunner extends _Runner implements StdinAgentCommandRunner {
  final List<String> inputs = [];

  @override
  Future<AgentCommandResult> runWithStdin(
    String command, {
    required String stdin,
    required Duration timeout,
    Future<void>? cancel,
  }) async {
    commands.add(command);
    inputs.add(stdin);
    return const AgentCommandResult(
      stdout: '{"ok":true}',
      stderr: '',
      exitCode: 0,
    );
  }
}

void main() {
  test('send puts the text on stdin, never in the command line', () async {
    final runner = _StdinRunner();
    // Over the host's 128 KiB single-argument limit once base64-encoded.
    final text = 'é${'x' * 120000}\nlast line\n';
    await ConductoreChatClient(runner).send('s-1', text);
    expect(runner.commands, hasLength(1));
    expect(runner.commands.single, contains('send s-1'));
    expect(runner.commands.single, isNot(contains('--text')));
    expect(runner.commands.single.length, lessThan(300));
    // The companion strips exactly one trailing newline.
    expect(runner.inputs.single, '$text\n');

    await ConductoreChatClient(runner).send('s-1', '2', enter: false);
    expect(runner.commands.last, endsWith("send s-1 --no-enter'"));
    expect(runner.inputs.last, '2\n');
  });

  test('a runner without stdin still sends the text base64-encoded', () async {
    final runner = _Runner();
    await ConductoreChatClient(runner).send('s-1', 'hi');
    expect(
      runner.commands.single,
      contains('send s-1 --text-b64 ${base64.encode(utf8.encode('hi'))}'),
    );
  });
}
