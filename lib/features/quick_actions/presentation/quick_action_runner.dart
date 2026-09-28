import 'dart:async';

import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/chat_view/data/conductore_chat_client.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/quick_actions/domain/quick_action.dart';
import 'package:conduit/features/quick_actions/domain/quick_action_plan.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:url_launcher/url_launcher.dart';

/// Where a quick action runs: the project's machine and repo, and its
/// agent for prompts.
class QuickActionContext {
  const QuickActionContext({
    required this.machine,
    this.root,
    this.agent,
    this.agentHost,
  });

  final SavedHost machine;

  /// The repo's folder on [machine], when known.
  final String? root;

  /// The agent a prompt goes to, and the monitored host it runs on.
  final AgentInfo? agent;
  final SavedHost? agentHost;
}

/// Runs quick actions: shell commands in a terminal, prompts to the
/// project's agent through the companion, URLs in the browser. Returns a
/// line to show the user.
class QuickActionRunner {
  QuickActionRunner({
    required this.workspace,
    this.attention,
    Future<bool> Function(Uri uri)? openUrl,
    Future<void> Function(SavedHost host, String sessionId, String text)?
    sendPrompt,
    this.connectTimeout = const Duration(seconds: 30),
  }) : _openUrl = openUrl ?? _launch,
       _sendPrompt = sendPrompt; // ignore: prefer_initializing_formals

  final TerminalWorkspaceController workspace;
  final AgentAttentionController? attention;
  final Future<bool> Function(Uri uri) _openUrl;
  final Future<void> Function(SavedHost host, String sessionId, String text)?
  _sendPrompt;
  final Duration connectTimeout;

  static Future<bool> _launch(Uri uri) =>
      launchUrl(uri, mode: LaunchMode.externalApplication);

  Future<String> run(QuickAction action, QuickActionContext context) async {
    switch (planQuickAction(action, root: context.root)) {
      case InvalidPlan(:final reason):
        throw StateError(reason);
      case OpenUrlPlan(:final uri):
        if (!await _openUrl(uri)) throw StateError('Could not open $uri.');
        return 'Opened ${uri.host}';
      case SendPromptPlan(:final text):
        final agent = context.agent;
        final host = context.agentHost;
        if (agent == null || host == null) {
          throw StateError('No agent is working in this project.');
        }
        await _send(host, agent.id, text);
        return 'Sent "${action.label}" to ${agent.name}';
      case RunInTerminalPlan(
        :final command,
        :final directory,
        :final terminalName,
      ):
        final session = await _runInTerminal(
          context.machine,
          command: command,
          directory: directory,
          name: terminalName?.trim().isNotEmpty ?? false
              ? terminalName!.trim()
              : action.label,
        );
        return 'Running "${action.label}" in ${session.title}';
    }
  }

  Future<void> _send(SavedHost host, String sessionId, String text) async {
    final custom = _sendPrompt;
    if (custom != null) return custom(host, sessionId, text);
    final attention = this.attention;
    if (attention == null) throw StateError('The agent monitor is off.');
    final (runner, :owned) = attention.runnerFor(host);
    try {
      await ConductoreChatClient(runner).send(sessionId, text);
    } finally {
      if (owned) unawaited(runner.close());
    }
  }

  /// The terminal named [name] on [machine] when it is open (the command
  /// is typed into it), else a new terminal at [directory] that runs the
  /// command once it connects.
  Future<TerminalSessionController> _runInTerminal(
    SavedHost machine, {
    required String command,
    required String? directory,
    required String name,
  }) async {
    final named = workspace.sessions
        .where(
          (session) =>
              baseHostId(session.host.id) == machine.id &&
              session.customTitle == name,
        )
        .firstOrNull;
    if (named != null) {
      workspace.activate(named);
      await _whenConnected(named);
      await named.sendAppText(command, submit: true);
      return named;
    }
    final target = directory == null
        ? const ConnectTarget.shell()
        : ConnectTarget.directory(directory);
    final before = workspace.sessions.toSet();
    final startup = [?target.startupCommand, command].join(' && ');
    final session = workspace.open(
      target.apply(machine),
      startupCommand: startup,
      target: target,
    );
    if (session.customTitle == null) session.rename(name);
    // A terminal already open at that folder: type the command into it.
    if (before.contains(session)) {
      await _whenConnected(session);
      await session.sendAppText(command, submit: true);
    }
    return session;
  }

  Future<void> _whenConnected(TerminalSessionController session) {
    if (session.isConnected) return Future.value();
    final done = Completer<void>();
    void listener() {
      if (session.isConnected && !done.isCompleted) done.complete();
    }

    session.addListener(listener);
    return done.future
        .timeout(
          connectTimeout,
          onTimeout: () =>
              throw StateError('${session.title} did not connect in time.'),
        )
        .whenComplete(() => session.removeListener(listener));
  }
}
