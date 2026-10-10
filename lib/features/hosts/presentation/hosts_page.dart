import 'dart:async';

import 'package:conduit/core/platform_features.dart';
import 'package:conduit/core/presentation/adaptive_modal.dart';
import 'package:conduit/core/presentation/conduit_brand.dart';
import 'package:conduit/core/presentation/desktop_layout.dart';
import 'package:conduit/core/presentation/multiplexer_icon.dart';
import 'package:conduit/core/presentation/system_navigation_insets.dart';
import 'package:conduit/core/presentation/terminal_route.dart';
import 'package:conduit/core/secure_storage.dart';
import 'package:conduit/core/telemetry/telemetry.dart';
import 'package:conduit/core/telemetry/telemetry_events.dart';
import 'package:conduit/core/theme/terminal_appearance.dart';
import 'package:conduit/core/theme/theme_controller.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/domain/agent_naming.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/agents_digest/presentation/agents_dashboard.dart';
import 'package:conduit/features/agents_digest/presentation/digest_controller.dart';
import 'package:conduit/features/app_lock/presentation/app_lock_controller.dart';
import 'package:conduit/features/backup/data/app_backup_service.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_launcher.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_presenter.dart';
import 'package:conduit/features/companion_setup/presentation/companion_setup_page.dart';
import 'package:conduit/features/continuity/domain/continuity_record.dart';
import 'package:conduit/features/continuity/domain/continuity_rules.dart';
import 'package:conduit/features/continuity/presentation/continuity_opener.dart';
import 'package:conduit/features/continuity/presentation/continuity_scope.dart';
import 'package:conduit/features/continuity/presentation/continuity_widgets.dart';
import 'package:conduit/features/desktop_shell/data/desktop_shell_store.dart';
import 'package:conduit/features/desktop_shell/domain/sidebar_tree.dart';
import 'package:conduit/features/desktop_shell/presentation/desktop_home.dart';
import 'package:conduit/features/desktop_shell/presentation/desktop_shell_controller.dart';
import 'package:conduit/features/desktop_shell/presentation/project_layout_controller.dart';
import 'package:conduit/features/home_widget/presentation/home_launch_requests.dart';
import 'package:conduit/features/hosts/data/secure_home_preferences_repository.dart';
import 'package:conduit/features/hosts/domain/home_preferences.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/hosts/presentation/home_board_controller.dart';
import 'package:conduit/features/hosts/presentation/host_form_page.dart';
import 'package:conduit/features/hosts/presentation/hosts_controller.dart';
import 'package:conduit/features/hosts/presentation/widgets/home_chrome.dart';
import 'package:conduit/features/hosts/presentation/widgets/home_projects.dart';
import 'package:conduit/features/hosts/presentation/widgets/home_session_grid.dart';
import 'package:conduit/features/hosts/presentation/widgets/host_card.dart';
import 'package:conduit/features/hosts/presentation/widgets/machine_switcher.dart';
import 'package:conduit/features/hosts/presentation/widgets/message_state.dart';
import 'package:conduit/features/local_shell/domain/local_shell_instance.dart';
import 'package:conduit/features/local_shell/presentation/local_shell_controller.dart';
import 'package:conduit/features/local_shell/presentation/local_shell_instance_page.dart';
import 'package:conduit/features/local_shell/presentation/local_shell_setup_page.dart';
import 'package:conduit/features/session_navigation/presentation/quick_switcher_actions.dart';
import 'package:conduit/features/session_navigation/presentation/quick_switcher_sheet.dart';
import 'package:conduit/features/session_navigation/presentation/quick_switcher_shortcut.dart';
import 'package:conduit/features/session_navigation/presentation/session_view_controller.dart';
import 'package:conduit/features/session_navigation/presentation/session_view_launcher.dart';
import 'package:conduit/features/session_navigation/presentation/session_view_widgets.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:conduit/features/sessions/domain/remote_session_listing.dart';
import 'package:conduit/features/sessions/presentation/live_terminal_preview.dart';
import 'package:conduit/features/sessions/presentation/session_connect_flow.dart';
import 'package:conduit/features/sessions/presentation/session_grid_page.dart'
    show agentStatePriority, summarizeAgentState;
import 'package:conduit/features/sessions/presentation/session_restore_controller.dart';
import 'package:conduit/features/settings/presentation/privacy_notice.dart';
import 'package:conduit/features/settings/presentation/settings_catalog.dart';
import 'package:conduit/features/settings/presentation/settings_page.dart';
import 'package:conduit/features/settings/presentation/settings_services.dart';
import 'package:conduit/features/sftp/domain/file_export.dart';
import 'package:conduit/features/sftp/domain/sftp_bookmarks_repository.dart';
import 'package:conduit/features/sftp/domain/sftp_repository.dart';
import 'package:conduit/features/sftp/presentation/sftp_browser_page.dart';
import 'package:conduit/features/sync/domain/local_data_changes.dart';
import 'package:conduit/features/terminal/domain/host_key_prompt.dart';
import 'package:conduit/features/terminal/domain/host_key_verifier.dart';
import 'package:conduit/features/terminal/domain/ssh_terminal_repository.dart';
import 'package:conduit/features/terminal/presentation/host_key_prompt_coordinator.dart';
import 'package:conduit/features/terminal/presentation/host_key_prompt_dialog.dart';
import 'package:conduit/features/terminal/presentation/terminal_page.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:conduit/features/this_computer/data/host_channels.dart';
import 'package:conduit/features/this_computer/domain/local_shell_launch.dart';
import 'package:conduit/features/usage/presentation/usage_explorer_view.dart';
import 'package:conduit/features/usage/presentation/usage_widgets.dart';
import 'package:conduit/features/voice_guide/presentation/app_guide.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

/// The home page, Moshi-style: a slim bar (lock, machine filter chip,
/// settings), the open sessions of the filtered machines as large live
/// previews or compact rows, then their other workspaces (tmux sessions and
/// Herdr workspaces not open in the app yet), grouped by machine, with one
/// notice per machine that cannot be listed.
///
/// The machine chip opens the machine sheet: pick one or more machines
/// (all by default), each machine's actions, "Add machine" and the local
/// shells.
class HostsPage extends StatefulWidget {
  const HostsPage({
    required this.hostsController,
    required this.lockController,
    required this.terminalRepository,
    required this.workspaceController,
    required this.localShellController,
    required this.themeController,
    required this.hostKeyVerifier,
    required this.promptCoordinator,
    required this.sftpRepository,
    required this.sftpBookmarksRepository,
    required this.agentAttention,
    required this.backupService,
    required this.fileExport,
    this.connectFlow,
    this.homeBoards,
    this.sessionRestore,
    this.localDataChanges,
    this.homePreferences = const SecureHomePreferencesRepository(
      conductoreSecureStorage,
    ),
    this.previewRefreshInterval = const Duration(seconds: 2),
    this.paneRefocusDelay = const Duration(seconds: 4),
    this.hostChannels,
    this.desktopShell,
    this.shellMode,
    this.usageSummary,
    this.launchRequests,
    super.key,
  });

  /// Screens asked for from outside the page (the home-screen widget's
  /// dashboard and usage taps).
  final HomeLaunchRequests? launchRequests;

  /// The desktop shell's state (sidebar, splits, unread). Null makes the
  /// page own one in secure storage when it runs as the shell.
  final DesktopShellController? desktopShell;

  /// Whether the page is the desktop shell (sidebar, tabs and splits, a
  /// dashboard) instead of the phone home: null decides by the device
  /// (desktops, and tablets 900 dp wide or more, at the first build).
  final bool? shellMode;

  /// Replaces the desktop shell's usage summary; null shows the app's
  /// usage controller ([UsageScope]) when there is one.
  final UsageSummaryBuilder? usageSummary;

  final HostsController hostsController;
  final AppLockController lockController;
  final SshTerminalRepository terminalRepository;
  final TerminalWorkspaceController workspaceController;
  final LocalShellController localShellController;
  final ThemeController themeController;
  final HostKeyVerifier hostKeyVerifier;
  final HostKeyPromptCoordinator promptCoordinator;
  final SftpRepository sftpRepository;
  final SftpBookmarksRepository sftpBookmarksRepository;
  final AgentAttentionController agentAttention;
  final AppBackupService backupService;
  final FileExport fileExport;

  /// Connect picker (tmux / Herdr / recent / skip); null connects to a plain
  /// shell like before.
  final SessionConnectFlow? connectFlow;

  /// Live boards (tmux sessions, Herdr workspaces) of the filtered
  /// machines. When null the page builds them from [connectFlow]'s runner
  /// factory (and shows none without a connect flow).
  final HomeBoards? homeBoards;

  /// Brings back the sessions of the last app run and keeps their list;
  /// null leaves every start empty.
  final SessionRestoreController? sessionRestore;

  /// Remembers the machine filter and the view modes.
  final HomePreferencesRepository homePreferences;

  /// Backup imports and sync pulls: the page reloads what it cached
  /// (trusted keys, machine filter) and rebuilds the home boards.
  final LocalDataChanges? localDataChanges;

  /// How often session previews are re-captured while visible.
  final Duration previewRefreshInterval;

  /// After opening a new session for a pane, the pane is focused again
  /// once Herdr has attached.
  final Duration paneRefocusDelay;

  /// Commands and port forwards per machine for the terminal page (SSH or
  /// This computer); null means SSH only.
  final HostChannels? hostChannels;

  @override
  State<HostsPage> createState() => _HostsPageState();
}

