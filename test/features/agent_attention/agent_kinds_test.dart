import 'dart:convert';

import 'package:conduit/features/agent_attention/data/conductore_host_attention_provider.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/domain/agent_kinds.dart';
import 'package:conduit/features/session_navigation/domain/session_view_preferences.dart';
import 'package:flutter_test/flutter_test.dart';

AgentInfo agent(String kind, {String id = 'sid-1'}) => AgentInfo(
  id: id,
  name: 'a',
  state: AgentAttentionState.working,
  kind: kind,
);

void main() {
  group('AgentKindCatalog', () {
    test('parses the companion adapters map and keeps unknown fields off', () {
      final catalog = AgentKindCatalog.fromJson(
        jsonDecode('''{
          "claude": {"label": "Claude Code", "events": "hooks", "approvals": "hook",
                     "always": true, "questions": true, "plans": true, "chat": "entries",
                     "send": "pane", "interrupt": "pane", "liveUsage": true, "limits": true,
                     "history": true, "brain": true, "brainSchema": true,
                     "accounts": "cswap", "facts": "full", "undo": true},
          "codex": {"label": "Codex", "approvals": "hook", "chat": "items",
                    "setup": ["trust-hooks", 3], "always": "yes"},
          "gemini": {"approvals": "observe"},
          "": {"approvals": "hook"},
          "broken": 7
        }'''),
      )!;
      expect(catalog.kinds.keys, ['claude', 'codex', 'gemini']);
      expect(catalog.of('claude'), AgentKindCapabilities.claudeCode);
      final codex = catalog.of('codex');
      expect(codex.label, 'Codex');
      expect(codex.chat, 'items');
      expect(codex.setup, ['trust-hooks']);
      expect(codex.always, isFalse);
      expect(codex.accounts, isNull);
      expect(codex.answersApprovals, isTrue);
      expect(catalog.of('gemini').answersApprovals, isFalse);
    });

    test(
      'without a report Claude Code keeps everything and others get nothing',
      () {
        const legacy = AgentKindCatalog.legacy;
        expect(legacy.of(''), AgentKindCapabilities.claudeCode);
        expect(legacy.of('Claude-Code'), AgentKindCapabilities.claudeCode);
        final codex = legacy.of('Codex');
        expect(codex.kind, 'codex');
        expect(codex.chat, isNull);
        expect(codex.send, isNull);
        expect(codex.answersApprovals, isFalse);
        // A companion report that leaves a kind out falls back the same way.
        final partial = AgentKindCatalog.fromJson({
          'codex': <String, Object?>{},
        })!;
        expect(partial.of('claude'), AgentKindCapabilities.claudeCode);
        expect(AgentKindCatalog.fromJson(null), isNull);
        expect(AgentKindCatalog.fromJson('x'), isNull);
      },
    );
  });

  group('supportsChatView', () {
    test('with the legacy catalog it is exactly isClaudeAgent', () {
      for (final a in [
        agent(''),
        agent('claude'),
        agent('Claude'),
        agent('claude-code'),
        agent('codex'),
        agent('opencode'),
        agent('gemini'),
        agent('claude', id: 'herdr/w1:p2'),
        agent('codex', id: 'herdr@work/w3:p1'),
      ]) {
        expect(
          supportsChatView(a),
          isClaudeAgent(a),
          reason: '${a.kind} ${a.id}',
        );
      }
    });

    test(
      'follows the reported chat format, only for formats the app renders',
      () {
        final catalog = AgentKindCatalog.fromJson({
          'claude': {'chat': 'entries'},
          'codex': {'chat': 'items'},
          'gemini': {'chat': 'entries'},
          'future': {'chat': 'other-format'},
        })!;
        expect(supportsChatView(agent('claude'), catalog), isTrue);
        expect(supportsChatView(agent('gemini'), catalog), isTrue);
        // The neutral format, paged by cursor (CON-068).
        expect(renderableChatFormats.contains('items'), isTrue);
        expect(supportsChatView(agent('codex'), catalog), isTrue);
        expect(supportsChatView(agent('future'), catalog), isFalse);
        expect(
          supportsChatView(agent('claude', id: 'herdr/w1:p2'), catalog),
          isFalse,
        );
        final noChat = AgentKindCatalog.fromJson({
          'claude': {'chat': false},
        })!;
        expect(supportsChatView(agent('claude'), noChat), isFalse);
      },
    );
  });

  group('status adapters', () {
    test('a full status reply carries the catalog, an older one none', () {
      final snapshot = ConductoreHostAttentionProvider.parseSnapshot(
        jsonEncode({
          'version': 1,
          'seq': 3,
          'agents': [
            {'sessionId': 's1', 'state': 'working', 'kind': 'claude'},
            {'sessionId': 's2', 'state': 'working'},
          ],
          'capabilities': ['smart-approvals'],
          'adapters': {
            'claude': {
              'label': 'Claude Code',
              'chat': 'entries',
              'approvals': 'hook',
            },
          },
        }),
      );
      expect(snapshot.kinds!.of('claude').label, 'Claude Code');
      expect(snapshot.agents.map((a) => a.kind), ['claude', 'claude']);
      final older = ConductoreHostAttentionProvider.parseSnapshot(
        jsonEncode({'version': 1, 'seq': 3, 'agents': <Object?>[]}),
      );
      expect(older.kinds, isNull);
    });

    test('a nameless Claude Code agent is still a "Claude session"', () {
      final snapshot = ConductoreHostAttentionProvider.parseSnapshot(
        jsonEncode({
          'version': 1,
          'seq': 1,
          'agents': [
            {'sessionId': 'a', 'state': 'working'},
            {'sessionId': 'b', 'state': 'working', 'kind': 'claude'},
            {'sessionId': 'c', 'state': 'working', 'kind': 'codex'},
          ],
        }),
      );
      expect(snapshot.agents.map((a) => a.name), [
        'Claude session',
        'Claude session',
        'codex',
      ]);
    });
  });
}
