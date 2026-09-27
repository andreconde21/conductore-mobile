import 'dart:async';

import 'package:conduit/core/app_failure.dart';
import 'package:conduit/core/connection_problem.dart';
import 'package:conduit/core/presentation/adaptive_modal.dart';
import 'package:conduit/core/presentation/connection_details.dart';
import 'package:conduit/core/presentation/terminal_route.dart';
import 'package:conduit/features/agent_attention/data/conductore_host_attention_provider.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/chat_view/data/attention_host_runner.dart';
import 'package:conduit/features/chat_view/data/conductore_chat_client.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_controller.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_page.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_presenter.dart';
import 'package:conduit/features/companion_setup/data/companion_probe.dart';
import 'package:conduit/features/companion_setup/domain/companion_status.dart';
import 'package:conduit/features/companion_setup/presentation/companion_setup_controller.dart';
import 'package:conduit/features/companion_setup/presentation/companion_setup_page.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:conduit/features/terminal/domain/prompt_image.dart';
import 'package:conduit/features/voice/presentation/dictation_controller.dart';
import 'package:flutter/material.dart';

/// Whether [host]'s agents come from the Conductore companion, which the
/// chat view needs (Herdr alone has no transcript or prompt relay here).
bool chatViewAvailable(AgentAttentionController attention, SavedHost host) =>
    attention.isMonitoring(host.id) &&
    attention.providerFor(host.id).id ==
        const ConductoreHostAttentionProvider().id;

List<AgentInfo> _live(Iterable<AgentInfo> agents) => [
  for (final agent in agents)
    if (agent.state != AgentAttentionState.finished) agent,
];

/// Where a terminal session is inside its multiplexer, as far as the app
/// knows beyond its connect target: the Herdr workspace it was moved to and
/// the pane Herdr has focused (the one on screen).
class ChatSessionLocation {
  const ChatSessionLocation({
    this.herdrWorkspaceId = '',
    this.herdrTabId = '',
    this.herdrPaneId = '',
  });

  final String herdrWorkspaceId;
  final String herdrTabId;
  final String herdrPaneId;

  bool get hasPane => herdrPaneId.isNotEmpty;
}

/// Which Claude session a terminal session is showing.
sealed class ChatAgentMatch {
  const ChatAgentMatch();
}

/// Exactly one live Claude session fits.
class ChatAgentMatched extends ChatAgentMatch {
  const ChatAgentMatched(this.agent);

  final AgentInfo agent;
}

/// Several fit and nothing tells them apart: the user picks one of
/// [candidates].
class ChatAgentAmbiguous extends ChatAgentMatch {
  const ChatAgentAmbiguous(this.candidates, {this.elsewhere = false});

  final List<AgentInfo> candidates;

  /// None of [candidates] is where the session is (its Herdr workspace or
  /// tmux session runs no Claude): ask even when there is only one.
  final bool elsewhere;
}

/// No live Claude session on the machine.
class ChatAgentNone extends ChatAgentMatch {
  const ChatAgentNone();
}

/// One agent per pane: a pane runs one Claude at a time, so when the
/// companion still lists an older session for the same pane, the most
/// recently updated one is the one on screen.
List<AgentInfo> _latestPerPane(List<AgentInfo> agents) {
  final byPane = <String, AgentInfo>{};
  final result = <AgentInfo>[];
  for (final agent in agents) {
    final pane = agent.pane;
    if (pane == null || pane.isEmpty) {
      result.add(agent);
      continue;
    }
    final seen = byPane[pane];
    if (seen == null) {
      byPane[pane] = agent;
      result.add(agent);
    } else if (_newer(agent, seen)) {
      byPane[pane] = agent;
      result[result.indexOf(seen)] = agent;
    }
  }
  return result;
}

bool _newer(AgentInfo a, AgentInfo b) {
  final at = a.stateChangedAt;
  final bt = b.stateChangedAt;
  if (at == null) return false;
  if (bt == null) return true;
  return at.isAfter(bt);
}

