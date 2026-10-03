import 'dart:async';

import 'package:conduit/core/presentation/adaptive_modal.dart';
import 'package:conduit/core/presentation/system_navigation_insets.dart';
import 'package:conduit/core/theme/app_theme.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/hosts/presentation/hosts_controller.dart';
import 'package:conduit/features/live/presentation/live_host_hub.dart';
import 'package:conduit/features/sessions/domain/connect_preferences.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:conduit/features/sessions/presentation/connect_picker_sheet.dart';
import 'package:conduit/features/sessions/presentation/herdr_session_focus.dart';
import 'package:conduit/features/sessions/presentation/tmux_session_focus.dart';
import 'package:conduit/features/terminal/domain/tmux_navigator.dart';
import 'package:conduit/features/terminal/presentation/recent_directories_controller.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Connects a saved host through the connect picker.
///
/// Owns everything the picker needs (a command runner factory for listing,
/// the per-host preferences) so pages only hand it a host. The caller is
/// still responsible for navigating to the terminal afterwards.
class SessionConnectFlow {
  SessionConnectFlow({
    required this.hostsController,
    required this.workspace,
    required this.runnerFactory,
    required this.preferences,
    this.recentDirectories,
    bool watchLifecycle = false,
    bool Function()? mayMoveHerdrFocus,
    Duration? herdrRefreshInterval,
  }) : herdr = HerdrSessionFocus(
         workspace: workspace,
         runnerFactory: runnerFactory,
         watchLifecycle: watchLifecycle,
         mayMoveFocus: mayMoveHerdrFocus,
         refreshInterval: herdrRefreshInterval,
       ),
       tmux = TmuxSessionFocus(
         workspace: workspace,
         runnerFactory: runnerFactory,
       ),
       live = LiveHostHub(runnerFactory: runnerFactory);

  final HostsController hostsController;
  final TerminalWorkspaceController workspace;
  final AgentCommandRunnerFactory runnerFactory;
  final ConnectPreferencesRepository preferences;

  /// Recent working directories per host: the picker's "Recent dirs" and
  /// the terminal's "cd to…". Null hides both.
  final RecentDirectoriesController? recentDirectories;

  /// Herdr focus across the app's sessions: re-focus on tab switch, deep
  /// links, and the command channel behind the Herdr gestures.
  final HerdrSessionFocus herdr;

  /// Deep links to agents running in tmux (the companion's tmux location).
  final TmuxSessionFocus tmux;

  /// Herdr and tmux pushed by each machine's companion (the home board,
  /// tab strips and the navigator read it instead of polling).
  final LiveHostHub live;

  /// The saved machine behind [host]: [host] itself, or the machine of a
  /// session's host (`<machine id>#herdr:w1`, which the agent monitors and
  /// everything listing their agents hand out). Sessions open on, and are
  /// looked up by, the machine: a target applied to a session's host would
  /// derive an id from a derived id, whose workspace no longer parses.
  SavedHost machineOf(SavedHost host) {
    final id = baseHostId(host.id);
    if (id == host.id || host.isLocal) return host;
    return hostsController.findById(id) ?? host.copyWith(id: id);
  }

  /// Opens [host] at an agent's exact place in Herdr (see
  /// [HerdrSessionFocus.openAgentLocation]).
  Future<TerminalSessionController?> openAgentLocation(
    SavedHost host, {
    required String workspaceId,
    String tabId = '',
    String paneId = '',
    String label = '',
  }) async {
    host = machineOf(host);
    // Not awaited: saving the host list must not hold up the terminal.
    unawaited(hostsController.markConnected(host));
    return herdr.openAgentLocation(
      host,
      workspaceId: workspaceId,
      tabId: tabId,
      paneId: paneId,
      label: label,
      open: (target) => open(host, target),
    );
  }

  /// Bumped when a deep link wants the terminal on screen; the home page
  /// listens and opens the terminal workspace if it is not showing.
  final ValueNotifier<int> terminalRequests = ValueNotifier<int>(0);

  /// The session and agent of the last [openAgent] that asked for the
  /// preferred view, until the page showing the terminal takes it.
  ({TerminalSessionController session, AgentInfo agent})? _openedAgent;

  /// What the last [openAgent] with `preferredView` opened, once: the page
  /// that shows the terminal on [terminalRequests] shows it in Chat View
  /// when that is where its session opens.
  ({TerminalSessionController session, AgentInfo agent})? takeOpenedAgent() {
    final opened = _openedAgent;
    _openedAgent = null;
    return opened;
  }

  /// Deep link to [agent] on [host] (a notification, the agent sheet, the
  /// home-screen widget): with a tmux location (the companion reports
  /// `tab` = `session:window`, `pane` = `%N`), the tab attached to that
  /// tmux session with the pane selected; with a Herdr location, the exact
  /// workspace, tab and pane; otherwise the host's open session, if any.
  /// Asks for the terminal to be shown when something was opened; with
  /// [preferredView] (a notification tap), in the session's preferred
  /// view (see [takeOpenedAgent]) rather than always its terminal.
  Future<TerminalSessionController?> openAgent(
    SavedHost host,
    AgentInfo agent, {
    bool preferredView = false,
  }) async {
    host = machineOf(host);
    final workspaceId = agent.workspace ?? '';
    final tmuxLocation = TmuxAgentLocation.parse(
      tab: agent.tab,
      pane: agent.pane,
    );
    TerminalSessionController? session;
    if (tmuxLocation != null && !host.isLocal) {
      unawaited(hostsController.markConnected(host));
      session = await tmux.openAgentLocation(
        host,
        tmuxLocation,
        open: (target) => open(host, target),
      );
    } else if (workspaceId.isNotEmpty && !host.isLocal) {
      session = await openAgentLocation(
        host,
        workspaceId: workspaceId,
        tabId: agent.tab ?? '',
        paneId: agent.pane ?? '',
      );
    } else {
      session = workspace.sessions
          .where((candidate) => baseHostId(candidate.host.id) == host.id)
          .firstOrNull;
      if (session != null) {
        workspace.activate(session);
      }
    }
    if (session != null) {
      _openedAgent = preferredView ? (session: session, agent: agent) : null;
      terminalRequests.value += 1;
    }
    return session;
  }

