import 'dart:async';

import 'package:conduit/core/presentation/adaptive_modal.dart';
import 'package:conduit/features/command_palette/domain/palette_entry.dart';
import 'package:conduit/features/continuity/domain/continuity_preferences.dart';
import 'package:conduit/features/continuity/domain/continuity_record.dart';
import 'package:conduit/features/continuity/domain/continuity_rules.dart';
import 'package:conduit/features/continuity/presentation/continuity_controller.dart';
import 'package:flutter/material.dart';

/// "5 min ago" for [at], from [now].
String continuityAgo(DateTime at, DateTime now) {
  final gap = now.difference(at);
  if (gap.inMinutes < 1) return 'just now';
  if (gap.inHours < 1) return '${gap.inMinutes} min ago';
  if (gap.inDays < 1) return '${gap.inHours} h ago';
  return '${gap.inDays} d ago';
}

IconData _deviceIcon(DeviceContinuity device) =>
    device.desktop ? Icons.computer_rounded : Icons.smartphone_rounded;

/// Home's "Continue from Omarchy: VTM · Chat view": one compact row while
/// there is an offer, nothing at all otherwise.
class ContinuityBanner extends StatelessWidget {
  const ContinuityBanner({
    required this.controller,
    required this.onOpen,
    super.key,
  });

  final ContinuityController controller;
  final ValueChanged<ContinuityOffer> onOpen;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final offer = controller.offer;
        return AnimatedSize(
          duration: const Duration(milliseconds: 200),
          alignment: Alignment.topCenter,
          child: offer == null
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                  child: _OfferChip(
                    key: const ValueKey('continuity-banner'),
                    offer: offer,
                    onOpen: () => onOpen(offer),
                    onDismiss: () => controller.dismiss(offer),
                  ),
                ),
        );
      },
    );
  }
}

class _OfferChip extends StatelessWidget {
  const _OfferChip({
    required this.offer,
    required this.onOpen,
    required this.onDismiss,
    super.key,
  });

  final ContinuityOffer offer;
  final VoidCallback onOpen;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Material(
      color: colors.secondaryContainer,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
          child: Row(
            children: [
              Icon(
                _deviceIcon(offer.device),
                size: 18,
                color: colors.onSecondaryContainer,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: 'Continue from ${offer.device.name}: '),
                      TextSpan(
                        text: offer.context.place.summary,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colors.onSecondaryContainer,
                  ),
                ),
              ),
              IconButton(
                key: const ValueKey('continuity-dismiss'),
                tooltip: 'Dismiss',
                visualDensity: VisualDensity.compact,
                onPressed: onDismiss,
                icon: Icon(
                  Icons.close_rounded,
                  size: 18,
                  color: colors.onSecondaryContainer,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The desktop's offer: a small card in a corner that goes away by itself
/// after [visibleFor], or when dismissed or taken.
class ContinuityToast extends StatefulWidget {
  const ContinuityToast({
    required this.controller,
    required this.onOpen,
    this.visibleFor = const Duration(seconds: 30),
    super.key,
  });

  final ContinuityController controller;
  final ValueChanged<ContinuityOffer> onOpen;
  final Duration visibleFor;

  @override
  State<ContinuityToast> createState() => _ContinuityToastState();
}

class _ContinuityToastState extends State<ContinuityToast> {
  String? _shownKey;
  bool _expired = false;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final offer = widget.controller.offer;
        if (offer?.key != _shownKey) {
          _shownKey = offer?.key;
          _expired = false;
          _timer?.cancel();
          if (offer != null) {
            _timer = Timer(widget.visibleFor, () {
              if (mounted) setState(() => _expired = true);
            });
          }
        }
        final show = offer != null && !_expired;
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: !show
              ? const SizedBox.shrink()
              : ConstrainedBox(
                  key: const ValueKey('continuity-toast'),
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Material(
                    elevation: 6,
                    borderRadius: BorderRadius.circular(14),
                    color: Theme.of(context).colorScheme.secondaryContainer,
                    child: _OfferChip(
                      offer: offer,
                      onOpen: () => widget.onOpen(offer),
                      onDismiss: () => widget.controller.dismiss(offer),
                    ),
                  ),
                ),
        );
      },
    );
  }
}