/// Narrows [candidates] step by step: the first filter that leaves exactly
/// one agent wins; a filter that leaves several narrows the rest; one that
/// leaves none is skipped.
List<AgentInfo> _narrow(
  List<AgentInfo> candidates,
  List<bool Function(AgentInfo)> filters,
) {
  var current = candidates;
  for (final filter in filters) {
    final next = current.where(filter).toList();
    if (next.isEmpty) continue;
    current = next;
    if (current.length == 1) break;
  }
  return current;
}

/// The Claude session among [agents] that the terminal session on [host]
/// is showing.
///
/// A Herdr session matches on Herdr's own ids, as the companion reports
/// them (`herdr.workspaceId` like `w7`, `tabId` like `w7:t1`, `paneId`
/// like `w7:p1`): the focused pane when [location] knows it, else the
/// session's tab, else its workspace ([location]'s, which follows moves
/// inside Herdr, else the connect target's). A tmux session matches on its
/// session name. When that leaves several agents, or the session says
/// nothing about where it is and the machine runs several, the result is
/// [ChatAgentAmbiguous] so the caller can ask.
ChatAgentMatch resolveChatAgent(
  SavedHost host,
  Iterable<AgentInfo> agents, {
  ChatSessionLocation location = const ChatSessionLocation(),
}) {
  final live = _latestPerPane(_live(agents));
  if (live.isEmpty) {
    return const ChatAgentNone();
  }
  final target = ConnectTarget.fromSessionHostId(host.id);
  List<AgentInfo> scoped = const [];
  var located = false;
  if (target?.kind == ConnectTargetKind.herdr) {
    final workspace = location.herdrWorkspaceId.isNotEmpty
        ? location.herdrWorkspaceId
        : target!.name;
    final tab = location.herdrTabId.isNotEmpty
        ? location.herdrTabId
        : target!.tabId;
    located = workspace.isNotEmpty;
    final inWorkspace = workspace.isEmpty
        ? live
        : live.where((agent) => agent.workspace == workspace).toList();
    scoped = inWorkspace.isEmpty
        ? const []
        : _narrow(inWorkspace, [
            if (tab.isNotEmpty) (agent) => agent.tab == tab,
            if (location.hasPane) (agent) => agent.pane == location.herdrPaneId,
          ]);
  } else if (host.startTmuxOnConnect && host.tmuxSessionName.isNotEmpty) {
    final name = host.tmuxSessionName;
    located = true;
    scoped = live
        .where(
          (agent) =>
              agent.tab == name || (agent.tab?.startsWith('$name:') ?? false),
        )
        .toList();
  }
  if (scoped.length == 1) {
    return ChatAgentMatched(scoped.single);
  }
  if (scoped.length > 1) {
    return ChatAgentAmbiguous(scoped);
  }
  if (located) {
    return ChatAgentAmbiguous(live, elsewhere: true);
  }
  return live.length == 1
      ? ChatAgentMatched(live.single)
      : ChatAgentAmbiguous(live);
}

/// [resolveChatAgent]'s agent when exactly one fits, else null.
AgentInfo? matchChatAgent(
  SavedHost host,
  Iterable<AgentInfo> agents, {
  ChatSessionLocation location = const ChatSessionLocation(),
}) => switch (resolveChatAgent(host, agents, location: location)) {
  ChatAgentMatched(:final agent) => agent,
  _ => null,
};

/// [matchChatAgent] over what the agent monitor already knows; null when
/// [host] is not monitored through the companion (see
/// [checkChatViewAccess] for asking the machine itself).
AgentInfo? chatAgentForSession(
  AgentAttentionController attention,
  SavedHost host,
) {
  if (!chatViewAvailable(attention, host)) {
    return null;
  }
  return matchChatAgent(
    host,
    attention.statusFor(host.id)?.agents ?? const <AgentInfo>[],
  );
}

