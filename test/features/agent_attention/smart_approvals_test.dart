import 'package:conduit/features/agent_attention/data/conductore_host_attention_provider.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/agent_attention/domain/approval_rules.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_sheet.dart';
import 'package:conduit/features/agent_attention/presentation/approval_rules_page.dart';
import 'package:conduit/features/chat_view/presentation/widgets/chat_thread_items.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

/// Answers by companion subcommand (`status`, `approvals`, `trust`, …):
/// each call takes the next reply queued for it, the last one repeats.
class RoutingRunner implements AgentCommandRunner {
  RoutingRunner(this.replies);

  final Map<String, List<String>> replies;
  final List<String> commands = [];

  static AgentCommandResult _result(String stdout) => AgentCommandResult(
    stdout: stdout,
    stderr: '',
    exitCode: stdout.contains('"error"') ? 1 : 0,
  );

  @override
  Future<AgentCommandResult> run(
    String command, {
    required Duration timeout,
  }) async {
    commands.add(command);
    final match = RegExp(
      r"conductore-hostd ([^\s']+)(?: ([^\s']+))?",
    ).firstMatch(command);
    final sub = match?.group(1) ?? '';
    final key = sub == 'rules' ? 'rules ${match?.group(2)}' : sub;
    final queue = replies[key];
    if (queue == null || queue.isEmpty) {
      return _result('{"error":"unknown command $key"}');
    }
    return _result(queue.length > 1 ? queue.removeAt(0) : queue.first);
  }

  List<String> sent(String sub) =>
      commands.where((c) => c.contains('conductore-hostd $sub')).toList();

  @override
  Future<void> close() async {}
}

const _lowGit =
    '{"id":"req-low","toolName":"Bash","summary":"git status",'
    '"toolInput":{"command":"git status"},"createdAt":1790000000000,'
    '"risk":{"level":"low","reason":"Read-only: git status"},'
    '"batchable":true,"suggestedRules":["Bash(git status *)","Bash(git *)"],'
    '"repo":"/home/a/api"}';
const _highRm =
    '{"id":"req-high","toolName":"Bash","summary":"rm -rf build",'
    '"toolInput":{"command":"rm -rf build"},"createdAt":1790000001000,'
    '"risk":{"level":"high","reason":"Deletes recursively (rm -rf): build"},'
    '"batchable":false,"suggestedRules":["Bash(rm *)"],"repo":"/home/a/api"}';
const _lowLs =
    '{"id":"req-ls","toolName":"Bash","summary":"ls -la",'
    '"toolInput":{"command":"ls -la"},"createdAt":1790000002000,'
    '"risk":{"level":"low","reason":"Read-only: ls"},'
    '"batchable":true,"suggestedRules":["Bash(ls *)"],"repo":"/home/a/web"}';

String _status(List<String> api, List<String> web, {bool capable = true}) =>
    '{"version":1,"seq":5,'
    '${capable ? '"capabilities":["smart-approvals"],' : ''}'
    '"agents":['
    '{"sessionId":"s-1","name":"api","cwd":"/home/a/api",'
    '"state":"${api.isEmpty ? 'working' : 'needs_permission'}",'
    '"updatedAt":1790000003000,"pending":[${api.join(',')}]},'
    '{"sessionId":"s-2","name":"web","cwd":"/home/a/web",'
    '"state":"${web.isEmpty ? 'working' : 'needs_permission'}",'
    '"updatedAt":1790000002000,"pending":[${web.join(',')}]}]}';

const _rule =
    '{"id":"r0000000001","rule":"Bash(git status *)","scope":{"kind":"repo",'
    '"path":"/home/a/api"},"expiresAt":4102444800000,"endsWithSession":null,'
    '"source":"trust","createdAt":1790000000000,"hits":2,"lastUsedAt":null}';
const _approvals =
    '{"rules":[$_rule],"now":1790000000000,"autoApproved":[{"requestId":'
    '"old-1","at":1790000000000,"sessionId":"s-1","agent":"api","cwd":'
    '"/home/a/api","toolName":"Bash","summary":"git status --short",'
    '"risk":{"level":"low","reason":"Read-only: git status"},"ruleId":'
    '"r0000000001","rule":"Bash(git status *)","scope":{"kind":"repo",'
    '"path":"/home/a/api"}}]}';

