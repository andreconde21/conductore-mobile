import 'dart:async';
import 'dart:math' as math;

import 'package:conduit/core/presentation/adaptive_modal.dart';
import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/features/usage/domain/usage_report.dart';
import 'package:conduit/features/usage/domain/usage_summary.dart';
import 'package:conduit/features/usage/presentation/usage_controller.dart';
import 'package:conduit/features/usage/presentation/usage_explorer_view.dart';
import 'package:flutter/material.dart';

/// Makes the app's [UsageController] reachable from any route (the home
/// bar, the Agents panel, Settings, the desktop shell).
class UsageScope extends InheritedWidget {
  const UsageScope({
    required this.controller,
    required super.child,
    this.openExplorer,
    super.key,
  });

  final UsageController controller;

  /// Shows the usage explorer (at [day] when given) somewhere other than
  /// a pushed page: the desktop shell's main area. Null: a page.
  final void Function({String? day})? openExplorer;

  static UsageController? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<UsageScope>()?.controller;

  static UsageScope? scopeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<UsageScope>();

  @override
  bool updateShouldNotify(UsageScope oldWidget) =>
      controller != oldWidget.controller ||
      openExplorer != oldWidget.openExplorer;
}

/// The colour of a limit at [percent]: the theme's accent, its yellow from
/// 80 %, its red from 95 % (flat Omarchy colours).
Color usageColor(double percent, AppPalette palette) =>
    switch (usageLevelFor(percent)) {
      UsageLevel.normal => palette.accent,
      UsageLevel.warning => palette.warning,
      UsageLevel.critical => palette.danger,
    };

/// A limit window as a ring: the share used, coloured by [usageColor],
/// the percentage inside. A null [percent] draws an empty track ("not
/// reported").
class UsageRing extends StatelessWidget {
  const UsageRing({
    required this.percent,
    this.size = 34,
    this.showPercent = true,
    this.semanticLabel,
    super.key,
  });

  final double? percent;
  final double size;
  final bool showPercent;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final value = percent?.clamp(0, 100).toDouble();
    final stroke = math.max(2.5, size / 9);
    return Semantics(
      label: semanticLabel,
      value: value == null ? 'not reported' : '${value.round()} percent',
      child: SizedBox.square(
        dimension: size,
        child: CustomPaint(
          painter: _UsageRingPainter(
            fraction: (value ?? 0) / 100,
            color: usageColor(value ?? 0, palette),
            track: palette.hairline,
            stroke: stroke,
          ),
          child: showPercent && size >= 26
              ? Center(
                  child: Text(
                    value == null ? '–' : '${value.round()}',
                    style: TextStyle(
                      fontSize: size * 0.3,
                      fontWeight: FontWeight.w700,
                      color: palette.foreground,
                      height: 1,
                    ),
                  ),
                )
              : null,
        ),
      ),
    );
  }
}

class _UsageRingPainter extends CustomPainter {
  const _UsageRingPainter({
    required this.fraction,
    required this.color,
    required this.track,
    required this.stroke,
  });

  final double fraction;
  final Color color;
  final Color track;
  final double stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(stroke / 2);
    canvas.drawArc(
      rect,
      0,
      math.pi * 2,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = track,
    );
    if (fraction <= 0) {
      return;
    }
    // Flat: square caps, no gradient.
    canvas.drawArc(
      rect,
      -math.pi / 2,
      math.pi * 2 * fraction.clamp(0, 1),
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.butt
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_UsageRingPainter old) =>
      old.fraction != fraction ||
      old.color != color ||
      old.track != track ||
      old.stroke != stroke;
}

/// Keeps [controller] polling while this widget is mounted.
mixin UsageViewAttachment<T extends StatefulWidget> on State<T> {
  UsageController get usageController;
  VoidCallback? _detach;

  /// A screen opened to look at usage asks every machine at once
  /// ([UsageController.attachView] with `refresh`); the home bar does not.
  bool get refreshUsageOnOpen => false;

  @override
  void initState() {
    super.initState();
    _detach = usageController.attachView(refresh: refreshUsageOnOpen);
  }

  @override
  void dispose() {
    _detach?.call();
    super.dispose();
  }
}

/// How [UsageSummaryView] lays itself out.
enum UsageSummaryLayout {
  /// Rings of 34 px with labels, today's tokens and cost beside them: the
  /// phone home bar, a desktop dashboard card.
  bar,

  /// One line of small rings and today's cost: a sidebar footer.
  compact,
}

/// Claude's 5-hour and weekly limit rings and today's tokens and estimated
/// cost across every machine. Drop-in: give it the app's controller
/// ([UsageScope.maybeOf]); it keeps usage fresh while it is on screen.
class UsageSummaryView extends StatefulWidget {
  const UsageSummaryView({
    required this.controller,
    this.layout = UsageSummaryLayout.bar,
    this.onTap,
    this.onAccounts,
    this.now,
    super.key,
  });

  final UsageController controller;
  final UsageSummaryLayout layout;
  final VoidCallback? onTap;

