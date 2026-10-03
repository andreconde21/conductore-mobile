import 'dart:convert';

import 'package:conduit/features/agent_attention/domain/agent_attention_notifier.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/agent_attention/domain/agent_notifications.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/usage/domain/usage_report.dart';
import 'package:conduit/features/usage/presentation/usage_controller.dart';
import 'package:flutter/foundation.dart';

SavedHost usageHost(String id, {String? name}) => SavedHost(
  id: id,
  name: name ?? id,
  host: '$id.example',
  port: 22,
  username: 'me',
  authMethod: SshAuthMethod.password,
);

/// A `conductore-hostd usage` reply (the README's shape).
Map<String, Object?> usageReplyJson({
  String machine = 'devbox',
  String today = '2026-09-25',
  String from = '2026-09-19',
  List<Map<String, Object?>> limits = const [],
  List<Map<String, Object?>> rows = const [],
  Map<String, Object?>? codex,
  bool partial = false,
  List<Map<String, Object?>>? accounts,
  bool cswap = true,
}) {
  Map<String, Object?> totals(Iterable<Map<String, Object?>> rows) {
    num sum(String key) =>
        rows.fold<num>(0, (s, r) => s + ((r[key] as num?) ?? 0));
    return {
      'input': sum('input'),
      'output': sum('output'),
      'cacheWrite': sum('cacheWrite'),
      'cacheRead': sum('cacheRead'),
      'messages': sum('messages'),
      'costUsd': rows.isEmpty ? null : sum('costUsd'),
    };
  }

  return {
    'version': '0.6.0',
    'schema': 1,
    'machine': machine,
    'generatedAt': DateTime.utc(2026, 9, 25, 12).millisecondsSinceEpoch,
    'today': today,
    'from': from,
    'claude': {
      'present': true,
      'limits': limits,
      'sessions': [
        {
          'sessionId': 's1',
          'name': 'api',
          'project': 'api',
          'contextUsedPct': 41,
          'contextTokens': 82000,
          'windowLabel': '200k',
        },
      ],
      'today': totals(rows.where((r) => r['date'] == today)),
      'range': totals(rows),
      'rows': rows,
      // Companions before cswap support send neither field.
      if (accounts != null) ...{
        'accounts': accounts,
        'cswap': {'present': cswap, 'activeSlot': 1},
      },
    },
    'codex': codex ?? {'present': false},
    'pricing': {
      'estimate': true,
      'asOf': '2026-09-25',
      'note': 'Estimate at public API list prices.',
      'unpriced': <String>[],
    },
    'scan': {'partial': partial},
  };
}

/// One `claude.accounts` entry (the companion's cswap shape).
Map<String, Object?> usageAccount(
  int slot,
  String label, {
  bool active = false,
  bool disabled = false,
  bool stale = false,
  num? fiveHour,
  num? weekly,
  DateTime? fiveHourResets,
  DateTime? weeklyResets,
  DateTime? usageAt,
  String? status,
  bool live = false,
}) => {
  'slot': slot,
  'alias': label.contains('*') ? null : label,
  'label': label,
  'active': active,
  'disabled': disabled,
  'status': status ?? (stale ? 'unavailable' : 'ok'),
  if (live) 'live': true,
  'limits': {
    if (fiveHour != null)
      '5h': {
        'usedPct': fiveHour,
        'resetsAt': fiveHourResets?.millisecondsSinceEpoch,
        'expired': false,
      },
    if (weekly != null)
      '7d': {
        'usedPct': weekly,
        'resetsAt': weeklyResets?.millisecondsSinceEpoch,
        'expired': false,
      },
  },
  if (stale) 'stale': true,
  if (usageAt != null) 'usageAt': usageAt.millisecondsSinceEpoch,
  'perModel': [
    {'model': 'Fable', 'usedPct': 7, 'resetsAt': null, 'expired': false},
  ],
};

/// The live login cswap does not manage (companion 1.3, CON-057), with
/// whether the sessions' limits confirm it is none of cswap's accounts
/// ([inCswap], companion 1.3.1, CON-067; absent before).
Map<String, Object?> usageUnmanagedAccount(
  String label, {
  bool? inCswap,
  Map<String, Object?> limits = const {},
  DateTime? usageAt,
}) => {
  'slot': null,
  'alias': null,
  'label': label,
  'active': true,
  'disabled': false,
  'managed': false,
  'status': null,
  'limits': limits,
  'inCswap': ?inCswap,
  if (usageAt != null) 'usageAt': usageAt.millisecondsSinceEpoch,
};

Map<String, Object?> usageRow(
  String date, {
  String project = 'api',
  String model = 'claude-opus-5',
  int input = 100,
  int output = 1000,
  int cacheWrite = 0,
  int cacheRead = 0,
  int messages = 1,
  double? costUsd = 1,
}) => {
  'date': date,
  'project': project,
  'model': model,
  'input': input,
  'output': output,
  'cacheWrite': cacheWrite,
  'cacheRead': cacheRead,
  'messages': messages,
  'costUsd': costUsd,
};

class FakeUsageRunner implements AgentCommandRunner {
  FakeUsageRunner(this.reply);

  /// What the next `usage` command answers.
  AgentCommandResult Function() reply;
  final List<String> commands = [];
  int closed = 0;

  @override
  Future<AgentCommandResult> run(
    String command, {
    required Duration timeout,
  }) async {
    commands.add(command);
    return reply();
  }

  @override
  Future<void> close() async => closed++;

  static AgentCommandResult ok(Map<String, Object?> json) =>
      AgentCommandResult(stdout: jsonEncode(json), stderr: '', exitCode: 0);
}

class FakeUsageSource extends ChangeNotifier implements UsageHostSource {
  FakeUsageSource(this.hosts, this.runners, {this.owned = false});

  List<SavedHost> hosts;
  final Map<String, FakeUsageRunner> runners;
  final Map<String, List<UsageLimit>> live = {};
  bool owned;

  void changed() => notifyListeners();

  @override
  List<SavedHost> get usageHosts => hosts;

  @override
  List<UsageLimit> liveLimitsFor(String hostId) => live[hostId] ?? const [];

  @override
  (AgentCommandRunner, {bool owned}) runnerFor(SavedHost host) =>
      (runners[host.id]!, owned: owned);
}

class FakeUsageNotifier implements AgentAttentionNotifier {
  final List<({String id, String title, String body})> shown = [];

  @override
  Future<void> show({
    required String id,
    required String title,
    required String body,
    AgentOpenTarget? open,
  }) async => shown.add((id: id, title: title, body: body));

  @override
  Future<void> showAgents({
    required String hostId,
    required List<AgentNotification> notifications,
  }) async {}

  @override
  Future<void> showAgent(AgentNotification notification) async {}

  @override
  Future<void> cancelAgent({required String key}) async {}

  @override
  Future<void> cancel({required String id}) async {}
}
