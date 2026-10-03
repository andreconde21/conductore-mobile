import 'dart:async';

import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/features/sessions/presentation/live_terminal_preview.dart';
import 'package:conduit/features/sessions/presentation/terminal_preview.dart';
import 'package:conduit/features/terminal/presentation/session_input_hold.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// One session's terminal with what Herdr's shared focus adds to it:
///
/// * a "Switching Herdr to …" hint while the session's input is held
///   (see [TerminalSessionController.holdInput]), and a notice when held
///   input had to be dropped;
/// * with [showSharedView] (a desktop split pane that is not the focused
///   one), the session's own last screen over its live one while that
///   mirrors another session's Herdr workspace. It takes the pointer, so
///   a click only focuses the pane (which focuses the session's workspace)
///   and never lands in the other workspace;
/// * with [herdrActions] (this device may not move Herdr's focus), a
///   banner while Herdr shows another workspace than the session's own,
///   with what to do about held keys, and a "Take focus" button on the
///   split pane cover instead of taking it on a click;
/// * with [showAgentView] (an agent opened here while this device may not
///   move Herdr's focus), the session's own screen over the live one,
///   which mirrors another workspace, with "Show here" (the focus moves
///   once, to the agent's pane) and the banner above it.
class SessionFocusFrame extends StatelessWidget {
  const SessionFocusFrame({
    required this.session,
    required this.palette,
    required this.brightness,
    required this.fontFamily,
    required this.child,
    this.showSharedView = false,
    this.showAgentView = false,
    this.herdrActions,
    super.key,
  });