  /// The accounts line's tap; the details sheet ([showUsageDetails]) by
  /// default.
  final VoidCallback? onAccounts;

  /// For tests.
  final DateTime? now;

  @override
  State<UsageSummaryView> createState() => _UsageSummaryViewState();
}

class _UsageSummaryViewState extends State<UsageSummaryView>
    with UsageViewAttachment {
  @override
  UsageController get usageController => widget.controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final summary = widget.controller.summary;
        final now = widget.now ?? DateTime.now();
        final content = switch (widget.layout) {
          UsageSummaryLayout.bar => _SummaryBar(
            summary: summary,
            controller: widget.controller,
            now: now,
            loading: widget.controller.isLoading,
            onAccounts: widget.onAccounts,
          ),
          UsageSummaryLayout.compact => _SummaryCompact(
            summary: summary,
            controller: widget.controller,
            now: now,
            onAccounts: widget.onAccounts,
          ),
        };
        final onTap = widget.onTap;
        if (onTap == null) {
          return content;
        }
        return InkWell(onTap: onTap, child: content);
      },
    );
  }
}

class _LabeledRing extends StatelessWidget {
  const _LabeledRing({
    required this.label,
    required this.limit,
    required this.now,
  });

  final String label;
  final UsageLimit? limit;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final limit = this.limit;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        UsageRing(
          key: ValueKey('usage-ring-$label'),
          percent: limit?.effectivePct(now),
          semanticLabel: '$label limit',
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            color: palette.mutedForeground,
            height: 1.1,
          ),
        ),
      ],
    );
  }
}

/// The accounts in one line: "3 accounts · best: home 12% · 1 needs
/// re-login" ([dense]: "3 acc · 1 re-login"). "best" only when another
/// account has clearly more headroom than the active one.
String usageAccountsLine(
  UsageSummary summary,
  DateTime now, {
  bool dense = false,
}) {
  final total = summary.accounts.length;
  final best = dense ? null : summary.bestAccount(now);
  final bestUsed = best?.usedPct(now);
  final relogin = summary.reloginCount;
  return [
    dense ? '$total acc' : '$total accounts',
    if (best != null && bestUsed != null)
      'best: ${best.label} ${bestUsed.round()}%',
    if (relogin > 0) dense ? '$relogin re-login' : '$relogin needs re-login',
  ].join(' · ');
}

/// The other Claude accounts as one tappable line (cswap: every account,
/// the active one included, counts): "3 accounts · 1 needs re-login".
/// Nothing without other accounts. A tap opens [onTap], else the accounts
/// sheet ([showUsageDetails]).
class UsageAccountsChip extends StatelessWidget {
  const UsageAccountsChip({
    required this.summary,
    required this.now,
    this.controller,
    this.onTap,
    this.dense = false,
    super.key,
  });

  final UsageSummary summary;
  final DateTime now;

  /// For the default tap: the details sheet.
  final UsageController? controller;
  final VoidCallback? onTap;

  /// Count only: a sidebar or a collapsed bar.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final others = summary.otherAccountCount;
    if (others == 0) {
      return const SizedBox.shrink();
    }
    final total = summary.accounts.length;
    final palette = AppPalette.of(context);
    final warn = summary.reloginCount > 0;
    final hint = !dense && summary.bestAccount(now) != null;
    final color = warn
        ? palette.warning
        : hint
        ? palette.accent
        : palette.mutedForeground;
    final chip = Container(
      padding: const EdgeInsets.fromLTRB(6, 2, 2, 2),
      decoration: BoxDecoration(
        border: Border.all(color: palette.hairline),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              usageAccountsLine(summary, now, dense: dense),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, height: 1.2, color: color),
            ),
          ),
          Icon(Icons.chevron_right_rounded, size: 14, color: color),
        ],
      ),
    );
    final controller = this.controller;
    return Tooltip(
      message:
          '$total Claude accounts (cswap): ${total - others} in use, '
          '$others other${others == 1 ? '' : 's'}',
      child: InkWell(
        key: const ValueKey('usage-accounts-chip'),
        onTap:
            onTap ??
            (controller == null
                ? null
                : () => unawaited(
                    showUsageDetails(context, controller, now: now),
                  )),
        child: chip,
      ),
    );
  }
}

/// A titled section that folds to one header line: [title], a one-line
/// [summary] of what it holds, and a chevron.
class UsageFold extends StatefulWidget {
  const UsageFold({
    required this.id,
    required this.title,
    required this.child,
    this.summary,
    this.initiallyExpanded = false,
    super.key,
  });

  /// Keys the header: `usage-fold-<id>`.
  final String id;
  final String title;
  final String? summary;
  final Widget child;
  final bool initiallyExpanded;

  @override
  State<UsageFold> createState() => _UsageFoldState();
}

class _UsageFoldState extends State<UsageFold> {
  late bool _open = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    final summary = widget.summary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          key: ValueKey('usage-fold-${widget.id}'),
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 200),
                  child: Text(
                    widget.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelLarge,
                  ),
                ),
                if (summary != null && summary.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      summary,
                      key: ValueKey('usage-fold-${widget.id}-summary'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: palette.mutedForeground,
                      ),
                    ),
                  ),
                ] else
                  const Spacer(),
                Semantics(
                  label: _open
                      ? 'Fold ${widget.title}'
                      : 'Show ${widget.title}',
                  child: Icon(
                    _open
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 20,
                    color: palette.mutedForeground,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_open) widget.child,
      ],
    );
  }
}