/// Whether Chat View can open for a machine, decided by the companion on
/// it rather than by the monitoring setting.
class ChatViewAccess {
  const ChatViewAccess.ready({required this.agents, required this.monitored})
    : title = null,
      problem = null,
      detail = null,
      canSetUp = false,
      companionMissing = false;

  const ChatViewAccess.blocked({
    required String this.title,
    required String this.problem,
    this.detail,
    this.canSetUp = true,
    this.companionMissing = false,
  }) : agents = const [],
       monitored = false;

  /// The machine's live Claude sessions, when [ready].
  final List<AgentInfo> agents;

  /// Whether they came from the running agent monitor (else from a direct
  /// `conductore-hostd status`).
  final bool monitored;

  /// Dialog title and text naming exactly what failed, when blocked.
  final String? title;
  final String? problem;

  /// The technical reason behind [problem], shown behind "Details".
  final String? detail;

  /// The machine could not be reached or refused the sign-in: [problem]
  /// already says what to check.
  factory ChatViewAccess.connection(ConnectionProblem problem) =>
      ChatViewAccess.blocked(
        title: problem.title,
        problem: problem.message,
        detail: problem.detail,
        canSetUp: false,
      );

  /// Whether the Agent hooks screen can fix it.
  final bool canSetUp;

  /// The machine has no companion at all (a plain SSH box, most likely),
  /// as opposed to a companion that is broken or out of date.
  final bool companionMissing;

  bool get ready => problem == null;
}

/// The saved machine behind a (possibly derived) session host, as the
/// Agent hooks screen caches it.
SavedHost _machine(SavedHost host) => host.copyWith(id: baseHostId(host.id));

/// Decides whether Chat View can open for [host] by asking its companion:
/// the monitor's list when it already watches [host] through the
/// companion, else a companion check ([companion]'s cached or fresh one,
/// or a direct probe) and a `conductore-hostd status` for the sessions.
/// Works whether or not "Monitor coding agents" is on.
Future<ChatViewAccess> checkChatViewAccess({
  required AgentAttentionController attention,
  required SavedHost host,
  CompanionSetupController? companion,
}) async {
  if (chatViewAvailable(attention, host)) {
    return ChatViewAccess.ready(
      agents: _live(attention.statusFor(host.id)?.agents ?? const []),
      monitored: true,
    );
  }
  final machine = _machine(host);
  CompanionStatus status;
  if (companion != null) {
    final cached = companion.statusFor(machine);
    status = cached != null && cached.state.isWorking
        ? cached
        : await companion.refresh(machine);
  } else {
    final (runner, :owned) = attention.runnerFor(host);
    try {
      status = await const CompanionProbe().check(runner);
    } finally {
      if (owned) await runner.close();
    }
  }
  if (!status.state.isWorking) {
    return _blockedBy(status, host);
  }
  final (runner, :owned) = attention.runnerFor(host);
  try {
    final snapshot = await const ConductoreHostAttentionProvider().fetchAgents(
      runner,
    );
    return ChatViewAccess.ready(
      agents: _live(snapshot.agents),
      monitored: false,
    );
  } catch (error) {
    final unreached = connectionProblemFor(
      error,
      machine: host.name,
      address: host.host,
      retryLabel: null,
    );
    if (unreached != null) return ChatViewAccess.connection(unreached);
    final detail = error is AppFailure ? error.userMessage : '$error';
    return ChatViewAccess.blocked(
      title: 'Could not list Claude sessions',
      problem:
          'The companion${_version(status)} is installed on ${host.name}, '
          'but "conductore-hostd status" failed: $detail',
      canSetUp: false,
    );
  } finally {
    if (owned) await runner.close();
  }
}

String _version(CompanionStatus status) {
  final version = status.installedVersion;
  return version == null ? '' : ' $version';
}

