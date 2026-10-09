import 'dart:async';

import 'package:conduit/core/presentation/edge_swipe_back.dart';
import 'package:conduit/core/theme/terminal_appearance.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/terminal/domain/herdr_remote_control.dart';
import 'package:conduit/features/terminal/domain/terminal_gesture_preferences.dart';
import 'package:conduit/features/terminal/presentation/gestures/desktop_wheel_zoom.dart';
import 'package:conduit/features/terminal/presentation/gestures/terminal_gesture_recognizers.dart';
import 'package:conduit/features/terminal/presentation/herdr_shortcuts.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:conduit_vt/conduit_vt.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// The key sequences the gestures send, kept apart from the widget so they
/// can be unit tested and reused by whoever wires more gestures later.
class TerminalGestureCommands {
  const TerminalGestureCommands(
    this.session,
    this.target, {
    this.herdr,
    this.onHerdrWorkspaceFocused,
  });

  final TerminalSessionController session;
  final TerminalWindowSwitchTarget target;

  /// Herdr's command channel for this session, when the host allows one.
  /// Herdr actions go through the CLI when it is there (independent of the
  /// server's key bindings) and fall back to Herdr's default bindings.
  final HerdrRemoteControl? herdr;

  /// Told which workspace a Herdr workspace swipe landed on.
  final ValueChanged<String>? onHerdrWorkspaceFocused;

  /// The prefix key for [target]: the host's configured multiplexer prefix
  /// (Ctrl+B unless changed), which tmux and Herdr share on a host.
  MultiplexerPrefixKey get prefixKey => switch (target) {
    TerminalWindowSwitchTarget.herdr ||
    TerminalWindowSwitchTarget.tmux => session.host.tmuxPrefixKey,
  };

  void _prefixed(String binding) {
    session.sendPrefix(prefixKey);
    session.sendText(binding);
  }

  bool get _isHerdr => target == TerminalWindowSwitchTarget.herdr;

  /// A Herdr config action with the machine's binding (Herdr's default
  /// until the machine's keymap is read). Nothing is typed when the
  /// machine unbound the action: a default key may mean something else
  /// there.
  void _herdrAction(String action) {
    sendHerdrAction(session, action, hostPrefix: prefixKey);
  }

  /// `prefix n`: next window in tmux, next tab in Herdr (its `next_tab`).
  void nextWindow() => _isHerdr ? _herdrAction('next_tab') : _prefixed('n');

  /// `prefix p`: previous window in tmux, previous tab in Herdr.
  void previousWindow() =>
      _isHerdr ? _herdrAction('previous_tab') : _prefixed('p');

  /// `prefix [`: copy (scrollback) mode in both tmux and Herdr.
  void enterScrollback() =>
      _isHerdr ? _herdrAction('copy_mode') : _prefixed('[');

  /// `q` leaves copy mode in both tmux and Herdr.
  void exitScrollback() => session.sendText('q');

  /// Herdr: focus the neighbouring pane (`herdr pane focus --direction`,
  /// or the default `prefix h/j/k/l`).
  void focusHerdrPane(HerdrDirection direction) {
    final control = herdr;
    if (control != null) {
      unawaited(control.focusPane(direction));
      return;
    }
    // The machine's binding: on some hosts prefix+h splits and panes are
    // focused with ctrl+alt+arrows.
    switch (direction) {
      case HerdrDirection.left:
        _herdrAction('focus_pane_left');
      case HerdrDirection.down:
        _herdrAction('focus_pane_down');
      case HerdrDirection.up:
        _herdrAction('focus_pane_up');
      case HerdrDirection.right:
        _herdrAction('focus_pane_right');
    }
  }

  /// Herdr: zoom the focused pane full-screen or restore it
  /// (`herdr pane zoom --on/--off`). Without the CLI, `prefix z` toggles,
  /// so the caller only asks when the zoom state should flip.
  void zoomHerdrPane({required bool on}) {
    final control = herdr;
    if (control != null) {
      unawaited(control.setZoom(on: on));
      return;
    }
    _herdrAction('zoom');
  }

