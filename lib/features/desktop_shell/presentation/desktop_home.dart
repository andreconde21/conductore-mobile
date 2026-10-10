import 'dart:async';

import 'package:conduit/core/platform_features.dart';
import 'package:conduit/core/presentation/adaptive_modal.dart';
import 'package:conduit/core/presentation/desktop_window.dart';
import 'package:conduit/core/telemetry/telemetry.dart';
import 'package:conduit/core/telemetry/telemetry_events.dart';
import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/core/theme/terminal_appearance.dart';
import 'package:conduit/core/theme/theme_controller.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/agent_attention/presentation/widgets/agents_icon.dart';
import 'package:conduit/features/agents_digest/presentation/agents_dashboard.dart';
import 'package:conduit/features/agents_digest/presentation/digest_controller.dart';
import 'package:conduit/features/command_palette/domain/palette_entry.dart';
import 'package:conduit/features/command_palette/presentation/command_palette.dart';
import 'package:conduit/features/companion_setup/presentation/companion_setup_page.dart';
import 'package:conduit/features/continuity/domain/continuity_record.dart';
import 'package:conduit/features/continuity/presentation/continuity_controller.dart';
import 'package:conduit/features/continuity/presentation/continuity_places.dart';
import 'package:conduit/features/continuity/presentation/continuity_scope.dart';
import 'package:conduit/features/continuity/presentation/continuity_widgets.dart';
import 'package:conduit/features/desktop_shell/domain/layout_presets.dart';
import 'package:conduit/features/desktop_shell/domain/project_tree.dart';
import 'package:conduit/features/desktop_shell/domain/shell_layout.dart';
import 'package:conduit/features/desktop_shell/domain/sidebar_prefs.dart';
import 'package:conduit/features/desktop_shell/domain/sidebar_tree.dart';
import 'package:conduit/features/desktop_shell/presentation/desktop_shell_controller.dart';
import 'package:conduit/features/desktop_shell/presentation/project_layout_controller.dart';
import 'package:conduit/features/desktop_shell/presentation/shell_palette.dart';
import 'package:conduit/features/desktop_shell/presentation/terminal_shell_embedding.dart';
import 'package:conduit/features/desktop_shell/presentation/widgets/layout_picker.dart';
import 'package:conduit/features/desktop_shell/presentation/widgets/project_sidebar.dart';
import 'package:conduit/features/desktop_shell/presentation/widgets/project_view.dart';
import 'package:conduit/features/desktop_shell/presentation/widgets/shell_dashboard.dart';
import 'package:conduit/features/desktop_shell/presentation/widgets/shell_sidebar.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/hosts/presentation/home_board_controller.dart';
import 'package:conduit/features/hosts/presentation/hosts_controller.dart';
import 'package:conduit/features/hosts/presentation/widgets/home_session_grid.dart';
import 'package:conduit/features/hosts/presentation/widgets/machine_switcher.dart';
import 'package:conduit/features/live_preview/presentation/live_preview_view.dart';
import 'package:conduit/features/quick_actions/domain/quick_action.dart';
import 'package:conduit/features/quick_actions/domain/quick_action_plan.dart';
import 'package:conduit/features/quick_actions/presentation/project_files_controller.dart';
import 'package:conduit/features/quick_actions/presentation/quick_action_form.dart';
import 'package:conduit/features/quick_actions/presentation/quick_action_runner.dart';
import 'package:conduit/features/session_navigation/presentation/quick_switcher_actions.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:conduit/features/sessions/presentation/live_terminal_preview.dart';
import 'package:conduit/features/sessions/presentation/session_connect_flow.dart';
import 'package:conduit/features/sessions/presentation/session_grid_page.dart'
    show summarizeAgentState;
import 'package:conduit/features/sessions/presentation/session_restore_controller.dart';
import 'package:conduit/features/settings/presentation/privacy_notice.dart';
import 'package:conduit/features/settings/presentation/settings_catalog.dart';
import 'package:conduit/features/terminal/presentation/desktop_shortcuts.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:conduit/features/terminal/presentation/widgets/desktop_shortcuts_sheet.dart';
import 'package:conduit/features/usage/presentation/usage_explorer_view.dart';
import 'package:conduit/features/usage/presentation/usage_widgets.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

part 'shell_projects.dart';

/// Whether a window of [size] gets the desktop shell: desktops always,
/// and tablets at least 900 dp wide. Phones (in landscape too) and
/// narrower tablets keep the phone home.
bool usesDesktopShell(Size size) =>
    PlatformFeatures.isDesktop ||
    (size.width >= 900 && size.shortestSide >= 600);

/// Builds the usage summary: [compact] for the sidebar footer, else the
/// dashboard's card.
typedef UsageSummaryBuilder =
    Widget Function(BuildContext context, {required bool compact});

/// What the desktop home asks the home page to do (the page owns the
/// connect flow, the machine forms and the dialogs).
class DesktopHomeActions {
  const DesktopHomeActions({
    required this.openTarget,
    required this.newSession,
    required this.openSwitcher,
    required this.openSettings,
    required this.addMachine,
    required this.machineMenu,
    required this.openSession,
    required this.sessionActions,
    required this.noticeAction,
    required this.openChat,
    this.lock,
    this.openSettingsAt,
    this.continueFrom,
  });

  /// Opens another device's place here (the palette's "Continue from…");
  /// null hides continuity.
  final Future<void> Function(ContinuityContext context)? continueFrom;

  /// Settings at a section (the command palette); null opens Settings.
  final Future<void> Function(SettingsSection section)? openSettingsAt;

  /// Opens what a sidebar row stands for (a workspace, tab, pane, tmux
  /// session or window, an open session).
  final Future<void> Function(SidebarTarget target) openTarget;
  final Future<void> Function() newSession;
  final Future<void> Function() openSwitcher;
  final Future<void> Function() openSettings;
  final Future<void> Function() addMachine;
  final Future<void> Function(MachineMenuChoice choice, SavedHost host)
  machineMenu;

  /// A session tile: activate it (Chat View when that is its view).
  final void Function(TerminalSessionController session) openSession;
  final Future<void> Function(TerminalSessionController session) sessionActions;
  final void Function(SavedHost host, HomeBoardNoticeAction action)
  noticeAction;
  final Future<void> Function(SavedHost host, AgentInfo agent) openChat;

  /// Locks the app; null where there is no app lock (Linux).
  final Future<void> Function()? lock;
}

/// The desktop shell: the sidebar, the main area (the embedded terminal
/// page with its tabs and splits, or the dashboard) and the optional right
/// panel. See docs/desktop.md.
class DesktopHome extends StatefulWidget {
  const DesktopHome({
    required this.controller,
    required this.hostsController,
    required this.workspace,
    required this.agentAttention,
    required this.themeController,
    required this.actions,
    required this.terminalBuilder,
    this.boards,
    this.connectFlow,
    this.sessionRestore,
    this.usageSummary,
    this.projectLayout,
    this.previewRefreshInterval = const Duration(seconds: 2),
    super.key,
  });

  final DesktopShellController controller;
  final HostsController hostsController;
  final TerminalWorkspaceController workspace;
  final AgentAttentionController agentAttention;
  final ThemeController themeController;
  final DesktopHomeActions actions;

  /// The terminal page, embedded (see [TerminalShellEmbedding]).
  final Widget Function(TerminalShellEmbedding embedding) terminalBuilder;
  final HomeBoards? boards;
  final SessionConnectFlow? connectFlow;
  final SessionRestoreController? sessionRestore;

  /// The usage summary for the dashboard and the sidebar footer; null
  /// keeps the slot empty (the usage feature fills it).
  final UsageSummaryBuilder? usageSummary;

  /// The project view's layout (CON-065); null uses the app's
  /// ([ProjectLayoutController.instance]), and without one the Projects
  /// tab groups by what agents report, as before.
  final ProjectLayoutController? projectLayout;

  /// How often the dashboard's live previews redraw while it is shown.
  final Duration previewRefreshInterval;

  @override
  State<DesktopHome> createState() => DesktopHomeState();
}

