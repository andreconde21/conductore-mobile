import 'dart:async';

import 'package:conduit/core/presentation/terminal_route.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/domain/agent_kinds.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_launcher.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/session_navigation/domain/session_view_preferences.dart';
import 'package:conduit/features/session_navigation/presentation/session_view_controller.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:conduit/features/sessions/presentation/herdr_session_focus.dart';
import 'package:conduit/features/terminal/domain/herdr_remote_control.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:conduit/features/voice/presentation/dictation_controller.dart';
import 'package:flutter/widgets.dart';

/// Whether [agent] (opened from a list of agents, at its pane) should show
/// in Chat View: a Claude session on a machine the companion monitors, and
/// the effective view of [sessionHostId] (the session it opens in) is Chat
/// View.
bool agentOpensInChat({
  required SessionViewController? views,
  required AgentAttentionController? attention,
  required SavedHost monitoredHost,
  required AgentInfo agent,
  String? sessionHostId,
}) {
  if (views == null || attention == null) return false;
  final runsClaude =
      supportsChatView(agent, attention.agentKinds(monitoredHost.id)) &&
      agent.state != AgentAttentionState.finished &&
      chatViewAvailable(attention, monitoredHost);
  return views.viewFor(
        sessionHostId ?? monitoredHost.id,
        runsClaude: runsClaude,
      ) ==
      SessionView.chat;
}

/// How long a session that is still connecting (a dormant workspace just
/// attached, a restored session coming back) may take to report its
/// agents before it stays in the terminal.
const preferredChatWait = Duration(seconds: 15);

/// The [openPreferredChatView] still waiting, per agent monitor: a newer
/// one replaces it.
final _waiting = Expando<_PreferredChatOpen>('preferred chat open');

/// Shows [session] (just opened, or brought to the front) in Chat View
/// when that is its effective view (its own choice, else the default) and
/// it runs a Claude session the companion reports; otherwise it stays in
/// the terminal the caller already showed. Completes with whether Chat
/// View opened. [onOpenTerminal] runs when its Terminal button is used,
/// with the monitored session the chat was opened through.
///
/// Which Claude session: [agent] when given (a notification, a pane
/// picked on home), and only that one (the same id, else the one in its
/// pane). Otherwise the one where [session]
/// is: its Herdr workspace ([herdr] tracks where a reused session was
/// moved) or its tmux session. Several there: the pane Herdr has focused
/// (the one on screen), else the one whose state changed last, which is
/// the one last worked in. A session that says nothing about where it is
/// (a plain shell) shows the machine's only Claude session, and only when
/// that is already known.
///
/// A session still connecting has no agents yet: this waits for its
/// agent monitor's first status, up to [wait], and gives up as soon as
/// the user moves on (another session, another page on top, the session
/// closed) or the machine turns out to have no companion.
Future<bool> openPreferredChatView(
  BuildContext context, {
  required AgentAttentionController? attention,
  required TerminalWorkspaceController workspace,
  required TerminalSessionController session,
  required void Function(SavedHost host, AgentInfo agent) onOpenTerminal,
  AgentInfo? agent,
  HerdrSessionFocus? herdr,
  DictationController? dictation,
  Duration wait = preferredChatWait,
}) async {
  final views = SessionViewScope.maybeOf(context);
  final navigator = Navigator.maybeOf(context);
  if (views == null ||
      attention == null ||
      navigator == null ||
      session.host.isLocal ||
      !attention.monitoringEnabled(session.host)) {
    return false;
  }
  ChatSessionLocation location() =>
      ChatSessionLocation(herdrWorkspaceId: herdr?.workspaceOf(session) ?? '');
  // Cheap test first: a session that opens in the terminal anyway needs
  // no agent lookup.
  final viewHostId = _viewHostId(session.host, location());
  if (views.viewFor(viewHostId, runsClaude: true) != SessionView.chat) {
    return false;
  }
  _waiting[attention]?.cancel();
  final pending = _PreferredChatOpen();
  _waiting[attention] = pending;
  // What is on top now (the terminal page, or home in the desktop shell):
  // anything pushed over it, or its pop, means the user moved on.
  final anchor = topRouteOf(navigator);
  bool wanted() =>
      !pending.cancelled &&
      context.mounted &&
      (anchor?.isCurrent ?? true) &&
      workspace.activeSession == session;

  _ChatStep step() => _nextStep(
    attention,
    session,
    agent: agent,
    location: location(),
    canWait: agent != null || _located(session.host),
  );

  try {
    var next = step();
    if (next is _Wait) {
      next = await pending.until(
        () => wanted() ? step() : const _GiveUp(),
        changes: Listenable.merge([attention, workspace, session]),
        timeout: wait,
      );
    }
    final (host, shown) = switch (next) {
      _Show(:final host, :final agent) => (host, agent),
      _Pick(:final host, :final candidates) => (
        host,
        await _pickInPlace(
          candidates,
          session,
          location(),
          herdr,
          attention.agentKinds(host.id),
        ),
      ),
      _ => (null, null),
    };
    if (host == null || shown == null || !wanted() || !context.mounted) {
      return false;
    }
    // Not awaited: the route stays up until the user leaves it.
    unawaited(
      openChatView(
        context: context,
        attention: attention,
        host: host,
        agent: shown,
        dictation: dictation,
        onOpenTerminal: () => onOpenTerminal(host, shown),
      ),
    );
    return true;
  } finally {
    if (identical(_waiting[attention], pending)) _waiting[attention] = null;
  }
}

