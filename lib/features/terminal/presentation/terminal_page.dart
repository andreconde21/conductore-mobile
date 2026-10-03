import 'dart:async';

import 'package:conduit/core/app_failure.dart';
import 'package:conduit/core/platform_features.dart';
import 'package:conduit/core/presentation/conduit_brand.dart';
import 'package:conduit/core/presentation/system_navigation_insets.dart';
import 'package:conduit/core/secure_storage.dart';
import 'package:conduit/core/telemetry/telemetry.dart';
import 'package:conduit/core/telemetry/telemetry_events.dart';
import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/core/theme/terminal_appearance.dart';
import 'package:conduit/core/theme/theme_controller.dart';
import 'package:conduit/features/agent_attention/data/remote_tool_command.dart';
import 'package:conduit/features/agent_attention/data/ssh_agent_command_runner.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_sheet.dart';
import 'package:conduit/features/chat_view/data/attention_host_runner.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_launcher.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_presenter.dart';
import 'package:conduit/features/companion_setup/domain/companion_status.dart';
import 'package:conduit/features/companion_setup/presentation/companion_setup_controller.dart';
import 'package:conduit/features/desktop_shell/domain/shell_layout.dart';
import 'package:conduit/features/desktop_shell/domain/sidebar_tree.dart';
import 'package:conduit/features/desktop_shell/presentation/chat_view_tab.dart';
import 'package:conduit/features/desktop_shell/presentation/terminal_shell_embedding.dart';
import 'package:conduit/features/desktop_shell/presentation/widgets/shell_split_area.dart';
import 'package:conduit/features/desktop_shell/presentation/widgets/shell_tab_strip.dart';
import 'package:conduit/features/diff_view/data/ssh_git_diff_source.dart';
import 'package:conduit/features/diff_view/presentation/diff_view.dart';
import 'package:conduit/features/diff_view/presentation/diff_view_controller.dart';
import 'package:conduit/features/diff_view/presentation/diff_view_tab.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/hosts/presentation/home_board_controller.dart';
import 'package:conduit/features/live/domain/live_host_model.dart';
import 'package:conduit/features/live_preview/data/preview_screenshot_sender.dart';
import 'package:conduit/features/live_preview/data/secure_live_preview_port_store.dart';
import 'package:conduit/features/live_preview/data/ssh_port_forwarder.dart';
import 'package:conduit/features/live_preview/domain/dev_server_detection.dart';
import 'package:conduit/features/live_preview/domain/live_preview_port_store.dart';
import 'package:conduit/features/live_preview/domain/port_forward.dart';
import 'package:conduit/features/live_preview/domain/preview_screenshot.dart';
import 'package:conduit/features/live_preview/presentation/live_preview_controller.dart';
import 'package:conduit/features/live_preview/presentation/live_preview_port_dialog.dart';
import 'package:conduit/features/live_preview/presentation/live_preview_tab.dart';
import 'package:conduit/features/live_preview/presentation/live_preview_view.dart';
import 'package:conduit/features/live_preview/presentation/preview_ready_chip.dart';
import 'package:conduit/features/live_preview/presentation/preview_ready_controller.dart';
import 'package:conduit/features/prompt_menus/presentation/prompt_menu_strip.dart';
import 'package:conduit/features/quick_actions/presentation/quick_action_runner.dart';
import 'package:conduit/features/quick_actions/presentation/session_quick_actions.dart';
import 'package:conduit/features/session_navigation/presentation/quick_switcher_actions.dart';
import 'package:conduit/features/session_navigation/presentation/quick_switcher_sheet.dart';
import 'package:conduit/features/session_navigation/presentation/quick_switcher_shortcut.dart';
import 'package:conduit/features/session_navigation/presentation/session_view_controller.dart';
import 'package:conduit/features/session_navigation/presentation/session_view_launcher.dart';
import 'package:conduit/features/session_navigation/presentation/session_view_widgets.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:conduit/features/sessions/presentation/herdr_session_focus.dart';
import 'package:conduit/features/sessions/presentation/session_connect_flow.dart';
import 'package:conduit/features/sessions/presentation/session_grid_page.dart';
import 'package:conduit/features/sessions/presentation/tmux_session_focus.dart';
import 'package:conduit/features/settings/presentation/settings_page.dart';
import 'package:conduit/features/settings/presentation/settings_services.dart';
import 'package:conduit/features/sftp/domain/sftp_repository.dart';
import 'package:conduit/features/sftp/presentation/file_viewer/discard_changes_dialog.dart';
import 'package:conduit/features/sftp/presentation/file_viewer/sftp_file_viewer.dart';
import 'package:conduit/features/share_target/data/sftp_share_uploader.dart';
import 'package:conduit/features/share_target/domain/share_inbox.dart';
import 'package:conduit/features/share_target/presentation/share_target_controller.dart';
import 'package:conduit/features/share_target/presentation/share_target_scope.dart';
import 'package:conduit/features/terminal/data/prompt_image_preparer.dart';
import 'package:conduit/features/terminal/domain/clipboard_image_paste.dart';
import 'package:conduit/features/terminal/domain/herdr_remote_control.dart';
import 'package:conduit/features/terminal/domain/host_key_verifier.dart';
import 'package:conduit/features/terminal/domain/multiplexer_tabs.dart';
import 'package:conduit/features/terminal/domain/prompt_image.dart';
import 'package:conduit/features/terminal/domain/recent_directories.dart';
import 'package:conduit/features/terminal/domain/security_key_interaction.dart';
import 'package:conduit/features/terminal/domain/terminal_gesture_preferences.dart';
import 'package:conduit/features/terminal/domain/terminal_link_detector.dart';
import 'package:conduit/features/terminal/presentation/desktop_shortcuts.dart';
import 'package:conduit/features/terminal/presentation/gestures/terminal_gesture_layer.dart';
import 'package:conduit/features/terminal/presentation/herdr_shortcuts.dart';
import 'package:conduit/features/terminal/presentation/multiplexer_tabs_controller.dart';
import 'package:conduit/features/terminal/presentation/prompt_image_scope.dart';
import 'package:conduit/features/terminal/presentation/security_key_picker_dialog.dart';
import 'package:conduit/features/terminal/presentation/security_key_pin_dialog.dart';
import 'package:conduit/features/terminal/presentation/terminal_file_tabs_controller.dart';
import 'package:conduit/features/terminal/presentation/terminal_keyboard_bar.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:conduit/features/terminal/presentation/widgets/desktop_shortcuts_sheet.dart';
import 'package:conduit/features/terminal/presentation/widgets/empty_terminal_state.dart';
import 'package:conduit/features/terminal/presentation/widgets/floating_toolbar.dart';
import 'package:conduit/features/terminal/presentation/widgets/multiplexer_tab_actions.dart';
import 'package:conduit/features/terminal/presentation/widgets/multiplexer_tab_compact.dart';
import 'package:conduit/features/terminal/presentation/widgets/multiplexer_tab_strip.dart';
import 'package:conduit/features/terminal/presentation/widgets/prompt_composer_sheet.dart';
import 'package:conduit/features/terminal/presentation/widgets/recent_directories_sheet.dart';
import 'package:conduit/features/terminal/presentation/widgets/session_focus_frame.dart';
import 'package:conduit/features/terminal/presentation/widgets/session_tabs.dart';
import 'package:conduit/features/terminal/presentation/widgets/terminal_header.dart';
import 'package:conduit/features/terminal/presentation/widgets/terminal_link_sheet.dart';
import 'package:conduit/features/terminal/presentation/widgets/terminal_surface.dart';
import 'package:conduit/features/this_computer/data/host_channels.dart';
import 'package:conduit/features/voice/data/platform_speech_recognizer.dart';
import 'package:conduit/features/voice/domain/speech_recognizer.dart';
import 'package:conduit/features/voice/presentation/dictation_button.dart';
import 'package:conduit/features/voice/presentation/dictation_controller.dart';
import 'package:conduit/features/voice/presentation/voice_services.dart';
import 'package:conduit_vt/conduit_vt.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

class TerminalPage extends StatefulWidget {
  const TerminalPage({
    required this.workspace,
    required this.themeController,
    required this.sftpRepository,
    this.agentAttention,
    this.hostKeyVerifier,
    this.livePreviewPortStore = const SecureLivePreviewPortStore(
      conductoreSecureStorage,
    ),
    this.connectFlow,
    this.speechRecognizer,
    this.promptImageSource,
    this.previewWatcherFactory,
    this.promptImagePreparer,
    this.homeBoards,
    this.hostChannels,
    this.shell,
    super.key,
  });

  final TerminalWorkspaceController workspace;
  final ThemeController themeController;
  final SftpRepository sftpRepository;

  /// Optional Agent Attention monitoring; null hides the dashboard.
  final AgentAttentionController? agentAttention;

  /// Opens the extra SSH connections behind the session tools (git diff,
  /// live preview); null hides the tools menu.
  final HostKeyVerifier? hostKeyVerifier;

  /// Remembers the last previewed port per host.
  final LivePreviewPortStore livePreviewPortStore;

  /// Optional connect flow for the session grid's "+" tile.
  final SessionConnectFlow? connectFlow;

  /// Voice input for Chat mode. Null means the platform default (Android's
  /// on-device recognizer; no mic elsewhere).
  final SpeechRecognizer? speechRecognizer;

  /// Where Chat mode's image button takes images from. Null means the
  /// platform picker and clipboard.
  final PromptImageSource? promptImageSource;

  /// Builds the "Preview ready" watcher for a remote session. Null means
  /// polling over an extra SSH connection (needs [hostKeyVerifier]).
  final PreviewReadyController Function(TerminalSessionController session)?
  previewWatcherFactory;

  /// Names and copies images before upload (Chat mode's image button and
  /// image paste). Null means the default under the app's temp directory.
  final PromptImagePreparer? promptImagePreparer;

  /// The home page's boards (tmux sessions and Herdr workspaces per
  /// machine), for the quick switcher's other workspaces.
  final HomeBoards? homeBoards;

  /// Commands and port forwards per machine, SSH or This computer. Null
  /// means SSH through [hostKeyVerifier].
  final HostChannels? hostChannels;

  /// Runs the page inside the desktop shell (its tabs, split panes and
  /// dashboard) instead of as a pushed route; null on phones and tablets.
  final TerminalShellEmbedding? shell;

