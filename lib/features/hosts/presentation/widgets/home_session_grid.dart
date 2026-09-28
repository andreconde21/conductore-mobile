import 'package:conduit/core/connection_problem.dart';
import 'package:conduit/core/presentation/multiplexer_icon.dart';
import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/core/theme/app_theme.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/hosts/presentation/home_board_controller.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:conduit/features/sessions/domain/remote_session_listing.dart';
import 'package:conduit/features/sessions/presentation/live_terminal_preview.dart';
import 'package:conduit/features/sessions/presentation/terminal_preview.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:flutter/material.dart';

/// Herdr's colour on the home page (workspace labels, the Herdr glyph).

/// Sizes of the home grid for a given content width: two columns on a
/// phone (one in the large layout), more on tablets.
@immutable
class HomeGridMetrics {
  const HomeGridMetrics._({
    required this.columns,
    required this.tileWidth,
    required this.sessionExtent,
    required this.dormantExtent,
  });

  factory HomeGridMetrics.of(double width, {bool large = false}) {
    final base = width >= 900
        ? 4
        : width >= 600
        ? 3
        : 2;
    final columns = large ? (base - 1).clamp(1, 3) : base;
    final inner = width - horizontalPadding * 2;
    final tileWidth = (inner - spacing * (columns - 1)) / columns;
    return HomeGridMetrics._(
      columns: columns,
      tileWidth: tileWidth,
      // A 4:5 preview plus the title and workspace lines below it.
      sessionExtent: tileWidth * 1.25 + labelHeight,
      dormantExtent: 118,
    );
  }

  static const horizontalPadding = 16.0;
  static const spacing = 12.0;
  static const labelHeight = 52.0;

  final int columns;
  final double tileWidth;
  final double sessionExtent;
  final double dormantExtent;
}

/// Summary of one app session for its home tile or row.
@immutable
class HomeSessionInfo {
  const HomeSessionInfo({
    required this.target,
    required this.targetLabel,
    required this.agentState,
    this.multiplexer,
    this.machineName = '',
    this.restoreNote,
  });

  /// What the session is attached to (null for a plain session).
  final ConnectTarget? target;

  /// Herdr workspace, tmux session or directory shown with the title.
  final String targetLabel;

  /// Most urgent agent state for the session, if any agent is known.
  final AgentAttentionState? agentState;

  /// The multiplexer the session runs in: a Herdr or tmux target, or a
  /// machine that starts tmux on connect.
  final MultiplexerKind? multiplexer;

  /// The saved machine's name (empty when unknown).
  final String machineName;

  /// For a session brought back from the last app run and not connected
  /// yet: what happens next ("Reconnecting…", "Tap to reconnect", a plain
  /// shell that ended). Shown instead of the screen.
  final String? restoreNote;

  bool get isHerdr => multiplexer == MultiplexerKind.herdr;

  /// Builds the info for [session]. [workspaces] (the home board of the
  /// session's machine) supplies live Herdr workspace names; the name baked
  /// into the session title is the fallback. A plain session to a machine
  /// that starts tmux on connect is labelled with that tmux session.
  static HomeSessionInfo of(
    TerminalSessionController session, {
    List<HomeBoardWorkspace> workspaces = const [],
    AgentAttentionState? agentState,
    String machineName = '',
    String? restoreNote,
  }) {
    final target = ConnectTarget.fromSessionHostId(session.host.id);
    var label = '';
    MultiplexerKind? multiplexer;
    AgentAttentionState? boardState;
    if (target != null && target.kind != ConnectTargetKind.shell) {
      multiplexer = switch (target.kind) {
        ConnectTargetKind.herdr => MultiplexerKind.herdr,
        ConnectTargetKind.tmux => MultiplexerKind.tmux,
        _ => null,
      };
      if (target.kind == ConnectTargetKind.herdr && target.name.isNotEmpty) {
        final live = workspaces.where((w) => w.id == target.name).firstOrNull;
        if (live != null) {
          label = live.label;
          boardState = live.summary;
        }
      }
      if (label.isEmpty) {
        final name = session.host.name;
        final cut = name.lastIndexOf(': ');
        label = cut > 0 && cut + 2 < name.length
            ? name.substring(cut + 2)
            : target.title;
      }
    } else if (session.host.startTmuxOnConnect && !session.host.isLocal) {
      multiplexer = MultiplexerKind.tmux;
      label = tmuxSessionNameOf(session.host);
    }
    return HomeSessionInfo(
      target: target,
      targetLabel: label,
      agentState: agentState ?? boardState,
      multiplexer: multiplexer,
      machineName: machineName,
      restoreNote: restoreNote,
    );
  }

