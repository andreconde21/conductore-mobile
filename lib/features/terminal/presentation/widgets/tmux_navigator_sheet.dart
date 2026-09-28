import 'dart:async';

import 'package:conduit/core/presentation/adaptive_modal.dart';
import 'package:conduit/core/presentation/multiplexer_icon.dart';
import 'package:conduit/core/presentation/system_navigation_insets.dart';
import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/core/theme/app_theme.dart';
import 'package:conduit/features/hosts/domain/multiplexer_prefix_key.dart';
import 'package:conduit/features/terminal/domain/tmux_navigator.dart';
import 'package:flutter/material.dart';

/// How the navigator shows a [TmuxQuickAction], and the tmux default key
/// (after the prefix) typed when the CLI cannot do it.
extension TmuxQuickActionDetails on TmuxQuickAction {
  String get label => switch (this) {
    TmuxQuickAction.splitRight => 'Split right',
    TmuxQuickAction.splitDown => 'Split down',
    TmuxQuickAction.newWindow => 'New window',
    TmuxQuickAction.zoom => 'Zoom',
    TmuxQuickAction.killPane => 'Kill pane',
    TmuxQuickAction.detach => 'Detach',
  };

  IconData get icon => switch (this) {
    TmuxQuickAction.splitRight => Icons.vertical_split_rounded,
    TmuxQuickAction.splitDown => Icons.splitscreen_rounded,
    TmuxQuickAction.newWindow => Icons.add_box_rounded,
    TmuxQuickAction.zoom => Icons.zoom_out_map_rounded,
    TmuxQuickAction.killPane => Icons.cancel_presentation_rounded,
    TmuxQuickAction.detach => Icons.logout_rounded,
  };

  /// tmux's default binding: `%` and `"` split, `c` new window, `z` zoom,
  /// `x` kill pane (tmux asks y/n itself), `d` detach. Key splits open in
  /// the session's start directory, not the pane's.
  String get fallbackKey => switch (this) {
    TmuxQuickAction.splitRight => '%',
    TmuxQuickAction.splitDown => '"',
    TmuxQuickAction.newWindow => 'c',
    TmuxQuickAction.zoom => 'z',
    TmuxQuickAction.killPane => 'x',
    TmuxQuickAction.detach => 'd',
  };

  /// Destructive: the app asks before running it.
  bool get confirm => this == TmuxQuickAction.killPane;

  /// The "new" actions the pill's long-press menu offers.
  static const creating = [
    TmuxQuickAction.splitRight,
    TmuxQuickAction.splitDown,
    TmuxQuickAction.newWindow,
  ];
}

/// What the user picked in the tmux navigator.
sealed class TmuxNavigatorPick {
  const TmuxNavigatorPick();
}

class TmuxPanePick extends TmuxNavigatorPick {
  const TmuxPanePick(this.pane);

  final TmuxPaneEntry pane;
}

class TmuxActionPick extends TmuxNavigatorPick {
  const TmuxActionPick(this.action);

  final TmuxQuickAction action;
}

/// Window [index] (1–9) of the app's session.
class TmuxWindowPick extends TmuxNavigatorPick {
  const TmuxWindowPick(this.index);

  final int index;
}

/// "cd to…": open the recent-directories sheet.
class TmuxCdToPick extends TmuxNavigatorPick {
  const TmuxCdToPick();
}

/// Opens the tmux navigator: one-tap actions and windows 1–9, then every
/// pane on the server as session › window › pane (tap switches this app's
/// client to it).
///
/// [sessionName] is the tmux session this app tab attached; its client's
/// pane is marked current. [cached] shows straight away and [load], when
/// given, refreshes it.
Future<TmuxNavigatorPick?> showTmuxNavigatorSheet({
  required BuildContext context,
  required AppPalette palette,
  required Brightness brightness,
  required MultiplexerPrefixKey hostPrefix,
  required String sessionName,
  TmuxListing? cached,
  Future<TmuxListing> Function()? load,
  String? paneListUnavailableReason,
  bool showCdTo = false,
}) {
  return showAdaptiveModal<TmuxNavigatorPick>(
    kind: AdaptiveModalKind.sidePanel,
    context: context,
    // The whole panel on desktop: nothing to drag there.
    desktopFill: true,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: palette.panelFor(brightness),
    builder: (context) => TmuxNavigatorSheet(
      palette: palette,
      brightness: brightness,
      hostPrefix: hostPrefix,
      sessionName: sessionName,
      cached: cached,
      load: load,
      paneListUnavailableReason: paneListUnavailableReason,
      showCdTo: showCdTo,
    ),
  );
}