/// The home card's details: the active account's limits with their resets
/// and ages, today with what the cost means, every account (with Switch),
/// and the way into the explorer. A bottom sheet on phones, a dialog on
/// desktop.
Future<void> showUsageDetails(
  BuildContext context,
  UsageController controller, {
  DateTime? now,
}) => showAdaptiveModal<void>(
  context: context,
  kind: AdaptiveModalKind.dialog,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  desktopMaxWidth: 520,
  builder: (sheetContext) => _UsageDetails(
    controller: controller,
    now: now,
    onExplore: () {
      Navigator.of(sheetContext).pop();
      unawaited(openUsageExplorer(context, controller));
    },
  ),
);

class _UsageDetails extends StatelessWidget {
  const _UsageDetails({
    required this.controller,
    required this.onExplore,
    this.now,
  });

  final UsageController controller;
  final VoidCallback onExplore;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: palette.mutedForeground,
    );
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final summary = controller.summary;
        final now = this.now ?? DateTime.now();
        final hasReport = summary.machines.any((m) => m.report != null);
        final updated = summary.updatedAt;
        return ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.85,
          ),
          child: ListView(
            key: const ValueKey('usage-details'),
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text('Usage', style: theme.textTheme.titleMedium),
                  ),
                  TextButton.icon(
                    key: const ValueKey('usage-details-explore'),
                    onPressed: onExplore,
                    icon: const Icon(Icons.insights_rounded, size: 18),
                    label: const Text('Explore'),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              for (final limit in [?summary.fiveHour, ?summary.weekly])
                UsageLimitBar(agent: 'Claude', limit: limit, now: now),
              if (updated != null)
                Text(
                  'Limits updated ${formatUsageAge(now, updated)}.',
                  key: const ValueKey('usage-details-updated'),
                  style: muted,
                ),
              if (hasReport) ...[
                const SizedBox(height: 10),
                Text(
                  'Today: ${formatUsageTokens(summary.today.tokens)} tokens · '
                  '${formatUsageCost(summary.today.costUsd)}',
                  style: theme.textTheme.bodyMedium,
                ),
                Text(
                  'Costs are estimates at public API list prices. On a '
                  'subscription plan this is the API-equivalent cost, not '
                  'what you pay.',
                  style: muted,
                ),
              ],
              if (summary.accounts.isNotEmpty) ...[
                const SizedBox(height: 14),
                UsageAccountsSection(controller: controller, now: now),
                const SizedBox(height: 4),
                Text(
                  'Accounts come from cswap on your machines. Switch changes '
                  'the account new Claude sessions use; greyed figures are '
                  'ones cswap cannot refresh.',
                  style: muted,
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// The home card: the rings beside at most three lines (today's tokens
/// and cost; the other accounts; how old the figures are, once stale).
/// Explanations live in the details sheet.
class _SummaryBar extends StatelessWidget {
  const _SummaryBar({
    required this.summary,
    required this.controller,
    required this.now,
    required this.loading,
    this.onAccounts,
  });

  final UsageSummary summary;
  final UsageController controller;
  final DateTime now;
  final bool loading;
  final VoidCallback? onAccounts;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    final today = summary.today;
    final hasReport = summary.machines.any((m) => m.report != null);
    final updated = summary.updatedAt;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          _LabeledRing(label: '5h', limit: summary.fiveHour, now: now),
          const SizedBox(width: 10),
          _LabeledRing(label: 'Week', limit: summary.weekly, now: now),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              key: const ValueKey('usage-home-lines'),
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  hasReport
                      ? '${formatUsageTokens(today.tokens)} tokens · '
                            '${formatUsageCost(today.costUsd)} today'
                      : loading
                      ? 'Counting…'
                      : 'No usage reported',
                  key: const ValueKey('usage-today'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (summary.otherAccountCount > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: UsageAccountsChip(
                      summary: summary,
                      now: now,
                      controller: controller,
                      onTap: onAccounts,
                    ),
                  ),
                if (updated != null && summary.isStale(now))
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      'Updated ${formatUsageAge(now, updated)}',
                      key: const ValueKey('usage-updated'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: palette.subtleForeground,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SummaryCompact extends StatelessWidget {
  const _SummaryCompact({
    required this.summary,
    required this.controller,
    required this.now,
    this.onAccounts,
  });

  final UsageSummary summary;
  final UsageController controller;
  final DateTime now;
  final VoidCallback? onAccounts;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final five = summary.fiveHour?.effectivePct(now);
    final week = summary.weekly?.effectivePct(now);
    final hasReport = summary.machines.any((m) => m.report != null);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          Tooltip(
            message: five == null
                ? '5-hour limit: not reported'
                : '5-hour limit: ${five.round()}%',
            child: UsageRing(
              percent: five,
              size: 20,
              showPercent: false,
              semanticLabel: '5h limit',
            ),
          ),
          const SizedBox(width: 6),
          Tooltip(
            message: week == null
                ? 'Weekly limit: not reported'
                : 'Weekly limit: ${week.round()}%',
            child: UsageRing(
              percent: week,
              size: 20,
              showPercent: false,
              semanticLabel: 'Weekly limit',
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              [
                if (five != null) '${five.round()}%',
                if (hasReport)
                  '${formatUsageCost(summary.today.costUsd)} today',
              ].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: palette.mutedForeground),
            ),
          ),
          if (summary.otherAccountCount > 0) ...[
            const SizedBox(width: 6),
            UsageAccountsChip(
              summary: summary,
              now: now,
              controller: controller,
              onTap: onAccounts,
              dense: true,
            ),
          ],
        ],
      ),
    );
  }
}

/// The slim bar at the top of the phone's home screen: limit rings and
/// today's tokens and cost, collapsible to one line. Tapping it opens the
/// usage explorer. Hidden while no machine is asked for usage.
class UsageHomeBar extends StatelessWidget {
  const UsageHomeBar({required this.controller, this.now, super.key});

  final UsageController controller;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final summary = controller.summary;
        if (summary.machines.isEmpty) {
          return const SizedBox.shrink();
        }
        final palette = AppPalette.of(context);
        final collapsed = controller.preferences.barCollapsed;
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
          child: Material(
            key: const ValueKey('usage-home-bar'),
            color: palette.panel,
            shape: RoundedRectangleBorder(
              side: BorderSide(color: palette.hairline),
              borderRadius: BorderRadius.circular(4),
            ),
            clipBehavior: Clip.antiAlias,
            child: Row(
              children: [
                Expanded(
                  child: collapsed
                      ? _CollapsedBar(controller: controller, now: now)
                      : UsageSummaryView(
                          controller: controller,
                          now: now,
                          onTap: () =>
                              unawaited(openUsageExplorer(context, controller)),
                        ),
                ),
                IconButton(
                  key: const ValueKey('usage-bar-toggle'),
                  tooltip: collapsed ? 'Show usage' : 'Hide usage details',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    collapsed
                        ? Icons.expand_more_rounded
                        : Icons.expand_less_rounded,
                    color: palette.mutedForeground,
                  ),
                  onPressed: () => controller.setBarCollapsed(!collapsed),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _CollapsedBar extends StatefulWidget {
  const _CollapsedBar({required this.controller, this.now});

  final UsageController controller;
  final DateTime? now;

  @override
  State<_CollapsedBar> createState() => _CollapsedBarState();
}

class _CollapsedBarState extends State<_CollapsedBar> with UsageViewAttachment {
  @override
  UsageController get usageController => widget.controller;

  @override
  Widget build(BuildContext context) {
    final summary = widget.controller.summary;
    final now = widget.now ?? DateTime.now();
    final palette = AppPalette.of(context);
    final five = summary.fiveHour?.effectivePct(now);
    final week = summary.weekly?.effectivePct(now);
    final hasReport = summary.machines.any((m) => m.report != null);
    final text = [
      '5h ${five == null ? '–' : '${five.round()}%'}',
      'wk ${week == null ? '–' : '${week.round()}%'}',
      if (hasReport) '${formatUsageCost(summary.today.costUsd)} today',
    ].join(' · ');
    return InkWell(
      onTap: () => unawaited(openUsageExplorer(context, widget.controller)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            UsageRing(percent: five, size: 16, showPercent: false),
            const SizedBox(width: 4),
            UsageRing(percent: week, size: 16, showPercent: false),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                key: const ValueKey('usage-collapsed-text'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: palette.foreground),
              ),
            ),
            if (summary.otherAccountCount > 0) ...[
              const SizedBox(width: 6),
              UsageAccountsChip(
                summary: summary,
                now: now,
                controller: widget.controller,
                dense: true,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The Usage tab's numbers: limits per machine, tokens and estimated cost
/// per day (bar chart) and by machine, project, model or agent, Codex
/// included when a machine has it.
class UsageBreakdown extends StatefulWidget {
  const UsageBreakdown({
    required this.controller,
    this.now,
    this.onUpdateCompanion,
    super.key,
  });

  final UsageController controller;
  final DateTime? now;

  /// Opens the agent hooks screen for a machine whose companion is too
  /// old; the note has no button without it.
  final void Function(String hostId)? onUpdateCompanion;

  @override
  State<UsageBreakdown> createState() => _UsageBreakdownState();
}

class _UsageBreakdownState extends State<UsageBreakdown>
    with UsageViewAttachment {
  UsageGrouping _grouping = UsageGrouping.project;

  @override
  UsageController get usageController => widget.controller;

  @override
  bool get refreshUsageOnOpen => true;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    final controller = widget.controller;
    final summary = controller.summary;
    final now = widget.now ?? DateTime.now();
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: palette.mutedForeground,
    );
    if (summary.machines.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text(
          'Usage comes from the Conductore companion (0.6 or newer) on '
          'machines monitored through it.',
          style: muted,
        ),
      );
    }
    final range = summary.range;
    final days = summary.days();
    final groups = summary.groupBy(_grouping);
    final hasReport = summary.machines.any((m) => m.report != null);
    final fetching = summary.machines.any(
      (m) => controller.isFetching(m.hostId),
    );
    final others = [
      for (final m in summary.machines)
        if (m.report case final r?
            when r.codex.present || r.opencode.present || r.gemini.present)
          m,
    ];
    return Column(
      key: const ValueKey('usage-breakdown'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                hasReport
                    ? 'Last ${days.isEmpty ? 7 : days.length} days: '
                          '${formatUsageTokens(range.tokens)} tokens · '
                          '${formatUsageCost(range.costUsd)}'
                    : controller.isLoading
                    ? 'Counting…'
                    : 'No token counts yet',
                style: theme.textTheme.titleSmall,
              ),
            ),
            if (fetching)
              const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              IconButton(
                tooltip: 'Refresh usage',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.refresh_rounded, size: 20),
                onPressed: controller.refresh,
              ),
            if (hasReport)
              TextButton(
                key: const ValueKey('usage-explore'),
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
                onPressed: () => unawaited(
                  openUsageExplorer(
                    context,
                    controller,
                    onUpdateCompanion: widget.onUpdateCompanion,
                  ),
                ),
                child: const Text('Explore'),
              ),
          ],
        ),
        for (final machine in summary.machines) ...[
          const SizedBox(height: 8),
          _MachineLimits(
            machine: machine,
            now: now,
            showName:
                summary.machines.length > 1 ||
                machine.needsUpdate ||
                machine.error != null,
            onUpdateCompanion: widget.onUpdateCompanion,
          ),
        ],
        if (summary.accounts.isNotEmpty) ...[
          const SizedBox(height: 8),
          UsageAccountsSection(
            controller: controller,
            now: now,
            foldable: true,
          ),
        ],
        if (others.isNotEmpty)
          UsageFold(
            id: 'agents',
            title: 'Other agents',
            summary: _otherAgentsLine(others, now),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final machine in others)
                  _OtherAgents(
                    machine: machine,
                    now: now,
                    showName: summary.machines.length > 1,
                  ),
              ],
            ),
          ),
        if (hasReport) ...[
          const SizedBox(height: 10),
          Text('Per day', style: theme.textTheme.labelLarge),
          const SizedBox(height: 6),
          UsageDayChart(
            days: days,
            onSelect: (day) => unawaited(
              openUsageExplorer(
                context,
                controller,
                day: day,
                onUpdateCompanion: widget.onUpdateCompanion,
              ),
            ),
          ),
          const SizedBox(height: 6),
          UsageFold(
            id: 'groups',
            title: 'By ${_grouping.label.toLowerCase()}',
            summary: groups.isEmpty
                ? null
                : 'top: ${groups.first.label} · '
                      '${formatUsageCost(groups.first.totals.costUsd)}',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SegmentedButton<UsageGrouping>(
                  key: const ValueKey('usage-grouping'),
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                  ),
                  segments: [
                    for (final grouping in UsageGrouping.values)
                      ButtonSegment(
                        value: grouping,
                        label: Text(grouping.label),
                      ),
                  ],
                  selected: {_grouping},
                  onSelectionChanged: (value) =>
                      setState(() => _grouping = value.first),
                ),
                const SizedBox(height: 8),
                if (groups.isEmpty)
                  Text('Nothing in this period.', style: muted)
                else
                  for (final group in groups.take(12))
                    _GroupRow(group: group, max: groups.first.totals),
                const SizedBox(height: 10),
                Text(
                  'Costs are estimates at public API list prices'
                  '${summary.pricingAsOf == null ? '' : ' (${summary.pricingAsOf})'}. '
                  'On a subscription plan this is the API-equivalent cost, '
                  'not what you pay.',
                  style: muted,
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  /// "Codex 40% · OpenCode · Gemini": each other agent once, Codex with
  /// its fullest window.
  static String _otherAgentsLine(List<MachineUsage> machines, DateTime now) {
    final codex = [for (final m in machines) ...m.codexLimits];
    final present = <String>{
      for (final m in machines)
        if (m.report case final report?) ...[
          if (report.codex.present) 'Codex',
          if (report.opencode.present) 'OpenCode',
          if (report.gemini.present) 'Gemini',
        ],
    };
    return [
      for (final name in present)
        if (name == 'Codex' && codex.isNotEmpty)
          'Codex ${codex.map((l) => l.effectivePct(now)).reduce(math.max).round()}%'
        else
          name,
    ].join(' · ');
  }
}

class _MachineLimits extends StatelessWidget {
  const _MachineLimits({
    required this.machine,
    required this.now,
    required this.showName,
    this.onUpdateCompanion,
  });

  final MachineUsage machine;
  final DateTime now;
  final bool showName;
  final void Function(String hostId)? onUpdateCompanion;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: palette.mutedForeground,
    );
    final report = machine.report;
    return Column(
      key: ValueKey('usage-machine-${machine.hostId}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showName)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(machine.hostName, style: theme.textTheme.labelLarge),
          ),
        if (machine.needsUpdate)
          Row(
            children: [
              Expanded(
                child: Text(
                  'The companion on this machine does not report usage '
                  'yet (it needs 0.6.0).',
                  style: muted,
                ),
              ),
              if (onUpdateCompanion case final update?)
                TextButton(
                  onPressed: () => update(machine.hostId),
                  child: const Text('Update agent hooks'),
                ),
            ],
          )
        else if (machine.error != null && report == null)
          Text('Could not read usage: ${machine.error}', style: muted),
        for (final limit in machine.claudeLimits)
          UsageLimitBar(agent: 'Claude', limit: limit, now: now),
        if (report != null && report.partial)
          Text('Still counting older transcripts…', style: muted),
      ],
    );
  }
}