/// One tmux session or Herdr workspace that is not open in the app.
sealed class _OtherItem {
  const _OtherItem(this.host);

  final SavedHost host;
}

class _OtherHerdr extends _OtherItem {
  const _OtherHerdr(super.host, this.workspace);

  final HomeBoardWorkspace workspace;
}

class _OtherTmux extends _OtherItem {
  const _OtherTmux(super.host, this.session);

  final TmuxSessionInfo session;
}

/// A machine's part of "Other workspaces": its items and its notice.
class _MachineGroup {
  const _MachineGroup(this.host, this.items, this.notice);

  final SavedHost host;
  final List<_OtherItem> items;
  final HomeBoardNotice? notice;
}

class _HostsPageState extends State<HostsPage> with WidgetsBindingObserver {
  bool _terminalPageOpen = false;

  /// Decided at the first build and kept: switching layouts under open
  /// sessions would pull the terminal out from under them.
  bool? _shellMode;
  DesktopShellController? _ownedShell;
  final _desktopHomeKey = GlobalKey<DesktopHomeState>();

  bool get _isShell => _shellMode ?? false;

  DesktopShellController get _shell =>
      widget.desktopShell ??
      (_ownedShell ??= DesktopShellController(
        store: const SecureDesktopShellStore(conductoreSecureStorage),
      ));

  /// Where dialogs and Chat View open from: inside the shell (below its
  /// Chat View presenter), else this page.
  BuildContext get _actionContext =>
      (_isShell ? _desktopHomeKey.currentContext : null) ?? context;
  bool _showingHostKeyPrompt = false;
  bool _appResumed = true;
  bool _routeVisible = true;
  HomePreferences _preferences = const HomePreferences();

  /// `host:port` of every trusted host key: machines reached before list
  /// their workspaces without asking.
  Set<String> _trustedEndpoints = const {};
  HomeBoards? _ownedBoards;
  Timer? _previewTimer;

  /// Ticks while the page is on screen with sessions open: the pace of
  /// the session previews (a [PreviewClock]).
  final _previewTicks = ValueNotifier<int>(0);
  Timer? _refocusTimer;

  HomeBoards? get _boards => widget.homeBoards ?? _ownedBoards;