  final TerminalSessionController session;
  final AppPalette palette;
  final Brightness brightness;
  final String fontFamily;
  final bool showSharedView;
  final bool showAgentView;
  final HerdrFocusActions? herdrActions;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final cover = showSharedView || (showAgentView && herdrActions != null);
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        if (cover)
          ValueListenableBuilder<SharedViewSnapshot?>(
            valueListenable: session.sharedView,
            builder: (context, shared, _) => shared == null
                ? const SizedBox.shrink()
                : _SharedViewCover(
                    shared: shared,
                    palette: palette,
                    brightness: brightness,
                    fontFamily: fontFamily,
                    onTakeFocus: herdrActions?.takeFocusOnce,
                    agentView: !showSharedView,
                  ),
          ),
        if (!showSharedView && herdrActions != null)
          Positioned(
            top: 8,
            left: 8,
            right: 8,
            child: _FocusElsewhereBanner(
              session: session,
              actions: herdrActions!,
              palette: palette,
              brightness: brightness,
            ),
          ),
        Positioned(
          top: 8,
          left: 12,
          right: 12,
          child: IgnorePointer(
            child: Center(
              child: _InputHoldHint(
                state: session.inputHold,
                palette: palette,
                brightness: brightness,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _SharedViewCover extends StatelessWidget {
  const _SharedViewCover({
    required this.shared,
    required this.palette,
    required this.brightness,
    required this.fontFamily,
    this.onTakeFocus,
    this.agentView = false,
  });

  /// Offered instead of focusing on a click, when set.
  final Future<void> Function()? onTakeFocus;

  /// An agent opened here: its own screen, and "Show here".
  final bool agentView;
  final SharedViewSnapshot shared;
  final AppPalette palette;
  final Brightness brightness;
  final String fontFamily;

  @override
  Widget build(BuildContext context) {
    final theme = palette.terminalThemeFor(brightness);
    final muted = palette.mutedForegroundFor(brightness);
    final when = shared.preview.isEmpty ? '' : ' · as of ${shared.timeLabel}';
    return MouseRegion(
      key: const ValueKey('shared-view-cover'),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        // Swallows the click: the pane's own listener focuses it.
        behavior: HitTestBehavior.opaque,
        onTap: () {},
        child: ColoredBox(
          color: theme.background,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Opacity(
                  opacity: 0.45,
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: LiveTerminalPreview(
                      preview: shared.preview,
                      theme: theme,
                      fontFamily: fontFamily,
                      placeholder: '',
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
                child: onTakeFocus == null
                    ? Text(
                        'Shared Herdr view$when. Click to focus.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: muted, fontSize: 12),
                      )
                    : Wrap(
                        alignment: WrapAlignment.center,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 8,
                        children: [
                          Text(
                            agentView
                                ? "The agent's screen$when (read-only)."
                                : 'Shared Herdr view$when.',
                            style: TextStyle(color: muted, fontSize: 12),
                          ),
                          if (agentView)
                            FilledButton(
                              key: const ValueKey('agent-view-show-here'),
                              onPressed: () => unawaited(onTakeFocus!()),
                              child: const Text('Show here'),
                            )
                          else
                            TextButton(
                              key: const ValueKey('shared-view-take-focus'),
                              onPressed: () => unawaited(onTakeFocus!()),
                              child: const Text('Take focus'),
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
}

/// Shows [InputHoldSwitching] after a short beat (a quick switch shows
/// nothing) and [InputHoldFailed] at once.
class _InputHoldHint extends StatefulWidget {
  const _InputHoldHint({
    required this.state,
    required this.palette,
    required this.brightness,
  });

  final ValueListenable<InputHoldState?> state;
  final AppPalette palette;
  final Brightness brightness;

  @override
  State<_InputHoldHint> createState() => _InputHoldHintState();
}

class _InputHoldHintState extends State<_InputHoldHint> {
  static const _switchingDelay = Duration(milliseconds: 250);

  InputHoldState? _shown;
  Timer? _delay;

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_changed);
    _changed();
  }

  @override
  void didUpdateWidget(_InputHoldHint oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      oldWidget.state.removeListener(_changed);
      widget.state.addListener(_changed);
      _changed();
    }
  }

  void _changed() {
    final state = widget.state.value;
    _delay?.cancel();
    if (state is InputHoldSwitching) {
      _delay = Timer(_switchingDelay, () {
        if (mounted) setState(() => _shown = widget.state.value);
      });
      return;
    }
    if (state != _shown && mounted) setState(() => _shown = state);
  }

  @override
  void dispose() {
    _delay?.cancel();
    widget.state.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = _shown;
    if (state == null) return const SizedBox.shrink();
    final place = state.label.isEmpty ? 'its workspace' : state.label;
    final failed = state is InputHoldFailed;
    if (state is InputHoldBlocked) {
      // The focus banner says it, with what to do.
      return const SizedBox.shrink();
    }
    final text = switch (state) {
      InputHoldBlocked() => '',
      InputHoldSwitching() => 'Switching Herdr to $place…',
      InputHoldFailed(:final dropped) =>
        'Herdr did not switch to $place: '
            '$dropped ${dropped == 1 ? 'character' : 'characters'} not sent',
    };
    final palette = widget.palette;
    final brightness = widget.brightness;
    return Semantics(
      liveRegion: true,
      child: DecoratedBox(
        key: ValueKey(failed ? 'input-hold-failed' : 'input-hold-switching'),
        decoration: BoxDecoration(
          color: palette.panelElevatedFor(brightness).withValues(alpha: 0.95),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: failed
                ? Theme.of(context).colorScheme.error
                : palette.hairlineFor(brightness),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: palette.foregroundFor(brightness),
              fontSize: 12.5,
            ),
          ),
        ),
      ),
    );
  }
}

/// What the focus banner and the split pane cover can do while this
/// device may not move Herdr's focus on its own.
class HerdrFocusActions {
  const HerdrFocusActions({
    required this.typeInComposer,
    required this.takeFocusOnce,
    required this.useShownWorkspace,
  });

  /// Opens the composer (which sends to the session's own pane), with the
  /// held text in it.
  final void Function(String heldText) typeInComposer;

  /// Moves Herdr's focus to the session's workspace this once, then sends
  /// what was held.
  final Future<void> Function() takeFocusOnce;

  /// Keeps the session on the workspace Herdr shows now.
  final Future<void> Function() useShownWorkspace;
}

/// "Herdr is showing X (another screen has focus)", while it does, with
/// Type in composer, Take focus once, Use X here and, when keys are held,
/// Discard.
class _FocusElsewhereBanner extends StatelessWidget {
  const _FocusElsewhereBanner({
    required this.session,
    required this.actions,
    required this.palette,
    required this.brightness,
  });

  final TerminalSessionController session;
  final HerdrFocusActions actions;
  final AppPalette palette;
  final Brightness brightness;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([session.focusElsewhere, session.inputHold]),
      builder: (context, _) {
        final hold = session.inputHold.value;
        final blocked = hold is InputHoldBlocked ? hold : null;
        final shown = session.focusElsewhere.value ?? blocked?.label;
        if (shown == null && blocked == null) return const SizedBox.shrink();
        final place = (shown ?? '').isEmpty ? 'another workspace' : shown!;
        final foreground = palette.foregroundFor(brightness);
        final held = blocked == null
            ? ''
            : ' ${blocked.queued} typed '
                  '${blocked.queued == 1 ? 'character is' : 'characters are'} '
                  'waiting.';
        return Semantics(
          liveRegion: true,
          child: DecoratedBox(
            key: const ValueKey('herdr-focus-banner'),
            decoration: BoxDecoration(
              color: palette
                  .panelElevatedFor(brightness)
                  .withValues(alpha: 0.96),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: palette.hairlineFor(brightness)),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Herdr is showing $place (another screen has focus).$held',
                    style: TextStyle(color: foreground, fontSize: 12.5),
                  ),
                  Wrap(
                    spacing: 2,
                    children: [
                      TextButton(
                        key: const ValueKey('herdr-focus-composer'),
                        onPressed: () =>
                            actions.typeInComposer(session.takeHeldText()),
                        child: const Text('Type in composer'),
                      ),
                      TextButton(
                        key: const ValueKey('herdr-focus-take'),
                        onPressed: () => unawaited(actions.takeFocusOnce()),
                        child: const Text('Take focus once'),
                      ),
                      if (shown != null && shown.isNotEmpty)
                        TextButton(
                          key: const ValueKey('herdr-focus-use-shown'),
                          onPressed: () =>
                              unawaited(actions.useShownWorkspace()),
                          child: Text('Use $shown here'),
                        ),
                      if (blocked != null)
                        TextButton(
                          key: const ValueKey('herdr-focus-discard'),
                          onPressed: session.discardHeldInput,
                          child: const Text('Discard'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