/// One machine's Codex limits and login, OpenCode's model and Gemini's:
/// the Usage tab's "Other agents".
class _OtherAgents extends StatelessWidget {
  const _OtherAgents({
    required this.machine,
    required this.now,
    required this.showName,
  });

  final MachineUsage machine;
  final DateTime now;
  final bool showName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: palette.mutedForeground,
    );
    final report = machine.report;
    final codexPresent = report?.codex.present ?? false;
    return Column(
      key: ValueKey('usage-agents-${machine.hostId}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showName)
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 4),
            child: Text(machine.hostName, style: theme.textTheme.labelLarge),
          ),
        if (codexPresent)
          if (machine.codexLimits.isEmpty)
            Text('Codex: no rate limits reported yet', style: muted)
          else
            for (final limit in machine.codexLimits)
              UsageLimitBar(agent: 'Codex', limit: limit, now: now),
        // Codex shows its active login only (no switching).
        if (codexPresent)
          if (report!.codex.accounts.where((a) => a.active).firstOrNull
              case final account?)
            Text(
              'Codex account: ${account.label}'
              '${account.plan == null ? '' : ' · ${_planLabel(account.plan!)}'}',
              key: ValueKey('usage-codex-account-${machine.hostId}'),
              style: muted,
            ),
        // OpenCode has no plan limits: the model it runs on, and that its
        // cost is its own figure, not our estimate.
        if (report != null && report.opencode.present)
          Text(
            [
              'OpenCode: ${report.opencode.activeModel ?? 'no answers yet'}',
              if (report.opencode.costReported) 'cost as reported by OpenCode',
            ].join(' · '),
            key: ValueKey('usage-opencode-${machine.hostId}'),
            style: muted,
          ),
        // Gemini CLI: tokens only (no prices, no plan limits reported).
        if (report != null && report.gemini.present)
          Text(
            'Gemini CLI: ${report.gemini.activeModel ?? 'no answers yet'}'
            ' · tokens only, no cost estimate',
            key: ValueKey('usage-gemini-${machine.hostId}'),
            style: muted,
          ),
      ],
    );
  }
}