  void dispose() {
    unawaited(herdr.dispose());
    terminalRequests.dispose();
  }

  /// Target keys with an open session for [host], for the "Active" badges.
  Set<String> activeTargetKeysFor(SavedHost host) => {
    for (final session in workspace.sessions)
      if (baseHostId(session.host.id) == host.id)
        ConnectTarget.keyFromSessionHostId(session.host.id) ?? 'shell',
  };

  /// Opens a session for [host]: straight away when the host remembers a
  /// choice (unless [forcePicker]), otherwise after the picker. Returns
  /// null when the picker was dismissed.
  Future<TerminalSessionController?> connect(
    BuildContext context,
    SavedHost host, {
    bool forcePicker = false,
  }) async {
    unawaited(hostsController.markConnected(host));
    if (host.isLocal) {
      return workspace.open(host);
    }
    final saved = await preferences.load(host.id);
    final directories =
        await recentDirectories?.load(host.id) ?? const <String>[];
    if (!context.mounted) {
      return null;
    }
    ConnectPickerResult? result;
    final remembered = saved.lastTarget;
    if (!forcePicker && saved.rememberChoice && remembered != null) {
      result = ConnectPickerResult(target: remembered, remember: true);
    } else {
      final runner = runnerFactory(host);
      try {
        result = await showConnectPicker(
          context: context,
          host: host,
          runner: runner,
          preferences: saved,
          activeTargetKeys: activeTargetKeysFor(host),
          initialTab: remembered?.kind == ConnectTargetKind.herdr
              ? ConnectPickerTab.herdr
              : ConnectPickerTab.tmux,
          recentDirectories: directories,
          mayMoveHerdrFocus: herdr.mayMoveFocus,
        );
      } finally {
        unawaited(runner.close());
      }
    }
    if (result == null) {
      return null;
    }
    unawaited(
      preferences.save(
        host.id,
        saved.withChoice(result.target, remember: result.remember),
      ),
    );
    return open(host, result.target);
  }

  /// Opens (or activates) the session for [target] on [host] without any
  /// UI.
  TerminalSessionController open(SavedHost host, ConnectTarget target) {
    return workspace.open(
      target.apply(machineOf(host)),
      startupCommand: target.startupCommand,
      target: target,
    );
  }

  /// Lets the user choose a saved machine, then runs [connect] for it.
  Future<TerminalSessionController?> pickHostAndConnect(
    BuildContext context,
  ) async {
    final host = await showAdaptiveModal<SavedHost>(
      kind: AdaptiveModalKind.dialog,
      context: context,
      useSafeArea: true,
      builder: (context) => AnnotatedRegion<SystemUiOverlayStyle>(
        value: AppTheme.systemUiOverlayStyle(Theme.of(context).brightness),
        child: HostChooser(hostsController: hostsController),
      ),
    );
    if (host == null || !context.mounted) {
      return null;
    }
    return connect(context, host);
  }
}

/// The "New session" machine list. On desktop a filter field sits on top
/// (the dialog focuses it) and Enter picks the first match.
@visibleForTesting
class HostChooser extends StatefulWidget {
  const HostChooser({required this.hostsController, super.key});

  final HostsController hostsController;

  @override
  State<HostChooser> createState() => _HostChooserState();
}

class _HostChooserState extends State<HostChooser> {
  String _query = '';

  bool _matches(SavedHost host) {
    final query = _query.trim().toLowerCase();
    return query.isEmpty ||
        host.name.toLowerCase().contains(query) ||
        host.endpoint.toLowerCase().contains(query);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final desktop = useDesktopModals(context);
    final bottomInset = shouldApplyBottomSafeArea(context)
        ? MediaQuery.viewPaddingOf(context).bottom
        : 0.0;
    return ListenableBuilder(
      listenable: widget.hostsController,
      builder: (context, _) {
        final machines = widget.hostsController.sortedMachines
            .where((host) => !host.isLocal)
            .toList();
        final hosts = machines.where(_matches).toList();
        return ListView(
          shrinkWrap: true,
          padding: EdgeInsets.fromLTRB(8, 12, 8, 16 + bottomInset),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Text('New session', style: theme.textTheme.titleMedium),
            ),
            if (desktop && machines.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: TextField(
                  key: const ValueKey('host-chooser-filter'),
                  decoration: const InputDecoration(
                    isDense: true,
                    prefixIcon: Icon(Icons.search_rounded, size: 18),
                    hintText: 'Filter machines',
                  ),
                  textInputAction: TextInputAction.go,
                  onChanged: (value) => setState(() => _query = value),
                  onSubmitted: (_) {
                    if (hosts.isEmpty) return;
                    Navigator.of(context).pop(hosts.first);
                  },
                ),
              ),
            if (machines.isEmpty)
              Padding(
                padding: const EdgeInsets.all(20),
                child: Text(
                  'No saved machines yet. Add one on the home page first.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              )
            else
              for (final host in hosts)
                ListTile(
                  leading: Icon(
                    host.isThisComputer
                        ? Icons.computer_rounded
                        : Icons.dns_rounded,
                  ),
                  title: Text(
                    host.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    host.endpoint,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontFamily: 'monospace'),
                  ),
                  onTap: () => Navigator.of(context).pop(host),
                ),
          ],
        );
      },
    );
  }
}
