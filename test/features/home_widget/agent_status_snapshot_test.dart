import 'dart:convert';

import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/features/agent_attention/data/conductore_host_attention_provider.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/home_widget/domain/agent_status_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.utc(2026, 9, 24, 10, 30);

  AgentInfo agent(String name, AgentAttentionState state) =>
      AgentInfo(id: name, name: name, state: state);

  test('orders agents most urgent first and keeps provider order for ties', () {
    final snapshot = AgentStatusSnapshot.build(
      hosts: [
        (
          hostId: 'host-dev',
          hostName: 'dev',
          agents: [
            agent('idle-1', AgentAttentionState.idle),
            agent('worker-a', AgentAttentionState.working),
            agent('done', AgentAttentionState.finished),
          ],
        ),
        (
          hostId: 'host-prod',
          hostName: 'prod',
          agents: [
            agent('worker-b', AgentAttentionState.working),
            agent('stuck', AgentAttentionState.blocked),
            agent('asks', AgentAttentionState.needsInput),
          ],
        ),
      ],
      monitoring: true,
      now: now,
    );

    expect(snapshot.monitoring, isTrue);
    expect(snapshot.attentionCount, 2);
    expect(snapshot.updatedAt, now);
    expect(snapshot.agents.map((entry) => entry.name), [
      'asks',
      'stuck',
      'done',
      'worker-a',
      'worker-b',
      'idle-1',
    ]);
    expect(snapshot.agents.first.host, 'prod');
    expect(snapshot.agents, hasLength(6));
  });

  test('a companion permission prompt counts as attention', () {
    final parsed = ConductoreHostAttentionProvider.parseSnapshot(
      '{"version":1,"seq":1,"agents":[{"sessionId":"s","name":"api",'
      '"state":"needs_permission","pending":[{"id":"r","toolName":"Bash",'
      '"summary":"ls"}]},{"sessionId":"t","name":"web","state":"working"}]}',
    );
    final snapshot = AgentStatusSnapshot.build(
      hosts: [(hostId: 'host-dev', hostName: 'dev', agents: parsed.agents)],
      monitoring: true,
      now: now,
    );
    expect(snapshot.attentionCount, 1);
    expect(snapshot.agents.first.name, 'api');
    expect(snapshot.agents.first.state, AgentAttentionState.needsInput);
  });

  test('counts every agent needing attention even beyond the row limit', () {
    final snapshot = AgentStatusSnapshot.build(
      hosts: [
        (
          hostId: 'host-dev',
          hostName: 'dev',
          agents: [
            for (var i = 0; i < AgentStatusSnapshot.maxAgents + 2; i++)
              agent('a$i', AgentAttentionState.needsInput),
          ],
        ),
      ],
      monitoring: true,
      now: now,
    );
    expect(snapshot.attentionCount, AgentStatusSnapshot.maxAgents + 2);
    expect(snapshot.agents, hasLength(AgentStatusSnapshot.maxAgents));
  });

  test('agents carry where they live and when their state changed', () {
    final changed = DateTime.utc(2026, 9, 24, 10, 12);
    final snapshot = AgentStatusSnapshot.build(
      hosts: [
        (
          hostId: 'host-dev',
          hostName: 'dev',
          agents: [
            AgentInfo(
              id: 's1',
              name: 'api',
              state: AgentAttentionState.needsInput,
              workspace: 'w1',
              tab: 'main:1',
              pane: '%3',
              stateChangedAt: changed,
            ),
          ],
        ),
      ],
      monitoring: true,
      now: now,
    );
    final json = jsonDecode(snapshot.encode()) as Map<String, Object?>;
    expect((json['agents']! as List).single, {
      'name': 'api',
      'host': 'dev',
      'state': 'needsInput',
      'label': 'Needs input',
      'hostId': 'host-dev',
      'agentId': 's1',
      'workspace': 'w1',
      'tab': 'main:1',
      'pane': '%3',
      'changedAt': changed.millisecondsSinceEpoch,
    });
    expect(AgentStatusSnapshot.decode(snapshot.encode()), snapshot);
  });

  test('empty snapshot is not monitoring', () {
    final snapshot = AgentStatusSnapshot.empty(now);
    expect(snapshot.monitoring, isFalse);
    expect(snapshot.attentionCount, 0);
    expect(snapshot.agents, isEmpty);
  });

  test('encodes the shape the native side reads', () {
    final snapshot = AgentStatusSnapshot.build(
      hosts: [
        (
          hostId: 'host-box',
          hostName: 'dev box',
          agents: [agent('builder', AgentAttentionState.needsInput)],
        ),
      ],
      monitoring: true,
      now: now,
    );

    final json = jsonDecode(snapshot.encode()) as Map<String, Object?>;
    expect(json, {
      'version': 3,
      'monitoring': true,
      'attentionCount': 1,
      'updatedAt': now.millisecondsSinceEpoch,
      'agents': [
        {
          'name': 'builder',
          'host': 'dev box',
          'state': 'needsInput',
          'label': 'Needs input',
          'hostId': 'host-box',
          'agentId': 'builder',
        },
      ],
      'limits': <Object?>[],
    });
  });

  test('carries the limit rings with their warning level', () {
    final resets = DateTime.utc(2026, 9, 25, 15);
    final snapshot = AgentStatusSnapshot.build(
      hosts: const [],
      monitoring: true,
      now: now,
      limits: [
        AgentStatusLimit(label: '5h', usedPct: 83, resetsAt: resets),
        const AgentStatusLimit(label: '7d', usedPct: 12),
      ],
    );
    final json = jsonDecode(snapshot.encode()) as Map<String, Object?>;
    expect(json['limits'], [
      {
        'label': '5h',
        'usedPct': 83,
        'level': 'warning',
        'resetsAt': resets.millisecondsSinceEpoch,
      },
      {'label': '7d', 'usedPct': 12, 'level': 'normal'},
    ]);
    expect(AgentStatusSnapshot.decode(snapshot.encode()), snapshot);
    expect(const AgentStatusLimit(label: '5h', usedPct: 95).level, 'critical');
    expect(const AgentStatusLimit(label: '5h', usedPct: 79).level, 'normal');
  });

  test('round-trips through JSON', () {
    final snapshot = AgentStatusSnapshot.build(
      hosts: [
        (
          hostId: 'host-dev',
          hostName: 'dev',
          agents: [
            agent('a', AgentAttentionState.working),
            agent('b', AgentAttentionState.blocked),
          ],
        ),
      ],
      monitoring: true,
      now: now,
    );
    expect(AgentStatusSnapshot.decode(snapshot.encode()), snapshot);
  });

  test('tolerates missing and unknown fields', () {
    final snapshot = AgentStatusSnapshot.decode(
      '{"agents":[{"name":"x","host":"h","state":"dancing"}]}',
    );
    expect(snapshot.monitoring, isFalse);
    expect(snapshot.attentionCount, 0);
    expect(snapshot.agents.single.state, AgentAttentionState.unknown);
    expect(
      snapshot.updatedAt,
      DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
  });

  group('payload 3', () {
    final dashboard = AgentStatusDashboard(
      needsYou: 2,
      working: 3,
      stuck: 1,
      done: 4,
      factsAt: DateTime.utc(2026, 9, 24, 10, 29),
      lines: [
        AgentStatusLine.capped(
          kind: AgentStatusLineKind.needsYou,
          name: 'api',
          host: 'dev',
          reason: 'approve Bash',
          hostId: 'host-1',
          agentId: 's1',
          workspace: 'w1',
          tab: 'main:1',
          pane: '%3',
        ),
        AgentStatusLine.capped(
          kind: AgentStatusLineKind.stuck,
          name: 'web',
          host: 'dev',
          reason: '`npm test` failed 3 times',
          hostId: 'host-1',
          agentId: 's2',
        ),
      ],
    );
    final theme = AgentStatusTheme.fromPalette(AppPalette.everforest);

    test('carries the dashboard and the theme, and round-trips', () {
      final snapshot = AgentStatusSnapshot.build(
        hosts: const [],
        monitoring: true,
        now: now,
        dashboard: dashboard,
        theme: theme,
      );
      final json = jsonDecode(snapshot.encode()) as Map<String, Object?>;
      expect(json['version'], 3);
      expect(json['dashboard'], {
        'needsYou': 2,
        'working': 3,
        'stuck': 1,
        'done': 4,
        'factsAt': DateTime.utc(2026, 9, 24, 10, 29).millisecondsSinceEpoch,
        'lines': [
          {
            'kind': 'needsYou',
            'name': 'api',
            'host': 'dev',
            'reason': 'approve Bash',
            'hostId': 'host-1',
            'agentId': 's1',
            'workspace': 'w1',
            'tab': 'main:1',
            'pane': '%3',
          },
          {
            'kind': 'stuck',
            'name': 'web',
            'host': 'dev',
            'reason': 'npm test failed 3 times',
            'hostId': 'host-1',
            'agentId': 's2',
          },
        ],
      });
      expect(AgentStatusSnapshot.decode(snapshot.encode()), snapshot);
    });

    test('the Everforest theme is the colours the widget defaults to', () {
      // Mirrors WidgetTheme.EVERFOREST and values/agent_widget.xml.
      expect(theme.toJson(), {
        'dark': true,
        'surface': 0xFF2D353B,
        'onSurface': 0xFFD3C6AA,
        'muted': 0xFFA19B89,
        'border': 0xFF475258,
        'accent': 0xFF7FBBB3,
        'onAccent': 0xFF2D353B,
        'warning': 0xFFDBBC7F,
        'urgent': 0xFFE67E80,
      });
      expect(AgentStatusTheme.fromPalette(AppPalette.white).dark, isFalse);
    });

    test('nothing monitored carries no dashboard', () {
      final snapshot = AgentStatusSnapshot.build(
        hosts: const [],
        monitoring: false,
        now: now,
        dashboard: dashboard,
      );
      expect(snapshot.dashboard, isNull);
      expect(snapshot.toJson().containsKey('dashboard'), isFalse);
    });

    test('a version 2 payload parses without a dashboard or theme', () {
      final snapshot = AgentStatusSnapshot.decode(
        '{"version":2,"monitoring":true,"attentionCount":1,'
        '"updatedAt":1790000000000,'
        '"agents":[{"name":"a","host":"h","state":"needsInput"}],'
        '"limits":[{"label":"5h","usedPct":42,"level":"normal"}],'
        '"dashboard":{"needsYou":9,"working":9}}',
      );
      expect(snapshot.attentionCount, 1);
      expect(snapshot.agents.single.state, AgentAttentionState.needsInput);
      expect(snapshot.limits.single.usedPct, 42);
      // Only payload 3 has these; a stray field in an older one is ignored.
      expect(snapshot.dashboard, isNull);
      expect(snapshot.theme, isNull);
    });

    test('lines are capped to what the widget fits', () {
      final line = AgentStatusLine.capped(
        kind: AgentStatusLineKind.stuck,
        name: 'a very long agent name that goes on and on',
        host: 'a-machine-with-a-long-name.example',
        reason: 'x' * 200,
        hostId: 'h',
        agentId: 'a',
      );
      expect(line.name, hasLength(AgentStatusLine.maxName));
      expect(line.name, endsWith('…'));
      expect(line.host, hasLength(AgentStatusLine.maxHost));
      expect(line.reason, hasLength(AgentStatusLine.maxReason));
      final decoded = AgentStatusDashboard.fromJson({
        'needsYou': 5,
        'working': 0,
        'lines': [for (var i = 0; i < 5; i++) line.toJson()],
      })!;
      expect(decoded.lines, hasLength(AgentStatusDashboard.maxLines));
      expect(decoded.stuck, isNull);
      expect(decoded.done, isNull);
    });
  });
}