/// One limit window as a labelled bar with its reset time.
class UsageLimitBar extends StatelessWidget {
  const UsageLimitBar({
    required this.agent,
    required this.limit,
    required this.now,
    super.key,
  });

  final String agent;
  final UsageLimit limit;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    final pct = limit.effectivePct(now);
    final reset = limit.resetsAt;
    final reportedAt = limit.reportedAt;
    final resetText = [
      if (limit.expired || (reset != null && !reset.isAfter(now)))
        'reset'
      else if (reset != null)
        'resets ${_resetsIn(reset.difference(now))}',
      // How old the figure is: an idle session's report can be hours old.
      if (reportedAt != null) 'updated ${formatUsageAge(now, reportedAt)}',
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '$agent · ${limit.title}',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              const SizedBox(width: 8),
              // Wraps rather than overflows on a phone.
              Flexible(
                flex: 2,
                child: Text(
                  '${pct.round()}%${resetText.isEmpty ? '' : ' · $resetText'}',
                  textAlign: TextAlign.end,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: palette.mutedForeground,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 3),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: pct / 100,
              minHeight: 5,
              color: usageColor(pct, palette),
              backgroundColor: palette.hairline,
            ),
          ),
        ],
      ),
    );
  }

  static String _resetsIn(Duration delta) => formatResetsIn(delta);
}