  /// Herdr: focus the next ([delta] 1) or previous (-1) workspace. Herdr
  /// has no default binding for that, so without the CLI this opens the
  /// workspace navigator (`prefix w`) instead.
  void focusAdjacentHerdrWorkspace(int delta) {
    final control = herdr;
    if (control == null) {
      _herdrAction('workspace_picker');
      return;
    }
    unawaited(
      control.focusAdjacentWorkspace(delta).then((workspaceId) {
        if (workspaceId != null) {
          onHerdrWorkspaceFocused?.call(workspaceId);
        }
      }),
    );
  }

  /// tmux: the neighbouring pane, with tmux's default `prefix Left/Right/
  /// Up/Down` (`select-pane -L/-R/-U/-D`). Typed into this session, so it
  /// reaches exactly the client the app is attached through.
  void selectTmuxPane(HerdrDirection direction) {
    session.sendPrefix(prefixKey);
    session.sendKey(switch (direction) {
      HerdrDirection.left => TerminalKey.arrowLeft,
      HerdrDirection.right => TerminalKey.arrowRight,
      HerdrDirection.up => TerminalKey.arrowUp,
      HerdrDirection.down => TerminalKey.arrowDown,
    });
  }

  void scrollBack(int lines) {
    for (var i = 0; i < lines; i += 1) {
      session.sendKey(TerminalKey.arrowUp);
    }
  }

  void scrollForward(int lines) {
    for (var i = 0; i < lines; i += 1) {
      session.sendKey(TerminalKey.arrowDown);
    }
  }
}

enum _TwoFingerKind { pinch, scroll, paneSwipe, workspaceSwipe, ignored }

/// Adds the Moshi-style touch gestures on top of a terminal surface.
///
/// For tmux (and plain shells):
///
/// * one-finger horizontal swipe switches the multiplexer window;
/// * pinch changes the terminal font size;
/// * two-finger vertical swipe scrolls back through history (entering the
///   app's scroll mode on the way in, leaving it again when swiped past the
///   bottom). It stays scrollback in tmux: tmux has no workspaces above its
///   sessions for it to switch;
/// * in a tmux session ([target] is [TerminalWindowSwitchTarget.tmux]),
///   two-finger left/right focuses the pane to the right/left
///   (`prefix Right` / `prefix Left`), under the same setting as Herdr's
///   pane swipe.
///
/// For Herdr ([target] is [TerminalWindowSwitchTarget.herdr]):
///
/// * one-finger left/right: next/previous tab (`prefix n` / `prefix p`);
/// * two-finger left/right: focus the pane to the right/left;
/// * two-finger up/down: next/previous workspace;
/// * pinch out/in: zoom the focused pane full-screen / restore it;
/// * scrollback: rest two fingers for [holdToScrollDelay], then drag; or,
///   once in scroll mode (the toolbar's or navigator's Scrollback), a plain
///   two-finger drag. Each mapping can be changed in the Gestures settings.
///
/// In both:
///
/// * swipe down from the header strip opens the session grid;
/// * swipe in from the right edge opens the agent panel;
/// * a swipe from the left edge of a pushed page is left to the page's
///   swipe-back (see `startsEdgeSwipeBack`).
///
/// Each gesture is switched by [preferences]. The layer never touches the
/// terminal view's own tap, long-press and single-finger scroll handling: its
/// recognisers only enter the gesture arena and win by the rules described
/// on [TerminalSwipeRecognizer] and [TwoFingerGestureRecognizer].
class TerminalGestureLayer extends StatefulWidget {
  const TerminalGestureLayer({
    required this.preferences,
    required this.session,
    required this.fontSize,
    required this.onFontSizeChanged,
    required this.scrollMode,
    required this.onEnterScrollMode,
    required this.onExitScrollMode,
    required this.child,
    this.enabled = true,
    this.onOpenSessionGrid,
    this.onOpenAgentPanel,
    this.headerZoneHeight = 48,
    this.edgeZoneWidth = 24,
    this.target,
    this.herdrControl,
    this.onHerdrWorkspaceFocused,
    super.key,
  });

  /// The multiplexer the gestures drive; null uses the preference's swipe
  /// target. A session opened on a Herdr or tmux target passes that.
  final TerminalWindowSwitchTarget? target;

  /// Herdr's command channel for this session (see
  /// [TerminalGestureCommands.herdr]).
  final HerdrRemoteControl? herdrControl;

  /// Told which workspace a two-finger workspace swipe landed on.
  final ValueChanged<String>? onHerdrWorkspaceFocused;