class DesktopHomeState extends State<DesktopHome> {
  late final TerminalShellEmbedding embedding = TerminalShellEmbedding(
    controller: widget.controller,
    onShowHome: () => widget.controller.showHome = true,
    isVisible: () => terminalVisible,
    badgeFor: _badgeFor,
    onFullscreenChanged: (value) {
      if (mounted) setState(() => _fullscreen = value);
    },
    onViewsChanged: _handleViewsChanged,
    headerActions: () => [
      ..._quickActionButtons(),
      _layoutPicker(),
      _previewToggle(),
    ],
    keepKey: (event) => _quickActionForKey(event) != null,
    onToggleAgents: () =>
        widget.controller.toggleRightPanel(ShellRightPanel.agents),
    onOpenPalette: () => unawaited(openPalette()),
    onDropNode: (paneId, edge, drag) =>
        unawaited(dropNode(paneId, edge, drag.node)),
    onFillPane: (paneId) {
      _focusPane(paneId);
      unawaited(openPalette(initial: '#'));
    },
  );

  List<SidebarNode> _tree = const [];
  final _panelFocus = FocusNode(debugLabel: 'shell-right-panel');

  /// The machine tree grouped by project (the Projects tab).
  List<ProjectGroup> _projects = const [];

  /// Each project's icon and `.code-workspace` quick actions.
  late final ProjectFilesController _projectFiles = ProjectFilesController(
    runnerFor: widget.agentAttention.runnerFor,
    hostFor: widget.hostsController.findById,
  )..addListener(_handleProjectFilesChanged);
  late final QuickActionRunner _quickActions = QuickActionRunner(
    workspace: widget.workspace,
    attention: widget.agentAttention,
  );

  void _handleProjectFilesChanged() {
    if (mounted) setState(() {});
  }

  /// A quick action's keys, for the focused project.
  bool _handleQuickActionKey(KeyEvent event) {
    if (!mounted || !(_route?.isCurrent ?? true)) return false;
    final match = _quickActionForKey(event);
    if (match == null) return false;
    unawaited(_runQuickAction(match.$1, match.$2));
    return true;
  }

  Set<String> _unreadKeys = const {};
  bool _fullscreen = false;
  bool _appResumed = true;
  ModalRoute<Object?>? _route;
  Timer? _previewTimer;
  final _previewTicks = ValueNotifier<int>(0);
  Timer? _feedTimer;
  AppLifecycleListener? _lifecycle;

  /// When each open session last printed something (not right after it
  /// connected: a reattach redraws the whole screen). The terminal model
  /// notifies on every write.
  final Map<TerminalSessionController, int> _outputAt = {};
  final Map<TerminalSessionController, VoidCallback> _paintListeners = {};

  /// Each session's terminal size when it last changed: a resize redraws
  /// without news (a pane moving offstage, a split).
  final Map<TerminalSessionController, (int, int)> _sizes = {};
  final Map<TerminalSessionController, DateTime> _connectedAt = {};
  final Map<TerminalSessionController, TerminalConnectionStatus> _status = {};

  late final _shortcuts = DesktopShortcutHandler(
    onShortcut: _handleShortcut,
    isActive: () => mounted && (_route?.isCurrent ?? true),
  );

  DesktopShellController get _controller => widget.controller;

  /// The sidebar's tree, as last built.
  List<SidebarNode> get tree => _tree;

  bool get _hasViews =>
      widget.workspace.hasSessions ||
      (embedding.host?.viewIds.isNotEmpty ?? false);

  /// Whether the main area shows the terminal page (else the dashboard or
  /// the usage explorer).
  bool get terminalVisible =>
      _hasViews && !_controller.showHome && !_controller.showUsage;