/// `in 6d 13h`, `in 4h 39m`, `in 5m`.
String formatResetsIn(Duration delta) {
  if (delta.inHours >= 24) {
    return 'in ${delta.inDays}d ${delta.inHours % 24}h';
  }
  if (delta.inMinutes >= 60) {
    return 'in ${delta.inHours}h ${delta.inMinutes % 60}m';
  }
  return 'in ${math.max(1, delta.inMinutes)}m';
}

/// How long before [now] [at] was: `11h ago`, `just now`.
String formatUsageAge(DateTime now, DateTime at) => _ago(now.difference(at));

/// `11h ago`, `3d ago`, `just now`.
String _ago(Duration delta) {
  if (delta.inDays >= 1) {
    return '${delta.inDays}d ago';
  }
  if (delta.inHours >= 1) {
    return '${delta.inHours}h ago';
  }
  if (delta.inMinutes >= 1) {
    return '${delta.inMinutes}m ago';
  }
  return 'just now';
}

/// The breakdown's "Accounts" section (cswap): one pair of rings (5-hour,
/// week) per Claude account across machines, the active one marked,
/// disabled ones greyed, reset times, and "Switch" / "Switch to best" on
/// machines whose companion reports cswap.
class UsageAccountsSection extends StatelessWidget {
  const UsageAccountsSection({
    required this.controller,
    required this.now,
    this.foldable = false,
    super.key,
  });