class TmuxNavigatorSheet extends StatefulWidget {
  const TmuxNavigatorSheet({
    required this.palette,
    required this.brightness,
    required this.hostPrefix,
    required this.sessionName,
    this.cached,
    this.load,
    this.paneListUnavailableReason,
    this.showCdTo = false,
    super.key,
  });

  final AppPalette palette;
  final Brightness brightness;
  final MultiplexerPrefixKey hostPrefix;
  final String sessionName;
  final TmuxListing? cached;
  final Future<TmuxListing> Function()? load;
  final String? paneListUnavailableReason;
  final bool showCdTo;

  @override
  State<TmuxNavigatorSheet> createState() => _TmuxNavigatorSheetState();
}

class _TmuxNavigatorSheetState extends State<TmuxNavigatorSheet> {
  late TmuxListing? _listing = widget.cached;
  bool _loading = false;

  AppPalette get _palette => widget.palette;
  Brightness get _brightness => widget.brightness;
  Color get _muted => _palette.mutedForegroundFor(_brightness);

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    final load = widget.load;
    if (load == null) {
      return;
    }
    setState(() => _loading = true);
    TmuxListing listing;
    try {
      listing = await load();
    } catch (error) {
      listing = TmuxListingFailed('$error');
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _loading = false;
      if (listing is! TmuxListingFailed || _listing is! TmuxPanesAvailable) {
        _listing = listing;
      }
    });
  }

  void _pick(TmuxNavigatorPick pick) => Navigator.of(context).pop(pick);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottomInset = shouldApplyBottomSafeArea(context)
        ? MediaQuery.viewPaddingOf(context).bottom
        : 0.0;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: adaptiveSheetFraction(context, 0.72),
      minChildSize: adaptiveSheetFraction(context, 0.4),
      maxChildSize: adaptiveSheetFraction(context, 0.94),
      builder: (context, scrollController) => ListView(
        key: const ValueKey('tmux-navigator'),
        controller: scrollController,
        padding: EdgeInsets.fromLTRB(16, 8, 16, 16 + bottomInset),
        children: [
          Row(
            children: [
              const MultiplexerIcon(MultiplexerKind.tmux, size: 24),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'tmux · ${widget.sessionName}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleLarge,
                ),
              ),
              Text(
                'prefix ${widget.hostPrefix.label}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: _muted,
                  fontFamily: 'monospace',
                ),
              ),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.only(left: 12),
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else if (widget.load != null)
                IconButton(
                  key: const ValueKey('tmux-refresh'),
                  tooltip: 'Refresh panes',
                  visualDensity: VisualDensity.compact,
                  onPressed: _refresh,
                  icon: const Icon(Icons.refresh_rounded),
                ),
            ],
          ),
          if (widget.showCdTo)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: ActionChip(
                  key: const ValueKey('tmux-cd-to'),
                  avatar: const Icon(Icons.folder_open_rounded, size: 16),
                  label: const Text('cd to…'),
                  onPressed: () => _pick(const TmuxCdToPick()),
                ),
              ),
            ),
          const SizedBox(height: 12),
          _quickActions(theme),
          const SizedBox(height: 12),
          _windows(theme),
          const SizedBox(height: 18),
          _sectionLabel(theme, 'Panes'),
          const SizedBox(height: 6),
          ..._paneSection(theme),
        ],
      ),
    );
  }

  Widget _quickActions(ThemeData theme) {
    final accent = _palette.accent;
    return GridView.count(
      crossAxisCount: 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 6,
      crossAxisSpacing: 6,
      childAspectRatio: 2.1,
      children: [
        for (final action in TmuxQuickAction.values)
          Material(
            color: TmuxQuickActionDetails.creating.contains(action)
                ? Color.alphaBlend(
                    accent.withValues(alpha: 0.14),
                    _palette.panelElevatedFor(_brightness),
                  )
                : _palette.panelElevatedFor(_brightness),
            borderRadius: BorderRadius.circular(AppTheme.radius),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: ValueKey('tmux-quick-${action.name}'),
              onTap: () => _pick(TmuxActionPick(action)),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      action.icon,
                      size: 18,
                      color: action.confirm ? _palette.warning : accent,
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        action.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelLarge,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _windows(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Window  ·  ${widget.hostPrefix.label} 1–9',
          style: theme.textTheme.labelMedium?.copyWith(color: _muted),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            for (var index = 1; index <= 9; index += 1) ...[
              if (index > 1) const SizedBox(width: 4),
              Expanded(
                child: SizedBox(
                  height: 40,
                  child: OutlinedButton(
                    key: ValueKey('tmux-window-$index'),
                    style: OutlinedButton.styleFrom(
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(0, 40),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppTheme.radius),
                      ),
                    ),
                    onPressed: () => _pick(TmuxWindowPick(index)),
                    child: Text(
                      '$index',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }

  Widget _sectionLabel(ThemeData theme, String label) {
    return Text(
      label.toUpperCase(),
      style: theme.textTheme.labelSmall?.copyWith(
        color: _muted,
        letterSpacing: 1.1,
        fontWeight: FontWeight.w700,
      ),
    );
  }

  Widget _message(ThemeData theme, String text, {Key? key}) {
    return Padding(
      key: key,
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Text(
        text,
        style: theme.textTheme.bodyMedium?.copyWith(color: _muted),
      ),
    );
  }

  List<Widget> _paneSection(ThemeData theme) {
    if (widget.load == null && widget.cached == null) {
      return [
        _message(
          theme,
          widget.paneListUnavailableReason ?? 'The pane list is not available.',
        ),
      ];
    }
    switch (_listing) {
      case null:
        return [_message(theme, 'Looking for tmux panes…')];
      case TmuxNotFound():
        return [
          _message(
            theme,
            'tmux not found on this machine. The actions above still work '
            'through the prefix key.',
            key: const ValueKey('tmux-not-found'),
          ),
        ];
      case TmuxNotRunning():
        return [_message(theme, 'No tmux server is running.')];
      case TmuxListingFailed(:final message):
        return [_message(theme, 'Could not list tmux panes. $message')];
      case TmuxPanesAvailable(:final snapshot):
        if (snapshot.panes.isEmpty) {
          return [_message(theme, 'tmux has no panes open.')];
        }
        final currentPane = snapshot.targetFor(widget.sessionName)?.paneId;
        final widgets = <Widget>[];
        String? session;
        String? window;
        for (final pane in snapshot.panes) {
          if (pane.sessionId != session) {
            session = pane.sessionId;
            window = null;
            widgets.add(
              Padding(
                padding: const EdgeInsets.only(top: 6, bottom: 4),
                child: Text(
                  pane.sessionName,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: pane.sessionName == widget.sessionName
                        ? _palette.accent
                        : null,
                  ),
                ),
              ),
            );
          }
          if (pane.windowId != window) {
            window = pane.windowId;
            widgets.add(
              Padding(
                padding: const EdgeInsets.only(left: 4, top: 2, bottom: 4),
                child: Text(
                  '${pane.windowIndex}: ${pane.windowName}'
                  '${pane.zoomed ? '  (zoomed)' : ''}',
                  style: theme.textTheme.labelMedium?.copyWith(color: _muted),
                ),
              ),
            );
          }
          widgets.add(
            _paneTile(theme, pane, current: pane.paneId == currentPane),
          );
        }
        return widgets;
    }
  }

  Widget _paneTile(
    ThemeData theme,
    TmuxPaneEntry pane, {
    required bool current,
  }) {
    final accent = _palette.accent;
    final title = pane.command.isEmpty
        ? 'pane ${pane.paneIndex}'
        : pane.command;
    final subtitle = [
      'pane ${pane.paneIndex}',
      if (pane.path.isNotEmpty) pane.path,
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 4, left: 4),
      child: Material(
        key: ValueKey('tmux-pane-${pane.paneId}'),
        color: current
            ? Color.alphaBlend(
                accent.withValues(alpha: 0.18),
                _palette.panelElevatedFor(_brightness),
              )
            : _palette.panelElevatedFor(_brightness),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radius),
          side: current
              ? BorderSide(color: accent.withValues(alpha: 0.7))
              : BorderSide.none,
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _pick(TmuxPanePick(pane)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            child: Row(
              children: [
                Icon(
                  pane.paneActive
                      ? Icons.crop_square_rounded
                      : Icons.check_box_outline_blank_rounded,
                  size: 20,
                  color: current ? accent : _muted,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: _muted,
                        ),
                      ),
                    ],
                  ),
                ),
                if (current) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(AppTheme.radius),
                    ),
                    child: Text(
                      'Current',
                      style: TextStyle(
                        color: accent,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Last tmux listing per host, so the navigator opens with something to
/// show while it refreshes.
class TmuxListingCache {
  TmuxListingCache._();

  static final instance = TmuxListingCache._();

  final _listings = <String, TmuxListing>{};

  TmuxListing? operator [](String hostId) => _listings[hostId];

  void operator []=(String hostId, TmuxListing listing) {
    _listings[hostId] = listing;
  }

  void clear() => _listings.clear();
}