  final TerminalGesturePreferences preferences;
  final TerminalSessionController session;
  final double fontSize;
  final ValueChanged<double> onFontSizeChanged;

  /// Whether the app's scroll (tmux copy) mode is active for this session.
  /// The layer sends the keys that enter and leave copy mode itself and only
  /// asks the owner to flip its state through [onEnterScrollMode] and
  /// [onExitScrollMode].
  final bool scrollMode;
  final VoidCallback onEnterScrollMode;
  final VoidCallback onExitScrollMode;

  /// Opens the session grid; null disables the header swipe.
  final VoidCallback? onOpenSessionGrid;

  /// Opens the agent panel; null disables the right-edge swipe.
  final VoidCallback? onOpenAgentPanel;

  /// Turns every gesture off (for example while a file tab covers the
  /// terminal) without rebuilding the child.
  final bool enabled;

  /// Height of the strip at the top of the terminal that counts as the
  /// header for the swipe-down gesture.
  final double headerZoneHeight;

  /// Width of the strip along the right side that starts the edge swipe.
  final double edgeZoneWidth;

  final Widget child;

  /// Pixels of two-finger travel per scrolled line.
  static const double scrollLineStep = 14;

  /// Extra upward two-finger travel, once at the bottom of the scrollback,
  /// that leaves scroll mode.
  static const double scrollExitDistance = 56;

  /// Two-finger movement needed before the gesture is classified as a pinch
  /// or a scroll.
  static const double classifyThreshold = 10;

  /// Two-finger travel that makes a Herdr pane or workspace swipe.
  static const double herdrSwipeDistance = 64;

  /// Scale a Herdr pinch has to pass to zoom (or, inverted, to restore).
  static const double herdrZoomScale = 1.2;

  /// In Herdr, two fingers resting this long before they move make the
  /// drag scroll back instead of switching workspaces.
  static const Duration holdToScrollDelay = Duration(milliseconds: 350);

  @override
  State<TerminalGestureLayer> createState() => _TerminalGestureLayerState();
}

class _TerminalGestureLayerState extends State<TerminalGestureLayer> {
  late final TerminalSwipeRecognizer _swipe;
  late final TwoFingerGestureRecognizer _twoFinger;
  _TwoFingerKind? _twoFingerKind;
  double _pinchStartFontSize = terminalFontSizeDefault;
  double _scrollRemainder = 0;
  double _exitTravel = 0;
  // Lines this layer has scrolled above the live screen. Only an estimate:
  // the Touch key's single-finger drag scrolls through the same session
  // without telling us, so "the bottom" can be reached early.
  int _linesAbove = 0;
  bool _scrollMode = false;
  // Herdr two-finger state: whether the current gesture already fired its
  // one action, and whether the fingers rested long enough to scroll.
  bool _fired = false;
  bool _held = false;
  Timer? _holdTimer;
  // Without the Herdr CLI, zoom is a toggle key: remember what we asked for.
  bool _herdrZoomed = false;

  TerminalWindowSwitchTarget get _target =>
      widget.target ?? widget.preferences.windowSwitchTarget;

  bool get _herdr => _target == TerminalWindowSwitchTarget.herdr;

  TerminalGestureCommands get _commands => TerminalGestureCommands(
    widget.session,
    _target,
    herdr: widget.herdrControl,
    onHerdrWorkspaceFocused: widget.onHerdrWorkspaceFocused,
  );

  @override
  void initState() {
    super.initState();
    _scrollMode = widget.scrollMode;
    _swipe = TerminalSwipeRecognizer(onSwipe: _handleSwipe);
    _twoFinger = TwoFingerGestureRecognizer(
      onStart: _handleTwoFingerStart,
      onUpdate: _handleTwoFingerUpdate,
      onEnd: _handleTwoFingerEnd,
    );
  }