  @override
  void initState() {
    super.initState();
    unawaited(_controller.load());
    widget.hostsController.addListener(_rebuildTree);
    widget.workspace.addListener(_handleWorkspaceChanged);
    widget.agentAttention.addListener(_rebuildTree);
    widget.boards?.addListener(_rebuildTree);
    _projectLayout?.addListener(_rebuildTree);
    _controller.addListener(_handleControllerChanged);
    _controller.layout.addListener(_syncViewed);
    _controller.layout.addListener(_reportContinuity);
    // The saved machine that is this desktop may be found after start.
    widget.hostsController.addListener(_reportContinuity);
    _controller.unreadChanges.addListener(_handleUnreadChanged);
    widget.sessionRestore?.addListener(_handleRestoreChanged);
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        final resumed = state == AppLifecycleState.resumed;
        if (!resumed) unawaited(_controller.flush());
        if (resumed == _appResumed) return;
        _appResumed = resumed;
        _syncViewed();
        _syncPreviewTimer();
      },
    );
    _shortcuts.attach();
    if (PlatformFeatures.isDesktop) {
      HardwareKeyboard.instance.addHandler(_handleQuickActionKey);
    }
    _watchSessions();
    _rebuildTree();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
    final continuity = ContinuityScope.maybeOf(context);
    if (!identical(continuity, _continuity)) {
      _continuity = continuity?..desktopShell = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _reportContinuity());
    }
  }

  // Continuity: the focused view is where this desktop is.

  ContinuityController? _continuity;

  /// Tells continuity the focused session or Chat View tab, and the
  /// layout's name. The dashboard leaves the last place as it is.
  void _reportContinuity() {
    final continuity = _continuity;
    final host = embedding.host;
    if (continuity == null || !mounted || host == null) return;
    final views = host.viewIds.toSet();
    final current = _controller.layout.value.pruned(views);
    final shown = [
      for (final pane in current.panes)
        if (pane.view != null) pane.view!,
    ];
    final preset = ShellLayoutPreset.of(current);
    final saved = _controller.savedLayouts
        .where((saved) => listEquals(saved.views, shown))
        .firstOrNull;
    final layout =
        saved?.name ??
        (preset == null || preset == ShellLayoutPreset.single
            ? ''
            : preset.label);
    final viewId = host.activeViewId;
    final place = !terminalVisible || viewId == null
        ? null
        : placeForShellView(
            viewId,
            workspace: widget.workspace,
            attention: widget.agentAttention,
            hosts: widget.hostsController,
            herdrWorkspaceOf: widget.connectFlow?.herdr.workspaceOf,
          );
    if (place != null) {
      continuity.reportPlace(place, layout: layout);
    } else {
      continuity.reportLayout(layout);
    }
  }

  @override
  void didUpdateWidget(covariant DesktopHome oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.boards != widget.boards) {
      oldWidget.boards?.removeListener(_rebuildTree);
      widget.boards?.addListener(_rebuildTree);
      _rebuildTree();
    }
    final oldLayout =
        oldWidget.projectLayout ?? ProjectLayoutController.instance;
    if (oldLayout != _projectLayout) {
      oldLayout?.removeListener(_rebuildTree);
      _projectLayout?.addListener(_rebuildTree);
      _rebuildTree();
    }
  }

  @override
  void dispose() {
    _shortcuts.detach();
    HardwareKeyboard.instance.removeHandler(_handleQuickActionKey);
    _projectFiles.dispose();
    _panelFocus.dispose();
    widget.hostsController.removeListener(_rebuildTree);
    widget.workspace.removeListener(_handleWorkspaceChanged);
    widget.agentAttention.removeListener(_rebuildTree);
    widget.boards?.removeListener(_rebuildTree);
    _projectLayout?.removeListener(_rebuildTree);
    _controller.removeListener(_handleControllerChanged);
    _controller.layout.removeListener(_syncViewed);
    _controller.layout.removeListener(_reportContinuity);
    widget.hostsController.removeListener(_reportContinuity);
    _controller.unreadChanges.removeListener(_handleUnreadChanged);
    widget.sessionRestore?.removeListener(_handleRestoreChanged);
    _lifecycle?.dispose();
    _previewTimer?.cancel();
    _previewTicks.dispose();
    _feedTimer?.cancel();
    for (final MapEntry(key: session, value: listener)
        in _paintListeners.entries) {
      session.terminal.removeListener(listener);
      session.removeListener(_handleSessionChanged);
    }
    _paintListeners.clear();
    super.dispose();
  }

  void _handleRestoreChanged() {
    if (mounted) setState(() {});
  }

  /// The screen last counted: the dashboard (home) or the terminal.
  TelemetryScreen _screen = TelemetryScreen.home;

  /// Counts a screen view when the main area switches between the
  /// dashboard and the terminal (the embedded terminal page is mounted all
  /// along, so its own start does not count).
  void _trackScreen() {
    final screen = terminalVisible
        ? TelemetryScreen.terminal
        : TelemetryScreen.home;
    if (screen == _screen) return;
    _screen = screen;
    Telemetry.instance.screen(screen);
  }

  /// The window's title follows the focused view.
  void _syncWindowTitle() {
    if (!mounted) return;
    String? label;
    if (terminalVisible) {
      final session = embedding.host?.focusedSession;
      label = session?.title;
      if (session != null) {
        final machine = widget.hostsController
            .findById(baseHostId(session.host.id))
            ?.name;
        if (machine != null && machine.isNotEmpty && label != machine) {
          label = '$label · $machine';
        }
      }
    } else if (_controller.showUsage) {
      label = 'Usage';
    }
    unawaited(DesktopWindow.setTitle(desktopWindowTitle(label)));
  }

  void _handleControllerChanged() {
    _reportContinuity();
    _syncWindowTitle();
    _trackScreen();
    _syncViewed();
    _syncPreviewTimer();
    _rebuildTree();
  }

  void _handleUnreadChanged() {
    if (!mounted) return;
    setState(() => _unreadKeys = _controller.unread.unreadKeys);
  }

  void _handleViewsChanged() {
    if (!mounted) return;
    _reportContinuity();
    _syncWindowTitle();
    _trackScreen();
    _syncViewed();
    _syncPreviewTimer();
    setState(() {});
  }

  void _handleWorkspaceChanged() {
    _reportContinuity();
    _syncWindowTitle();
    _trackScreen();
    _watchSessions();
    _syncViewed();
    _syncPreviewTimer();
    _rebuildTree();
  }

  // Terminal output as unread activity.

  void _watchSessions() {
    final sessions = widget.workspace.sessions.toSet();
    for (final session in List.of(_paintListeners.keys)) {
      if (sessions.contains(session)) continue;
      session.terminal.removeListener(_paintListeners.remove(session)!);
      session.removeListener(_handleSessionChanged);
      _outputAt.remove(session);
      _sizes.remove(session);
      _connectedAt.remove(session);
      _status.remove(session);
    }
    for (final session in sessions) {
      if (_paintListeners.containsKey(session)) continue;
      void listener() => _noteOutput(session);
      _paintListeners[session] = listener;
      _status[session] = session.status;
      if (session.isConnected) _connectedAt[session] = _controller.now();
      _sizes[session] = _sizeOf(session);
      session.terminal.addListener(listener);
      session.addListener(_handleSessionChanged);
    }
  }

  void _handleSessionChanged() {
    _syncWindowTitle();
    for (final session in _paintListeners.keys) {
      final status = session.status;
      if (_status[session] == status) continue;
      _status[session] = status;
      if (status == TerminalConnectionStatus.connected) {
        _connectedAt[session] = _controller.now();
      }
    }
  }

  /// A reconnect or reattach repaints the whole screen: not news.
  static const _settleAfterConnect = Duration(seconds: 4);

  static (int, int) _sizeOf(TerminalSessionController session) =>
      (session.terminal.viewWidth, session.terminal.viewHeight);

  void _noteOutput(TerminalSessionController session) {
    final size = _sizeOf(session);
    if (_sizes[session] != size) {
      _sizes[session] = size;
      return;
    }
    final connected = _connectedAt[session];
    final now = _controller.now();
    if (connected == null || now.difference(connected) < _settleAfterConnect) {
      return;
    }
    _outputAt[session] = now.millisecondsSinceEpoch;
    _feedTimer ??= Timer(const Duration(milliseconds: 400), () {
      _feedTimer = null;
      if (mounted) _feedUnread();
    });
  }

  /// The sidebar row that stands for [session].
  String keyForSession(TerminalSessionController session) {
    final machineId = baseHostId(session.host.id);
    final target = ConnectTarget.fromSessionHostId(session.host.id);
    if (target?.kind == ConnectTargetKind.herdr) {
      final workspaceId =
          widget.connectFlow?.herdr.workspaceOf(session) ?? target!.name;
      if (workspaceId.isNotEmpty &&
          SidebarTreeBuilder.find(
                _tree,
                SidebarKeys.herdrWorkspace(machineId, workspaceId),
              ) !=
              null) {
        return SidebarKeys.herdrWorkspace(machineId, workspaceId);
      }
    }
    final tmux = HomeSessionInfo.tmuxSessionOf(session);
    if (tmux != null &&
        SidebarTreeBuilder.find(
              _tree,
              SidebarKeys.tmuxSession(machineId, tmux),
            ) !=
            null) {
      return SidebarKeys.tmuxSession(machineId, tmux);
    }
    return SidebarKeys.openSession(machineId, session.host.id);
  }

  TerminalSessionController? _sessionForView(String viewId) => widget
      .workspace
      .sessions
      .where((session) => sessionViewId(session) == viewId)
      .firstOrNull;

  // The tree and the unread markers.

  List<SidebarMachineInput> _inputs() {
    final sessions = widget.workspace.sessions;
    final attention = widget.agentAttention;
    return [
      for (final host in widget.hostsController.sortedMachines)
        if (!host.isLocal)
          () {
            final own = [
              for (final session in sessions)
                if (baseHostId(session.host.id) == host.id) session,
            ];
            final agents = <String, AgentInfo>{};
            for (final monitored in attention.monitoredHosts) {
              if (baseHostId(monitored.id) != host.id) continue;
              for (final agent
                  in attention.statusFor(monitored.id)?.agents ??
                      const <AgentInfo>[]) {
                agents[agent.id] = agent;
              }
            }
            final board = widget.boards?[host.id];
            return SidebarMachineInput(
              host: host,
              board: board?.state,
              openSessions: [
                for (final session in own)
                  () {
                    final target = ConnectTarget.fromSessionHostId(
                      session.host.id,
                    );
                    final herdr = target?.kind == ConnectTargetKind.herdr
                        ? (widget.connectFlow?.herdr.workspaceOf(session) ??
                              target!.name)
                        : null;
                    return SidebarOpenSession(
                      sessionHostId: session.host.id,
                      title: session.title,
                      herdrWorkspaceId: herdr,
                      tmuxSession: HomeSessionInfo.tmuxSessionOf(session),
                      agentState: summarizeAgentState(
                        attention.statusFor(session.host.id),
                        session.host.id,
                      ),
                    );
                  }(),
              ],
              agents: agents.values.toList(),
              tmuxWindows: _controller.tmuxWindowsOf(host.id),
              status: _statusLine(board),
            );
          }(),
    ];
  }

  static String _statusLine(HomeBoardController? board) {
    if (board == null) return '';
    final state = board.state;
    return switch (state.phase) {
      HomeBoardPhase.awaitingRequest =>
        board.requestReason == HomeBoardRequestReason.hardwareKey
            ? 'Security key: open to list'
            : 'Not connected yet',
      HomeBoardPhase.loading => 'Listing…',
      // The phone notice's words ("Can't reach …").
      HomeBoardPhase.failed
          when state.workspaces.isEmpty && state.tmuxSessions.isEmpty =>
        state.problem?.title ?? 'Could not list',
      _ => '',
    };
  }

  /// Each listed tmux session's activity when its windows were listed.
  final Map<String, DateTime?> _windowsListedAt = {};

  void _rebuildTree() {
    if (!mounted) return;
    final self = widget.hostsController.hiddenSelfMachine;
    _controller.machineAlias = self == null
        ? null
        : (from: self.id, to: thisComputerHostId);
    _tree = SidebarTreeBuilder.build(_inputs(), _controller.prefs);
    _projects = _buildProjects();
    _refreshListedWindows();
    _feedUnread();
    setState(() => _unreadKeys = _controller.unread.unreadKeys);
  }

  /// A tmux session whose windows are listed and that had output since:
  /// list them again, so each window's activity (and unread mark) follows.
  void _refreshListedWindows() {
    for (final machine in _tree) {
      for (final node in machine.children) {
        final target = node.target;
        if (target is! TmuxSessionTarget) continue;
        final name = target.session.name;
        if (_controller.tmuxWindowsFor(node.machineId, name) == null) continue;
        final key = node.key;
        final activity = target.session.lastActivity;
        if (!_windowsListedAt.containsKey(key)) {
          _windowsListedAt[key] = activity;
          continue;
        }
        if (_windowsListedAt[key] == activity) continue;
        _windowsListedAt[key] = activity;
        _expand(node);
      }
    }
  }

  void _feedUnread() {
    final tree = _tree;
    _controller.updateUnread((tracker) {
      var changed = false;
      for (final machine in tree) {
        for (final node in machine.descendantsAndSelf.skip(1)) {
          final target = node.target;
          if (target is TmuxWindowTarget) {
            final activity = target.window.activity;
            if (activity != null) {
              changed =
                  tracker.observe(node.key, activity.millisecondsSinceEpoch) ||
                  changed;
            }
          }
          if (target is TmuxSessionTarget) {
            final activity = target.session.lastActivity;
            if (activity != null) {
              changed =
                  tracker.observe(node.key, activity.millisecondsSinceEpoch) ||
                  changed;
            }
          }
          // Agent states count on the deepest rows, so one agent finishing
          // is one unread row (rolled up to its parents).
          if (node.children.isEmpty &&
              node.dot != SidebarDot.none &&
              node.kind != SidebarNodeKind.openSession) {
            changed =
                tracker.observeState(
                  node.key,
                  node.dot.name,
                  news:
                      node.dot == SidebarDot.done ||
                      node.dot == SidebarDot.needsYou ||
                      node.dot == SidebarDot.idle,
                ) ||
                changed;
          }
        }
      }
      for (final MapEntry(key: session, value: at) in _outputAt.entries) {
        changed = tracker.observe(keyForSession(session), at) || changed;
      }
      return changed;
    });
  }

  /// The rows on screen: every view in a pane, while the terminal shows
  /// and the app is in front.
  void _syncViewed() {
    if (!mounted) return;
    final host = embedding.host;
    if (!_appResumed || !terminalVisible || host == null) {
      _controller.setViewed(const {});
      return;
    }
    final views = host.viewIds.toSet();
    final visible = _controller.layout.value.pruned(views).visibleViews;
    _controller.setViewed({
      for (final viewId in visible)
        if (_sessionForView(viewId) case final session?) keyForSession(session),
    });
  }

  ShellTabBadge _badgeFor(String viewId) {
    final session = _sessionForView(viewId);
    if (session == null) return const ShellTabBadge();
    final key = keyForSession(session);
    final node = SidebarTreeBuilder.find(_tree, key);
    final dot =
        node?.dot ??
        SidebarDot.of(
          summarizeAgentState(
            widget.agentAttention.statusFor(session.host.id),
            session.host.id,
          ),
        );
    return ShellTabBadge(
      dot: dot,
      unread: _unreadKeys.any((unread) => SidebarKeys.isUnder(unread, key)),
    );
  }

  /// The row of the focused view.
  String? get _selectedKey {
    if (!terminalVisible) return null;
    final session = embedding.host?.focusedSession;
    return session == null ? null : keyForSession(session);
  }

  void _syncPreviewTimer() {
    final dashboard = !terminalVisible && !_controller.showUsage && _appResumed;
    if (dashboard && widget.workspace.hasSessions) {
      // Tiles redraw their own previews on a tick, only after output
      // (see TerminalSnapshotBuilder); the shell itself does not rebuild.
      _previewTimer ??= Timer.periodic(widget.previewRefreshInterval, (_) {
        if (mounted) _previewTicks.value += 1;
      });
    } else {
      _previewTimer?.cancel();
      _previewTimer = null;
    }
  }

  // Opening rows.

  Future<void> open(SidebarNode node) async {
    if (node.target is MachineTarget) {
      if (!_controller.isExpanded(node)) _expand(node);
      _controller.toggleExpanded(node);
      return;
    }
    _controller.markRead(node.key);
    await widget.actions.openTarget(node.target);
  }

  void _expand(SidebarNode node) {
    final target = node.target;
    if (target is! TmuxSessionTarget) return;
    final board = widget.boards?[node.machineId];
    if (board == null) return;
    unawaited(
      _controller.loadTmuxWindows(
        node.machineId,
        target.session.name,
        () => board.listTmuxWindows(target.session.name),
      ),
    );
  }

  /// Ctrl+Shift+U: the next unread row after the focused one (wrapping),
  /// opened, with its parents expanded.
  bool openNextUnread() {
    final rows = [
      for (final machine in _tree)
        for (final node in machine.descendantsAndSelf)
          if (node.kind != SidebarNodeKind.machine) node,
    ];
    final unread = [
      for (final node in rows)
        if (_unreadKeys.contains(node.key)) node,
    ];
    if (unread.isEmpty) return false;
    final selected = _selectedKey;
    final from = selected == null
        ? -1
        : rows.indexWhere((node) => node.key == selected);
    final next = unread.firstWhere(
      (node) => rows.indexOf(node) > from,
      orElse: () => unread.first,
    );
    _controller.updatePrefs((prefs) {
      var next0 = prefs;
      for (final machine in _tree) {
        for (final node in machine.descendantsAndSelf) {
          if (node.key != next.key && SidebarKeys.isUnder(next.key, node.key)) {
            next0 = next0.setExpanded(node.key, true);
          }
        }
      }
      return next0;
    });
    unawaited(open(next));
    return true;
  }

  bool _handleShortcut(DesktopShortcutMatch match) {
    switch (match.action) {
      case DesktopAction.nextUnread:
        return openNextUnread();
      case DesktopAction.commandPalette:
        unawaited(openPalette(initial: '>'));
        return true;
      case DesktopAction.openSettings:
        unawaited(widget.actions.openSettings());
        return true;
      case DesktopAction.toggleSidebar:
        _controller.toggleSidebar();
        return true;
      default:
        break;
    }
    // With the terminal on screen, the terminal page answers the rest.
    if (terminalVisible) return false;
    final sessions = widget.workspace.sessions;
    switch (match.action) {
      case DesktopAction.newSession:
        unawaited(widget.actions.newSession());
      case DesktopAction.nextSession:
      case DesktopAction.previousSession:
      case DesktopAction.goToSession:
        if (sessions.isEmpty) return false;
        final active = widget.workspace.activeSession ?? sessions.first;
        final TerminalSessionController target;
        if (match.action == DesktopAction.goToSession) {
          if (match.index >= sessions.length) return false;
          target = sessions[match.index];
        } else {
          target = match.action == DesktopAction.nextSession
              ? active
              : sessions[(sessions.indexOf(active) - 1) % sessions.length];
        }
        widget.workspace.activate(target);
        _controller.showHome = false;
      case DesktopAction.showShortcuts:
        unawaited(showDesktopShortcutsSheet(context));
      default:
        return false;
    }
    return true;
  }

  // Context menus.

  /// A row's right-click menu; [entry] in [project] adds the project
  /// view's "Move to project…", "Move to Other" and "Hide".
  Future<void> showNodeMenu(
    SidebarNode node,
    Offset position, {
    ProjectEntry? entry,
    ProjectGroup? project,
  }) async {
    final prefs = _controller.prefs;
    final layout = _projectLayout;
    final machine = node.kind == SidebarNodeKind.machine;
    final unread = _unreadKeys.any((key) => SidebarKeys.isUnder(key, node.key));
    final host = node.target.host;
    final items = <PopupMenuEntry<_NodeAction>>[
      if (!machine) ...[
        const PopupMenuItem(
          value: _NodeAction.open,
          child: _MenuRow(Icons.open_in_new_rounded, 'Open'),
        ),
        const PopupMenuItem(
          value: _NodeAction.openRight,
          child: _MenuRow(Icons.vertical_split_outlined, 'Open in a split'),
        ),
        const PopupMenuDivider(),
      ],
      if (entry != null && project != null && layout != null) ...[
        ...projectEntryMenuItems<_NodeAction>(
          entry,
          project: project,
          value: _NodeAction.project,
          controller: layout,
          row: node,
        ),
        const PopupMenuDivider(),
      ],
      PopupMenuItem(
        value: unread ? _NodeAction.markRead : _NodeAction.markUnread,
        child: _MenuRow(
          unread ? Icons.mark_email_read_outlined : Icons.markunread_outlined,
          unread ? 'Mark as read' : 'Mark as unread',
        ),
      ),
      PopupMenuItem(
        value: _NodeAction.pin,
        child: _MenuRow(
          prefs.isPinned(node.key)
              ? Icons.push_pin_rounded
              : Icons.push_pin_outlined,
          prefs.isPinned(node.key) ? 'Unpin' : 'Pin',
        ),
      ),
      if (machine) ...[
        const PopupMenuDivider(),
        for (final group in prefs.groups)
          if (prefs.groupOf(node.machineId)?.id != group.id)
            PopupMenuItem(
              value: _NodeAction.group(group.id),
              child: _MenuRow(Icons.folder_outlined, 'Move to ${group.name}'),
            ),
        if (prefs.groupOf(node.machineId) != null)
          const PopupMenuItem(
            value: _NodeAction.ungroup,
            child: _MenuRow(Icons.folder_off_outlined, 'Remove from group'),
          ),
        const PopupMenuItem(
          value: _NodeAction.newGroup,
          child: _MenuRow(Icons.create_new_folder_outlined, 'New group…'),
        ),
        const PopupMenuDivider(),
        for (final choice in MachineMenuChoice.forHost(host))
          PopupMenuItem(
            value: _NodeAction.machine(choice),
            child: _MenuRow(choice.icon, choice.label),
          ),
      ],
    ];
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final action = await showMenu<_NodeAction>(
      context: context,
      position: RelativeRect.fromRect(
        position & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: items,
    );
    if (action == null || !mounted) return;
    switch (action.kind) {
      case _NodeActionKind.open:
        await open(node);
      case _NodeActionKind.openRight:
        await _openInSplit(node);
      case _NodeActionKind.markRead:
        _controller.markRead(node.key);
      case _NodeActionKind.markUnread:
        _controller.markUnread(node.key);
      case _NodeActionKind.pin:
        _controller.updatePrefs((prefs) => prefs.togglePin(node.key));
      case _NodeActionKind.group:
        _controller.updatePrefs(
          (prefs) => prefs.setGroup(node.machineId, action.groupId),
        );
      case _NodeActionKind.ungroup:
        _controller.updatePrefs(
          (prefs) => prefs.setGroup(node.machineId, null),
        );
      case _NodeActionKind.newGroup:
        final name = await _askName(context, title: 'New group');
        if (name == null || name.isEmpty) return;
        final id = 'g${_controller.now().microsecondsSinceEpoch}';
        _controller.updatePrefs(
          (prefs) => prefs
              .addGroup(SidebarGroup(id: id, name: name))
              .setGroup(node.machineId, id),
        );
      case _NodeActionKind.machine:
        await widget.actions.machineMenu(action.choice!, host);
      case _NodeActionKind.project:
        if (entry == null || project == null || layout == null) return;
        await runProjectEntryAction(
          context,
          layout,
          entry,
          action.projectAction!,
          project: project,
          row: node,
        );
    }
  }

  /// "Open in a split": a new pane on the right of the focused one.
  Future<void> _openInSplit(SidebarNode node) async {
    final host = embedding.host;
    if (host == null || !_hasViews) {
      await open(node);
      return;
    }
    final existing = widget.workspace.sessions
        .where((session) => keyForSession(session) == node.key)
        .firstOrNull;
    if (existing != null) {
      _controller.showHome = false;
      host.splitView(sessionViewId(existing), ShellEdge.right);
      return;
    }
    host.requestSplit(ShellEdge.right);
    await open(node);
  }

  Future<void> showGroupMenu(SidebarGroup group, Offset position) async {
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        position & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: const [
        PopupMenuItem(
          value: 'rename',
          child: _MenuRow(Icons.drive_file_rename_outline_rounded, 'Rename'),
        ),
        PopupMenuItem(
          value: 'delete',
          child: _MenuRow(Icons.folder_delete_outlined, 'Delete group'),
        ),
      ],
    );
    if (!mounted) return;
    switch (action) {
      case 'rename':
        final name = await _askName(
          context,
          title: 'Rename group',
          initial: group.name,
        );
        if (name == null || name.isEmpty) return;
        _controller.updatePrefs((prefs) => prefs.renameGroup(group.id, name));
      case 'delete':
        _controller.updatePrefs((prefs) => prefs.removeGroup(group.id));
    }
  }

  // The command palette.

  bool _paletteOpen = false;

  /// Opens the command palette (Ctrl+Shift+P with [initial] `>`, the
  /// switcher keys and buttons without): every session, agent, workspace,
  /// layout, setting and command, and runs the one picked.
  Future<void> openPalette({String initial = ''}) async {
    if (_paletteOpen || !mounted) return;
    _paletteOpen = true;
    final source = QuickSwitcherSource(
      workspace: widget.workspace,
      attention: widget.agentAttention,
      connectFlow: widget.connectFlow,
      homeBoards: widget.boards,
    );
    final recents = ValueNotifier<Map<String, List<ConnectTarget>>>(const {});
    unawaited(
      source.loadRecents().then((value) {
        if (_paletteOpen) recents.value = value;
      }),
    );
    PaletteEntry? picked;
    try {
      picked = await showCommandPalette(
        context,
        initialQuery: initial,
        recents: _controller.paletteRecents,
        changes: Listenable.merge([source.changes, recents, _controller]),
        entries: () => paletteEntries(source, recents.value),
      );
    } finally {
      _paletteOpen = false;
      recents.dispose();
    }
    if (picked == null || !mounted) return;
    _controller.notePaletteUse(picked.id);
    await picked.run();
  }

  /// Everything the palette lists now.
  @visibleForTesting
  List<PaletteEntry> paletteEntries(
    QuickSwitcherSource source, [
    Map<String, List<ConnectTarget>> recents = const {},
  ]) {
    final theme = widget.themeController;
    final host = embedding.host;
    return buildShellPaletteEntries(
      controller: _controller,
      places: source.items(recents: recents),
      selectedPalette: theme.selectedPalette,
      voice: theme.voice,
      hasUsage: UsageScope.maybeOf(context) != null,
      hasViews: _hasViews,
      actions: ShellPaletteActions(
        newSession: widget.actions.newSession,
        openSettings: (section) =>
            section != null && widget.actions.openSettingsAt != null
            ? widget.actions.openSettingsAt!(section)
            : widget.actions.openSettings(),
        addMachine: widget.actions.addMachine,
        showShortcuts: () => showDesktopShortcutsSheet(context),
        showHome: () => _controller.showHome = true,
        openItem: (item) => openSwitcherItem(
          context,
          item,
          source: source,
          showTerminal: () => _controller.showHome = false,
        ),
        applyPreset: applyPreset,
        restoreLayout: restoreLayout,
        saveLayout: saveLayoutAs,
        openUsage: (preset) => _controller.setShowUsage(true, preset: preset),
        setPalette: theme.setPalette,
        setVoice: theme.setVoice,
        nextUnread: openNextUnread,
        lock: widget.actions.lock,
        extra: [..._projectPaletteEntries(), ..._continuityPaletteEntries()],
        closeFocused: switch ((host, host?.activeViewId)) {
          (final host?, final view?) => () => host.closeView(view),
          _ => null,
        },
      ),
    );
  }

  /// "Continue from Phone: VTM · Chat view" and "Continue on…".
  List<PaletteEntry> _continuityPaletteEntries() {
    final continuity = _continuity;
    final open = widget.actions.continueFrom;
    if (continuity == null || open == null) return const [];
    return continuityPaletteEntries(
      continuity,
      open: open,
      showAll: () async {
        final picked = await showContinuitySheet(context, continuity);
        if (picked != null && mounted) await open(picked);
      },
    );
  }

  // Layouts.

  void _focusPane(String paneId) {
    final host = embedding.host;
    if (host == null) return;
    _controller.editLayout(
      host.viewIds.toSet(),
      (layout) => layout.focus(paneId),
    );
  }

  /// Lays the main area out as [preset]: the views on screen first (the
  /// focused one in the first pane), then the most recent others; the
  /// panes left over wait empty for a drop.
  void applyPreset(ShellLayoutPreset preset) {
    final host = embedding.host;
    final views = host?.viewIds ?? const <String>[];
    final current = _controller.layout.value.pruned(views.toSet());
    final active = host?.activeViewId;
    final next = preset.apply(viewsForPreset(current, [?active, ...views]));
    _controller.replaceLayout(next);
    if (views.isNotEmpty) _controller.showHome = false;
  }

  /// Brings a saved layout back, opening its sessions that are not open.
  Future<void> restoreLayout(SavedShellLayout saved) async {
    final host = embedding.host;
    final open = (host?.viewIds ?? const <String>[]).toSet();
    final flow = widget.connectFlow;
    for (final view in saved.views) {
      if (open.contains(view) || !view.startsWith('session:')) continue;
      final hostId = view.substring('session:'.length);
      final machine = widget.hostsController.findById(baseHostId(hostId));
      final target = ConnectTarget.fromSessionHostId(hostId);
      if (flow == null || machine == null || target == null) continue;
      flow.open(machine, target);
    }
    final layout = saved.layout.asSlots();
    _controller.replaceLayout(layout);
    _controller.showHome = false;
    // Sessions that just opened reveal themselves; the saved panes win.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _controller.replaceLayout(layout);
    });
  }

  /// Asks for a name and saves the current layout under it.
  Future<void> saveLayoutAs() async {
    final name = await _askName(
      context,
      title: 'Save layout',
      hint: 'Morning check, VTM work…',
    );
    if (name == null || name.isEmpty || !mounted) return;
    _controller.saveLayout(name);
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text('Saved the layout "$name".')));
  }

  Widget _layoutPicker() {
    final host = embedding.host;
    final views = (host?.viewIds ?? const <String>[]).toSet();
    return LayoutPickerButton(
      current: ShellLayoutPreset.of(_controller.layout.value.pruned(views)),
      saved: _controller.savedLayouts,
      onPick: (pick) {
        switch (pick) {
          case LayoutPickPreset(:final preset):
            applyPreset(preset);
          case LayoutPickSaved(:final saved):
            unawaited(restoreLayout(saved));
          case LayoutPickSave():
            unawaited(saveLayoutAs());
          case LayoutPickDelete(:final saved):
            _controller.deleteSavedLayout(saved.id);
        }
      },
    );
  }

  /// A sidebar row dropped on pane [paneId]: shows it there (the middle)
  /// or in a new pane at [edge]. A machine starts a new session there.
  Future<void> dropNode(String paneId, ShellEdge edge, SidebarNode node) async {
    final host = embedding.host;
    if (host == null) return;
    final existing = widget.workspace.sessions
        .where((session) => keyForSession(session) == node.key)
        .firstOrNull;
    if (existing != null) {
      _controller.showHome = false;
      host.placeView(paneId, edge, sessionViewId(existing));
      return;
    }
    final before = host.viewIds.toSet();
    _focusPane(paneId);
    if (edge != ShellEdge.center) host.requestSplit(edge);
    _controller.showHome = false;
    if (node.target is MachineTarget) {
      await widget.actions.openTarget(node.target);
    } else {
      await open(node);
    }
    if (!mounted) return;
    // It opened in a session that was already there (an agent of an open
    // workspace): move that one instead.
    final active = host.activeViewId;
    if (active != null && before.contains(active)) {
      host.cancelSplit();
      host.placeView(paneId, edge, active);
    } else if (!host.viewIds.any((view) => !before.contains(view))) {
      host.cancelSplit();
    }
  }

  // Building.

  Widget _previewToggle() {
    final active = _controller.rightPanel == ShellRightPanel.preview;
    return IconButton(
      key: const ValueKey('shell-toggle-preview'),
      tooltip: active ? 'Hide the live preview panel' : 'Live preview panel',
      isSelected: active,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 38, height: 40),
      icon: const Icon(Icons.public_rounded, size: 19),
      onPressed: () => _controller.toggleRightPanel(ShellRightPanel.preview),
    );
  }

  Widget _agentsToggle() {
    final active = _controller.rightPanel == ShellRightPanel.agents;
    final count = widget.agentAttention.attentionCount;
    return IconButton(
      key: const ValueKey('shell-toggle-agents'),
      tooltip: active ? 'Hide the agents panel' : 'Agents panel',
      isSelected: active,
      icon: AgentsIcon(count: count, size: 20),
      onPressed: () => _controller.toggleRightPanel(ShellRightPanel.agents),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return PreviewClock(
      ticks: _previewTicks,
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final palette = AppPalette.of(context);
          final showTerminal = terminalVisible;
          final chrome = !_fullscreen;
          final panel = controller.rightPanel;
          final shell = ColoredBox(
            color: palette.canvas,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (chrome) ...[
                  SizedBox(
                    width: controller.sidebarCollapsed
                        ? DesktopShellController.collapsedSidebarWidth
                        : controller.sidebarWidth,
                    child: controller.sidebarCollapsed
                        ? _collapsedSidebar()
                        : _sidebar(),
                  ),
                  if (controller.sidebarCollapsed)
                    VerticalDivider(width: 1, color: palette.hairline)
                  else
                    _ResizeHandle(
                      key: const ValueKey('sidebar-resize'),
                      onDrag: (delta) => controller.sidebarWidth =
                          controller.sidebarWidth + delta,
                    ),
                ],
                Expanded(
                  child: IndexedStack(
                    index: controller.showUsage
                        ? 2
                        : showTerminal
                        ? 0
                        : 1,
                    sizing: StackFit.expand,
                    children: [
                      TickerMode(
                        enabled: showTerminal,
                        child: widget.terminalBuilder(embedding),
                      ),
                      TickerMode(
                        enabled: !showTerminal && !controller.showUsage,
                        // A sidebar row dropped on the dashboard opens.
                        child: DragTarget<SidebarDrag>(
                          onWillAcceptWithDetails: (details) =>
                              details.data.node.kind != SidebarNodeKind.machine,
                          onAcceptWithDetails: (details) =>
                              unawaited(open(details.data.node)),
                          builder: (context, _, _) => _dashboard(context),
                        ),
                      ),
                      _usageMain(context),
                    ],
                  ),
                ),
                if (chrome && panel != ShellRightPanel.none) ...[
                  _ResizeHandle(
                    key: const ValueKey('right-panel-resize'),
                    onDrag: (delta) => controller.rightPanelWidth =
                        controller.rightPanelWidth - delta,
                  ),
                  SizedBox(
                    width: controller.rightPanelWidth,
                    child: _rightPanel(context, panel),
                  ),
                ],
              ],
            ),
          );
          // "Explore" in a usage view opens the explorer in the main area.
          final usage = UsageScope.maybeOf(context);
          if (usage == null) return shell;
          return UsageScope(
            controller: usage,
            openExplorer: _openUsage,
            child: shell,
          );
        },
      ),
    );
  }

  void _openUsage({String? day}) => _controller.setShowUsage(true, day: day);

  Widget _sidebarHeader() {
    final palette = AppPalette.of(context);
    // As tall as the main area's top row, so their lines meet.
    return Container(
      height: 40,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.only(left: 12, right: 4),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: palette.hairline)),
      ),
      child: Row(
        children: [
          Icon(Icons.hub_rounded, size: 18, color: palette.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Conductore',
              style: TextStyle(
                color: palette.foreground,
                fontWeight: FontWeight.w800,
                fontSize: 14,
              ),
            ),
          ),
          IconButton(
            key: const ValueKey('sidebar-switcher'),
            tooltip:
                'Command palette '
                '(${desktopShortcutKeys(DesktopAction.commandPalette)}, '
                '$quickSwitcherKeys)',
            iconSize: 18,
            onPressed: () => unawaited(widget.actions.openSwitcher()),
            icon: const Icon(Icons.search_rounded),
          ),
          IconButton(
            key: const ValueKey('sidebar-new-session'),
            tooltip:
                'New session (${desktopShortcutKeys(DesktopAction.newSession)})',
            iconSize: 18,
            onPressed: () => unawaited(widget.actions.newSession()),
            icon: const Icon(Icons.add_rounded),
          ),
          IconButton(
            key: const ValueKey('sidebar-collapse'),
            tooltip: 'Collapse the sidebar',
            iconSize: 18,
            onPressed: _controller.toggleSidebar,
            icon: const Icon(Icons.keyboard_double_arrow_left_rounded),
          ),
        ],
      ),
    );
  }

  Widget _sidebarFooter({bool compact = false}) {
    final palette = AppPalette.of(context);
    final usage = _usageView(context);
    final buttons = [
      IconButton(
        key: const ValueKey('sidebar-add-machine'),
        tooltip: 'Add machine',
        iconSize: 18,
        onPressed: () => unawaited(widget.actions.addMachine()),
        icon: const Icon(Icons.add_to_queue_rounded),
      ),
      IconButton(
        key: const ValueKey('sidebar-settings'),
        tooltip: 'Settings',
        iconSize: 18,
        onPressed: () => unawaited(widget.actions.openSettings()),
        icon: const Icon(Icons.settings_outlined),
      ),
      if (widget.actions.lock case final lock?)
        IconButton(
          key: const ValueKey('sidebar-lock'),
          tooltip: 'Lock',
          iconSize: 18,
          onPressed: () => unawaited(lock()),
          icon: const Icon(Icons.lock_outline_rounded),
        ),
    ];
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: palette.hairline)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Reserved for the usage summary (host companion `usage`).
          if (usage != null && !compact)
            KeyedSubtree(
              key: const ValueKey('sidebar-usage-slot'),
              child: usage,
            ),
          if (compact)
            ...buttons
          else
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Row(children: buttons),
            ),
        ],
      ),
    );
  }

  Widget _sidebar() {
    if (_controller.sidebarTab == ShellSidebarTab.projects) {
      return _projectSidebar();
    }
    return ShellSidebar(
      key: const ValueKey('shell-sidebar'),
      controller: _controller,
      tree: _tree,
      unreadKeys: _unreadKeys,
      selectedKey: _selectedKey,
      onOpen: (node) => unawaited(open(node)),
      onContextMenu: (node, position) =>
          unawaited(showNodeMenu(node, position)),
      onGroupMenu: (group, position) =>
          unawaited(showGroupMenu(group, position)),
      onExpand: _expand,
      header: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _sidebarHeader(),
          SidebarTabs(controller: _controller),
        ],
      ),
      footer: _sidebarFooter(),
    );
  }

  Widget _collapsedSidebar() {
    final needsYou = SidebarTreeBuilder.needsYou(_tree);
    return CollapsedShellSidebar(
      key: const ValueKey('shell-sidebar-collapsed'),
      tree: _tree,
      unreadCount: (node) => _controller.unreadCount(node, _unreadKeys),
      needsYouCount: needsYou.length,
      onExpand: _controller.toggleSidebar,
      onMachine: (node) {
        _controller.sidebarCollapsed = false;
        if (!_controller.isExpanded(node)) _controller.toggleExpanded(node);
      },
      onNeedsYou: () {
        if (needsYou.isNotEmpty) unawaited(open(needsYou.first));
      },
      footer: _sidebarFooter(compact: true),
      onContextMenu: (node, position) =>
          unawaited(showNodeMenu(node, position)),
    );
  }

  // The dashboard.

  Widget _dashboard(BuildContext context) {
    final palette = widget.themeController.palette;
    final brightness = Theme.of(context).brightness;
    final fontFamily = widget.themeController.terminalFont.fontFamily;
    final sessions = [...widget.workspace.sessions]
      ..sort((a, b) => (_outputAt[b] ?? 0).compareTo(_outputAt[a] ?? 0));
    final attention = widget.agentAttention;
    final boards = widget.boards;
    // With several machines, those never reached stay quiet instead of
    // each asking to be listed, like the phone's home.
    final quietWaiting = _tree.length > 2;
    final groups = <DashboardWorkspaceGroup>[];
    for (final machine in _tree) {
      final host = machine.target.host;
      final board = boards?[machine.machineId];
      final tiles = <Widget>[
        for (final node in machine.children)
          if (!node.openInApp)
            switch (node.target) {
              HerdrWorkspaceTarget(:final workspace) => DormantWorkspaceTile(
                key: ValueKey('dashboard-other-${node.key}'),
                workspace: workspace,
                palette: palette,
                brightness: brightness,
                onTap: () => unawaited(open(node)),
                onLongPress: () => unawaited(
                  showNodeMenu(
                    node,
                    AdaptiveModalPointer.recent ?? Offset.zero,
                  ),
                ),
              ),
              TmuxSessionTarget(:final session) => DormantTmuxTile(
                key: ValueKey('dashboard-other-${node.key}'),
                session: session,
                palette: palette,
                brightness: brightness,
                onTap: () => unawaited(open(node)),
                onLongPress: () => unawaited(
                  showNodeMenu(
                    node,
                    AdaptiveModalPointer.recent ?? Offset.zero,
                  ),
                ),
              ),
              _ => const SizedBox.shrink(),
            },
      ]..removeWhere((tile) => tile is SizedBox);
      HomeBoardNotice? notice;
      if (board != null) {
        final reason = board.requestReason;
        notice =
            quietWaiting &&
                reason == HomeBoardRequestReason.neverConnected &&
                board.state.phase == HomeBoardPhase.awaitingRequest
            ? null
            : HomeBoardNotice.of(
                board.state,
                requestReason: reason,
                hasOpenHerdrSession: machine.children.any(
                  (node) =>
                      node.openInApp &&
                      node.kind == SidebarNodeKind.herdrWorkspace,
                ),
              );
      }
      if (tiles.isEmpty && notice == null) continue;
      groups.add(
        DashboardWorkspaceGroup(
          machineName: machine.label,
          tiles: tiles,
          notice: notice == null
              ? null
              : HomeBoardNoticeTile(
                  key: ValueKey('dashboard-notice-${machine.machineId}'),
                  notice: notice,
                  palette: palette,
                  brightness: brightness,
                  onAction: notice.action == null
                      ? null
                      : () =>
                            widget.actions.noticeAction(host, notice!.action!),
                ),
        ),
      );
    }
    return ListenableBuilder(
      listenable: widget.sessionRestore ?? _never,
      builder: (context, _) => ShellDashboard(
        sessions: [
          for (final session in sessions)
            HomeSessionTile(
              key: ValueKey('dashboard-session-${session.host.id}'),
              session: session,
              info: HomeSessionInfo.of(
                session,
                workspaces:
                    boards?[baseHostId(session.host.id)]?.state.workspaces ??
                    const [],
                agentState: summarizeAgentState(
                  attention.statusFor(session.host.id),
                  session.host.id,
                ),
                machineName:
                    widget.hostsController
                        .findById(baseHostId(session.host.id))
                        ?.name ??
                    '',
                restoreNote: widget.sessionRestore?.noteFor(session),
              ),
              palette: palette,
              brightness: brightness,
              fontFamily: fontFamily,
              onTap: () => widget.actions.openSession(session),
              onLongPress: () =>
                  unawaited(widget.actions.sessionActions(session)),
            ),
        ],
        otherGroups: groups,
        onNewSession: () => unawaited(widget.actions.newSession()),
        agents: _agentsDigest(context),
        actions: [_agentsToggle(), _previewToggle()],
        // Crash reports and usage counts, once, like the phone's home.
        notice: const PrivacyNotice(),
      ),
    );
  }

  static final Listenable _never = ChangeNotifier();

  /// The agents dashboard (companion `digest`) in the home's main column;
  /// null without the app's digest controller.
  Widget? _agentsDigest(BuildContext context) {
    final digest = DigestScope.maybeOf(context);
    if (digest == null) return null;
    return AgentsDashboardView(
      controller: digest,
      attention: widget.agentAttention,
      shrinkWrap: true,
      inlineMenu: true,
      padding: EdgeInsets.zero,
      onOpenChat: (host, agent) =>
          unawaited(widget.actions.openChat(host, agent)),
      onOpenTerminal: (host, agent) {
        final flow = widget.connectFlow;
        if (flow != null) {
          unawaited(flow.openAgent(host, agent));
        } else {
          unawaited(widget.agentAttention.focusAgent(host.id, agent));
        }
        _controller.showHome = false;
      },
    );
  }

  /// Usage at a glance (companion `usage`): the app's usage controller in
  /// its compact layout; a tap opens the breakdown in the right panel.
  /// Null without usage (the dashboard then keeps its note).
  Widget? _usageView(BuildContext context) {
    final custom = widget.usageSummary;
    if (custom != null) return custom(context, compact: true);
    final usage = UsageScope.maybeOf(context);
    if (usage == null) return null;
    return UsageSummaryView(
      key: const ValueKey('sidebar-usage'),
      controller: usage,
      layout: UsageSummaryLayout.compact,
      onTap: _openUsage,
    );
  }

  /// The usage explorer in the main area: more room than the right panel
  /// for a wide chart, breakdowns side by side and the day beside them.
  Widget _usageMain(BuildContext context) {
    final usage = UsageScope.maybeOf(context);
    if (usage == null || !_controller.showUsage) {
      return const SizedBox.shrink();
    }
    return Material(
      color: AppPalette.of(context).canvas,
      child: UsageExplorerView(
        key: ValueKey(
          'shell-usage-explorer-${_controller.usageDay}-'
          '${_controller.usagePreset?.name}',
        ),
        usage: usage,
        initialDay: _controller.usageDay,
        initialPreset: _controller.usagePreset,
        onClose: () => _controller.setShowUsage(false),
        onUpdateCompanion: (hostId) {
          final host = usage.hostFor(hostId);
          if (host != null) unawaited(showCompanionSetup(context, host));
        },
      ),
    );
  }

  // The right panel.

  Widget _rightPanel(BuildContext context, ShellRightPanel panel) {
    final palette = AppPalette.of(context);
    final title = switch (panel) {
      ShellRightPanel.agents => 'Agents',
      ShellRightPanel.preview => 'Live preview',
      ShellRightPanel.usage => 'Usage',
      ShellRightPanel.none => '',
    };
    // Esc in the panel closes it.
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            _controller.rightPanel = ShellRightPanel.none,
      },
      child: Listener(
        // A click in the panel gives it the keys (Esc), unless something
        // inside takes them.
        onPointerDown: (_) {
          if (!_panelFocus.hasFocus) _panelFocus.requestFocus();
        },
        child: Focus(
          focusNode: _panelFocus,
          child: Material(
            key: ValueKey('shell-right-panel-${panel.name}'),
            color: palette.panel,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  height: 40,
                  padding: const EdgeInsets.only(left: 14),
                  decoration: BoxDecoration(
                    border: Border(bottom: BorderSide(color: palette.hairline)),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 13.5,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Close the panel',
                        iconSize: 18,
                        onPressed: () =>
                            _controller.rightPanel = ShellRightPanel.none,
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: switch (panel) {
                    ShellRightPanel.agents => AgentsDashboardView(
                      key: const ValueKey('shell-agents-panel'),
                      attention: widget.agentAttention,
                      tabs: true,
                      inlineMenu: true,
                      padding: const EdgeInsets.fromLTRB(14, 8, 14, 20),
                      onOpenTerminal: (host, agent) {
                        final flow = widget.connectFlow;
                        if (flow != null) {
                          unawaited(flow.openAgent(host, agent));
                        } else {
                          unawaited(
                            widget.agentAttention.focusAgent(host.id, agent),
                          );
                        }
                        _controller.showHome = false;
                      },
                      onOpenChat: (host, agent) =>
                          unawaited(widget.actions.openChat(host, agent)),
                    ),
                    ShellRightPanel.preview => _previewPanel(context),
                    ShellRightPanel.usage => switch (UsageScope.maybeOf(
                      context,
                    )) {
                      final usage? => ListView(
                        key: const ValueKey('shell-usage-panel'),
                        padding: const EdgeInsets.fromLTRB(14, 10, 14, 20),
                        children: [UsageBreakdown(controller: usage)],
                      ),
                      null => const SizedBox.shrink(),
                    },
                    ShellRightPanel.none => const SizedBox.shrink(),
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _previewPanel(BuildContext context) {
    final palette = widget.themeController.palette;
    final brightness = Theme.of(context).brightness;
    final host = embedding.host;
    final session = host?.focusedSession ?? widget.workspace.activeSession;
    final tab = session == null ? null : host?.previewTabFor(session.host);
    if (tab != null) {
      return LivePreviewView(
        key: ValueKey('panel-preview-${tab.host.id}'),
        controller: tab.controller,
        palette: palette,
        brightness: brightness,
        onChangePort: () => unawaited(host?.openPreviewForFocused()),
      );
    }
    final muted = AppPalette.of(context).mutedForeground;
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.public_rounded, size: 36, color: muted),
          const SizedBox(height: 10),
          Text(
            session == null
                ? 'Open a session to preview its web app.'
                : 'No live preview for ${session.title} yet.',
            textAlign: TextAlign.center,
            style: TextStyle(color: muted),
          ),
          if (session != null && !session.host.isLocal) ...[
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              key: const ValueKey('panel-start-preview'),
              onPressed: () {
                _controller.showHome = false;
                unawaited(host?.openPreviewForFocused());
              },
              icon: const Icon(Icons.play_arrow_rounded),
              label: const Text('Start live preview'),
            ),
          ],
        ],
      ),
    );
  }
}