/// The session host id [host]'s view choice is read under: a Herdr
/// session that was moved to another workspace reads that workspace's.
String _viewHostId(SavedHost host, ChatSessionLocation location) {
  final target = ConnectTarget.fromSessionHostId(host.id);
  final workspace = location.herdrWorkspaceId;
  if (target == null ||
      target.kind != ConnectTargetKind.herdr ||
      workspace.isEmpty ||
      workspace == target.name) {
    return host.id;
  }
  return ConnectTarget.herdr(
    workspaceId: workspace,
    session: target.session,
  ).apply(host.copyWith(id: baseHostId(host.id))).id;
}

/// Whether [host] (a session host) names the place its Claude session
/// runs in: a Herdr workspace or a tmux session.
bool _located(SavedHost host) {
  final target = ConnectTarget.fromSessionHostId(host.id);
  return switch (target?.kind) {
    ConnectTargetKind.herdr => target!.name.isNotEmpty,
    _ => host.startTmuxOnConnect && host.tmuxSessionName.isNotEmpty,
  };
}

sealed class _ChatStep {
  const _ChatStep();
}

/// Not known yet: the session is connecting or its monitor's first status
/// has not come.
class _Wait extends _ChatStep {
  const _Wait();
}

/// The terminal it is.
class _GiveUp extends _ChatStep {
  const _GiveUp();
}

class _Show extends _ChatStep {
  const _Show(this.host, this.agent);

  final SavedHost host;
  final AgentInfo agent;
}

/// Several Claude sessions where the session is.
class _Pick extends _ChatStep {
  const _Pick(this.host, this.candidates);

  final SavedHost host;
  final List<AgentInfo> candidates;
}

