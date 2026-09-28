import 'dart:convert';
import 'dart:io';

import 'package:conduit/core/app_failure.dart';
import 'package:conduit/features/agent_attention/data/conductore_host_attention_provider.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention_provider.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

/// `conductore-hostd status` as the protocol-1 contract specifies it.
const statusFixture = '''
{"version":1,"seq":7,"agents":[
  {"sessionId":"s-1","name":"api","cwd":"/home/andre/api",
   "tmux":{"session":"main","window":2,"paneId":"%5"},
   "state":"needs_permission","lastEvent":"PreToolUse","lastToolName":"Bash",
   "updatedAt":1758700000000,
   "pending":[{"id":"req-1","toolName":"Bash","summary":"rm -rf build",
     "toolInput":{"command":"rm -rf build","description":"Clean"},
     "createdAt":1758700000000}]},
  {"sessionId":"s-2","name":"","cwd":"/srv/web","tmux":null,
   "state":"working","lastEvent":"PostToolUse","lastToolName":null,
   "updatedAt":1758700001000,"pending":[]},
  {"sessionId":"s-3","name":"chat","cwd":"/tmp","tmux":null,
   "herdr":{"workspaceId":"w1","tabId":"w1:t1","paneId":"w1:p1","name":null},
   "state":"waiting_input","lastEvent":"Stop","lastToolName":null,
   "lastMessage":"Done. Shall I push?",
   "updatedAt":1758700002000,"pending":[]},
  {"sessionId":"s-4","name":"old","cwd":"/tmp","tmux":null,
   "state":"ended","lastEvent":"SessionEnd","lastToolName":null,
   "updatedAt":1758700003000,"pending":[]}
]}
''';