enum _NodeActionKind {
  open,
  openRight,
  markRead,
  markUnread,
  pin,
  group,
  ungroup,
  newGroup,
  machine,
  project,
}

@immutable
class _NodeAction {
  const _NodeAction._(
    this.kind, {
    this.groupId,
    this.choice,
    this.projectAction,
  });

  const _NodeAction.project(ProjectEntryAction action)
    : this._(_NodeActionKind.project, projectAction: action);

  const _NodeAction.group(String id)
    : this._(_NodeActionKind.group, groupId: id);

  const _NodeAction.machine(MachineMenuChoice choice)
    : this._(_NodeActionKind.machine, choice: choice);

  static const open = _NodeAction._(_NodeActionKind.open);
  static const openRight = _NodeAction._(_NodeActionKind.openRight);
  static const markRead = _NodeAction._(_NodeActionKind.markRead);
  static const markUnread = _NodeAction._(_NodeActionKind.markUnread);
  static const pin = _NodeAction._(_NodeActionKind.pin);
  static const ungroup = _NodeAction._(_NodeActionKind.ungroup);
  static const newGroup = _NodeAction._(_NodeActionKind.newGroup);

  final _NodeActionKind kind;
  final String? groupId;
  final MachineMenuChoice? choice;
  final ProjectEntryAction? projectAction;

