import 'dart:async';

import 'package:conduit/core/presentation/adaptive_modal.dart';
import 'package:conduit/core/presentation/multiplexer_icon.dart';
import 'package:conduit/core/presentation/system_navigation_insets.dart';
import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/core/theme/app_theme.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/hosts/domain/multiplexer_prefix_key.dart';
import 'package:conduit/features/terminal/domain/herdr_keymap.dart';
import 'package:conduit/features/terminal/domain/herdr_navigator.dart';
import 'package:conduit/features/terminal/domain/herdr_remote_control.dart';
import 'package:conduit/features/terminal/presentation/herdr_shortcuts.dart';
import 'package:flutter/material.dart';

/// What the user picked in the Herdr navigator.
sealed class HerdrNavigatorPick {
  const HerdrNavigatorPick();
}

class HerdrPanePick extends HerdrNavigatorPick {
  const HerdrPanePick(this.entry);

  final HerdrPaneEntry entry;
}

/// "cd to…": open the recent-directories sheet.
class HerdrCdToPick extends HerdrNavigatorPick {
  const HerdrCdToPick();
}

class HerdrShortcutPick extends HerdrNavigatorPick {
  const HerdrShortcutPick(this.shortcut);

  final HerdrShortcut shortcut;
}

/// Open a new pane, tab or workspace in the focused pane's directory.
class HerdrNewPanePick extends HerdrNavigatorPick {
  const HerdrNewPanePick(this.kind);

  final HerdrNewPane kind;
}

/// Jump to tab [number] (1–9) of the focused workspace: Herdr's default
/// `switch_tab = "prefix+1..9"` binding.
class HerdrTabPick extends HerdrNavigatorPick {
  const HerdrTabPick(this.number);

  final int number;
}

/// Opens the Herdr navigator: the host's panes first (switch with a tap),
/// then Herdr's shortcuts grouped by what they act on.
///
/// [cached] is shown straight away; [load], when given, refreshes it as the
/// sheet opens. Without [load] the pane section explains why
/// ([paneListUnavailableReason]) and only the shortcuts are offered.
Future<HerdrNavigatorPick?> showHerdrNavigatorSheet({
  required BuildContext context,
  required AppPalette palette,
  required Brightness brightness,
  required MultiplexerPrefixKey hostPrefix,
  String keymapHostId = '',
  HerdrPaneListing? cached,
  Future<HerdrPaneListing> Function()? load,
  String? paneListUnavailableReason,
  bool showCdTo = false,
}) {
  return showAdaptiveModal<HerdrNavigatorPick>(
    kind: AdaptiveModalKind.sidePanel,
    context: context,
    // The whole panel on desktop: nothing to drag there.
    desktopFill: true,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: palette.panelFor(brightness),
    builder: (context) => HerdrNavigatorSheet(
      palette: palette,
      brightness: brightness,
      hostPrefix: hostPrefix,
      keymapHostId: keymapHostId,
      cached: cached,
      load: load,
      paneListUnavailableReason: paneListUnavailableReason,
      showCdTo: showCdTo,
    ),
  );
}

class HerdrNavigatorSheet extends StatefulWidget {
  const HerdrNavigatorSheet({
    required this.palette,
    required this.brightness,
    required this.hostPrefix,
    this.keymapHostId = '',
    this.cached,
    this.load,
    this.paneListUnavailableReason,
    this.showCdTo = false,
    super.key,
  });

  final AppPalette palette;
  final Brightness brightness;

  /// The host's configured multiplexer prefix; the machine's Herdr
  /// `keys.prefix` wins once its keymap is read.
  final MultiplexerPrefixKey hostPrefix;

  /// Saved host id whose Herdr keymap labels the shortcuts (see
  /// [HerdrKeymapCache]); the labels update when it is read.
  final String keymapHostId;
  final HerdrPaneListing? cached;
  final Future<HerdrPaneListing> Function()? load;
  final String? paneListUnavailableReason;

  /// Adds a "cd to…" chip that resolves to [HerdrCdToPick].
  final bool showCdTo;

  @override
  State<HerdrNavigatorSheet> createState() => _HerdrNavigatorSheetState();
}

