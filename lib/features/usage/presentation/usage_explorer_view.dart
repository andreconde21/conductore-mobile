import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:conduit/core/platform_features.dart';
import 'package:conduit/core/presentation/adaptive_modal.dart';
import 'package:conduit/core/presentation/adaptive_page.dart';
import 'package:conduit/core/telemetry/telemetry.dart';
import 'package:conduit/core/telemetry/telemetry_events.dart';
import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/features/sftp/data/file_picker_file_export.dart';
import 'package:conduit/features/sftp/domain/file_export.dart';
import 'package:conduit/features/usage/domain/usage_explorer.dart';
import 'package:conduit/features/usage/domain/usage_range.dart';
import 'package:conduit/features/usage/domain/usage_report.dart';
import 'package:conduit/features/usage/domain/usage_summary.dart';
import 'package:conduit/features/usage/presentation/usage_controller.dart';
import 'package:conduit/features/usage/presentation/usage_explorer_controller.dart';
import 'package:conduit/features/usage/presentation/usage_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// From this width the explorer lays out side by side: a wider chart,
/// breakdowns next to each other, the day's detail in a column.
const kUsageExplorerWideWidth = 900.0;

/// Opens the usage explorer (at [day] when given): in the desktop shell's
/// main area when the shell offers that ([UsageScope.openExplorer]), else
/// as a full-screen page.
Future<void> openUsageExplorer(
  BuildContext context,
  UsageController usage, {
  String? day,
  void Function(String hostId)? onUpdateCompanion,
}) async {
  final opener = UsageScope.scopeOf(context)?.openExplorer;
  if (opener != null) {
    opener(day: day);
    return;
  }
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (context) => UsageExplorerPage(
        usage: usage,
        initialDay: day,
        onUpdateCompanion: onUpdateCompanion,
      ),
    ),
  );
}

/// The usage explorer as a page of its own (phones).
class UsageExplorerPage extends StatelessWidget {
  const UsageExplorerPage({
    required this.usage,
    this.initialDay,
    this.onUpdateCompanion,
    this.fileExport,
    this.now,
    super.key,
  });

  final UsageController usage;
  final String? initialDay;
  final void Function(String hostId)? onUpdateCompanion;
  final FileExport? fileExport;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const ValueKey('usage-explorer-page'),
      appBar: AppBar(title: const Text('Usage')),
      body: SafeArea(
        top: false,
        child: UsageExplorerView(
          usage: usage,
          initialDay: initialDay,
          onUpdateCompanion: onUpdateCompanion,
          fileExport: fileExport,
          now: now,
        ),
      ),
    );
  }
}

/// Usage over a range: limit rings, the range and measure, the total with
/// its change from the period before and the average per day, filters, an
/// interactive day chart (a tap opens the day: hours, projects, models,
/// sessions, machines, accounts), breakdowns whose rows filter, and a CSV
/// export. Side by side from [kUsageExplorerWideWidth].
class UsageExplorerView extends StatefulWidget {
  const UsageExplorerView({
    required this.usage,
    this.initialDay,
    this.initialPreset,
    this.onUpdateCompanion,
    this.onClose,
    this.fileExport,
    this.firstWeekday,
    this.now,
    super.key,
  });

  final UsageController usage;

  /// A day to open in detail at once.
  final String? initialDay;

  /// The range to start on (the command palette's "Usage: 7 days").
  final UsageRangePreset? initialPreset;

  /// Opens the agent hooks screen for a machine whose companion is older.
  final void Function(String hostId)? onUpdateCompanion;

  /// A close button in the header (the desktop main area).
  final VoidCallback? onClose;

  /// Where the CSV goes (the platform's save dialog by default).
  final FileExport? fileExport;

  /// The weekday a week starts on; the device's region decides by default.
  final int? firstWeekday;

  /// For tests.
  final DateTime? now;

  @override
  State<UsageExplorerView> createState() => _UsageExplorerViewState();
}

