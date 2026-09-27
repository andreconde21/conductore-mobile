import 'dart:async';

import 'package:conduit/core/platform_features.dart';
import 'package:conduit/core/presentation/adaptive_modal.dart';
import 'package:conduit/core/presentation/conduit_brand.dart';
import 'package:conduit/core/presentation/multiplexer_icon.dart';
import 'package:conduit/core/presentation/system_navigation_insets.dart';
import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/core/theme/app_theme.dart';
import 'package:conduit/core/theme/theme_controller.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:conduit/features/sessions/presentation/session_connect_flow.dart';
import 'package:conduit/features/sessions/presentation/terminal_preview.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:flutter/material.dart';

/// Pushes the session home grid. Resolves when it is closed; the workspace's
/// active session reflects whatever tile was tapped.
///
/// [connectFlow] enables the "+" tile; without it the grid only switches
/// between and closes existing sessions.
Future<void> showSessionGrid(
  BuildContext context, {
  required TerminalWorkspaceController workspace,
  required ThemeController themeController,
  AgentAttentionController? agentAttention,
  SessionConnectFlow? connectFlow,
}) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => SessionGridPage(
        workspace: workspace,
        themeController: themeController,
        agentAttention: agentAttention,
        connectFlow: connectFlow,
      ),
    ),
  );
}

/// Moshi-style overview of open sessions: a two-column grid of live text
/// previews with the machine name, the tmux/Herdr target and the agent
/// status. Tap activates a session, long-press offers reconnect/close.
class SessionGridPage extends StatefulWidget {
  const SessionGridPage({
    required this.workspace,
    required this.themeController,
    this.agentAttention,
    this.connectFlow,
    this.refreshInterval = const Duration(seconds: 2),
    super.key,
  });

  final TerminalWorkspaceController workspace;
  final ThemeController themeController;
  final AgentAttentionController? agentAttention;
  final SessionConnectFlow? connectFlow;

  /// How often previews are re-captured while the page is visible.
  final Duration refreshInterval;

  @override
  State<SessionGridPage> createState() => _SessionGridPageState();
}