  MachineFilter get _filter => MachineFilter(
    _preferences.machineFilter,
  ).validFor(widget.hostsController.machines);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final flow = widget.connectFlow;
    Telemetry.instance.screen(TelemetryScreen.home);
    if (widget.homeBoards == null && flow != null) {
      _ownedBoards = HomeBoards(
        runnerFactory: flow.runnerFactory,
        provider: widget.agentAttention.provider,
        liveFeed: flow.live.feedFor,
      );
    }
    widget.hostsController.addListener(_syncBoards);
    widget.workspaceController.addListener(_syncBoards);
    widget.workspaceController.addListener(_labelSessions);
    _boards?.addListener(_labelSessions);
    flow?.terminalRequests.addListener(_handleTerminalRequest);
    widget.launchRequests?.addListener(_handleLaunchRequest);
    widget.sessionRestore?.addListener(_handleRestoreChanged);
    widget.sessionRestore?.autoClosed.addListener(_handleAutoClosed);
    widget.localDataChanges?.addListener(_handleLocalDataChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // The page exists only while unlocked: this is the app start (or the
      // unlock after a lock) the saved sessions come back on.
      unawaited(_restoreSessions());
      unawaited(widget.hostsController.load());
      unawaited(widget.localShellController.refresh());
      unawaited(_loadPreferences());
      _handlePromptChanged();
      _syncBoards();
      _syncVisibility();
      unawaited(_loadTrustedEndpoints());
      _handleLaunchRequest();
    });
    widget.promptCoordinator.addListener(_handlePromptChanged);
  }

  /// Brings back the last run's sessions; the shell keeps its saved split
  /// layout until they are back.
  Future<void> _restoreSessions() async {
    try {
      await Future.wait([
        ?widget.sessionRestore?.restore(),
        if (_isShell) _shell.load(),
      ]);
    } finally {
      if (mounted && _isShell) _shell.releaseLayout();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Routes pushed on top (terminal, forms, SFTP) put this page offstage
    // with tickers disabled; that is the signal to pause live polling.
    final visible = TickerMode.valuesOf(context).enabled;
    if (visible != _routeVisible) {
      _routeVisible = visible;
      WidgetsBinding.instance.addPostFrameCallback((_) => _syncVisibility());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appResumed = state == AppLifecycleState.resumed;
    // The process may be killed while in the background: write the
    // session list now rather than after the debounce.
    if (!_appResumed) unawaited(widget.sessionRestore?.flush());
    _syncVisibility();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.hostsController.removeListener(_syncBoards);
    widget.workspaceController.removeListener(_syncBoards);
    widget.workspaceController.removeListener(_labelSessions);
    _boards?.removeListener(_labelSessions);
    widget.connectFlow?.terminalRequests.removeListener(_handleTerminalRequest);
    widget.launchRequests?.removeListener(_handleLaunchRequest);
    widget.sessionRestore?.removeListener(_handleRestoreChanged);
    widget.sessionRestore?.autoClosed.removeListener(_handleAutoClosed);
    widget.localDataChanges?.removeListener(_handleLocalDataChanged);
    widget.sessionRestore?.setHomeVisible(false);
    widget.promptCoordinator.removeListener(_handlePromptChanged);
    widget.promptCoordinator.rejectAll();
    _previewTimer?.cancel();
    _previewTicks.dispose();
    _refocusTimer?.cancel();
    widget.homeBoards?.setVisible(false);
    _ownedBoards?.dispose();
    _ownedShell?.dispose();
    super.dispose();
  }

  Future<void> _loadPreferences() async {
    final loaded = await widget.homePreferences.load();
    if (!mounted) return;
    setState(() => _preferences = loaded);
    _syncBoards();
  }

  void _savePreferences(HomePreferences next) {
    if (next == _preferences) return;
    setState(() => _preferences = next);
    unawaited(widget.homePreferences.save(next));
  }

  void _setFilter(MachineFilter filter) {
    _savePreferences(_preferences.copyWith(machineFilter: filter.keys));
    _syncBoards();
  }

  void _handleRestoreChanged() {
    if (mounted) setState(() {});
  }

  /// Restored tabs closed because their Herdr workspace has been gone for
  /// over a day (CON-115): one notice, with Undo.
  void _handleAutoClosed() {
    final restore = widget.sessionRestore;
    final closed = restore?.autoClosed.value;
    if (!mounted || restore == null || closed == null) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(closed.message),
          duration: const Duration(seconds: 8),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () => unawaited(restore.undoAutoClose(closed)),
          ),
        ),
      );
  }

  /// A backup import or a sync pull replaced saved data behind the page:
  /// the machines are already live (HostsController), but the trusted host
  /// keys and the machine filter were read at start. Imported machines have
  /// no last-connected time, so without their trusted keys their boards
  /// waited for a tap until the app restarted.
  void _handleLocalDataChanged() {
    if (mounted) unawaited(_reloadAfterDataChange());
  }

  Future<void> _reloadAfterDataChange() async {
    await _loadPreferences();
    if (!mounted) return;
    // A selection naming only machines that are gone falls back to "All";
    // store that, so the next import does not bring the old one back.
    final stored = _preferences.machineFilter;
    final valid = MachineFilter(
      stored,
    ).validFor(widget.hostsController.machines);
    if (valid.keys.length != stored.length) {
      _savePreferences(_preferences.copyWith(machineFilter: valid.keys));
    }
    await _loadTrustedEndpoints();
    if (!mounted) return;
    _syncBoards();
    unawaited(_boards?.refresh());
  }

  void _syncVisibility() {
    if (!mounted) return;
    final visible = _appResumed && _routeVisible;
    _boards?.setVisible(visible);
    widget.sessionRestore?.setHomeVisible(visible);
    if (visible) {
      // Back from the terminal a first connection may have trusted a key.
      unawaited(_loadTrustedEndpoints());
      // The shell's dashboard redraws its own previews.
      if (_isShell) return;
      // Each tile redraws its own preview on a tick, and only when its
      // terminal printed something since (see TerminalSnapshotBuilder).
      _previewTimer ??= Timer.periodic(widget.previewRefreshInterval, (_) {
        if (mounted && widget.workspaceController.hasSessions) {
          _previewTicks.value += 1;
        }
      });
    } else {
      _previewTimer?.cancel();
      _previewTimer = null;
    }
  }

  /// Saved machines the filter shows, in the machine list's order (every
  /// machine in the desktop shell, whose sidebar lists them all).
  List<SavedHost> get _shownHosts {
    if (_isShell) {
      return [
        for (final host in widget.hostsController.sortedMachines)
          if (!host.isLocal) host,
      ];
    }
    final filter = _filter;
    return [
      for (final host in widget.hostsController.sortedMachines)
        if (!host.isLocal && filter.includes(host.id)) host,
    ];
  }

  /// Filter key of a session: its saved machine, or the device for local
  /// shells.
  static String _filterKey(TerminalSessionController session) =>
      session.host.isLocal ||
          localShellInstanceIdFromHostId(session.host.id) != null
      ? localMachineFilterKey
      : baseHostId(session.host.id);

  List<TerminalSessionController> get _shownSessions {
    final filter = _filter;
    return [
      for (final session in widget.workspaceController.sessions)
        if (filter.includes(_filterKey(session))) session,
    ];
  }

  void _syncBoards() {
    if (!mounted) return;
    // While the switcher is open it searches every machine, not only the
    // ones the filter shows.
    final hosts = _switcherOpen && !_isShell
        ? [
            for (final host in widget.hostsController.sortedMachines)
              if (!host.isLocal) host,
          ]
        : _shownHosts;
    _boards?.sync([
      for (final host in hosts)
        HomeBoardEntry(host, connectedBefore: _connectedBefore(host)),
    ]);
  }

  /// What the session's agent is about, for its home row: the dashboard's
  /// summary of the most urgent agent there, else that agent's last
  /// message unless it is only Claude Code's generic notice.
  String? _agentLineFor(TerminalSessionController session) {
    final status = widget.agentAttention.statusFor(session.host.id);
    if (status == null || status.agents.isEmpty) return null;
    final target = ConnectTarget.fromSessionHostId(session.host.id);
    final workspace = target?.kind == ConnectTargetKind.herdr
        ? target!.name
        : '';
    final agents =
        [
          for (final agent in status.agents)
            if (workspace.isEmpty || agent.workspace == workspace) agent,
        ]..sort(
          (a, b) => agentStatePriority(a.state) - agentStatePriority(b.state),
        );
    for (final agent in agents) {
      final summary = widget.agentAttention.notificationDetail?.call(
        session.host.id,
        agent.id,
      );
      final topic = agentTopic(
        summary: summary,
        lastMessage: agent.lastMessage,
      );
      if (topic != null) return topic;
    }
    return null;
  }

  /// Gives each open Herdr session its workspace's live label, so titles
  /// everywhere (home, tabs, switcher, sidebar) name the workspace, not
  /// Herdr's raw id a session opened by id was named with.
  void _labelSessions() {
    final boards = _boards;
    if (boards == null) return;
    for (final session in widget.workspaceController.sessions) {
      final target = ConnectTarget.fromSessionHostId(session.host.id);
      if (target?.kind != ConnectTargetKind.herdr || target!.name.isEmpty) {
        continue;
      }
      final board = boards[baseHostId(session.host.id)];
      final live = board?.state.workspaces
          .where((workspace) => workspace.id == target.name)
          .firstOrNull;
      if (live != null) session.noteTargetLabel(live.label);
    }
  }

  bool _connectedBefore(SavedHost host) =>
      host.isThisComputer ||
      _trustedEndpoints.contains('${host.host.trim()}:${host.port}') ||
      _sessionsFor(host).isNotEmpty;

  Future<void> _loadTrustedEndpoints() async {
    try {
      final records = await widget.hostKeyVerifier.loadTrustedKeys();
      if (!mounted) return;
      _trustedEndpoints = {for (final record in records) record.key};
      _syncBoards();
    } catch (_) {
      // Unreadable key store: never-connected machines just wait for a tap.
    }
  }

  List<TerminalSessionController> _sessionsFor(SavedHost host) => [
    for (final session in widget.workspaceController.sessions)
      if (baseHostId(session.host.id) == host.id) session,
  ];

  SavedHost? _hostById(String id) => widget.hostsController.findById(id);

  void _handlePromptChanged() {
    if (_showingHostKeyPrompt || !mounted) return;
    if (widget.promptCoordinator.current == null) return;
    _showingHostKeyPrompt = true;
    Future<void>.microtask(() async {
      try {
        while (true) {
          final next = widget.promptCoordinator.current;
          if (next == null) break;
          final decision = await _requestHostKeyDecision(next);
          widget.promptCoordinator.resolve(next, decision);
        }
      } finally {
        _showingHostKeyPrompt = false;
      }
    });
  }

  Future<HostKeyDecision> _requestHostKeyDecision(
    HostKeyPromptRequest request,
  ) async {
    if (!mounted) return HostKeyDecision.reject;
    return await showHostKeyPromptDialog(context: context, request: request) ??
        HostKeyDecision.reject;
  }

  Future<void> _refreshAll() async {
    await widget.hostsController.load();
    await _boards?.refresh();
  }

  @override
  Widget build(BuildContext context) {
    if (_shellMode == null) {
      _shellMode =
          widget.shellMode ?? usesDesktopShell(MediaQuery.sizeOf(context));
      if (_shellMode!) {
        // Every machine gets a board in the shell, whatever the filter.
        WidgetsBinding.instance.addPostFrameCallback((_) => _syncBoards());
      }
    }
    if (_isShell) return _buildShell(context);
    final palette = widget.themeController.palette;
    final boards = _boards;
    return PreviewClock(
      ticks: _previewTicks,
      child: QuickSwitcherShortcut(
        onInvoke: () => unawaited(_openSwitcher(fromKeyboard: true)),
        child: Scaffold(
          body: ConduitBackdrop(
            palette: palette,
            child: SafeArea(
              bottom: shouldApplyBottomSafeArea(context),
              child: RefreshIndicator(
                color: Theme.of(context).colorScheme.primary,
                onRefresh: _refreshAll,
                child: ListenableBuilder(
                  listenable: Listenable.merge([
                    widget.hostsController,
                    widget.workspaceController,
                    widget.themeController,
                    widget.agentAttention,
                    ?boards,
                  ]),
                  builder: (context, _) {
                    return CustomScrollView(
                      key: const ValueKey('home-scroll'),
                      physics: const AlwaysScrollableScrollPhysics(),
                      slivers: centerSliversOnDesktop([
                        SliverToBoxAdapter(
                          child: HomeTopBar(
                            onLock: _lock,
                            onSettings: _openSettings,
                            onSwitcher: () => unawaited(_openSwitcher()),
                            onSearch: () =>
                                unawaited(_openSwitcher(focusSearch: true)),
                            onGuide: _guideButton(context),
                            onAgents: DigestScope.maybeOf(context) == null
                                ? null
                                : _openAgentsDashboard,
                            agentsBadge: widget.agentAttention.attentionCount,
                            machine: _machineChip(),
                          ),
                        ),
                        // Limit rings and today's tokens (companion usage).
                        if (UsageScope.maybeOf(context) case final usage?)
                          SliverToBoxAdapter(
                            child: UsageHomeBar(controller: usage),
                          ),
                        // Another device was in use since: pick up there.
                        if (ContinuityScope.maybeOf(context)
                            case final continuity?)
                          SliverToBoxAdapter(
                            child: ContinuityBanner(
                              controller: continuity,
                              onOpen: _acceptContinuityOffer,
                            ),
                          ),
                        // Once, after the update that added crash reports.
                        const SliverToBoxAdapter(child: PrivacyNotice()),
                        ..._buildMain(context),
                        const SliverToBoxAdapter(
                          child: SizedBox(
                            key: ValueKey('home-end'),
                            height: 24,
                          ),
                        ),
                      ]),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The voice guide's button, when the guide is on (it hides when
  /// turned off in Settings).
  VoidCallback? _guideButton(BuildContext context) {
    final guide = GuideScope.maybeOf(context);
    if (guide == null || !widget.themeController.voice.guide.enabled) {
      return null;
    }
    return guide.start;
  }

  /// The desktop shell: sidebar, tabs and splits, dashboard.
  Widget _buildShell(BuildContext context) {
    final shell = _shell;
    return QuickSwitcherShortcut(
      onInvoke: () => unawaited(_openSwitcher(fromKeyboard: true)),
      child: Scaffold(
        body: ChatViewPresenter(
          present: (request) {
            final host = _desktopHomeKey.currentState?.embedding.host;
            if (host == null) return false;
            shell.showHome = false;
            return host.presentChat(request);
          },
          child: _withContinuityToast(
            context,
            DesktopHome(
              key: _desktopHomeKey,
              controller: shell,
              hostsController: widget.hostsController,
              workspace: widget.workspaceController,
              agentAttention: widget.agentAttention,
              themeController: widget.themeController,
              boards: _boards,
              connectFlow: widget.connectFlow,
              sessionRestore: widget.sessionRestore,
              usageSummary: widget.usageSummary,
              previewRefreshInterval: widget.previewRefreshInterval,
              terminalBuilder: (embedding) => TerminalPage(
                workspace: widget.workspaceController,
                themeController: widget.themeController,
                sftpRepository: widget.sftpRepository,
                agentAttention: widget.agentAttention,
                hostKeyVerifier: widget.hostKeyVerifier,
                connectFlow: widget.connectFlow,
                homeBoards: _boards,
                hostChannels: widget.hostChannels,
                shell: embedding,
              ),
              actions: DesktopHomeActions(
                openTarget: _openSidebarTarget,
                newSession: _newSession,
                openSwitcher: _openSwitcher,
                openSettings: _openSettings,
                addMachine: _openForm,
                machineMenu: _handleMenu,
                openSession: (session) {
                  widget.workspaceController.activate(session);
                  unawaited(_showSession(session));
                },
                sessionActions: _showSessionActions,
                noticeAction: _handleNoticeAction,
                openChat: _openChatForAgent,
                lock: widget.lockController.enabled ? _lock : null,
                openSettingsAt: _openSettings,
                continueFrom: _continueFrom,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The desktop's offer to continue another device's place: a small card
  /// in the bottom corner, over the shell.
  Widget _withContinuityToast(BuildContext context, Widget shell) {
    final continuity = ContinuityScope.maybeOf(context);
    if (continuity == null) return shell;
    return Stack(
      children: [
        Positioned.fill(child: shell),
        Positioned(
          right: 16,
          bottom: 16,
          child: ContinuityToast(
            controller: continuity,
            onOpen: _acceptContinuityOffer,
          ),
        ),
      ],
    );
  }

  // Continuity: another device's place, opened here.

  void _acceptContinuityOffer(ContinuityOffer offer) {
    ContinuityScope.maybeOf(context)?.accept(offer);
    unawaited(_continueFrom(offer.context));
  }

  /// Opens another device's [place]: the same machine (its "This
  /// computer" is the saved machine that is that desktop), session and
  /// view; Chat View then scrolls where it was and offers its draft.
  Future<void> _continueFrom(ContinuityContext place) async {
    final continuity = ContinuityScope.maybeOf(context);
    if (continuity == null) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final result = await openContinuityContext(
      continuity,
      place,
      ContinuityOpenActions(
        openTerminal: _openContinuityTerminal,
        openChat: _openContinuityChat,
      ),
    );
    final message = continuityOpenMessage(result, place);
    if (message != null) {
      messenger?.showSnackBar(SnackBar(content: Text(message)));
    }
  }

  /// "Continue on…": the other devices' places to pick from.
  Future<void> _showContinueOn() async {
    final continuity = ContinuityScope.maybeOf(context);
    if (continuity == null) return;
    final picked = await showContinuitySheet(_actionContext, continuity);
    if (picked != null && mounted) await _continueFrom(picked);
  }

  Future<bool> _openContinuityTerminal(
    SavedHost host,
    ContinuityPlace place,
  ) async {
    final flow = widget.connectFlow;
    final target = place.target;
    if (flow != null &&
        target != null &&
        target.kind == ConnectTargetKind.herdr &&
        target.name.isNotEmpty &&
        !host.isLocal) {
      final session = await flow.openAgentLocation(
        host,
        workspaceId: target.name,
        tabId: target.tabId,
        paneId: place.paneId,
        label: target.label,
      );
      if (session == null || !mounted) return false;
      unawaited(_showSession(null));
      return true;
    }
    if (target != null) {
      // Exactly the terminal, whatever the session's preferred view.
      unawaited(_openTarget(host, target, preferredView: false));
      return true;
    }
    final open = _sessionsFor(host).where(
      (session) => ConnectTarget.keyFromSessionHostId(session.host.id) == null,
    );
    if (open.firstOrNull case final session?) {
      widget.workspaceController.activate(session);
      unawaited(_showSession(null));
      return true;
    }
    unawaited(
      _openTarget(host, const ConnectTarget.shell(), preferredView: false),
    );
    return true;
  }

  Future<bool> _openContinuityChat(
    SavedHost host,
    ContinuityPlace place,
  ) async {
    final attention = widget.agentAttention;
    final chatContext = _actionContext;
    final access = await checkChatViewAccessWithProgress(
      chatContext,
      attention: attention,
      host: host,
    );
    if (access == null || !access.ready || !mounted) return false;
    final agent = access.agents
        .where((agent) => agent.id == place.agentId)
        .firstOrNull;
    if (agent == null || !chatContext.mounted) return false;
    unawaited(
      openChatView(
        context: chatContext,
        attention: attention,
        host: host,
        agent: agent,
        pasteImages: widget.themeController.pasteImagesAsFiles,
        onOpenTerminal: () {
          final flow = widget.connectFlow;
          if (flow != null) {
            unawaited(flow.openAgent(host, agent));
          } else {
            unawaited(attention.focusAgent(host.id, agent));
          }
        },
      ),
    );
    return true;
  }

  /// A sidebar row: the workspace, tab, pane, tmux session or window it
  /// stands for, or the open session.
  Future<void> _openSidebarTarget(SidebarTarget target) async {
    switch (target) {
      case MachineTarget(:final host):
        await _connect(host, forcePicker: true);
      case HerdrWorkspaceTarget(:final host, :final workspace):
        await _openPane(host, workspace, null);
      case AgentPaneTarget(:final host, :final workspace, :final pane):
        await _openPane(host, workspace, pane);
      case HerdrTabTarget(:final host, :final workspace, :final tab):
        final flow = widget.connectFlow;
        if (flow == null) {
          await _openPane(host, workspace, null);
          return;
        }
        final session = await flow.openAgentLocation(
          host,
          workspaceId: workspace.id,
          tabId: tab.id,
          label: workspace.label,
        );
        if (!mounted) return;
        await _showSession(session);
      case TmuxSessionTarget(:final host, :final session):
        await _openTmux(host, session.name);
      case TmuxWindowTarget(:final host, :final session, :final window):
        await _openTmux(host, session, window: window.index);
      case OpenSessionTarget(:final sessionHostId):
        final session = widget.workspaceController.sessions
            .where((session) => session.host.id == sessionHostId)
            .firstOrNull;
        if (session == null) return;
        widget.workspaceController.activate(session);
        await _showSession(session);
    }
  }

  /// The home-screen widget's taps: the dashboard, or usage.
  void _handleLaunchRequest() {
    if (!mounted) return;
    switch (widget.launchRequests?.take()) {
      case HomeLaunchRequest.dashboard:
        _openAgentsDashboard();
      case HomeLaunchRequest.usage:
        if (UsageScope.maybeOf(context) case final usage?) {
          unawaited(openUsageExplorer(context, usage));
        }
      case null:
        break;
    }
  }

  /// The phone's agents dashboard (home bar button).
  void _openAgentsDashboard() {
    final digest = DigestScope.maybeOf(context);
    if (digest == null) return;
    unawaited(
      showAgentsDashboard(
        context,
        controller: digest,
        attention: widget.agentAttention,
        onOpenChat: (host, agent) => unawaited(_openChatForAgent(host, agent)),
        onOpenTerminal: (host, agent) =>
            unawaited(_openAgentTerminal(host, agent)),
      ),
    );
  }

  /// The dashboard's Terminal button: the agent's own pane, in the
  /// terminal (a new session when none is open there).
  Future<void> _openAgentTerminal(SavedHost host, AgentInfo agent) async {
    final flow = widget.connectFlow;
    if (flow != null) {
      await flow.openAgent(host, agent);
    } else {
      final session = widget.workspaceController.sessions
          .where((session) => session.host.id == host.id)
          .firstOrNull;
      if (session != null) widget.workspaceController.activate(session);
      unawaited(widget.agentAttention.focusAgent(host.id, agent));
    }
    if (!mounted || !widget.workspaceController.hasSessions) return;
    await _openTerminalWorkspace();
  }

  /// The agents panel's and the dashboard's Chat buttons.
  Future<void> _openChatForAgent(SavedHost host, AgentInfo agent) async {
    final attention = widget.agentAttention;
    final chatContext = _actionContext;
    final access = await checkChatViewAccessWithProgress(
      chatContext,
      attention: attention,
      host: host,
    );
    if (access == null || !mounted || !chatContext.mounted) return;
    if (!access.ready) {
      await showChatViewUnavailable(chatContext, host: host, access: access);
      return;
    }
    await openChatView(
      context: chatContext,
      attention: attention,
      host: host,
      agent: agent,
      pasteImages: widget.themeController.pasteImagesAsFiles,
      onOpenTerminal: () {
        final flow = widget.connectFlow;
        if (flow != null) {
          unawaited(flow.openAgent(host, agent));
        } else {
          unawaited(attention.focusAgent(host.id, agent));
        }
      },
    );
  }

  bool _switcherOpen = false;

  /// The quick switcher from home (the top bar's buttons, Ctrl+K): what is
  /// picked opens in the terminal (or Chat View, per session). It lists
  /// the workspaces of every machine, whatever the filter; [focusSearch]
  /// (the search button) brings the keyboard up at once.
  Future<void> _openSwitcher({
    bool fromKeyboard = false,
    bool focusSearch = false,
  }) async {
    // The desktop shell's command palette lists the same and more.
    if (_isShell) {
      final home = _desktopHomeKey.currentState;
      if (home != null) {
        await home.openPalette();
        return;
      }
    }
    if (_switcherOpen) return;
    _switcherOpen = true;
    _syncBoards();
    final source = QuickSwitcherSource(
      workspace: widget.workspaceController,
      attention: widget.agentAttention,
      connectFlow: widget.connectFlow,
      homeBoards: _boards,
    );
    final QuickSwitcherChoice? choice;
    try {
      choice = await showQuickSwitcher(
        _actionContext,
        source: source,
        fontFamily: widget.themeController.terminalFont.fontFamily,
        fromKeyboard: fromKeyboard,
        focusSearch: focusSearch,
        canCreate: true,
      );
    } finally {
      _switcherOpen = false;
      _syncBoards();
    }
    if (!mounted) return;
    switch (choice) {
      case QuickSwitcherOpen(:final item):
        await openSwitcherItem(
          _actionContext,
          item,
          source: source,
          showTerminal: () => unawaited(_openTerminalWorkspace()),
        );
      case QuickSwitcherNewSession():
        await _newSession();
      case QuickSwitcherShowGrid() || null:
        break;
    }
  }

  Widget _machineChip() {
    final filter = _filter;
    final hosts = widget.hostsController.machines;
    return MachineChip(
      label: hosts.isEmpty && filter.isAll
          ? 'Machines'
          : filter.label(widget.hostsController.sortedMachines),
      live: _shownSessions.isNotEmpty,
      otherAttentionCount: _hiddenAttentionCount(filter),
      onTap: _openMachineSheet,
    );
  }

  List<Widget> _buildMain(BuildContext context) {
    final controller = widget.hostsController;
    if (controller.isLoading && controller.machines.isEmpty) {
      return const [
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.all(48),
            child: Center(child: CircularProgressIndicator()),
          ),
        ),
      ];
    }
    if (controller.errorMessage != null && controller.machines.isEmpty) {
      return [
        SliverToBoxAdapter(
          child: MessageState(
            icon: Icons.error_outline,
            title: 'Something went wrong',
            message: controller.errorMessage!,
            actionLabel: 'Retry',
            onAction: controller.load,
          ),
        ),
      ];
    }
    if (controller.machines.isEmpty &&
        !widget.workspaceController.hasSessions) {
      return [_buildNoMachines(context)];
    }
    return [
      ..._buildSessions(context),
      ...(ProjectLayoutController.instance?.groupByProject ?? false)
          ? _buildProjects(context, ProjectLayoutController.instance!)
          : _buildOtherWorkspaces(context),
    ];
  }

  /// The proot local-shell section ("This device"): Android only, and
  /// only while the setting shows it. Desktops have This computer.
  bool get _showProotShell =>
      PlatformFeatures.prootLocalShell && widget.themeController.showLocalShell;

  Widget _buildNoMachines(BuildContext context) {
    final showLocal =
        _showProotShell && !widget.localShellController.isUnsupported;
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 24),
      sliver: SliverList(
        delegate: SliverChildListDelegate.fixed([
          const _MachineSectionHeader(),
          const SizedBox(height: 24),
          MessageState(
            icon: Icons.dns_outlined,
            title: 'No saved machines yet',
            message:
                'Add an SSH or Mosh server and Conductore will keep its '
                'credentials in your device’s secure storage.',
            actionLabel: 'Add machine',
            onAction: _openForm,
          ),
          if (showLocal)
            Center(
              child: TextButton.icon(
                onPressed: _openLocalShellSetup,
                icon: const Icon(Icons.phone_android_rounded),
                label: const Text('Or set up a local shell'),
              ),
            ),
        ]),
      ),
    );
  }

  List<Widget> _buildSessions(BuildContext context) {
    final palette = widget.themeController.palette;
    final brightness = Theme.of(context).brightness;
    final fontFamily = widget.themeController.terminalFont.fontFamily;
    final width = MediaQuery.sizeOf(context).width;
    final view = _preferences.sessionsView;
    final metrics = HomeGridMetrics.of(
      width,
      large: view == HomeSessionsView.large,
    );
    final sessions = _shownSessions;
    final active = widget.workspaceController.activeSession;
    const gutter = HomeGridMetrics.horizontalPadding;

    HomeSessionInfo infoFor(TerminalSessionController session) {
      final hostId = baseHostId(session.host.id);
      final board = _boards?[hostId];
      final machine = _hostById(hostId);
      return HomeSessionInfo.of(
        session,
        workspaces: board?.state.workspaces ?? const [],
        agentState: summarizeAgentState(
          widget.agentAttention.statusFor(session.host.id),
          session.host.id,
        ),
        machineName: session.host.isLocal ? 'This device' : machine?.name ?? '',
        restoreNote: widget.sessionRestore?.noteFor(session),
        agentLine: _agentLineFor(session),
      );
    }

    void open(TerminalSessionController session) {
      widget.workspaceController.activate(session);
      unawaited(_showSession(session));
    }

    // The "+" tile fills the last row's gap (or stands alone when nothing
    // is open); otherwise the header's "+" opens the picker.
    final showAddTile =
        sessions.isEmpty || sessions.length % metrics.columns != 0;

    return [
      SliverToBoxAdapter(
        child: _SectionHeader(
          label: 'SESSIONS',
          detail: sessions.isEmpty ? 'none open' : '${sessions.length} open',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: 'New session',
                icon: const Icon(Icons.add_rounded),
                onPressed: _newSession,
              ),
              _SessionsViewMenu(
                value: view,
                onChanged: (next) =>
                    _savePreferences(_preferences.copyWith(sessionsView: next)),
              ),
            ],
          ),
        ),
      ),
      if (view == HomeSessionsView.list && sessions.isNotEmpty)
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(gutter, 4, gutter, 8),
          sliver: SliverList.separated(
            itemCount: sessions.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final session = sessions[index];
              return HomeSessionRow(
                key: ValueKey('home-session-${session.host.id}'),
                session: session,
                info: infoFor(session),
                palette: palette,
                brightness: brightness,
                fontFamily: fontFamily,
                selected: session == active,
                onTap: () => open(session),
                onLongPress: () => _showSessionActions(session),
              );
            },
          ),
        )
      else
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(gutter, 4, gutter, 8),
          sliver: SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: metrics.columns,
              mainAxisSpacing: 18,
              crossAxisSpacing: HomeGridMetrics.spacing,
              mainAxisExtent: metrics.sessionExtent,
            ),
            delegate: SliverChildBuilderDelegate((context, index) {
              if (index == sessions.length) {
                return HomeAddTile(
                  palette: palette,
                  brightness: brightness,
                  label: sessions.isEmpty ? 'Connect' : 'New session',
                  onTap: _newSession,
                );
              }
              final session = sessions[index];
              return HomeSessionTile(
                key: ValueKey('home-session-${session.host.id}'),
                session: session,
                info: infoFor(session),
                palette: palette,
                brightness: brightness,
                fontFamily: fontFamily,
                selected: session == active,
                onTap: () => open(session),
                onLongPress: () => _showSessionActions(session),
              );
            }, childCount: sessions.length + (showAddTile ? 1 : 0)),
          ),
        ),
    ];
  }

  /// Per shown machine: the tmux sessions and Herdr workspaces that are
  /// not open in the app, and the notice explaining what cannot be listed.
  List<_MachineGroup> _otherWorkspaceGroups() {
    final boards = _boards;
    if (boards == null) return const [];
    final shown = _shownHosts;
    // With every machine shown, machines never reached stay quiet instead
    // of each asking to be listed; picking them (or having only one) asks.
    final quietWaiting = _filter.isAll && shown.length > 1;
    final groups = <_MachineGroup>[];
    for (final host in shown) {
      final board = boards[host.id];
      if (board == null) continue;
      final state = board.state;
      final sessions = _sessionsFor(host);
      final openHerdr = <String>{};
      final openTmux = <String>{};
      var hasOpenHerdrSession = false;
      for (final session in sessions) {
        final target = ConnectTarget.fromSessionHostId(session.host.id);
        if (target?.kind == ConnectTargetKind.herdr) {
          hasOpenHerdrSession = true;
          if (target!.name.isNotEmpty) openHerdr.add(target.name);
        }
        final tmux = HomeSessionInfo.tmuxSessionOf(session);
        if (tmux != null) openTmux.add(tmux);
      }
      final items = <_OtherItem>[
        for (final workspace in state.workspaces)
          if (!openHerdr.contains(workspace.id)) _OtherHerdr(host, workspace),
        for (final tmux in state.tmuxSessions)
          if (!openTmux.contains(tmux.name)) _OtherTmux(host, tmux),
      ];
      final reason = board.requestReason;
      final notice =
          quietWaiting &&
              reason == HomeBoardRequestReason.neverConnected &&
              state.phase == HomeBoardPhase.awaitingRequest
          ? null
          : HomeBoardNotice.of(
              state,
              requestReason: reason,
              hasOpenHerdrSession: hasOpenHerdrSession,
            );
      if (items.isEmpty && notice == null) continue;
      groups.add(_MachineGroup(host, items, notice));
    }
    return groups;
  }

  List<Widget> _buildOtherWorkspaces(BuildContext context) {
    final groups = _otherWorkspaceGroups();
    if (groups.isEmpty) return const [];
    final palette = widget.themeController.palette;
    final brightness = Theme.of(context).brightness;
    final width = MediaQuery.sizeOf(context).width;
    final metrics = HomeGridMetrics.of(width);
    final view = _preferences.workspacesView;
    final count = groups.fold(0, (sum, group) => sum + group.items.length);
    final grouped = groups.length > 1;
    const gutter = HomeGridMetrics.horizontalPadding;

    Widget tileFor(_OtherItem item) => switch (item) {
      _OtherHerdr(:final host, :final workspace) =>
        view == HomeWorkspacesView.list
            ? OtherWorkspaceRow(
                key: ValueKey('other-herdr-${host.id}-${workspace.id}'),
                kind: MultiplexerKind.herdr,
                title: workspace.label,
                details: herdrDetails(workspace),
                chips: herdrStateChips(workspace),
                attention: workspace.summary,
                palette: palette,
                brightness: brightness,
                onTap: () => _openPane(host, workspace, null),
                onLongPress: workspace.panes.isEmpty
                    ? null
                    : () => _showWorkspacePanes(host, workspace),
              )
            : DormantWorkspaceTile(
                key: ValueKey('other-herdr-${host.id}-${workspace.id}'),
                workspace: workspace,
                palette: palette,
                brightness: brightness,
                onTap: () => _openPane(host, workspace, null),
                onLongPress: workspace.panes.isEmpty
                    ? null
                    : () => _showWorkspacePanes(host, workspace),
              ),
      _OtherTmux(:final host, :final session) =>
        view == HomeWorkspacesView.list
            ? OtherWorkspaceRow(
                key: ValueKey('other-tmux-${host.id}-${session.name}'),
                kind: MultiplexerKind.tmux,
                title: session.name,
                details: tmuxDetails(session),
                chips: [if (session.isAttached) const AttachedChip()],
                palette: palette,
                brightness: brightness,
                onTap: () => _openTmux(host, session.name),
                onLongPress: () => _showTmuxWindows(host, session),
              )
            : DormantTmuxTile(
                key: ValueKey('other-tmux-${host.id}-${session.name}'),
                session: session,
                palette: palette,
                brightness: brightness,
                onTap: () => _openTmux(host, session.name),
                onLongPress: () => _showTmuxWindows(host, session),
              ),
    };

    return [
      SliverToBoxAdapter(
        child: _SectionHeader(
          label: 'OTHER WORKSPACES',
          detail: count == 0 ? null : '$count not open',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (ProjectLayoutController.instance case final projects?)
                _groupByToggle(projects),
              IconButton(
                key: const ValueKey('workspaces-view-toggle'),
                tooltip: view == HomeWorkspacesView.list
                    ? 'Show as grid'
                    : 'Show as list',
                icon: Icon(
                  view == HomeWorkspacesView.list
                      ? Icons.grid_view_rounded
                      : Icons.view_list_rounded,
                ),
                onPressed: () => _savePreferences(
                  _preferences.copyWith(
                    workspacesView: view == HomeWorkspacesView.list
                        ? HomeWorkspacesView.grid
                        : HomeWorkspacesView.list,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      for (final group in groups) ...[
        if (grouped)
          SliverToBoxAdapter(
            child: _MachineGroupHeader(
              key: ValueKey('other-group-${group.host.id}'),
              name: group.host.name,
            ),
          ),
        if (group.notice != null)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(gutter, 4, gutter, 8),
            sliver: SliverToBoxAdapter(
              child: HomeBoardNoticeTile(
                key: ValueKey('home-board-notice-${group.host.id}'),
                notice: group.notice!,
                palette: palette,
                brightness: brightness,
                onAction: group.notice!.action == null
                    ? null
                    : () => _handleNoticeAction(
                        group.host,
                        group.notice!.action!,
                      ),
              ),
            ),
          ),
        if (group.items.isNotEmpty)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(gutter, 4, gutter, 8),
            sliver: view == HomeWorkspacesView.list
                ? SliverList.separated(
                    itemCount: group.items.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 6),
                    itemBuilder: (context, index) =>
                        tileFor(group.items[index]),
                  )
                : SliverGrid(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: metrics.columns,
                      mainAxisSpacing: HomeGridMetrics.spacing,
                      crossAxisSpacing: HomeGridMetrics.spacing,
                      mainAxisExtent: metrics.dormantExtent,
                    ),
                    delegate: SliverChildListDelegate([
                      for (final item in group.items) tileFor(item),
                    ]),
                  ),
          ),
      ],
    ];
  }

  /// Group by project or by machine (CON-065), next to the view toggle.
  Widget _groupByToggle(ProjectLayoutController projects) => IconButton(
    key: const ValueKey('home-group-by-toggle'),
    tooltip: projects.groupByProject ? 'Group by machine' : 'Group by project',
    icon: Icon(
      projects.groupByProject ? Icons.dns_outlined : Icons.folder_copy_outlined,
    ),
    onPressed: () async {
      await projects.setGroupByProject(!projects.groupByProject);
      if (mounted) setState(() {});
    },
  );

  /// The workspaces of the shown machines by project, sheprd's way.
  List<Widget> _buildProjects(
    BuildContext context,
    ProjectLayoutController projects,
  ) => [
    SliverToBoxAdapter(
      child: _SectionHeader(
        label: 'PROJECTS',
        trailing: _groupByToggle(projects),
      ),
    ),
    // Machines that cannot be listed keep their notice, as one line each.
    for (final group in _otherWorkspaceGroups())
      if (group.notice case final notice?)
        SliverToBoxAdapter(
          child: HomeNoticeLine(
            key: ValueKey('home-notice-line-${group.host.id}'),
            machine: group.host.name,
            notice: notice,
            palette: widget.themeController.palette,
            onAction: notice.action == null
                ? null
                : () => _handleNoticeAction(group.host, notice.action!),
          ),
        ),
    SliverToBoxAdapter(
      child: HomeProjectsList(
        controller: projects,
        hosts: _shownHosts,
        sessions: widget.workspaceController.sessions,
        attention: widget.agentAttention,
        boards: _boards,
        herdrWorkspaceOf: widget.connectFlow?.herdr.workspaceOf,
        onOpen: (target) => unawaited(_openSidebarTarget(target)),
      ),
    ),
  ];

  void _handleNoticeAction(SavedHost host, HomeBoardNoticeAction action) {
    final board = _boards?[host.id];
    switch (action) {
      case HomeBoardNoticeAction.request:
        board?.requestLoad();
      case HomeBoardNoticeAction.retry:
        if (board != null) unawaited(board.refresh());
      case HomeBoardNoticeAction.startHerdr:
        unawaited(
          _openTarget(host, const ConnectTarget.herdr(workspaceId: '')),
        );
      case HomeBoardNoticeAction.openShell:
        unawaited(_openTarget(host, const ConnectTarget.shell()));
    }
  }

  /// Lists a workspace's agent panes; tapping one opens the workspace
  /// focused on that pane.
  Future<void> _showWorkspacePanes(
    SavedHost host,
    HomeBoardWorkspace workspace,
  ) async {
    final pane = await showAdaptiveModal<HomeBoardPane>(
      kind: AdaptiveModalKind.dialog,
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.7,
          ),
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                leading: const MultiplexerIcon(MultiplexerKind.herdr, size: 24),
                title: Text(
                  workspace.label,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                subtitle: const Text('Open the workspace at an agent'),
              ),
              const Divider(height: 1),
              for (final pane in workspace.panes)
                ListTile(
                  key: ValueKey('pane-${pane.agent.pane ?? pane.agent.id}'),
                  title: Text(
                    pane.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    [
                      if (pane.tabLabel.isNotEmpty) pane.tabLabel,
                      pane.agent.kind,
                    ].join(' › '),
                  ),
                  trailing: AgentStateChip(state: pane.agent.state),
                  onTap: () => Navigator.of(context).pop(pane),
                ),
            ],
          ),
        ),
      ),
    );
    if (pane == null || !mounted) return;
    await _openPane(host, workspace, pane);
  }

  /// Lists a tmux session's windows; tapping one opens the session there.
  Future<void> _showTmuxWindows(SavedHost host, TmuxSessionInfo session) async {
    final board = _boards?[host.id];
    final windows = board == null
        ? Future.value(const <TmuxWindowInfo>[])
        : board.listTmuxWindows(session.name);
    final picked = await showAdaptiveModal<TmuxWindowInfo>(
      kind: AdaptiveModalKind.dialog,
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.7,
          ),
          child: FutureBuilder<List<TmuxWindowInfo>>(
            future: windows,
            builder: (context, snapshot) {
              final list = snapshot.data;
              return ListView(
                shrinkWrap: true,
                children: [
                  ListTile(
                    leading: const MultiplexerIcon(
                      MultiplexerKind.tmux,
                      size: 24,
                    ),
                    title: Text(
                      session.name,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    subtitle: const Text('Open the session at a window'),
                  ),
                  const Divider(height: 1),
                  if (list == null)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (list.isEmpty)
                    const ListTile(
                      title: Text('Could not list the windows'),
                      subtitle: Text('Tap the session to attach to it.'),
                    )
                  else
                    for (final window in list)
                      ListTile(
                        key: ValueKey('tmux-window-${window.index}'),
                        leading: Text(
                          '${window.index}',
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 16,
                          ),
                        ),
                        title: Text(
                          window.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          window.panes == 1
                              ? '1 pane'
                              : '${window.panes} panes',
                        ),
                        trailing: window.active ? const Text('current') : null,
                        onTap: () => Navigator.of(context).pop(window),
                      ),
                ],
              );
            },
          ),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    await _openTmux(host, session.name, window: picked.index);
  }

  /// Attaches to tmux [sessionName] on [host] (activating an open session
  /// for it), at [window] when given.
  Future<void> _openTmux(
    SavedHost host,
    String sessionName, {
    int? window,
  }) async {
    final board = _boards?[host.id];
    if (window != null && board != null) {
      // tmux shows the session's current window on attach.
      await board.selectTmuxWindow(sessionName, window);
      if (!mounted) return;
    }
    final existing = _sessionsFor(
      host,
    ).where((s) => HomeSessionInfo.tmuxSessionOf(s) == sessionName).firstOrNull;
    // A window picked by hand is a place in the terminal: it stays there.
    final preferredView = window == null;
    if (existing != null) {
      widget.workspaceController.activate(existing);
      await _showSession(preferredView ? existing : null);
      return;
    }
    await _openTarget(
      host,
      ConnectTarget.tmux(sessionName),
      preferredView: preferredView,
    );
  }

  /// The gear: the full-screen Settings page.
  Future<void> _openSettings([SettingsSection? section]) => showSettings(
    context,
    section: section,
    services: SettingsServices(
      theme: widget.themeController,
      backupService: widget.backupService,
      hostsController: widget.hostsController,
      hostKeyVerifier: widget.hostKeyVerifier,
      agentAttention: widget.agentAttention,
      digest: DigestScope.maybeOf(context),
      onLockNow: _lock,
    ),
  );

  /// Agents needing input on machines the filter hides.
  int _hiddenAttentionCount(MachineFilter filter) {
    if (filter.isAll) return 0;
    var count = 0;
    for (final host in widget.agentAttention.monitoredHosts) {
      if (filter.includes(baseHostId(host.id))) continue;
      final agents = widget.agentAttention.statusFor(host.id)?.agents;
      if (agents == null) continue;
      count += agents.where((agent) => agent.state.needsAttention).length;
    }
    return count;
  }

  Future<void> _openMachineSheet() async {
    final showLocal = _showProotShell;
    final result = await showMachineSheet(
      context: context,
      hostsController: widget.hostsController,
      filter: _filter,
      onFilterChanged: _setFilter,
      liveKeys: {
        for (final session in widget.workspaceController.sessions)
          _filterKey(session),
      },
      localShellController: showLocal ? widget.localShellController : null,
      activeLocalInstanceIds: widget.workspaceController.sessions
          .map((session) => localShellInstanceIdFromHostId(session.host.id))
          .whereType<String>()
          .toSet(),
    );
    if (!mounted || result == null) return;
    switch (result) {
      case MachineAddRequested():
        await _openForm();
      case MachineMenuRequested(:final host, :final choice):
        await _handleMenu(choice, host);
      case LocalShellSetupRequested():
        await _openLocalShellSetup();
      case LocalShellOpenRequested(:final instance):
        await _openLocalSession(instance);
      case LocalShellManageRequested(:final instance):
        _openLocalShellInstance(instance);
    }
  }

  Future<void> _handleMenu(MachineMenuChoice choice, SavedHost host) async {
    final action = choice.hostAction;
    if (action != null) {
      await _handleHostAction(action, host);
      return;
    }
    if (choice == MachineMenuChoice.shell) {
      await _pickWindowsShell();
      return;
    }
    await showCompanionSetup(context, host);
  }

  /// Windows: which shell "This computer" opens (new sessions use it).
  Future<void> _pickWindowsShell() async {
    final controller = widget.hostsController;
    final picked = await showDialog<WindowsShellKind>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Shell on this computer'),
        children: [
          RadioGroup<WindowsShellKind>(
            groupValue: controller.windowsShell,
            onChanged: (value) => Navigator.of(context).pop(value),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final kind in WindowsShellKind.values)
                  RadioListTile<WindowsShellKind>(
                    value: kind,
                    title: Text(kind.label),
                    subtitle: kind == WindowsShellKind.wsl
                        ? const Text('Local tmux, Herdr and agent hooks')
                        : null,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (picked != null) await controller.setWindowsShell(picked);
  }

  /// "+": the connect picker for the one shown machine, or a machine
  /// chooser first when several (or none) are shown.
  Future<void> _newSession() async {
    final shown = _shownHosts;
    if (shown.length == 1) {
      await _connect(shown.single, forcePicker: true);
      return;
    }
    final candidates = shown.isEmpty
        ? widget.hostsController.sortedMachines
        : shown;
    if (candidates.isEmpty) {
      await _openForm();
      return;
    }
    final host = await showAdaptiveModal<SavedHost>(
      kind: AdaptiveModalKind.dialog,
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.7,
          ),
          child: ListView(
            shrinkWrap: true,
            children: [
              const ListTile(
                title: Text(
                  'New session on',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
              for (final host in candidates)
                ListTile(
                  key: ValueKey('new-session-${host.id}'),
                  leading: Icon(
                    host.isThisComputer
                        ? Icons.computer_rounded
                        : Icons.dns_outlined,
                  ),
                  title: Text(host.name),
                  subtitle: Text(host.endpoint),
                  onTap: () => Navigator.of(context).pop(host),
                ),
            ],
          ),
        ),
      ),
    );
    if (host == null || !mounted) return;
    await _connect(host, forcePicker: true);
  }

  /// Opens (or activates) the Herdr session for [workspace] and focuses
  /// [pane] in it (or the whole workspace when [pane] is null).
  Future<void> _openPane(
    SavedHost host,
    HomeBoardWorkspace workspace,
    HomeBoardPane? pane,
  ) async {
    final flow = widget.connectFlow;
    if (flow != null) {
      // Lands on the exact workspace, tab and pane: reuses (and if needed
      // reconnects) an open Herdr tab, or attaches a new one focused there.
      final session = await flow.openAgentLocation(
        host,
        workspaceId: workspace.id,
        tabId: pane?.agent.tab ?? '',
        paneId: pane?.agent.pane ?? '',
        label: workspace.label,
      );
      if (!mounted) return;
      await _showSession(session, agent: pane?.agent);
      return;
    }
    final board = _boards?[host.id];
    final existing = _herdrSessionFor(host, workspace.id);
    if (existing != null) {
      widget.workspaceController.activate(existing);
      if (board != null) {
        if (pane != null) {
          unawaited(board.focusPane(pane.agent));
        } else {
          unawaited(board.focusWorkspace(workspace.id));
        }
      }
      await _showSession(existing, agent: pane?.agent);
      return;
    }
    if (pane != null && board != null) {
      // Focus over the socket before attaching, and once more after the
      // new client is up (its startup focuses the workspace).
      await board.focusPane(pane.agent);
      _refocusTimer?.cancel();
      _refocusTimer = Timer(widget.paneRefocusDelay, () {
        unawaited(board.focusPane(pane.agent));
      });
    }
    await _openTarget(
      host,
      ConnectTarget.herdr(workspaceId: workspace.id, label: workspace.label),
      agent: pane?.agent,
    );
  }

  /// An open Herdr session on [host], preferring one attached to
  /// [workspaceId].
  TerminalSessionController? _herdrSessionFor(
    SavedHost host,
    String workspaceId,
  ) {
    TerminalSessionController? anyHerdr;
    for (final session in _sessionsFor(host)) {
      final target = ConnectTarget.fromSessionHostId(session.host.id);
      if (target == null || target.kind != ConnectTargetKind.herdr) continue;
      if (target.name == workspaceId) return session;
      anyHerdr ??= session;
    }
    return anyHerdr;
  }

  /// Opens [target] on [host] and shows it (see [_showSession]; with
  /// [preferredView] false, always in the terminal).
  Future<void> _openTarget(
    SavedHost host,
    ConnectTarget target, {
    AgentInfo? agent,
    bool preferredView = true,
  }) async {
    unawaited(widget.hostsController.markConnected(host));
    final flow = widget.connectFlow;
    final TerminalSessionController session;
    if (flow != null) {
      session = flow.open(host, target);
    } else {
      session = widget.workspaceController.open(
        target.apply(host),
        startupCommand: target.startupCommand,
        target: target,
      );
    }
    if (!mounted) return;
    await _showSession(preferredView ? session : null, agent: agent);
  }

  /// Shows [session] (just opened or activated): the terminal, with Chat
  /// View on top when its pane runs a Claude session and it opens in Chat
  /// View, as soon as its agents are known (see [openPreferredChatView]).
  /// [agent] pins which Claude session. Its Terminal button leaves the
  /// terminal, at the agent's pane. Completes when the terminal page is
  /// left, like [_openTerminalWorkspace].
  Future<void> _showSession(
    TerminalSessionController? session, {
    AgentInfo? agent,
  }) {
    // Pushed first: Chat View goes over it and remembers it for back.
    final shown = _openTerminalWorkspace();
    if (session != null) {
      final attention = widget.agentAttention;
      final flow = widget.connectFlow;
      unawaited(
        openPreferredChatView(
          _actionContext,
          attention: attention,
          workspace: widget.workspaceController,
          session: session,
          agent: agent,
          herdr: flow?.herdr,
          onOpenTerminal: (host, agent) {
            if (flow != null) {
              unawaited(flow.openAgent(host, agent));
            } else {
              unawaited(attention.focusAgent(host.id, agent));
            }
          },
        ),
      );
    }
    return shown;
  }

  Future<void> _showSessionActions(TerminalSessionController session) async {
    final views = session.host.isLocal
        ? null
        : SessionViewScope.maybeOf(context);
    final continuity = ContinuityScope.maybeOf(context);
    final action = await showAdaptiveModal<_SessionAction>(
      kind: AdaptiveModalKind.menu,
      context: context,
      useSafeArea: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                session.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(session.host.endpoint),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.refresh_rounded),
              title: const Text('Reconnect'),
              onTap: () => Navigator.of(context).pop(_SessionAction.reconnect),
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline_rounded),
              title: const Text('Rename'),
              onTap: () => Navigator.of(context).pop(_SessionAction.rename),
            ),
            if (views != null)
              ListTile(
                key: const ValueKey('session-action-open-in'),
                leading: const Icon(Icons.forum_outlined),
                title: const Text('Open in…'),
                subtitle: Text(sessionViewSummary(views, session.host.id)),
                onTap: () => Navigator.of(context).pop(_SessionAction.openIn),
              ),
            if (continuity != null && continuity.active)
              ListTile(
                key: const ValueKey('session-action-continue-on'),
                leading: const Icon(Icons.devices_rounded),
                title: const Text('Continue on…'),
                subtitle: const Text('Where your other devices are'),
                onTap: () =>
                    Navigator.of(context).pop(_SessionAction.continueOn),
              ),
            ListTile(
              leading: const Icon(Icons.close_rounded),
              title: const Text('Close session'),
              onTap: () => Navigator.of(context).pop(_SessionAction.close),
            ),
          ],
        ),
      ),
    );
    switch (action) {
      case _SessionAction.reconnect:
        await session.disconnect();
        await session.connect();
      case _SessionAction.rename:
        await _renameSession(session);
      case _SessionAction.openIn:
        if (views != null && mounted) {
          await showSessionViewPicker(
            context,
            controller: views,
            sessionHostId: session.host.id,
            title: session.title,
          );
        }
      case _SessionAction.continueOn:
        await _showContinueOn();
      case _SessionAction.close:
        await widget.workspaceController.close(session);
      case null:
        break;
    }
  }

  Future<void> _renameSession(TerminalSessionController session) async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) => _RenameDialog(
        initial: session.customTitle ?? session.title,
        fallback: session.host.name,
      ),
    );
    if (name == null || !mounted) return;
    setState(() => session.rename(name));
  }

  /// A deep link (notification, widget, agent sheet) opened a session.
  void _handleTerminalRequest() {
    final opened = widget.connectFlow?.takeOpenedAgent();
    if (mounted && widget.workspaceController.hasSessions) {
      unawaited(_showSession(opened?.session, agent: opened?.agent));
    }
  }

  Future<void> _openTerminalWorkspace() async {
    if (_isShell) {
      // The shell's main area shows the terminal instead of a new route.
      _shell.showHome = false;
      return;
    }
    if (_terminalPageOpen) return;
    _terminalPageOpen = true;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        settings: terminalRouteSettings,
        builder: (_) => TerminalPage(
          workspace: widget.workspaceController,
          themeController: widget.themeController,
          sftpRepository: widget.sftpRepository,
          agentAttention: widget.agentAttention,
          hostKeyVerifier: widget.hostKeyVerifier,
          connectFlow: widget.connectFlow,
          homeBoards: _boards,
          hostChannels: widget.hostChannels,
        ),
      ),
    );
    _terminalPageOpen = false;
  }

  Future<void> _openLocalShellSetup() async {
    final request = await Navigator.of(context).push<LocalShellSetupRequest>(
      MaterialPageRoute(
        builder: (_) =>
            LocalShellSetupPage(controller: widget.localShellController),
      ),
    );
    if (request == null) return;
    unawaited(
      widget.localShellController.installNew(
        request.distroId,
        name: request.name,
      ),
    );
  }

  void _openLocalShellInstance(LocalShellInstance instance) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => LocalShellInstancePage(
          controller: widget.localShellController,
          instanceId: instance.id,
          onOpenSession: (instance) =>
              _openLocalSession(instance, forceNew: true),
          onCloseSessions: _closeLocalSession,
        ),
      ),
    );
  }

  Future<void> _openLocalSession(
    LocalShellInstance instance, {
    bool forceNew = false,
  }) async {
    if (widget.localShellController.sharedStorageFeatureEnabled &&
        !widget.localShellController.sharedStorageAccessGranted) {
      await widget.localShellController.requestSharedStorageAccess();
      if (!widget.localShellController.sharedStorageAccessGranted) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Grant file access, then open the shell again.'),
          ),
        );
        return;
      }
    }
    final existing = widget.workspaceController.sessions
        .where(
          (session) =>
              localShellInstanceIdFromHostId(session.host.id) == instance.id,
        )
        .toList();
    if (!forceNew && existing.isNotEmpty) {
      widget.workspaceController.activate(existing.first);
    } else {
      widget.workspaceController.open(
        widget.localShellController.localHost(
          instance,
          sessionNumber: existing.length + 1,
        ),
      );
    }
    unawaited(widget.localShellController.markOpened(instance.id));
    if (!mounted) return;
    await _openTerminalWorkspace();
  }

  Future<void> _closeLocalSession(String instanceId) async {
    final sessions = widget.workspaceController.sessions.where(
      (session) =>
          localShellInstanceIdFromHostId(session.host.id) == instanceId,
    );
    for (final session in List.of(sessions)) {
      await widget.workspaceController.close(session);
    }
  }

  Future<void> _openFiles(SavedHost host) async {
    await widget.hostsController.markConnected(host);
    if (!mounted) return;
    await openSftpBrowser(
      context,
      host: host,
      repository: widget.sftpRepository,
      fileExport: widget.fileExport,
      themeController: widget.themeController,
      bookmarksRepository: widget.sftpBookmarksRepository,
    );
  }

  Future<void> _connect(SavedHost host, {bool forcePicker = false}) async {
    final flow = widget.connectFlow;
    final TerminalSessionController session;
    if (flow == null) {
      await widget.hostsController.markConnected(host);
      session = widget.workspaceController.open(host);
    } else {
      final connected = await flow.connect(
        context,
        host,
        forcePicker: forcePicker,
      );
      if (connected == null) return;
      session = connected;
    }
    if (!mounted) return;
    await _showSession(session);
  }

  Future<void> _lock() async {
    // Locking closes every session; unlocking brings them back.
    await widget.sessionRestore?.holdForLock();
    await widget.workspaceController.closeAll();
    widget.lockController.lock();
  }

  Future<void> _openForm([SavedHost? host]) async {
    final savedHost = await openHostForm(
      context,
      host: host,
      themeController: widget.themeController,
    );
    if (savedHost != null) {
      await widget.hostsController.upsert(savedHost);
      final filter = _filter;
      if (host == null && mounted && !filter.isAll) {
        // A newly added machine joins the machines on screen.
        _setFilter(MachineFilter({...filter.keys, savedHost.id}));
      }
    }
  }

  Future<void> _handleHostAction(HostAction action, SavedHost host) async {
    switch (action) {
      case HostAction.connectTo:
        await _connect(host, forcePicker: true);
      case HostAction.files:
        await _openFiles(host);
      case HostAction.edit:
        await _openForm(host);
      case HostAction.duplicate:
        await _duplicate(host);
      case HostAction.copyAddress:
        await Clipboard.setData(ClipboardData(text: host.endpoint));
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Copied ${host.endpoint}')));
      case HostAction.delete:
        await _confirmDelete(host);
    }
  }

  Future<void> _duplicate(SavedHost host) async {
    final keepSecrets = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Duplicate machine'),
        content: const Text(
          'Copy the saved password and key material into the new machine?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Without secrets'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Copy secrets'),
          ),
        ],
      ),
    );
    if (keepSecrets == null) return;
    final base = keepSecrets
        ? host
        : host.copyWith(password: '', privateKey: '', passphrase: '');
    await widget.hostsController.upsert(
      base.copyWith(
        id: const Uuid().v4(),
        name: '${host.name} Copy',
        clearLastConnectedAt: true,
      ),
    );
  }

  Future<void> _confirmDelete(SavedHost host) async {
    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete machine?'),
        content: Text('Conductore will forget “${host.name}”.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (shouldDelete ?? false) {
      await widget.hostsController.remove(host);
      final keys = _preferences.machineFilter;
      if (keys.contains(host.id) && mounted) {
        _setFilter(MachineFilter({...keys}..remove(host.id)));
      }
    }
  }
}