class _UsageExplorerViewState extends State<UsageExplorerView>
    with UsageViewAttachment {
  late final UsageExplorerController _explorer;
  final _focus = FocusNode(debugLabel: 'usage-explorer');
  bool _isWide = false;

  @override
  UsageController get usageController => widget.usage;

  @override
  void initState() {
    super.initState();
    Telemetry.instance.track(const TelemetryEvent.usageExplorerOpened());
    _explorer = UsageExplorerController(
      usage: widget.usage,
      firstWeekday:
          widget.firstWeekday ??
          firstWeekdayFor(WidgetsBinding.instance.platformDispatcher.locale),
    )..start();
    if (widget.initialPreset case final preset?
        when preset != UsageRangePreset.custom) {
      _explorer.setPreset(preset);
    }
    if (widget.initialDay case final day?) {
      if (!_explorer.range.contains(day)) {
        _explorer.setPreset(UsageRangePreset.last30);
      }
      if (_explorer.range.contains(day) && !_explorer.range.isSingleDay) {
        _explorer.selectDay(day);
      }
    }
  }

  @override
  void dispose() {
    _explorer.dispose();
    _focus.dispose();
    super.dispose();
  }

  DateTime get _now => widget.now ?? DateTime.now();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([_explorer, widget.usage]),
      builder: (context, _) => LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= kUsageExplorerWideWidth;
          _isWide = wide;
          return CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
                  _explorer.stepDay(-1),
              const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
                  _explorer.stepDay(1),
              const SingleActivator(LogicalKeyboardKey.escape): () =>
                  _explorer.selectDay(null),
            },
            child: Focus(
              focusNode: _focus,
              autofocus: wide,
              child: wide ? _wide(context) : _narrow(context),
            ),
          );
        },
      ),
    );
  }

  // --- layouts ------------------------------------------------------------

  Widget _narrow(BuildContext context) {
    final explorer = _explorer;
    final single = explorer.range.isSingleDay;
    return RefreshIndicator(
      onRefresh: explorer.refresh,
      child: ListView(
        key: const ValueKey('usage-explorer'),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          ..._header(context, wide: false),
          const SizedBox(height: 12),
          if (single)
            _DayDetail(
              explorer: explorer,
              usage: widget.usage,
              onUpdateCompanion: widget.onUpdateCompanion,
              embedded: true,
            )
          else ...[
            _dayChart(context, height: 110),
            const SizedBox(height: 16),
            _BreakdownPicker(explorer: explorer),
          ],
          ..._notes(context),
        ],
      ),
    );
  }

  Widget _wide(BuildContext context) {
    final explorer = _explorer;
    final single = explorer.range.isSingleDay;
    final day = single ? null : explorer.selectedDay;
    final palette = AppPalette.of(context);
    final main = ListView(
      key: const ValueKey('usage-explorer'),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
      children: [
        ..._header(context, wide: true),
        const SizedBox(height: 16),
        if (single)
          _DayDetail(
            explorer: explorer,
            usage: widget.usage,
            onUpdateCompanion: widget.onUpdateCompanion,
            embedded: true,
            wide: true,
          )
        else ...[
          _dayChart(context, height: 180),
          const SizedBox(height: 20),
          _BreakdownGrid(
            key: const ValueKey('usage-explorer-grid'),
            explorer: explorer,
            slice: explorer.current,
            dimensions: const [
              UsageDimension.project,
              UsageDimension.model,
              UsageDimension.machine,
              UsageDimension.account,
              UsageDimension.agent,
            ],
          ),
        ],
        ..._notes(context),
      ],
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: main),
        if (day != null) ...[
          VerticalDivider(width: 1, color: palette.hairline),
          SizedBox(
            key: const ValueKey('usage-day-panel'),
            width: 420,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                _DayDetail(
                  explorer: explorer,
                  usage: widget.usage,
                  onUpdateCompanion: widget.onUpdateCompanion,
                  onClose: () => explorer.selectDay(null),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  // --- pieces -------------------------------------------------------------

  List<Widget> _header(BuildContext context, {required bool wide}) {
    final theme = Theme.of(context);
    final explorer = _explorer;
    return [
      Row(
        children: [
          Expanded(
            child: _LimitsRow(summary: widget.usage.summary, now: _now),
          ),
          if (explorer.refreshing)
            const Padding(
              padding: EdgeInsets.all(12),
              child: SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            IconButton(
              key: const ValueKey('usage-explorer-refresh'),
              tooltip: 'Refresh usage',
              icon: const Icon(Icons.refresh_rounded, size: 20),
              onPressed: () => unawaited(explorer.refresh()),
            ),
          IconButton(
            key: const ValueKey('usage-explorer-export'),
            tooltip: 'Export CSV',
            icon: const Icon(Icons.file_download_outlined, size: 20),
            onPressed: explorer.current.rows.isEmpty
                ? null
                : () => unawaited(_export(context)),
          ),
          if (widget.onClose case final close?)
            IconButton(
              key: const ValueKey('usage-explorer-close'),
              tooltip: 'Close usage',
              icon: const Icon(Icons.close_rounded, size: 20),
              onPressed: close,
            ),
        ],
      ),
      // cswap accounts, with Switch (the home bar's "+N accounts").
      if (widget.usage.summary.accounts.isNotEmpty) ...[
        const SizedBox(height: 10),
        UsageAccountsSection(controller: widget.usage, now: _now),
      ],
      const SizedBox(height: 10),
      _RangeChips(explorer: explorer, onCustom: () => _pickCustom(context)),
      const SizedBox(height: 12),
      _Headline(explorer: explorer, wide: wide),
      const SizedBox(height: 8),
      _FilterRow(explorer: explorer),
      if (explorer.loading)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text('Counting…', style: theme.textTheme.bodySmall),
        ),
    ];
  }

  Widget _dayChart(BuildContext context, {required double height}) {
    final explorer = _explorer;
    final range = explorer.range;
    final offset = [
      for (final r in explorer.results) ?r.report?.utcOffsetMinutes,
    ].firstOrNull;
    return UsageExplorerDayChart(
      key: const ValueKey('usage-explorer-chart'),
      days: explorer.current.days(range),
      today: widget.usage.today,
      metric: explorer.metric,
      split: explorer.split,
      selected: explorer.selectedDay,
      height: height,
      markers: range.shownDays.length <= 14
          ? usageWeeklyMarkers(
              widget.usage.summary.weekly,
              range,
              utcOffsetMinutes: offset ?? _now.timeZoneOffset.inMinutes,
              now: _now,
            )
          : const [],
      onSelect: (day) => _openDay(context, day),
    );
  }

  void _openDay(BuildContext context, String day) {
    final explorer = _explorer;
    if (_isWide) {
      explorer.selectDay(explorer.selectedDay == day ? null : day);
      _focus.requestFocus();
      return;
    }
    explorer.selectDay(day);
    // A narrow pane on desktop (a split, a small window): the day opens as
    // a dialog over the shell rather than a page covering it.
    unawaited(
      pushAdaptivePage<void>(
        context,
        desktopMaxWidth: 720,
        builder: (context) => _UsageDayPage(
          explorer: explorer,
          usage: widget.usage,
          onUpdateCompanion: widget.onUpdateCompanion,
        ),
      ).then((_) {
        if (mounted) {
          explorer.selectDay(null);
        }
      }),
    );
  }

  Future<void> _pickCustom(BuildContext context) async {
    final explorer = _explorer;
    final today = parseUsageDate(widget.usage.today)!;
    final current = explorer.custom ?? explorer.range;
    DateTime local(String date) {
      final d = parseUsageDate(date)!;
      return DateTime(d.year, d.month, d.day);
    }

    final first = DateTime(today.year, today.month, today.day - 61);
    final last = DateTime(today.year, today.month, today.day);
    DateTime clamp(DateTime d) =>
        d.isBefore(first) ? first : (d.isAfter(last) ? last : d);
    final picked = await showDateRangePicker(
      context: context,
      firstDate: first,
      lastDate: last,
      initialDateRange: DateTimeRange(
        start: clamp(local(current.from)),
        end: clamp(local(current.to)),
      ),
      helpText: 'Usage range',
      builder: useDesktopModals(context)
          ? (context, child) => Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: 440,
                  maxHeight: 640,
                ),
                child: child,
              ),
            )
          : null,
    );
    if (picked == null) {
      return;
    }
    explorer.setPreset(
      UsageRangePreset.custom,
      custom: UsageDateRange(
        formatUsageDate(picked.start),
        formatUsageDate(picked.end),
      ),
    );
  }

  Future<void> _export(BuildContext context) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final export = widget.fileExport ?? const FilePickerFileExport();
    try {
      final path = await export.save(
        _explorer.csvFileName,
        utf8.encode(_explorer.csv()),
      );
      if (path != null) {
        messenger?.showSnackBar(
          SnackBar(content: Text('Saved ${_explorer.csvFileName}')),
        );
      }
    } on Object catch (error) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Could not save the CSV: $error')),
      );
    }
  }

  List<Widget> _notes(BuildContext context) {
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: palette.mutedForeground,
    );
    final explorer = _explorer;
    final asOf = explorer.pricingAsOf;
    return [
      const SizedBox(height: 16),
      for (final name in explorer.needsUpdate)
        Text(
          '$name: the companion does not report usage yet (it needs 0.6.0).',
          style: muted,
        ),
      for (final (name, error) in explorer.errors)
        Text('$name: could not read usage: $error', style: muted),
      if (explorer.partial)
        Text('Still counting older transcripts…', style: muted),
      for (final name in explorer.rebuilding)
        Text(
          '$name: recounting after the companion update; hours and sessions '
          'follow in a minute or two.',
          style: muted,
        ),
      if (explorer.legacyHosts.isNotEmpty)
        _UpdateNote(
          hostIds: explorer.legacyHosts,
          usage: widget.usage,
          onUpdateCompanion: widget.onUpdateCompanion,
          text:
              'Older companion: daily numbers for the last 31 days only. '
              'Update agent hooks for hourly detail and longer ranges.',
        ),
      const SizedBox(height: 6),
      Text(
        'Costs are API-price estimates at public list prices'
        '${asOf == null ? '' : ' ($asOf)'}. On a subscription plan this is '
        'the API-equivalent cost, not what you pay.',
        style: muted,
      ),
    ];
  }
}