class _SessionGridPageState extends State<SessionGridPage>
    with WidgetsBindingObserver {
  Timer? _refreshTimer;
  bool _visible = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startTimer();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _refreshTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final visible = state == AppLifecycleState.resumed;
    if (visible == _visible) {
      return;
    }
    _visible = visible;
    if (visible) {
      _startTimer();
      if (mounted) setState(() {});
    } else {
      _refreshTimer?.cancel();
      _refreshTimer = null;
    }
  }

  void _startTimer() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(widget.refreshInterval, (_) {
      if (mounted) setState(() {});
    });
  }

  void _activate(TerminalSessionController session) {
    widget.workspace.activate(session);
    Navigator.of(context).pop();
  }

  Future<void> _showActions(TerminalSessionController session) async {
    final action = await showAdaptiveModal<_TileAction>(
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
                style: Theme.of(context).textTheme.titleMedium,
              ),
              subtitle: Text(session.host.endpoint),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.refresh_rounded),
              title: const Text('Reconnect'),
              onTap: () => Navigator.of(context).pop(_TileAction.reconnect),
            ),
            ListTile(
              leading: const Icon(Icons.close_rounded),
              title: const Text('Close session'),
              onTap: () => Navigator.of(context).pop(_TileAction.close),
            ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) {
      return;
    }
    switch (action) {
      case _TileAction.reconnect:
        await session.disconnect();
        unawaited(session.connect());
      case _TileAction.close:
        await widget.workspace.close(session);
    }
  }

  Future<void> _add() async {
    final flow = widget.connectFlow;
    if (flow == null) {
      return;
    }
    final session = await flow.pickHostAndConnect(context);
    if (session != null && mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = widget.themeController.palette;
    final brightness = Theme.of(context).brightness;
    final width = MediaQuery.sizeOf(context).width;
    final columns = width >= 900
        ? 4
        : width >= 600
        ? 3
        : 2;
    return Scaffold(
      body: ConduitBackdrop(
        palette: palette,
        child: SafeArea(
          bottom: shouldApplyBottomSafeArea(context),
          child: ListenableBuilder(
            listenable: Listenable.merge([
              widget.workspace,
              widget.agentAttention ?? _inert,
            ]),
            builder: (context, _) {
              final sessions = widget.workspace.sessions;
              final active = widget.workspace.activeSession;
              return CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(8, 8, 16, 4),
                      child: Row(
                        children: [
                          IconButton(
                            tooltip: 'Back',
                            icon: const Icon(Icons.arrow_back_rounded),
                            onPressed: () => Navigator.of(context).pop(),
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              'Sessions',
                              style: Theme.of(context).textTheme.titleLarge
                                  ?.copyWith(fontWeight: FontWeight.w800),
                            ),
                          ),
                          Text(
                            sessions.length == 1
                                ? '1 open'
                                : '${sessions.length} open',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                    sliver: SliverGrid(
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        mainAxisSpacing: 12,
                        crossAxisSpacing: 12,
                        childAspectRatio: 0.78,
                      ),
                      delegate: SliverChildBuilderDelegate(
                        (context, index) {
                          if (index == sessions.length) {
                            return _AddTile(
                              palette: palette,
                              brightness: brightness,
                              onTap: _add,
                            );
                          }
                          final session = sessions[index];
                          return SessionTile(
                            key: ValueKey(session.host.id),
                            session: session,
                            palette: palette,
                            brightness: brightness,
                            selected: session == active,
                            agentStatus: widget.agentAttention?.statusFor(
                              session.host.id,
                            ),
                            onTap: () => _activate(session),
                            onLongPress: () => _showActions(session),
                          );
                        },
                        childCount:
                            sessions.length +
                            (widget.connectFlow == null ? 0 : 1),
                      ),
                    ),
                  ),
                  if (sessions.isEmpty && widget.connectFlow == null)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: Center(
                        child: Text(
                          'No open sessions.',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  static final Listenable _inert = ChangeNotifier();
}

enum _TileAction { reconnect, close }

/// Summarizes a host's agents for one session: agents in the session's
/// Herdr workspace when the target names one, otherwise every agent on the
/// host. The most urgent state wins.
AgentAttentionState? summarizeAgentState(
  AgentHostStatus? status,
  String sessionHostId,
) {
  if (status == null || status.agents.isEmpty) {
    return null;
  }
  final target = ConnectTarget.fromSessionHostId(sessionHostId);
  final workspaceId = target?.kind == ConnectTargetKind.herdr
      ? target!.name
      : '';
  final agents = workspaceId.isEmpty
      ? status.agents
      : status.agents.where((agent) => agent.workspace == workspaceId);
  AgentAttentionState? summary;
  for (final agent in agents) {
    final state = agent.state;
    if (summary == null || _priority(state) < _priority(summary)) {
      summary = state;
    }
  }
  return summary;
}

int _priority(AgentAttentionState state) => switch (state) {
  AgentAttentionState.needsInput => 0,
  AgentAttentionState.blocked => 1,
  AgentAttentionState.working => 2,
  AgentAttentionState.finished => 3,
  AgentAttentionState.idle => 4,
  AgentAttentionState.unknown => 5,
};

class SessionTile extends StatelessWidget {
  const SessionTile({
    required this.session,
    required this.palette,
    required this.brightness,
    required this.onTap,
    required this.onLongPress,
    this.selected = false,
    this.agentStatus,
    super.key,
  });

  final TerminalSessionController session;
  final AppPalette palette;
  final Brightness brightness;
  final bool selected;
  final AgentHostStatus? agentStatus;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  static const previewRows = 14;
  static const previewColumns = 44;

  @override
  Widget build(BuildContext context) {
    final foreground = palette.foregroundFor(brightness);
    final muted = palette.mutedForegroundFor(brightness);
    final accent = palette.accent;
    final preview = TerminalPreview.capture(
      session.terminal,
      rows: previewRows,
      columns: previewColumns,
    );
    final target = ConnectTarget.fromSessionHostId(session.host.id);
    final hostName = _baseName(session);
    final subtitle = _subtitle(session, target);
    final agentState = summarizeAgentState(agentStatus, session.host.id);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppTheme.radius),
        onTap: onTap,
        onLongPress: onLongPress,
        // Desktop: right-click opens the same actions (the menu anchors at
        // the pointer).
        onSecondaryTap: PlatformFeatures.isDesktop ? onLongPress : null,
        child: Container(
          decoration: BoxDecoration(
            color: palette.panelFor(brightness),
            borderRadius: BorderRadius.circular(AppTheme.radius),
            border: Border.all(
              color: selected
                  ? accent.withValues(alpha: 0.7)
                  : palette.hairlineFor(brightness),
              width: selected ? 1.5 : 1,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Container(
                  width: double.infinity,
                  color: palette.terminalBackgroundFor(brightness),
                  padding: const EdgeInsets.fromLTRB(8, 8, 4, 4),
                  child: Stack(
                    children: [
                      _PreviewText(
                        preview: preview,
                        color: palette.terminalForegroundFor(brightness),
                        placeholder: _placeholderFor(session.status),
                        placeholderColor: muted,
                      ),
                      Positioned(
                        top: 0,
                        right: 4,
                        child: _StatusDot(status: session.status),
                      ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      hostName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: foreground,
                        fontWeight: FontWeight.w800,
                        fontSize: 13.5,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        if (target != null &&
                            target.kind != ConnectTargetKind.shell)
                          Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: target.kind == ConnectTargetKind.herdr
                                ? const MultiplexerIcon(
                                    MultiplexerKind.herdr,
                                    size: 12,
                                  )
                                : target.kind == ConnectTargetKind.tmux
                                ? const MultiplexerIcon(
                                    MultiplexerKind.tmux,
                                    size: 12,
                                  )
                                : Icon(
                                    Icons.folder_outlined,
                                    size: 12,
                                    color: accent,
                                  ),
                          ),
                        Expanded(
                          child: Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: target == null ? muted : accent,
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (agentState != null) ...[
                          const SizedBox(width: 6),
                          _AgentBadge(state: agentState),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The saved host's name: the part before the target suffix that
  /// [ConnectTarget.apply] appended.
  static String _baseName(TerminalSessionController session) {
    final target = ConnectTarget.fromSessionHostId(session.host.id);
    if (target == null) {
      return session.host.name;
    }
    final name = session.host.name;
    const suffix = ': ';
    final cut = name.lastIndexOf(suffix);
    return cut <= 0 ? name : name.substring(0, cut);
  }

  static String _subtitle(
    TerminalSessionController session,
    ConnectTarget? target,
  ) {
    if (target != null && target.kind != ConnectTargetKind.shell) {
      // The derived host name carries the label the picker knew; the id
      // alone only has the workspace id.
      final name = session.host.name;
      final cut = name.lastIndexOf(': ');
      if (cut > 0 && cut + 2 < name.length) {
        return name.substring(cut + 2);
      }
      return target.title;
    }
    final title = session.terminalTitle;
    return title.isNotEmpty ? title : session.host.endpoint;
  }

  static String? _placeholderFor(TerminalConnectionStatus status) =>
      switch (status) {
        TerminalConnectionStatus.idle => 'Not connected',
        TerminalConnectionStatus.connecting => 'Connecting…',
        TerminalConnectionStatus.connected => null,
        TerminalConnectionStatus.disconnected => 'Disconnected',
        TerminalConnectionStatus.failed => 'Connection failed',
      };
}

class _PreviewText extends StatelessWidget {
  const _PreviewText({
    required this.preview,
    required this.color,
    required this.placeholder,
    required this.placeholderColor,
  });

  final TerminalPreview preview;
  final Color color;
  final String? placeholder;
  final Color placeholderColor;

  @override
  Widget build(BuildContext context) {
    if (preview.isEmpty) {
      return Center(
        child: Text(
          placeholder ?? 'Waiting for output…',
          style: TextStyle(color: placeholderColor, fontSize: 11),
        ),
      );
    }
    return ClipRect(
      child: Text(
        preview.lines.join('\n'),
        softWrap: false,
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 6.5,
          height: 1.25,
          color: color.withValues(alpha: 0.85),
        ),
      ),
    );
  }
}

class _AgentBadge extends StatelessWidget {
  const _AgentBadge({required this.state});

  final AgentAttentionState state;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final (label, color) = switch (state) {
      AgentAttentionState.needsInput => ('Needs input', colorScheme.error),
      AgentAttentionState.blocked => ('Blocked', colorScheme.error),
      AgentAttentionState.working => ('Working', colorScheme.primary),
      AgentAttentionState.finished => ('Done', AppPalette.of(context).success),
      AgentAttentionState.idle => ('Idle', colorScheme.onSurfaceVariant),
      AgentAttentionState.unknown => ('Agent', colorScheme.onSurfaceVariant),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(AppTheme.radius),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.status});

  final TerminalConnectionStatus status;

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      TerminalConnectionStatus.connected => AppPalette.of(context).success,
      TerminalConnectionStatus.connecting => AppPalette.of(context).warning,
      TerminalConnectionStatus.failed => Theme.of(context).colorScheme.error,
      TerminalConnectionStatus.idle ||
      TerminalConnectionStatus.disconnected => AppPalette.of(context).inactive,
    };
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

class _AddTile extends StatelessWidget {
  const _AddTile({
    required this.palette,
    required this.brightness,
    required this.onTap,
  });

  final AppPalette palette;
  final Brightness brightness;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final muted = palette.mutedForegroundFor(brightness);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppTheme.radius),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppTheme.radius),
            border: Border.all(color: palette.borderFor(brightness)),
            color: palette.panelFor(brightness).withValues(alpha: 0.5),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.add_rounded, size: 34, color: palette.accent),
              const SizedBox(height: 6),
              Text(
                'New session',
                style: TextStyle(
                  color: muted,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