void main() {
  SavedHost host() => buildHost('h').copyWith(
    agentAttentionEnabled: true,
    agentMonitor: AgentMonitorKind.companion,
  );

  Future<(AgentAttentionController, RoutingRunner)> start(
    WidgetTester tester,
    Map<String, List<String>> replies, {
    RecordingAgentNotifier? notifier,
  }) async {
    final workspace = TerminalWorkspaceController(
      ImmediateTerminalRepository(TrackableTerminalSession()),
    );
    final runner = RoutingRunner(replies);
    final controller = AgentAttentionController(
      workspace: workspace,
      runnerFactory: (_) => runner,
      provider: const ConductoreHostAttentionProvider(),
      companionProvider: const ConductoreHostAttentionProvider(),
      notifier: notifier,
      pollInterval: const Duration(days: 1),
    );
    controller.setAppForeground(false);
    addTearDown(controller.dispose);
    addTearDown(workspace.dispose);
    final session = workspace.open(host());
    await tester.runAsync(session.connect);
    await tester.runAsync(pumpEventQueue);
    return (controller, runner);
  }

  Future<void> pumpSheet(
    WidgetTester tester,
    AgentAttentionController controller,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentAttentionSheet(
            controller: controller,
            onOpenAgent: (host, agent) {},
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.runAsync(pumpEventQueue);
    await tester.pump();
  }

  group('provider', () {
    const provider = ConductoreHostAttentionProvider();

    test('parses capabilities, risk, batchable, suggestions and repo', () {
      final snapshot = ConductoreHostAttentionProvider.parseSnapshot(
        _status([_lowGit, _highRm], []),
      );
      expect(snapshot.capabilities, {'smart-approvals'});
      final [low, high] = snapshot.agents.first.pendingRequests;
      expect(
        low.risk,
        const PermissionRisk(PermissionRiskLevel.low, 'Read-only: git status'),
      );
      expect(low.batchable, isTrue);
      expect(low.trustable, isTrue);
      expect(low.suggestedRules, ['Bash(git status *)', 'Bash(git *)']);
      expect(low.repo, '/home/a/api');
      expect(high.risk!.level, PermissionRiskLevel.high);
      expect(high.batchable, isFalse);
      expect(high.trustable, isFalse);
    });

    test('an older companion parses without the new fields', () {
      final snapshot = ConductoreHostAttentionProvider.parseSnapshot(
        '{"version":1,"seq":1,"agents":[{"sessionId":"s","state":'
        '"needs_permission","pending":[{"id":"r","toolName":"Bash",'
        '"summary":"ls"}]}]}',
      );
      expect(snapshot.capabilities, isNull);
      final request = snapshot.agents.single.pendingRequests.single;
      expect(request.risk, isNull);
      expect(request.batchable, isFalse);
      expect(request.trustable, isFalse);
    });

    test('batchable needs a low rating, whatever the flag says', () {
      final info = parsePendingApprovalInfo({
        'risk': {'level': 'high', 'reason': 'x'},
        'batchable': true,
      });
      expect(info.batchable, isFalse);
    });

    test('builds quoted commands', () {
      const request = PendingPermissionRequest(
        id: 'req-1',
        toolName: 'Bash',
        summary: 'npm test',
      );
      expect(
        provider.trustCommand(
          request,
          const ApprovalRuleDraft(
            rule: 'Bash(npm test *)',
            scope: ApprovalScope.repo('/home/a/my app'),
            duration: TrustDuration.minutes(15),
          ),
          source: 'voice',
        ),
        contains(
          r"trust req-1 --rule '\''Bash(npm test *)'\'' --scope repo "
          r"--path '\''/home/a/my app'\'' --minutes 15 --source voice",
        ),
      );
      expect(
        provider.approveLowCommand(['a', 'b']),
        allOf(contains('approve-low --ids'), contains('a,b')),
      );
      expect(
        provider.addRuleCommand(
          const ApprovalRuleDraft(
            rule: 'Read',
            scope: ApprovalScope.any(),
            duration: TrustDuration.forever(),
          ),
        ),
        contains('rules add Read --scope any --forever --source cli'),
      );
      expect(provider.removeRuleCommand('r1'), contains('rules remove r1'));
    });

    test('parses approvals, batch and trust replies; errors throw', () {
      final approvals = provider.parseApprovals(_approvals);
      expect(approvals.rules.single.rule, 'Bash(git status *)');
      expect(approvals.rules.single.scope.path, '/home/a/api');
      expect(approvals.rules.single.isTimeBoxed, isTrue);
      expect(approvals.autoApproved.single.summary, 'git status --short');
      expect(
        approvals.autoApproved.single.risk!.level,
        PermissionRiskLevel.low,
      );
      final batch = provider.parseBatch(
        '{"ok":true,"approved":[{"id":"a"}],"skipped":[{"id":"b",'
        '"reason":"high risk: review it"}]}',
      );
      expect(batch.approved, ['a']);
      expect(batch.skipped.single.reason, 'high risk: review it');
      final trust = provider.parseTrust(
        '{"ok":true,"rule":$_rule,"approved":["x","y"]}',
      );
      expect(trust.rule.id, 'r0000000001');
      expect(trust.approved, ['x', 'y']);
      expect(
        () => provider.parseTrust('{"error":"high-risk requests always ask"}'),
        throwsA(anything),
      );
    });
  });

  group('rules model', () {
    test('durations and scopes describe themselves', () {
      final rule = ApprovalRule.parse({
        'id': 'r',
        'rule': 'Bash',
        'scope': {
          'kind': 'session',
          'sessionId': 'abcdef123456',
          'label': 'api',
        },
        'expiresAt': DateTime.utc(2026, 1, 1, 12, 30).millisecondsSinceEpoch,
      })!;
      expect(rule.scope.describe(), 'in session api');
      expect(
        rule.describeDuration(now: DateTime.utc(2026, 1, 1, 12)),
        '30 min left',
      );
      expect(
        rule.describeDuration(now: DateTime.utc(2026, 1, 1, 13)),
        'expired',
      );
      expect(const TrustDuration.minutes(60).label, '1 h');
      expect(const TrustDuration.minutes(15).label, '15 min');
      expect(isValidApprovalRule('Bash(npm test *)'), isTrue);
      expect(isValidApprovalRule('mcp__github'), isTrue);
      expect(isValidApprovalRule('npm test'), isFalse);
      expect(isValidApprovalRule(''), isFalse);
    });
  });

  group('controller', () {
    testWidgets('approveAllLowRisk sends only the low-risk ids and drops them', (
      tester,
    ) async {
      final (controller, runner) = await start(tester, {
        'status': [
          _status([_lowGit, _highRm], [_lowLs]),
          _status([_highRm], []),
        ],
        'approve-low': [
          '{"ok":true,"approved":[{"id":"req-low"},{"id":"req-ls"}],"skipped":[]}',
        ],
      });
      expect(controller.supportsSmartApprovals('h'), isTrue);
      expect(controller.pendingApprovals.map((p) => p.request.id), [
        'req-low',
        'req-high',
        'req-ls',
      ]);
      expect(controller.lowRiskPending.map((p) => p.request.id), [
        'req-low',
        'req-ls',
      ]);
      late BatchApprovalResult result;
      await tester.runAsync(() async {
        result = await controller.approveAllLowRisk();
      });
      expect(result.approved, ['req-low', 'req-ls']);
      expect(runner.sent('approve-low').single, contains('req-low,req-ls'));
      expect(runner.sent('approve-low').single, isNot(contains('req-high')));
      expect(controller.pendingApprovals.map((p) => p.request.id), [
        'req-high',
      ]);
    });

    testWidgets('trustRequest sends the rule, scope and duration', (
      tester,
    ) async {
      final (controller, runner) = await start(tester, {
        'status': [
          _status([_lowGit], []),
          _status([], []),
        ],
        'trust': ['{"ok":true,"rule":$_rule,"approved":["req-low"]}'],
        'approvals': [_approvals],
      });
      final request = controller.pendingApprovals.single.request;
      late TrustResult result;
      await tester.runAsync(() async {
        result = await controller.trustRequest(
          'h',
          request,
          duration: const TrustDuration.minutes(15),
          source: 'voice',
        );
        await pumpEventQueue();
      });
      expect(result.rule.rule, 'Bash(git status *)');
      final sent = runner.sent('trust').single;
      expect(sent, contains('trust req-low'));
      // No rule picked: the companion saves one for exactly this call.
      expect(sent, isNot(contains('--rule')));
      expect(sent, contains('--scope repo'));
      expect(sent, contains('/home/a/api'));
      expect(sent, contains('--minutes 15'));
      expect(sent, contains('--source voice'));
      expect(controller.pendingApprovals, isEmpty);
      expect(controller.approvalsFor('h')!.rules.single.id, 'r0000000001');
    });

    testWidgets('a companion without the capability has no smart approvals', (
      tester,
    ) async {
      final (controller, _) = await start(tester, {
        'status': [
          _status([_lowGit], [], capable: false),
        ],
      });
      expect(controller.supportsSmartApprovals('h'), isFalse);
      expect(controller.lowRiskPending, isEmpty);
    });

    testWidgets('notifications carry the risk label and reason', (
      tester,
    ) async {
      final notifier = RecordingAgentNotifier();
      await start(tester, {
        'status': [
          _status([_highRm], []),
        ],
      }, notifier: notifier);
      final notification = notifier.agents.values.single;
      expect(notification.title, endsWith('needs you'));
      expect(notification.text, 'Approve Bash: rm -rf build · High risk');
      expect(notification.lines, [
        'Approve Bash: rm -rf build · High risk',
        '  Deletes recursively (rm -rf): build',
      ]);
      // High risk always asks: no Always button.
      expect(notification.action?.requestId, 'req-high');
      expect(notification.action?.allowAlways, isFalse);
    });
  });

  group('inbox', () {
    testWidgets('shows risk labels; high risk gets neither Trust nor Always', (
      tester,
    ) async {
      final (controller, _) = await start(tester, {
        'status': [
          _status([_lowGit, _highRm], []),
        ],
        'approvals': [_approvals],
      });
      await pumpSheet(tester, controller);
      expect(find.text('Low risk'), findsWidgets);
      expect(find.text('High risk'), findsOneWidget);
      expect(find.text('Deletes recursively (rm -rf): build'), findsOneWidget);
      expect(find.byKey(const ValueKey('trust-req-low')), findsOneWidget);
      expect(find.byKey(const ValueKey('trust-req-high')), findsNothing);
      // One Always (the low one); the high one only has Deny and Allow.
      expect(find.text('Always'), findsOneWidget);
      expect(find.text('Allow'), findsNWidgets(2));
    });

    testWidgets('an older companion keeps the plain buttons', (tester) async {
      final (controller, runner) = await start(tester, {
        'status': [
          _status([_lowGit], [], capable: false),
        ],
        'decide': ['{"ok":true}'],
      });
      await pumpSheet(tester, controller);
      expect(find.text('Trust…'), findsNothing);
      expect(find.byKey(const ValueKey('batch-approval-card')), findsNothing);
      await tester.tap(find.text('Always'));
      await tester.runAsync(pumpEventQueue);
      await tester.pump();
      expect(runner.sent('decide').single, contains('decide req-low always'));
    });

    testWidgets('Approve all safe lists the low ones and approves them', (
      tester,
    ) async {
      final (controller, runner) = await start(tester, {
        'status': [
          _status([_lowGit, _highRm], [_lowLs]),
          _status([_highRm], []),
        ],
        'approvals': [_approvals],
        'approve-low': [
          '{"ok":true,"approved":[{"id":"req-low"},{"id":"req-ls"}],"skipped":[]}',
        ],
      });
      await pumpSheet(tester, controller);
      expect(find.text('3 requests waiting'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('batch-approve-safe')));
      await tester.pumpAndSettle();
      expect(find.text('Approve 2 low-risk requests?'), findsOneWidget);
      expect(find.textContaining('git status'), findsWidgets);
      await tester.ensureVisible(find.byKey(const ValueKey('batch-confirm')));
      await tester.tap(find.byKey(const ValueKey('batch-confirm')));
      await tester.pumpAndSettle();
      await tester.runAsync(pumpEventQueue);
      await tester.pumpAndSettle();
      expect(runner.sent('approve-low').single, contains('req-low,req-ls'));
      expect(find.text('Approved 2.'), findsOneWidget);
      expect(find.byKey(const ValueKey('batch-approval-card')), findsNothing);
    });

    testWidgets('Review each hides the batch card', (tester) async {
      final (controller, _) = await start(tester, {
        'status': [
          _status([_lowGit, _highRm], []),
        ],
        'approvals': [_approvals],
      });
      await pumpSheet(tester, controller);
      expect(find.byKey(const ValueKey('batch-approval-card')), findsOneWidget);
      await tester.tap(find.text('Review each'));
      await tester.pump();
      expect(find.byKey(const ValueKey('batch-approval-card')), findsNothing);
    });

    testWidgets('Trust… opens the sheet and saves the chosen rule', (
      tester,
    ) async {
      final (controller, runner) = await start(tester, {
        'status': [
          _status([_lowGit], []),
          _status([], []),
        ],
        'approvals': [_approvals],
        'trust': ['{"ok":true,"rule":$_rule,"approved":["req-low"]}'],
      });
      await pumpSheet(tester, controller);
      await tester.tap(find.byKey(const ValueKey('trust-req-low')));
      await tester.pumpAndSettle();
      expect(find.text('Trust Bash'), findsOneWidget);
      await tester.tap(find.text('Bash(git *)'));
      await tester.ensureVisible(
        find.byKey(const ValueKey('trust-duration-1 h')),
      );
      await tester.tap(find.byKey(const ValueKey('trust-duration-1 h')));
      await tester.pump();
      await tester.ensureVisible(find.byKey(const ValueKey('trust-save')));
      await tester.tap(find.byKey(const ValueKey('trust-save')));
      await tester.pumpAndSettle();
      await tester.runAsync(pumpEventQueue);
      await tester.pumpAndSettle();
      final sent = runner.sent('trust').single;
      expect(sent, contains('Bash(git *)'));
      expect(sent, contains('--minutes 60'));
      expect(find.textContaining('Trusted Bash(git status *)'), findsOneWidget);
    });

    testWidgets(
      'Always on a smart companion saves a rule, not Claude Code\'s',
      (tester) async {
        final (controller, runner) = await start(tester, {
          'status': [
            _status([_lowGit], []),
          ],
          'approvals': [_approvals],
          'trust': ['{"ok":true,"rule":$_rule,"approved":["req-low"]}'],
        });
        await pumpSheet(tester, controller);
        await tester.tap(find.text('Always'));
        await tester.pumpAndSettle();
        expect(find.text('Save a rule'), findsOneWidget);
        await tester.ensureVisible(find.byKey(const ValueKey('trust-save')));
        await tester.tap(find.byKey(const ValueKey('trust-save')));
        await tester.pumpAndSettle();
        await tester.runAsync(pumpEventQueue);
        expect(runner.sent('trust').single, contains('--forever'));
        expect(runner.sent('trust').single, contains('--source always'));
        expect(runner.sent('decide'), isEmpty);
      },
    );

    testWidgets('the auto-approved list undoes a trust', (tester) async {
      final (controller, runner) = await start(tester, {
        'status': [_status([], [])],
        'approvals': [_approvals, '{"rules":[],"autoApproved":[]}'],
        'rules remove': ['{"ok":true,"removed":$_rule}'],
      });
      await pumpSheet(tester, controller);
      expect(find.text('AUTO-APPROVED (24 H)  1'), findsOneWidget);
      expect(find.text('git status --short'), findsOneWidget);
      expect(find.textContaining('Trusted in api'), findsOneWidget);
      await tester.tap(find.text('Undo trust'));
      await tester.runAsync(pumpEventQueue);
      await tester.pumpAndSettle();
      expect(
        runner.sent('rules remove').single,
        contains('rules remove r0000000001'),
      );
      expect(find.textContaining('Revoked Bash(git status *)'), findsOneWidget);
    });
  });

  group('rules page', () {
    testWidgets('lists, adds and revokes rules', (tester) async {
      final (controller, runner) = await start(tester, {
        'status': [_status([], [])],
        'approvals': [_approvals],
        'rules add': ['{"ok":true,"rule":$_rule,"approved":[]}'],
        'rules remove': ['{"ok":true,"removed":$_rule}'],
      });
      await tester.pumpWidget(
        MaterialApp(
          home: ApprovalRulesPage(controller: controller, host: host()),
        ),
      );
      await tester.runAsync(pumpEventQueue);
      await tester.pumpAndSettle();
      expect(find.text('Bash(git status *)'), findsOneWidget);
      expect(find.textContaining('in /home/a/api'), findsOneWidget);
      expect(find.textContaining('used 2×'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('rules-add')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('rule-editor-rule')),
        'Bash(cargo test *)',
      );
      await tester.pump();
      await tester.ensureVisible(
        find.byKey(const ValueKey('rule-editor-save')),
      );
      await tester.tap(find.byKey(const ValueKey('rule-editor-save')));
      await tester.pumpAndSettle();
      await tester.runAsync(pumpEventQueue);
      await tester.pumpAndSettle();
      final add = runner.sent('rules add').single;
      expect(add, contains('Bash(cargo test *)'));
      expect(add, contains('--scope repo'));
      expect(add, contains('/home/a/api'));
      expect(add, contains('--forever'));

      await tester.tap(find.byKey(const ValueKey('rule-revoke-r0000000001')));
      await tester.runAsync(pumpEventQueue);
      await tester.pumpAndSettle();
      expect(runner.sent('rules remove').single, contains('r0000000001'));
    });

    Future<void> openRules(
      WidgetTester tester,
      AgentAttentionController controller,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showApprovalRules(
                  context,
                  controller: controller,
                  host: host(),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.runAsync(pumpEventQueue);
      await tester.pumpAndSettle();
    }

    testWidgets(
      'desktop: a dialog over the window, Add rule in the app bar',
      (tester) async {
        final (controller, _) = await start(tester, {
          'status': [_status([], [])],
          'approvals': [_approvals],
        });
        await openRules(tester, controller);
        expect(
          find.byKey(const ValueKey('desktop-page-frame')),
          findsOneWidget,
        );
        expect(find.byType(FloatingActionButton), findsNothing);
        final add = find.byKey(const ValueKey('rules-add'));
        expect(
          find.ancestor(of: add, matching: find.byType(AppBar)),
          findsOneWidget,
        );
        await tester.tap(add);
        await tester.pumpAndSettle();
        expect(find.text('Add rule'), findsNWidgets(2));
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.linux,
        TargetPlatform.windows,
        TargetPlatform.macOS,
      }),
    );

    testWidgets('phone: a full page with the floating Add rule', (
      tester,
    ) async {
      final (controller, _) = await start(tester, {
        'status': [_status([], [])],
        'approvals': [_approvals],
      });
      await openRules(tester, controller);
      expect(find.byKey(const ValueKey('desktop-page-frame')), findsNothing);
      expect(find.byType(FloatingActionButton), findsOneWidget);
    });

    testWidgets('an invalid rule cannot be saved', (tester) async {
      final (controller, _) = await start(tester, {
        'status': [_status([], [])],
        'approvals': ['{"rules":[],"autoApproved":[]}'],
      });
      await tester.pumpWidget(
        MaterialApp(
          home: ApprovalRulesPage(controller: controller, host: host()),
        ),
      );
      await tester.runAsync(pumpEventQueue);
      await tester.pumpAndSettle();
      expect(find.textContaining('No rules yet'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('rules-add')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('rule-editor-rule')),
        'npm test',
      );
      await tester.pump();
      expect(find.text('Tool or Tool(pattern)'), findsOneWidget);
      final save = tester.widget<FilledButton>(
        find.byKey(const ValueKey('rule-editor-save')),
      );
      expect(save.onPressed, isNull);
    });
  });

  group('chat card', () {
    Future<void> pumpCard(
      WidgetTester tester,
      PendingPermissionRequest request, {
      VoidCallback? onTrust,
    }) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatApprovalCard(
            request: request,
            busy: false,
            onDecide: (_) {},
            onTrust: onTrust,
          ),
        ),
      ),
    );

    final low = ConductoreHostAttentionProvider.parseSnapshot(
      _status([_lowGit, _highRm], []),
    ).agents.first.pendingRequests;

    testWidgets('shows the risk line and Trust for a trustable request', (
      tester,
    ) async {
      var trusted = false;
      await pumpCard(tester, low.first, onTrust: () => trusted = true);
      expect(find.text('Low risk'), findsOneWidget);
      expect(find.text('Read-only: git status'), findsOneWidget);
      await tester.tap(find.text('Trust…'));
      expect(trusted, isTrue);
      expect(find.text('Always'), findsOneWidget);
    });

    testWidgets('a high-risk request has no Trust and no Always', (
      tester,
    ) async {
      await pumpCard(tester, low.last, onTrust: () {});
      expect(find.text('High risk'), findsOneWidget);
      expect(find.text('Trust…'), findsNothing);
      expect(find.text('Always'), findsNothing);
      expect(find.text('Allow'), findsOneWidget);
    });
  });
}