ChatViewAccess _blockedBy(CompanionStatus status, SavedHost host) {
  final name = host.name;
  final failure = status.connectionFailure;
  final unreached = failure == null
      ? null
      : connectionProblemFor(
          failure,
          machine: name,
          address: host.host,
          retryLabel: null,
        );
  if (unreached != null) return ChatViewAccess.connection(unreached);
  return switch (status.state) {
    CompanionState.notInstalled => ChatViewAccess.blocked(
      companionMissing: true,
      title: 'Chat view needs the companion',
      problem:
          '"conductore-hostd" was not found on $name'
          '${status.user == null ? '' : ' for ${status.user}'}. '
          '${ConductoreChatClient.installHint}',
    ),
    CompanionState.hooksMissing => ChatViewAccess.blocked(
      title: 'Claude Code hooks are not registered',
      problem:
          'The companion${_version(status)} is installed on $name, but '
          'Claude Code\'s hooks are not registered, so it cannot see '
          'sessions. Register them from Agent hooks.',
    ),
    CompanionState.outdated => ChatViewAccess.blocked(
      title: 'The companion needs an update',
      problem:
          'The companion on $name is version '
          '${status.installedVersion ?? 'unknown'}; this app needs '
          '$kCompanionMinVersion or newer. Update it from Agent hooks.',
    ),
    _ => ChatViewAccess.blocked(
      title: 'Could not check the companion',
      problem:
          'Checking the companion on $name failed: '
          '${[status.message, status.errorDetail].nonNulls.join(' ').trim()}',
      canSetUp: false,
    ),
  };
}

/// Opens the chat view for [agent] on [host] as a full-screen route, or
/// through the nearest [ChatViewPresenter] (the desktop shell's tabs).
/// [onOpenTerminal] runs after the route is popped by its Terminal button
/// (the caller shows that session's TUI).
Future<void> openChatView({
  required BuildContext context,
  required AgentAttentionController attention,
  required SavedHost host,
  required AgentInfo agent,
  required VoidCallback onOpenTerminal,
  DictationController? dictation,
  Widget Function(BuildContext routeContext)? accessoryBuilder,
  String initialDraft = '',
  PromptImageAttacher? imageAttacher,
  bool pasteImages = true,
}) async {
  // Resolved per command: the monitor's connection is replaced when the
  // session reconnects, and the chat may stay open across that.
  final runner = AttentionHostRunner(attention, host);
  final changes = _AgentChangeSignal(attention, host.id, agent.id);
  Future<void> decide(
    PendingPermissionRequest request,
    PermissionVerdict verdict,
  ) async {
    if (attention.isMonitoring(host.id)) {
      return attention.decide(host.id, request, verdict);
    }
    final command = const ConductoreHostAttentionProvider().decideCommand(
      request,
      verdict,
    );
    final result = await runner.run(
      command!,
      timeout: const Duration(seconds: 15),
    );
    if (result.exitCode != null && result.exitCode != 0) {
      throw ConductoreHostAttentionProvider.failureFrom(
        result.stdout,
        result.stderr,
      );
    }
  }

  final controller = ChatViewController(
    runner: runner,
    ownsRunner: true,
    sessionId: agent.id,
    fallbackName: agent.name,
    decide: decide,
    agentChanges: changes,
  );
  // The desktop shell shows the chat as a tab in its panes.
  final presenter = ChatViewPresenter.maybeOf(context);
  if (presenter != null) {
    final companion = CompanionSetupScope.maybeOf(context);
    final presented = presenter.present(
      ChatViewRequest(
        host: host,
        agent: agent,
        controller: controller,
        onOpenTerminal: onOpenTerminal,
        onDispose: changes.dispose,
        dictation: dictation,
        initialDraft: initialDraft,
        imageAttacher: imageAttacher,
        pasteImages: pasteImages,
        attention: attention,
        onSetUpCompanion: companion == null || !context.mounted
            ? null
            : () => showCompanionSetup(context, host),
        onEnableMonitoring: attention.monitoringEnabled(host)
            ? null
            : () => attention.enableMonitoring(host),
      ),
    );
    if (presented) return;
  }
  var toTerminal = false;
  final navigator = Navigator.of(context);
  // Opened over a terminal page (its Chat button, a session that opens in
  // Chat View): back leaves that page too, straight home. The Terminal
  // button is how to switch modes.
  final over = topRouteOf(navigator);
  await navigator.push(
    MaterialPageRoute<void>(
      settings: chatRouteSettings(hostId: host.id, agentId: agent.id),
      builder: (routeContext) => ChatViewPage(
        controller: controller,
        hostName: host.name,
        dictation: dictation,
        accessory: accessoryBuilder?.call(routeContext),
        initialDraft: initialDraft,
        imageAttacher: imageAttacher,
        pasteImages: pasteImages,
        attention: attention,
        hostId: host.id,
        onSetUpCompanion: CompanionSetupScope.maybeOf(routeContext) == null
            ? null
            : () => showCompanionSetup(routeContext, host),
        onEnableMonitoring: attention.monitoringEnabled(host)
            ? null
            : () => attention.enableMonitoring(host),
        onOpenTerminal: () {
          toTerminal = true;
          Navigator.of(routeContext).pop();
        },
      ),
    ),
  );
  changes.dispose();
  if (toTerminal) {
    onOpenTerminal();
  } else if (over != null &&
      isTerminalRoute(over) &&
      over.isCurrent &&
      navigator.mounted) {
    // Like back on the terminal page: sessions stay open in the workspace,
    // and a PopScope there still gets its say.
    await navigator.maybePop();
  }
}