/// The 5-hour and weekly rings with when each resets.
class _LimitsRow extends StatelessWidget {
  const _LimitsRow({required this.summary, required this.now});

  final UsageSummary summary;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    Widget ring(String label, UsageLimit? limit) {
      final reset = limit?.resetsAt;
      final pct = limit?.effectivePct(now);
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          UsageRing(
            key: ValueKey('usage-explorer-ring-$label'),
            percent: pct,
            size: 38,
            semanticLabel: '$label limit',
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
              Text(
                reset == null
                    ? 'not reported'
                    : !reset.isAfter(now)
                    ? 'reset'
                    : 'resets ${formatResetsIn(reset.difference(now))}',
                style: TextStyle(
                  fontSize: 11.5,
                  color: palette.mutedForeground,
                ),
              ),
            ],
          ),
        ],
      );
    }

    return Wrap(
      spacing: 20,
      runSpacing: 8,
      children: [ring('5h', summary.fiveHour), ring('Week', summary.weekly)],
    );
  }
}

class _RangeChips extends StatelessWidget {
  const _RangeChips({required this.explorer, required this.onCustom});

  final UsageExplorerController explorer;
  final VoidCallback onCustom;

  @override
  Widget build(BuildContext context) {
    final range = explorer.range;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final preset in UsageRangePreset.values)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ChoiceChip(
                key: ValueKey('usage-range-${preset.name}'),
                visualDensity: VisualDensity.compact,
                label: Text(
                  preset == UsageRangePreset.custom &&
                          explorer.preset == UsageRangePreset.custom
                      ? formatUsageRange(range)
                      : preset == UsageRangePreset.custom
                      ? 'Custom…'
                      : preset.label,
                ),
                selected: explorer.preset == preset,
                onSelected: (_) => preset == UsageRangePreset.custom
                    ? onCustom()
                    : explorer.setPreset(preset),
              ),
            ),
        ],
      ),
    );
  }
}