  @override
  void didUpdateWidget(covariant TerminalGestureLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scrollMode != widget.scrollMode) {
      _scrollMode = widget.scrollMode;
      if (!_scrollMode) {
        _linesAbove = 0;
        _exitTravel = 0;
      }
    }
  }

  bool get _windowSwipeEnabled =>
      widget.enabled &&
      widget.preferences.swipeSwitchesWindow &&
      !widget.scrollMode;

  bool get _headerSwipeEnabled =>
      widget.enabled &&
      widget.preferences.headerSwipeOpensSessions &&
      widget.onOpenSessionGrid != null;

  bool get _edgeSwipeEnabled =>
      widget.enabled &&
      widget.preferences.edgeSwipeOpensAgents &&
      widget.onOpenAgentPanel != null;

  bool get _pinchEnabled => widget.enabled && widget.preferences.pinchZoom;

  bool get _pinchZoomsHerdrPane =>
      _herdr && widget.preferences.herdrPinch == HerdrPinchAction.zoomPane;

  bool get _twoFingerScrollEnabled =>
      widget.enabled && widget.preferences.twoFingerScroll;

  bool get _paneSwipeEnabled =>
      widget.enabled && _herdr && widget.preferences.herdrTwoFingerPanes;

  /// Only for sessions attached to tmux: in a plain shell the prefix and
  /// an arrow would reach the shell.
  bool get _tmuxPaneSwipeEnabled =>
      widget.enabled &&
      widget.target == TerminalWindowSwitchTarget.tmux &&
      widget.preferences.herdrTwoFingerPanes;

  bool get _workspaceSwipeEnabled =>
      widget.enabled &&
      _herdr &&
      widget.preferences.herdrTwoFingerVertical ==
          HerdrVerticalSwipe.workspaces;

  @override
  void dispose() {
    _holdTimer?.cancel();
    super.dispose();
  }

  void _handleSwipe(TerminalSwipeKind kind) {
    switch (kind) {
      case TerminalSwipeKind.windowNext:
        _commands.nextWindow();
      case TerminalSwipeKind.windowPrevious:
        _commands.previousWindow();
      case TerminalSwipeKind.headerDown:
        widget.onOpenSessionGrid?.call();
      case TerminalSwipeKind.edgeIn:
        widget.onOpenAgentPanel?.call();
    }
  }

  void _handleTwoFingerStart() {
    _twoFingerKind = null;
    _scrollRemainder = 0;
    _pinchStartFontSize = widget.fontSize;
    _fired = false;
    _held = false;
    _holdTimer?.cancel();
    if (_herdr && _workspaceSwipeEnabled && _twoFingerScrollEnabled) {
      _holdTimer = Timer(TerminalGestureLayer.holdToScrollDelay, () {
        if (_twoFingerKind == null) {
          _held = true;
          unawaited(HapticFeedback.selectionClick());
        }
      });
    }
  }

  /// Sorts a Herdr (or tmux pane-swipe) two-finger gesture into one of its
  /// mappings, or null while it has not moved far enough to tell.
  _TwoFingerKind? _classifyHerdr(TwoFingerUpdate update) {
    const threshold = TerminalGestureLayer.classifyThreshold;
    final first = update.firstDelta;
    final second = update.secondDelta;
    final firstMoved = first.distance >= threshold;
    final secondMoved = second.distance >= threshold;
    if (!firstMoved && !secondMoved) {
      return null;
    }
    final bool pinch;
    if (firstMoved && secondMoved) {
      // Fingers moving apart or together point in opposite directions.
      final cosine =
          (first.dx * second.dx + first.dy * second.dy) /
          (first.distance * second.distance);
      pinch = cosine < 0;
    } else {
      // One finger moved alone: its partner may simply lag an event behind.
      // Only a clear lead with the other finger resting is a pinch
      // (a thumb anchored while the index finger spreads).
      final moving = firstMoved ? first : second;
      final resting = firstMoved ? second : first;
      if (moving.distance < threshold * 3 || resting.distance >= threshold) {
        return null;
      }
      pinch = true;
    }
    final dx = update.focalDelta.dx.abs();
    final dy = update.focalDelta.dy.abs();
    if (pinch) {
      return _pinchEnabled ? _TwoFingerKind.pinch : _TwoFingerKind.ignored;
    }
    if (dx > dy) {
      // Changing pane under an open copy mode would strand it.
      return (_paneSwipeEnabled || _tmuxPaneSwipeEnabled) && !_scrollMode
          ? _TwoFingerKind.paneSwipe
          : _TwoFingerKind.ignored;
    }
    final scrollback = _scrollMode || _held || !_workspaceSwipeEnabled;
    if (!scrollback) {
      return _TwoFingerKind.workspaceSwipe;
    }
    return _twoFingerScrollEnabled
        ? _TwoFingerKind.scroll
        : _TwoFingerKind.ignored;
  }

  void _handleTwoFingerUpdate(TwoFingerUpdate update) {
    var kind = _twoFingerKind;
    // tmux sessions with the pane swipe share Herdr's classifier: it tells a
    // sideways two-finger swipe from a pinch whose fingers report one at a
    // time. Vertical stays scrollback there (no workspace swipe).
    if (kind == null && (_herdr || _tmuxPaneSwipeEnabled)) {
      kind = _classifyHerdr(update);
      if (kind == null) {
        return;
      }
      _twoFingerKind = kind;
      _holdTimer?.cancel();
      if (kind == _TwoFingerKind.scroll) {
        _scrollRemainder = update.focalDelta.dy;
        _applyScroll();
        return;
      }
    }
    if (kind == null) {
      final span = update.spanDelta.abs();
      final travel = update.focalDelta.dy.abs();
      if (span < TerminalGestureLayer.classifyThreshold &&
          travel < TerminalGestureLayer.classifyThreshold) {
        return;
      }
      if (!_pinchEnabled && !_twoFingerScrollEnabled) {
        return;
      }
      kind = _pinchEnabled && (!_twoFingerScrollEnabled || span >= travel)
          ? _TwoFingerKind.pinch
          : _TwoFingerKind.scroll;
      _twoFingerKind = kind;
      if (kind == _TwoFingerKind.scroll) {
        // The travel that classified the gesture counts as scrolling too.
        _scrollRemainder = update.focalDelta.dy;
        _applyScroll();
        return;
      }
    }
    switch (kind) {
      case _TwoFingerKind.pinch:
        if (_pinchZoomsHerdrPane) {
          _zoomHerdrPane(update.scale);
        } else {
          widget.onFontSizeChanged(
            clampTerminalFontSize(_pinchStartFontSize * update.scale),
          );
        }
      case _TwoFingerKind.scroll:
        _scrollRemainder += update.focalStep.dy;
        _applyScroll();
      case _TwoFingerKind.paneSwipe:
        final dx = update.focalDelta.dx;
        if (!_fired && dx.abs() >= TerminalGestureLayer.herdrSwipeDistance) {
          _fired = true;
          // Like the one-finger tab swipe: leftwards brings in what is on
          // the right.
          final direction = dx < 0 ? HerdrDirection.right : HerdrDirection.left;
          if (_herdr) {
            _commands.focusHerdrPane(direction);
          } else {
            _commands.selectTmuxPane(direction);
          }
        }
      case _TwoFingerKind.workspaceSwipe:
        final dy = update.focalDelta.dy;
        if (!_fired && dy.abs() >= TerminalGestureLayer.herdrSwipeDistance) {
          _fired = true;
          _commands.focusAdjacentHerdrWorkspace(dy < 0 ? 1 : -1);
        }
      case _TwoFingerKind.ignored:
        break;
    }
  }

  void _zoomHerdrPane(double scale) {
    if (_fired) {
      return;
    }
    final bool on;
    if (scale >= TerminalGestureLayer.herdrZoomScale) {
      on = true;
    } else if (scale <= 1 / TerminalGestureLayer.herdrZoomScale) {
      on = false;
    } else {
      return;
    }
    _fired = true;
    if (widget.herdrControl == null) {
      // A toggle key: only press it when the zoom should actually flip.
      if (_herdrZoomed == on) {
        return;
      }
      _herdrZoomed = on;
    }
    _commands.zoomHerdrPane(on: on);
  }

  void _applyScroll() {
    const step = TerminalGestureLayer.scrollLineStep;
    final commands = _commands;
    // Fingers moving down reveal older output: scroll back.
    var back = 0;
    while (_scrollRemainder >= step) {
      _scrollRemainder -= step;
      back += 1;
    }
    if (back > 0) {
      _exitTravel = 0;
      if (!_scrollMode) {
        _scrollMode = true;
        _linesAbove = 0;
        commands.enterScrollback();
        widget.onEnterScrollMode();
      }
      commands.scrollBack(back);
      _linesAbove += back;
    }
    // Fingers moving up head back towards the live screen.
    var forward = 0;
    while (_scrollRemainder <= -step) {
      _scrollRemainder += step;
      forward += 1;
    }
    if (forward == 0) {
      return;
    }
    if (!_scrollMode) {
      // Nothing newer than the live screen; swallow the travel.
      return;
    }
    final scrollable = forward.clamp(0, _linesAbove);
    if (scrollable > 0) {
      commands.scrollForward(scrollable);
      _linesAbove -= scrollable;
    }
    final overshoot = forward - scrollable;
    if (overshoot > 0) {
      _exitTravel += overshoot * step;
      if (_exitTravel >= TerminalGestureLayer.scrollExitDistance) {
        _exitTravel = 0;
        _scrollMode = false;
        _linesAbove = 0;
        commands.exitScrollback();
        widget.onExitScrollMode();
      }
    }
  }

  void _handleTwoFingerEnd() {
    _twoFingerKind = null;
    _scrollRemainder = 0;
    _fired = false;
    _held = false;
    _holdTimer?.cancel();
  }

  @override
  Widget build(BuildContext context) {
    final touchSlop =
        MediaQuery.maybeGestureSettingsOf(context)?.touchSlop ?? kTouchSlop;
    return LayoutBuilder(
      builder: (context, constraints) {
        _swipe
          ..zones = TerminalSwipeZones(
            size: constraints.biggest,
            headerHeight: widget.headerZoneHeight,
            edgeWidth: widget.edgeZoneWidth,
          )
          ..touchSlop = touchSlop
          ..windowSwipeEnabled = _windowSwipeEnabled
          ..headerSwipeEnabled = _headerSwipeEnabled
          ..edgeSwipeEnabled = _edgeSwipeEnabled;
        final twoFinger =
            _pinchEnabled ||
            _twoFingerScrollEnabled ||
            _paneSwipeEnabled ||
            _tmuxPaneSwipeEnabled ||
            _workspaceSwipeEnabled;
        // See TerminalPointerMember for why a Listener feeds the members
        // instead of a RawGestureDetector.
        return Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (event) {
            // A touch in the left strip of a pushed page is the page's
            // swipe-back, not a window swipe; taps, long presses and
            // vertical scrolling there stay with the terminal view.
            if (!startsEdgeSwipeBack(context, event.position)) {
              _swipe.handlePointerDown(event);
            }
            if (twoFinger) {
              _twoFinger.handlePointerDown(event);
            }
          },
          onPointerMove: (event) {
            _swipe.handlePointerMove(event);
            _twoFinger.handlePointerMove(event);
          },
          onPointerUp: (event) {
            _swipe.handlePointerUp(event);
            _twoFinger.handlePointerUp(event);
          },
          onPointerCancel: (event) {
            _swipe.handlePointerCancel(event);
            _twoFinger.handlePointerCancel(event);
          },
          child: DesktopWheelZoom(
            fontSize: widget.fontSize,
            onFontSizeChanged: widget.onFontSizeChanged,
            child: widget.child,
          ),
        );
      },
    );
  }
}

