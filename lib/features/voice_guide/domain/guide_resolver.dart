import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/voice_guide/domain/guide_intent.dart';
import 'package:conduit/features/voice_guide/domain/guide_world.dart';

/// What a [GuideRef] points at in the current [GuideWorld].
sealed class GuideResolved {
  const GuideResolved();
}

class ResolvedAgent extends GuideResolved {
  const ResolvedAgent(this.agent);

  final GuideAgent agent;
}

class ResolvedMachine extends GuideResolved {
  const ResolvedMachine(this.machine);

  final GuideMachine machine;
}

class ResolvedRequest extends GuideResolved {
  const ResolvedRequest(this.pending);

  final GuidePending pending;
}

/// Nothing by that name or id (any more).
class ResolvedNothing extends GuideResolved {
  const ResolvedNothing(this.name, {this.ended});

  /// The name as said, or null for an id (the thing vanished).
  final String? name;

  /// The agent was found but its session ended.
  final GuideAgent? ended;
}

/// Several fit equally well; the guide names them and does nothing.
class ResolvedAmbiguous extends GuideResolved {
  const ResolvedAmbiguous(this.agents);

  final List<GuideAgent> agents;
}

/// Finds what a spoken name or a brain id refers to. Names match agents
/// (name, project), then machines, forgivingly: case, punctuation,
/// "conductor mobile" for "conductore-mobile", a word or two off. "api on
/// VTM" narrows to that machine.
abstract final class GuideResolver {
  static GuideResolved resolve(
    GuideRef ref,
    GuideWorld world, {
    bool agentsOnly = false,
  }) {
    switch (ref) {
      case GuideAgentRef(:final hostId, :final agentId):
        final agent = world.agent(hostId, agentId);
        if (agent == null) return const ResolvedNothing(null);
        if (agent.ended) return ResolvedNothing(null, ended: agent);
        return ResolvedAgent(agent);
      case GuideMachineRef(:final hostId):
        final machine = world.machine(hostId);
        return machine == null
            ? const ResolvedNothing(null)
            : ResolvedMachine(machine);
      case GuideRequestRef(:final hostId, :final requestId):
        final pending = world.request(hostId, requestId);
        return pending == null
            ? const ResolvedNothing(null)
            : ResolvedRequest(pending);
      case GuideProjectRef(:final project):
        return _pick([
          for (final agent in world.live)
            if (agent.label == project) agent,
        ], project);
      case GuideByName(:final name):
        return _byName(name, world, agentsOnly: agentsOnly);
    }
  }

  static GuideResolved _byName(
    String spoken,
    GuideWorld world, {
    required bool agentsOnly,
  }) {
    var name = spoken;
    var machines = world.machines;
    // "api on VTM", "o api no portátil".
    final on = RegExp(r'^(.+?) (?:on|at|in|no|na|em) (.+)$').firstMatch(name);
    if (on != null) {
      final machine = _best(
        world.machines,
        on.group(2)!,
        (machine) => [machine.name],
      );
      if (machine.length == 1) {
        name = on.group(1)!;
        machines = machine;
      }
    }
    final hostIds = {for (final machine in machines) machine.hostId};
    final agents = [
      for (final agent in world.agents)
        if (hostIds.isEmpty || hostIds.contains(agent.hostId)) agent,
    ];
    final byAgent = _best(
      agents,
      name,
      (agent) => [agent.info.name, agent.label],
    );
    if (byAgent.isNotEmpty) {
      final live = [
        for (final agent in byAgent)
          if (!agent.ended) agent,
      ];
      if (live.isEmpty) return ResolvedNothing(spoken, ended: byAgent.first);
      return _pick(live, spoken);
    }
    if (!agentsOnly) {
      final machine = _best(world.machines, name, (m) => [m.name]);
      if (machine.length == 1) return ResolvedMachine(machine.first);
    }
    return ResolvedNothing(spoken);
  }

  /// One agent of [agents]: the only one; else the one waiting on the
  /// user, when exactly one is; else they are ambiguous unless they are
  /// all one project on one machine (then the most recent).
  static GuideResolved _pick(List<GuideAgent> agents, String name) {
    if (agents.isEmpty) return ResolvedNothing(name);
    if (agents.length == 1) return ResolvedAgent(agents.first);
    final waiting = [
      for (final agent in agents)
        if (agent.pending.isNotEmpty || agent.info.state.needsAttention) agent,
    ];
    if (waiting.length == 1) return ResolvedAgent(waiting.first);
    final places = {
      for (final agent in agents) '${agent.hostId}/${agent.label}',
    };
    if (places.length == 1) {
      final newest = [...agents]
        ..sort((a, b) {
          final at = a.info.stateChangedAt;
          final bt = b.info.stateChangedAt;
          if (at == null || bt == null) return at == null ? 1 : -1;
          return bt.compareTo(at);
        });
      return ResolvedAgent(newest.first);
    }
    return ResolvedAmbiguous(agents);
  }

  /// The items of [items] whose names fit [spoken] best (empty when none
  /// fits at all).
  static List<T> _best<T>(
    List<T> items,
    String spoken,
    List<String> Function(T item) names,
  ) {
    var best = 0;
    final result = <T>[];
    for (final item in items) {
      var score = 0;
      for (final name in names(item)) {
        final s = matchScore(spoken, name);
        if (s > score) score = s;
      }
      if (score == 0 || score < best) continue;
      if (score > best) {
        best = score;
        result.clear();
      }
      result.add(item);
    }
    return result;
  }

  static String _words(String text) => text
      .toLowerCase()
      .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
      .trim();

  static String _compact(String text) => _words(text).replaceAll(' ', '');

  /// How well [spoken] names [name]: 4 exact, 3 the same letters and
  /// digits (spacing and punctuation aside), 2 one starts with the other
  /// or all spoken words are in the name, 1 close (an edit or two, for
  /// recognizer slips like "conductor" for "conductore"), 0 no match.
  static int matchScore(String spoken, String name) {
    final a = _words(spoken);
    final b = _words(name);
    if (a.isEmpty || b.isEmpty) return 0;
    if (a == b) return 4;
    final ca = _compact(spoken);
    final cb = _compact(name);
    if (ca == cb) return 3;
    if (ca.length >= 3 && (cb.startsWith(ca) || ca.startsWith(cb))) return 2;
    final nameWords = b.split(' ').toSet();
    if (a.split(' ').every(nameWords.contains)) return 2;
    if (ca.length >= 4 && _distance(ca, cb) <= (ca.length >= 8 ? 2 : 1)) {
      return 1;
    }
    return 0;
  }

  static int _distance(String a, String b) {
    if ((a.length - b.length).abs() > 2) return 3;
    var previous = List<int>.generate(b.length + 1, (i) => i);
    for (var i = 1; i <= a.length; i++) {
      final current = List<int>.filled(b.length + 1, 0)..[0] = i;
      for (var j = 1; j <= b.length; j++) {
        final cost = a[i - 1] == b[j - 1] ? 0 : 1;
        current[j] = [
          previous[j] + 1,
          current[j - 1] + 1,
          previous[j - 1] + cost,
        ].reduce((x, y) => x < y ? x : y);
      }
      previous = current;
    }
    return previous[b.length];
  }
}
