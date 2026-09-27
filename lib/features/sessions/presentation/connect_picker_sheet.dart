import 'dart:async';

import 'package:conduit/core/connection_problem.dart';
import 'package:conduit/core/presentation/adaptive_modal.dart';
import 'package:conduit/core/presentation/connection_details.dart';
import 'package:conduit/core/presentation/multiplexer_icon.dart';
import 'package:conduit/core/presentation/system_navigation_insets.dart';
import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/core/theme/app_theme.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/sessions/data/remote_session_lister.dart';
import 'package:conduit/features/sessions/domain/connect_preferences.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:conduit/features/sessions/domain/remote_session_listing.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// What the user picked in the connect picker.
class ConnectPickerResult {
  const ConnectPickerResult({required this.target, required this.remember});

  final ConnectTarget target;

  /// Whether to skip the picker next time and reuse [target].
  final bool remember;
}

enum ConnectPickerTab { tmux, herdr, recent }

/// Shows the Moshi-style picker (Tmux / Herdr / Recent / Skip) for [host].
///
/// Listing runs over [runner], a dedicated exec channel that is closed when
/// the sheet goes away. Returns null when dismissed.
Future<ConnectPickerResult?> showConnectPicker({
  required BuildContext context,
  required SavedHost host,
  required AgentCommandRunner runner,
  ConnectPreferences preferences = const ConnectPreferences(),
  Set<String> activeTargetKeys = const {},
  ConnectPickerTab initialTab = ConnectPickerTab.tmux,
  List<String> recentDirectories = const [],
}) {
  return showAdaptiveModal<ConnectPickerResult>(
    kind: AdaptiveModalKind.dialog,
    desktopFill: true,
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => AnnotatedRegion<SystemUiOverlayStyle>(
      value: AppTheme.systemUiOverlayStyle(Theme.of(context).brightness),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: adaptiveSheetFraction(context, 0.62),
        minChildSize: adaptiveSheetFraction(context, 0.35),
        maxChildSize: adaptiveSheetFraction(context, 0.92),
        builder: (context, scrollController) => ConnectPickerSheet(
          host: host,
          runner: runner,
          preferences: preferences,
          activeTargetKeys: activeTargetKeys,
          initialTab: initialTab,
          recentDirectories: recentDirectories,
          scrollController: scrollController,
          onPicked: (result) => Navigator.of(context).pop(result),
        ),
      ),
    ),
  );
}

class ConnectPickerSheet extends StatefulWidget {
  const ConnectPickerSheet({
    required this.host,
    required this.runner,
    required this.onPicked,
    this.preferences = const ConnectPreferences(),
    this.activeTargetKeys = const {},
    this.initialTab = ConnectPickerTab.tmux,
    this.recentDirectories = const [],
    this.scrollController,
    super.key,
  });

  final SavedHost host;
  final AgentCommandRunner runner;
  final ValueChanged<ConnectPickerResult> onPicked;
  final ConnectPreferences preferences;

  /// Target keys that already have an open session in this app; shown with
  /// an "Active" badge.
  final Set<String> activeTargetKeys;
  final ConnectPickerTab initialTab;

  /// The host's recent working directories, most recent first; shown in
  /// the Recent tab as "Recent dirs", each opening a shell there.
  final List<String> recentDirectories;
  final ScrollController? scrollController;

  @override
  State<ConnectPickerSheet> createState() => _ConnectPickerSheetState();
}

class _ConnectPickerSheetState extends State<ConnectPickerSheet> {
  late ConnectPickerTab _tab = widget.initialTab;
  late bool _remember = widget.preferences.rememberChoice;
  late final RemoteSessionLister _lister = RemoteSessionLister(widget.runner);

  /// The desktop filter: only rows whose name contains it (any case).
  String _query = '';

  Future<RemoteListing<TmuxSessionInfo>>? _tmux;
  Future<RemoteListing<HerdrWorkspaceInfo>>? _herdr;

  /// Hardware-key logins ask for a key touch per connection; the listing
  /// would be a second one, so it only runs on request.
  bool get _autoLoad => widget.host.authMethod != SshAuthMethod.hardwareKey;

  @override
  void initState() {
    super.initState();
    if (_autoLoad) {
      _load();
    }
  }

