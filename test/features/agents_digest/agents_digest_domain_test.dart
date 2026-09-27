import 'dart:convert';

import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agents_digest/data/digest_preferences.dart';
import 'package:conduit/features/agents_digest/domain/agents_digest.dart';
import 'package:flutter_test/flutter_test.dart';

import 'digest_fakes.dart';

void main() {
  DigestReport parse(Map<String, Object?> json) =>
      parseDigestReport(jsonEncode(json), hostId: 'box', hostName: 'Box')!;

  test('parses a digest reply: facts, stuck flags, summaries, cost', () {
    final report = parse(
      digestReplyJson(
        [
          digestAgentJson(
            'api',
            state: 'needs_permission',
            attention: 'permission',
            headline: 'Tests pass; pushing next.',
            pending: [
              {
                'id': 'r1',
                'toolName': 'Bash',
                'summary': 'git push',
                'risk': {'level': 'medium', 'reason': 'Pushes'},
              },
            ],
            summary: 'Fixed the date bug. It wants to push: approve or deny.',
          ),
          digestAgentJson(
            'etl',
            stuck: [
              {
                'rule': 'same-failure',
                'reason': '`node import.js` failed 3 times',
              },
            ],
            summaryPending: true,
          ),
        ],
        tokensToday: 12000,
        costToday: 0.03,
      ),
    );
    expect(report.agents, hasLength(2));
    final api = report.agents.first;
    expect(api.hostId, 'box');
    expect(api.hostName, 'Box');
    expect(api.attention, DigestAttention.permission);
    expect(api.pending.single.risk!.level, PermissionRiskLevel.medium);
    expect(api.facts.filesEdited, 2);
    expect(api.facts.linesAdded, 48);
    expect(api.facts.testsFailed, 1);
    expect(api.facts.lastTestPassed, isTrue);
    expect(api.facts.tokens, 962010);
    expect(api.facts.costUsd, 0.41);
    expect(api.summaryFresh, isTrue);
    expect(api.line, startsWith('Fixed the date bug.'));
    final etl = report.agents.last;
    expect(etl.stuck.single.reason, '`node import.js` failed 3 times');
    expect(report.hasPendingSummaries, isTrue);
    expect(report.tokensToday, 12000);
    expect(report.costTodayUsd, 0.03);
  });

  test('an older companion or an error is not a digest', () {
    expect(
      parseDigestReport(
        '{"error":"unknown command digest"}',
        hostId: 'b',
        hostName: 'B',
      ),
      isNull,
    );
    expect(parseDigestReport('', hostId: 'b', hostName: 'B'), isNull);
    expect(parseDigestReport('garbage', hostId: 'b', hostName: 'B'), isNull);
  });

  test('sections: needs you, stuck, working, done since, quiet', () {
    final since = digestNow.subtract(const Duration(hours: 2));
    final report = parse(
      digestReplyJson([
        digestAgentJson('ask', attention: 'question'),
        digestAgentJson(
          'loop',
          state: 'working',
          stuck: [
            {'rule': 'repeating', 'reason': 'Ran `curl` 5 times'},
          ],
        ),
        digestAgentJson('busy', state: 'working'),
        digestAgentJson('done'),
        digestAgentJson(
          'old',
          lastActivityAt: since.subtract(const Duration(hours: 1)),
        ),
      ]),
    );
    final overview = DigestOverview(report.agents, since: since);
    String names(DigestSection s) =>
        overview.section(s).map((a) => a.name).join(',');
    expect(names(DigestSection.needsYou), 'ask');
    expect(names(DigestSection.stuck), 'loop');
    expect(names(DigestSection.working), 'busy');
    expect(names(DigestSection.done), 'done');
    expect(names(DigestSection.quiet), 'old');
    expect(overview.count(DigestSection.done), 2, reason: 'quiet ones too');
  });

  test('the facts line stands in for a summary', () {
    final report = parse(
      digestReplyJson([
        digestAgentJson('a', headline: 'All green.'),
        digestAgentJson(
          'b',
          facts: {
            'filesEdited': 1,
            'testRuns': 2,
            'lastTest': {'ok': false},
            'failedCommands': 3,
            'testsFailed': 1,
          },
        ),
        digestAgentJson('c', state: 'working', facts: {}),
      ]),
    );
    final [a, b, c] = report.agents;
    // The one failure was the failing test run: not counted twice.
    expect(a.line, '2 files edited, tests passing. All green.');
    expect(b.line, '1 file edited, tests failing, 2 failed commands.');
    expect(c.line, 'Working.');
  });

  test('an older companion: the monitor status becomes a digest', () {
    final report = digestFromStatus(
      hostId: 'box',
      hostName: 'Box',
      agents: [
        const AgentInfo(
          id: 's1',
          name: 'api',
          state: AgentAttentionState.needsInput,
          pendingRequests: [
            PendingPermissionRequest(id: 'r', toolName: 'Bash', summary: 'ls'),
          ],
        ),
        const AgentInfo(
          id: 's2',
          name: 'web',
          state: AgentAttentionState.needsInput,
          lastMessage: '## Done\n\nShould I deploy?',
        ),
        const AgentInfo(
          id: 's3',
          name: 'docs',
          state: AgentAttentionState.needsInput,
          lastMessage: 'Updated the README.',
        ),
        const AgentInfo(
          id: 's4',
          name: 'ci',
          state: AgentAttentionState.working,
        ),
      ],
    );
    expect(report.fromStatus, isTrue);
    expect(report.activity, isFalse);
    final [api, web, docs, ci] = report.agents;
    expect(api.attention, DigestAttention.permission);
    expect(api.state, 'needs_permission');
    expect(web.attention, DigestAttention.question);
    expect(web.headline, 'Done');
    expect(docs.attention, isNull);
    expect(ci.state, 'working');
    expect(report.hasPendingSummaries, isFalse);
  });

  test('catch me up: counts, then who needs you and who is stuck', () {
    final since = digestNow.subtract(const Duration(hours: 2));
    final report = parse(
      digestReplyJson([
        digestAgentJson(
          'api',
          attention: 'permission',
          summary: 'Fixed the bug. Wants to push.',
        ),
        digestAgentJson(
          'web',
          attention: 'permission',
          pending: [
            {'id': 'r', 'toolName': 'Bash', 'summary': 'rm -rf dist'},
          ],
        ),
        digestAgentJson(
          'etl',
          stuck: [
            {'rule': 'same-failure', 'reason': 'The import failed 3 times'},
          ],
        ),
        digestAgentJson('ci', state: 'working'),
      ]),
    );
    final overview = DigestOverview(report.agents, since: since);
    expect(
      catchUpSpeech(overview, 'en'),
      '2 need you, 1 stuck, 1 working, 0 done. '
      'Needs you: api: Fixed the bug. web: wants approval for Bash. '
      'Stuck: etl: The import failed 3 times.',
    );
    expect(
      catchUpSpeech(overview, 'pt-PT'),
      startsWith('2 precisam de ti, 1 parado, 1 a trabalhar, 0 terminados.'),
    );
    expect(catchUpSpeech(overview, 'pt'), contains('quer aprovação para Bash'));
    expect(
      catchUpSpeech(DigestOverview(const [], since: since), 'en'),
      'No agents are running.',
    );
  });

  test('windows and preferences', () {
    final now = DateTime(2026, 9, 27, 14, 30);
    final seen = DateTime(2026, 9, 27, 9);
    expect(DigestWindow.sinceLastCheck.since(now, seen), seen);
    expect(
      DigestWindow.sinceLastCheck.since(now, null),
      now.subtract(const Duration(hours: 2)),
    );
    expect(DigestWindow.today.since(now, seen), DateTime(2026, 9, 27));
    const thresholds = DigestThresholds(workingMinutes: 60, sameCommands: 10);
    expect(thresholds.arguments, '--stuck-working-min 60 --stuck-repeats 10');
    expect(const DigestThresholds().arguments, '');
    final prefs = DigestPreferences(
      summariesEnabled: false,
      window: DigestWindow.today,
      lastSeen: seen.toUtc(),
      thresholds: thresholds,
    );
    final back = DigestPreferences.fromJson(
      jsonDecode(jsonEncode(prefs.toJson())),
    );
    expect(back.summariesEnabled, isFalse);
    expect(back.window, DigestWindow.today);
    expect(back.lastSeen, seen.toUtc());
    expect(back.thresholds, thresholds);
    expect(DigestPreferences.fromJson(null).summariesEnabled, isTrue);
  });
}
