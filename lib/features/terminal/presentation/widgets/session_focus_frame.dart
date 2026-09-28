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
///   and never lands in the other workspace.
class SessionFocusFrame extends StatelessWidget {
  const SessionFocusFrame({
    required this.session,
    required this.palette,
    required this.brightness,
    required this.fontFamily,
    required this.child,
    this.showSharedView = false,
    super.key,
  });

  final TerminalSessionController session;
  final AppPalette palette;
  final Brightness brightness;
  final String fontFamily;
  final bool showSharedView;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        if (showSharedView)
          ValueListenableBuilder<SharedViewSnapshot?>(
            valueListenable: session.sharedView,
            builder: (context, shared, _) => shared == null
                ? const SizedBox.shrink()
                : _SharedViewCover(
                    shared: shared,
                    palette: palette,
                    brightness: brightness,
                    fontFamily: fontFamily,
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
  });

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
                child: Text(
                  'Shared Herdr view$when. Click to focus.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: muted, fontSize: 12),
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
    final text = switch (state) {
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