  void _load() {
    setState(() {
      _tmux = _lister.listTmux();
      _herdr = _lister.listHerdr();
    });
  }

  bool _matches(Iterable<String> texts) {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return true;
    return texts.any((text) => text.toLowerCase().contains(query));
  }

  /// Desktop: Ctrl+1/2/3 (Cmd on macOS) switch between the tabs.
  Map<ShortcutActivator, VoidCallback> get _tabShortcuts {
    final mac = defaultTargetPlatform == TargetPlatform.macOS;
    return {
      for (final (index, tab) in ConnectPickerTab.values.indexed)
        SingleActivator(
          [
            LogicalKeyboardKey.digit1,
            LogicalKeyboardKey.digit2,
            LogicalKeyboardKey.digit3,
          ][index],
          control: !mac,
          meta: mac,
        ): () =>
            setState(() => _tab = tab),
    };
  }

  void _pick(ConnectTarget target) {
    widget.onPicked(ConnectPickerResult(target: target, remember: _remember));
  }

  Future<void> _newTmuxSession() async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) => const _TmuxSessionNameDialog(),
    );
    if (name == null || !mounted) {
      return;
    }
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      return;
    }
    _pick(ConnectTarget.tmux(trimmed));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottomInset = shouldApplyBottomSafeArea(context)
        ? MediaQuery.viewPaddingOf(context).bottom
        : 0.0;
    final desktop = useDesktopModals(context);
    final column = Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 12, 4),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.host.name,
                      style: theme.textTheme.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      'Choose what to attach to',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              Tooltip(
                message: 'Skip the picker next time and reuse this choice',
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Remember', style: theme.textTheme.labelMedium),
                    Switch(
                      value: _remember,
                      onChanged: (value) => setState(() => _remember = value),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: SegmentedButton<ConnectPickerTab>(
                  key: const ValueKey('connect-picker-tabs'),
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    padding: WidgetStatePropertyAll(
                      EdgeInsets.symmetric(horizontal: 4),
                    ),
                  ),
                  segments: const [
                    ButtonSegment(
                      value: ConnectPickerTab.tmux,
                      label: _TabLabel(
                        icon: MultiplexerIcon(
                          MultiplexerKind.tmux,
                          size: 15,
                          semanticLabel: '',
                        ),
                        label: 'Tmux',
                      ),
                    ),
                    ButtonSegment(
                      value: ConnectPickerTab.herdr,
                      label: _TabLabel(
                        icon: MultiplexerIcon(
                          MultiplexerKind.herdr,
                          size: 15,
                          semanticLabel: '',
                        ),
                        label: 'Herdr',
                      ),
                    ),
                    ButtonSegment(
                      value: ConnectPickerTab.recent,
                      label: _TabLabel(
                        icon: Icon(Icons.history_rounded, size: 16),
                        label: 'Recent',
                      ),
                    ),
                  ],
                  selected: {_tab},
                  onSelectionChanged: (selection) =>
                      setState(() => _tab = selection.first),
                ),
              ),
              const SizedBox(width: 6),
              FilledButton.tonal(
                key: const ValueKey('connect-picker-skip'),
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                ),
                onPressed: () => _pick(const ConnectTarget.shell()),
                child: const _TabLabel(
                  icon: Icon(Icons.skip_next_rounded, size: 16),
                  label: 'Skip',
                ),
              ),
            ],
          ),
        ),
        if (desktop)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              key: const ValueKey('connect-picker-filter'),
              decoration: const InputDecoration(
                isDense: true,
                prefixIcon: Icon(Icons.search_rounded, size: 18),
                hintText: 'Filter',
              ),
              onChanged: (value) => setState(() => _query = value),
            ),
          ),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            controller: widget.scrollController,
            padding: EdgeInsets.fromLTRB(12, 8, 12, 16 + bottomInset),
            children: switch (_tab) {
              ConnectPickerTab.tmux => _buildTmux(),
              ConnectPickerTab.herdr => _buildHerdr(),
              ConnectPickerTab.recent => _buildRecent(),
            },
          ),
        ),
      ],
    );
    if (!desktop) return column;
    return CallbackShortcuts(bindings: _tabShortcuts, child: column);
  }

  List<Widget> _buildTmux() {
    final pending = _tmux;
    return [
      ListTile(
        leading: const Icon(Icons.add_circle_outline_rounded),
        title: const Text('New session'),
        subtitle: const Text('Create a named tmux session'),
        onTap: _newTmuxSession,
      ),
      if (pending == null)
        _LoadOnRequest(onLoad: _load)
      else
        FutureBuilder<RemoteListing<TmuxSessionInfo>>(
          future: pending,
          builder: (context, snapshot) {
            final listing = snapshot.data;
            if (listing == null) {
              return const _Loading();
            }
            return switch (listing) {
              RemoteListingNotInstalled() => const _Message(
                icon: Icons.extension_off_outlined,
                message: 'tmux is not installed on this machine.',
              ),
              RemoteListingNotRunning(:final message) => _Message(
                icon: Icons.power_settings_new_rounded,
                message: message,
              ),
              final RemoteListingFailed<TmuxSessionInfo> failed => _failed(
                failed,
                'Could not list tmux sessions.',
              ),
              RemoteListingAvailable(:final items) =>
                items.isEmpty
                    ? const _Message(
                        icon: Icons.inbox_outlined,
                        message: 'No tmux sessions are running.',
                      )
                    : Column(
                        children: [
                          for (final session in items)
                            if (_matches([session.name]))
                              _TargetTile(
                                title: session.name,
                                subtitle: _tmuxSubtitle(session),
                                active: widget.activeTargetKeys.contains(
                                  ConnectTarget.tmux(session.name).key,
                                ),
                                trailingLabel: session.isAttached
                                    ? 'Attached'
                                    : null,
                                onTap: () =>
                                    _pick(ConnectTarget.tmux(session.name)),
                              ),
                        ],
                      ),
            };
          },
        ),
    ];
  }

  /// A failed listing: the shared wording when the machine was not
  /// reached or refused the sign-in, else [headline] and the command's
  /// error.
  Widget _failed(RemoteListingFailed<Object?> listing, String headline) {
    final error = listing.error;
    final problem = error == null
        ? null
        : connectionProblemFor(
            error,
            machine: widget.host.name,
            address: widget.host.host,
          );
    if (problem == null) {
      return _Message(
        icon: Icons.error_outline_rounded,
        message: '$headline ${listing.message}',
        onRetry: _load,
      );
    }
    return _Message(
      icon: problem.kind == ConnectionProblemKind.unreachable
          ? Icons.cloud_off_rounded
          : Icons.lock_outline_rounded,
      title: problem.title,
      message: problem.message,
      detail: problem.detail,
      onRetry: _load,
    );
  }

  static String _tmuxSubtitle(TmuxSessionInfo session) {
    final windows = session.windows == 1
        ? '1 window'
        : '${session.windows} windows';
    final activity = session.lastActivity;
    if (activity == null) {
      return windows;
    }
    return '$windows · active ${_relative(activity)}';
  }

  List<Widget> _buildHerdr() {
    final pending = _herdr;
    if (pending == null) {
      return [_LoadOnRequest(onLoad: _load)];
    }
    return [
      FutureBuilder<RemoteListing<HerdrWorkspaceInfo>>(
        future: pending,
        builder: (context, snapshot) {
          final listing = snapshot.data;
          if (listing == null) {
            return const _Loading();
          }
          return switch (listing) {
            RemoteListingNotInstalled() => const _Message(
              icon: Icons.extension_off_outlined,
              message: 'Herdr is not installed on this machine.',
            ),
            RemoteListingNotRunning(:final message) => _Message(
              icon: Icons.power_settings_new_rounded,
              message: '$message Start it from a plain shell with "herdr".',
              actionLabel: 'Start Herdr',
              onAction: () => _pick(const ConnectTarget.herdr(workspaceId: '')),
            ),
            final RemoteListingFailed<HerdrWorkspaceInfo> failed => _failed(
              failed,
              'Could not list Herdr workspaces.',
            ),
            RemoteListingAvailable(:final items) =>
              items.isEmpty
                  ? const _Message(
                      icon: Icons.inbox_outlined,
                      message: 'Herdr has no workspaces yet.',
                    )
                  : Column(
                      children: [
                        for (final workspace in items.where(
                          (workspace) => _matches([
                            workspace.displayLabel,
                            for (final (position, tab)
                                in workspace.tabs.indexed)
                              tab.displayLabel(position + 1),
                          ]),
                        )) ...[
                          _TargetTile(
                            key: ValueKey(
                              'herdr-workspace-${workspace.session}:'
                              '${workspace.id}',
                            ),
                            title: workspace.displayLabel,
                            subtitle: _herdrSubtitle(workspace),
                            focused: workspace.focused,
                            active: widget.activeTargetKeys.contains(
                              ConnectTarget.herdr(
                                workspaceId: workspace.id,
                                session: workspace.session,
                              ).key,
                            ),
                            trailingLabel: _agentStatusLabel(
                              workspace.agentStatus,
                            ),
                            onTap: () => _pick(
                              ConnectTarget.herdr(
                                workspaceId: workspace.id,
                                label: workspace.displayLabel,
                                session: workspace.session,
                              ),
                            ),
                          ),
                          if (workspace.tabs.length > 1)
                            for (final (position, tab)
                                in workspace.tabs.indexed)
                              _TargetTile(
                                key: ValueKey('herdr-tab-${tab.id}'),
                                title: tab.displayLabel(position + 1),
                                subtitle: tab.summary.isEmpty
                                    ? null
                                    : tab.summary,
                                indented: true,
                                active: widget.activeTargetKeys.contains(
                                  ConnectTarget.herdr(
                                    workspaceId: workspace.id,
                                    tabId: tab.id,
                                    session: workspace.session,
                                  ).key,
                                ),
                                trailingLabel: _agentStatusLabel(
                                  tab.agentStatus,
                                ),
                                onTap: () => _pick(
                                  ConnectTarget.herdr(
                                    workspaceId: workspace.id,
                                    label: tab.label.isEmpty
                                        ? workspace.displayLabel
                                        : '${workspace.displayLabel} / '
                                              '${tab.label}',
                                    tabId: tab.id,
                                    session: workspace.session,
                                  ),
                                ),
                              ),
                        ],
                      ],
                    ),
          };
        },
      ),
    ];
  }

  static String _herdrSubtitle(HerdrWorkspaceInfo workspace) {
    return workspace.tabCount == 1 ? '1 tab' : '${workspace.tabCount} tabs';
  }

  static String? _agentStatusLabel(String status) => switch (status) {
    'working' => 'Working',
    'blocked' => 'Needs input',
    'done' => 'Done',
    _ => null,
  };

  List<Widget> _buildRecent() {
    final recents = widget.preferences.recents;
    final directories = widget.recentDirectories;
    if (recents.isEmpty && directories.isEmpty) {
      return const [
        _Message(
          icon: Icons.history_rounded,
          message:
              'Nothing picked for this machine yet. Choices from the Tmux '
              'and Herdr tabs show up here, and so do the directories you '
              'work in.',
        ),
      ];
    }
    return [
      for (final target in recents)
        if (_matches([target.title, target.name]))
          _TargetTile(
            title: target.title,
            subtitle: switch (target.kind) {
              ConnectTargetKind.tmux => 'tmux session',
              ConnectTargetKind.herdr =>
                target.tabId.isEmpty
                    ? 'Herdr workspace ${target.name}'
                    : 'Herdr tab ${target.tabId}',
              ConnectTargetKind.shell => 'Plain shell',
              ConnectTargetKind.directory => target.name,
            },
            active: widget.activeTargetKeys.contains(target.key),
            onTap: () => _pick(target),
          ),
      if (directories.isNotEmpty) ...[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            'RECENT DIRS',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              letterSpacing: 1.1,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        for (final directory in directories)
          if (_matches([directory]))
            _TargetTile(
              title: ConnectTarget.directory(directory).title,
              subtitle: directory,
              active: widget.activeTargetKeys.contains(
                ConnectTarget.directory(directory).key,
              ),
              onTap: () => _pick(ConnectTarget.directory(directory)),
            ),
      ],
    ];
  }

  static String _relative(DateTime time) {
    final diff = DateTime.now().toUtc().difference(time.toUtc());
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}

