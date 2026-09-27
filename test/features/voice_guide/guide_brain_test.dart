import 'dart:convert';

import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/voice_guide/domain/approval_actions.dart';
import 'package:conduit/features/voice_guide/domain/guide_brain.dart';
import 'package:conduit/features/voice_guide/domain/guide_intent.dart';
import 'package:conduit/features/voice_guide/domain/guide_resolver.dart';
import 'package:conduit/features/voice_guide/domain/guide_world.dart';
import 'package:flutter_test/flutter_test.dart';

import 'guide_fixtures.dart';

void main() {
  group('GuideContext', () {
    test('short ids and labels only, never the last message', () {
      final world = fleet(
        screen: const GuideScreen(
          GuideView.chat,
          hostId: 'vtm',
          agentId: 's-api',
        ),
      );
      final context = GuideContext.of(
        world,
        language: 'en',
        riskOf: (_, request) =>
            request.id == npmTest.id ? ApprovalRisk.low : ApprovalRisk.unknown,
      );
      final json = context.json;
      final text = jsonEncode(json);
      expect(text, isNot(contains('s-api')), reason: 'no real session ids');
      expect(text, isNot(contains('req-npm')));
      expect(text, isNot(contains('pull request')), reason: 'no messages');
      expect(json['lang'], 'en');
      expect(json['machines'], [
        {'id': 'm1', 'name': 'VTM'},
        {'id': 'm2', 'name': 'Laptop'},
      ]);
      final agents = (json['agents']! as List).cast<Map<String, Object?>>();
      expect(agents.first, {
        'id': 'a1',
        'machine': 'm1',
        'name': 'claude',
        'project': 'p1',
        'state': 'needs_permission',
        'pending': [
          {'id': 'r1', 'tool': 'Bash', 'summary': 'npm test', 'risk': 'low'},
        ],
      });
      expect(json['screen'], {'view': 'chat', 'agent': 'a1', 'machine': 'm1'});
      expect(context.ref('a2'), isA<GuideAgentRef>());
      expect((context.ref('r1')! as GuideRequestRef).requestId, 'req-npm');
      expect(context.ref('a9'), isNull);
    });

    test('actions map back to app references; unknown ids are rejected', () {
      final context = GuideContext.of(fleet(), language: 'en');
      GuideIntent intent(
        String action, {
        String target = '',
        String text = '',
        int minutes = 0,
        String speak = '',
      }) => context.intentFor(
        GuideBrainAction(
          action: action,
          target: target,
          text: text,
          minutes: minutes,
          speak: speak,
        ),
        fallback: 'fallback',
      );

      final open = intent('open', target: 'a2') as GuideOpen;
      expect((open.target as GuideAgentRef).agentId, 's-web');
      expect(intent('open', target: 'm2'), isA<GuideOpen>());
      expect(
        ((intent('open', target: 'p1') as GuideOpen).target as GuideProjectRef)
            .project,
        'api',
      );
      final approve = intent('approve', target: 'r1') as GuideDecide;
      expect((approve.target! as GuideRequestRef).requestId, 'req-npm');
      final send =
          intent('send', target: 'a1', text: 'Run the tests') as GuideSend;
      expect((send.target as GuideAgentRef).agentId, 's-api');

      // Ids this context never made, or of the wrong kind, never act.
      expect((intent('open', target: 'a7') as GuideSay).text, 'fallback');
      expect((intent('approve', target: 's-api') as GuideSay).text, 'fallback');
      expect(intent('send', target: 'm1', text: 'x'), isA<GuideSay>());
      expect(intent('send', target: 'a1'), isA<GuideSay>());
      expect(intent('chat', target: 'r1'), isA<GuideSay>());
      expect(intent('trust', target: 'a1'), isA<GuideSay>());
      expect(intent('open'), isA<GuideSay>());
      expect(intent('rm -rf /'), isA<GuideSay>());
      expect(
        (intent('say', speak: 'Two agents.') as GuideSay).text,
        'Two agents.',
      );
    });
  });

  group('GuideBrainReply.parse', () {
    test('an action', () {
      final reply = GuideBrainReply.parse(
        stdout:
            '{"schema":1,"action":{"action":"send","target":"a1","text":"Hi","minutes":0,"speak":"Sending."},"ms":2000,"model":"haiku"}\n',
        stderr: '',
        exitCode: 0,
      );
      final action = reply as GuideBrainAction;
      expect(action.action, 'send');
      expect(action.target, 'a1');
      expect(action.text, 'Hi');
      expect(action.speak, 'Sending.');
      expect(action.rejected, isNull);
    });

    test('errors, an older companion, none', () {
      expect(
        (GuideBrainReply.parse(
                  stdout: '{"schema":1,"error":"busy","message":"x"}',
                  stderr: '',
                  exitCode: 0,
                )
                as GuideBrainFailed)
            .reason,
        'busy',
      );
      expect(
        (GuideBrainReply.parse(
                  stdout: '{"error":"unknown command guide\\nusage: …"}',
                  stderr: '',
                  exitCode: 1,
                )
                as GuideBrainFailed)
            .reason,
        GuideBrainFailed.outdated,
      );
      expect(
        (GuideBrainReply.parse(
                  stdout: '',
                  stderr: 'sh: conductore-hostd: not found',
                  exitCode: 127,
                )
                as GuideBrainFailed)
            .reason,
        GuideBrainFailed.missing,
      );
      expect(
        (GuideBrainReply.parse(stdout: 'garbage', stderr: '', exitCode: 0)
                as GuideBrainFailed)
            .reason,
        GuideBrainFailed.failed,
      );
    });
  });

  group('GuideResolver', () {
    test('forgiving names: case, spacing, a slip of the recognizer', () {
      expect(GuideResolver.matchScore('api', 'api'), 4);
      expect(
        GuideResolver.matchScore('conductore mobile', 'conductore-mobile'),
        4,
      );
      expect(
        GuideResolver.matchScore('conductoremobile', 'conductore-mobile'),
        3,
      );
      expect(
        GuideResolver.matchScore('conductor mobile', 'conductore-mobile'),
        1,
      );
      expect(GuideResolver.matchScore('web', 'website'), 2);
      expect(GuideResolver.matchScore('xyz', 'website'), 0);
    });

    test('agents, projects, machines, "on <machine>"', () {
      final world = fleet();
      expect(
        (GuideResolver.resolve(const GuideByName('web'), world)
                as ResolvedAgent)
            .agent
            .id,
        's-web',
      );
      expect(
        (GuideResolver.resolve(const GuideByName('laptop'), world)
                as ResolvedMachine)
            .machine
            .hostId,
        'laptop',
      );
      expect(
        GuideResolver.resolve(
          const GuideByName('laptop'),
          world,
          agentsOnly: true,
        ),
        isA<ResolvedNothing>(),
      );
      expect(
        (GuideResolver.resolve(const GuideByName('nothing here'), world)
                as ResolvedNothing)
            .name,
        'nothing here',
      );
      final twoApis = GuideWorld(
        machines: const [vtm, laptop],
        agents: [
          agent('a', project: 'api'),
          agent('b', hostId: 'laptop', machine: 'Laptop', project: 'api'),
        ],
      );
      expect(
        GuideResolver.resolve(const GuideByName('api'), twoApis),
        isA<ResolvedAmbiguous>(),
      );
      expect(
        (GuideResolver.resolve(const GuideByName('api on laptop'), twoApis)
                as ResolvedAgent)
            .agent
            .id,
        'b',
      );
    });

    test('ended and vanished agents', () {
      final world = GuideWorld(
        machines: const [vtm],
        agents: [
          agent('old', project: 'api', state: AgentAttentionState.finished),
        ],
      );
      final named = GuideResolver.resolve(const GuideByName('api'), world);
      expect((named as ResolvedNothing).ended?.id, 'old');
      final byId = GuideResolver.resolve(
        const GuideAgentRef('vtm', 'old'),
        world,
      );
      expect((byId as ResolvedNothing).ended?.id, 'old');
      expect(
        GuideResolver.resolve(const GuideAgentRef('vtm', 'gone'), world),
        isA<ResolvedNothing>(),
      );
    });
  });
}
