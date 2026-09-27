import 'dart:convert';

import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/voice_guide/domain/approval_actions.dart';
import 'package:conduit/features/voice_guide/domain/guide_intent.dart';
import 'package:conduit/features/voice_guide/domain/guide_world.dart';

/// The snapshot sent with an utterance to the brain, and the map from its
/// short ids (`m1`, `p1`, `a1`, `r1`) back to the app's own. Made fresh for
/// each request; only ids made here are accepted in the answer.
class GuideContext {
  GuideContext._(this.json, this._refs);

  /// Most agents described (the rest are left out).
  static const maxAgents = 40;

  /// Most pending requests described per agent.
  static const maxPending = 5;

  /// Ids and short labels only: never a transcript or a last message.
  factory GuideContext.of(
    GuideWorld world, {
    required String language,
    ApprovalRisk Function(String hostId, PendingPermissionRequest request)?
    riskOf,
  }) {
    final refs = <String, GuideRef>{};
    final machineIds = <String, String>{};
    final projectIds = <String, String>{};
    final machines = <Map<String, Object?>>[];
    final projects = <Map<String, Object?>>[];
    final agents = <Map<String, Object?>>[];
    String cap(String text, int max) {
      final t = text.replaceAll(RegExp(r'\s+'), ' ').trim();
      return t.length <= max ? t : '${t.substring(0, max - 1)}…';
    }

    for (final machine in world.machines) {
      final id = 'm${machines.length + 1}';
      machineIds[machine.hostId] = id;
      refs[id] = GuideMachineRef(machine.hostId);
      machines.add({'id': id, 'name': cap(machine.name, 60)});
    }
    String? onScreen;
    var requests = 0;
    for (final agent in world.agents.take(maxAgents)) {
      final id = 'a${agents.length + 1}';
      refs[id] = GuideAgentRef(agent.hostId, agent.id);
      if (world.onScreen?.same(agent) ?? false) onScreen = id;
      final project = agent.info.projectLabel;
      String? projectId;
      if (project != null && project.isNotEmpty) {
        projectId = projectIds[project];
        if (projectId == null) {
          projectId = 'p${projects.length + 1}';
          projectIds[project] = projectId;
          refs[projectId] = GuideProjectRef(project);
          projects.add({'id': projectId, 'name': cap(project, 60)});
        }
      }
      final pending = <Map<String, Object?>>[];
      for (final request in agent.pending.take(maxPending)) {
        final requestId = 'r${++requests}';
        refs[requestId] = GuideRequestRef(agent.hostId, request.id);
        final risk =
            riskOf?.call(agent.hostId, request) ?? ApprovalRisk.unknown;
        pending.add({
          'id': requestId,
          'tool': cap(request.toolName, 40),
          'summary': cap(request.summary, 120),
          if (risk != ApprovalRisk.unknown) 'risk': risk.name,
        });
      }
      agents.add({
        'id': id,
        'machine': ?machineIds[agent.hostId],
        'name': cap(agent.info.name, 60),
        'project': ?projectId,
        'state': stateName(agent),
        'pending': pending,
      });
    }
    return GuideContext._({
      'lang': language,
      'screen': {
        'view': world.screen.view.name,
        'agent': ?onScreen,
        'machine': ?machineIds[world.screen.hostId],
      },
      'machines': machines,
      'projects': projects,
      'agents': agents,
    }, refs);
  }

  final Map<String, Object?> json;
  final Map<String, GuideRef> _refs;

  /// The app reference for a short id, or null when this context made no
  /// such id.
  GuideRef? ref(String id) => _refs[id];

  static String stateName(GuideAgent agent) {
    if (agent.pending.isNotEmpty) return 'needs_permission';
    return switch (agent.info.state) {
      AgentAttentionState.working => 'working',
      AgentAttentionState.needsInput => 'needs_input',
      AgentAttentionState.blocked => 'blocked',
      AgentAttentionState.finished => 'ended',
      AgentAttentionState.idle => 'idle',
      AgentAttentionState.unknown => 'unknown',
    };
  }