/// "Continue on…": every other device's place and recent places; picking
/// one returns it.
Future<ContinuityContext?> showContinuitySheet(
  BuildContext context,
  ContinuityController controller,
) {
  return showAdaptiveModal<ContinuityContext>(
    kind: AdaptiveModalKind.dialog,
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.75,
        ),
        child: _ContinuityList(controller: controller),
      ),
    ),
  );
}

class _ContinuityList extends StatelessWidget {
  const _ContinuityList({required this.controller});

  final ContinuityController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final devices = controller.continuable;
    final now = DateTime.now();
    return ListView(
      key: const ValueKey('continuity-sheet'),
      shrinkWrap: true,
      children: [
        const ListTile(
          title: Text(
            'Continue on…',
            style: TextStyle(fontWeight: FontWeight.w800),
          ),
          subtitle: Text('Where your other devices are and were lately'),
        ),
        const Divider(height: 1),
        if (devices.isEmpty)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              controller.active
                  ? 'No other device has shared where it is yet.'
                  : 'Turn on sync and "Continue where you left off" in '
                        'Settings › Sync to continue across devices.',
              style: theme.textTheme.bodyMedium,
            ),
          ),
        for (final device in devices) ...[
          ListTile(
            dense: true,
            leading: Icon(_deviceIcon(device)),
            title: Text(
              device.name,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: device.activeAt == null
                ? null
                : Text('Used ${continuityAgo(device.activeAt!, now)}'),
          ),
          for (final (index, entry) in [
            ?device.context,
            ...device.recent,
          ].indexed)
            ListTile(
              key: ValueKey(
                'continuity-${device.deviceId}-'
                '${entry.at.millisecondsSinceEpoch}',
              ),
              contentPadding: const EdgeInsets.only(left: 56, right: 16),
              enabled: controller.machineFor(entry.place) != null,
              leading: Icon(
                entry.place.view == ContinuityView.chat
                    ? Icons.forum_outlined
                    : Icons.terminal_rounded,
                size: 20,
              ),
              title: Text(
                entry.place.summary,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                [
                  if (index == 0) 'Now' else continuityAgo(entry.at, now),
                  if (entry.place.machineName.isNotEmpty)
                    entry.place.machineName,
                  if (entry.layout.isNotEmpty) entry.layout,
                  if (controller.machineFor(entry.place) == null)
                    'not saved here',
                ].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => Navigator.of(context).pop(entry),
            ),
        ],
      ],
    );
  }
}

/// The desktop palette's rows: "Continue from Omarchy: VTM · Chat view" for each
/// other device, and "Continue on…" for the whole list.
List<PaletteEntry> continuityPaletteEntries(
  ContinuityController controller, {
  required Future<void> Function(ContinuityContext context) open,
  required Future<void> Function() showAll,
}) {
  if (!controller.active || !controller.preferences.sessions) return const [];
  final now = DateTime.now();
  return [
    for (final device in controller.continuable)
      if (device.context case final context?
          when controller.machineFor(context.place) != null)
        PaletteEntry(
          id: 'continuity:${device.deviceId}',
          title: 'Continue from ${device.name}: ${context.place.summary}',
          subtitle: [
            if (context.place.machineName.isNotEmpty) context.place.machineName,
            if (device.activeAt != null) continuityAgo(device.activeAt!, now),
          ].join(' · '),
          kind: PaletteKind.command,
          icon: device.desktop
              ? Icons.computer_rounded
              : Icons.smartphone_rounded,
          keywords: const ['continue on', 'handoff', 'other device', 'phone'],
          run: () => open(context),
        ),
    PaletteEntry(
      id: 'command:continue-on',
      title: 'Continue on…',
      subtitle: 'Where your other devices are',
      kind: PaletteKind.command,
      icon: Icons.devices_rounded,
      keywords: const ['continuity', 'handoff', 'other device', 'phone'],
      run: showAll,
    ),
  ];
}