class _HerdrNavigatorSheetState extends State<HerdrNavigatorSheet> {
  late HerdrPaneListing? _listing = widget.cached;
  bool _loading = false;

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
    HerdrPaneListing listing;
    try {
      listing = await load();
    } catch (error) {
      listing = HerdrListingFailed('$error');
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _loading = false;
      // Keep showing the cached panes when a refresh fails outright.
      if (listing is! HerdrListingFailed || _listing is! HerdrPanesAvailable) {
        _listing = listing;
      }
    });
  }

  HerdrKeymap get _keymap => HerdrKeymapCache.instance.of(widget.keymapHostId);

  String get _prefixLabel => herdrPrefixOf(_keymap, widget.hostPrefix).label;

  AppPalette get _palette => widget.palette;
  Brightness get _brightness => widget.brightness;

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
      builder: (context, scrollController) {
        return ListenableBuilder(
          listenable: HerdrKeymapCache.instance,
          builder: (context, _) =>
              _buildList(context, theme, scrollController, bottomInset),
        );
      },
    );
  }

  Widget _buildList(
    BuildContext context,
    ThemeData theme,
    ScrollController scrollController,
    double bottomInset,
  ) {
    return ListView(
      key: const ValueKey('herdr-navigator'),
      controller: scrollController,
      padding: EdgeInsets.fromLTRB(16, 8, 16, 16 + bottomInset),
      children: [
        Row(
          children: [
            const MultiplexerIcon(MultiplexerKind.herdr, size: 24),
            const SizedBox(width: 10),
            Expanded(child: Text('Herdr', style: theme.textTheme.titleLarge)),
            if (_loading)
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else if (widget.load != null)
              IconButton(
                key: const ValueKey('herdr-refresh'),
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
                key: const ValueKey('herdr-cd-to'),
                avatar: const Icon(Icons.folder_open_rounded, size: 16),
                label: const Text('cd to…'),
                onPressed: () =>
                    Navigator.of(context).pop(const HerdrCdToPick()),
              ),
            ),
          ),
        const SizedBox(height: 12),
        _newPaneRow(theme),
        const SizedBox(height: 16),
        _sectionLabel(theme, 'Panes'),
        const SizedBox(height: 6),
        ..._buildPaneSection(theme),
        const SizedBox(height: 18),
        Row(
          children: [
            Expanded(child: _sectionLabel(theme, 'Shortcuts')),
            Text(
              'prefix $_prefixLabel',
              style: theme.textTheme.labelSmall?.copyWith(
                color: _palette.mutedForegroundFor(_brightness),
                fontFamily: 'monospace',
              ),
            ),
          ],
        ),
        if (_keymap.switchTabWithPrefix) ...[
          const SizedBox(height: 10),
          _quickTabs(theme),
        ],
        const SizedBox(height: 10),
        _quickActions(theme),
        for (final group in HerdrShortcutGroup.values) ...[
          const SizedBox(height: 10),
          Text(
            group.label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: _palette.mutedForegroundFor(_brightness),
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final shortcut in HerdrShortcut.inGroup(group))
                Tooltip(
                  message: shortcut.keyHintIn(_keymap, _prefixLabel),
                  child: ActionChip(
                    key: ValueKey('herdr-shortcut-${shortcut.name}'),
                    avatar: Icon(shortcut.icon, size: 16),
                    label: Text(shortcut.label),
                    visualDensity: VisualDensity.compact,
                    onPressed: () =>
                        Navigator.of(context).pop(HerdrShortcutPick(shortcut)),
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }

  /// The prominent one-tap row: split right, split down, new tab, new
  /// workspace, each opening in the focused pane's directory.
  Widget _newPaneRow(ThemeData theme) {
    final accent = _palette.accent;
    return Row(
      children: [
        for (final (index, kind) in HerdrNewPane.values.indexed) ...[
          if (index > 0) const SizedBox(width: 6),
          Expanded(
            child: Material(
              color: Color.alphaBlend(
                accent.withValues(alpha: 0.14),
                _palette.panelElevatedFor(_brightness),
              ),
              borderRadius: BorderRadius.circular(AppTheme.radius),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                key: ValueKey('herdr-new-${kind.name}'),
                onTap: () => Navigator.of(context).pop(HerdrNewPanePick(kind)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 10,
                  ),
                  child: Column(
                    children: [
                      Icon(kind.icon, color: accent),
                      const SizedBox(height: 4),
                      Text(
                        kind.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.labelMedium,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// Tab 1–9 buttons (`prefix 1` … `prefix 9`).
  Widget _quickTabs(ThemeData theme) {
    final muted = _palette.mutedForegroundFor(_brightness);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Jump to tab  ·  $_prefixLabel 1–9',
          style: theme.textTheme.labelMedium?.copyWith(color: muted),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            for (var number = 1; number <= 9; number += 1) ...[
              if (number > 1) const SizedBox(width: 4),
              Expanded(
                child: SizedBox(
                  height: 40,
                  child: OutlinedButton(
                    key: ValueKey('herdr-tab-$number'),
                    style: OutlinedButton.styleFrom(
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(0, 40),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppTheme.radius),
                      ),
                    ),
                    onPressed: () =>
                        Navigator.of(context).pop(HerdrTabPick(number)),
                    child: Text(
                      '$number',
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

  /// One-tap actions, each labelled with the keys it sends.
  Widget _quickActions(ThemeData theme) {
    final muted = _palette.mutedForegroundFor(_brightness);
    return GridView.count(
      crossAxisCount: 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 6,
      crossAxisSpacing: 6,
      childAspectRatio: 2.1,
      children: [
        for (final shortcut in HerdrShortcut.quick)
          Material(
            color: _palette.panelElevatedFor(_brightness),
            borderRadius: BorderRadius.circular(AppTheme.radius),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: ValueKey('herdr-quick-${shortcut.name}'),
              onTap: () =>
                  Navigator.of(context).pop(HerdrShortcutPick(shortcut)),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          shortcut.icon,
                          size: 16,
                          color: shortcut.confirm
                              ? _palette.warning
                              : _palette.accent,
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            shortcut.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelLarge,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      shortcut.keyHintIn(_keymap, _prefixLabel),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: muted,
                        fontFamily: 'monospace',
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

  Widget _sectionLabel(ThemeData theme, String label) {
    return Text(
      label.toUpperCase(),
      style: theme.textTheme.labelSmall?.copyWith(
        color: _palette.mutedForegroundFor(_brightness),
        letterSpacing: 1.1,
        fontWeight: FontWeight.w700,
      ),
    );
  }

  List<Widget> _buildPaneSection(ThemeData theme) {
    final reason = widget.paneListUnavailableReason;
    if (widget.load == null && widget.cached == null) {
      return [_message(theme, reason ?? 'The pane list is not available.')];
    }
    final listing = _listing;
    switch (listing) {
      case null:
        return [_message(theme, 'Looking for Herdr panes…')];
      case HerdrNotFound():
        return [
          _message(
            theme,
            'Herdr not found on this machine. The shortcuts below still '
            'work if Herdr runs inside this session.',
            key: const ValueKey('herdr-not-found'),
          ),
        ];
      case HerdrNotRunning():
        return [_message(theme, 'Herdr is installed but not running.')];
      case HerdrListingFailed(:final message):
        return [_message(theme, 'Could not list Herdr panes. $message')];
      case HerdrPanesAvailable(:final entries):
        if (entries.isEmpty) {
          return [_message(theme, 'Herdr has no panes open.')];
        }
        return [for (final entry in entries) _paneTile(theme, entry)];
    }
  }

  Widget _message(ThemeData theme, String text, {Key? key}) {
    return Padding(
      key: key,
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Text(
        text,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: _palette.mutedForegroundFor(_brightness),
        ),
      ),
    );
  }

  Widget _paneTile(ThemeData theme, HerdrPaneEntry entry) {
    final accent = _palette.accent;
    final location = [
      entry.workspaceLabel,
      if (entry.tabLabel.isNotEmpty && entry.tabLabel != entry.title)
        entry.tabLabel,
    ].join(' › ');
    final title = entry.title.isEmpty ? entry.workspaceLabel : entry.title;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        key: ValueKey('herdr-pane-${entry.paneId ?? entry.tabId}'),
        color: entry.focused
            ? Color.alphaBlend(
                accent.withValues(alpha: 0.18),
                _palette.panelElevatedFor(_brightness),
              )
            : _palette.panelElevatedFor(_brightness),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radius),
          side: entry.focused
              ? BorderSide(color: accent.withValues(alpha: 0.7))
              : BorderSide.none,
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => Navigator.of(context).pop(HerdrPanePick(entry)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            child: Row(
              children: [
                Icon(
                  entry.isAgent
                      ? Icons.smart_toy_outlined
                      : Icons.terminal_rounded,
                  size: 20,
                  color: entry.focused
                      ? accent
                      : _palette.mutedForegroundFor(_brightness),
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
                        [
                          location,
                          if (entry.agentKind.isNotEmpty) entry.agentKind,
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: _palette.mutedForegroundFor(_brightness),
                        ),
                      ),
                    ],
                  ),
                ),
                if (entry.focused) ...[
                  const SizedBox(width: 8),
                  _chip('Current', accent),
                ],
                if (entry.status case final status?) ...[
                  const SizedBox(width: 6),
                  _chip(status.label, _statusColor(status)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Color _statusColor(AgentAttentionState status) => switch (status) {
    AgentAttentionState.needsInput ||
    AgentAttentionState.blocked => _palette.warning,
    AgentAttentionState.working => _palette.accent,
    AgentAttentionState.finished => _palette.success,
    AgentAttentionState.idle ||
    AgentAttentionState.unknown => _palette.mutedForegroundFor(_brightness),
  };

  Widget _chip(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(AppTheme.radius),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