/// Explains why the chat view cannot open for [host] and how to fix it.
/// [access] names the failed condition; without it (no agent monitor in
/// this build, so nothing could be checked) the install steps are shown.
Future<void> showChatViewUnavailable(
  BuildContext context, {
  required SavedHost host,
  ChatViewAccess? access,
}) {
  final title = access?.title ?? 'Chat view needs the companion';
  final detail = access?.detail;
  final message =
      access?.problem ??
      'Chat view reads the session through the Conductore companion on '
          '${host.name}. ${ConductoreChatClient.installHint}';
  final canSetUp =
      (access?.canSetUp ?? true) &&
      CompanionSetupScope.maybeOf(context) != null;
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: detail == null
          ? SelectableText(message)
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(message),
                const SizedBox(height: 4),
                ConnectionDetails(detail: detail),
              ],
            ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('OK'),
        ),
        if (canSetUp)
          FilledButton(
            key: const ValueKey('chat-unavailable-agent-hooks'),
            onPressed: () {
              Navigator.of(dialogContext).pop();
              showCompanionSetup(context, _machine(host));
            },
            child: const Text('Agent hooks'),
          ),
      ],
    ),
  );
}

/// Picks which Claude session on [host] to open: the only live one, or
/// the user's choice. Null when there is none (after telling the user) or
/// the picker was dismissed.
Future<AgentInfo?> pickChatAgent(
  BuildContext context, {
  required SavedHost host,
  required List<AgentInfo> agents,
  String title = 'Open chat for…',
  bool alwaysAsk = false,
}) async {
  agents = _live(agents);
  if (agents.isEmpty) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(
          'No Claude session is running on ${host.name}. Start claude in '
          'tmux or Herdr there, then try again.',
        ),
      ),
    );
    return null;
  }
  if (agents.length == 1 && !alwaysAsk) {
    return agents.single;
  }
  return showAdaptiveModal<AgentInfo>(
    kind: AdaptiveModalKind.dialog,
    context: context,
    useSafeArea: true,
    builder: (context) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          ListTile(
            key: const ValueKey('chat-agent-picker-title'),
            title: Text(title),
          ),
          for (final agent in agents)
            ListTile(
              key: ValueKey('chat-agent-${agent.id}'),
              leading: const Icon(Icons.forum_outlined),
              title: Text(agent.name),
              subtitle: Text(
                [agent.state.label, ?agent.workspace].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => Navigator.of(context).pop(agent),
            ),
        ],
      ),
    ),
  );
}