  final UsageController controller;
  final DateTime now;

  /// Folded to one line ([UsageFold]) until tapped: the explorer and the
  /// Usage tab, where the summary leads.
  final bool foldable;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final summary = controller.summary;
    final accounts = summary.accounts;
    final switchable = [
      for (final machine in summary.machines)
        if (machine.canSwitchAccounts) machine,
    ];
    final switchBest = switchable.isNotEmpty && accounts.length > 1
        ? TextButton(
            key: const ValueKey('usage-switch-best'),
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            onPressed: () => switchUsageAccount(
              context,
              controller,
              machines: [for (final m in switchable) (m.hostId, m.hostName)],
            ),
            child: const Text('Switch to best'),
          )
        : null;
    final rows = [
      for (final account in accounts)
        _AccountRow(
          account: account,
          now: now,
          showMachines: summary.machines.length > 1,
          onSwitch: account.switchTargets.isEmpty
              ? null
              : () => switchUsageAccount(
                  context,
                  controller,
                  account: account,
                  machines: [
                    for (final p in account.switchTargets)
                      (p.hostId, p.hostName),
                  ],
                ),
        ),
    ];
    if (foldable) {
      return KeyedSubtree(
        key: const ValueKey('usage-accounts'),
        child: UsageFold(
          id: 'accounts',
          title: 'Accounts',
          summary: usageAccountsLine(summary, now),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (switchBest != null)
                Align(alignment: Alignment.centerRight, child: switchBest),
              ...rows,
            ],
          ),
        ),
      );
    }
    return Column(
      key: const ValueKey('usage-accounts'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('Accounts', style: theme.textTheme.labelLarge),
            ),
            ?switchBest,
          ],
        ),
        const SizedBox(height: 4),
        ...rows,
      ],
    );
  }
}

class _AccountRow extends StatelessWidget {
  const _AccountRow({
    required this.account,
    required this.now,
    required this.showMachines,
    this.onSwitch,
  });

  final UsageAccountSummary account;
  final DateTime now;
  final bool showMachines;
  final VoidCallback? onSwitch;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: palette.mutedForeground,
    );
    String? reset(String name, UsageLimit? limit) {
      final at = limit?.resetsAt;
      if (limit == null || at == null) {
        return null;
      }
      // A window that ended since it was measured shows 0 %: say so.
      if (limit.expired || !at.isAfter(now)) {
        return '$name reset';
      }
      return '$name ${formatResetsIn(at.difference(now))}';
    }

    final resets = [
      ?reset('5h', account.fiveHour),
      ?reset('week', account.weekly),
    ];
    final usageAt = account.usageAt;
    final notes = [
      if (account.needsLogin) 'Needs re-login',
      if (account.unmanaged) 'Current login',
      if (account.notInCswap) 'not in cswap (cswap add to switch)',
      if (account.live && !account.active) 'in use by sessions',
      if (account.active && showMachines)
        'active on ${account.activeOn.join(', ')}',
      if (account.disabled) 'disabled',
      // Every figure's age, not only cswap's stale ones.
      if (usageAt != null) 'updated ${formatUsageAge(now, usageAt)}',
      if (resets.isNotEmpty) 'resets ${resets.join(' · ')}',
    ];
    // Numbers cswap cannot refresh are greyed.
    final ringPair = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _LabeledRing(label: '5h', limit: account.fiveHour, now: now),
        const SizedBox(width: 8),
        _LabeledRing(label: 'Week', limit: account.weekly, now: now),
      ],
    );
    final rings = account.needsLogin
        ? Opacity(
            key: ValueKey('usage-account-greyed-${account.label}'),
            opacity: 0.4,
            child: ringPair,
          )
        : ringPair;
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          rings,
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        account.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: account.active
                              ? FontWeight.w700
                              : FontWeight.w500,
                        ),
                      ),
                    ),
                    if (account.active) ...[
                      const SizedBox(width: 6),
                      Container(
                        key: ValueKey('usage-account-active-${account.label}'),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 1,
                        ),
                        color: palette.accent.withValues(alpha: 0.18),
                        child: Text(
                          'active',
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                            color: palette.accent,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                if (notes.isNotEmpty)
                  Text(
                    notes.join(' · '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: muted,
                  ),
              ],
            ),
          ),
          if (onSwitch != null)
            TextButton(
              key: ValueKey('usage-account-switch-${account.label}'),
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              onPressed: onSwitch,
              child: const Text('Switch'),
            ),
        ],
      ),
    );
    return KeyedSubtree(
      key: ValueKey('usage-account-${account.label}'),
      child: account.disabled ? Opacity(opacity: 0.45, child: row) : row,
    );
  }
}