  /// The brain's action as an intent, every id mapped back through this
  /// context. An id it did not make, a target of the wrong kind or a
  /// missing text is rejected: the result is a [GuideSay] of [fallback]
  /// (or the brain's own sentence when the action was only to speak).
  GuideIntent intentFor(GuideBrainAction answer, {required String fallback}) {
    final target = answer.target;
    GuideRef? ref;
    if (target.isNotEmpty) {
      ref = _refs[target];
      if (ref == null) return GuideSay(fallback);
    }
    GuideIntent reject() => GuideSay(fallback);
    bool isAgent(GuideRef? r) => r is GuideAgentRef;
    switch (answer.action) {
      case 'open':
        return ref == null ? reject() : GuideOpen(ref);
      case 'chat':
        return ref == null || isAgent(ref) ? GuideShowChat(ref) : reject();
      case 'terminal':
        return ref == null || isAgent(ref) ? GuideShowTerminal(ref) : reject();
      case 'approve' || 'deny':
        final allow = answer.action == 'approve';
        return ref == null || ref is GuideRequestRef || isAgent(ref)
            ? GuideDecide(allow: allow, target: ref)
            : reject();
      case 'approveAllSafe':
        return const GuideApproveAllSafe();
      case 'trust':
        return (ref == null || isAgent(ref)) && answer.minutes > 0
            ? GuideTrust(answer.minutes, ref)
            : reject();
      case 'send':
        return isAgent(ref) && answer.text.trim().isNotEmpty
            ? GuideSend(ref!, answer.text.trim())
            : reject();
      case 'read':
        return ref == null || isAgent(ref) ? GuideRead(ref) : reject();
      case 'usage':
        return const GuideUsage();
      case 'home':
        return const GuideHome();
      case 'say':
        final text = answer.speak.trim();
        return GuideSay(text.isEmpty ? fallback : text);
    }
    return reject();
  }
}

/// What the brain machine answered.
sealed class GuideBrainReply {
  const GuideBrainReply();

  /// Parses `conductore-hostd guide`'s one JSON line. An older companion
  /// answers "unknown command"; none at all is "not found" (127).
  static GuideBrainReply parse({
    required String stdout,
    required String stderr,
    int? exitCode,
  }) {
    final output = '$stdout\n$stderr';
    if (exitCode == 127 ||
        output.contains('command not found') ||
        output.contains('conductore-hostd: not found')) {
      return const GuideBrainFailed(GuideBrainFailed.missing);
    }
    if (output.contains('unknown command')) {
      return const GuideBrainFailed(GuideBrainFailed.outdated);
    }
    for (final line in stdout.trim().split('\n').reversed) {
      final trimmed = line.trim();
      if (!trimmed.startsWith('{')) continue;
      try {
        final json = jsonDecode(trimmed);
        if (json is! Map) break;
        final action = json['action'];
        if (action is Map) {
          String text(String key) =>
              action[key] is String ? action[key] as String : '';
          return GuideBrainAction(
            action: text('action'),
            target: text('target'),
            text: text('text'),
            minutes: action['minutes'] is int ? action['minutes'] as int : 0,
            speak: text('speak'),
            rejected: json['rejected'] is String
                ? json['rejected'] as String
                : null,
          );
        }
        final error = json['error'];
        if (error is String) {
          return GuideBrainFailed(
            error,
            message: json['message'] is String
                ? json['message'] as String
                : null,
          );
        }
      } on FormatException {
        // Not the reply line.
      }
      break;
    }
    return const GuideBrainFailed(GuideBrainFailed.failed);
  }
}

class GuideBrainAction extends GuideBrainReply {
  const GuideBrainAction({
    required this.action,
    this.target = '',
    this.text = '',
    this.minutes = 0,
    this.speak = '',
    this.rejected,
  });

  final String action;
  final String target;
  final String text;
  final int minutes;
  final String speak;

  /// The companion turned the answer into a `say` (unknown id, missing
  /// text).
  final String? rejected;
}

class GuideBrainFailed extends GuideBrainReply {
  const GuideBrainFailed(this.reason, {this.message});

  // The companion's error codes.
  static const claudeMissing = 'claude-missing';
  static const notLoggedIn = 'not-logged-in';
  static const timeout = 'timeout';
  static const busy = 'busy';
  static const failed = 'failed';

  // The app's own.
  static const outdated = 'outdated';
  static const missing = 'missing';
  static const unreachable = 'unreachable';

  /// No machine can be the brain (none connected with the companion).
  static const noBrain = 'no-brain';

  final String reason;
  final String? message;
}

/// Asks the brain machine what an utterance means.
abstract class GuideBrain {
  /// Completing [cancel] stops waiting (the result is then ignored).
  Future<GuideBrainReply> ask(
    String utterance,
    Map<String, Object?> context, {
    Future<void>? cancel,
  });
}