/// Icon and label of a picker tab (or the Skip button) on one line: on a
/// narrow phone or with large text the pair scales down instead of wrapping.
class _TabLabel extends StatelessWidget {
  const _TabLabel({required this.icon, required this.label});

  final Widget icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          icon,
          const SizedBox(width: 5),
          Text(label, maxLines: 1, softWrap: false),
        ],
      ),
    );
  }
}

class _TargetTile extends StatelessWidget {
  const _TargetTile({
    required this.title,
    required this.onTap,
    this.subtitle,
    this.active = false,
    this.focused = false,
    this.indented = false,
    this.trailingLabel,
    super.key,
  });

  final String title;
  final String? subtitle;
  final bool active;

  /// Herdr's focused workspace: marked with a dot before the title.
  final bool focused;
  final bool indented;
  final String? trailingLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      contentPadding: EdgeInsets.only(left: indented ? 40 : 16, right: 16),
      title: Row(
        children: [
          if (focused) ...[
            Tooltip(
              message: 'Focused in Herdr',
              child: Container(
                key: const ValueKey('herdr-focused-dot'),
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary,
                  shape: BoxShape.circle,
                ),
              ),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if (active) ...[
            const SizedBox(width: 8),
            const _Badge(label: 'Active', tone: _BadgeTone.success),
          ],
        ],
      ),
      subtitle: subtitle == null ? null : Text(subtitle!),
      trailing: trailingLabel == null
          ? null
          : _Badge(
              label: trailingLabel!,
              tone: trailingLabel == 'Needs input'
                  ? _BadgeTone.danger
                  : _BadgeTone.neutral,
            ),
      onTap: onTap,
    );
  }
}