  @override
  State<TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends State<TerminalPage>
    with SingleTickerProviderStateMixin
    implements TerminalShellHost {
  final _focusNode = FocusNode();

  /// The short slide after a swipe on the top row switched sessions.
  /// Created up front: a page that never slid (the desktop shell's) must
  /// not create it in dispose.
  late final AnimationController _slide;
  int _slideDirection = 0;
  late final TerminalFileTabsController _fileTabs;
  TerminalSessionController? _focusedSession;
  bool _fullscreen = false;
  bool _tmuxScrollMode = false;
  bool _composeMode = false;

  /// The next chat line starts dictating as it opens (the Dictate button);
  /// cleared once that bar is built.
  bool _dictateOnOpen = false;

  /// The on-screen pill and key rows. Hidden by default on desktop, where a
  /// physical keyboard exists; a slim strip keeps them one click away.
  bool _touchKeysVisible = PlatformFeatures.touchKeyRowsByDefault;
  // Compose recall: recently SENT lines (deduped, oldest first, capped) so a
  // line sent into a mode that discarded it can be recalled; plus one UNSENT
  // draft per session (keyed by host id), preserved across compose close,
  // tab switches, and backgrounding so composing can't silently lose text.
  // Drafts are deliberately in-memory only: prompts can be sensitive, so
  // they are not persisted across a full app restart.
  static const int _composeHistoryLimit = 20;
  final List<String> _composeHistory = <String>[];
  final Map<String, String> _composeDrafts = <String, String>{};
  // Bumped whenever a draft is edited outside the inline bar (the composer
  // sheet), forcing the bar to rebuild with the updated text.
  int _composeRevision = 0;
  DictationController? _dictation;
  ShareTargetController? _shareTarget;
  final Map<TerminalSessionController, StreamSubscription<String>>
  _clipboardSubscriptions = {};

  /// "Preview ready" detection, one per remote session; only the active
  /// session's watcher polls, and only while the app is in the foreground.
  final Map<TerminalSessionController, PreviewReadyController>
  _previewWatchers = {};
  AppLifecycleListener? _lifecycle;
  bool _appResumed = true;

  /// False while a route covers the page or the desktop dashboard hides
  /// it (tickers are off): port polling pauses then.
  bool _onScreen = true;

  /// "Uploading image…" while a pasted image goes to the host.
  String? _pasteStatus;

  /// Desktop keyboard shortcuts (zoom, sessions, fullscreen, help); a no-op
  /// on phones. See desktop_shortcuts.dart.
  late final _desktopShortcuts = DesktopShortcutHandler(
    onShortcut: _handleDesktopShortcut,
    isActive: () =>
        mounted &&
        (_route?.isCurrent ?? true) &&
        (widget.shell?.isVisible() ?? true),
  );

  /// The desktop shell's panes and this page's focus, kept in step.
  TerminalShellSync? _shellSync;
  ModalRoute<Object?>? _route;

  @override
  void initState() {
    super.initState();
    _slide = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    _fileTabs = TerminalFileTabsController(widget.sftpRepository);
    // In the desktop shell the page is mounted from the start; the shell
    // counts the terminal when it comes on screen.
    if (widget.shell == null) {
      Telemetry.instance.screen(TelemetryScreen.terminal);
    }
    final recognizer =
        widget.speechRecognizer ??
        VoiceServicesScope.maybeOf(context)?.recognizer ??
        (defaultTargetPlatform == TargetPlatform.android
            ? PlatformSpeechRecognizer()
            : null);
    if (recognizer != null) {
      _dictation = DictationController(
        recognizer,
        language: () => widget.themeController.speechLanguage,
      );
      unawaited(_dictation!.checkAvailability());
    }
    unawaited(WakelockPlus.enable());
    SecurityKeyInteraction.instance.registerPinPrompt(_promptSecurityKeyPin);
    SecurityKeyInteraction.instance.registerSelectionPrompt(
      _promptSecurityKeySelection,
    );
    widget.workspace.addListener(_handleWorkspaceChanged);
    GestureBinding.instance.pointerRouter.addGlobalRoute(_notePointer);
    _syncRemoteClipboardSubscriptions();
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        _appResumed = state == AppLifecycleState.resumed;
        _syncPreviewWatchers();
      },
    );
    _syncPreviewWatchers();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusedSession = widget.workspace.activeSession;
      _focusNode.requestFocus();
    });
    _desktopShortcuts.attach();
    final shell = widget.shell;
    if (shell != null) {
      shell.host = this;
      _shellSync = TerminalShellSync(
        controller: shell.controller,
        viewIds: () => viewIds,
        activeViewId: () => activeViewId,
        activate: activateView,
      );
      _fileTabs.addListener(_handleShellViewsChanged);
      shell.controller.addListener(_handleShellControllerChanged);
      _layoutWasHeld = shell.controller.layoutHeld;
      _shellSync!.fromPage();
    }
  }

  bool _layoutWasHeld = true;

  void _handleShellViewsChanged() {
    _shellSync?.fromPage();
    widget.shell?.onViewsChanged?.call();
  }

  void _handleShellControllerChanged() {
    final held = widget.shell!.controller.layoutHeld;
    if (_layoutWasHeld && !held) {
      _layoutWasHeld = false;
      _shellSync?.afterRelease();
      widget.shell?.onViewsChanged?.call();
    }
  }

  // TerminalShellHost: what the desktop shell asks of the embedded page.

  @override
  List<String> get viewIds => [
    for (final session in widget.workspace.sessions) sessionViewId(session),
    for (final tab in _fileTabs.tabs) tab.viewId,
  ];

  @override
  String? get activeViewId {
    final tab = _fileTabs.active;
    if (tab != null) return tab.viewId;
    final session = widget.workspace.activeSession;
    return session == null ? null : sessionViewId(session);
  }

  @override
  TerminalSessionController? get focusedSession =>
      _fileTabs.active == null ? widget.workspace.activeSession : null;

  TerminalSessionController? _sessionForView(String viewId) => widget
      .workspace
      .sessions
      .where((session) => sessionViewId(session) == viewId)
      .firstOrNull;

  TerminalFileTab? _tabForView(String viewId) =>
      _fileTabs.tabs.where((tab) => tab.viewId == viewId).firstOrNull;

  @override
  void activateView(String viewId) {
    final session = _sessionForView(viewId);
    if (session != null) {
      _fileTabs.activate(null);
      widget.workspace.activate(session);
      _focusNode.requestFocus();
      return;
    }
    final tab = _tabForView(viewId);
    if (tab != null) _fileTabs.activate(tab);
  }

  @override
  Future<void> closeView(String viewId) async {
    final session = _sessionForView(viewId);
    if (session != null) {
      await _closeSessionFromKeyboard(session);
      return;
    }
    final tab = _tabForView(viewId);
    if (tab != null) await _closeFileTab(tab);
  }

  @override
  bool presentChat(ChatViewRequest request) {
    if (!mounted) return false;
    _fileTabs.add(ChatViewTab(request));
    return true;
  }

  @override
  LivePreviewTab? previewTabFor(SavedHost host) => _previewTabFor(host);

  @override
  Future<void> openPreviewForFocused() async {
    final session = widget.workspace.activeSession;
    if (session == null) return;
    await _openLivePreview(session);
  }

  @override
  void splitView(String viewId, ShellEdge edge) {
    final sync = _shellSync;
    if (sync == null) return;
    _dropView(sync.rendered.focusedPane.id, edge, viewId);
  }

  @override
  void requestSplit(ShellEdge edge) => _shellSync?.requestSplit(edge);

  @override
  void placeView(String paneId, ShellEdge edge, String viewId) =>
      _dropView(paneId, edge, viewId);

  @override
  void cancelSplit() => _shellSync?.clearSplit();

  /// Splits the focused pane at [edge] with the most recent view on no
  /// pane, or with a new session when every view is on screen.
  Future<void> _splitFocused(ShellEdge edge) async {
    final sync = _shellSync;
    final shell = widget.shell;
    if (sync == null || shell == null) return;
    final rendered = sync.rendered;
    if (!rendered.canSplit) return;
    final hidden = sync.hiddenView;
    if (hidden != null) {
      shell.controller.editLayout(
        viewIds.toSet(),
        (layout) => layout.split(layout.focusedPane.id, edge, hidden),
      );
      return;
    }
    final connectFlow = widget.connectFlow;
    if (connectFlow == null) return;
    sync.requestSplit(edge);
    try {
      await _newSessionOnMachine(connectFlow, widget.workspace.activeSession);
    } finally {
      // A cancelled picker leaves no split waiting for the next session.
      sync.clearSplit();
    }
  }

  /// Alt+arrows: the pane that way, if there is one.
  bool _focusPaneToward(int direction) {
    final sync = _shellSync;
    final shell = widget.shell;
    if (sync == null || shell == null) return false;
    final target = sync.rendered.neighbor(ShellDirection.values[direction]);
    if (target == null) return false;
    shell.controller.editLayout(
      viewIds.toSet(),
      (layout) => layout.focus(target),
    );
    return true;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
    final onScreen = TickerMode.valuesOf(context).enabled;
    if (onScreen != _onScreen) {
      _onScreen = onScreen;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _syncPreviewWatchers();
      });
    }
    final shareTarget = ShareTargetScope.maybeOf(context);
    if (shareTarget == _shareTarget) {
      return;
    }
    _shareTarget?.removeListener(_consumeSharedDraft);
    _shareTarget?.detachTerminalPage();
    _shareTarget = shareTarget;
    shareTarget?.attachTerminalPage();
    shareTarget?.addListener(_consumeSharedDraft);
    WidgetsBinding.instance.addPostFrameCallback((_) => _consumeSharedDraft());
  }

  /// Moves a delivered share (uploaded file paths and/or shared text) into
  /// the active session's Chat draft and opens the composer so the user can
  /// add instructions before sending.
  void _consumeSharedDraft() {
    final shareTarget = _shareTarget;
    final session = widget.workspace.activeSession;
    if (!mounted || shareTarget == null || session == null) {
      return;
    }
    final hostId = session.host.id;
    if (!shareTarget.hasDraft(hostId)) {
      return;
    }
    final draft = shareTarget.takeDraft(hostId)!;
    setState(() {
      _composeDrafts[hostId] = mergeShareDraft(
        _composeDrafts[hostId] ?? '',
        draft,
      );
      _composeMode = true;
      _composeRevision += 1;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.workspace.activeSession == session) {
        unawaited(_openPromptComposer(session));
      }
    });
  }

  @override
  void dispose() {
    _desktopShortcuts.detach();
    final shell = widget.shell;
    if (shell != null) {
      if (identical(shell.host, this)) shell.host = null;
      shell.controller.removeListener(_handleShellControllerChanged);
      _fileTabs.removeListener(_handleShellViewsChanged);
      _shellSync?.dispose();
    }
    unawaited(WakelockPlus.disable());
    _setSystemUiFullscreen(false);
    _shareTarget?.removeListener(_consumeSharedDraft);
    _shareTarget?.detachTerminalPage();
    _dictation?.dispose();
    SecurityKeyInteraction.instance.unregisterPinPrompt(_promptSecurityKeyPin);
    SecurityKeyInteraction.instance.unregisterSelectionPrompt(
      _promptSecurityKeySelection,
    );
    widget.workspace.removeListener(_handleWorkspaceChanged);
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_notePointer);
    for (final tabs in _muxTabs.values) {
      tabs?.dispose();
    }
    _muxTabs.clear();
    for (final subscription in _clipboardSubscriptions.values) {
      unawaited(subscription.cancel());
    }
    _clipboardSubscriptions.clear();
    _focusNode.dispose();
    _fileTabs.dispose();
    _lifecycle?.dispose();
    for (final watcher in _previewWatchers.values) {
      watcher.dispose();
    }
    _previewWatchers.clear();
    _slide.dispose();
    super.dispose();
  }

  Future<String?> _promptSecurityKeyPin(SecurityKeyPinRequest request) {
    if (!mounted) {
      return Future<String?>.value();
    }
    return showSecurityKeyPinDialog(context, request);
  }

  Future<int?> _promptSecurityKeySelection(
    SecurityKeySelectionRequest request,
  ) {
    if (!mounted) {
      return Future<int?>.value();
    }
    return showSecurityKeyPickerDialog(context, request);
  }

  /// Follows every open session's OSC 52 copies, background tabs
  /// included, so a copy made in one tab is not lost while another shows.
  void _syncRemoteClipboardSubscriptions() {
    final sessions = widget.workspace.sessions.toSet();
    _clipboardSubscriptions.removeWhere((session, subscription) {
      if (sessions.contains(session)) {
        return false;
      }
      unawaited(subscription.cancel());
      return true;
    });
    for (final session in sessions) {
      _clipboardSubscriptions[session] ??= session.remoteClipboardWrites.listen(
        (text) => _handleRemoteClipboardWrite(session, text),
      );
    }
  }

  void _handleRemoteClipboardWrite(
    TerminalSessionController session,
    String text,
  ) {
    if (!mounted || !widget.themeController.remoteClipboardEnabled) {
      return;
    }
    unawaited(Clipboard.setData(ClipboardData(text: text)));
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('Copied from ${session.host.name}'),
          duration: const Duration(seconds: 2),
        ),
      );
  }

  /// Whether "Preview ready" can watch [session]'s machine: a remote host
  /// the page can open extra connections to, without a hardware key (each
  /// poll would ask for a touch).
  bool _canWatchPreview(TerminalSessionController session) =>
      (_hasSessionTools(session.host) ||
          widget.previewWatcherFactory != null) &&
      !session.host.isLocal &&
      session.host.authMethod != SshAuthMethod.hardwareKey;

  /// Creates watchers for new sessions, drops those of closed ones, and
  /// lets only the active session's watcher poll.
  void _syncPreviewWatchers() {
    final sessions = widget.workspace.sessions.toSet();
    _previewWatchers.removeWhere((session, watcher) {
      if (sessions.contains(session)) return false;
      watcher.dispose();
      return true;
    });
    final verifier = widget.hostKeyVerifier;
    final active = widget.workspace.activeSession;
    for (final session in sessions) {
      if (!_canWatchPreview(session)) continue;
      final watcher = _previewWatchers[session] ??=
          (widget.previewWatcherFactory?.call(session) ??
                PreviewReadyController(
                  runnerFactory: () => _previewRunnerFor(session, verifier),
                  canPoll: () => session.isConnected,
                ))
            ..attachScreen(
              _TerminalScreen(session.terminal),
              () => _TerminalScreen.visibleRows(session.terminal),
            );
      watcher.setForeground(_appResumed && _onScreen && session == active);
    }
  }

  /// A command runner for [session]'s port polls: the connect flow's (the
  /// app's SSH exec channels), else the agent monitor's, else one from the
  /// host key verifier.
  AgentCommandRunner _previewRunnerFor(
    TerminalSessionController session,
    HostKeyVerifier? verifier,
  ) {
    final flow = widget.connectFlow;
    if (flow != null) return flow.runnerFactory(session.host);
    final attention = widget.agentAttention;
    // Asked per command, so a reconnect's new monitor connection is used.
    if (attention != null) return AttentionHostRunner(attention, session.host);
    return _commandRunnerFor(session.host) ??
        SshAgentCommandRunner(verifier!, session.host);
  }

  /// Whether the page can open side channels (git, preview) to [host].
  bool _hasSessionTools(SavedHost host) =>
      !host.isLocal &&
      (widget.hostChannels != null ||
          (widget.hostKeyVerifier != null && !host.isThisComputer));

  /// A new command runner for [host] (the caller closes it), or null
  /// when the page has no way to reach it.
  AgentCommandRunner? _commandRunnerFor(SavedHost host) {
    final channels = widget.hostChannels;
    if (channels != null) return channels.runner(host);
    final verifier = widget.hostKeyVerifier;
    if (verifier == null || host.isThisComputer) return null;
    return SshAgentCommandRunner(verifier, host);
  }

  PortForwarder? _portForwarderFor(SavedHost host) {
    final channels = widget.hostChannels;
    if (channels != null) return channels.portForwarder(host);
    final verifier = widget.hostKeyVerifier;
    if (verifier == null || host.isThisComputer) return null;
    return SshPortForwarder(verifier, host);
  }

  /// The Live preview tab of [host], when one is open.
  LivePreviewTab? _previewTabFor(SavedHost host) => _fileTabs.tabs
      .whereType<LivePreviewTab>()
      .where((tab) => tab.host.id == host.id)
      .firstOrNull;

  /// Whether Live preview already shows [offer]'s port for [session].
  bool _previewShows(TerminalSessionController session, DevServerOffer offer) {
    final controller = _previewTabFor(session.host)?.controller;
    return controller != null &&
        controller.remotePort == offer.port &&
        (controller.phase == LivePreviewPhase.ready ||
            controller.phase == LivePreviewPhase.connecting);
  }

  /// The "Preview ready" chip for Chat View on [host]: opening it leaves
  /// the chat for the Live preview tab.
  Widget Function(BuildContext routeContext)? _chatPreviewChip(SavedHost host) {
    final entry = _previewWatchers.entries
        .where((entry) => entry.key.host.id == host.id)
        .firstOrNull;
    if (entry == null) return null;
    final session = entry.key;
    return (routeContext) => PreviewReadyChip(
      controller: entry.value,
      hidden: (offer) => _previewShows(session, offer),
      onOpen: (offer) {
        Navigator.of(routeContext).pop();
        if (!mounted) return;
        if (widget.workspace.sessions.contains(session)) {
          widget.workspace.activate(session);
        }
        unawaited(
          _openLivePreview(session, port: offer.port, path: offer.path),
        );
      },
    );
  }

  /// Multiplexer tab strips, per session host id (null: not a Herdr or
  /// tmux session the app can drive in the background).
  final _muxTabs = <String, MultiplexerTabsController?>{};

  MultiplexerTabsController? _muxTabsFor(TerminalSessionController session) {
    final id = session.host.id;
    if (_muxTabs.containsKey(id)) return _muxTabs[id];
    return _muxTabs[id] = _createMuxTabs(session);
  }

  MultiplexerTabsController? _createMuxTabs(TerminalSessionController session) {
    final flow = widget.connectFlow;
    final host = session.host;
    if (flow == null ||
        host.isLocal ||
        host.authMethod == SshAuthMethod.hardwareKey) {
      return null;
    }
    final MultiplexerTabsBackend backend;
    final tmuxSession = TmuxSessionFocus.tmuxSessionOf(session);
    if (HerdrSessionFocus.herdrTargetOf(session) != null) {
      final control = flow.herdr.controlFor(session);
      if (control == null) return null;
      backend = HerdrTabsBackend(
        control: control,
        fallbackWorkspaceId: () => flow.herdr.workspaceOf(session) ?? '',
      );
    } else if (tmuxSession != null) {
      backend = TmuxTabsBackend(
        channel: SerialCommandChannel(
          runnerFactory: () => flow.runnerFactory(host),
        ),
        sessionName: tmuxSession,
      );
    } else {
      return null;
    }
    final herdr = backend.kind == MultiplexerTabsKind.herdr;
    final feed = flow.live.feedFor(host);
    final herdrServer = LiveHostModel.herdrServerId(
      HerdrSessionFocus.herdrTargetOf(session)?.session ?? '',
    );
    return MultiplexerTabsController(
      backend: backend,
      live: feed == null
          ? null
          : MultiplexerLiveTabs(
              feed: feed,
              read: herdr
                  ? (model) => model.herdrStripTabs(
                      server: herdrServer,
                      fallbackWorkspaceId:
                          flow.herdr.workspaceOf(session) ?? '',
                    )
                  : (model) => model.tmuxWindows(tmuxSession!),
              // tmux is pushed only with `tmux-live` on (off by default).
              server: herdr ? null : LiveHostModel.tmuxServerId,
            ),
      agentStateFor: (tab) => _agentStateOfTab(
        session,
        herdr ? tab.id : '$tmuxSession:${tab.index}',
      ),
      keys: MultiplexerTabsKeys(
        select: (tab, position) {
          if (herdr) {
            return position <= 9 &&
                sendHerdrTab(session, position, hostPrefix: host.tmuxPrefixKey);
          }
          if (tab.index < 0 || tab.index > 9) return false;
          session
            ..sendPrefix(host.tmuxPrefixKey)
            ..sendText('${tab.index}');
          return true;
        },
        create: () {
          if (herdr) {
            return sendHerdrAction(
              session,
              'new_tab',
              hostPrefix: host.tmuxPrefixKey,
            );
          }
          session
            ..sendPrefix(host.tmuxPrefixKey)
            ..sendText('c');
          return true;
        },
      ),
    );
  }

  /// The most urgent state of the companion's agents in a tab: [tabKey]
  /// is the Herdr tab id, or `session:window` for tmux, as the companion
  /// reports an agent's tab.
  AgentAttentionState? _agentStateOfTab(
    TerminalSessionController session,
    String tabKey,
  ) {
    final agents = widget.agentAttention?.statusFor(session.host.id)?.agents;
    AgentAttentionState? best;
    for (final agent in agents ?? const <AgentInfo>[]) {
      if (agent.tab != tabKey) continue;
      final state = agent.state;
      if (best == null || _statePriority(state) < _statePriority(best)) {
        best = state;
      }
    }
    return best;
  }

  static int _statePriority(AgentAttentionState state) => switch (state) {
    AgentAttentionState.needsInput => 0,
    AgentAttentionState.blocked => 1,
    AgentAttentionState.working => 2,
    AgentAttentionState.finished => 3,
    AgentAttentionState.idle => 4,
    AgentAttentionState.unknown => 5,
  };

  /// A finger or click lifted anywhere: a swipe or tap in the terminal may
  /// have moved the multiplexer, so the strip checks again shortly.
  void _notePointer(PointerEvent event) {
    if (event is! PointerUpEvent || !mounted) return;
    final active = widget.workspace.activeSession;
    if (active == null) return;
    _muxTabs[active.host.id]?.refreshSoon();
  }

  /// Strip (desktop, or phones set to it), compact (phones) or none.
  MultiplexerTabsLayout get _muxLayout => multiplexerTabsLayout(
    widget.themeController.multiplexerTabs,
    desktop: PlatformFeatures.isDesktop,
  );

  /// The compact mode's list of the session's multiplexer tabs.
  void _openMuxTabsSheet(TerminalSessionController session) {
    final tabs = _muxTabs[session.host.id];
    if (tabs == null) return;
    unawaited(
      showMultiplexerTabsSheet(
        context,
        tabs,
        sessionLabel: SessionTabs.labelFor(session, widget.workspace.sessions),
        onDone: _focusNode.requestFocus,
      ),
    );
  }

  /// Keys the app keeps from the terminal: Ctrl+K (the quick switcher,
  /// handled globally) and Ctrl+PageUp / Ctrl+PageDown for the previous
  /// and next multiplexer tab.
  KeyEventResult _handleTerminalKey(
    TerminalSessionController session,
    KeyEvent event,
  ) {
    // Switcher and desktop shortcuts never reach the session.
    if (_keepFromSession(event)) return KeyEventResult.handled;
    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.pageUp &&
        key != LogicalKeyboardKey.pageDown) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    final tabs = _muxTabs[session.host.id];
    if (!keyboard.isControlPressed ||
        keyboard.isShiftPressed ||
        keyboard.isAltPressed ||
        tabs == null ||
        tabs.tabs.length < 2) {
      return KeyEventResult.ignored;
    }
    if (event is! KeyUpEvent) {
      unawaited(tabs.selectAdjacent(key == LogicalKeyboardKey.pageUp ? -1 : 1));
    }
    return KeyEventResult.handled;
  }

  void _handleWorkspaceChanged() {
    if (_shellSync != null) _handleShellViewsChanged();
    final open = {
      for (final session in widget.workspace.sessions) session.host.id,
    };
    _muxTabs.removeWhere((id, tabs) {
      if (open.contains(id)) return false;
      tabs?.dispose();
      return true;
    });
    _syncRemoteClipboardSubscriptions();
    _syncPreviewWatchers();
    final active = widget.workspace.activeSession;
    if (active == null || active == _focusedSession) return;
    _focusedSession = active;
    _fileTabs.activate(null);
    if (_tmuxScrollMode) {
      setState(() => _tmuxScrollMode = false);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  /// The pill's Dictate button: the chat line, dictating straight away.
  void _startDictationLine() {
    setState(() {
      _composeMode = true;
      _dictateOnOpen = true;
      // A fresh bar, so an open one starts dictating too (its draft is
      // kept in _composeDrafts).
      _composeRevision += 1;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _dictateOnOpen = false);
  }

  /// The pill's Chat button: Chat View when the session shows a Claude
  /// session the companion knows, else the inline composer. Long-press
  /// always toggles the composer.
  void _handleChatButton(TerminalSessionController session) {
    _maybeShowChatButtonHint();
    if (_composeMode) {
      setState(() => _composeMode = false);
      _focusNode.requestFocus();
      return;
    }
    final attention = widget.agentAttention;
    final host = session.host;
    if (attention == null || host.isLocal) {
      setState(() => _composeMode = true);
      return;
    }
    unawaited(_openChatForSession(attention, session));
  }

  /// The Chat button on a remote session: finds the Claude session this
  /// terminal shows (through the agent monitor, else by asking the
  /// companion), and opens its Chat View. Every way this can fail says so:
  /// a machine without the companion, or without a Claude session here,
  /// gets the composer with a note why; a broken companion explains what to
  /// fix; several candidates ask which one.
  ///
  /// With [draft] (a Live preview screenshot) Chat View opens with it in
  /// the composer. Returns whether Chat View opened, so a caller with a
  /// draft can put it in the composer otherwise.
  Future<bool> _openChatForSession(
    AgentAttentionController attention,
    TerminalSessionController session, {
    String draft = '',
  }) async {
    final host = session.host;
    final List<AgentInfo> agents;
    if (chatViewAvailable(attention, host)) {
      agents = attention.statusFor(host.id)?.agents ?? const [];
    } else {
      final companion = CompanionSetupScope.maybeOf(context);
      final known = companion?.statusFor(
        host.copyWith(id: baseHostId(host.id)),
      );
      if (known?.state == CompanionState.notInstalled) {
        _openComposerBecause(
          'No Conductore companion on ${host.name}, so there is no Chat '
          'View here. Opened the composer.',
        );
        return false;
      }
      final access = await checkChatViewAccessWithProgress(
        context,
        attention: attention,
        host: host,
      );
      if (!mounted || access == null) return false;
      if (!access.ready) {
        if (access.companionMissing) {
          _openComposerBecause(
            'No Conductore companion on ${host.name}, so there is no Chat '
            'View here. Opened the composer.',
          );
        } else {
          await showChatViewUnavailable(context, host: host, access: access);
        }
        return false;
      }
      agents = access.agents;
    }
    if (!mounted || widget.workspace.activeSession != session) return false;

    var location = _chatLocationFor(session);
    var match = resolveChatAgent(host, agents, location: location);
    if (match is ChatAgentAmbiguous && !match.elsewhere) {
      // Several Claude sessions in this workspace: the one on screen is
      // the pane Herdr has focused.
      final pane = await _focusedHerdrPane(session, location);
      if (!mounted) return false;
      if (pane != null) {
        location = ChatSessionLocation(
          herdrWorkspaceId: location.herdrWorkspaceId,
          herdrTabId: pane.tabId,
          herdrPaneId: pane.paneId,
        );
        match = resolveChatAgent(host, agents, location: location);
      }
    }
    switch (match) {
      case ChatAgentMatched(:final agent):
        _openChat(attention, host, agent, draft: draft);
        return true;
      case ChatAgentAmbiguous(:final candidates, :final elsewhere):
        final agent = await pickChatAgent(
          context,
          host: host,
          agents: candidates,
          alwaysAsk: elsewhere,
          title: elsewhere
              ? 'No Claude session in this ${_placeName(session)}. Open '
                    'another?'
              : 'Open chat for…',
        );
        if (agent != null && mounted) {
          _openChat(attention, host, agent, draft: draft);
          return true;
        }
      case ChatAgentNone():
        _openComposerBecause(
          'No Claude session is running on ${host.name}. Opened the '
          'composer.',
        );
    }
    return false;
  }

  static String _placeName(TerminalSessionController session) =>
      ConnectTarget.fromSessionHostId(session.host.id)?.kind ==
          ConnectTargetKind.herdr
      ? 'workspace'
      : 'session';

  void _openComposerBecause(String message) {
    if (!mounted) return;
    setState(() => _composeMode = true);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          key: const ValueKey('chat-fallback-notice'),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 112),
          content: Text(message),
        ),
      );
  }

  /// Where [session] is in Herdr as far as the app tracks it (the
  /// workspace it was moved to, else its connect target's).
  ChatSessionLocation _chatLocationFor(TerminalSessionController session) {
    final herdr = widget.connectFlow?.herdr;
    final workspace = herdr?.workspaceOf(session) ?? '';
    return ChatSessionLocation(herdrWorkspaceId: workspace);
  }

  /// The pane Herdr shows in [session] right now, when it is in the
  /// session's workspace (Herdr's focus is per server).
  Future<HerdrFocusedPane?> _focusedHerdrPane(
    TerminalSessionController session,
    ChatSessionLocation location,
  ) async {
    if (HerdrSessionFocus.herdrTargetOf(session) == null) return null;
    final control = widget.connectFlow?.herdr.controlFor(session);
    if (control == null) return null;
    final pane = await control.readFocusedPane();
    if (pane == null) return null;
    final workspace = location.herdrWorkspaceId;
    if (workspace.isNotEmpty &&
        pane.workspaceId.isNotEmpty &&
        pane.workspaceId != workspace) {
      return null;
    }
    return pane;
  }

  void _openChat(
    AgentAttentionController attention,
    SavedHost host,
    AgentInfo agent, {
    String draft = '',
  }) {
    unawaited(
      openChatView(
        context: context,
        attention: attention,
        host: host,
        agent: agent,
        dictation: _dictation,
        onOpenTerminal: () => _showAgentTerminal(attention, host, agent),
        accessoryBuilder: _chatPreviewChip(host),
        initialDraft: draft,
        imageAttacher: _promptImageAttacher(host),
        pasteImages: widget.themeController.pasteImagesAsFiles,
      ),
    );
  }

  void _maybeShowChatButtonHint() {
    final themeController = widget.themeController;
    if (!mounted || themeController.chatButtonHintSeen) {
      return;
    }
    unawaited(themeController.markChatButtonHintSeen());
    // Floating well above the bottom edge: the chat bar (or Chat View's
    // input) that just opened lives there and must stay tappable.
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        behavior: SnackBarBehavior.floating,
        margin: EdgeInsets.fromLTRB(16, 0, 16, 112),
        content: Text(
          'Chat opens Chat View for Claude sessions. Long-press it for the '
          'composer.',
        ),
      ),
    );
  }

  void _maybeShowTouchModeHint() {
    final themeController = widget.themeController;
    if (!mounted ||
        themeController.touchModeHintSeen ||
        themeController.terminalMouseInput) {
      return;
    }
    unawaited(themeController.markTouchModeHintSeen());
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'This app supports mouse taps. Use the Touch key to forward taps '
          'as terminal mouse clicks.',
        ),
        duration: Duration(seconds: 6),
      ),
    );
  }

  void _showTerminal() {
    _fileTabs.activate(null);
    _focusNode.requestFocus();
  }

  /// Runs a desktop keyboard shortcut. False lets the key through when
  /// there is nothing to act on.
  bool _handleDesktopShortcut(DesktopShortcutMatch match) {
    final workspace = widget.workspace;
    final sessions = workspace.sessions;
    final active = workspace.activeSession;
    final themeController = widget.themeController;
    switch (match.action) {
      case DesktopAction.zoomIn:
      case DesktopAction.zoomOut:
        final step = match.action == DesktopAction.zoomIn
            ? desktopZoomStep
            : -desktopZoomStep;
        unawaited(
          themeController.setTerminalFontSize(
            clampTerminalFontSize(themeController.terminalFontSize + step),
          ),
        );
      case DesktopAction.zoomReset:
        unawaited(themeController.setTerminalFontSize(terminalFontSizeDefault));
      case DesktopAction.newSession:
        final connectFlow = widget.connectFlow;
        if (connectFlow == null) return false;
        unawaited(_newSessionOnMachine(connectFlow, active));
      case DesktopAction.closeSession:
        if (active == null) return false;
        unawaited(_closeSessionFromKeyboard(active));
      case DesktopAction.nextSession:
      case DesktopAction.previousSession:
        if (active == null || sessions.length < 2) return false;
        final direction = match.action == DesktopAction.nextSession ? 1 : -1;
        final index = (sessions.indexOf(active) + direction) % sessions.length;
        workspace.activate(sessions[index]);
        _showTerminal();
      case DesktopAction.goToSession:
        if (match.index >= sessions.length) return false;
        workspace.activate(sessions[match.index]);
        _showTerminal();
      case DesktopAction.toggleFullscreen:
        _toggleFullscreen();
      case DesktopAction.showShortcuts:
        unawaited(_showDesktopShortcuts());
      case DesktopAction.splitRight:
      case DesktopAction.splitDown:
        if (_shellSync == null || !_shellSync!.rendered.canSplit) return false;
        unawaited(
          _splitFocused(
            match.action == DesktopAction.splitRight
                ? ShellEdge.right
                : ShellEdge.bottom,
          ),
        );
      case DesktopAction.focusPane:
        return _focusPaneToward(match.index);
      case DesktopAction.nextUnread:
      case DesktopAction.commandPalette:
      case DesktopAction.openSettings:
      case DesktopAction.toggleSidebar:
        // The desktop shell's own handler (it knows the sidebar).
        return false;
    }
    return true;
  }

  /// App shortcuts the terminal must not forward to the shell: the quick
  /// switcher, and on desktop the zoom / session / help keys (run by
  /// [_desktopShortcuts], which sees the key after the terminal does).
  bool _keepFromSession(KeyEvent event) {
    if (isQuickSwitcherShortcut(event)) return true;
    if (widget.shell?.keepKey?.call(event) ?? false) return true;
    final match = matchDesktopShortcut(event);
    if (match == null) return false;
    return switch (match.action) {
      // Only the desktop shell splits and has unread rows.
      DesktopAction.splitRight ||
      DesktopAction.splitDown ||
      DesktopAction.nextUnread ||
      DesktopAction.commandPalette ||
      DesktopAction.toggleSidebar => _shellSync != null,
      // Alt+arrows stay the shell's word motion unless a split lies that
      // way.
      DesktopAction.focusPane =>
        _shellSync?.rendered.neighbor(ShellDirection.values[match.index]) !=
            null,
      _ => true,
    };
  }

  Future<void> _showDesktopShortcuts() async {
    await showDesktopShortcutsSheet(context);
    if (mounted) _focusNode.requestFocus();
  }

  /// Ctrl+Shift+T: the connect picker for the active session's machine
  /// (tmux, Herdr or a shell there), else the machine chooser.
  Future<void> _newSessionOnMachine(
    SessionConnectFlow connectFlow,
    TerminalSessionController? active,
  ) async {
    final hostId = active == null ? null : baseHostId(active.host.id);
    final host = connectFlow.hostsController.hosts
        .where((host) => host.id == hostId && !host.isLocal)
        .firstOrNull;
    final session = host == null
        ? await connectFlow.pickHostAndConnect(context)
        : await connectFlow.connect(context, host, forcePicker: true);
    if (!mounted) return;
    _showTerminal();
    _openPreferredView(session);
  }

  /// Whether closing [session] ends what runs in it: a connected plain
  /// shell (or local shell) does; a tmux or Herdr session only detaches.
  bool _closeEndsProcesses(TerminalSessionController session) {
    if (!session.isConnected) return false;
    final kind = widget.workspace.targetOf(session).kind;
    if (kind == ConnectTargetKind.tmux || kind == ConnectTargetKind.herdr) {
      return false;
    }
    return !session.host.startTmuxOnConnect;
  }

  /// Ctrl+Shift+W: closes the active session, after a confirmation when it
  /// would end running programs.
  Future<void> _closeSessionFromKeyboard(
    TerminalSessionController session,
  ) async {
    if (_closeEndsProcesses(session)) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          key: const ValueKey('close-session-confirm'),
          title: Text('Close ${session.title}?'),
          content: const Text(
            'This session is not in tmux or Herdr: closing it ends the shell '
            'and anything still running in it.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              autofocus: true,
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Close'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) {
        if (mounted) _focusNode.requestFocus();
        return;
      }
    }
    await widget.workspace.close(session);
    if (!mounted) return;
    if (!widget.workspace.hasSessions && _fileTabs.tabs.isEmpty) {
      // The desktop shell shows its dashboard on its own.
      if (widget.shell == null) Navigator.of(context).pop();
      return;
    }
    _showTerminal();
  }

  void _handlePathTap(TerminalSessionController session, String path) {
    if (session.host.isLocal) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(path, maxLines: 1, overflow: TextOverflow.ellipsis),
          duration: const Duration(seconds: 5),
          action: SnackBarAction(
            label: 'Open',
            onPressed: () => _fileTabs.open(session.host, path),
          ),
        ),
      );
  }

  /// A tapped link: a snackbar to open or copy it. Links to the host's own
  /// ports (localhost:3000) open in the live preview, since the phone's
  /// browser would look for them on the phone.
  void _handleLinkTap(TerminalSessionController session, String url) {
    final previewPort = _previewPortFor(session, url);
    final messenger = ScaffoldMessenger.of(context);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Row(
            children: [
              Expanded(
                child: Text(url, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              TextButton(
                onPressed: () {
                  messenger.hideCurrentSnackBar();
                  _copyToClipboard(url, 'Link copied');
                },
                child: const Text('Copy'),
              ),
            ],
          ),
          duration: const Duration(seconds: 5),
          action: SnackBarAction(
            label: previewPort == null ? 'Open' : 'Preview',
            onPressed: () => previewPort == null
                ? unawaited(_openInBrowser(url))
                : unawaited(
                    _openLivePreview(
                      session,
                      port: previewPort,
                      path: previewPathOf(url),
                    ),
                  ),
          ),
        ),
      );
  }

  Future<bool> _handleLinkLongPress(
    TerminalSessionController session,
    String url,
    String line,
  ) async {
    final previewPort = _previewPortFor(session, url);
    final action = await showTerminalLinkSheet(
      context,
      url: url,
      previewPort: previewPort,
    );
    if (!mounted || action == null) {
      return false;
    }
    switch (action) {
      case TerminalLinkAction.openInBrowser:
        unawaited(_openInBrowser(url));
      case TerminalLinkAction.openInPreview:
        unawaited(
          _openLivePreview(
            session,
            port: previewPort,
            path: previewPathOf(url),
          ),
        );
      case TerminalLinkAction.copyLink:
        _copyToClipboard(url, 'Link copied');
      case TerminalLinkAction.copyText:
        _copyToClipboard(line, 'Line copied');
    }
    return true;
  }

  int? _previewPortFor(TerminalSessionController session, String url) {
    if (!_hasSessionTools(session.host)) {
      return null;
    }
    return loopbackPreviewPort(url);
  }

  /// The menu's "Quick actions" for [session]'s project, when there is
  /// something to offer (see [sessionProjectOf]).
  VoidCallback? _quickActionsFor(TerminalSessionController? session) {
    if (session == null) return null;
    final personal = widget.themeController.quickActions;
    final project = sessionProjectOf(
      attention: widget.agentAttention,
      sessionHostId: session.host.id,
      sessionTitle: session.title,
      personal: personal,
    );
    if (project == null) return null;
    return () {
      final machine =
          widget.connectFlow?.hostsController.findById(
            baseHostId(session.host.id),
          ) ??
          session.host;
      unawaited(
        showSessionQuickActions(
          context,
          project: project,
          machine: machine,
          sessionHost: session.host,
          personal: personal,
          attention: widget.agentAttention,
          runner: QuickActionRunner(
            workspace: widget.workspace,
            attention: widget.agentAttention,
          ),
        ),
      );
    };
  }

  Future<void> _openInBrowser(String url) async {
    final uri = Uri.tryParse(url);
    var opened = false;
    if (uri != null) {
      try {
        opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (_) {
        opened = false;
      }
    }
    if (!opened && mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('No app can open it')));
    }
  }

  void _copyToClipboard(String text, String message) {
    unawaited(Clipboard.setData(ClipboardData(text: text)));
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
      );
  }

  Future<void> _closeFileTab(TerminalFileTab tab) async {
    if (tab.viewerKey.currentState?.isDirty ?? false) {
      final discard = await confirmDiscardChanges(context, fileName: tab.title);
      if (!discard || !mounted) return;
    }
    _fileTabs.close(tab);
  }

  static final Listenable _inertListenable = ChangeNotifier();

  /// The ⋮ menu's Settings: the app-wide services when the app provides
  /// them, else the appearance-level settings this page holds.
  Future<void> _openSettings() => showSettings(
    context,
    services:
        SettingsScope.maybeOf(context) ??
        SettingsServices(
          theme: widget.themeController,
          agentAttention: widget.agentAttention,
        ),
  );

  void _toggleFullscreen() {
    setState(() => _fullscreen = !_fullscreen);
    _setSystemUiFullscreen(_fullscreen);
    widget.shell?.onFullscreenChanged?.call(_fullscreen);
  }

  Future<void> _openPromptComposer(TerminalSessionController session) async {
    final hostId = session.host.id;
    await showPromptComposerSheet(
      context: context,
      initialText: _composeDrafts[hostId] ?? '',
      onDraftChanged: (draft) => _composeDrafts[hostId] = draft,
      onSend: session.sendComposed,
      submitEnter: widget.themeController.composeSubmitEnter,
      onSubmitEnterChanged: (enabled) =>
          unawaited(widget.themeController.setComposeSubmitEnter(enabled)),
      isConnected: () => session.isConnected,
      bracketedPasteSupported: () => session.bracketedPasteSupported,
      dictation: _dictation,
      imageAttacher: _promptImageAttacher(session.host),
      pasteImages: widget.themeController.pasteImagesAsFiles,
    );
    if (!mounted) {
      return;
    }
    // The sheet may have edited or cleared this session's draft; rebuild the
    // inline bar so it shows the latest text.
    setState(() => _composeRevision += 1);
    _focusNode.requestFocus();
  }

  /// Images go to the same per-host inbox as files shared into the app,
  /// and the composer inserts the uploaded path for the agent to read.
  PromptImageAttacher _promptImageAttacher(SavedHost host) =>
      sftpPromptImageAttacher(
        repository: widget.sftpRepository,
        host: host,
        context: () => context,
        source: widget.promptImageSource,
        preparer: widget.promptImagePreparer,
      );

  /// Paste with an image on the clipboard: uploads it to the host's share
  /// inbox and pastes its path (bracketed when the program asked for it, no
  /// Enter), which Claude Code reads as an image. Resolves to false when
  /// there is no image, or the setting is off, so the text is pasted.
  Future<bool> _pasteImageInto(TerminalSessionController session) async {
    if (!widget.themeController.pasteImagesAsFiles) return false;
    final paster = ClipboardImagePaster.fromAttacher(
      _promptImageAttacher(session.host),
    );
    try {
      final path = await paster.paste(
        onUploading: () {
          if (mounted) setState(() => _pasteStatus = 'Uploading image…');
        },
      );
      if (path == null) return false;
      if (mounted) unawaited(session.sendAppText(path, paste: true));
      return true;
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              key: const ValueKey('paste-image-failed'),
              content: Text(
                'Could not paste the image: '
                '${error is AppFailure ? error.userMessage : error}',
              ),
            ),
          );
      }
      return true;
    } finally {
      if (mounted && _pasteStatus != null) {
        setState(() => _pasteStatus = null);
      }
    }
  }

  /// "cd to…" from the Tmux+ menu or the Herdr navigator: the machine's
  /// recent directories, acted on in the way that fits the session.
  Future<void> _openRecentDirectories(TerminalSessionController session) async {
    final directories = widget.connectFlow?.recentDirectories;
    if (directories == null) {
      return;
    }
    final host = session.host;
    final hostId = baseHostId(host.id);
    final list = await directories.load(hostId);
    if (!mounted) {
      return;
    }
    final runnerFactory = widget.connectFlow?.runnerFactory;
    final inHerdr =
        ConnectTarget.fromSessionHostId(host.id)?.kind ==
        ConnectTargetKind.herdr;
    final canRunCommands =
        runnerFactory != null &&
        !host.isLocal &&
        host.authMethod != SshAuthMethod.hardwareKey;
    final actions = <RecentDirectoryAction>[
      if (inHerdr && canRunCommands) RecentDirectoryAction.herdrTab,
      if (host.startTmuxOnConnect) RecentDirectoryAction.tmuxWindow,
      RecentDirectoryAction.cd,
    ];
    final pick = await showRecentDirectoriesSheet(
      context: context,
      hostName: host.name,
      directories: list,
      actions: actions,
      currentDirectory: session.workingDirectory,
    );
    if (pick == null || !mounted) {
      _focusNode.requestFocus();
      return;
    }
    unawaited(directories.record(hostId, pick.directory));
    switch (pick.action) {
      case RecentDirectoryAction.cd:
        unawaited(session.sendAppText(cdCommand(pick.directory), submit: true));
      case RecentDirectoryAction.tmuxWindow:
        session.sendPrefix(host.tmuxPrefixKey);
        session.sendText(':');
        session.sendText(tmuxNewWindowCommand(pick.directory));
        _sendEnterSoon(session);
      case RecentDirectoryAction.herdrTab:
        final runner = runnerFactory!(host);
        try {
          final result = await runner.run(
            remoteToolCommand('herdr', herdrNewTabArguments(pick.directory)),
            timeout: const Duration(seconds: 10),
          );
          if (result.exitCode != 0 && mounted) {
            final detail = result.stderr.trim().split('\n').first;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'Herdr could not open a tab there'
                  '${detail.isEmpty ? '' : ': $detail'}',
                ),
              ),
            );
          }
        } catch (error) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Herdr could not open a tab: $error')),
            );
          }
        } finally {
          unawaited(runner.close());
        }
    }
    if (mounted) {
      _focusNode.requestFocus();
    }
  }

  /// Enter as its own write, like the compose bar: TUIs treat a line that
  /// arrives with its CR in one read as a paste.
  void _sendEnterSoon(TerminalSessionController session) {
    Future<void>.delayed(TerminalSessionController.composedEnterDelay, () {
      session.sendKey(TerminalKey.enter);
    });
  }

  Future<void> _openAgentAttention(AgentAttentionController attention) async {
    await showAgentAttentionSheet(
      context: context,
      controller: attention,
      onOpenAgent: (host, agent) {
        final flow = widget.connectFlow;
        if (flow != null) {
          // The agent's exact workspace, tab and pane, in the right tab.
          unawaited(flow.openAgent(host, agent));
          Navigator.of(context).pop();
          _focusNode.requestFocus();
          return;
        }
        // Navigate as close as possible: activate the host's terminal tab
        // and ask the provider to focus the agent in the remote UI.
        final session = widget.workspace.sessions
            .where((session) => session.host.id == host.id)
            .firstOrNull;
        if (session != null) {
          widget.workspace.activate(session);
        }
        unawaited(attention.focusAgent(host.id, agent));
        Navigator.of(context).pop();
        _focusNode.requestFocus();
      },
      onOpenChat: (host, agent) {
        Navigator.of(context).pop();
        unawaited(_openChatForAgent(attention, host, agent));
      },
    );
    if (mounted) {
      _focusNode.requestFocus();
    }
  }

  /// The Agents panel's Chat button: the companion on [host] decides, not
  /// the monitor's provider (Herdr-monitored machines can have it too).
  Future<void> _openChatForAgent(
    AgentAttentionController attention,
    SavedHost host,
    AgentInfo agent,
  ) async {
    final access = await checkChatViewAccessWithProgress(
      context,
      attention: attention,
      host: host,
    );
    if (access == null || !mounted) return;
    if (!access.ready) {
      await showChatViewUnavailable(context, host: host, access: access);
      return;
    }
    await openChatView(
      context: context,
      attention: attention,
      host: host,
      agent: agent,
      dictation: _dictation,
      onOpenTerminal: () => _showAgentTerminal(attention, host, agent),
      accessoryBuilder: _chatPreviewChip(host),
      imageAttacher: _promptImageAttacher(host),
      pasteImages: widget.themeController.pasteImagesAsFiles,
    );
  }

  /// After the chat view: show the agent's session and focus its pane.
  void _showAgentTerminal(
    AgentAttentionController attention,
    SavedHost host,
    AgentInfo agent,
  ) {
    if (!mounted) return;
    final flow = widget.connectFlow;
    if (flow != null) {
      // The agent's exact Herdr workspace, tab and pane, in the right tab
      // (a plain tab id match misses tabs opened on a Herdr target).
      unawaited(flow.openAgent(host, agent));
      _showTerminal();
      return;
    }
    final session = widget.workspace.sessions
        .where((session) => session.host.id == host.id)
        .firstOrNull;
    if (session != null) widget.workspace.activate(session);
    unawaited(attention.focusAgent(host.id, agent));
    _showTerminal();
  }

  /// A session the user picked (its tab, the session grid, a new one from
  /// the connect picker): Chat View when its effective view is Chat View
  /// and it runs a Claude session the companion knows, once that is known
  /// (see [openPreferredChatView]); the terminal otherwise.
  void _openPreferredView(TerminalSessionController? session) {
    final attention = widget.agentAttention;
    if (!mounted ||
        session == null ||
        attention == null ||
        widget.workspace.activeSession != session) {
      return;
    }
    unawaited(
      openPreferredChatView(
        context,
        attention: attention,
        workspace: widget.workspace,
        session: session,
        herdr: widget.connectFlow?.herdr,
        dictation: _dictation,
        onOpenTerminal: (host, agent) =>
            _showAgentTerminal(attention, host, agent),
      ),
    );
  }

  /// Long-press on a session's tab: where it opens when it runs Claude.
  Future<void> _pickSessionView(TerminalSessionController session) async {
    final views = SessionViewScope.maybeOf(context);
    if (views == null || session.host.isLocal) return;
    await showSessionViewPicker(
      context,
      controller: views,
      sessionHostId: session.host.id,
      title: session.title,
    );
    if (mounted) _focusNode.requestFocus();
  }

  /// A horizontal swipe on the top row: the next (1) or previous (-1)
  /// open session, sliding in from that side.
  void _swipeSession(int direction) {
    final sessions = widget.workspace.sessions;
    final active = widget.workspace.activeSession;
    if (active == null) return;
    final index = sessions.indexOf(active) + direction;
    if (index < 0 || index >= sessions.length) return;
    widget.workspace.activate(sessions[index]);
    _showTerminal();
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) return;
    _slideDirection = direction;
    unawaited(_slide.forward(from: 0));
  }

  Widget _slideIn(Widget child) {
    return ClipRect(
      child: AnimatedBuilder(
        animation: _slide,
        child: child,
        builder: (context, child) {
          final sliding = _slide.status == AnimationStatus.forward;
          final remaining = sliding
              ? 1 - Curves.easeOutCubic.transform(_slide.value)
              : 0.0;
          return FractionalTranslation(
            translation: Offset(_slideDirection * remaining * 0.3, 0),
            child: child,
          );
        },
      ),
    );
  }

  bool _switcherOpen = false;

  QuickSwitcherSource get _switcherSource => QuickSwitcherSource(
    workspace: widget.workspace,
    attention: widget.agentAttention,
    connectFlow: widget.connectFlow,
    homeBoards: widget.homeBoards,
  );

  /// The quick switcher (grid button, swipes on the top row, Ctrl+K).
  Future<void> _openSwitcher({bool fromKeyboard = false}) async {
    // In the desktop shell, the command palette lists the same and more.
    if (widget.shell?.onOpenPalette case final openPalette?) {
      openPalette();
      return;
    }
    if (_switcherOpen) return;
    _switcherOpen = true;
    final source = _switcherSource;
    final connectFlow = widget.connectFlow;
    final QuickSwitcherChoice? choice;
    try {
      choice = await showQuickSwitcher(
        context,
        source: source,
        fontFamily: widget.themeController.terminalFont.fontFamily,
        fromKeyboard: fromKeyboard,
        canCreate: connectFlow != null,
        canShowGrid: true,
      );
    } finally {
      _switcherOpen = false;
    }
    if (!mounted) return;
    switch (choice) {
      case QuickSwitcherOpen(:final item):
        await openSwitcherItem(
          context,
          item,
          source: source,
          showTerminal: _showTerminal,
          dictation: _dictation,
        );
      case QuickSwitcherNewSession():
        if (connectFlow != null) await _openNewSession(connectFlow);
      case QuickSwitcherShowGrid():
        await _openSessionGrid();
      case null:
        _showTerminal();
    }
  }

  Future<void> _openSessionGrid() async {
    final before = widget.workspace.activeSession;
    await showSessionGrid(
      context,
      workspace: widget.workspace,
      themeController: widget.themeController,
      agentAttention: widget.agentAttention,
      connectFlow: widget.connectFlow,
    );
    if (!mounted) return;
    _showTerminal();
    final active = widget.workspace.activeSession;
    if (active != before) _openPreferredView(active);
  }

  Future<void> _openNewSession(SessionConnectFlow connectFlow) async {
    final session = await connectFlow.pickHostAndConnect(context);
    if (!mounted) return;
    _showTerminal();
    _openPreferredView(session);
  }

  /// The Herdr command channel for [session]'s gestures. For a session
  /// that drives Herdr it also has the machine's Herdr keymap read (once,
  /// read-only), so key-labelled shortcuts and key fallbacks use its own
  /// bindings.
  HerdrRemoteControl? _herdrControlFor(TerminalSessionController session) {
    final herdr = widget.connectFlow?.herdr;
    if (herdr == null) {
      return null;
    }
    final drivesHerdr =
        (_gestureTargetFor(session) ??
            widget.themeController.terminalGestures.windowSwitchTarget) ==
        TerminalWindowSwitchTarget.herdr;
    if (drivesHerdr) {
      herdr.ensureKeymap(session);
    }
    return herdr.controlFor(session);
  }

  /// Enters copy mode for a one-finger drag on a tmux or Herdr session
  /// whose screen offers no other way into history (tmux without `mouse
  /// on`): the two-finger scrollback's keys, then the scroll-mode state.
  /// Null for plain shells, where such a drag sends arrow keys.
  VoidCallback? _dragScrollModeEntry(TerminalSessionController session) {
    final target = _gestureTargetFor(session);
    if (target == null) {
      return null;
    }
    return () {
      TerminalGestureCommands(
        session,
        target,
        herdr: _herdrControlFor(session),
      ).enterScrollback();
      setState(() => _tmuxScrollMode = true);
      _focusNode.requestFocus();
    };
  }

  /// The multiplexer a session's gestures drive: the one it was opened on
  /// (a host that starts tmux on connect is a tmux session too), or null
  /// (the Gestures preference) for plain shells.
  static TerminalWindowSwitchTarget? _gestureTargetFor(
    TerminalSessionController session,
  ) {
    return switch (ConnectTarget.fromSessionHostId(session.host.id)?.kind) {
      ConnectTargetKind.herdr => TerminalWindowSwitchTarget.herdr,
      ConnectTargetKind.tmux => TerminalWindowSwitchTarget.tmux,
      ConnectTargetKind.shell || ConnectTargetKind.directory || null =>
        session.host.startTmuxOnConnect
            ? TerminalWindowSwitchTarget.tmux
            : null,
    };
  }

  /// Gesture hook: swipe in from the right edge opens the agent attention
  /// sheet when monitoring is available, otherwise the gesture is off.
  VoidCallback? _agentPanelOpener() {
    final attention = widget.agentAttention;
    if (attention == null) {
      return null;
    }
    return () => _openAgentAttention(attention);
  }

  void _setSystemUiFullscreen(bool fullscreen) {
    SystemChrome.setEnabledSystemUIMode(
      fullscreen ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    );
  }

  void _openSessionTool(TerminalSessionController session, SessionTool tool) {
    switch (tool) {
      case SessionTool.gitDiff:
        _openGitDiff(session);
      case SessionTool.livePreview:
        unawaited(_openLivePreview(session));
    }
  }

  void _openGitDiff(TerminalSessionController session) {
    final host = session.host;
    final runner = _commandRunnerFor(host);
    if (runner == null) {
      return;
    }
    final tab = _fileTabs.add(
      DiffViewTab(
        host: host,
        controller: DiffViewController(SshGitDiffSource(runner, host)),
      ),
    );
    if (tab is DiffViewTab && tab.controller.phase == DiffViewPhase.idle) {
      unawaited(tab.controller.start());
    }
  }

  /// Opens the host's live preview tab. With [port] (a tapped
  /// localhost link) the port dialog is skipped and [path] is loaded.
  Future<void> _openLivePreview(
    TerminalSessionController session, {
    int? port,
    String? path,
  }) async {
    final host = session.host;
    if (!_hasSessionTools(host)) {
      return;
    }
    final existing = _fileTabs.tabs
        .whereType<LivePreviewTab>()
        .where((tab) => tab.host.id == host.id)
        .firstOrNull;
    if (existing != null) {
      _fileTabs.activate(existing);
      final controller = existing.controller;
      if (port != null &&
          (controller.remotePort != port ||
              controller.path !=
                  LivePreviewController.normalizePath(path ?? '/'))) {
        controller.setPath(path ?? '/');
        // Restarting rebinds the local port, which reloads the WebView on
        // the new path.
        unawaited(controller.start(port));
      }
      if (port != null) _previewWatchers[session]?.markPreviewing(port);
      return;
    }
    final controller = LivePreviewController(
      _portForwarderFor(host)!,
      hostId: host.id,
      portStore: switch (widget.connectFlow?.hostsController) {
        final hosts? => FallbackLivePreviewPortStore(
          widget.livePreviewPortStore,
          hosts.fallbackHostIdFor,
        ),
        null => widget.livePreviewPortStore,
      },
      commandRunner: _commandRunnerFor(host),
    );
    final int? chosenPort;
    if (port != null) {
      chosenPort = port;
      controller.setPath(path ?? '/');
    } else {
      final initialPort = await controller.suggestedPort();
      if (!mounted) {
        controller.dispose();
        return;
      }
      chosenPort = await showLivePreviewPortDialog(
        context,
        initialPort: initialPort,
        detectPorts: controller.detectPorts,
        hostName: host.name,
      );
    }
    if (chosenPort == null || !mounted) {
      controller.dispose();
      return;
    }
    controller.attachSession(session, () => session.isConnected);
    _fileTabs.add(LivePreviewTab(host: host, controller: controller));
    unawaited(controller.start(chosenPort));
    _previewWatchers[session]?.markPreviewing(chosenPort);
  }

  /// Live preview's "Screenshot to Claude": uploads the image to the
  /// host's share inbox (like a Chat mode image) and puts its path and a
  /// note in front of Claude: Chat View's composer when this session runs
  /// a Claude session the companion knows, else the Chat mode composer.
  Future<void> _sendPreviewScreenshot(
    LivePreviewTab tab,
    PreviewScreenshot shot,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('Uploading screenshot…'),
          duration: Duration(minutes: 1),
        ),
      );
    final String draft;
    try {
      draft = await PreviewScreenshotSender(
        upload: (file) async => (await SftpShareUploader(
          widget.sftpRepository,
        ).upload(tab.host, [file])).single,
      ).send(shot);
    } catch (error) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              'Could not upload the screenshot: '
              '${error is AppFailure ? error.userMessage : error}',
            ),
          ),
        );
      return;
    }
    messenger.hideCurrentSnackBar();
    if (!mounted) return;
    final session = widget.workspace.sessions
        .where((session) => session.host.id == tab.host.id)
        .firstOrNull;
    if (session == null) {
      _copyToClipboard(draft, 'Screenshot uploaded; its path is copied');
      return;
    }
    await _deliverChatDraft(session, draft);
  }

  /// Opens [session]'s chat with [draft] in the composer: Chat View when
  /// it can, else Chat mode's composer sheet.
  Future<void> _deliverChatDraft(
    TerminalSessionController session,
    String draft,
  ) async {
    if (widget.workspace.activeSession != session) {
      widget.workspace.activate(session);
    }
    _showTerminal();
    final attention = widget.agentAttention;
    if (attention != null && !session.host.isLocal) {
      final opened = await _openChatForSession(
        attention,
        session,
        draft: draft,
      );
      if (opened || !mounted) return;
    }
    _putDraftInComposer(session, draft);
  }

  /// Adds [draft] to [session]'s Chat mode draft and opens the composer
  /// sheet, the way a file shared into the app arrives.
  void _putDraftInComposer(TerminalSessionController session, String draft) {
    final hostId = session.host.id;
    setState(() {
      _composeDrafts[hostId] = mergeShareDraft(
        _composeDrafts[hostId] ?? '',
        draft,
      );
      _composeMode = true;
      _composeRevision += 1;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.workspace.activeSession == session) {
        unawaited(_openPromptComposer(session));
      }
    });
  }

  Future<void> _changePreviewPort(LivePreviewTab tab) async {
    final controller = tab.controller;
    final initialPort =
        controller.remotePort ?? await controller.suggestedPort();
    if (!mounted) {
      return;
    }
    final port = await showLivePreviewPortDialog(
      context,
      initialPort: initialPort,
      detectPorts: controller.detectPorts,
      hostName: tab.host.name,
    );
    if (port != null && mounted) {
      unawaited(controller.start(port));
    }
  }

  Widget _buildFileTab(
    TerminalFileTab tab,
    AppPalette palette,
    Brightness brightness,
  ) {
    final fontFamily = widget.themeController.terminalFont.fontFamily;
    if (tab.viewBuilder case final builder?) {
      return Builder(key: ValueKey(tab), builder: builder);
    }
    return switch (tab) {
      DiffViewTab() => DiffView(
        key: ValueKey(tab),
        controller: tab.controller,
        palette: palette,
        brightness: brightness,
        fontFamily: fontFamily,
        onOpenFile: (path) => _fileTabs.open(tab.host, path),
      ),
      LivePreviewTab() => LivePreviewView(
        key: ValueKey(tab),
        controller: tab.controller,
        palette: palette,
        brightness: brightness,
        onChangePort: () => unawaited(_changePreviewPort(tab)),
        onScreenshot: (shot) => _sendPreviewScreenshot(tab, shot),
      ),
      _ => SftpFileViewer(
        key: tab.viewerKey,
        path: tab.path,
        palette: palette,
        brightness: brightness,
        fontFamily: fontFamily,
        read: (onProgress) => _fileTabs.read(tab, onProgress),
        write: (bytes) => _fileTabs.write(tab, bytes),
      ),
    };
  }

  /// The back / home button, and the empty state's: the previous route,
  /// or the desktop shell's dashboard.
  void _leave() {
    final shell = widget.shell;
    if (shell != null) {
      shell.onShowHome();
    } else {
      Navigator.of(context).pop();
    }
  }

  /// The desktop shell's tab strip: every session and file-like view.
  Widget _buildShellTabs(
    TerminalSessionController? activeSession,
    TerminalFileTab? activeFileTab,
    List<TerminalFileTab> fileTabs,
  ) {
    final shell = widget.shell!;
    final sessions = widget.workspace.sessions;
    final rendered = _shellSync!.rendered;
    ShellTabBadge badge(String viewId) =>
        shell.badgeFor?.call(viewId) ?? const ShellTabBadge();
    final tabs = <ShellTabData>[
      for (final session in sessions)
        () {
          final viewId = sessionViewId(session);
          final info = badge(viewId);
          return ShellTabData(
            viewId: viewId,
            label: SessionTabs.labelFor(session, sessions),
            tooltip: '${session.title}\n${session.host.endpoint}',
            leading: SessionTabLeading(session: session),
            dot: info.dot,
            unread: info.unread,
            isSession: true,
          );
        }(),
      for (final tab in fileTabs)
        ShellTabData(
          viewId: tab.viewId,
          label: tab.title,
          tooltip: tab.tooltip,
          leading: Icon(
            tab.icon,
            size: 13,
            color: widget.themeController.palette.accent,
          ),
          dirty: tab.viewerKey.currentState?.isDirty ?? false,
          listenable: tab.listenable,
        ),
    ];
    return ShellTabStrip(
      tabs: tabs,
      focusedViewId: activeViewId,
      visibleViews: rendered.visibleViews,
      canSplit: rendered.canSplit,
      onSelect: (viewId) {
        activateView(viewId);
        _showShellTerminalFocus(viewId);
      },
      onClose: (viewId) => unawaited(closeView(viewId)),
      onAction: (viewId, action) {
        final edge = edgeForTabAction(action);
        if (edge == null) {
          unawaited(closeView(viewId));
          return;
        }
        _dropView(rendered.focusedPane.id, edge, viewId);
      },
    );
  }

  void _showShellTerminalFocus(String viewId) {
    if (_sessionForView(viewId) != null) _focusNode.requestFocus();
  }

  /// A tab dropped on a pane (or its menu's split): split there, or show
  /// it in that pane.
  void _dropView(String paneId, ShellEdge edge, String viewId) {
    final shell = widget.shell;
    final sync = _shellSync;
    if (shell == null || sync == null) return;
    shell.controller.editLayout(viewIds.toSet(), (layout) {
      // Splitting a pane with its own view: the old pane shows the most
      // recent view that is on no pane.
      final fallback = sync.recent
          .where(
            (view) => view != viewId && !layout.visibleViews.contains(view),
          )
          .firstOrNull;
      return layout.split(paneId, edge, viewId, fallbackView: fallback);
    });
    _showShellTerminalFocus(viewId);
  }

  ShellPaneTitle _titleForView(String viewId) {
    final session = _sessionForView(viewId);
    final badge = widget.shell?.badgeFor?.call(viewId);
    if (session != null) {
      return ShellPaneTitle(
        SessionTabs.labelFor(session, widget.workspace.sessions),
        leading: SessionTabLeading(session: session),
        dot: badge?.dot ?? SidebarDot.none,
      );
    }
    final tab = _tabForView(viewId);
    return ShellPaneTitle(
      tab?.title ?? '',
      leading: tab == null
          ? null
          : Icon(
              tab.icon,
              size: 13,
              color: widget.themeController.palette.accent,
            ),
    );
  }

  /// The desktop shell's panes: every view built once, placed by the
  /// saved split layout.
  Widget _buildShellPanes(
    List<Widget> overlays,
    TerminalSessionController? activeSession,
    TerminalFileTab? activeFileTab,
    AppPalette palette,
    Brightness brightness,
  ) {
    final shell = widget.shell!;
    final views = <String, Widget>{
      for (final session in widget.workspace.sessions)
        sessionViewId(session): _sessionView(
          session,
          activeSession,
          activeFileTab,
          palette,
          brightness,
        ),
      for (final tab in _fileTabs.tabs)
        tab.viewId: _buildFileTab(tab, palette, brightness),
    };
    return ShellSplitArea(
      key: const ValueKey('shell-split-area'),
      layout: _shellSync!.rendered,
      views: views,
      focusedOverlay: overlays,
      titleFor: _titleForView,
      onFocusPane: (paneId) => shell.controller.editLayout(
        views.keys.toSet(),
        (layout) => layout.focus(paneId),
      ),
      onDrop: _dropView,
      onResize: (path, ratio) => shell.controller.editLayout(
        views.keys.toSet(),
        (layout) => layout.resize(path, ratio),
      ),
      onClosePane: (paneId) => shell.controller.editLayout(
        views.keys.toSet(),
        (layout) => layout.closePane(paneId),
      ),
      onSwap: (from, to) => shell.controller.editLayout(
        views.keys.toSet(),
        (layout) => layout.swap(from, to),
      ),
      onDropNode: shell.onDropNode,
      onFillPane: shell.onFillPane,
    );
  }

  /// The focus banner's actions for a Herdr session while this device may
  /// not move Herdr's focus on its own; null otherwise.
  HerdrFocusActions? _herdrFocusActionsFor(TerminalSessionController session) {
    final herdr = widget.connectFlow?.herdr;
    if (herdr == null ||
        herdr.mayMoveFocus ||
        HerdrSessionFocus.herdrTargetOf(session) == null ||
        herdr.controlFor(session) == null) {
      return null;
    }
    void failed(String message) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(message)));
    }

    return HerdrFocusActions(
      typeInComposer: (held) {
        final hostId = session.host.id;
        if (held.isNotEmpty) {
          _composeDrafts[hostId] = '${_composeDrafts[hostId] ?? ''}$held';
        }
        widget.workspace.activate(session);
        unawaited(_openPromptComposer(session));
      },
      takeFocusOnce: () async {
        widget.workspace.activate(session);
        if (!await herdr.takeFocusOnce(session)) {
          failed('Herdr did not switch: the typed keys are still held.');
        }
        _focusNode.requestFocus();
      },
      useShownWorkspace: () async {
        if (!await herdr.useShownWorkspace(session)) {
          failed("Couldn't read what Herdr shows.");
        }
        _focusNode.requestFocus();
      },
    );
  }

  /// One session's terminal (gestures, surface), as a tab's content or a
  /// pane of the desktop shell.
  Widget _sessionView(
    TerminalSessionController session,
    TerminalSessionController? activeSession,
    TerminalFileTab? activeFileTab,
    AppPalette palette,
    Brightness brightness,
  ) {
    final agentViews = widget.connectFlow?.herdr.agentViews;
    final terminal = TerminalGestureLayer(
      key: ValueKey(session.host.id),
      target: _gestureTargetFor(session),
      herdrControl: _herdrControlFor(session),
      onHerdrWorkspaceFocused: (workspaceId) =>
          widget.connectFlow?.herdr.noteWorkspace(session, workspaceId),
      preferences: widget.themeController.terminalGestures,
      session: session,
      fontSize: widget.themeController.terminalFontSize,
      onFontSizeChanged: (fontSize) {
        unawaited(widget.themeController.setTerminalFontSize(fontSize));
      },
      scrollMode: session == activeSession && _tmuxScrollMode,
      onEnterScrollMode: () {
        setState(() => _tmuxScrollMode = true);
        _focusNode.requestFocus();
      },
      onExitScrollMode: () {
        setState(() => _tmuxScrollMode = false);
        _focusNode.requestFocus();
      },
      onOpenSessionGrid: _openSwitcher,
      onOpenAgentPanel: _agentPanelOpener(),
      child: TerminalSurface(
        session: session,
        onLinkOpen: (url) => unawaited(_openInBrowser(url)),
        autoConnect: widget.workspace.mayAutoConnect(session),
        palette: palette,
        brightness: brightness,
        fontFamily: widget.themeController.terminalFont.fontFamily,
        fontSize: widget.themeController.terminalFontSize,
        predictiveEchoEnabled: session.host.predictiveEchoEnabled,
        terminalMouseInput: widget.themeController.terminalMouseInput,
        focusNode: session == activeSession && activeFileTab == null
            ? _focusNode
            : null,
        tmuxScrollMode: session == activeSession && _tmuxScrollMode,
        onExitTmuxScrollMode: () {
          setState(() => _tmuxScrollMode = false);
          _focusNode.requestFocus();
        },
        onPathTap: (path) => _handlePathTap(session, path),
        onLinkTap: (url) => _handleLinkTap(session, url),
        dragScrollsRemote:
            widget.themeController.terminalGestures.dragScrollsRemote,
        onEnterScrollMode: _dragScrollModeEntry(session),
        onKeyEvent: (_, event) => _handleTerminalKey(session, event),
        onLinkLongPress: (url, line) =>
            _handleLinkLongPress(session, url, line),
        onPasteImage: () => _pasteImageInto(session),
      ),
    );
    Widget frame(bool agentView) => SessionFocusFrame(
      key: ValueKey('focus-frame-${session.host.id}'),
      session: session,
      palette: palette,
      brightness: brightness,
      fontFamily: widget.themeController.terminalFont.fontFamily,
      // Only a desktop split shows sessions that are not the active one.
      showSharedView: widget.shell != null && session != activeSession,
      showAgentView: agentView,
      herdrActions: _herdrFocusActionsFor(session),
      child: terminal,
    );
    if (agentViews == null) return frame(false);
    return ValueListenableBuilder<Set<TerminalSessionController>>(
      key: ValueKey('agent-view-${session.host.id}'),
      valueListenable: agentViews,
      builder: (context, views, _) => frame(views.contains(session)),
    );
  }

  void _setTouchKeysVisible(bool visible) {
    setState(() => _touchKeysVisible = visible);
    _focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.themeController,
      builder: (context, _) {
        final palette = widget.themeController.palette;
        return QuickSwitcherShortcut(
          // In the desktop shell, the home page's switcher answers.
          enabled: widget.shell == null,
          onInvoke: () => unawaited(_openSwitcher(fromKeyboard: true)),
          child: Scaffold(
            body: ListenableBuilder(
              listenable: Listenable.merge([
                widget.workspace,
                _fileTabs,
                ?widget.shell?.controller.layout,
              ]),
              builder: (context, _) {
                final activeSession = widget.workspace.activeSession;
                final fileTabs = _fileTabs.tabs;
                final activeFileTab = _fileTabs.active;
                final brightness = Theme.of(context).brightness;
                if (activeSession == null && fileTabs.isEmpty) {
                  return ConduitBackdrop(
                    palette: palette,
                    child: SafeArea(
                      bottom: shouldApplyBottomSafeArea(context),
                      child: EmptyTerminalState(onBack: _leave),
                    ),
                  );
                }

                final landscape =
                    MediaQuery.orientationOf(context) == Orientation.landscape;
                final gestureNavigation = usesAndroidGestureNavigation(context);
                return SafeArea(
                  top: !_fullscreen,
                  bottom: shouldApplyBottomSafeArea(context),
                  left: !_fullscreen && (!landscape || !gestureNavigation),
                  right: !_fullscreen && (!landscape || !gestureNavigation),
                  child: Column(
                    children: [
                      if (!_fullscreen)
                        ListenableBuilder(
                          listenable: Listenable.merge([
                            widget.agentAttention ?? _inertListenable,
                            ?widget.shell?.controller.unreadChanges,
                          ]),
                          builder: (context, _) {
                            final attention = widget.agentAttention;
                            final showAgents =
                                attention != null &&
                                (attention.monitoredHosts.isNotEmpty ||
                                    (activeSession
                                            ?.host
                                            .agentAttentionEnabled ??
                                        false));
                            final connectFlow = widget.connectFlow;
                            return TerminalHeader(
                              workspace: widget.workspace,
                              activeSession: activeSession,
                              palette: palette,
                              brightness: brightness,
                              onBack: _leave,
                              tabs: widget.shell == null
                                  ? null
                                  : _buildShellTabs(
                                      activeSession,
                                      activeFileTab,
                                      fileTabs,
                                    ),
                              backIcon: widget.shell == null
                                  ? Icons.chevron_left_rounded
                                  : Icons.space_dashboard_outlined,
                              backTooltip: widget.shell == null
                                  ? 'Machines'
                                  : 'Home',
                              leavesWhenEmpty: widget.shell == null,
                              onOpenSettings: () => unawaited(_openSettings()),
                              onTabsChanged: _showTerminal,
                              fileTabs: fileTabs,
                              activeFileTab: activeFileTab,
                              onFileTabSelected: _fileTabs.activate,
                              onFileTabClosed: _closeFileTab,
                              onReconnect: activeSession == null
                                  ? null
                                  : () async {
                                      await activeSession.disconnect();
                                      await activeSession.connect();
                                      _focusNode.requestFocus();
                                    },
                              onToggleFullscreen: _toggleFullscreen,
                              onNewSession: connectFlow == null
                                  ? null
                                  : () => _openNewSession(connectFlow),
                              onShowShortcuts: PlatformFeatures.isDesktop
                                  ? () => unawaited(_showDesktopShortcuts())
                                  : null,
                              onQuickActions: _quickActionsFor(activeSession),
                              onComposePrompt:
                                  PlatformFeatures.isDesktop &&
                                      activeSession != null
                                  ? () => unawaited(
                                      _openPromptComposer(activeSession),
                                    )
                                  : null,
                              onRecentDirectories:
                                  PlatformFeatures.isDesktop &&
                                      activeSession != null
                                  ? () => unawaited(
                                      _openRecentDirectories(activeSession),
                                    )
                                  : null,
                              onOpenChatView:
                                  attention == null ||
                                      activeSession == null ||
                                      activeSession.host.isLocal
                                  ? null
                                  : () => openChatViewForHost(
                                      context: context,
                                      attention: attention,
                                      host: activeSession.host,
                                      dictation: _dictation,
                                      accessoryBuilder: _chatPreviewChip(
                                        activeSession.host,
                                      ),
                                      imageAttacher: _promptImageAttacher(
                                        activeSession.host,
                                      ),
                                      pasteImages: widget
                                          .themeController
                                          .pasteImagesAsFiles,
                                      onOpenTerminal: (agent) =>
                                          _showAgentTerminal(
                                            attention,
                                            activeSession.host,
                                            agent,
                                          ),
                                    ),
                              attentionCount: attention?.attentionCount ?? 0,
                              onOpenAgentAttention: !showAgents
                                  ? null
                                  : widget.shell?.onToggleAgents ??
                                        () => _openAgentAttention(attention),
                              extraActions:
                                  widget.shell?.headerActions?.call() ??
                                  const [],
                              onOpenSessionGrid: _openSwitcher,
                              onSwipeSession: _swipeSession,
                              onSessionActivated: _openPreferredView,
                              multiplexerTabsFor:
                                  _muxLayout == MultiplexerTabsLayout.compact
                                  ? _muxTabsFor
                                  : null,
                              onOpenMultiplexerTabs: _openMuxTabsSheet,
                              onSessionLongPress: (session) =>
                                  unawaited(_pickSessionView(session)),
                              swipeDownOpensSessionGrid: widget
                                  .themeController
                                  .terminalGestures
                                  .headerSwipeOpensSessions,
                              onOpenSessionTool:
                                  activeSession != null &&
                                      _hasSessionTools(activeSession.host)
                                  ? (tool) =>
                                        _openSessionTool(activeSession, tool)
                                  : null,
                            );
                          },
                        ),
                      // Keeps the active session's multiplexer tabs fresh;
                      // only the strip layout takes a row.
                      if (activeFileTab == null && activeSession != null)
                        if (_muxTabsFor(activeSession) case final muxTabs?)
                          MultiplexerTabsPoller(
                            key: ValueKey('mux-tabs-${activeSession.host.id}'),
                            controller: muxTabs,
                            active: _muxLayout != MultiplexerTabsLayout.hidden,
                            interval:
                                _muxLayout == MultiplexerTabsLayout.compact
                                ? MultiplexerTabsController.compactPollInterval
                                : MultiplexerTabsController.listPollInterval,
                            child:
                                !_fullscreen &&
                                    _muxLayout == MultiplexerTabsLayout.strip
                                ? MultiplexerTabStrip(
                                    controller: muxTabs,
                                    palette: palette,
                                    brightness: brightness,
                                    desktop: PlatformFeatures.isDesktop,
                                    onChanged: _focusNode.requestFocus,
                                  )
                                : const SizedBox.shrink(),
                          ),
                      Expanded(
                        child: Builder(
                          builder: (context) {
                            // Chips and bars of the focused session: over
                            // the whole area, or its pane in the shell.
                            final overlays = <Widget>[
                              if (activeFileTab == null &&
                                  activeSession != null &&
                                  _muxLayout == MultiplexerTabsLayout.compact &&
                                  _muxTabs[activeSession.host.id] != null)
                                Positioned.fill(
                                  child: MultiplexerTabOverlay(
                                    key: ValueKey(
                                      'mux-overlay-${activeSession.host.id}',
                                    ),
                                    controller:
                                        _muxTabs[activeSession.host.id]!,
                                  ),
                                ),
                              if (_pasteStatus case final status?)
                                Positioned(
                                  top: 8,
                                  left: 8,
                                  child: _PasteStatusChip(text: status),
                                ),
                              if (activeFileTab == null &&
                                  activeSession != null &&
                                  activeSession.runsOnThisComputer &&
                                  activeSession.status ==
                                      TerminalConnectionStatus.disconnected)
                                Positioned(
                                  left: 16,
                                  right: 16,
                                  bottom: 16,
                                  child: Center(
                                    child: _ShellExitedBar(
                                      key: ValueKey(
                                        'shell-exited-${activeSession.host.id}',
                                      ),
                                      exitCode: activeSession.exitCode,
                                      onRestart: () async {
                                        await activeSession.connect();
                                        _focusNode.requestFocus();
                                      },
                                    ),
                                  ),
                                ),
                              if (activeFileTab == null &&
                                  activeSession != null &&
                                  _previewWatchers[activeSession] != null)
                                Positioned(
                                  top: 8,
                                  right: 8,
                                  child: PreviewReadyChip(
                                    key: ValueKey(
                                      'preview-ready-${activeSession.host.id}',
                                    ),
                                    controller:
                                        _previewWatchers[activeSession]!,
                                    hidden: (offer) =>
                                        _previewShows(activeSession, offer),
                                    onOpen: (offer) => unawaited(
                                      _openLivePreview(
                                        activeSession,
                                        port: offer.port,
                                        path: offer.path,
                                      ),
                                    ),
                                  ),
                                ),
                            ];
                            final content = Container(
                              color: palette.terminalBackgroundFor(brightness),
                              child:
                                  activeFileTab == null && activeSession == null
                                  ? EmptyTerminalState(onBack: _leave)
                                  : widget.shell != null
                                  ? _buildShellPanes(
                                      overlays,
                                      activeSession,
                                      activeFileTab,
                                      palette,
                                      brightness,
                                    )
                                  : _slideIn(
                                      IndexedStack(
                                        index: activeFileTab != null
                                            ? widget.workspace.sessions.length +
                                                  fileTabs.indexOf(
                                                    activeFileTab,
                                                  )
                                            : widget.workspace.sessions.indexOf(
                                                activeSession!,
                                              ),
                                        children: [
                                          for (final session
                                              in widget.workspace.sessions)
                                            _sessionView(
                                              session,
                                              activeSession,
                                              activeFileTab,
                                              palette,
                                              brightness,
                                            ),
                                          for (final tab in fileTabs)
                                            _buildFileTab(
                                              tab,
                                              palette,
                                              brightness,
                                            ),
                                        ],
                                      ),
                                    ),
                            );
                            return Stack(
                              children: [
                                Positioned.fill(child: content),
                                if (widget.shell == null) ...overlays,
                              ],
                            );
                          },
                        ),
                      ),
                      // Menu → buttons: tappable choices for prompts on screen.
                      if (activeFileTab == null &&
                          activeSession != null &&
                          widget.themeController.menuButtonsEnabled)
                        PromptMenuStrip(
                          key: ValueKey('prompt-menu-${activeSession.host.id}'),
                          session: activeSession,
                          palette: palette,
                          brightness: brightness,
                          onSent: _focusNode.requestFocus,
                        ),
                      if (PlatformFeatures.isDesktop &&
                          _touchKeysVisible &&
                          activeFileTab == null &&
                          activeSession != null &&
                          !_composeMode)
                        _DesktopKeysToggle(
                          visible: true,
                          palette: palette,
                          brightness: brightness,
                          onChanged: _setTouchKeysVisible,
                        ),
                      if (activeFileTab != null || activeSession == null)
                        const SizedBox.shrink()
                      else if (_composeMode)
                        _ComposeInputBar(
                          key: ValueKey(
                            'compose-${activeSession.host.id}-$_composeRevision',
                          ),
                          palette: palette,
                          brightness: brightness,
                          history: _composeHistory,
                          initialText:
                              _composeDrafts[activeSession.host.id] ?? '',
                          dictation: _dictation,
                          startDictation: _dictateOnOpen,
                          onChanged: (draft) {
                            _composeDrafts[activeSession.host.id] = draft;
                          },
                          onExpand: () => _openPromptComposer(activeSession),
                          onSend: (line) {
                            if (!activeSession.isConnected) {
                              // The line would be silently dropped; keep it as
                              // the draft instead of clearing it.
                              setState(() {
                                _composeDrafts[activeSession.host.id] = line;
                                _composeRevision += 1;
                              });
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    'Not connected. The line was kept as a '
                                    'draft.',
                                  ),
                                ),
                              );
                              return;
                            }
                            // Send the line, then deliver Enter as a SEPARATE write a
                            // short moment later. Some remote TUIs (e.g. Claude Code
                            // and other Ink/readline apps) classify a single terminal
                            // read that contains a long line ending in CR as a *paste*
                            // and insert the trailing CR as a literal newline instead
                            // of submitting — so a wrapping compose line silently fails
                            // to send. Delivering Enter in its own read makes it an
                            // isolated keypress that submits regardless of line length.
                            // (sendAppText does exactly that; a Herdr session
                            // whose focus this device may not move gets the
                            // line by pane id instead.)
                            unawaited(
                              activeSession.sendAppText(line, submit: true),
                            );
                            setState(() {
                              // De-duplicate: drop any earlier identical entry so the
                              // ring keeps distinct lines (re-sending a recalled line
                              // can't churn duplicates that evict good older ones).
                              _composeHistory.remove(line);
                              _composeHistory.add(line);
                              if (_composeHistory.length >
                                  _composeHistoryLimit) {
                                _composeHistory.removeAt(0);
                              }
                              _composeDrafts[activeSession.host.id] = '';
                            });
                          },
                          onClose: (draft) {
                            setState(() {
                              _composeMode = false;
                              // Preserve the unsent draft for this session.
                              _composeDrafts[activeSession.host.id] = draft;
                            });
                            _focusNode.requestFocus();
                          },
                        )
                      else if (!_touchKeysVisible)
                        _DesktopKeysToggle(
                          visible: false,
                          palette: palette,
                          brightness: brightness,
                          onChanged: _setTouchKeysVisible,
                        )
                      else
                        TerminalKeyboardBar(
                          controller: activeSession,
                          focusNode: _focusNode,
                          palette: palette,
                          brightness: brightness,
                          rows: widget.themeController.terminalKeyboardRows,
                          globalSnippets:
                              widget.themeController.terminalSnippets,
                          fullscreen: _fullscreen,
                          onToggleFullscreen: _toggleFullscreen,
                          composeActive: _composeMode,
                          onToggleCompose: () =>
                              setState(() => _composeMode = !_composeMode),
                          onChatButton: () => _handleChatButton(activeSession),
                          onDictate: _dictation == null
                              ? null
                              : _startDictationLine,
                          tmuxPrefixKey: activeSession.host.tmuxPrefixKey,
                          tmuxScrollMode: _tmuxScrollMode,
                          terminalMouseInput:
                              widget.themeController.terminalMouseInput,
                          onTerminalMouseInputChanged: (enabled) {
                            unawaited(
                              widget.themeController.setTerminalMouseInput(
                                enabled,
                              ),
                            );
                            _focusNode.requestFocus();
                          },
                          onRemoteMouseTrackingActivated:
                              _maybeShowTouchModeHint,
                          onPasteImage: () => _pasteImageInto(activeSession),
                          onOpenRecentDirectories:
                              widget.connectFlow?.recentDirectories == null
                              ? null
                              : () => unawaited(
                                  _openRecentDirectories(activeSession),
                                ),
                          onEnterTmuxScrollMode: () {
                            setState(() => _tmuxScrollMode = true);
                            _focusNode.requestFocus();
                          },
                          onExitTmuxScrollMode: () {
                            setState(() => _tmuxScrollMode = false);
                            _focusNode.requestFocus();
                          },
                        ).withToolbarStyle(
                          widget.themeController.terminalToolbarStyle,
                          onReconnect: () async {
                            await activeSession.disconnect();
                            await activeSession.connect();
                          },
                          pillItems: widget.themeController.terminalPillItems,
                          onPillItemsChanged: (items) => unawaited(
                            widget.themeController.setTerminalPillItems(items),
                          ),
                          runnerFactory: widget.connectFlow?.runnerFactory,
                          liveFeed: widget.connectFlow?.live.feedFor,
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }
}

/// Desktop only: shows or hides the on-screen pill and key rows, which a
/// physical keyboard makes optional.
class _DesktopKeysToggle extends StatelessWidget {
  const _DesktopKeysToggle({
    required this.visible,
    required this.palette,
    required this.brightness,
    required this.onChanged,
  });

  final bool visible;
  final AppPalette palette;
  final Brightness brightness;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: palette.canvasFor(brightness),
      child: Align(
        alignment: Alignment.centerRight,
        child: TextButton.icon(
          key: const ValueKey('desktop-keys-toggle'),
          style: TextButton.styleFrom(
            foregroundColor: palette.mutedForegroundFor(brightness),
            visualDensity: VisualDensity.compact,
            // The theme's font: a bare TextStyle would drop it.
            textStyle: Theme.of(
              context,
            ).textTheme.labelMedium?.copyWith(fontSize: 12),
          ),
          onPressed: () => onChanged(!visible),
          icon: Icon(
            visible ? Icons.keyboard_hide_outlined : Icons.keyboard_outlined,
            size: 16,
          ),
          label: Text(visible ? 'Hide on-screen keys' : 'On-screen keys'),
        ),
      ),
    );
  }
}

class _ComposeInputBar extends StatefulWidget {
  const _ComposeInputBar({
    required this.palette,
    required this.brightness,
    required this.onSend,
    required this.onClose,
    this.onChanged,
    this.onExpand,
    this.history = const <String>[],
    this.initialText = '',
    this.dictation,
    this.startDictation = false,
    super.key,
  });

  final AppPalette palette;
  final Brightness brightness;
  final ValueChanged<String> onSend;

  /// Called on every edit with the current field text so the owner can keep
  /// the per-session draft up to date even if the bar is torn down (e.g. on
  /// a tab switch) without a close event.
  final ValueChanged<String>? onChanged;

  /// Opens the full multiline composer seeded with the current draft.
  final VoidCallback? onExpand;

  /// Called on close with the current (unsent) field text so the caller can
  /// preserve it — closing compose must not silently discard a draft.
  final ValueChanged<String> onClose;

  /// Recently sent lines, oldest first; shown most-recent-first in the recall
  /// menu. Deduplicated by the caller.
  final List<String> history;

  /// Draft text to restore into the field when compose reopens.
  final String initialText;

  /// Voice input; null hides the mic.
  final DictationController? dictation;

  /// Start dictating as the bar opens.
  final bool startDictation;

  @override
  State<_ComposeInputBar> createState() => _ComposeInputBarState();
}

class _ComposeInputBarState extends State<_ComposeInputBar> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    if (widget.initialText.isNotEmpty) {
      _controller.value = TextEditingValue(
        text: widget.initialText,
        selection: TextSelection.collapsed(offset: widget.initialText.length),
      );
    }
    _controller.addListener(_notifyChanged);
    // Ask for focus now, not after the first frame: the request is applied
    // as soon as the field is in the tree, so the keyboard comes up in the
    // same frame the bar replaces the pill. A post-frame request let the
    // terminal drop its input connection first (keyboard starts hiding)
    // and then reopen it, so the terminal resized twice, a frame late.
    _focusNode.requestFocus();
  }

  void _notifyChanged() {
    widget.onChanged?.call(_controller.text);
  }

  @override
  void dispose() {
    _controller.removeListener(_notifyChanged);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _send() {
    final text = _controller.text.replaceAll(RegExp(r'[\r\n]'), '');
    _controller.clear();
    if (text.isEmpty) {
      return;
    }
    widget.onSend(text);
    _focusNode.requestFocus();
  }

  void _recall(String line) {
    _controller.value = TextEditingValue(
      text: line,
      selection: TextSelection.collapsed(offset: line.length),
    );
    _focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: widget.palette.panelFor(widget.brightness),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(2, 6, 4, 6),
        child: Row(
          children: [
            PopupMenuButton<String>(
              icon: const Icon(Icons.history_rounded),
              tooltip: 'Recall a sent line',
              color: widget.palette.panelFor(widget.brightness),
              enabled: widget.history.isNotEmpty,
              onSelected: _recall,
              // Opening the menu takes focus off the field (hiding the soft
              // keyboard). _recall restores focus on select; do the same on
              // cancel so the keyboard always returns after the menu closes.
              onCanceled: _focusNode.requestFocus,
              itemBuilder: (context) => [
                for (final line in widget.history.reversed)
                  PopupMenuItem<String>(
                    value: line,
                    child: Text(
                      line,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
            Expanded(
              child: TextField(
                controller: _controller,
                focusNode: _focusNode,
                autofocus: true,
                autocorrect: true,
                keyboardType: TextInputType.text,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _send(),
                inputFormatters: [
                  // Gboard's action key is inconsistent: sometimes 'Send' (fires
                  // onSubmitted), sometimes 'Enter' (inserts a newline into the
                  // field). Catch the newline-insert path here so submitting is
                  // deterministic regardless of which the IME chooses.
                  TextInputFormatter.withFunction((oldValue, newValue) {
                    if (newValue.text.contains('\n') ||
                        newValue.text.contains('\r')) {
                      WidgetsBinding.instance.addPostFrameCallback(
                        (_) => _send(),
                      );
                      final clean = newValue.text.replaceAll(
                        RegExp(r'[\r\n]'),
                        '',
                      );
                      return TextEditingValue(
                        text: clean,
                        selection: TextSelection.collapsed(
                          offset: clean.length,
                        ),
                      );
                    }
                    return newValue;
                  }),
                ],
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: 'Chat: type a line, Enter to send …',
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                ),
              ),
            ),
            if (widget.dictation != null)
              DictationButton(
                controller: widget.dictation!,
                textController: _controller,
                focusNode: _focusNode,
                autoStart: widget.startDictation,
                onMessage: (message) {
                  ScaffoldMessenger.of(context)
                    ..hideCurrentSnackBar()
                    ..showSnackBar(SnackBar(content: Text(message)));
                },
              ),
            if (widget.onExpand != null)
              IconButton(
                icon: const Icon(Icons.open_in_full_rounded),
                tooltip: 'Open chat mode',
                onPressed: widget.onExpand,
              ),
            IconButton(
              icon: const Icon(Icons.close_rounded),
              tooltip: 'Close chat mode',
              onPressed: () => widget.onClose(_controller.text),
            ),
          ],
        ),
      ),
    );
  }
}

/// A terminal's screen as a [Listenable], for watchers that re-read it
/// after output.
class _TerminalScreen implements Listenable {
  const _TerminalScreen(this.terminal);

  final Terminal terminal;

  @override
  void addListener(VoidCallback listener) => terminal.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      terminal.removeListener(listener);

  /// The visible rows of the active buffer, top to bottom.
  static List<String> visibleRows(Terminal terminal) {
    final buffer = terminal.buffer;
    final lines = buffer.lines;
    final start = buffer.scrollBack.clamp(0, lines.length);
    return [
      for (var row = start; row < lines.length; row++) lines[row].getText(),
    ];
  }
}

/// A small progress pill over the terminal ("Uploading image…").
class _PasteStatusChip extends StatelessWidget {
  const _PasteStatusChip({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      key: const ValueKey('paste-status-chip'),
      color: scheme.secondaryContainer,
      elevation: 3,
      shape: const StadiumBorder(),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: scheme.onSecondaryContainer,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              text,
              style: TextStyle(
                color: scheme.onSecondaryContainer,
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Under a shell on "This computer" that ended: how it ended and a way to
/// start it again.
class _ShellExitedBar extends StatelessWidget {
  const _ShellExitedBar({
    required this.exitCode,
    required this.onRestart,
    super.key,
  });

  final int? exitCode;
  final VoidCallback onRestart;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final code = exitCode;
    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      elevation: 3,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 6, 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.power_settings_new_rounded,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 10),
            Text(
              code == null ? 'Shell exited' : 'Exited (code $code)',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(width: 12),
            FilledButton.tonalIcon(
              key: const ValueKey('shell-restart'),
              onPressed: onRestart,
              icon: const Icon(Icons.restart_alt_rounded, size: 18),
              label: const Text('Restart'),
            ),
          ],
        ),
      ),
    );
  }
}
