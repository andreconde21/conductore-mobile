import 'dart:async';
import 'dart:math' as math;

import 'package:conduit/core/presentation/adaptive_modal.dart';
import 'package:conduit/core/presentation/multiplexer_icon.dart';
import 'package:conduit/core/presentation/system_navigation_insets.dart';
import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/core/theme/app_theme.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/hosts/presentation/widgets/home_session_grid.dart';
import 'package:conduit/features/session_navigation/presentation/quick_switcher_actions.dart';
import 'package:conduit/features/session_navigation/presentation/quick_switcher_model.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:conduit/features/sessions/presentation/live_terminal_preview.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// What the user picked in the quick switcher.
sealed class QuickSwitcherChoice {
  const QuickSwitcherChoice();
}

/// Open this row.
class QuickSwitcherOpen extends QuickSwitcherChoice {
  const QuickSwitcherOpen(this.item);

  final SwitcherItem item;
}

/// The header's "+": a new session through the connect picker.
class QuickSwitcherNewSession extends QuickSwitcherChoice {
  const QuickSwitcherNewSession();
}

/// The header's grid button: the session grid page.
class QuickSwitcherShowGrid extends QuickSwitcherChoice {
  const QuickSwitcherShowGrid();
}

/// Whether the search field takes the focus at once: on a desktop, when a
/// hardware keyboard opened the switcher, or when it was opened to search
/// ([focusSearch], the home's search button). Otherwise, on a phone, the
/// soft keyboard would cover the list.
bool _focusSearchFirst(bool fromKeyboard, {bool focusSearch = false}) =>
    fromKeyboard ||
    focusSearch ||
    switch (defaultTargetPlatform) {
      TargetPlatform.linux ||
      TargetPlatform.macOS ||
      TargetPlatform.windows => true,
      _ => false,
    };

/// The quick switcher, like a phone's app switcher: a full-height sheet
/// with a search field and, in order, the agents waiting on the user, the
/// open sessions (live thumbnails), the other workspaces on the machines
/// and the recent targets. Resolves with the choice (null when dismissed);
/// the caller opens it, see [openSwitcherItem]. With [focusSearch] the
/// search field takes the focus (and the keyboard comes up) at once.
Future<QuickSwitcherChoice?> showQuickSwitcher(
  BuildContext context, {
  required QuickSwitcherSource source,
  String fontFamily = 'monospace',
  bool fromKeyboard = false,
  bool focusSearch = false,
  bool canCreate = false,
  bool canShowGrid = false,
  Duration previewRefreshInterval = const Duration(seconds: 2),
}) {
  final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
  return showAdaptiveModal<QuickSwitcherChoice>(
    kind: AdaptiveModalKind.palette,
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    sheetAnimationStyle: reduceMotion ? AnimationStyle.noAnimation : null,
    builder: (context) => QuickSwitcherSheet(
      source: source,
      fontFamily: fontFamily,
      autofocusSearch: _focusSearchFirst(
        fromKeyboard,
        focusSearch: focusSearch,
      ),
      canCreate: canCreate,
      canShowGrid: canShowGrid,
      previewRefreshInterval: previewRefreshInterval,
    ),
  );
}

class QuickSwitcherSheet extends StatefulWidget {
  const QuickSwitcherSheet({
    required this.source,
    this.fontFamily = 'monospace',
    this.autofocusSearch = false,
    this.canCreate = false,
    this.canShowGrid = false,
    this.previewRefreshInterval = const Duration(seconds: 2),
    super.key,
  });

  final QuickSwitcherSource source;
  final String fontFamily;
  final bool autofocusSearch;
  final bool canCreate;
  final bool canShowGrid;

  /// How often the session thumbnails are re-captured.
  final Duration previewRefreshInterval;

  @override
  State<QuickSwitcherSheet> createState() => _QuickSwitcherSheetState();
}