  /// The tmux session a session is attached to, or null when it is not in
  /// tmux (a tmux target, or a machine that starts tmux on connect).
  static String? tmuxSessionOf(TerminalSessionController session) {
    final target = ConnectTarget.fromSessionHostId(session.host.id);
    if (target?.kind == ConnectTargetKind.tmux) return target!.name;
    if (target == null && session.host.startTmuxOnConnect) {
      return tmuxSessionNameOf(session.host);
    }
    return null;
  }

  /// The tmux session name a host attaches to on connect.
  static String tmuxSessionNameOf(SavedHost host) {
    final name = host.tmuxSessionName.trim();
    return name.isEmpty ? defaultTmuxSessionName : name;
  }
}

/// Icon for what a session is attached to: the multiplexer's logo, a
/// folder for a directory, a prompt for a plain shell.
class SessionTargetIcon extends StatelessWidget {
  const SessionTargetIcon({required this.info, this.size = 15, super.key});

  final HomeSessionInfo info;
  final double size;

  @override
  Widget build(BuildContext context) {
    final multiplexer = info.multiplexer;
    if (multiplexer != null) {
      return MultiplexerIcon(multiplexer, size: size, semanticLabel: '');
    }
    return Icon(
      info.target?.kind == ConnectTargetKind.directory
          ? Icons.folder_outlined
          : Icons.terminal_rounded,
      size: size,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
  }
}

/// Agent states worth a banner on a session (idle and unknown are not).
bool showsAgentState(AgentAttentionState? state) =>
    state != null &&
    state != AgentAttentionState.idle &&
    state != AgentAttentionState.unknown;

/// Solid, prominent pill for an agent state on a session tile.
class AgentStateBanner extends StatelessWidget {
  const AgentStateBanner({required this.state, super.key});

  final AgentAttentionState state;

  @override
  Widget build(BuildContext context) {
    final color = agentStateColor(context, state);
    final onColor =
        ThemeData.estimateBrightnessForColor(color) == Brightness.dark
        ? Colors.white
        : Colors.black;
    return Container(
      key: const ValueKey('agent-state-banner'),
      padding: const EdgeInsets.fromLTRB(8, 3, 10, 3),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(AppTheme.radius),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_icon(state), size: 14, color: onColor),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              AgentStateChip.labelFor(state),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: onColor,
                fontSize: 12,
                fontWeight: FontWeight.w800,
                height: 1.2,
              ),
            ),
          ),
        ],
      ),
    );
  }

  static IconData _icon(AgentAttentionState state) => switch (state) {
    AgentAttentionState.needsInput => Icons.front_hand_rounded,
    AgentAttentionState.blocked => Icons.block_rounded,
    AgentAttentionState.working => Icons.autorenew_rounded,
    AgentAttentionState.finished => Icons.check_circle_rounded,
    AgentAttentionState.idle ||
    AgentAttentionState.unknown => Icons.circle_outlined,
  };
}

/// A large live tile for one open session: a scaled-down render of its
/// screen in the terminal's own colours, a status dot, the title and the
/// transport badge over the top, and the title plus Herdr workspace below.
class HomeSessionTile extends StatelessWidget {
  const HomeSessionTile({
    required this.session,
    required this.info,
    required this.palette,
    required this.brightness,
    required this.fontFamily,
    required this.onTap,
    required this.onLongPress,
    this.selected = false,
    super.key,
  });