/// The range's total in the chosen measure, its change from the period
/// before, the average per day, and the input/output/cache split.
class _Headline extends StatelessWidget {
  const _Headline({required this.explorer, required this.wide});

  final UsageExplorerController explorer;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: palette.mutedForeground,
    );
    final metric = explorer.metric;
    final total = explorer.current.total;
    final comparison = explorer.comparison;
    final range = explorer.range;
    final controls = Wrap(
      spacing: 8,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SegmentedButton<UsageMetric>(
          key: const ValueKey('usage-metric'),
          showSelectedIcon: false,
          style: const ButtonStyle(visualDensity: VisualDensity.compact),
          segments: [
            for (final m in UsageMetric.values)
              ButtonSegment(value: m, label: Text(m.label)),
          ],
          selected: {metric},
          onSelectionChanged: (value) => explorer.setMetric(value.first),
        ),
        FilterChip(
          key: const ValueKey('usage-split'),
          visualDensity: VisualDensity.compact,
          label: const Text('Split'),
          tooltip: 'Input, output and cache apart',
          selected: explorer.split,
          onSelected: explorer.setSplit,
        ),
      ],
    );
    final numbers = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${formatUsageRange(range)}'
          '${range.length > 1 ? ' · ${range.length} days' : ''}',
          style: muted,
        ),
        const SizedBox(height: 2),
        Text(
          formatUsageMetric(total, metric),
          key: const ValueKey('usage-explorer-total'),
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        if (metric == UsageMetric.cost)
          Text(
            'API-price estimate',
            key: const ValueKey('usage-explorer-estimate'),
            style: muted,
          )
        else
          Text('${formatUsageCost(total.costUsd)} at API prices', style: muted),
        const SizedBox(height: 4),
        Wrap(
          spacing: 14,
          children: [
            Text(
              comparison == null
                  ? 'vs previous period: not enough history'
                  : 'vs previous period ${comparison.label}',
              key: const ValueKey('usage-explorer-delta'),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: comparison == null
                    ? palette.mutedForeground
                    : palette.foreground,
              ),
            ),
            if (range.length > 1)
              Text(
                'avg ${formatUsageMetricValue(explorer.averagePerDay, metric)}'
                '/day',
                key: const ValueKey('usage-explorer-average'),
                style: theme.textTheme.bodyMedium,
              ),
          ],
        ),
        if (explorer.split) ...[
          const SizedBox(height: 6),
          _SplitLegend(totals: total),
        ],
      ],
    );
    if (wide) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: numbers),
          controls,
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [numbers, const SizedBox(height: 8), controls],
    );
  }
}

/// The token kinds, in stacking order (bottom first).
List<(String, int Function(UsageTotals), Color)> _splitParts(
  AppPalette palette,
) => [
  ('Input', (t) => t.input, palette.accent),
  ('Output', (t) => t.output, palette.success),
  ('Cache write', (t) => t.cacheWrite, palette.attention),
  ('Cache read', (t) => t.cacheRead, palette.subtleForeground),
];

class _SplitLegend extends StatelessWidget {
  const _SplitLegend({required this.totals});

  final UsageTotals totals;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Wrap(
      key: const ValueKey('usage-split-legend'),
      spacing: 12,
      runSpacing: 4,
      children: [
        for (final (label, value, color) in _splitParts(palette))
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(width: 10, height: 10, color: color),
              const SizedBox(width: 5),
              Text(
                '$label ${formatUsageTokens(value(totals))}',
                style: TextStyle(fontSize: 12, color: palette.foreground),
              ),
            ],
          ),
      ],
    );
  }
}

/// The filter chips (each removable) and "Filter" to add some.
class _FilterRow extends StatelessWidget {
  const _FilterRow({required this.explorer});

  final UsageExplorerController explorer;

  @override
  Widget build(BuildContext context) {
    final chips = explorer.filter.chips;
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final (dimension, value) in chips)
          InputChip(
            key: ValueKey('usage-filter-${dimension.name}-$value'),
            visualDensity: VisualDensity.compact,
            label: Text('${dimension.label}: $value'),
            onDeleted: () => explorer.toggleFilter(dimension, value),
          ),
        ActionChip(
          key: const ValueKey('usage-filter-add'),
          visualDensity: VisualDensity.compact,
          avatar: const Icon(Icons.filter_list_rounded, size: 16),
          label: const Text('Filter'),
          onPressed: () => unawaited(_pick(context)),
        ),
        if (chips.length > 1)
          TextButton(
            onPressed: explorer.clearFilter,
            child: const Text('Clear'),
          ),
      ],
    );
  }

  Future<void> _pick(BuildContext context) => showAdaptiveModal<void>(
    context: context,
    kind: AdaptiveModalKind.dialog,
    isScrollControlled: true,
    useSafeArea: true,
    desktopMaxWidth: 520,
    builder: (context) => ListenableBuilder(
      listenable: explorer,
      builder: (context, _) {
        final all = explorer.unfiltered;
        final theme = Theme.of(context);
        return ListView(
          key: const ValueKey('usage-filter-picker'),
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: [
            Text('Filter usage', style: theme.textTheme.titleMedium),
            for (final dimension in const [
              UsageDimension.machine,
              UsageDimension.account,
              UsageDimension.project,
              UsageDimension.model,
              UsageDimension.agent,
            ])
              if (all.valuesOf(dimension) case final values
                  when values.length > 1 ||
                      (explorer.filter.values[dimension]?.isNotEmpty ??
                          false)) ...[
                const SizedBox(height: 12),
                Text(dimension.plural, style: theme.textTheme.labelLarge),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final value in values)
                      FilterChip(
                        key: ValueKey(
                          'usage-filter-option-${dimension.name}-$value',
                        ),
                        visualDensity: VisualDensity.compact,
                        label: Text(value),
                        selected: explorer.filter.has(dimension, value),
                        onSelected: (_) =>
                            explorer.toggleFilter(dimension, value),
                      ),
                  ],
                ),
              ],
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Done'),
              ),
            ),
          ],
        );
      },
    ),
  );
}