/// Wraps a header widget so a downward swipe on it opens the session grid.
///
/// The header has no vertical gestures of its own, so a plain vertical drag
/// is enough here; taps on the header's buttons are unaffected.
class TerminalHeaderSwipeArea extends StatefulWidget {
  const TerminalHeaderSwipeArea({
    required this.onSwipeDown,
    required this.child,
    this.enabled = true,
    super.key,
  });

  final VoidCallback? onSwipeDown;
  final bool enabled;
  final Widget child;

  @override
  State<TerminalHeaderSwipeArea> createState() =>
      _TerminalHeaderSwipeAreaState();
}

class _TerminalHeaderSwipeAreaState extends State<TerminalHeaderSwipeArea> {
  double _travel = 0;

  @override
  Widget build(BuildContext context) {
    final onSwipeDown = widget.onSwipeDown;
    if (!widget.enabled || onSwipeDown == null) {
      return widget.child;
    }
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onVerticalDragStart: (_) => _travel = 0,
      onVerticalDragUpdate: (details) => _travel += details.delta.dy,
      onVerticalDragEnd: (_) {
        if (_travel >= TerminalSwipeRecognizer.minimumDistance) {
          onSwipeDown();
        }
        _travel = 0;
      },
      child: widget.child,
    );
  }
}