/// Asks to confirm, then switches the Claude account on the chosen machine
/// ([account], or cswap's best with none) and reports the outcome in a
/// snackbar. [machines] are (hostId, name) pairs whose companion reports
/// cswap.
Future<void> switchUsageAccount(
  BuildContext context,
  UsageController controller, {
  required List<(String, String)> machines,
  UsageAccountSummary? account,
}) async {
  if (machines.isEmpty) {
    return;
  }
  final hostId = await showDialog<String>(
    context: context,
    builder: (context) =>
        _AccountSwitchDialog(account: account?.label, machines: machines),
  );
  if (hostId == null || !context.mounted) {
    return;
  }
  final slot = account?.placements
      .where((p) => p.hostId == hostId)
      .firstOrNull
      ?.account
      .slot;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final result = await controller.switchAccount(
    hostId,
    slot: slot,
    best: account == null,
  );
  messenger?.showSnackBar(SnackBar(content: Text(result.message)));
}

class _AccountSwitchDialog extends StatelessWidget {
  const _AccountSwitchDialog({required this.account, required this.machines});

  /// Null: cswap's best.
  final String? account;
  final List<(String, String)> machines;

  @override
  Widget build(BuildContext context) {
    final one = machines.length == 1;
    final where = one ? machines.single.$2 : 'the machine you pick';
    final target = account == null
        ? 'the account with the most headroom'
        : account!;
    return AlertDialog(
      key: const ValueKey('usage-switch-confirm'),
      title: Text(
        account == null ? 'Switch to best account?' : 'Switch to $account?',
      ),
      content: Text(
        'This changes the Claude account for new Claude sessions on '
        '$where to $target (cswap switch). Sessions already running keep '
        'their account.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        for (final (hostId, name) in machines)
          FilledButton(
            key: ValueKey('usage-switch-confirm-$hostId'),
            onPressed: () => Navigator.of(context).pop(hostId),
            child: Text(one ? 'Switch' : 'Switch on $name'),
          ),
      ],
    );
  }
}

/// Tokens per day as flat bars, today last; the estimated cost under each.
/// A tap on a day calls [onSelect] (the explorer, open at that day).
class UsageDayChart extends StatelessWidget {
  const UsageDayChart({
    required this.days,
    this.height = 84,
    this.onSelect,
    super.key,
  });

  final List<UsageDay> days;
  final ValueChanged<String>? onSelect;

  /// Height of the tallest bar.
  final double height;

  static const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final max = days.fold<int>(0, (m, d) => math.max(m, d.totals.tokens));
    final label = TextStyle(
      fontSize: 10,
      height: 1.2,
      color: palette.mutedForeground,
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (final (index, day) in days.indexed)
          Expanded(
            child: Tooltip(
              message:
                  '${day.date}: ${formatUsageTokens(day.totals.tokens)} '
                  'tokens · ${formatUsageCost(day.totals.costUsd)}',
              child: InkWell(
                onTap: onSelect == null ? null : () => onSelect!(day.date),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        height: height,
                        child: Align(
                          alignment: Alignment.bottomCenter,
                          child: Container(
                            key: ValueKey('usage-day-${day.date}'),
                            height: max == 0 || day.totals.tokens == 0
                                ? 0
                                : math.max(2, height * day.totals.tokens / max),
                            color: index == days.length - 1
                                ? palette.accent
                                : palette.accent.withValues(alpha: 0.45),
                          ),
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(_weekday(day.date), style: label, maxLines: 1),
                      Text(
                        day.totals.costUsd == null || day.totals.tokens == 0
                            ? ''
                            : formatUsageCost(day.totals.costUsd),
                        style: label,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.clip,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  static String _weekday(String date) {
    final parsed = DateTime.tryParse(date);
    return parsed == null ? '' : _weekdays[parsed.weekday - 1];
  }
}

class _GroupRow extends StatelessWidget {
  const _GroupRow({required this.group, required this.max});

  final UsageGroup group;
  final UsageTotals max;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    final share = max.costUsd != null && max.costUsd! > 0
        ? (group.totals.costUsd ?? 0) / max.costUsd!
        : max.tokens == 0
        ? 0.0
        : group.totals.tokens / max.tokens;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  group.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              Text(
                '${formatUsageTokens(group.totals.tokens)} · '
                '${formatUsageCost(group.totals.costUsd)}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: palette.mutedForeground,
                ),
              ),
            ],
          ),
          const SizedBox(height: 3),
          Align(
            alignment: Alignment.centerLeft,
            child: FractionallySizedBox(
              widthFactor: share.clamp(0.0, 1.0),
              child: Container(
                height: 4,
                color: palette.accent.withValues(alpha: 0.7),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// `plus` -> `Plus`; an API key login has no plan.
String _planLabel(String plan) =>
    plan.isEmpty ? plan : plan[0].toUpperCase() + plan.substring(1);
