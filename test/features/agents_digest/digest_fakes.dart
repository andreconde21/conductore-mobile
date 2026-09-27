import 'dart:convert';

import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/agents_digest/presentation/digest_controller.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:flutter/foundation.dart';

SavedHost digestHost(String id, {String? name}) => SavedHost(
  id: id,
  name: name ?? id,
  host: '$id.example',
  port: 22,
  username: 'me',
  authMethod: SshAuthMethod.password,
);

final digestNow = DateTime.utc(2026, 9, 27, 14);

int _ms(DateTime t) => t.millisecondsSinceEpoch;

/// One agent of a `conductore-hostd digest` reply (the README's shape).
Map<String, Object?> digestAgentJson(
  String sessionId, {
  String? name,
  String state = 'waiting_input',
  String? attention,
  DateTime? lastActivityAt,
  String? headline,
  List<Map<String, Object?>> stuck = const [],
  List<Map<String, Object?>> pending = const [],
  Map<String, Object?>? facts,
  String? summary,
  bool fresh = true,
  bool summaryPending = false,
  bool live = true,
}) => {
  'sessionId': sessionId,
  'name': name ?? sessionId,
  'machine': 'devbox',
  'project': name ?? sessionId,
  'cwd': '/home/a/${name ?? sessionId}',
  'state': state,
  'attention': attention,
  'live': live,
  'lastActivityAt': _ms(
    lastActivityAt ?? digestNow.subtract(const Duration(minutes: 10)),
  ),
  'headline': headline,
  'pending': pending,
  'facts':
      facts ??
      {
        'turns': 2,
        'files': ['lib/a.dart', 'test/a_test.dart'],
        'filesEdited': 2,
        'linesAdded': 48,
        'linesRemoved': 9,
        'lines': 'git',
        'commands': 5,
        'failedCommands': 1,
        'testRuns': 3,
        'testsPassed': 2,
        'testsFailed': 1,
        'lastTest': {'ok': true, 'at': _ms(digestNow), 'command': 'npm test'},
        'waitingPermissionMs': 0,
        'waitingInputMs': 0,
        'tokens': {'total': 962010, 'output': 9800},
        'costUsd': 0.41,
        'partial': false,
      },
  'stuck': stuck,
  'summary': summary == null
      ? null
      : {'text': summary, 'at': _ms(digestNow), 'fresh': fresh},
  'summaryPending': summaryPending,
};

Map<String, Object?> digestReplyJson(
  List<Map<String, Object?>> agents, {
  Map<String, Object?>? summaries,
  int tokensToday = 0,
  double costToday = 0,
}) => {
  'version': '0.8.0',
  'schema': 1,
  'machine': 'devbox',
  'generatedAt': _ms(digestNow),
  'since': _ms(digestNow.subtract(const Duration(hours: 2))),
  'source': 'daemon',
  'activity': true,
  'counts': {},
  'agents': agents,
  'summaries':
      summaries ??
      {
        'enabled': false,
        'pending': 0,
        'done': 0,
        'calls': 0,
        'tokens': {'total': 0},
        'costUsd': 0,
      },
  'summaryUsageToday': {
    'runs': 1,
    'calls': 1,
    'tokens': {'total': tokensToday},
    'costUsd': costToday,
  },
};

/// Answers `digest` (facts) and `digest … --summaries` separately.
class FakeDigestRunner implements AgentCommandRunner {
  FakeDigestRunner({required this.facts, Map<String, Object?>? summaries})
    : summaries = summaries ?? facts;

  Map<String, Object?> facts;
  Map<String, Object?> summaries;

  /// Replaces the answer entirely (an older companion, a failure).
  AgentCommandResult? raw;
  final List<String> commands = [];
  int closed = 0;

  List<String> get summaryCommands =>
      commands.where((c) => c.contains('--summaries')).toList();

  @override
  Future<AgentCommandResult> run(
    String command, {
    required Duration timeout,
  }) async {
    commands.add(command);
    if (raw case final raw?) return raw;
    final json = command.contains('--summaries') ? summaries : facts;
    return AgentCommandResult(
      stdout: jsonEncode(json),
      stderr: '',
      exitCode: 0,
    );
  }

  @override
  Future<void> close() async => closed++;
}

class FakeDigestSource extends ChangeNotifier implements DigestHostSource {
  FakeDigestSource(this.hosts, this.runners);

  List<SavedHost> hosts;
  final Map<String, FakeDigestRunner> runners;
  final Map<String, List<AgentInfo>> live = {};

  void changed() => notifyListeners();

  @override
  List<SavedHost> get digestHosts => hosts;

  @override
  List<AgentInfo> liveAgentsFor(String hostId) => live[hostId] ?? const [];

  @override
  (AgentCommandRunner, {bool owned}) runnerFor(SavedHost host) =>
      (runners[host.id]!, owned: false);
}
