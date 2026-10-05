import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:conduit/core/diagnostics/app_error_log.dart';
import 'package:conduit/core/platform_features.dart';
import 'package:conduit/core/presentation/adaptive_modal.dart';
import 'package:conduit/core/presentation/adaptive_page.dart';
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
import 'package:conduit/features/agent_attention/domain/agent_attention_notifier.dart';
import 'package:conduit/features/agent_attention/domain/agent_notifications.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/agent_attention/presentation/agent_monitoring_lifecycle.dart';
import 'package:conduit/features/agent_attention/presentation/agent_notification_open_listener.dart';
import 'package:conduit/features/agent_attention/presentation/agent_permission_action_listener.dart';
import 'package:conduit/features/agent_messaging/data/agent_messenger.dart';
import 'package:conduit/features/agent_messaging/domain/agent_message.dart';
import 'package:conduit/features/agents_digest/data/digest_preferences.dart';
import 'package:conduit/features/agents_digest/presentation/digest_controller.dart';
import 'package:conduit/features/app_lock/data/local_app_authenticator.dart';
import 'package:conduit/features/app_lock/data/secure_app_lock_preferences.dart';
import 'package:conduit/features/app_lock/presentation/app_lock_controller.dart';
import 'package:conduit/features/app_lock/presentation/app_lock_gate.dart';
import 'package:conduit/features/app_lock/presentation/lock_page.dart';
import 'package:conduit/features/backup/data/app_backup_service.dart';
import 'package:conduit/features/companion_setup/presentation/companion_setup_controller.dart';
import 'package:conduit/features/continuity/data/secure_continuity_store.dart';
import 'package:conduit/features/continuity/domain/continuity_rules.dart';
import 'package:conduit/features/continuity/presentation/continuity_controller.dart';
import 'package:conduit/features/continuity/presentation/continuity_places.dart';
import 'package:conduit/features/continuity/presentation/continuity_scope.dart';
import 'package:conduit/features/continuity/presentation/continuity_sync_link.dart';
import 'package:conduit/features/desktop_shell/presentation/project_layout_controller.dart';
import 'package:conduit/features/home_widget/data/platform_agent_status_widget_channel.dart';
import 'package:conduit/features/home_widget/domain/agent_status_snapshot.dart';
import 'package:conduit/features/home_widget/domain/launcher_themes.dart';
import 'package:conduit/features/home_widget/presentation/agent_status_launch_listener.dart';
import 'package:conduit/features/home_widget/presentation/agent_status_widget_pusher.dart';
import 'package:conduit/features/home_widget/presentation/home_launch_requests.dart';
import 'package:conduit/features/hosts/data/secure_saved_hosts_repository.dart';
import 'package:conduit/features/hosts/presentation/hosts_controller.dart';
import 'package:conduit/features/hosts/presentation/hosts_page.dart';
import 'package:conduit/features/live/presentation/companion_preferences.dart';
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
import 'package:conduit/features/talkbawt/data/conductore_talkbawt_client.dart';
import 'package:conduit/features/talkbawt/domain/talkbawt_settings.dart';
import 'package:conduit/features/talkbawt/presentation/paired_mode_page.dart';
import 'package:conduit/features/talkbawt/presentation/talkbawt_controller.dart';
import 'package:conduit/features/talkbawt/presentation/talkbawt_entry.dart';
import 'package:conduit/features/talkbawt/presentation/talkbawt_scope.dart';
import 'package:conduit/features/tasks/presentation/task_runs_controller.dart';
import 'package:conduit/features/tasks/presentation/task_sources_controller.dart';
import 'package:conduit/features/tasks/presentation/tasks_entry.dart';
import 'package:conduit/features/terminal/data/connectivity_plus_network.dart';
import 'package:conduit/features/terminal/data/dart_ssh_terminal_repository.dart';
import 'package:conduit/features/terminal/data/mosh_terminal_repository.dart';
import 'package:conduit/features/terminal/data/routing_terminal_repository.dart';
import 'package:conduit/features/terminal/data/secure_host_key_verifier.dart';
import 'package:conduit/features/terminal/data/secure_mosh_server_ledger_store.dart';
import 'package:conduit/features/terminal/data/secure_recent_directories_store.dart';
import 'package:conduit/features/terminal/data/ssh_keepalive_policy.dart';
import 'package:conduit/features/terminal/domain/host_key_verifier.dart';
import 'package:conduit/features/terminal/domain/mosh_server_ledger.dart';
import 'package:conduit/features/terminal/domain/ssh_terminal_repository.dart';
import 'package:conduit/features/terminal/presentation/host_key_prompt_coordinator.dart';
import 'package:conduit/features/terminal/presentation/prompt_image_scope.dart';
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
    preferences: const SecureAppLockPreferences(secureStorage),
  );
  unawaited(lockController.loadPreferences());
  // Notification buttons and the launcher answer only while the app lock
  // would let the user in (CON-090): the native side follows every change.
  void pushAppLockState() {
    final state = lockController.actionState.value;
    unawaited(
      PlatformAgentAttentionNotifier.setAppLockState(
        locked: state.locked,
        relockAt: state.relockAt,
      ),
    );
  }

  lockController.actionState.addListener(pushAppLockState);
  pushAppLockState();
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
    // A new network leaves the shared side connections half dead: they
    // reconnect on their next command.
    networkChanges: ConnectivityPlusNetwork().onNetworkChanged,
  );
  final terminalRepository = RoutingTerminalRepository(
    ssh: DartSshTerminalRepository(hostKeyVerifier),
    mosh: MoshTerminalRepository(
      hostKeyVerifier,
      cleanupRunner: hostChannels.runner,
      ledger: MoshServerLedger(
        const SecureMoshServerLedgerStore(secureStorage),
      ),
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
  // Quitting the desktop app closes its sessions, so their mosh-servers
  // end instead of waiting for a client that is gone.
  AppLifecycleListener(
    onExitRequested: () async {
      await workspaceController.disconnectAll();
      return AppExitResponse.exit;
    },
  );
  final sftpRepository = hostChannels.files;
  const sftpBookmarksRepository = SecureSftpBookmarksRepository(secureStorage);
  final agentAttention = AgentAttentionController(
    workspace: workspaceController,
    runnerFactory: hostChannels.runner,
    provider: const HerdrAttentionProvider(),
    companionProvider: const ConductoreHostAttentionProvider(),
    notifier: const PlatformAgentAttentionNotifier(),
    notificationPreferences: const SecureAgentNotificationPreferencesStore(
      secureStorage,
    ),
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
    agentKinds: agentAttention.agentKinds,
    // The app coming back re-focuses the Herdr workspace in use (or, when
    // this device may not move Herdr's focus, checks where it is).
    watchLifecycle: true,
    mayMoveHerdrFocus: () => themeController.herdrMayMoveFocus,
    // Previews of Herdr sessions the shared focus is not on.
    herdrRefreshInterval: const Duration(seconds: 15),
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
  // The agents dashboard (companion `digest`): facts, stuck flags and
  // Claude summaries per agent, asked only while it is on screen.
  final digest = DigestController(
    source: AttentionDigestHostSource(
      attention: agentAttention,
      hosts: hostsController,
    ),
    preferences: const SecureDigestPreferencesStore(secureStorage),
    language: () {
      final own = themeController.voice.guide.language;
      final speech = own.isNotEmpty ? own : themeController.speechLanguage;
      return speech.isNotEmpty
          ? speech
          : WidgetsBinding.instance.platformDispatcher.locale.languageCode;
    },
  );
  // An agent's expanded notification ends with its dashboard line.
  agentAttention.notificationDetail = digest.cachedLineFor;
  // The urgent modes alert on the dashboard's stuck flags (CON-074): its
  // facts stay fresh in the background while they are wanted, and each new
  // answer re-checks the alerts and the ongoing status.
  agentAttention.stuckReasonFor = digest.cachedStuckFor;
  agentAttention.machineName = (id) => hostsController.findById(id)?.name;
  void syncStuckFacts() {
    final preferences = agentAttention.notificationPreferences;
    digest.keepFactsFresh(
      preferences.mode.urgentOnlyAlerts && preferences.stuck,
    );
  }

  agentAttention.addListener(syncStuckFacts);
  syncStuckFacts();
  digest.addListener(() => unawaited(agentAttention.resyncNotifications()));
  // Herdr sidebar tokens and the worktree location, per companion; read
  // from storage only once a companion that takes them connects.
  final companionPreferences = CompanionPreferences.instance =
      CompanionPreferences.secure(secureStorage, attention: agentAttention);
  agentAttention.onCompanionCapabilities = (host, capabilities) =>
      unawaited(companionPreferences.hostConnected(host, capabilities));
  // Task sources (CON-039): trackers and markdown folders, tokens in
  // secure storage on this device only. Read when Tasks first opens.
  final taskSources = TaskSourcesController.instance = createAppTaskSources(
    storage: secureStorage,
    hosts: hostsController,
    attention: agentAttention,
  );
  // Started tasks (CON-037): batches on the machines' companions, followed
  // once Tasks or the dashboard shows them (no timer at startup); finished
  // ones move to done when asked.
  TaskRunsController.instance = createAppTaskRuns(
    storage: secureStorage,
    attention: agentAttention,
    sources: taskSources,
  );
  appTaskStartEnvironment = taskStartEnvironment(agentAttention);
  // The project view (CON-065): its prefs sync with the app settings; the
  // machines' sidebar.toml is read when a project view shows.
  ProjectLayoutController.instance = ProjectLayoutController(
    theme: themeController,
    attention: agentAttention,
  );
  // Crash reports never carry Claude account names (cswap aliases, masked
  // emails).
  addTelemetryTerms(() => usage.summary.accountTerms);
  // The widget's dashboard counts read the digest's cached answers only;
  // its colours follow the app theme.
  AgentStatusWidgetPusher.forController(
    agentAttention,
    usage: usage,
    digest: digest,
    theme: () => AgentStatusTheme.fromPalette(themeController.palette),
    pcTheme: () {
      final synced = themeController.omarchySyncedTheme;
      return AgentStatusPcTheme.fromSynced(
        synced,
        machine: synced == null
            ? null
            : hostsController.findById(synced.hostId)?.name,
      );
    },
    themeChanges: themeController,
    channel: PlatformAgentStatusWidgetChannel.instance,
  ).start();
  // Talkbawt (CON-050): handoffs and threads between agents through a
  // machine's companion, the only Talkbawt client. Owned links live in
  // secure storage and sync only with the credentials, end-to-end
  // encrypted. Reply notifications open the preview, nothing else.
  final talkbawt = TalkbawtController(
    store: const SecureJsonMapStore(
      secureStorage,
      TalkbawtController.storageKey,
    ),
    clients: (host) {
      final (runner, :owned) = agentAttention.runnerFor(host);
      return (
        client: ConductoreTalkbawtClient(runner),
        release: () async {
          if (owned) await runner.close();
        },
      );
    },
    findHost: hostsController.findById,
    notify: (notice) => const PlatformAgentAttentionNotifier().show(
      id: 'talkbawt-${notice.threadId}',
      title: notice.title,
      body: notice.body,
      open: AgentOpenTarget(
        hostId: talkbawtNotificationPrefix,
        agentId: notice.threadId,
      ),
    ),
  );
  unawaited(talkbawt.load());
  // "Message agents" to another machine: the relay setting (Settings ›
  // Agents › Talkbawt) picks the phone relay (default) or Talkbawt.
  AgentMessenger.routeSetting = () =>
      talkbawt.settings.relay == TalkbawtRelayMode.talkbawt
      ? AgentRelayRoute.talkbawt
      : AgentRelayRoute.phone;
  AgentMessenger.talkbawt =
      ({required from, required fromLabel, required target, required text}) =>
          talkbawt.relayViaTalkbawt(
            from: from,
            fromLabel: fromLabel,
            to: TalkbawtRelayTarget(host: target.host, agent: target.agent),
            text: text,
          );
  const fileExport = FilePickerFileExport();
  final shareTarget = ShareTargetController(
    source: PlatformShareTargetSource(),
    workspace: workspaceController,
    uploader: SftpShareUploader(sftpRepository),
  );
  // A shared Talkbawt link opens its preview, not the upload flow.
  shareTarget.intercept = (payload) {
    final link = talkbawtLinkIn(payload);
    if (link == null) return false;
    talkbawt.receiveSharedLink(link.url);
    return true;
  };

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
  // Continue where you left off (CON-008): where this device is, its
  // drafts, and the other devices' places, through device sync.
  final continuitySync = SyncControllerContinuityLink();
  final continuity = ContinuityController(
    store: const SecureContinuityStore(secureStorage),
    sync: continuitySync,
    // A desktop's "This computer" and the phone's saved machine for that
    // desktop are the same place.
    machineFor: (id) => localMachineFor(
      id,
      findById: hostsController.findById,
      selfMachineId: hostsController.selfMachine?.id,
      thisComputer: hostsController.thisComputer,
    ),
    selfMachineId: () => hostsController.selfMachine?.id,
    platform: defaultTargetPlatform.name,
    desktop: PlatformFeatures.isDesktop,
  );
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
    continuity: continuity,
    talkbawt: const SecureJsonMapStore(
      secureStorage,
      TalkbawtController.storageKey,
    ),
  );
  // A sync pull or backup import may bring Talkbawt links from another
  // device.
  localDataChanges.addListener(() {
    final keys = localDataChanges.lastKeys;
    if (keys.isEmpty || keys.contains(AppLocalSyncStore.talkbawtKey)) {
      unawaited(talkbawt.reload());
    }
  });
  // Settings › Sync: this device's data, end-to-end encrypted, through
  // one saved machine (the hub) over the same SSH/SFTP stack.
  final syncController = SyncController(
    state: const SecureSyncStateStore(secureStorage),
    local: localSyncStore,
    hubFactory: (host, deviceId) => SshSyncHub(
      host: host,
      runner: hostChannels.runner(host),
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
      talkbawt.saves,
    ],
    platform: defaultTargetPlatform.name,
    defaultDeviceName: defaultSyncDeviceName(),
  );
  continuitySync.controller = syncController;
  unawaited(themeLoaded.then((_) => syncController.start()));
  unawaited(continuity.start());
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
      catchUp: digest.catchUp,
      accounts: UsageGuideAccounts(usage),
      reviewer: AppGuideReviewer(
        navigatorKey: navigatorKey,
        attention: agentAttention,
      ),
      locked: () => !lockController.admitsActions(),
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
    digest: digest,
    appLock: PlatformFeatures.appLock ? lockController : null,
    talkbawt: talkbawt,
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
        child: ContinuityScope(
          controller: continuity,
          child: VoiceSettingsScope(
            settings: themeController,
            child: SessionViewScope(
              controller: sessionViews,
              child: CompanionSetupScope(
                controller: companionSetup,
                agentAttention: agentAttention,
                child: UsageScope(
                  controller: usage,
                  child: DigestScope(
                    controller: digest,
                    child: TalkbawtScope(
                      controller: talkbawt,
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
                        continuity: continuity,
                        talkbawt: talkbawt,
                      ),
                    ),
                  ),
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
    this.continuity,
    this.talkbawt,
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

  /// Where this device is, for the other devices; null leaves it out.
  final ContinuityController? continuity;

  /// Talkbawt handoffs: shared links, reply notifications, owned-thread
  /// watching while the app is in front, and the paired-mode banner.
  final TalkbawtController? talkbawt;

  @override
  State<ConduitApp> createState() => _ConduitAppState();
}

class _ConduitAppState extends State<ConduitApp> with WidgetsBindingObserver {
  final _backgroundKeepalive = const TerminalBackgroundKeepalive();
  AppLifecycleState _lifecycleState = AppLifecycleState.resumed;

  /// The Android keepalive service; null where there is none.
  late final BackgroundKeepaliveSync? _keepaliveSync =
      PlatformFeatures.backgroundKeepalive
      ? BackgroundKeepaliveSync(
          start: (count) => _backgroundKeepalive.start(sessionCount: count),
          stop: _backgroundKeepalive.stop,
        )
      : null;
  bool _notificationPermissionRequested = false;

  /// Reports the phone's place (Chat View, terminal, home) to continuity.
  ContinuityRouteTracker? _continuityTracker;

  /// One list for every rebuild: the navigator keeps its observers.
  late final List<NavigatorObserver> _navigatorObservers = [
    ?_continuityTracker,
  ];

  @override
  void initState() {
    super.initState();
    if (widget.continuity case final continuity?) {
      _continuityTracker = ContinuityRouteTracker(
        continuity: continuity,
        workspace: widget.workspaceController,
        attention: widget.agentAttention,
        hosts: widget.hostsController,
        herdrWorkspaceOf: widget.connectFlow?.herdr.workspaceOf,
      );
    }
    WidgetsBinding.instance.addObserver(this);
    widget.workspaceController.addListener(_syncBackgroundKeepalive);
    // Reconciles a service still running from an earlier engine.
    _syncBackgroundKeepalive();
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
    SshKeepalivePolicy.instance.foregroundSeconds =
        widget.themeController.sshKeepaliveSeconds;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
    _syncBackgroundKeepalive();
    // Slower SSH keep-alives while nothing is on screen (CON-089).
    SshKeepalivePolicy.instance.background =
        state == AppLifecycleState.hidden || state == AppLifecycleState.paused;
    _syncAgentAttention(state);

    if (state == AppLifecycleState.resumed) {
      for (final session in widget.workspaceController.sessions) {
        session.forceResize();
      }
    }
  }

  void _syncAgentAttention(AppLifecycleState state) {
    widget.agentAttention.setAppActive(
      agentMonitoringActive(state, defaultTargetPlatform),
    );
    // The companion long-poll runs whenever monitoring does, in the
    // Android background too; only the fallback tick slows down there
    // (CON-089).
    widget.agentAttention.setInBackground(
      state == AppLifecycleState.hidden || state == AppLifecycleState.paused,
    );
    // Owned Talkbawt threads are watched for replies only while in front.
    widget.talkbawt?.setForeground(
      state == AppLifecycleState.resumed || state == AppLifecycleState.inactive,
    );
  }

  void _syncBackgroundKeepalive() {
    final keepaliveSync = _keepaliveSync;
    if (keepaliveSync == null) {
      return;
    }
    final sessionCount = widget.workspaceController.liveSessionCount;
    _maybeRequestNotificationPermission(sessionCount);
    keepaliveSync.sync(sessionCount: sessionCount, lifecycle: _lifecycleState);
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
    _continuityTracker?.dispose();
    _keepaliveSync?.dispose();
    _launchRequests.dispose();
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

  /// Every tap counts as use of this device (continuity's "in use").
  Widget _wrapActivity(Widget app) {
    final continuity = widget.continuity;
    if (continuity == null) return app;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => continuity.noteActivity(),
      child: app,
    );
  }

  /// Prompt images (attach, paste) for Chat Views opened from anywhere.
  Widget _wrapPromptImageScope(Widget app) => PromptImageScope(
    attacherFor: (host, context) => sftpPromptImageAttacher(
      repository: widget.sftpRepository,
      host: host,
      context: context,
    ),
    pasteImages: () => widget.themeController.pasteImagesAsFiles,
    child: app,
  );

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
    final talkbawt = widget.talkbawt;
    return AgentNotificationOpenListener(
      source: PlatformAgentOpenRequests.instance,
      // A Talkbawt reply opens its preview, never an agent.
      intercept: talkbawt == null
          ? null
          : (target) {
              if (!target.hostId.startsWith(talkbawtNotificationPrefix)) {
                return false;
              }
              final navigator = widget.navigatorKey?.currentState;
              if (navigator != null) {
                unawaited(
                  openTalkbawtNotification(navigator, talkbawt, target.agentId),
                );
              }
              return true;
            },
      findHost: (hostId) async {
        await widget.hostsController.selfMachineKnown();
        return widget.hostsController.findById(hostId);
      },
      onOpen: (host, agent) async {
        await flow.openAgent(host, agent, preferredView: true);
      },
      child: home,
    );
  }

  /// Shared Talkbawt links open their preview once the app is unlocked.
  Widget _wrapTalkbawtLinks(Widget home) {
    final talkbawt = widget.talkbawt;
    if (talkbawt == null) return home;
    return TalkbawtLinkListener(
      controller: talkbawt,
      attention: widget.agentAttention,
      child: home,
    );
  }

  /// The widget's dashboard and usage taps, for the home page.
  final _launchRequests = HomeLaunchRequests();

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
          navigatorObservers: _navigatorObservers,
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
              child: _wrapActivity(
                Stack(
                  children: [
                    child ?? const SizedBox.shrink(),
                    AndroidThreeButtonNavigationBackground(
                      color: Theme.of(context).scaffoldBackgroundColor,
                    ),
                    if (widget.guide case final guide?)
                      GuideOverlay(controller: guide),
                    // Paired machines: shown above every screen while on.
                    if (widget.talkbawt case final talkbawt?)
                      Align(
                        alignment: Alignment.topCenter,
                        child: SafeArea(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: PairedModeBanner(
                              controller: talkbawt,
                              compact: true,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            );
            // The builder sits above the Navigator, so pushed routes (the
            // terminal page) can read the share-target controller. The lock
            // covers every route, so locking again after the app was away
            // hides a terminal or dialog left open.
            return _wrapPromptImageScope(
              _wrapShareTargetScope(
                DesktopEscapeToPop(
                  navigatorKey: widget.navigatorKey,
                  child: AppLockGate(
                    controller: widget.lockController,
                    lockPage: (_) => LockPage(
                      controller: widget.lockController,
                      themeController: widget.themeController,
                    ),
                    child: content,
                  ),
                ),
              ),
            );
          },
          home: ListenableBuilder(
            listenable: widget.lockController,
            builder: (context, _) {
              if (!widget.lockController.isUnlocked) {
                // AppLockGate shows the lock page above every route; the
                // home page (and its share and notification handlers) is
                // gone until unlocked.
                return const Scaffold();
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
                launchRequests: _launchRequests,
              );
              return _wrapShareTargetHost(
                AgentStatusLaunchListener(
                  channel: PlatformAgentStatusWidgetChannel.instance,
                  agentAttention: widget.agentAttention,
                  workspace: widget.workspaceController,
                  connectFlow: widget.connectFlow,
                  onGuide: widget.guide?.start,
                  onDashboard: () =>
                      _launchRequests.request(HomeLaunchRequest.dashboard),
                  onUsage: () =>
                      _launchRequests.request(HomeLaunchRequest.usage),
                  child: AgentPermissionActionListener(
                    source: PlatformAgentPermissionActions.instance,
                    mayAct: widget.lockController.admitsActions,
                    launcherActions: PlatformLauncherActions.instance,
                    agentAttention: widget.agentAttention,
                    findHost: (hostId) async {
                      await widget.hostsController.selfMachineKnown();
                      return widget.hostsController.findById(hostId);
                    },
                    child: _wrapNotificationOpen(_wrapTalkbawtLinks(home)),
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