  final TerminalSessionController session;
  final HomeSessionInfo info;
  final AppPalette palette;
  final Brightness brightness;
  final String fontFamily;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final terminalTheme = palette.terminalThemeFor(brightness);
    final foreground = palette.foregroundFor(brightness);
    final muted = palette.mutedForegroundFor(brightness);
    final radius = BorderRadius.circular(AppTheme.radius);
    final state = info.agentState;
    final attention = state != null && state.needsAttention;
    return Semantics(
      button: true,
      label: [
        session.title,
        info.restoreNote ?? statusLabel(session.status),
        if (showsAgentState(state)) AgentStateChip.labelFor(state!),
      ].join(', '),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Material(
              color: terminalTheme.background,
              shape: RoundedRectangleBorder(
                borderRadius: radius,
                side: BorderSide(
                  color: attention
                      ? agentStateColor(context, state).withValues(alpha: 0.8)
                      : selected
                      ? palette.accent.withValues(alpha: 0.75)
                      : palette.hairlineFor(brightness),
                  width: attention || selected ? 1.5 : 1,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: onTap,
                onLongPress: onLongPress,
                // A right-click opens the same actions (desktop).
                onSecondaryTap: onLongPress,
                child: Stack(
                  children: [
                    Positioned.fill(
                      top: 30,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
                        child: info.restoreNote != null
                            ? Center(
                                key: const ValueKey('home-tile-restore-note'),
                                child: Text(
                                  info.restoreNote!,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(color: muted, fontSize: 11),
                                ),
                              )
                            : SessionPreviewBuilder(
                                session: session,
                                builder: (context, preview, shared) => Stack(
                                  children: [
                                    Positioned.fill(
                                      child: LiveTerminalPreview(
                                        preview: preview,
                                        theme: terminalTheme,
                                        fontFamily: fontFamily,
                                        placeholder: shared != null
                                            ? SessionPreviewBuilder
                                                  .sharedPlaceholder
                                            : placeholderFor(session.status),
                                        placeholderColor: muted,
                                      ),
                                    ),
                                    if (shared != null)
                                      Positioned(
                                        top: 2,
                                        right: 0,
                                        child: SharedViewCaption(
                                          shared: shared,
                                          background: terminalTheme.background,
                                          foreground: terminalTheme.foreground,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                      ),
                    ),
                    if (showsAgentState(state))
                      Positioned(
                        left: 8,
                        bottom: 8,
                        right: 8,
                        child: Align(
                          alignment: Alignment.bottomLeft,
                          child: AgentStateBanner(state: state!),
                        ),
                      ),
                    Positioned(
                      left: 0,
                      right: 0,
                      top: 0,
                      child: _TileHeader(
                        title: session.title,
                        dotColor: dotColor(context, session.status, state),
                        background: terminalTheme.background,
                        foreground: terminalTheme.foreground,
                        badge: TransportBadge.forSession(session),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 7),
          Text(
            session.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: foreground,
              fontSize: 15,
              fontWeight: FontWeight.w700,
              height: 1.2,
            ),
          ),
          const SizedBox(height: 3),
          SizedBox(
            height: 20,
            child: Row(
              children: [
                if (info.targetLabel.isNotEmpty) ...[
                  SessionTargetIcon(info: info),
                  const SizedBox(width: 5),
                  Flexible(
                    child: Text(
                      info.targetLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: info.isHerdr
                            ? AppPalette.of(context).success
                            : muted,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ] else
                  Flexible(
                    child: Text(
                      info.machineName.isEmpty
                          ? session.host.endpoint
                          : info.machineName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: muted, fontSize: 12.5),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String statusLabel(TerminalConnectionStatus status) =>
      switch (status) {
        TerminalConnectionStatus.idle => 'not connected',
        TerminalConnectionStatus.connecting => 'connecting',
        TerminalConnectionStatus.connected => 'connected',
        TerminalConnectionStatus.disconnected => 'disconnected',
        TerminalConnectionStatus.failed => 'connection failed',
      };

  static String? placeholderFor(TerminalConnectionStatus status) =>
      switch (status) {
        TerminalConnectionStatus.idle => 'Not connected',
        TerminalConnectionStatus.connecting => 'Connecting…',
        TerminalConnectionStatus.connected => null,
        TerminalConnectionStatus.disconnected => 'Disconnected',
        TerminalConnectionStatus.failed => 'Connection failed',
      };

  /// Agent needing input wins; otherwise the connection state.
  static Color dotColor(
    BuildContext context,
    TerminalConnectionStatus status,
    AgentAttentionState? state,
  ) {
    if (state != null && state.needsAttention) {
      return agentStateColor(context, state);
    }
    return switch (status) {
      TerminalConnectionStatus.connected => AppPalette.of(context).success,
      TerminalConnectionStatus.connecting => AppPalette.of(context).warning,
      TerminalConnectionStatus.failed => Theme.of(context).colorScheme.error,
      TerminalConnectionStatus.idle ||
      TerminalConnectionStatus.disconnected => AppPalette.of(context).inactive,
    };
  }
}

class _TileHeader extends StatelessWidget {
  const _TileHeader({
    required this.title,
    required this.dotColor,
    required this.background,
    required this.foreground,
    required this.badge,
  });

  final String title;
  final Color dotColor;
  final Color background;
  final Color foreground;
  final Widget badge;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(color: background),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(9, 7, 6, 5),
        child: Row(
          children: [
            Container(
              key: const ValueKey('home-tile-dot'),
              width: 9,
              height: 9,
              decoration: BoxDecoration(
                color: dotColor,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.fade,
                softWrap: false,
                style: TextStyle(
                  color: foreground.withValues(alpha: 0.9),
                  fontFamily: 'monospace',
                  fontSize: 11.5,
                ),
              ),
            ),
            const SizedBox(width: 4),
            badge,
          ],
        ),
      ),
    );
  }
}

/// Badge naming how the session is carried, in the theme's colours: Mosh
/// (cyan), SSH (blue) or the on-device shell (muted).
class TransportBadge extends StatelessWidget {
  const TransportBadge({required this.label, this.color, super.key});

  factory TransportBadge.forSession(TerminalSessionController session) {
    final host = session.host;
    if (host.isLocal) {
      return const TransportBadge(label: 'Local');
    }
    return TransportBadge(label: host.useMosh ? 'Mosh' : 'SSH');
  }

  final String label;

  /// Overrides the theme colour picked from [label].
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final color =
        this.color ??
        switch (label) {
          'Mosh' => palette.colors.cyan,
          'SSH' => palette.colors.blue,
          _ => palette.inactive,
        };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(AppTheme.radius),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: palette.canvas,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          height: 1.2,
        ),
      ),
    );
  }
}

/// The "+" tile: opens the connect picker for the selected machine.
class HomeAddTile extends StatelessWidget {
  const HomeAddTile({
    required this.palette,
    required this.brightness,
    required this.onTap,
    this.label = 'New session',
    super.key,
  });

  final AppPalette palette;
  final Brightness brightness;
  final VoidCallback onTap;
  final String label;

  @override
  Widget build(BuildContext context) {
    final muted = palette.mutedForegroundFor(brightness);
    final radius = BorderRadius.circular(AppTheme.radius);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Material(
            color: palette.panelFor(brightness).withValues(alpha: 0.5),
            shape: RoundedRectangleBorder(
              borderRadius: radius,
              side: BorderSide(color: palette.borderFor(brightness)),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: const ValueKey('home-add-tile'),
              onTap: onTap,
              child: Center(
                child: Icon(Icons.add_rounded, size: 40, color: palette.accent),
              ),
            ),
          ),
        ),
        const SizedBox(height: 7),
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: muted,
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 23),
      ],
    );
  }
}

/// A Herdr workspace on the selected machine that has no session in the
/// app yet: its name, pane and tab counts, and chips for its agents.
class DormantWorkspaceTile extends StatelessWidget {
  const DormantWorkspaceTile({
    required this.workspace,
    required this.palette,
    required this.brightness,
    required this.onTap,
    this.onLongPress,
    super.key,
  });

  final HomeBoardWorkspace workspace;
  final AppPalette palette;
  final Brightness brightness;
  final VoidCallback onTap;

  /// Lists the workspace's agent panes (null when there are none).
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final foreground = palette.foregroundFor(brightness);
    final muted = palette.mutedForegroundFor(brightness);
    final summary = workspace.summary;
    final attention = summary != null && summary.needsAttention;
    return Material(
      color: palette.panelFor(brightness),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radius),
        side: BorderSide(
          color: attention
              ? agentStateColor(context, summary).withValues(alpha: 0.6)
              : palette.hairlineFor(brightness),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        // A right-click opens the same actions (desktop).
        onSecondaryTap: onLongPress,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 11, 10, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const MultiplexerIcon(
                    MultiplexerKind.herdr,
                    size: 16,
                    semanticLabel: '',
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      workspace.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: foreground,
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Icon(Icons.play_arrow_rounded, size: 18, color: muted),
                ],
              ),
              const SizedBox(height: 3),
              Text(
                herdrDetails(workspace),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: muted, fontSize: 12),
              ),
              const Spacer(),
              SizedBox(
                height: 22,
                child: ClipRect(
                  child: Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: herdrStateChips(workspace),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A tmux session on a shown machine that has no session in the app yet:
/// its name, window count, last activity, and whether another client is
/// attached.
class DormantTmuxTile extends StatelessWidget {
  const DormantTmuxTile({
    required this.session,
    required this.palette,
    required this.brightness,
    required this.onTap,
    this.onLongPress,
    super.key,
  });

  final TmuxSessionInfo session;
  final AppPalette palette;
  final Brightness brightness;
  final VoidCallback onTap;

  /// Lists the session's windows.
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final foreground = palette.foregroundFor(brightness);
    final muted = palette.mutedForegroundFor(brightness);
    return Material(
      color: palette.panelFor(brightness),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radius),
        side: BorderSide(color: palette.hairlineFor(brightness)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        // A right-click opens the same actions (desktop).
        onSecondaryTap: onLongPress,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 11, 10, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const MultiplexerIcon(
                    MultiplexerKind.tmux,
                    size: 16,
                    semanticLabel: '',
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      session.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: foreground,
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Icon(Icons.play_arrow_rounded, size: 18, color: muted),
                ],
              ),
              const SizedBox(height: 3),
              Text(
                tmuxDetails(session),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: muted, fontSize: 12),
              ),
              const Spacer(),
              if (session.isAttached)
                const AttachedChip()
              else
                Text(
                  'tmux session',
                  style: TextStyle(color: muted, fontSize: 11.5),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "2 windows · active 5m ago" for a tmux session.
String tmuxDetails(TmuxSessionInfo session, {DateTime? now}) {
  final windows = session.windows == 1
      ? '1 window'
      : '${session.windows} windows';
  final activity = session.lastActivity;
  if (activity == null) return windows;
  final diff = (now ?? DateTime.now()).toUtc().difference(activity.toUtc());
  final ago = diff.inMinutes < 1
      ? 'just now'
      : diff.inHours < 1
      ? '${diff.inMinutes}m ago'
      : diff.inDays < 1
      ? '${diff.inHours}h ago'
      : '${diff.inDays}d ago';
  return '$windows · active $ago';
}

/// "1 agent · 2 tabs" for a Herdr workspace.
String herdrDetails(HomeBoardWorkspace workspace) {
  final panes = workspace.panes.length;
  final tabs = workspace.workspace.tabCount;
  final details = [
    if (panes > 0) panes == 1 ? '1 agent' : '$panes agents',
    if (tabs > 0) tabs == 1 ? '1 tab' : '$tabs tabs',
  ].join(' · ');
  return details.isEmpty ? 'Not open in the app' : details;
}

/// Pill marking a tmux session another client is attached to.
class AttachedChip extends StatelessWidget {
  const AttachedChip({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppTheme.radius),
      ),
      child: Text(
        'Attached elsewhere',
        style: TextStyle(
          color: colorScheme.onSurfaceVariant,
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// Compact row for one open session in the list view: status dot,
/// transport badge, title, machine, the Herdr workspace or tmux session
/// with its logo, the agent state, and the last line of output.
class HomeSessionRow extends StatelessWidget {
  const HomeSessionRow({
    required this.session,
    required this.info,
    required this.palette,
    required this.brightness,
    required this.fontFamily,
    required this.onTap,
    required this.onLongPress,
    this.selected = false,
    super.key,
  });

  final TerminalSessionController session;
  final HomeSessionInfo info;
  final AppPalette palette;
  final Brightness brightness;
  final String fontFamily;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  /// The last non-blank line on the session's screen.
  static String tailOf(TerminalSessionController session) {
    final lines = TerminalPreview.capture(
      session.terminal,
      rows: 1,
      columns: 160,
    ).lines;
    return lines.isEmpty ? '' : lines.last.trim();
  }

  @override
  Widget build(BuildContext context) {
    final foreground = palette.foregroundFor(brightness);
    final muted = palette.mutedForegroundFor(brightness);
    final state = info.agentState;
    final attention = state != null && state.needsAttention;
    final placeholder =
        info.restoreNote ?? HomeSessionTile.placeholderFor(session.status);
    return Semantics(
      button: true,
      label: [
        session.title,
        info.restoreNote ?? HomeSessionTile.statusLabel(session.status),
        if (showsAgentState(state)) AgentStateChip.labelFor(state!),
      ].join(', '),
      child: Material(
        color: palette.panelFor(brightness),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radius),
          side: BorderSide(
            color: attention
                ? agentStateColor(context, state).withValues(alpha: 0.8)
                : selected
                ? palette.accent.withValues(alpha: 0.75)
                : palette.hairlineFor(brightness),
            width: attention || selected ? 1.5 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 9, 10, 9),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      key: const ValueKey('home-row-dot'),
                      width: 9,
                      height: 9,
                      decoration: BoxDecoration(
                        color: HomeSessionTile.dotColor(
                          context,
                          session.status,
                          state,
                        ),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        session.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: foreground,
                          fontSize: 14.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    if (showsAgentState(state)) ...[
                      AgentStateChip(state: state!),
                      const SizedBox(width: 6),
                    ],
                    TransportBadge.forSession(session),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    const SizedBox(width: 17),
                    if (info.targetLabel.isNotEmpty) ...[
                      SessionTargetIcon(info: info, size: 14),
                      const SizedBox(width: 5),
                      Flexible(
                        child: Text(
                          info.targetLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: info.isHerdr
                                ? AppPalette.of(context).success
                                : muted,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    Flexible(
                      child: Text(
                        info.machineName.isEmpty
                            ? session.host.endpoint
                            : info.machineName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: muted, fontSize: 12.5),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Padding(
                  padding: const EdgeInsets.only(left: 17),
                  child: SessionPreviewBuilder(
                    session: session,
                    builder: (context, _, shared) {
                      final tail = shared?.tail ?? tailOf(session);
                      return Text(
                        placeholder ?? (tail.isEmpty ? ' ' : tail),
                        key: const ValueKey('home-row-tail'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        softWrap: false,
                        style: TextStyle(
                          color: muted,
                          fontFamily: fontFamily,
                          fontSize: 12,
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Compact row for a tmux session or Herdr workspace that is not open in
/// the app (the list view of "Other workspaces").
class OtherWorkspaceRow extends StatelessWidget {
  const OtherWorkspaceRow({
    required this.kind,
    required this.title,
    required this.details,
    required this.palette,
    required this.brightness,
    required this.onTap,
    this.onLongPress,
    this.chips = const [],
    this.attention,
    super.key,
  });

  final MultiplexerKind kind;
  final String title;
  final String details;
  final AppPalette palette;
  final Brightness brightness;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final List<Widget> chips;

  /// Border colour hint when an agent needs input.
  final AgentAttentionState? attention;

  @override
  Widget build(BuildContext context) {
    final foreground = palette.foregroundFor(brightness);
    final muted = palette.mutedForegroundFor(brightness);
    final urgent = attention != null && attention!.needsAttention;
    return Material(
      color: palette.panelFor(brightness),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radius),
        side: BorderSide(
          color: urgent
              ? agentStateColor(context, attention).withValues(alpha: 0.6)
              : palette.hairlineFor(brightness),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          child: Row(
            children: [
              MultiplexerIcon(kind),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: foreground,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      details,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: muted, fontSize: 12),
                    ),
                  ],
                ),
              ),
              if (chips.isNotEmpty) ...[
                const SizedBox(width: 6),
                Flexible(
                  child: Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 4,
                    runSpacing: 4,
                    children: chips,
                  ),
                ),
              ],
              Icon(Icons.play_arrow_rounded, size: 18, color: muted),
            ],
          ),
        ),
      ),
    );
  }
}

/// Chips for a Herdr workspace's agents, most urgent first ("Needs input
/// ×2"), or its Herdr-level status when no agent is listed.
List<Widget> herdrStateChips(HomeBoardWorkspace workspace) {
  final counts = <AgentAttentionState, int>{};
  for (final pane in workspace.panes) {
    counts.update(pane.agent.state, (count) => count + 1, ifAbsent: () => 1);
  }
  final states = counts.keys.toList()
    ..sort((a, b) => homeBoardPriority(a).compareTo(homeBoardPriority(b)));
  final summary = workspace.summary;
  return [
    if (states.isEmpty && summary != null)
      AgentStateChip(state: summary, dense: true),
    for (final state in states)
      AgentStateChip(
        state: state,
        dense: true,
        label: counts[state]! > 1
            ? '${AgentStateChip.labelFor(state)} ×${counts[state]}'
            : null,
      ),
  ];
}

/// What resolves a machine's notice on the home page.
enum HomeBoardNoticeAction {
  /// List a machine that waits for an explicit request.
  request,

  /// Try listing again.
  retry,

  /// Open a session that starts Herdr.
  startHerdr,

  /// Open a plain shell.
  openShell,
}

/// One compact notice about the board, with the action that resolves it.
@immutable
class HomeBoardNotice {
  const HomeBoardNotice({
    required this.icon,
    required this.title,
    required this.message,
    this.detail,
    this.actionLabel,
    this.action,
    this.busy = false,
  });

  final IconData icon;
  final String title;
  final String message;

  /// The technical reason, shown behind "Details".
  final String? detail;
  final String? actionLabel;
  final HomeBoardNoticeAction? action;

  /// A fetch is running (spinner instead of an icon).
  final bool busy;

  /// The notice for a machine's [state], or null when there is nothing to
  /// say (workspaces or tmux sessions are listed, a local machine).
  ///
  /// A machine with tmux but no Herdr is a normal machine: Herdr being
  /// absent (or stopped, while tmux sessions exist) is not worth a notice.
  static HomeBoardNotice? of(
    HomeBoardState state, {
    HomeBoardRequestReason? requestReason,
    bool hasOpenHerdrSession = false,
  }) {
    switch (state.phase) {
      case HomeBoardPhase.idle:
        return null;
      case HomeBoardPhase.awaitingRequest:
        return requestReason == HomeBoardRequestReason.hardwareKey
            ? const HomeBoardNotice(
                icon: Icons.usb_rounded,
                title: 'Hardware-key login',
                message:
                    'Listing tmux sessions and Herdr workspaces opens a '
                    'connection and asks for a key touch.',
                actionLabel: 'List workspaces',
                action: HomeBoardNoticeAction.request,
              )
            : const HomeBoardNotice(
                icon: Icons.verified_user_outlined,
                title: 'Not connected yet',
                message:
                    'Listing tmux sessions and Herdr workspaces connects to '
                    'this machine and may ask you to trust its host key.',
                actionLabel: 'List workspaces',
                action: HomeBoardNoticeAction.request,
              );
      case HomeBoardPhase.loading:
        return const HomeBoardNotice(
          icon: Icons.sync_rounded,
          title: 'Listing workspaces…',
          message: 'Connecting to the machine.',
          busy: true,
        );
      case HomeBoardPhase.notInstalled:
        return switch (state.tmux) {
          HomeTmuxStatus.available => null,
          HomeTmuxStatus.notInstalled => const HomeBoardNotice(
            icon: Icons.extension_off_outlined,
            title: 'No tmux or Herdr here',
            message:
                'Install tmux or Herdr to keep sessions running on this '
                'machine.',
            actionLabel: 'Open a shell',
            action: HomeBoardNoticeAction.openShell,
          ),
          HomeTmuxStatus.unknown || HomeTmuxStatus.failed => HomeBoardNotice(
            icon: Icons.extension_off_outlined,
            title: 'Herdr is not installed',
            message:
                state.message ?? 'Install Herdr to see its workspaces here.',
            actionLabel: 'Open a shell',
            action: HomeBoardNoticeAction.openShell,
          ),
        };
      case HomeBoardPhase.notRunning:
        if (state.tmuxSessions.isNotEmpty) return null;
        return const HomeBoardNotice(
          icon: Icons.pause_circle_outline_rounded,
          title: 'Herdr is not running',
          message: 'Start Herdr to run agents on this machine.',
          actionLabel: 'Start Herdr',
          action: HomeBoardNoticeAction.startHerdr,
        );
      case HomeBoardPhase.failed:
        final problem = state.problem;
        if (problem != null) {
          // The machine was not reached (or refused the sign-in): say so
          // instead of blaming the listing.
          final stale =
              state.workspaces.isNotEmpty || state.tmuxSessions.isNotEmpty;
          return HomeBoardNotice(
            icon: stale
                ? Icons.history_rounded
                : problem.kind == ConnectionProblemKind.unreachable
                ? Icons.cloud_off_rounded
                : Icons.lock_outline_rounded,
            title: problem.title,
            message: stale
                ? 'Showing the last list. ${problem.message}'
                : problem.message,
            detail: problem.detail,
            actionLabel: 'Retry',
            action: HomeBoardNoticeAction.retry,
          );
        }
        final reason = state.message ?? 'The machine did not answer.';
        final herdrOnly = state.hasTmux;
        if (herdrOnly && state.tmuxSessions.isNotEmpty) {
          // tmux answered: only Herdr is broken; say so briefly.
          return HomeBoardNotice(
            icon: Icons.history_rounded,
            title: 'Could not list Herdr workspaces',
            message: reason,
            actionLabel: 'Retry',
            action: HomeBoardNoticeAction.retry,
          );
        }
        return state.workspaces.isEmpty && state.tmuxSessions.isEmpty
            ? HomeBoardNotice(
                icon: Icons.cloud_off_rounded,
                title: herdrOnly
                    ? 'Could not list Herdr workspaces'
                    : 'Could not list workspaces',
                message: reason,
                actionLabel: 'Retry',
                action: HomeBoardNoticeAction.retry,
              )
            : HomeBoardNotice(
                icon: Icons.history_rounded,
                title: 'Showing the last list',
                message: reason,
                actionLabel: 'Retry',
                action: HomeBoardNoticeAction.retry,
              );
      case HomeBoardPhase.ready:
        if (state.workspaces.isNotEmpty ||
            hasOpenHerdrSession ||
            state.tmuxSessions.isNotEmpty) {
          return null;
        }
        return const HomeBoardNotice(
          icon: Icons.space_dashboard_outlined,
          title: 'No Herdr workspaces',
          message: 'Herdr is running but has no workspaces yet.',
          actionLabel: 'Open Herdr',
          action: HomeBoardNoticeAction.startHerdr,
        );
    }
  }
}

/// Full-width compact card for a [HomeBoardNotice].
class HomeBoardNoticeTile extends StatefulWidget {
  const HomeBoardNoticeTile({
    required this.notice,
    required this.palette,
    required this.brightness,
    this.onAction,
    super.key,
  });

  final HomeBoardNotice notice;
  final AppPalette palette;
  final Brightness brightness;
  final VoidCallback? onAction;

  @override
  State<HomeBoardNoticeTile> createState() => _HomeBoardNoticeTileState();
}

class _HomeBoardNoticeTileState extends State<HomeBoardNoticeTile> {
  bool _showDetail = false;

  @override
  Widget build(BuildContext context) {
    final notice = widget.notice;
    final palette = widget.palette;
    final brightness = widget.brightness;
    final onAction = widget.onAction;
    final foreground = palette.foregroundFor(brightness);
    final muted = palette.mutedForegroundFor(brightness);
    final label = notice.actionLabel;
    final detail = notice.detail;
    return Container(
      key: const ValueKey('home-board-notice'),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: palette.panelFor(brightness),
        borderRadius: BorderRadius.circular(AppTheme.radius),
        border: Border.all(color: palette.hairlineFor(brightness)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 22,
            height: 22,
            child: notice.busy
                ? const Padding(
                    padding: EdgeInsets.all(3),
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    notice.icon,
                    size: 20,
                    color: Theme.of(context).colorScheme.primary,
                  ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  notice.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: foreground,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  notice.message,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: muted, fontSize: 12, height: 1.25),
                ),
                if (detail != null) ...[
                  const SizedBox(height: 2),
                  InkWell(
                    key: const ValueKey('home-board-notice-details'),
                    onTap: () => setState(() => _showDetail = !_showDetail),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(
                        _showDetail ? 'Hide details' : 'Details',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.primary,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  if (_showDetail)
                    SelectableText(
                      detail,
                      key: const ValueKey('home-board-notice-detail-text'),
                      style: TextStyle(
                        color: muted,
                        fontSize: 11,
                        height: 1.25,
                        fontFamily: 'monospace',
                      ),
                    ),
                ],
              ],
            ),
          ),
          if (label != null && onAction != null) ...[
            const SizedBox(width: 6),
            FilledButton.tonal(
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 12),
              ),
              onPressed: onAction,
              child: Text(label),
            ),
          ],
        ],
      ),
    );
  }
}

/// Small pill with an agent state (and a dot in its colour).
class AgentStateChip extends StatelessWidget {
  const AgentStateChip({
    required this.state,
    this.label,
    this.dense = false,
    super.key,
  });

  final AgentAttentionState state;

  /// Overrides the state's label.
  final String? label;

  /// Tighter padding and text for tiles.
  final bool dense;

  static String labelFor(AgentAttentionState state) => switch (state) {
    AgentAttentionState.working => 'Working',
    AgentAttentionState.needsInput => 'Needs input',
    AgentAttentionState.blocked => 'Blocked',
    AgentAttentionState.finished => 'Done',
    AgentAttentionState.idle => 'Idle',
    AgentAttentionState.unknown => 'Unknown',
  };

  @override
  Widget build(BuildContext context) {
    final color = agentStateColor(context, state);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 6 : 8,
        vertical: dense ? 2 : 3,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(AppTheme.radius),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 4),
          Text(
            label ?? labelFor(state),
            style: TextStyle(
              color: color,
              fontSize: dense ? 10.5 : 11,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

/// Colour of an agent state across the home page.
Color agentStateColor(BuildContext context, AgentAttentionState? state) {
  final colorScheme = Theme.of(context).colorScheme;
  return switch (state) {
    AgentAttentionState.needsInput ||
    AgentAttentionState.blocked => AppPalette.of(context).attention,
    AgentAttentionState.working => colorScheme.primary,
    AgentAttentionState.finished => AppPalette.of(context).success,
    AgentAttentionState.idle ||
    AgentAttentionState.unknown ||
    null => colorScheme.onSurfaceVariant,
  };
}
