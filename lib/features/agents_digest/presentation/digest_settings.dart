import 'dart:async';

import 'package:conduit/core/presentation/theme_sheet.dart';
import 'package:conduit/features/agent_attention/presentation/widgets/agent_inbox_widgets.dart';
import 'package:conduit/features/agents_digest/data/digest_preferences.dart';
import 'package:conduit/features/agents_digest/presentation/digest_controller.dart';
import 'package:flutter/material.dart';

/// Settings › Agents › Dashboard: summaries on or off, the always-on
/// "only changed agents" rule, the stuck thresholds, and what summaries
/// cost today.
class DigestSettingsCards extends StatelessWidget {
  const DigestSettingsCards({required this.controller, super.key});

  final DigestController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final preferences = controller.preferences;
        final thresholds = preferences.thresholds;
        final today = controller.summaryUsageToday;
        const defaults = DigestThresholds.defaults;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SettingsSwitchCard(
              key: const ValueKey('settings-digest-summaries'),
              switchKey: const ValueKey('settings-digest-summaries-switch'),
              icon: Icons.auto_awesome_outlined,
              title: 'Summaries by an agent',
              subtitle:
                  'A one- or two-sentence summary per agent, written by a '
                  'coding agent on the machine (Claude Haiku, Codex or '
                  'OpenCode, whichever is installed) when you open the '
                  'dashboard. Off: facts only, no model cost.',
              value: preferences.summariesEnabled,
              onChanged: (value) =>
                  unawaited(controller.setSummariesEnabled(value)),
            ),
            const SizedBox(height: 8),
            SettingsCard(
              child: ListTile(
                key: const ValueKey('settings-digest-only-changed'),
                leading: const Icon(Icons.filter_alt_outlined),
                title: const Text('Only for agents that changed'),
                subtitle: Text(
                  'Always on. An agent is summarised again only when it did '
                  'something since its last summary; the others keep their '
                  'text, and nothing runs in the background.',
                  style: muted,
                ),
                trailing: const Icon(Icons.lock_outline_rounded, size: 18),
              ),
            ),
            const SizedBox(height: 8),
            SettingsCard(
              child: Column(
                children: [
                  _ThresholdTile(
                    key: const ValueKey('settings-digest-working'),
                    title: 'Working without edits',
                    unit: 'min',
                    value: thresholds.workingMinutes,
                    fallback: defaults.workingMinutes,
                    options: const [15, 30, 60, 120],
                    onChanged: (v) => controller.setThresholds(
                      _copy(thresholds, workingMinutes: v),
                    ),
                  ),
                  _ThresholdTile(
                    key: const ValueKey('settings-digest-failures'),
                    title: 'Same failure',
                    unit: 'times',
                    value: thresholds.sameFailures,
                    fallback: defaults.sameFailures,
                    options: const [2, 3, 5, 10],
                    onChanged: (v) => controller.setThresholds(
                      _copy(thresholds, sameFailures: v),
                    ),
                  ),
                  _ThresholdTile(
                    key: const ValueKey('settings-digest-repeats'),
                    title: 'Same command',
                    unit: 'times',
                    value: thresholds.sameCommands,
                    fallback: defaults.sameCommands,
                    options: const [3, 5, 10, 20],
                    onChanged: (v) => controller.setThresholds(
                      _copy(thresholds, sameCommands: v),
                    ),
                  ),
                  _ThresholdTile(
                    key: const ValueKey('settings-digest-approval'),
                    title: 'Approval waiting',
                    unit: 'min',
                    value: thresholds.approvalMinutes,
                    fallback: defaults.approvalMinutes,
                    options: const [15, 30, 60, 120],
                    onChanged: (v) => controller.setThresholds(
                      _copy(thresholds, approvalMinutes: v),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              today.tokens == 0
                  ? 'Summaries today: none yet.'
                  : 'Summaries today: ${compactTokens(today.tokens)} tokens'
                        '${today.costUsd >= 0.01 ? ' · about \$${today.costUsd.toStringAsFixed(2)}' : ''}'
                        ' (as of the last dashboard update).',
              key: const ValueKey('settings-digest-usage'),
              style: muted,
            ),
          ],
        );
      },
    );
  }

  static DigestThresholds _copy(
    DigestThresholds t, {
    int? workingMinutes,
    int? sameFailures,
    int? sameCommands,
    int? approvalMinutes,
  }) => DigestThresholds(
    workingMinutes: workingMinutes ?? t.workingMinutes,
    sameFailures: sameFailures ?? t.sameFailures,
    sameCommands: sameCommands ?? t.sameCommands,
    approvalMinutes: approvalMinutes ?? t.approvalMinutes,
  );
}

/// One stuck threshold: its value (or the companion's default) and a
/// menu of sensible values.
class _ThresholdTile extends StatelessWidget {
  const _ThresholdTile({
    required this.title,
    required this.unit,
    required this.value,
    required this.fallback,
    required this.options,
    required this.onChanged,
    super.key,
  });

  final String title;
  final String unit;
  final int? value;
  final int fallback;
  final List<int> options;
  final Future<void> Function(int value) onChanged;

  @override
  Widget build(BuildContext context) {
    final current = value ?? fallback;
    return ListTile(
      dense: true,
      title: Text(title),
      trailing: DropdownButton<int>(
        value: options.contains(current) ? current : null,
        hint: Text('$current $unit'),
        underline: const SizedBox.shrink(),
        items: [
          for (final option in options)
            DropdownMenuItem(
              value: option,
              child: Text(
                option == fallback
                    ? '$option $unit (default)'
                    : '$option $unit',
              ),
            ),
        ],
        onChanged: (v) {
          if (v != null) unawaited(onChanged(v));
        },
      ),
    );
  }
}