class _QuickSwitcherSheetState extends State<QuickSwitcherSheet> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  final _highlightKey = GlobalKey();
  Map<String, List<ConnectTarget>> _recents = const {};
  Timer? _refresh;

  /// Index into the visible rows of the row Enter opens; shown once the
  /// keyboard is in use.
  int _highlight = 0;
  late bool _keyboard = widget.autofocusSearch;
  bool _done = false;
  List<SwitcherItem> _visible = const [];
  final _previewTicks = ValueNotifier<int>(0);

  @override
  void initState() {
    super.initState();
    unawaited(_loadRecents());
    // The boards pause while the home page is covered; list afresh (after
    // this frame: a refresh notifies at once).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(widget.source.homeBoards?.refresh());
    });
    // Previews redraw on a tick, each only after its terminal printed
    // (see TerminalSnapshotBuilder); the sheet itself does not rebuild.
    _refresh = Timer.periodic(widget.previewRefreshInterval, (_) {
      if (mounted) _previewTicks.value += 1;
    });
  }

  Future<void> _loadRecents() async {
    final recents = await widget.source.loadRecents();
    if (mounted) setState(() => _recents = recents);
  }

  @override
  void dispose() {
    _refresh?.cancel();
    _previewTicks.dispose();
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _choose(QuickSwitcherChoice choice) {
    if (_done) return;
    _done = true;
    Navigator.of(context).pop(choice);
  }

  void _openHighlighted() {
    if (_visible.isEmpty) return;
    _choose(
      QuickSwitcherOpen(_visible[_highlight.clamp(0, _visible.length - 1)]),
    );
  }

  void _move(int delta) {
    if (_visible.isEmpty) return;
    setState(() {
      _keyboard = true;
      _highlight = (_highlight + delta).clamp(0, _visible.length - 1);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _highlightKey.currentContext;
      if (!mounted || target == null) return;
      unawaited(
        Scrollable.ensureVisible(
          target,
          alignmentPolicy: delta > 0
              ? ScrollPositionAlignmentPolicy.keepVisibleAtEnd
              : ScrollPositionAlignmentPolicy.keepVisibleAtStart,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final brightness = Theme.of(context).brightness;
    final theme = Theme.of(context);
    final muted = palette.mutedForegroundFor(brightness);
    final media = MediaQuery.of(context);
    // Clear of the 3-button bar, or of the keyboard (which covers it).
    final bottom = math.max(
      shouldApplyBottomSafeArea(context) ? media.viewPadding.bottom : 0.0,
      media.viewInsets.bottom,
    );
    return PreviewClock(
      ticks: _previewTicks,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.arrowDown): () => _move(1),
          const SingleActivator(LogicalKeyboardKey.arrowUp): () => _move(-1),
          const SingleActivator(LogicalKeyboardKey.enter): _openHighlighted,
          const SingleActivator(LogicalKeyboardKey.numpadEnter):
              _openHighlighted,
        },
        child: Focus(
          autofocus: !widget.autofocusSearch,
          child: SizedBox(
            key: const ValueKey('quick-switcher'),
            height: media.size.height,
            child: Padding(
              padding: EdgeInsets.only(bottom: bottom),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 10, 6, 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Switch to',
                            style: theme.textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        if (widget.canShowGrid)
                          IconButton(
                            tooltip: 'Session grid',
                            icon: const Icon(Icons.grid_view_rounded),
                            onPressed: () =>
                                _choose(const QuickSwitcherShowGrid()),
                          ),
                        if (widget.canCreate)
                          IconButton(
                            tooltip: 'New session',
                            icon: const Icon(Icons.add_rounded),
                            onPressed: () =>
                                _choose(const QuickSwitcherNewSession()),
                          ),
                        IconButton(
                          tooltip: 'Close',
                          icon: const Icon(Icons.close_rounded),
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
                    child: TextField(
                      key: const ValueKey('quick-switcher-search'),
                      controller: _search,
                      focusNode: _searchFocus,
                      autofocus: widget.autofocusSearch,
                      textInputAction: TextInputAction.go,
                      onChanged: (_) => setState(() => _highlight = 0),
                      onSubmitted: (_) => _openHighlighted(),
                      decoration: InputDecoration(
                        isDense: true,
                        prefixIcon: const Icon(Icons.search_rounded),
                        hintText: 'Workspace, folder, agent, machine, project…',
                        border: OutlineInputBorder(
                          borderRadius: AppTheme.borderRadius,
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: ListenableBuilder(
                      listenable: widget.source.changes,
                      builder: (context, _) {
                        final sections = filterSwitcher(
                          widget.source.items(recents: _recents),
                          _search.text,
                        );
                        _visible = [
                          for (final section in sections) ...section.items,
                        ];
                        if (_visible.isEmpty) {
                          return Center(
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Text(
                                _search.text.trim().isEmpty
                                    ? 'Nothing open yet.'
                                    : 'Nothing matches "${_search.text.trim()}".',
                                style: TextStyle(color: muted),
                              ),
                            ),
                          );
                        }
                        final highlight = _highlight.clamp(
                          0,
                          _visible.length - 1,
                        );
                        var index = 0;
                        return ListView(
                          key: const ValueKey('quick-switcher-list'),
                          padding: const EdgeInsets.fromLTRB(10, 0, 10, 16),
                          children: [
                            for (final section in sections) ...[
                              _SectionHeader(
                                key: ValueKey(
                                  'switcher-section-${section.section.name}',
                                ),
                                label: section.section.label,
                                count: section.items.length,
                              ),
                              for (final item in section.items)
                                _row(
                                  item,
                                  highlighted:
                                      _keyboard && index++ == highlight,
                                  fontFamily: widget.fontFamily,
                                ),
                            ],
                          ],
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(
    SwitcherItem item, {
    required bool highlighted,
    required String fontFamily,
  }) {
    final row = _SwitcherRow(
      key: ValueKey('switcher-${item.key}'),
      item: item,
      highlighted: highlighted,
      fontFamily: fontFamily,
      onTap: () => _choose(QuickSwitcherOpen(item)),
    );
    return highlighted ? KeyedSubtree(key: _highlightKey, child: row) : row;
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label, required this.count, super.key});

  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final muted = palette.mutedForegroundFor(Theme.of(context).brightness);
    final style = TextStyle(
      color: muted,
      fontSize: 11.5,
      fontWeight: FontWeight.w800,
      letterSpacing: 1.1,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 14, 8, 6),
      child: Row(
        children: [
          Text(label, style: style),
          const SizedBox(width: 8),
          Text('$count', style: style.copyWith(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _SwitcherRow extends StatelessWidget {
  const _SwitcherRow({
    required this.item,
    required this.highlighted,
    required this.fontFamily,
    required this.onTap,
    super.key,
  });

  final SwitcherItem item;
  final bool highlighted;
  final String fontFamily;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final brightness = Theme.of(context).brightness;
    final foreground = palette.foregroundFor(brightness);
    final muted = palette.mutedForegroundFor(brightness);
    final radius = BorderRadius.circular(AppTheme.radius);
    final (leading, subtitle, trailing) = _parts(context, palette, brightness);
    final current =
        item is SwitcherSessionItem && (item as SwitcherSessionItem).active;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: highlighted
            ? Color.alphaBlend(
                palette.accent.withValues(alpha: 0.14),
                palette.panelFor(brightness),
              )
            : palette.panelFor(brightness),
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(
            color: highlighted || current
                ? palette.accent.withValues(alpha: 0.6)
                : palette.hairlineFor(brightness),
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 10, 8),
            child: Row(
              children: [
                leading,
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: foreground,
                          fontWeight: FontWeight.w800,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 2),
                      DefaultTextStyle.merge(
                        style: TextStyle(color: muted, fontSize: 12),
                        child: subtitle,
                      ),
                    ],
                  ),
                ),
                if (trailing != null) ...[const SizedBox(width: 8), trailing],
              ],
            ),
          ),
        ),
      ),
    );
  }

  (Widget, Widget, Widget?) _parts(
    BuildContext context,
    AppPalette palette,
    Brightness brightness,
  ) {
    Widget text(String value, {int lines = 1}) =>
        Text(value, maxLines: lines, overflow: TextOverflow.ellipsis);
    Widget iconBox(Widget child) =>
        SizedBox.square(dimension: 40, child: Center(child: child));
    switch (item) {
      case SwitcherAgentItem(:final agent, :final machineName, :final asks):
        final color = agentStateColor(context, agent.state);
        return (
          iconBox(
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(AppTheme.radius),
              ),
              child: Icon(
                agent.pendingRequests.isNotEmpty
                    ? Icons.gpp_maybe_outlined
                    : Icons.chat_bubble_outline_rounded,
                size: 18,
                color: color,
              ),
            ),
          ),
          text('$machineName · $asks', lines: 2),
          AgentStateChip(
            state: agent.state,
            label: agent.pendingRequests.isNotEmpty ? 'Approval' : null,
            dense: true,
          ),
        );
      case SwitcherSessionItem(:final session, :final info, :final machineName):
        final state = info.agentState;
        return (
          _Thumbnail(
            session: session,
            fontFamily: fontFamily,
            palette: palette,
            brightness: brightness,
          ),
          Row(
            children: [
              if (info.multiplexer != null) ...[
                MultiplexerIcon(info.multiplexer!, size: 12, semanticLabel: ''),
                const SizedBox(width: 4),
              ],
              Expanded(
                child: text(
                  [
                    if (info.targetLabel.isNotEmpty &&
                        info.targetLabel != item.title)
                      info.targetLabel,
                    machineName,
                  ].join(' · '),
                ),
              ),
            ],
          ),
          state == null || state == AgentAttentionState.unknown
              ? null
              : AgentStateChip(state: state, dense: true),
        );
      case SwitcherWorkspaceItem(
        :final kind,
        :final machineName,
        :final details,
        :final attention,
      ):
        return (
          iconBox(MultiplexerIcon(kind, size: 22)),
          text([machineName, if (details.isNotEmpty) details].join(' · ')),
          attention == null || !attention.needsAttention
              ? null
              : AgentStateChip(state: attention, dense: true),
        );
      case SwitcherRecentItem(:final multiplexer, :final machineName):
        return (
          iconBox(
            multiplexer == null
                ? Icon(
                    Icons.history_rounded,
                    size: 22,
                    color: palette.mutedForegroundFor(brightness),
                  )
                : MultiplexerIcon(multiplexer, size: 22),
          ),
          text(machineName),
          null,
        );
    }
  }
}

/// A small live picture of a session's screen.
class _Thumbnail extends StatelessWidget {
  const _Thumbnail({
    required this.session,
    required this.fontFamily,
    required this.palette,
    required this.brightness,
  });

  final TerminalSessionController session;
  final String fontFamily;
  final AppPalette palette;
  final Brightness brightness;

  static const width = 76.0;
  static const height = 52.0;

  @override
  Widget build(BuildContext context) {
    final theme = palette.terminalThemeFor(brightness);
    return Container(
      width: width,
      height: height,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: theme.background,
        borderRadius: BorderRadius.circular(AppTheme.radius),
        border: Border.all(color: palette.hairlineFor(brightness)),
      ),
      clipBehavior: Clip.antiAlias,
      child: SessionPreviewBuilder(
        session: session,
        builder: (context, preview, shared) => LiveTerminalPreview(
          preview: preview,
          theme: theme,
          fontFamily: fontFamily,
          placeholder: shared != null
              ? 'Herdr'
              : switch (session.status) {
                  TerminalConnectionStatus.connected => '',
                  TerminalConnectionStatus.connecting => '…',
                  _ => '—',
                },
          placeholderColor: palette.mutedForegroundFor(brightness),
        ),
      ),
    );
  }
}
