import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/voice_guide/domain/approval_actions.dart';
import 'package:conduit/features/voice_guide/domain/guide_brain.dart';
import 'package:conduit/features/voice_guide/domain/guide_ports.dart';
import 'package:conduit/features/voice_guide/domain/guide_world.dart';

const npmTest = PendingPermissionRequest(
  id: 'req-npm',
  toolName: 'Bash',
  summary: 'npm test',
);

const rmRf = PendingPermissionRequest(
  id: 'req-rm',
  toolName: 'Bash',
  summary: 'rm -rf build',
);

GuideAgent agent(
  String id, {
  String hostId = 'vtm',
  String machine = 'VTM',
  String name = 'claude',
  String? project,
  AgentAttentionState state = AgentAttentionState.working,
  List<PendingPermissionRequest> pending = const [],
  String? lastMessage,
  DateTime? changedAt,
}) => GuideAgent(
  hostId: hostId,
  machineName: machine,
  info: AgentInfo(
    id: id,
    name: name,
    state: pending.isEmpty ? state : AgentAttentionState.needsInput,
    project: project,
    pendingRequests: pending,
    lastMessage: lastMessage,
    stateChangedAt: changedAt,
  ),
);

const vtm = GuideMachine(hostId: 'vtm', name: 'VTM', monitored: true);
const laptop = GuideMachine(hostId: 'laptop', name: 'Laptop', monitored: true);

/// The fleet most tests start from: api on VTM waiting on npm test, web
/// on the laptop working.
GuideWorld fleet({GuideScreen screen = GuideScreen.home}) => GuideWorld(
  machines: const [vtm, laptop],
  agents: [
    agent('s-api', project: 'api', pending: const [npmTest]),
    agent(
      's-web',
      hostId: 'laptop',
      machine: 'Laptop',
      project: 'website',
      lastMessage:
          '## Done\n\nThe **build** is green. I also fixed the '
          'flaky login test. Then I updated the changelog. And the docs. '
          'Should I open a pull request?',
    ),
  ],
  screen: screen,
);

class FakeApprovals extends ApprovalActions {
  FakeApprovals({this.risks = const {}, this.smart = false});

  final Map<String, ApprovalRisk> risks;
  final bool smart;
  final decided = <(String, String, PermissionVerdict)>[];
  final batches = <List<String>>[];
  final trusted = <(String, String, Duration)>[];
  Object? failWith;

  @override
  ApprovalRisk riskOf(String hostId, PendingPermissionRequest request) =>
      risks[request.id] ?? ApprovalRisk.unknown;

  @override
  Future<void> decide(
    String hostId,
    PendingPermissionRequest request,
    PermissionVerdict verdict,
  ) async {
    if (failWith case final error?) throw error;
    decided.add((hostId, request.id, verdict));
  }

  @override
  bool get supportsApproveAllSafe => smart;

  @override
  Future<int> approveAllSafe(List<ApprovalTarget> targets) async {
    batches.add([for (final t in targets) t.request.id]);
    return targets.length;
  }

  @override
  bool get supportsTrust => smart;

  @override
  Future<void> trust(
    String hostId,
    PendingPermissionRequest request,
    Duration duration,
  ) async => trusted.add((hostId, request.id, duration));
}

class FakeNavigator implements GuideNavigator {
  FakeNavigator(this.current);

  GuideScreen current;
  final opened = <(String, GuideView?)>[];
  final machines = <String>[];
  var homes = 0;

  /// What [openAgent] reports it showed (null: follow the request).
  GuideView? shows;

  @override
  GuideScreen get screen => current;

  @override
  Future<void> home() async {
    homes += 1;
    current = GuideScreen.home;
  }

  @override
  Future<GuideView?> openAgent(GuideAgent agent, {GuideView? view}) async {
    opened.add((agent.id, view));
    final shown = shows ?? view ?? GuideView.chat;
    current = GuideScreen(shown, hostId: agent.hostId, agentId: agent.id);
    return shown;
  }

  @override
  Future<bool> openMachine(GuideMachine machine) async {
    machines.add(machine.hostId);
    return true;
  }
}

class FakeMessenger implements GuideMessenger {
  final sent = <(String, String)>[];

  @override
  Future<void> send(GuideAgent agent, String text) async =>
      sent.add((agent.id, text));
}

/// Answers with [reply], recording what it was asked.
class FakeBrain implements GuideBrain {
  FakeBrain(this.reply);

  GuideBrainReply Function(Map<String, Object?> context) reply;
  final asked = <(String, Map<String, Object?>)>[];

  @override
  Future<GuideBrainReply> ask(
    String utterance,
    Map<String, Object?> context, {
    Future<void>? cancel,
  }) async {
    asked.add((utterance, context));
    return reply(context);
  }
}

/// The short id the context gave the agent working in [project].
String agentIdFor(Map<String, Object?> context, String project) {
  List<Map<String, Object?>> list(String key) =>
      (context[key]! as List).cast<Map<String, Object?>>();
  final projectId = list(
    'projects',
  ).firstWhere((p) => p['name'] == project)['id'];
  return list('agents').firstWhere((a) => a['project'] == projectId)['id']!
      as String;
}

class FakeAccounts implements GuideAccounts {
  @override
  bool available = true;
  final switched = <String>[];

  @override
  List<GuideAccount> get accounts => const [
    GuideAccount(
      label: 'Work',
      targets: [
        (hostId: 'vtm', hostName: 'VTM', slot: 2),
        (hostId: 'laptop', hostName: 'Laptop', slot: 1),
      ],
    ),
    GuideAccount(label: 'Personal', active: true),
  ];

  @override
  Future<List<GuideAccountSwitch>> switchTo(GuideAccount account) async {
    switched.add(account.label);
    return [
      for (final t in account.targets)
        (hostName: t.hostName, ok: true, error: null),
    ];
  }
}

/// Review and undo for the guide: every agent can, [last] is its newest
/// turn, and every call is recorded.
class FakeReviewer implements GuideReviewer {
  FakeReviewer({this.undoable = true});

  bool undoable;
  GuideTurnPreview? last = const GuideTurnPreview(
    turn: 4,
    files: 3,
    prompt: 'Fix the date parser',
  );
  final reviewed = <String>[];
  final undone = <(String, int)>[];

  @override
  bool canReview(GuideAgent agent) => true;

  @override
  bool canUndo(GuideAgent agent) => undoable;

  @override
  Future<bool> review(GuideAgent agent) async {
    reviewed.add(agent.id);
    return true;
  }

  @override
  Future<GuideTurnPreview?> lastTurn(GuideAgent agent) async => last;

  @override
  Future<int> undo(GuideAgent agent, int turn) async {
    undone.add((agent.id, turn));
    return 3;
  }
}