/// Tokens (or cost) per day as bars, the selected day highlighted; a tap
/// or click on a day opens it ([onSelect]); hovering shows its numbers.
/// Days after [today] are empty. [markers] draw the weekly window's
/// boundaries.
class UsageExplorerDayChart extends StatelessWidget {
  const UsageExplorerDayChart({
    required this.days,
    required this.today,
    required this.metric,
    required this.onSelect,
    this.split = false,
    this.selected,
    this.markers = const [],
    this.height = 110,
    super.key,
  });

  final List<UsageDay> days;
  final String today;
  final UsageMetric metric;
  final bool split;
  final String? selected;
  final List<UsageChartMarker> markers;
  final double height;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final stacked = split && metric == UsageMetric.tokens;
    final max = days.fold<double>(
      0,
      (m, d) => math.max(m, usageMetricValue(d.totals, metric)),
    );
    final n = days.length;
    final label = TextStyle(
      fontSize: 10,
      height: 1.2,
      color: palette.mutedForeground,
    );
    // Every day labelled up to two weeks, then every few.
    final every = n <= 14 ? 1 : (n / 7).ceil();
    final bars = Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (final (index, day) in days.indexed)
          Expanded(
            child: _DayBar(
              day: day,
              value: usageMetricValue(day.totals, metric),
              max: max,
              height: height,
              metric: metric,
              stacked: stacked,
              future: day.date.compareTo(today) > 0,
              selected: day.date == selected,
              dimmed: selected != null && day.date != selected,
              label: index % every == 0
                  ? (n <= 7
                        ? usageWeekday(day.date)
                        : '${parseUsageDate(day.date)?.day ?? ''}')
                  : '',
              valueLabel: n <= 7 && day.totals.tokens > 0
                  ? formatUsageMetricValue(
                      usageMetricValue(day.totals, metric),
                      metric,
                    )
                  : '',
              labelStyle: label,
              onTap: day.date.compareTo(today) > 0
                  ? null
                  : () => onSelect(day.date),
            ),
          ),
      ],
    );
    if (markers.isEmpty || n == 0) {
      return bars;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            return Stack(
              clipBehavior: Clip.none,
              children: [
                bars,
                for (final marker in markers)
                  if (days.indexWhere((d) => d.date == marker.date)
                      case final index when index >= 0)
                    Positioned(
                      key: ValueKey(
                        'usage-weekly-marker-${marker.upcoming ? 'reset' : 'start'}',
                      ),
                      left: (index + marker.fraction) / n * width - 1,
                      top: 0,
                      height: height,
                      child: Tooltip(
                        message: marker.label,
                        child: Container(
                          width: 2,
                          color: marker.upcoming
                              ? palette.warning
                              : palette.mutedForeground,
                        ),
                      ),
                    ),
              ],
            );
          },
        ),
        const SizedBox(height: 4),
        for (final marker in markers)
          Row(
            children: [
              Container(
                width: 10,
                height: 2,
                color: marker.upcoming
                    ? palette.warning
                    : palette.mutedForeground,
              ),
              const SizedBox(width: 6),
              Text(
                marker.label,
                style: TextStyle(fontSize: 11.5, color: palette.foreground),
              ),
            ],
          ),
      ],
    );
  }
}

class _DayBar extends StatelessWidget {
  const _DayBar({
    required this.day,
    required this.value,
    required this.max,
    required this.height,
    required this.metric,
    required this.stacked,
    required this.future,
    required this.selected,
    required this.dimmed,
    required this.label,
    required this.valueLabel,
    required this.labelStyle,
    required this.onTap,
  });