/// Fires when the attention controller's record of one session changes
/// (state, pending requests, message), so the chat polls at once instead of
/// waiting for its next tick.
class _AgentChangeSignal extends ChangeNotifier {
  _AgentChangeSignal(this._attention, this._hostId, this._agentId) {
    _last = _current();
    _attention.addListener(_check);
  }

  final AgentAttentionController _attention;
  final String _hostId;
  final String _agentId;
  AgentInfo? _last;

  AgentInfo? _current() {
    for (final agent
        in _attention.statusFor(_hostId)?.agents ?? const <AgentInfo>[]) {
      if (agent.id == _agentId) {
        return agent;
      }
    }
    return null;
  }

  void _check() {
    final now = _current();
    if (now != _last) {
      _last = now;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _attention.removeListener(_check);
    super.dispose();
  }
}

/// Checks [host]'s companion while a small progress dialog shows (a
/// direct check is an SSH round trip or two); returns right away when the
/// agent monitor already has the answer.
Future<ChatViewAccess?> checkChatViewAccessWithProgress(
  BuildContext context, {
  required AgentAttentionController attention,
  required SavedHost host,
}) async {
  final companion = CompanionSetupScope.maybeOf(context);
  final check = checkChatViewAccess(
    attention: attention,
    host: host,
    companion: companion,
  );
  if (chatViewAvailable(attention, host)) {
    return check;
  }
  final navigator = Navigator.of(context);
  var open = true;
  unawaited(
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        key: const ValueKey('chat-access-checking'),
        content: Row(
          children: [
            const SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 16),
            Expanded(child: Text('Checking the companion on ${host.name}…')),
          ],
        ),
      ),
    ).whenComplete(() => open = false),
  );
  try {
    return await check;
  } finally {
    if (open && navigator.mounted) navigator.pop();
  }
}

/// The terminal overflow's "Open chat view": asks the companion on [host]
/// (whether or not agent monitoring is on), explains exactly what is
/// missing, else picks the session and opens its chat. [onOpenTerminal]
/// gets the agent whose TUI to show afterwards.
Future<void> openChatViewForHost({
  required BuildContext context,
  required AgentAttentionController? attention,
  required SavedHost host,
  required ValueChanged<AgentInfo> onOpenTerminal,
  DictationController? dictation,
  ChatSessionLocation location = const ChatSessionLocation(),
  Widget Function(BuildContext routeContext)? accessoryBuilder,
  PromptImageAttacher? imageAttacher,
  bool pasteImages = true,
}) async {
  if (attention == null) {
    await showChatViewUnavailable(context, host: host);
    return;
  }
  final access = await checkChatViewAccessWithProgress(
    context,
    attention: attention,
    host: host,
  );
  if (access == null || !context.mounted) {
    return;
  }
  if (!access.ready) {
    await showChatViewUnavailable(context, host: host, access: access);
    return;
  }
  final match = resolveChatAgent(host, access.agents, location: location);
  final agent = match is ChatAgentMatched
      ? match.agent
      : await pickChatAgent(
          context,
          host: host,
          agents: match is ChatAgentAmbiguous && !match.elsewhere
              ? match.candidates
              : access.agents,
        );
  if (agent == null || !context.mounted) {
    return;
  }
  await openChatView(
    context: context,
    attention: attention,
    host: host,
    agent: agent,
    dictation: dictation,
    onOpenTerminal: () => onOpenTerminal(agent),
    accessoryBuilder: accessoryBuilder,
    imageAttacher: imageAttacher,
    pasteImages: pasteImages,
  );
}