void main() {
  const provider = ConductoreHostAttentionProvider();

  AgentCommandResult ok(String stdout) =>
      AgentCommandResult(stdout: stdout, stderr: '', exitCode: 0);

  group('parseSnapshot', () {
    test('maps the contract onto agent records', () {
      final snapshot = ConductoreHostAttentionProvider.parseSnapshot(
        statusFixture,
      );
      expect(snapshot.sequence, 7);
      expect(snapshot.agents, hasLength(4));

      final api = snapshot.agents[0];
      expect(api.id, 's-1');
      expect(api.name, 'api');
      expect(api.kind, 'claude');
      expect(api.state, AgentAttentionState.needsInput);
      // A tmux location has no Herdr workspace; the cwd is never one.
      expect(api.workspace, isNull);
      expect(api.tab, 'main:2');
      expect(api.pane, '%5');
      expect(
        api.stateChangedAt,
        DateTime.fromMillisecondsSinceEpoch(1758700000000, isUtc: true),
      );
      expect(api.pendingRequests, hasLength(1));
      final request = api.pendingRequests.single;
      expect(request.id, 'req-1');
      expect(request.toolName, 'Bash');
      expect(request.summary, 'rm -rf build');
      expect(request.toolInput, contains('"command": "rm -rf build"'));
      expect(
        request.createdAt,
        DateTime.fromMillisecondsSinceEpoch(1758700000000, isUtc: true),
      );

      // An unnamed agent is labelled by its working directory.
      final web = snapshot.agents[1];
      expect(web.name, 'web');
      expect(web.state, AgentAttentionState.working);
      expect(web.tab, isNull);
      expect(web.workspace, isNull);
      expect(web.pendingRequests, isEmpty);

      expect(api.lastMessage, isNull);

      // A Herdr pane stands in for the tmux location.
      final chat = snapshot.agents[2];
      expect(chat.state, AgentAttentionState.needsInput);
      expect(chat.workspace, 'w1');
      expect(chat.tab, 'w1:t1');
      expect(chat.pane, 'w1:p1');
      expect(chat.lastMessage, 'Done. Shall I push?');
      expect(snapshot.agents[3].state, AgentAttentionState.finished);
    });

    test('maps every documented state', () {
      expect(
        ConductoreHostAttentionProvider.parseState('working'),
        AgentAttentionState.working,
      );
      expect(
        ConductoreHostAttentionProvider.parseState('needs_permission'),
        AgentAttentionState.needsInput,
      );
      expect(
        ConductoreHostAttentionProvider.parseState('waiting_input'),
        AgentAttentionState.needsInput,
      );
      expect(
        ConductoreHostAttentionProvider.parseState('ended'),
        AgentAttentionState.finished,
      );
      expect(
        ConductoreHostAttentionProvider.parseState('something_new'),
        AgentAttentionState.unknown,
      );
      // An unknown state with a pending request still needs a human.
      expect(
        ConductoreHostAttentionProvider.parseState(
          'something_new',
          pending: const [
            PendingPermissionRequest(id: 'r', toolName: 't', summary: 's'),
          ],
        ),
        AgentAttentionState.needsInput,
      );
    });

    test('skips malformed entries and requests without ids', () {
      final snapshot = ConductoreHostAttentionProvider.parseSnapshot(
        '{"version":1,"seq":1,"agents":[42,{"name":"no-id"},'
        '{"sessionId":"s","state":"working","pending":[{"toolName":"x"},'
        '{"id":"req-2","toolName":"Edit","summary":"edit a.txt"}]}]}',
      );
      expect(snapshot.agents, hasLength(1));
      expect(snapshot.agents.single.pendingRequests.single.id, 'req-2');
    });

    test('caps the tool input', () {
      final huge = {'content': 'x' * 10000};
      final text = ConductoreHostAttentionProvider.formatToolInput(huge);
      expect(
        text.length,
        lessThan(PendingPermissionRequest.maxToolInputLength + 100),
      );
      expect(text, contains('more characters'));
    });

    test('rejects non-JSON and unexpected shapes', () {
      expect(
        () => ConductoreHostAttentionProvider.parseSnapshot('not json'),
        throwsA(isA<AppFailure>()),
      );
      expect(
        () => ConductoreHostAttentionProvider.parseSnapshot('{"foo":1}'),
        throwsA(isA<AppFailure>()),
      );
      expect(
        () => ConductoreHostAttentionProvider.parseSnapshot(''),
        throwsA(isA<AppFailure>()),
      );
    });
  });

  group('parseEvents', () {
    test('reads change and remove lines in order', () {
      final batch = ConductoreHostAttentionProvider.parseEvents(
        '{"seq":8,"type":"change","sessionId":"s","reason":"PreToolUse",'
        '"agent":{"sessionId":"s","name":"api","state":"working",'
        '"pending":[]}}\n'
        '{"seq":9,"type":"change","sessionId":"s","reason":"Stop",'
        '"agent":{"sessionId":"s","name":"api","state":"waiting_input",'
        '"lastMessage":"All green.","pending":[]}}\n'
        '{"seq":10,"type":"remove","sessionId":"old","reason":"prune",'
        '"agent":null}\n',
      );
      expect(batch.snapshot, isNull);
      expect(batch.changes.map((change) => change.sequence), [8, 9, 10]);
      expect(batch.changes[1].agent?.state, AgentAttentionState.needsInput);
      expect(batch.changes[1].agent?.lastMessage, 'All green.');
      expect(batch.changes[2].agentId, 'old');
      expect(batch.changes[2].agent, isNull);
    });

    test('a snapshot line replaces everything before it', () {
      final batch = ConductoreHostAttentionProvider.parseEvents(
        '{"seq":3,"type":"change","sessionId":"x","agent":'
        '{"sessionId":"x","state":"working"}}\n'
        '{"type":"snapshot","version":1,"seq":43,"agents":'
        '[{"sessionId":"s","state":"ended"}]}\n',
      );
      expect(batch.snapshot?.sequence, 43);
      expect(batch.snapshot?.agents.single.state, AgentAttentionState.finished);
      expect(batch.changes, isEmpty);
    });

    test('a timeout (or an unknown line type) is an empty batch', () {
      expect(
        ConductoreHostAttentionProvider.parseEvents(
          '{"type":"timeout","seq":43}\n{"type":"future","seq":44}\n',
        ).isEmpty,
        isTrue,
      );
      expect(ConductoreHostAttentionProvider.parseEvents('\n').isEmpty, isTrue);
    });

    test('an error line fails the poll', () {
      expect(
        () => ConductoreHostAttentionProvider.parseEvents(
          '{"error":"--since must be a number"}',
        ),
        throwsA(isA<AppFailure>()),
      );
    });
  });

  test('formatDoctor lists the checks', () {
    final text = ConductoreHostAttentionProvider.formatDoctor(
      '{"ok":false,"user":"andre","checks":[{"name":"hooks registered",'
      '"ok":true,"detail":"9 events"},{"name":"daemon","ok":false}]}',
    );
    expect(text, 'user: andre\n[ok] hooks registered: 9 events\n[!!] daemon');
    expect(ConductoreHostAttentionProvider.formatDoctor('plain'), 'plain');
  });

  group('fetchAgents', () {
    test('runs status through the PATH wrapper', () async {
      final runner = ScriptedAgentCommandRunner([ok(statusFixture)]);
      final snapshot = await provider.fetchAgents(runner);
      expect(snapshot.agents, hasLength(4));
      expect(runner.commands.single, startsWith("sh -c 'PATH="));
      expect(runner.commands.single, contains('exec conductore-hostd status'));
    });

    test('exit 127 means not installed', () async {
      final runner = ScriptedAgentCommandRunner([
        const AgentCommandResult(
          stdout: '',
          stderr: 'sh: conductore-hostd: not found',
          exitCode: 127,
        ),
      ]);
      expect(
        () => provider.fetchAgents(runner),
        throwsA(isA<AgentProviderUnavailable>()),
      );
    });

    test('exit 1 surfaces the reported error', () async {
      final runner = ScriptedAgentCommandRunner([
        const AgentCommandResult(
          stdout: '{"error":"daemon not running"}',
          stderr: '',
          exitCode: 1,
        ),
      ]);
      await expectLater(
        provider.fetchAgents(runner),
        throwsA(
          isA<AppFailure>().having(
            (failure) => failure.toString(),
            'message',
            contains('daemon not running'),
          ),
        ),
      );
    });
  });

  test('watchAgents long-polls since the last sequence', () async {
    final runner = ScriptedAgentCommandRunner([
      ok(
        '{"seq":8,"type":"change","sessionId":"s","reason":"Stop",'
        '"agent":{"sessionId":"s","state":"working"}}',
      ),
      ok('{"type":"timeout","seq":8}'),
    ]);
    final batch = await provider.watchAgents(runner, since: 7);
    expect(batch?.changes.single.sequence, 8);
    expect(
      runner.commands.single,
      contains('exec conductore-hostd events --since 7 --timeout 55'),
    );
    // PATH gets ~/.local/bin first, as the companion README asks.
    expect(
      runner.commands.single,
      startsWith("sh -c 'PATH=\"\$HOME/.local/bin:"),
    );

    expect(await provider.watchAgents(runner, since: 8), isNull);
  });

  test('isAvailable probes version', () async {
    final present = ScriptedAgentCommandRunner([ok('{"version":"0.1.0"}')]);
    expect(await provider.isAvailable(present), isTrue);
    expect(present.commands.single, contains('exec conductore-hostd version'));

    final missing = ScriptedAgentCommandRunner([
      const AgentCommandResult(stdout: '', stderr: '', exitCode: 127),
    ]);
    expect(await provider.isAvailable(missing), isFalse);

    final offline = ScriptedAgentCommandRunner([StateError('no route')]);
    expect(await provider.isAvailable(offline), isFalse);
  });

  test('builds focus and decide commands with quoting', () {
    const agent = AgentInfo(
      id: 'sess 1',
      name: 'x',
      state: AgentAttentionState.working,
    );
    expect(provider.focusCommand(agent), contains("focus '\\''sess 1'\\''"));
    const request = PendingPermissionRequest(
      id: 'req-1',
      toolName: 'Bash',
      summary: 'ls',
    );
    expect(
      provider.decideCommand(request, PermissionVerdict.always),
      contains('exec conductore-hostd decide req-1 always'),
    );
    expect(
      provider.decideCommand(
        const PendingPermissionRequest(id: '', toolName: 'x', summary: ''),
        PermissionVerdict.allow,
      ),
      isNull,
    );
  });

  group('status etag and gzip', () {
    String withEtag(String etag) => statusFixture.trim().replaceFirst(
      '"seq":7,',
      '"seq":7,"etag":"$etag",',
    );

    test(
      'the next status sends the etag; "unchanged" keeps the agents',
      () async {
        final runner = ScriptedAgentCommandRunner([
          ok(withEtag('e1.7')),
          ok(
            '{"version":1,"seq":7,"etag":"e1.7","unchanged":true,'
            '"source":"daemon","capabilities":["digest"]}',
          ),
        ]);
        final first = await provider.fetchAgents(runner);
        expect(runner.commands.first, contains('status --gzip'));
        final second = await provider.fetchAgents(runner);
        expect(runner.commands.last, contains('status --etag e1.7 --gzip'));
        expect(second.agents, first.agents);
        expect(second.sequence, 7);
        expect(second.capabilities, {'digest'});
      },
    );

    test('a changed state answers in full and replaces the copy', () async {
      final runner = ScriptedAgentCommandRunner([
        ok(withEtag('e1.7')),
        ok('{"version":1,"seq":8,"etag":"e1.8","agents":[]}'),
      ]);
      await provider.fetchAgents(runner);
      final next = await provider.fetchAgents(runner);
      expect(next.agents, isEmpty);
      expect(next.sequence, 8);
    });

    test('"unchanged" without a copy asks again in full', () async {
      final runner = ScriptedAgentCommandRunner([
        ok('{"version":1,"seq":7,"unchanged":true}'),
        ok(statusFixture),
      ]);
      final snapshot = await provider.fetchAgents(runner);
      expect(snapshot.agents, hasLength(4));
      expect(runner.commands, hasLength(2));
      expect(runner.commands.last, isNot(contains('--etag')));
    });

    test('a gzipped status parses like a plain one', () async {
      final packed = jsonEncode({
        'encoding': 'gzip',
        'data': base64.encode(gzip.encode(utf8.encode(statusFixture))),
      });
      final snapshot = await provider.fetchAgents(
        ScriptedAgentCommandRunner([ok(packed)]),
      );
      expect(snapshot.agents, hasLength(4));
      expect(snapshot.sequence, 7);
    });
  });
}