/// Settings › Sync, under "Continue where you left off": what this device
/// shares and takes.
class ContinuitySettingsTiles extends StatelessWidget {
  const ContinuitySettingsTiles({
    required this.controller,
    this.enabled = true,
    super.key,
  });

  final ContinuityController controller;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final prefs = controller.preferences;
        void set(ContinuityPreferences next) =>
            unawaited(controller.setPreferences(next));
        Widget tile(
          String key,
          String title,
          String subtitle,
          bool value,
          ContinuityPreferences Function(bool on) next,
        ) => CheckboxListTile(
          key: ValueKey('continuity-$key'),
          contentPadding: const EdgeInsets.only(left: 16),
          dense: true,
          title: Text(title),
          subtitle: Text(subtitle),
          value: value,
          onChanged: enabled ? (on) => set(next(on ?? false)) : null,
        );
        return Column(
          children: [
            tile(
              'sessions',
              'Sessions and views',
              'Where you are (machine, workspace, terminal or Chat view) '
                  'and your recent places.',
              prefs.sessions,
              (on) => prefs.copyWith(sessions: on),
            ),
            tile(
              'drafts',
              'Unsent drafts',
              'Chat view prompts you have not sent. They travel only '
                  'inside the end-to-end encrypted sync data.',
              prefs.drafts,
              (on) => prefs.copyWith(drafts: on),
            ),
            tile(
              'scroll',
              'Chat view position',
              'The message you were reading.',
              prefs.scroll,
              (on) => prefs.copyWith(scroll: on),
            ),
          ],
        );
      },
    );
  }
}

/// Above Chat View's composer: another device's draft for this session.
class ContinuityDraftBar extends StatelessWidget {
  const ContinuityDraftBar({
    required this.resolution,
    required this.onUseTheirs,
    required this.onAppend,
    required this.onKeepMine,
    required this.onClear,
    required this.onDismissHint,
    this.filledFrom,
    super.key,
  });

  /// What to offer; [DraftKeep] with [filledFrom] shows only the hint.
  final DraftResolution resolution;

  /// The device whose draft was just put in the empty composer.
  final DeviceContinuity? filledFrom;
  final VoidCallback onUseTheirs;
  final VoidCallback onAppend;
  final VoidCallback onKeepMine;
  final VoidCallback onClear;
  final VoidCallback onDismissHint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final style = theme.textTheme.bodySmall?.copyWith(
      color: colors.onSurfaceVariant,
    );
    Widget row(IconData icon, String text, List<Widget> actions) => Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 8, 0),
      child: Row(
        children: [
          Icon(icon, size: 16, color: colors.onSurfaceVariant),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: style,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          ...actions,
        ],
      ),
    );
    TextButton button(String key, String label, VoidCallback onPressed) =>
        TextButton(
          key: ValueKey('continuity-draft-$key'),
          style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
          onPressed: onPressed,
          child: Text(label),
        );
    return switch (resolution) {
      DraftChoice(:final device) =>
        row(Icons.devices_rounded, '${device.name} has a different draft', [
          button('theirs', 'Use it', onUseTheirs),
          button('append', 'Both', onAppend),
          button('mine', 'Keep mine', onKeepMine),
        ]),
      DraftClearedElsewhere(:final device) => row(
        Icons.devices_rounded,
        'Sent or cleared on ${device.name}',
        [
          button('clear', 'Clear here', onClear),
          button('mine', 'Keep', onKeepMine),
        ],
      ),
      DraftFill() || DraftKeep() => switch (filledFrom) {
        final device? =>
          row(Icons.devices_rounded, 'Draft from ${device.name}', [
            IconButton(
              key: const ValueKey('continuity-draft-hint-close'),
              tooltip: 'Hide',
              visualDensity: VisualDensity.compact,
              iconSize: 16,
              onPressed: onDismissHint,
              icon: const Icon(Icons.close_rounded),
            ),
          ]),
        null => const SizedBox.shrink(),
      },
    };
  }
}