  final UsageDay day;
  final double value;
  final double max;
  final double height;
  final UsageMetric metric;
  final bool stacked;
  final bool future;
  final bool selected;
  final bool dimmed;
  final String label;
  final String valueLabel;
  final TextStyle labelStyle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final barHeight = max <= 0 || value <= 0
        ? 0.0
        : math.max(2.0, height * value / max);
    final alpha = selected ? 1.0 : (dimmed ? 0.35 : 0.7);
    Widget bar;
    if (stacked && barHeight > 0) {
      final total = day.totals.tokens;
      bar = Column(
        mainAxisSize: MainAxisSize.min,
        verticalDirection: VerticalDirection.up,
        children: [
          for (final (_, part, color) in _splitParts(palette))
            if (part(day.totals) > 0)
              Container(
                height: barHeight * part(day.totals) / total,
                color: color.withValues(alpha: alpha),
              ),
        ],
      );
    } else {
      bar = Container(
        height: barHeight,
        color: palette.accent.withValues(alpha: alpha),
      );
    }
    final totals = day.totals;
    final tooltip = future
        ? '${formatUsageDay(day.date)}: not yet'
        : '${formatUsageDay(day.date)}\n'
              '${formatUsageTokens(totals.tokens)} tokens · '
              '${formatUsageCost(totals.costUsd)} (API-price estimate)\n'
              'in ${formatUsageTokens(totals.input)} · '
              'out ${formatUsageTokens(totals.output)} · '
              'cache ${formatUsageTokens(totals.cacheWrite + totals.cacheRead)}';
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 150),
      child: Semantics(
        button: onTap != null,
        selected: selected,
        label: tooltip,
        child: InkWell(
          key: ValueKey('usage-explorer-day-${day.date}'),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 1),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  height: height,
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        border: selected
                            ? Border(
                                bottom: BorderSide(
                                  color: palette.foreground,
                                  width: 2,
                                ),
                              )
                            : null,
                      ),
                      child: SizedBox(width: double.infinity, child: bar),
                    ),
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  label,
                  style: labelStyle.copyWith(
                    fontWeight: selected ? FontWeight.w700 : null,
                    color: selected
                        ? palette.foreground
                        : future
                        ? palette.subtleForeground
                        : null,
                  ),
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.clip,
                ),
                if (valueLabel.isNotEmpty || label.isNotEmpty)
                  Text(
                    valueLabel,
                    style: labelStyle,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.clip,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A day's 24 hours as bars (tokens or cost), hovering or pressing one
/// shows its numbers.
class UsageHourChart extends StatelessWidget {
  const UsageHourChart({
    required this.hours,
    required this.metric,
    this.height = 80,
    super.key,
  });

  final List<UsageTotals> hours;
  final UsageMetric metric;
  final double height;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final max = hours.fold<double>(
      0,
      (m, h) => math.max(m, usageMetricValue(h, metric)),
    );
    final label = TextStyle(fontSize: 10, color: palette.mutedForeground);
    return Column(
      key: const ValueKey('usage-hour-chart'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: height,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final (hour, totals) in hours.indexed)
                Expanded(
                  child: Tooltip(
                    message:
                        '${hour.toString().padLeft(2, '0')}:00–'
                        '${hour.toString().padLeft(2, '0')}:59\n'
                        '${formatUsageTokens(totals.tokens)} tokens · '
                        '${formatUsageCost(totals.costUsd)}',
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 1),
                      child: Align(
                        alignment: Alignment.bottomCenter,
                        child: Container(
                          key: ValueKey('usage-hour-$hour'),
                          height:
                              max <= 0 || usageMetricValue(totals, metric) <= 0
                              ? 0
                              : math.max(
                                  2,
                                  height *
                                      usageMetricValue(totals, metric) /
                                      max,
                                ),
                          color: palette.accent.withValues(alpha: 0.75),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 3),
        Row(
          children: [
            for (final hour in const [0, 6, 12, 18])
              Expanded(
                child: Text(
                  '${hour.toString().padLeft(2, '0')}h',
                  style: label,
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// One day: its total, hours, and what it went to.
class _DayDetail extends StatelessWidget {
  const _DayDetail({
    required this.explorer,
    required this.usage,
    this.onUpdateCompanion,
    this.onClose,
    this.embedded = false,
    this.wide = false,
  });

  final UsageExplorerController explorer;
  final UsageController usage;
  final void Function(String hostId)? onUpdateCompanion;
  final VoidCallback? onClose;

  /// Inside the explorer's own list (a one-day range): no title bar.
  final bool embedded;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: palette.mutedForeground,
    );
    final day = explorer.detailDay;
    if (day == null) {
      return const SizedBox.shrink();
    }
    final slice = explorer.daySlice;
    final sessions = explorer.daySessions;
    final metric = explorer.metric;
    final withoutHours = explorer.dayWithoutHours;
    final names = _sessionNames(usage);
    final header = Row(
      children: [
        IconButton(
          key: const ValueKey('usage-day-previous'),
          tooltip: 'Previous day',
          icon: const Icon(Icons.chevron_left_rounded),
          onPressed: explorer.canStep(-1) ? () => explorer.stepDay(-1) : null,
        ),
        Expanded(
          child: Text(
            formatUsageDay(day),
            key: const ValueKey('usage-day-title'),
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium,
          ),
        ),
        IconButton(
          key: const ValueKey('usage-day-next'),
          tooltip: 'Next day',
          icon: const Icon(Icons.chevron_right_rounded),
          onPressed: explorer.canStep(1) ? () => explorer.stepDay(1) : null,
        ),
        if (onClose case final close?)
          IconButton(
            key: const ValueKey('usage-day-close'),
            tooltip: 'Close the day',
            icon: const Icon(Icons.close_rounded, size: 20),
            onPressed: close,
          ),
      ],
    );
    return Column(
      key: ValueKey('usage-day-detail-$day'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        if (!embedded) ...[
          Text(
            formatUsageMetric(slice.total, metric),
            key: const ValueKey('usage-day-total'),
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          Text(
            metric == UsageMetric.cost
                ? 'API-price estimate'
                : '${formatUsageCost(slice.total.costUsd)} at API prices',
            style: muted,
          ),
        ],
        const SizedBox(height: 10),
        Text('By hour', style: theme.textTheme.labelLarge),
        const SizedBox(height: 6),
        if (explorer.dayLoading)
          Text('Loading the hours…', style: muted)
        else if (explorer.dayHasHours)
          UsageHourChart(
            hours: slice.hours(day),
            metric: metric,
            height: wide ? 120 : 80,
          ),
        if (withoutHours.isNotEmpty)
          _UpdateNote(
            hostIds: withoutHours,
            usage: usage,
            onUpdateCompanion: onUpdateCompanion,
            text: explorer.dayHasHours
                ? 'Some machines have an older companion: their use is '
                      'not in the hours. Update agent hooks for hourly '
                      'detail.'
                : 'Update agent hooks for hourly detail.',
          ),
        const SizedBox(height: 14),
        if (wide)
          _BreakdownGrid(
            explorer: explorer,
            slice: slice,
            sessions: sessions,
            sessionNames: names,
            dimensions: const [
              UsageDimension.project,
              UsageDimension.model,
              UsageDimension.session,
              UsageDimension.machine,
              UsageDimension.account,
              UsageDimension.agent,
            ],
          )
        else
          for (final dimension in const [
            UsageDimension.project,
            UsageDimension.model,
            UsageDimension.session,
            UsageDimension.machine,
            UsageDimension.account,
            UsageDimension.agent,
          ])
            _BreakdownSection(
              explorer: explorer,
              slice: dimension == UsageDimension.session ? sessions : slice,
              dimension: dimension,
              sessionNames: names,
            ),
      ],
    );
  }
}

/// Live session names by the first 8 characters of their id.
Map<String, String> _sessionNames(UsageController usage) => {
  for (final machine in usage.summary.machines)
    if (machine.report case final report?)
      for (final session in report.claude.sessions)
        if (session.sessionId.length >= 8)
          session.sessionId.substring(0, 8):
              session.name ?? session.project ?? '',
};

/// A day in detail on its own page (phones): swipe or the arrows step to
/// the day before or after.
class _UsageDayPage extends StatelessWidget {
  const _UsageDayPage({
    required this.explorer,
    required this.usage,
    this.onUpdateCompanion,
  });

  final UsageExplorerController explorer;
  final UsageController usage;
  final void Function(String hostId)? onUpdateCompanion;

  @override
  Widget build(BuildContext context) {
    final page = Scaffold(
      key: const ValueKey('usage-day-page'),
      appBar: AppBar(title: const Text('Usage by day')),
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragEnd: (details) {
          final v = details.primaryVelocity ?? 0;
          if (v.abs() < 250) {
            return;
          }
          explorer.stepDay(v > 0 ? -1 : 1);
        },
        child: ListenableBuilder(
          listenable: explorer,
          builder: (context, _) => ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              _FilterRow(explorer: explorer),
              const SizedBox(height: 8),
              _DayDetail(
                explorer: explorer,
                usage: usage,
                onUpdateCompanion: onUpdateCompanion,
              ),
            ],
          ),
        ),
      ),
    );
    if (!PlatformFeatures.isDesktop) return page;
    // Desktop: the arrow keys step the day like the swipe (Esc closes the
    // page on its own).
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
            explorer.stepDay(-1),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
            explorer.stepDay(1),
      },
      child: Focus(autofocus: true, child: page),
    );
  }
}

/// Phones: one breakdown at a time, picked by chip.
class _BreakdownPicker extends StatefulWidget {
  const _BreakdownPicker({required this.explorer});

  final UsageExplorerController explorer;

  @override
  State<_BreakdownPicker> createState() => _BreakdownPickerState();
}

class _BreakdownPickerState extends State<_BreakdownPicker> {
  UsageDimension _dimension = UsageDimension.project;

  @override
  Widget build(BuildContext context) {
    final slice = widget.explorer.current;
    final dimensions = [
      for (final d in const [
        UsageDimension.project,
        UsageDimension.model,
        UsageDimension.machine,
        UsageDimension.account,
        UsageDimension.agent,
      ])
        if (d == UsageDimension.project ||
            d == UsageDimension.model ||
            _showsDimension(slice, d))
          d,
    ];
    final dimension = dimensions.contains(_dimension)
        ? _dimension
        : UsageDimension.project;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 6,
          children: [
            for (final d in dimensions)
              ChoiceChip(
                key: ValueKey('usage-breakdown-${d.name}'),
                visualDensity: VisualDensity.compact,
                label: Text(d.label),
                selected: d == dimension,
                onSelected: (_) => setState(() => _dimension = d),
              ),
          ],
        ),
        const SizedBox(height: 8),
        _BreakdownSection(
          explorer: widget.explorer,
          slice: slice,
          dimension: dimension,
          showTitle: false,
          limit: 12,
        ),
      ],
    );
  }
}

