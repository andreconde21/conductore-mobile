import 'dart:async';

import 'package:conduit/core/diagnostics/app_error_log.dart';
import 'package:conduit/core/platform_features.dart';
import 'package:conduit/core/presentation/adaptive_modal.dart';
import 'package:conduit/core/presentation/multiplexer_icon.dart';
import 'package:conduit/core/presentation/system_navigation_insets.dart';
import 'package:conduit/core/secure_storage.dart';
import 'package:conduit/core/telemetry/telemetry_setup.dart';
import 'package:conduit/core/telemetry/telemetry_terms.dart';
import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/core/theme/app_theme.dart';
import 'package:conduit/core/theme/omarchy_theme_sync_controller.dart';
import 'package:conduit/core/theme/theme_controller.dart';
import 'package:conduit/core/theme/theme_licenses.dart';
import 'package:conduit/core/theme/theme_preferences_repository.dart';
import 'package:conduit/features/agent_attention/data/conductore_host_attention_provider.dart';
import 'package:conduit/features/agent_attention/data/herdr_attention_provider.dart';
import 'package:conduit/features/agent_attention/data/platform_agent_notifier.dart';
import 'package:conduit/features/agent_attention/data/ssh_agent_command_runner.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/agent_attention/presentation/agent_notification_open_listener.dart';
import 'package:conduit/features/agent_attention/presentation/agent_permission_action_listener.dart';
import 'package:conduit/features/app_lock/data/local_app_authenticator.dart';
import 'package:conduit/features/app_lock/presentation/app_lock_controller.dart';
import 'package:conduit/features/app_lock/presentation/lock_page.dart';
import 'package:conduit/features/backup/data/app_backup_service.dart';
import 'package:conduit/features/companion_setup/presentation/companion_setup_controller.dart';
import 'package:conduit/features/home_widget/data/platform_agent_status_widget_channel.dart';
import 'package:conduit/features/home_widget/presentation/agent_status_launch_listener.dart';
import 'package:conduit/features/home_widget/presentation/agent_status_widget_pusher.dart';
import 'package:conduit/features/hosts/data/secure_saved_hosts_repository.dart';
import 'package:conduit/features/hosts/presentation/hosts_controller.dart';
import 'package:conduit/features/hosts/presentation/hosts_page.dart';
import 'package:conduit/features/local_shell/data/local_terminal_repository.dart';
import 'package:conduit/features/local_shell/local_shell_licenses.dart';
import 'package:conduit/features/local_shell/presentation/local_shell_controller.dart';
import 'package:conduit/features/session_navigation/data/secure_session_view_preferences_repository.dart';
import 'package:conduit/features/session_navigation/presentation/session_view_controller.dart';
import 'package:conduit/features/sessions/data/secure_connect_preferences_repository.dart';
import 'package:conduit/features/sessions/data/secure_session_snapshot_repository.dart';
import 'package:conduit/features/sessions/presentation/session_connect_flow.dart';
import 'package:conduit/features/sessions/presentation/session_restore_controller.dart';
import 'package:conduit/features/settings/presentation/settings_services.dart';
import 'package:conduit/features/sftp/data/dart_ssh_sftp_repository.dart';
import 'package:conduit/features/sftp/data/file_picker_file_export.dart';
import 'package:conduit/features/sftp/data/secure_sftp_bookmarks_repository.dart';
import 'package:conduit/features/sftp/domain/file_export.dart';
import 'package:conduit/features/sftp/domain/sftp_bookmarks_repository.dart';
import 'package:conduit/features/sftp/domain/sftp_repository.dart';
import 'package:conduit/features/share_target/data/platform_share_target_source.dart';
import 'package:conduit/features/share_target/data/sftp_share_uploader.dart';
import 'package:conduit/features/share_target/presentation/share_target_controller.dart';
import 'package:conduit/features/share_target/presentation/share_target_host.dart';
import 'package:conduit/features/share_target/presentation/share_target_scope.dart';
import 'package:conduit/features/sync/data/app_local_sync_store.dart';
import 'package:conduit/features/sync/data/ssh_sync_hub.dart';
import 'package:conduit/features/sync/data/sync_state_store.dart';
import 'package:conduit/features/sync/domain/local_data_changes.dart';
import 'package:conduit/features/sync/presentation/sync_controller.dart';
import 'package:conduit/features/sync/presentation/sync_scope.dart';
import 'package:conduit/features/terminal/data/connectivity_plus_network.dart';
import 'package:conduit/features/terminal/data/dart_ssh_terminal_repository.dart';
import 'package:conduit/features/terminal/data/mosh_terminal_repository.dart';
import 'package:conduit/features/terminal/data/routing_terminal_repository.dart';
import 'package:conduit/features/terminal/data/secure_host_key_verifier.dart';
import 'package:conduit/features/terminal/data/secure_recent_directories_store.dart';
import 'package:conduit/features/terminal/domain/host_key_verifier.dart';
import 'package:conduit/features/terminal/domain/ssh_terminal_repository.dart';
import 'package:conduit/features/terminal/presentation/host_key_prompt_coordinator.dart';
import 'package:conduit/features/terminal/presentation/recent_directories_controller.dart';
import 'package:conduit/features/terminal/presentation/recent_directory_tracker.dart';
import 'package:conduit/features/terminal/presentation/terminal_background_keepalive.dart';
import 'package:conduit/features/terminal/presentation/terminal_page.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:conduit/features/this_computer/data/desktop_terminal_repository.dart';
import 'package:conduit/features/this_computer/data/device_local_sync.dart';
import 'package:conduit/features/this_computer/data/host_channels.dart';
import 'package:conduit/features/this_computer/data/local_agent_command_runner.dart';
import 'package:conduit/features/this_computer/data/local_file_repository.dart';
import 'package:conduit/features/this_computer/data/secure_this_computer_store.dart';
import 'package:conduit/features/this_computer/data/self_machine_matcher.dart';
import 'package:conduit/features/this_computer/presentation/self_machine_watcher.dart';
import 'package:conduit/features/usage/data/usage_preferences.dart';
import 'package:conduit/features/usage/presentation/usage_controller.dart';
import 'package:conduit/features/usage/presentation/usage_widgets.dart';
import 'package:conduit/features/voice/presentation/dictation_controller.dart';
import 'package:conduit/features/voice/presentation/read_aloud_controller.dart';
import 'package:conduit/features/voice/presentation/voice_services.dart';
import 'package:conduit/features/voice/presentation/voice_settings_scope.dart';
import 'package:conduit/features/voice_guide/data/companion_guide_brain.dart';
import 'package:conduit/features/voice_guide/data/guide_wake_channel.dart';
import 'package:conduit/features/voice_guide/presentation/app_guide.dart';
import 'package:conduit/features/voice_guide/presentation/guide_controller.dart';
import 'package:conduit/features/voice_guide/presentation/guide_overlay.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // A release build otherwise shows a blank page for a widget that failed
  // to build: keep the errors, and show them with a way to copy them.
  AppErrorLog.instance.install();
  AdaptiveModalPointer.install();
  registerLocalShellLicenses();
  registerThemeLicenses();
  registerMultiplexerLogoLicenses();
  unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));

  const secureStorage = conductoreSecureStorage;
  final themeController = ThemeController(
    const ThemePreferencesRepository(secureStorage),
  );
  final lockController = AppLockController(
    LocalAppAuthenticator(),
    enabled: PlatformFeatures.appLock,
  );
  // "This computer" (desktops): the device itself as a machine, with
  // per-device settings that never join the synced machine list.
  final hostsController = HostsController(
    const SecureSavedHostsRepository(secureStorage),
    thisComputerStore: PlatformFeatures.thisComputer
        ? const SecureThisComputerStore(secureStorage)
        : null,
  );
  // Crash reports and anonymous usage counts (Settings › Privacy).
  startTelemetry(
    storage: secureStorage,
    hosts: hostsController,
    theme: themeController,
  );
  final promptCoordinator = HostKeyPromptCoordinator();
  final hostKeyVerifier = SecureHostKeyVerifier(
    secureStorage,
    promptCoordinator,
  );
  final localShellController = LocalShellController();
  // Commands, files and port forwards per machine: SSH, or the desktop
  // itself for "This computer".
  final hostChannels = HostChannels(
    hostKeyVerifier: hostKeyVerifier,
    localRunner: () => LocalAgentCommandRunner(
      windowsShell: () => hostsController.windowsShell,
    ),
    sshFiles: DartSshSftpRepository(hostKeyVerifier),
    localFiles: const LocalFileRepository(),
  );
  final terminalRepository = RoutingTerminalRepository(
    ssh: DartSshTerminalRepository(hostKeyVerifier),
    mosh: MoshTerminalRepository(
      hostKeyVerifier,
      cleanupRunner: (host) => SshAgentCommandRunner(hostKeyVerifier, host),
    ),
    local: LocalTerminalRepository(
      resolveLaunch: localShellController.requireLaunch,
    ),
    thisComputer: PlatformFeatures.thisComputer
        ? DesktopTerminalRepository(
            windowsShell: () => hostsController.windowsShell,
          )
        : null,
  );
  final workspaceController = TerminalWorkspaceController(
    terminalRepository,
    ConnectivityPlusNetwork(),
  );
  final sftpRepository = hostChannels.files;
  const sftpBookmarksRepository = SecureSftpBookmarksRepository(secureStorage);
  final agentAttention = AgentAttentionController(
    workspace: workspaceController,
    runnerFactory: hostChannels.runner,
    provider: const HerdrAttentionProvider(),
    companionProvider: const ConductoreHostAttentionProvider(),
    notifier: const PlatformAgentAttentionNotifier(),
    persistMonitoringEnabled: (savedHostId) async {
      final host = hostsController.findById(savedHostId);
      if (host != null && !host.agentAttentionEnabled) {
        await hostsController.upsert(
          host.copyWith(agentAttentionEnabled: true),
        );
      }
    },
  );
  final recentDirectories = RecentDirectoriesController(
    const SecureRecentDirectoriesStore(secureStorage),
  );
  final connectFlow = SessionConnectFlow(
    hostsController: hostsController,
    workspace: workspaceController,
    runnerFactory: hostChannels.runner,
    preferences: const SecureConnectPreferencesRepository(secureStorage),
    recentDirectories: recentDirectories,
  );
  // Collects recent directories (OSC 7, tmux on detach, companion agents)
  // for the app's whole lifetime, like the widget pusher below.
  RecentDirectoryTracker(
    workspace: workspaceController,
    directories: recentDirectories,
    runnerFactory: hostChannels.runner,
    agentAttention: agentAttention,
  );
  // Mirrors the agent dashboard onto the Android home-screen widget and
  // quick-settings tile for the app's whole lifetime.
  // Usage at a glance (companion `usage`): the home bar, the Agents
  // panel's Usage tab, the widget's limit rings and the 80 % alert.
  final usage = UsageController(
    source: AttentionUsageHostSource(
      attention: agentAttention,
      hosts: hostsController,
    ),
    preferences: const SecureUsagePreferencesStore(secureStorage),
    notifier: const PlatformAgentAttentionNotifier(),
  );
  // Crash reports never carry Claude account names (cswap aliases, masked
  // emails).
  addTelemetryTerms(() => usage.summary.accountTerms);
  AgentStatusWidgetPusher.forController(
    agentAttention,
    usage: usage,
    channel: PlatformAgentStatusWidgetChannel.instance,
  ).start();
  const fileExport = FilePickerFileExport();
  final shareTarget = ShareTargetController(
    source: PlatformShareTargetSource(),
    workspace: workspaceController,
    uploader: SftpShareUploader(sftpRepository),
  );

  // Agent hooks screen: companion status per machine, shared by every
  // entry point through the scope around the whole app.
  final companionSetup = CompanionSetupController(
    runnerFactory: hostChannels.runner,
    sftpRepository: sftpRepository,
  );

  // Follows a machine's Omarchy theme (Appearance settings); syncs once
  // the saved theme is loaded, then on every resume.
  final omarchyThemeSync = OmarchyThemeSyncController(
    theme: themeController,
    hosts: () async {
      await hostsController.firstLoad;
      return hostsController.machines;
    },
    // A synced machine that is this desktop reads as "This computer".
    findHost: (id) async {
      await hostsController.selfMachineKnown();
      return hostsController.findById(id);
    },
    runnerFactory: hostChannels.runner,
  );
  themeController.omarchySync = omarchyThemeSync;
  final themeLoaded = themeController.load();
  unawaited(themeLoaded.then((_) => omarchyThemeSync.start()));

  // Keeps the open-session list in secure storage and brings it back
  // after the app lock (setting: Restore sessions on launch).
  late final SessionRestoreController sessionRestore;
  sessionRestore = SessionRestoreController(
    workspace: workspaceController,
    repository: const SecureSessionSnapshotRepository(secureStorage),
    findHost: (hostId) async {
      await hostsController.selfMachineKnown();
      return hostsController.findById(hostId);
    },
    ready: themeLoaded.then((_) {
      sessionRestore.enabled = themeController.restoreSessionsOnLaunch;
    }),
  );
  themeController.addListener(
    () => sessionRestore.enabled = themeController.restoreSessionsOnLaunch,
  );
  // Backup imports and sync pulls announce here; the home page reloads
  // what it cached (trusted keys, machine filter) and its boards.
  final localDataChanges = LocalDataChanges();
  // Desktops: a saved machine that is this device (the phone's SSH entry
  // for this PC, synced here) folds into "This computer". Phones skip it.
  if (PlatformFeatures.thisComputer) {
    unawaited(
      SelfMachineWatcher(
        hosts: hostsController,
        matcher: SelfMachineMatcher(),
        trustedKeys: hostKeyVerifier.loadTrustedKeys,
        networkChanges: ConnectivityPlusNetwork().onNetworkChanged,
        dataChanges: localDataChanges,
      ).start(),
    );
  }
  // This device's data as sync records: file backups and device sync
  // (Settings › Sync) read and write the app through it.
  final localSyncStore = AppLocalSyncStore(
    hosts: hostsController,
    theme: themeController,
    hostKeys: hostKeyVerifier,
    // "This computer" is per device: its connect-picker memory and its
    // sessions stay out of backups and sync.
    connectPreferences: const DeviceLocalJsonMapStore(
      SecureJsonMapStore(
        secureStorage,
        SecureConnectPreferencesRepository.storageKey,
      ),
    ),
    recentDirectoriesStore: const DeviceLocalJsonMapStore(
      SecureJsonMapStore(
        secureStorage,
        SecureRecentDirectoriesStore.storageKey,
      ),
    ),
    recentDirectories: recentDirectories,
    sessions: const DeviceLocalSessionSnapshots(
      SecureSessionSnapshotRepository(secureStorage),
    ),
    ready: themeLoaded,
    changes: localDataChanges,
  );
  // Settings › Sync: this device's data, end-to-end encrypted, through
  // one saved machine (the hub) over the same SSH/SFTP stack.
  final syncController = SyncController(
    state: const SecureSyncStateStore(secureStorage),
    local: localSyncStore,
    hubFactory: (host, deviceId) => SshSyncHub(
      host: host,
      runner: SshAgentCommandRunner(hostKeyVerifier, host),
      sftp: sftpRepository,
      deviceId: deviceId,
    ),
    hosts: hostsController,
    hostKeys: hostKeyVerifier,
    changeSources: [
      hostsController,
      themeController,
      recentDirectories,
      sessionRestore,
    ],
    platform: defaultTargetPlatform.name,
    defaultDeviceName: defaultSyncDeviceName(),
  );
  unawaited(themeLoaded.then((_) => syncController.start()));
  final backupService = AppBackupService(
    hostsController: hostsController,
    themeController: themeController,
    hostKeyVerifier: hostKeyVerifier,
    localStore: localSyncStore,
    changes: localDataChanges,
    syncHubHostId: () => syncController.config?.hubHostId,
  );
  unawaited(shareTarget.start());

  // "Open Claude sessions in" and the per-session choices, for every page.
  final sessionViews = SessionViewController(
    const SecureSessionViewPreferencesRepository(secureStorage),
  );
  // "This computer" follows the choices made for the synced machine that
  // is this device, until it has its own.
  sessionViews.fallbackHostOf = hostsController.fallbackHostIdFor;
  loadSessionViews(sessionViews);

  // The voice guide (CON-007): hands-free commands from the Guide button,
  // its quick-settings tile or the headset. Its own mic and speaker share
  // the platform recognizer and voice with the chats (one listens at a
  // time).
  final navigatorKey = GlobalKey<NavigatorState>();
  // One recognizer and one voice for the whole app (see VoiceServices).
  final voice = VoiceServices.platform();
  GuideController? guide;
  final guideRecognizer = voice.recognizer;
  final guideTts = voice.tts;
  if (guideRecognizer != null && guideTts != null) {
    String guideLanguage() {
      final own = themeController.voice.guide.language;
      return own.isNotEmpty ? own : themeController.speechLanguage;
    }

    final guideNavigator = AppGuideNavigator(
      navigatorKey: navigatorKey,
      workspace: workspaceController,
      attention: agentAttention,
      hosts: hostsController,
      connectFlow: connectFlow,
      sessionViews: sessionViews,
    );
    guide = GuideController(
      dictation: DictationController(guideRecognizer, language: guideLanguage),
      speaker: ReadAloudController(
        tts: guideTts,
        preferences: () {
          final voice = themeController.voice;
          final own = voice.guide.language;
          // A guide language of its own speaks with that language's
          // best voice, not the chats' voice.
          return own.isEmpty
              ? voice
              : voice.copyWith(ttsLanguage: own, ttsVoice: '');
        },
        dictationLanguage: () => themeController.speechLanguage,
      ),
      world: () => buildGuideWorld(
        attention: agentAttention,
        hosts: hostsController,
        screen: guideNavigator.screen,
      ),
      approvals: attentionApprovalActions(agentAttention),
      navigator: guideNavigator,
      messenger: AttentionGuideMessenger(agentAttention),
      preferences: () => themeController.voice.guide,
      speechLanguage: () => themeController.speechLanguage,
      brain: CompanionGuideBrain(
        candidates: () => guideBrainCandidates(
          attention: agentAttention,
          hosts: hostsController,
          preferredHostId: themeController.voice.guide.brainHostId,
        ),
        runnerFor: agentAttention.runnerFor,
      ),
      usage: (code) => guideUsageText(usage.summary, code),
      accounts: UsageGuideAccounts(usage),
      locked: () => !lockController.isUnlocked,
    );
  }

  // Settings from any route (the terminal's ⋮ menu): the same services
  // the home page's gear passes.
  final settingsServices = SettingsServices(
    theme: themeController,
    backupService: backupService,
    hostsController: hostsController,
    hostKeyVerifier: hostKeyVerifier,
    agentAttention: agentAttention,
    onLockNow: () async {
      // Locking closes every session; unlocking brings them back.
      await sessionRestore.holdForLock();
      await workspaceController.closeAll();
      lockController.lock();
    },
  );

  runApp(
    SettingsScope(
      services: settingsServices,
      child: SyncScope(
        controller: syncController,
        child: VoiceSettingsScope(
          settings: themeController,
          child: SessionViewScope(
            controller: sessionViews,
            child: CompanionSetupScope(
              controller: companionSetup,
              agentAttention: agentAttention,
              child: UsageScope(
                controller: usage,
                child: ConduitApp(
                  themeController: themeController,
                  lockController: lockController,
                  hostsController: hostsController,
                  terminalRepository: terminalRepository,
                  workspaceController: workspaceController,
                  localShellController: localShellController,
                  hostKeyVerifier: hostKeyVerifier,
                  promptCoordinator: promptCoordinator,
                  sftpRepository: sftpRepository,
                  sftpBookmarksRepository: sftpBookmarksRepository,
                  agentAttention: agentAttention,
                  backupService: backupService,
                  fileExport: fileExport,
                  connectFlow: connectFlow,
                  shareTarget: shareTarget,
                  sessionRestore: sessionRestore,
                  localDataChanges: localDataChanges,
                  hostChannels: hostChannels,
                  navigatorKey: navigatorKey,
                  voice: voice,
                  guide: guide,
                  guideWake: guide == null ? null : GuideWakeChannel(),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class ConduitApp extends StatefulWidget {
  const ConduitApp({
    required this.themeController,
    required this.lockController,
    required this.hostsController,
    required this.terminalRepository,
    required this.workspaceController,
    required this.localShellController,
    required this.hostKeyVerifier,
    required this.promptCoordinator,
    required this.sftpRepository,
    required this.sftpBookmarksRepository,
    required this.agentAttention,
    required this.backupService,
    required this.fileExport,
    this.connectFlow,
    this.shareTarget,
    this.sessionRestore,
    this.localDataChanges,
    this.hostChannels,
    this.navigatorKey,
    this.voice,
    this.guide,
    this.guideWake,
    super.key,
  });

  final ThemeController themeController;
  final AppLockController lockController;
  final HostsController hostsController;
  final SshTerminalRepository terminalRepository;
  final TerminalWorkspaceController workspaceController;
  final LocalShellController localShellController;
  final HostKeyVerifier hostKeyVerifier;
  final HostKeyPromptCoordinator promptCoordinator;
  final SftpRepository sftpRepository;
  final SftpBookmarksRepository sftpBookmarksRepository;
  final AgentAttentionController agentAttention;
  final AppBackupService backupService;
  final FileExport fileExport;
  final SessionConnectFlow? connectFlow;

  /// Share-to-agent flow; null disables the Android share target.
  final ShareTargetController? shareTarget;
  final SessionRestoreController? sessionRestore;

  /// Backup imports and sync pulls, for the pages that cache saved data.
  final LocalDataChanges? localDataChanges;

  /// Commands and port forwards per machine (SSH or This computer); null
  /// means SSH only.
  final HostChannels? hostChannels;

  /// The app's navigator, for the voice guide to move around.
  final GlobalKey<NavigatorState>? navigatorKey;

  /// The app's one recognizer and voice; null lets each page make its
  /// own (tests).
  final VoiceServices? voice;

  /// The voice guide; null on platforms without speech.
  final GuideController? guide;

  /// The headset-button wake for [guide].
  final GuideWakeChannel? guideWake;

  @override
  State<ConduitApp> createState() => _ConduitAppState();
}

class _ConduitAppState extends State<ConduitApp> with WidgetsBindingObserver {
  final _backgroundKeepalive = const TerminalBackgroundKeepalive();
  AppLifecycleState _lifecycleState = AppLifecycleState.resumed;
  bool _keepaliveRunning = false;
  int _keepaliveSessionCount = 0;
  bool _notificationPermissionRequested = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.workspaceController.addListener(_syncBackgroundKeepalive);
    widget.themeController.addListener(_syncTerminalPreferences);
    widget.lockController.addListener(_syncShareTargetGate);
    _syncTerminalPreferences();
    _syncShareTargetGate();
    final guide = widget.guide;
    if (guide != null) {
      widget.guideWake?.setListener(guide.start);
      widget.themeController.addListener(_syncGuideWake);
      widget.lockController.addListener(_stopGuideWhenLocked);
      _syncGuideWake();
    }
  }

  // Locking closes every session: the guide stops with them.
  void _stopGuideWhenLocked() {
    if (!widget.lockController.isUnlocked) widget.guide?.stop();
  }

  // "Wake with headset button" follows the guide's settings.
  void _syncGuideWake() {
    final prefs = widget.themeController.voice.guide;
    unawaited(
      widget.guideWake?.setHeadsetWake(prefs.enabled && prefs.headsetWake),
    );
  }

  // Shares wait behind the lock screen instead of opening pickers over it.
  void _syncShareTargetGate() {
    widget.shareTarget?.setGateOpen(widget.lockController.isUnlocked);
  }

  void _syncTerminalPreferences() {
    widget.workspaceController.setEnterSequence(
      widget.themeController.terminalEnterSequence,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
    _syncBackgroundKeepalive();
    _syncAgentAttention(state);

    if (state == AppLifecycleState.resumed) {
      for (final session in widget.workspaceController.sessions) {
        session.forceResize();
      }
    }
  }

  void _syncAgentAttention(AppLifecycleState state) {
    // On Android the keepalive foreground service holds connections open in
    // the background, which is exactly when attention notifications matter,
    // so polling continues. Elsewhere backgrounded sockets die anyway, so
    // polling pauses until the app returns.
    final active =
        state == AppLifecycleState.resumed ||
        (defaultTargetPlatform == TargetPlatform.android &&
            state != AppLifecycleState.detached);
    widget.agentAttention.setAppActive(active);
    // The companion long-poll only runs while the app is on screen; in the
    // background the periodic poll (and its notifications) is enough.
    widget.agentAttention.setAppForeground(
      state == AppLifecycleState.resumed || state == AppLifecycleState.inactive,
    );
  }

  void _syncBackgroundKeepalive() {
    if (!PlatformFeatures.backgroundKeepalive) {
      return;
    }
    final sessionCount = widget.workspaceController.liveSessionCount;
    _maybeRequestNotificationPermission(sessionCount);
    final shouldRun =
        sessionCount > 0 &&
        (_lifecycleState == AppLifecycleState.hidden ||
            _lifecycleState == AppLifecycleState.paused);

    if (shouldRun == _keepaliveRunning &&
        (!shouldRun || sessionCount == _keepaliveSessionCount)) {
      return;
    }

    _keepaliveRunning = shouldRun;
    _keepaliveSessionCount = shouldRun ? sessionCount : 0;
    unawaited(
      (shouldRun
              ? _backgroundKeepalive.start(sessionCount: sessionCount)
              : _backgroundKeepalive.stop())
          .catchError((_) {
            _keepaliveRunning = !shouldRun;
            _keepaliveSessionCount = 0;
          }),
    );
  }

  void _maybeRequestNotificationPermission(int sessionCount) {
    if (_notificationPermissionRequested ||
        sessionCount == 0 ||
        _lifecycleState != AppLifecycleState.resumed ||
        defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    _notificationPermissionRequested = true;
    unawaited(
      _backgroundKeepalive.requestNotificationPermission().catchError((_) {}),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.workspaceController.removeListener(_syncBackgroundKeepalive);
    widget.themeController.removeListener(_syncTerminalPreferences);
    widget.lockController.removeListener(_syncShareTargetGate);
    widget.themeController.removeListener(_syncGuideWake);
    widget.lockController.removeListener(_stopGuideWhenLocked);
    widget.guideWake?.setListener(null);
    if (PlatformFeatures.backgroundKeepalive) {
      unawaited(_backgroundKeepalive.stop().catchError((_) {}));
    }
    super.dispose();
  }

  Widget _buildTerminalPage(BuildContext context) {
    return TerminalPage(
      workspace: widget.workspaceController,
      themeController: widget.themeController,
      sftpRepository: widget.sftpRepository,
      agentAttention: widget.agentAttention,
      connectFlow: widget.connectFlow,
      hostChannels: widget.hostChannels,
    );
  }

  /// Wraps the home page with the share-to-agent UI (banner, pickers).
  Widget _wrapShareTargetHost(Widget home) {
    final shareTarget = widget.shareTarget;
    if (shareTarget == null) {
      return home;
    }
    return ShareTargetHost(
      controller: shareTarget,
      workspace: widget.workspaceController,
      terminalPageBuilder: _buildTerminalPage,
      child: home,
    );
  }

  Widget _wrapShareTargetScope(Widget app) {
    final shareTarget = widget.shareTarget;
    if (shareTarget == null) {
      return app;
    }
    return ShareTargetScope(controller: shareTarget, child: app);
  }

  /// Notification taps open the agent's exact place (Herdr workspace, tab
  /// and pane) through the connect flow.
  Widget _wrapNotificationOpen(Widget home) {
    final flow = widget.connectFlow;
    if (flow == null) {
      return home;
    }
    return AgentNotificationOpenListener(
      source: PlatformAgentOpenRequests.instance,
      findHost: (hostId) async {
        await widget.hostsController.selfMachineKnown();
        return widget.hostsController.findById(hostId);
      },
      onOpen: (host, agent) async {
        await flow.openAgent(host, agent);
      },
      child: home,
    );
  }

  AppPalette? _themedPalette;
  late ThemeData _lightTheme;
  late ThemeData _darkTheme;

  /// Builds the two app themes only when the palette changed: the theme
  /// controller also notifies for settings that change no colours.
  void _updateThemes(AppPalette palette) {
    if (palette == _themedPalette) return;
    _themedPalette = palette;
    _lightTheme = AppTheme.build(
      brightness: Brightness.light,
      palette: palette,
    );
    _darkTheme = AppTheme.build(brightness: Brightness.dark, palette: palette);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.themeController,
      builder: (context, _) {
        _updateThemes(widget.themeController.palette);
        final app = MaterialApp(
          navigatorKey: widget.navigatorKey,
          title: 'Conductore',
          debugShowCheckedModeBanner: false,
          theme: _lightTheme,
          darkTheme: _darkTheme,
          themeMode: widget.themeController.effectiveThemeMode,
          builder: (context, child) {
            final overlayStyle = AppTheme.systemUiOverlayStyle(
              Theme.of(context).brightness,
            );
            SystemChrome.setSystemUIOverlayStyle(overlayStyle);
            final content = AnnotatedRegion<SystemUiOverlayStyle>(
              value: overlayStyle,
              child: Stack(
                children: [
                  child ?? const SizedBox.shrink(),
                  AndroidThreeButtonNavigationBackground(
                    color: Theme.of(context).scaffoldBackgroundColor,
                  ),
                  if (widget.guide case final guide?)
                    GuideOverlay(controller: guide),
                ],
              ),
            );
            // The builder sits above the Navigator, so pushed routes (the
            // terminal page) can read the share-target controller.
            return _wrapShareTargetScope(content);
          },
          home: ListenableBuilder(
            listenable: widget.lockController,
            builder: (context, _) {
              if (!widget.lockController.isUnlocked) {
                return LockPage(
                  controller: widget.lockController,
                  themeController: widget.themeController,
                );
              }

              final home = HostsPage(
                hostsController: widget.hostsController,
                lockController: widget.lockController,
                terminalRepository: widget.terminalRepository,
                workspaceController: widget.workspaceController,
                localShellController: widget.localShellController,
                themeController: widget.themeController,
                hostKeyVerifier: widget.hostKeyVerifier,
                promptCoordinator: widget.promptCoordinator,
                sftpRepository: widget.sftpRepository,
                sftpBookmarksRepository: widget.sftpBookmarksRepository,
                agentAttention: widget.agentAttention,
                backupService: widget.backupService,
                fileExport: widget.fileExport,
                connectFlow: widget.connectFlow,
                sessionRestore: widget.sessionRestore,
                localDataChanges: widget.localDataChanges,
                hostChannels: widget.hostChannels,
              );
              return _wrapShareTargetHost(
                AgentStatusLaunchListener(
                  channel: PlatformAgentStatusWidgetChannel.instance,
                  agentAttention: widget.agentAttention,
                  workspace: widget.workspaceController,
                  connectFlow: widget.connectFlow,
                  onGuide: widget.guide?.start,
                  child: AgentPermissionActionListener(
                    source: PlatformAgentPermissionActions.instance,
                    agentAttention: widget.agentAttention,
                    findHost: (hostId) async {
                      await widget.hostsController.selfMachineKnown();
                      return widget.hostsController.findById(hostId);
                    },
                    child: _wrapNotificationOpen(home),
                  ),
                ),
              );
            },
          ),
        );
        // The Guide button (home) and Talk's long press find the guide
        // here.
        final guide = widget.guide;
        final voice = widget.voice;
        final guided = guide == null
            ? app
            : GuideScope(controller: guide, child: app);
        return voice == null
            ? guided
            : VoiceServicesScope(services: voice, child: guided);
      },
    );
  }
}