enum _SessionAction { reconnect, rename, openIn, continueOn, close }

class _MachineSectionHeader extends StatelessWidget {
  const _MachineSectionHeader();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Saved machines',
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          'SSH and Mosh connections you have saved.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
            height: 1.25,
          ),
        ),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label, this.detail, this.trailing});

  final String label;
  final String? detail;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        HomeGridMetrics.horizontalPadding + 2,
        trailing == null ? 14 : 6,
        6,
        trailing == null ? 4 : 0,
      ),
      child: Row(
        children: [
          Text(
            label,
            style: theme.textTheme.titleSmall?.copyWith(
              color: muted,
              fontWeight: FontWeight.w500,
              letterSpacing: 1.2,
            ),
          ),
          if (detail != null) ...[
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                detail!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
            ),
          ] else
            const Spacer(),
          ?trailing,
        ],
      ),
    );
  }
}

/// The sessions' layout menu: two-column tiles, large tiles, or rows.
class _SessionsViewMenu extends StatelessWidget {
  const _SessionsViewMenu({required this.value, required this.onChanged});

  final HomeSessionsView value;
  final ValueChanged<HomeSessionsView> onChanged;

  static IconData iconFor(HomeSessionsView view) => switch (view) {
    HomeSessionsView.grid => Icons.grid_view_rounded,
    HomeSessionsView.large => Icons.view_agenda_outlined,
    HomeSessionsView.list => Icons.view_list_rounded,
  };