  @override
  bool operator ==(Object other) =>
      other is _NodeAction &&
      other.kind == kind &&
      other.groupId == groupId &&
      other.choice == choice &&
      other.projectAction == projectAction;

  @override
  int get hashCode => Object.hash(kind, groupId, choice, projectAction);
}

class _MenuRow extends StatelessWidget {
  const _MenuRow(this.icon, this.label);

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 18),
      const SizedBox(width: 10),
      Flexible(
        child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    ],
  );
}

Future<String?> _askName(
  BuildContext context, {
  required String title,
  String initial = '',
  String hint = 'Clients, Infra…',
}) => showDialog<String>(
  context: context,
  builder: (context) => _NameDialog(title: title, initial: initial, hint: hint),
);

/// Asks for a group's name; owns its text field's controller, which must
/// outlive the dialog's closing animation.
class _NameDialog extends StatefulWidget {
  const _NameDialog({
    required this.title,
    required this.initial,
    required this.hint,
  });

  final String title;
  final String initial;
  final String hint;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final TextEditingController _text = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        key: const ValueKey('group-name-field'),
        controller: _text,
        autofocus: true,
        decoration: InputDecoration(hintText: widget.hint),
        onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('group-name-save'),
          onPressed: () => Navigator.of(context).pop(_text.text.trim()),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// A thin vertical grab bar that resizes the panel next to it.
class _ResizeHandle extends StatefulWidget {
  const _ResizeHandle({required this.onDrag, super.key});

  final ValueChanged<double> onDrag;

  @override
  State<_ResizeHandle> createState() => _ResizeHandleState();
}

class _ResizeHandleState extends State<_ResizeHandle> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (details) => widget.onDrag(details.delta.dx),
        child: SizedBox(
          width: 5,
          child: Center(
            child: Container(
              width: _hovered ? 3 : 1,
              color: _hovered ? palette.accent : palette.hairline,
            ),
          ),
        ),
      ),
    );
  }
}