/// Whether [dimension] says anything in [slice]: more than one value, or
/// one account that is a real one.
bool _showsDimension(UsageSlice slice, UsageDimension dimension) {
  final values = slice.valuesOf(dimension);
  return switch (dimension) {
    UsageDimension.account => values.any((v) => v != kUsageNoAccount),
    UsageDimension.machine || UsageDimension.agent => values.length > 1,
    _ => values.isNotEmpty,
  };
}

/// Desktop: breakdowns next to each other.
class _BreakdownGrid extends StatelessWidget {
  const _BreakdownGrid({
    required this.explorer,
    required this.slice,
    required this.dimensions,
    this.sessions,
    this.sessionNames = const {},
    super.key,
  });

  final UsageExplorerController explorer;
  final UsageSlice slice;
  final UsageSlice? sessions;
  final Map<String, String> sessionNames;
  final List<UsageDimension> dimensions;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = math.max(1, (constraints.maxWidth / 300).floor());
        final width = (constraints.maxWidth - (columns - 1) * 16) / columns;
        return Wrap(
          spacing: 16,
          runSpacing: 16,
          children: [
            for (final dimension in dimensions)
              if (dimension == UsageDimension.project ||
                  dimension == UsageDimension.model ||
                  (dimension == UsageDimension.session
                      ? (sessions?.rows.isNotEmpty ?? false)
                      : _showsDimension(slice, dimension)))
                Container(
                  width: width,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    border: Border.all(color: palette.hairline),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: _BreakdownSection(
                    explorer: explorer,
                    slice: dimension == UsageDimension.session
                        ? sessions!
                        : slice,
                    dimension: dimension,
                    sessionNames: sessionNames,
                    alwaysShow: true,
                  ),
                ),
          ],
        );
      },
    );
  }
}