  static String labelFor(HomeSessionsView view) => switch (view) {
    HomeSessionsView.grid => 'Grid',
    HomeSessionsView.large => 'Large tiles',
    HomeSessionsView.list => 'List',
  };

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<HomeSessionsView>(
      key: const ValueKey('sessions-view-menu'),
      tooltip: 'Layout: ${labelFor(value)}',
      initialValue: value,
      icon: Icon(iconFor(value)),
      onSelected: onChanged,
      itemBuilder: (context) => [
        for (final view in HomeSessionsView.values)
          PopupMenuItem(
            value: view,
            child: Row(
              children: [
                Icon(iconFor(view), size: 18),
                const SizedBox(width: 10),
                Text(labelFor(view)),
              ],
            ),
          ),
      ],
    );
  }
}

/// Machine name above its part of "Other workspaces" when several
/// machines are shown.
class _MachineGroupHeader extends StatelessWidget {
  const _MachineGroupHeader({required this.name, super.key});

  final String name;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        HomeGridMetrics.horizontalPadding + 2,
        8,
        16,
        2,
      ),
      child: Row(
        children: [
          Icon(Icons.dns_outlined, size: 15, color: muted),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.onSurface,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.initial, required this.fallback});

  final String initial;
  final String fallback;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
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
      title: const Text('Rename session'),
      content: TextField(
        controller: _text,
        autofocus: true,
        decoration: InputDecoration(hintText: widget.fallback),
        onSubmitted: (value) => Navigator.of(context).pop(value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(''),
          child: const Text('Reset'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_text.text),
          child: const Text('Rename'),
        ),
      ],
    );
  }
}