_ChatStep _nextStep(
  AgentAttentionController attention,
  TerminalSessionController session, {
  required AgentInfo? agent,
  required ChatSessionLocation location,
  required bool canWait,
}) {
  final notYet = canWait ? const _Wait() : const _GiveUp();
  // A given agent can be read from any monitored session on its machine;
  // the session's own agent only from the session's own monitor.
  final host = attention.isMonitoring(session.host.id)
      ? session.host
      : agent == null
      ? null
      : attention.monitoredHosts
            .where(
              (host) =>
                  baseHostId(host.id) == baseHostId(session.host.id) &&
                  attention.statusFor(host.id)?.updatedAt != null,
            )
            .firstOrNull;
  if (host == null) return notYet;
  final status = attention.statusFor(host.id)!;
  if (status.unavailableReason != null) return const _GiveUp();
  if (status.updatedAt == null || status.loading) return notYet;
  // A failed poll says nothing yet; the next one may.
  final settled = status.error == null ? const _GiveUp() : notYet;
  if (!chatViewAvailable(attention, host)) return settled;
  final kinds = attention.agentKinds(host.id);
  if (agent != null) {
    final live = _sameAgent(agent, status.agents);
    return live != null && supportsChatView(live, kinds)
        ? _Show(host, live)
        : settled;
  }
  return switch (resolveChatAgent(host, status.agents, location: location)) {
    ChatAgentMatched(:final agent) when supportsChatView(agent, kinds) => _Show(
      host,
      agent,
    ),
    ChatAgentAmbiguous(:final candidates, inPlace: true) => _Pick(
      host,
      candidates,
    ),
    _ => settled,
  };
}

/// [agent] among [agents] as the companion reports it: by its id, else
/// (an agent from Herdr's own listing, as the home board has them) the
/// live one in its pane.
AgentInfo? _sameAgent(AgentInfo agent, List<AgentInfo> agents) {
  final live = [
    for (final candidate in agents)
      if (candidate.state != AgentAttentionState.finished) candidate,
  ];
  final byId = live.where((candidate) => candidate.id == agent.id);
  if (byId.isNotEmpty) return byId.first;
  final pane = agent.pane ?? '';
  if (pane.isEmpty) return null;
  final inPane = live.where(
    (candidate) =>
        candidate.pane == pane &&
        (agent.workspace == null || candidate.workspace == agent.workspace),
  );
  return inPane.isEmpty ? null : mostRecentAgent(inPane.toList());
}

/// Of several Claude sessions in [session]'s place: the pane Herdr has
/// focused, else the most recently active. Null when the focused pane
/// runs something else (a shell, another agent).
Future<AgentInfo?> _pickInPlace(
  List<AgentInfo> candidates,
  TerminalSessionController session,
  ChatSessionLocation location,
  HerdrSessionFocus? herdr,
  AgentKindCatalog kinds,
) async {
  HerdrFocusedPane? focused;
  final control = HerdrSessionFocus.herdrTargetOf(session) == null
      ? null
      : herdr?.controlFor(session);
  if (control != null) {
    try {
      focused = await control.readFocusedPane().timeout(
        const Duration(seconds: 3),
      );
    } catch (_) {
      // Best effort: the most recent one below.
    }
  }
  final workspace = location.herdrWorkspaceId;
  if (focused != null &&
      (workspace.isEmpty ||
          focused.workspaceId.isEmpty ||
          focused.workspaceId == workspace)) {
    final paneId = focused.paneId;
    final inPane = candidates.where((agent) => agent.pane == paneId);
    if (inPane.isNotEmpty) {
      return supportsChatView(inPane.first, kinds) ? inPane.first : null;
    }
  }
  final claude = [
    for (final agent in candidates)
      if (supportsChatView(agent, kinds)) agent,
  ];
  return claude.isEmpty ? null : mostRecentAgent(claude);
}

/// One [openPreferredChatView] waiting for its session's agents.
class _PreferredChatOpen {
  bool cancelled = false;
  VoidCallback? _wake;

  void cancel() {
    cancelled = true;
    _wake?.call();
  }

  /// Re-runs [step] on every change until it is no longer [_Wait], or
  /// [timeout] passes.
  Future<_ChatStep> until(
    _ChatStep Function() step, {
    required Listenable changes,
    required Duration timeout,
  }) {
    final done = Completer<_ChatStep>();
    void finish(_ChatStep result) {
      if (!done.isCompleted) done.complete(result);
    }

    void check() {
      final next = cancelled ? const _GiveUp() : step();
      if (next is! _Wait) finish(next);
    }

    final timer = Timer(timeout, () => finish(const _GiveUp()));
    changes.addListener(check);
    _wake = check;
    return done.future.whenComplete(() {
      timer.cancel();
      changes.removeListener(check);
      _wake = null;
    });
  }
}