/// One breakdown: rows by [dimension], largest first; a tap on a row
/// filters the whole explorer by it (sessions excepted).
class _BreakdownSection extends StatelessWidget {
  const _BreakdownSection({
    required this.explorer,
    required this.slice,
    required this.dimension,
    this.sessionNames = const {},
    this.showTitle = true,
    this.alwaysShow = false,
    this.limit = 6,
  });

  final UsageExplorerController explorer;
  final UsageSlice slice;
  final UsageDimension dimension;
  final Map<String, String> sessionNames;
  final bool showTitle;
  final bool alwaysShow;
  final int limit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    final metric = explorer.metric;
    if (!alwaysShow &&
        showTitle &&
        dimension != UsageDimension.project &&
        dimension != UsageDimension.model &&
        !(dimension == UsageDimension.session
            ? slice.rows.isNotEmpty
            : _showsDimension(slice, dimension))) {
      return const SizedBox.shrink();
    }
    final groups = slice.groupBy(dimension, metric: metric);
    final max = groups.isEmpty
        ? 0.0
        : usageMetricValue(groups.first.totals, metric);
    final shown = groups.take(limit).toList();
    return Padding(
      key: ValueKey('usage-section-${dimension.name}'),
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (showTitle)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                dimension == UsageDimension.account
                    ? 'Accounts (as seen active)'
                    : dimension.plural,
                style: theme.textTheme.labelLarge,
              ),
            ),
          if (groups.isEmpty)
            Text(
              'Nothing here.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: palette.mutedForeground,
              ),
            ),
          for (final group in shown)
            _GroupTile(
              group: group,
              label: _label(group.label),
              metric: metric,
              share: max <= 0
                  ? 0
                  : usageMetricValue(group.totals, metric) / max,
              active: explorer.filter.has(dimension, group.label),
              onTap: dimension.filterable
                  ? () => explorer.toggleFilter(dimension, group.label)
                  : null,
              tileKey: ValueKey('usage-row-${dimension.name}-${group.label}'),
            ),
          if (groups.length > shown.length)
            Text(
              '+${groups.length - shown.length} more',
              style: theme.textTheme.bodySmall?.copyWith(
                color: palette.mutedForeground,
              ),
            ),
        ],
      ),
    );
  }

  String _label(String value) {
    if (dimension != UsageDimension.session) {
      return value;
    }
    final name = sessionNames[value];
    final project = slice.rows
        .where((r) => r.session == value)
        .map((r) => r.project)
        .firstOrNull;
    return [
      if (name != null && name.isNotEmpty) name else ?project,
      value,
    ].join(' · ');
  }
}

class _GroupTile extends StatelessWidget {
  const _GroupTile({
    required this.group,
    required this.label,
    required this.metric,
    required this.share,
    required this.active,
    required this.onTap,
    required this.tileKey,
  });

  final UsageGroup group;
  final String label;
  final UsageMetric metric;
  final double share;
  final bool active;
  final VoidCallback? onTap;
  final Key tileKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    final other = metric == UsageMetric.cost
        ? '${formatUsageTokens(group.totals.tokens)} tok'
        : formatUsageCost(group.totals.costUsd);
    return InkWell(
      key: tileKey,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                if (active)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Icon(
                      Icons.filter_alt_rounded,
                      size: 14,
                      color: palette.accent,
                    ),
                  ),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: active ? FontWeight.w700 : null,
                    ),
                  ),
                ),
                Text(
                  '${formatUsageMetricValue(usageMetricValue(group.totals, metric), metric)}'
                  ' · $other',
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
      ),
    );
  }
}

/// A note about machines with an older companion, with "Update agent
/// hooks" when the caller can open that.
class _UpdateNote extends StatelessWidget {
  const _UpdateNote({
    required this.hostIds,
    required this.usage,
    required this.text,
    this.onUpdateCompanion,
  });

  final List<String> hostIds;
  final UsageController usage;
  final String text;
  final void Function(String hostId)? onUpdateCompanion;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    final names = [for (final id in hostIds) usage.hostFor(id)?.name ?? id];
    return Padding(
      key: const ValueKey('usage-update-note'),
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '${names.join(', ')}: $text',
              style: theme.textTheme.bodySmall?.copyWith(
                color: palette.mutedForeground,
              ),
            ),
          ),
          if (onUpdateCompanion case final update?)
            TextButton(
              onPressed: () => update(hostIds.first),
              child: const Text('Update agent hooks'),
            ),
        ],
      ),
    );
  }
}