enum _BadgeTone { success, danger, neutral }

class _Badge extends StatelessWidget {
  const _Badge({required this.label, required this.tone});

  final String label;
  final _BadgeTone tone;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final (background, foreground) = switch (tone) {
      _BadgeTone.success => (
        AppPalette.of(context).success.withValues(alpha: 0.18),
        AppPalette.of(context).success,
      ),
      _BadgeTone.danger => (
        colorScheme.error.withValues(alpha: 0.16),
        colorScheme.error,
      ),
      _BadgeTone.neutral => (
        colorScheme.surfaceContainerHigh,
        colorScheme.onSurfaceVariant,
      ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(AppTheme.radius),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: foreground,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 28),
      child: Center(child: CircularProgressIndicator()),
    );
  }
}

class _LoadOnRequest extends StatelessWidget {
  const _LoadOnRequest({required this.onLoad});

  final VoidCallback onLoad;

  @override
  Widget build(BuildContext context) {
    return _Message(
      icon: Icons.usb_rounded,
      message:
          'Listing sessions opens a second connection, which asks for a '
          'hardware key touch.',
      actionLabel: 'Load sessions',
      onAction: onLoad,
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.message,
    this.title,
    this.detail,
    this.onRetry,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String? title;
  final String message;

  /// Technical reason, behind "Details".
  final String? detail;
  final VoidCallback? onRetry;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
      child: Column(
        children: [
          Icon(icon, size: 28, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(height: 10),
          if (title case final title?) ...[
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
          ],
          Text(
            message,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (detail case final detail?)
            ConnectionDetails(detail: detail, textAlign: TextAlign.center),
          if (onRetry != null) ...[
            const SizedBox(height: 8),
            TextButton(onPressed: onRetry, child: const Text('Retry')),
          ],
          if (onAction != null && actionLabel != null) ...[
            const SizedBox(height: 8),
            FilledButton.tonal(onPressed: onAction, child: Text(actionLabel!)),
          ],
        ],
      ),
    );
  }
}

class _TmuxSessionNameDialog extends StatefulWidget {
  const _TmuxSessionNameDialog();

  @override
  State<_TmuxSessionNameDialog> createState() => _TmuxSessionNameDialogState();
}

class _TmuxSessionNameDialogState extends State<_TmuxSessionNameDialog> {
  final _controller = TextEditingController(text: defaultTmuxSessionName);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_controller.text);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New tmux session'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _submit(),
        decoration: const InputDecoration(
          labelText: 'Session name',
          helperText: 'Attaches to it if it already exists.',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Connect')),
      ],
    );
  }
}
