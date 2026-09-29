import 'dart:async';

import 'package:conduit/core/platform_features.dart';
import 'package:conduit/core/presentation/adaptive_modal.dart';
import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/features/terminal/domain/terminal_link_detector.dart';
import 'package:conduit/features/terminal/domain/terminal_path_detector.dart';
import 'package:conduit/features/terminal/domain/terminal_remote_scroll.dart';
import 'package:conduit/features/terminal/presentation/desktop_keyboard.dart';
import 'package:conduit/features/terminal/presentation/desktop_shortcuts.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:conduit_vt/conduit_vt.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class TerminalSurface extends StatefulWidget {
  const TerminalSurface({
    required this.session,
    required this.palette,
    required this.brightness,
    required this.fontFamily,
    required this.fontSize,
    required this.predictiveEchoEnabled,
    required this.terminalMouseInput,
    required this.focusNode,
    required this.tmuxScrollMode,
    required this.onExitTmuxScrollMode,
    this.onPathTap,
    this.onLinkTap,
    this.onLinkLongPress,
    this.onLinkOpen,
    this.autoConnect = true,
    this.onKeyEvent,
    this.dragScrollsRemote = true,
    this.onEnterScrollMode,
    this.onPasteImage,
    super.key,
  });

  final TerminalSessionController session;
  final AppPalette palette;
  final Brightness brightness;
  final String fontFamily;
  final double fontSize;
  final bool predictiveEchoEnabled;
  final bool terminalMouseInput;
  final FocusNode? focusNode;
  final bool tmuxScrollMode;
  final VoidCallback onExitTmuxScrollMode;

  /// Called when the user taps something in the output that looks like a
  /// file path.
  final ValueChanged<String>? onPathTap;

  /// Called when the user taps an http(s) link in the output.
  final ValueChanged<String>? onLinkTap;

  /// Called when the user long-presses an http(s) link, with the link and
  /// the logical line it sits on. The word selection the long press makes
  /// stays unless the callback resolves to true (an action was taken).
  final Future<bool> Function(String url, String line)? onLinkLongPress;

  /// Desktop only: opens an http(s) link straight away, for a Ctrl+click
  /// (Cmd+click on macOS). When set, a plain click on a link no longer
  /// calls [onLinkTap] on desktop, so it can start a selection like any
  /// other text. Null keeps the plain click on [onLinkTap].
  final ValueChanged<String>? onLinkOpen;

  /// Whether a disconnected session connects as soon as this view is
  /// built. False for a background tab that waits to be shown (a session
  /// restored from the last app run); it connects when this turns true.
  final bool autoConnect;

  /// Sees each hardware key before the terminal does; a result other than
  /// ignored keeps the key from the session (app shortcuts like Ctrl+K).
  final FocusOnKeyEventCallback? onKeyEvent;

  /// Whether a one-finger vertical drag scrolls the remote program when it
  /// is on the alternate screen or asked for mouse reports (see
  /// [remoteScrollRouteFor]). Off, drags go to the terminal view as before.
  final bool dragScrollsRemote;

  /// Enters the multiplexer's copy mode (sends the keys and flips the
  /// page's scroll-mode state), for a drag on the alternate screen that
  /// has no other way to reach history. Null when the session is not a
  /// tmux or Herdr session: such drags send arrow keys instead.
  final VoidCallback? onEnterScrollMode;

  /// Tried first when the paste shortcut (Ctrl+V, Cmd+V on Apple) is
  /// pressed: pastes the clipboard's image as an uploaded file path and
  /// resolves to true, or to false so the text is pasted. Null keeps the
  /// terminal's own text paste.
  final Future<bool> Function()? onPasteImage;

  @override
  State<TerminalSurface> createState() => _TerminalSurfaceState();
}

class _TerminalSurfaceState extends State<TerminalSurface> {
  double _tmuxScrollDelta = 0;
  late final TerminalController _terminalController;
  final _viewKey = GlobalKey<TerminalViewState>();
  Timer? _longPressTimer;
  int? _longPressPointer;
  Offset? _longPressOrigin;

  // One-finger drags that scroll the remote program.
  // Owned (and disposed) by its RawGestureDetector.
  _RemoteScrollDragRecognizer? _remoteDrag;
  final _remoteScroll = RemoteScrollAccumulator();
  RemoteScrollRoute _remoteRoute = RemoteScrollRoute.local;
  Offset _remoteDragPosition = Offset.zero;
  Timer? _momentumTimer;
  int _pointersDown = 0;
  // Copy mode this surface entered for a drag; a tap leaves it again.
  bool _dragEnteredScrollMode = false;
  // Desktop: mouse wheel and trackpad travel towards the next report to a
  // remote program (see _desktopScrollRoute).
  final _desktopScroll = RemoteScrollAccumulator(step: desktopWheelStep);
  // Desktop: the mouse is over a link (a hand cursor), and the buttons of
  // the last press (a middle-click also reaches the secondary callback).
  bool _hoveringLink = false;
  int _lastButtons = 0;

  static PointerInputs _pointerInputsFor(bool terminalMouseInput) {
    return terminalMouseInput
        ? const PointerInputs({PointerInput.tap})
        : const PointerInputs.none();
  }

  @override
  void initState() {
    super.initState();
    _terminalController = TerminalController(
      pointerInputs: _pointerInputsFor(widget.terminalMouseInput),
    );
    widget.session.predictiveEchoEnabled = widget.predictiveEchoEnabled;
    WidgetsBinding.instance.addPostFrameCallback((_) => _connectIfNeeded());
  }

  @override
  void didUpdateWidget(covariant TerminalSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.predictiveEchoEnabled != widget.predictiveEchoEnabled ||
        oldWidget.session != widget.session) {
      widget.session.predictiveEchoEnabled = widget.predictiveEchoEnabled;
    }
    if (oldWidget.terminalMouseInput != widget.terminalMouseInput) {
      _terminalController.setPointerInputs(
        _pointerInputsFor(widget.terminalMouseInput),
      );
    }
    if (oldWidget.session != widget.session) {
      _stopMomentum();
    }
    if (oldWidget.session != widget.session ||
        (!oldWidget.autoConnect && widget.autoConnect)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _connectIfNeeded());
    }
    if (!widget.tmuxScrollMode) {
      _dragEnteredScrollMode = false;
    }
    if (!widget.dragScrollsRemote) {
      _stopMomentum();
    }
  }

  @override
  void dispose() {
    _stopMomentum();
    _longPressTimer?.cancel();
    _terminalController.dispose();
    super.dispose();
  }

  /// Connects a new or dropped session. A session that is already live
  /// had no view while this page was closed (or the app was away), so the
  /// remote is asked for a full repaint instead of trusting the buffer.
  Future<void> _connectIfNeeded() async {
    if (!mounted) return;
    final session = widget.session;
    if (session.shouldConnect) {
      if (!widget.autoConnect) return;
      await session.connect();
    } else if (session.isConnected) {
      session.forceResize();
    }
  }

  void _handleTmuxScrollDrag(DragUpdateDetails details) {
    _tmuxScrollDelta += details.primaryDelta ?? 0;
    const step = 12.0;
    while (_tmuxScrollDelta.abs() >= step) {
      if (_tmuxScrollDelta > 0) {
        widget.session.sendKey(TerminalKey.arrowUp);
        _tmuxScrollDelta -= step;
      } else {
        widget.session.sendKey(TerminalKey.arrowDown);
        _tmuxScrollDelta += step;
      }
    }
  }

  void _handleTmuxScrollEnd(DragEndDetails details) {
    _tmuxScrollDelta = 0;
  }

  static const _maxWrappedRows = 8;

  void _handleTapUp(TapUpDetails details, CellOffset offset) {
    if (widget.tmuxScrollMode) {
      return;
    }
    // The cursor row is the prompt or the command being typed. Tapping there
    // is how the keyboard gets summoned on a phone, and prompts routinely
    // show the working directory, so it must not raise an "Open" snackbar on
    // every tap. Output above the cursor is unaffected.
    if (offset.y == widget.session.terminal.buffer.absoluteCursorY) {
      return;
    }
    final line = _logicalLineAt(offset);
    if (line == null) {
      return;
    }
    final onLinkTap = widget.onLinkTap;
    final onLinkOpen = PlatformFeatures.isDesktop ? widget.onLinkOpen : null;
    if (onLinkTap != null || onLinkOpen != null) {
      final url = terminalUrlAt(line.text, line.column);
      if (url != null) {
        if (onLinkOpen != null) {
          // Ctrl/Cmd+click opens; a plain click stays a click in text.
          if (_linkModifierPressed) onLinkOpen(url);
        } else {
          onLinkTap?.call(url);
        }
        return;
      }
    }
    final onPathTap = widget.onPathTap;
    if (onPathTap == null) {
      return;
    }
    final path = terminalPathAt(line.text, line.column);
    if (path != null) {
      onPathTap(path);
    }
  }

  /// Ctrl on Linux and Windows, Cmd on macOS: the modifier of a click that
  /// opens a link.
  static bool get _linkModifierPressed =>
      defaultTargetPlatform == TargetPlatform.macOS
      ? HardwareKeyboard.instance.isMetaPressed
      : HardwareKeyboard.instance.isControlPressed;

  /// Desktop: a hand cursor while the mouse is over a link.
  void _handleHover(PointerHoverEvent event) {
    final render = _viewKey.currentState?.renderTerminal;
    var overLink = false;
    if (render != null && render.attached) {
      final offset = render.getCellOffset(render.globalToLocal(event.position));
      final line = _logicalLineAt(offset);
      overLink = line != null && terminalUrlAt(line.text, line.column) != null;
    }
    if (overLink != _hoveringLink) {
      setState(() => _hoveringLink = overLink);
    }
  }

  /// Desktop right-click, when the remote program does not take the mouse
  /// itself (TerminalView only calls this for clicks it did not report):
  /// Copy, Paste and Select all at the pointer. The right button leaves a
  /// selection alone, so Copy copies what was just selected.
  Future<void> _handleSecondaryTapUp(
    TapUpDetails details,
    CellOffset offset,
  ) async {
    // A middle-click reaches this callback too; it is not a menu.
    if (_lastButtons & kSecondaryMouseButton == 0) return;
    final terminal = widget.session.terminal;
    if (terminal.mouseMode != MouseMode.none) return;
    final selection = _terminalController.selection;
    final action = await showAdaptiveModal<_TerminalMenuAction>(
      context: context,
      kind: AdaptiveModalKind.menu,
      anchorPosition: details.globalPosition,
      desktopMaxWidth: 220,
      builder: (context) => Column(
        key: const ValueKey('terminal-context-menu'),
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            key: const ValueKey('terminal-menu-copy'),
            dense: true,
            enabled: selection != null,
            leading: const Icon(Icons.copy_rounded, size: 18),
            title: const Text('Copy'),
            onTap: () => Navigator.of(context).pop(_TerminalMenuAction.copy),
          ),
          ListTile(
            key: const ValueKey('terminal-menu-paste'),
            dense: true,
            leading: const Icon(Icons.content_paste_rounded, size: 18),
            title: const Text('Paste'),
            onTap: () => Navigator.of(context).pop(_TerminalMenuAction.paste),
          ),
          ListTile(
            key: const ValueKey('terminal-menu-select-all'),
            dense: true,
            leading: const Icon(Icons.select_all_rounded, size: 18),
            title: const Text('Select all'),
            onTap: () =>
                Navigator.of(context).pop(_TerminalMenuAction.selectAll),
          ),
        ],
      ),
    );
    if (!mounted) return;
    switch (action) {
      case _TerminalMenuAction.copy:
        final current = _terminalController.selection ?? selection;
        if (current != null) {
          await Clipboard.setData(
            ClipboardData(text: terminal.buffer.getText(current)),
          );
          _terminalController.clearSelection();
        }
      case _TerminalMenuAction.paste:
        await _pasteClipboard();
      case _TerminalMenuAction.selectAll:
        final buffer = terminal.buffer;
        _terminalController.setSelection(
          buffer.createAnchor(0, buffer.height - terminal.viewHeight),
          buffer.createAnchor(terminal.viewWidth, buffer.height - 1),
        );
      case null:
        break;
    }
    widget.focusNode?.requestFocus();
  }

  /// The logical line under [offset] with soft-wrapped rows joined, so a
  /// path or link broken across rows is still recognized, and the tapped
  /// column translated into it. Earlier rows are padded back to full width
  /// because getText() trims trailing blanks.
  ({String text, int column})? _logicalLineAt(CellOffset offset) {
    final terminal = widget.session.terminal;
    final lines = terminal.buffer.lines;
    if (offset.y < 0 || offset.y >= lines.length) {
      return null;
    }
    var first = offset.y;
    while (first > 0 &&
        offset.y - first < _maxWrappedRows &&
        lines[first].isWrapped) {
      first--;
    }
    final buffer = StringBuffer();
    var column = offset.x;
    for (var row = first; row < lines.length; row++) {
      if (row != first && !lines[row].isWrapped) {
        break;
      }
      if (row - first >= _maxWrappedRows) {
        break;
      }
      var text = lines[row].getText();
      if (row < offset.y) {
        text = text.padRight(terminal.viewWidth);
        column += terminal.viewWidth;
      }
      buffer.write(text);
    }
    return (text: buffer.toString(), column: column);
  }

  // Long press on a link. The terminal's own long press (word selection)
  // lives inside TerminalView's gesture arena; a raw Listener watches the
  // same pointer without competing, so selection keeps working and the
  // link menu opens on top of it.
  void _handlePointerDown(PointerDownEvent event) {
    _lastButtons = event.buttons;
    _pointersDown += 1;
    // Any touch catches a running fling, as in a scroll view.
    _stopMomentum();
    if (_pointersDown > 1) {
      // Two fingers belong to the gesture layer (pinch, two-finger
      // scrollback, Herdr swipes), not to a one-finger drag.
      _remoteDrag?.yieldToMultiTouch();
    }
    // A second finger (pinch, two-finger scroll) is never a long press.
    final multiTouch = _longPressPointer != null;
    _cancelLongPress();
    if (multiTouch || widget.onLinkLongPress == null || widget.tmuxScrollMode) {
      return;
    }
    _longPressPointer = event.pointer;
    _longPressOrigin = event.position;
    _longPressTimer = Timer(kLongPressTimeout, () {
      final origin = _longPressOrigin;
      _longPressPointer = null;
      if (origin != null) {
        unawaited(_handleLinkLongPress(origin));
      }
    });
  }

  void _handlePointerMove(PointerMoveEvent event) {
    final origin = _longPressOrigin;
    if (event.pointer == _longPressPointer &&
        origin != null &&
        (event.position - origin).distance > kTouchSlop) {
      _cancelLongPress();
    }
  }

  void _handlePointerEnd(PointerEvent event) {
    if (_pointersDown > 0) {
      _pointersDown -= 1;
    }
    if (event.pointer == _longPressPointer) {
      _cancelLongPress();
    }
  }

  void _cancelLongPress() {
    _longPressTimer?.cancel();
    _longPressTimer = null;
    _longPressPointer = null;
    _longPressOrigin = null;
  }

  Future<void> _handleLinkLongPress(Offset globalPosition) async {
    final onLinkLongPress = widget.onLinkLongPress;
    final render = _viewKey.currentState?.renderTerminal;
    if (onLinkLongPress == null || render == null || !render.attached) {
      return;
    }
    final offset = render.getCellOffset(render.globalToLocal(globalPosition));
    final line = _logicalLineAt(offset);
    if (line == null) {
      return;
    }
    final url = terminalUrlAt(line.text, line.column);
    if (url == null) {
      return;
    }
    final acted = await onLinkLongPress(url, line.text.trimRight());
    if (acted && mounted) {
      _terminalController.clearSelection();
    }
  }

  /// Decides at pointer down whether this drag is the remote program's.
  bool _claimRemoteDrag(PointerEvent event) {
    if (!widget.dragScrollsRemote ||
        widget.tmuxScrollMode ||
        _pointersDown > 0 ||
        event.kind != PointerDeviceKind.touch) {
      return false;
    }
    final terminal = widget.session.terminal;
    _remoteRoute = remoteScrollRouteFor(
      mouseMode: terminal.mouseMode,
      altBuffer: terminal.isUsingAltBuffer,
      alternateScroll: terminal.altBufferMouseScrollMode,
      multiplexer: widget.onEnterScrollMode != null,
    );
    return _remoteRoute != RemoteScrollRoute.local;
  }

  void _handleRemoteDragStart(DragStartDetails details) {
    _remoteScroll.reset();
    _remoteDragPosition = details.globalPosition;
    if (_remoteRoute == RemoteScrollRoute.copyMode) {
      // The same path as the two-finger scrollback: the multiplexer's
      // copy mode keys, then the page's scroll-mode state. The rest of
      // this drag scrolls there with arrows.
      _dragEnteredScrollMode = true;
      _remoteRoute = RemoteScrollRoute.arrows;
      widget.onEnterScrollMode?.call();
    }
  }

  void _handleRemoteDragUpdate(DragUpdateDetails details) {
    _remoteDragPosition = details.globalPosition;
    _sendRemoteScroll(_remoteScroll.add(details.delta.dy));
  }

  void _handleRemoteDragEnd(DragEndDetails details) {
    _remoteScroll.reset();
    _startMomentum(remoteScrollMomentum(details.primaryVelocity ?? 0));
  }

  /// Sends the notches of a fling's [schedule], one per tick.
  void _startMomentum(List<int> schedule) {
    if (schedule.isEmpty) {
      return;
    }
    var index = 0;
    _momentumTimer?.cancel();
    _momentumTimer = Timer.periodic(momentumTick, (timer) {
      if (!mounted || index >= schedule.length) {
        timer.cancel();
        return;
      }
      _sendRemoteScroll(schedule[index]);
      index += 1;
    });
  }

  void _stopMomentum() {
    _momentumTimer?.cancel();
    _momentumTimer = null;
  }

  /// Desktop: where a mouse wheel or trackpad scroll goes, like a native
  /// terminal: to the program as wheel reports when it asked for mouse
  /// reports (Herdr, tmux with `mouse on`, vim), as arrow keys on the
  /// alternate screen otherwise, and to the local scrollback on the main
  /// screen. A multiplexer without mouse reports gets its copy mode, as
  /// for a drag on a phone ([RemoteScrollRoute.copyMode]).
  RemoteScrollRoute _desktopScrollRoute() {
    final terminal = widget.session.terminal;
    final route = remoteScrollRouteFor(
      mouseMode: terminal.mouseMode,
      altBuffer: terminal.isUsingAltBuffer,
      alternateScroll: terminal.altBufferMouseScrollMode,
      multiplexer: widget.onEnterScrollMode != null,
    );
    if (route == RemoteScrollRoute.copyMode && widget.tmuxScrollMode) {
      // Already in copy mode: arrows scroll there.
      return RemoteScrollRoute.arrows;
    }
    return route;
  }

  /// Starts a wheel or trackpad scroll of the remote program at
  /// [globalPosition] by [route], entering copy mode first if need be.
  void _beginDesktopScroll(RemoteScrollRoute route, Offset globalPosition) {
    _stopMomentum();
    _remoteDragPosition = globalPosition;
    if (route == RemoteScrollRoute.copyMode) {
      _dragEnteredScrollMode = true;
      route = RemoteScrollRoute.arrows;
      widget.onEnterScrollMode?.call();
    }
    _remoteRoute = route;
  }

  /// Desktop mouse wheel. The terminal's own scrollables would send
  /// Shift+wheel to the program (see [encodeWheelEvent]) and one report
  /// per line of travel; this sits above them, so it claims the event
  /// first whenever the program, not the scrollback, should scroll.
  void _handleDesktopWheel(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || isWheelZoomModifierPressed) return;
    final route = _desktopScrollRoute();
    if (route == RemoteScrollRoute.local) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (event) {
      final scroll = event as PointerScrollEvent;
      if (scroll.scrollDelta.dy == 0) return;
      _beginDesktopScroll(route, scroll.position);
      // Wheel up (a negative delta) shows older output, like a finger
      // moving down: a positive notch.
      _sendDesktopScroll(_desktopScroll.add(-scroll.scrollDelta.dy));
    });
  }

  bool _claimTrackpadScroll() =>
      _desktopScrollRoute() != RemoteScrollRoute.local;

  void _handleTrackpadStart(DragStartDetails details) {
    _desktopScroll.reset();
    _beginDesktopScroll(_desktopScrollRoute(), details.globalPosition);
  }

  void _handleTrackpadUpdate(DragUpdateDetails details) {
    _remoteDragPosition = details.globalPosition;
    _sendDesktopScroll(_desktopScroll.add(details.delta.dy));
  }

  /// One wheel report per notch (the program picks its own step), or the
  /// lines of a notch as arrow presses.
  void _sendDesktopScroll(int notches) {
    _sendRemoteScroll(
      _remoteRoute == RemoteScrollRoute.arrows
          ? notches * desktopArrowsPerNotch
          : notches,
    );
  }

  void _handleTrackpadEnd(DragEndDetails details) {
    _desktopScroll.reset();
    // The fling after the fingers lift, as the scrollback has.
    final schedule = remoteScrollMomentum(
      details.primaryVelocity ?? 0,
      step: desktopWheelStep,
    );
    _startMomentum(
      _remoteRoute == RemoteScrollRoute.arrows
          ? [for (final notches in schedule) notches * desktopArrowsPerNotch]
          : schedule,
    );
  }

  /// Sends [notches] of scrolling (positive: up, towards older output) by
  /// the route chosen for this drag.
  void _sendRemoteScroll(int notches) {
    if (notches == 0) {
      return;
    }
    final terminal = widget.session.terminal;
    final up = notches > 0;
    final count = notches.abs();
    if (_remoteRoute == RemoteScrollRoute.wheel) {
      if (!terminal.mouseMode.reportScroll) {
        // The program switched mouse reports off mid-drag.
        _stopMomentum();
        return;
      }
      final cell = _remoteCell(_remoteDragPosition);
      final notch = encodeWheelEvent(
        up: up,
        column: cell.x,
        row: cell.y,
        mode: terminal.mouseReportMode,
      );
      // Straight to the terminal's output: a sticky Ctrl or Alt on the
      // keyboard bar is for the next key, not for the wheel.
      terminal.textInput(notch * count);
      return;
    }
    // Arrow keys follow the cursor-key mode (ESC O A in vim and less).
    final arrow = encodeScrollArrow(
      up: up,
      applicationCursorKeys: terminal.cursorKeysMode,
    );
    terminal.textInput(arrow * count);
  }

  /// The screen cell (zero-based column and row of the visible screen)
  /// under [globalPosition].
  CellOffset _remoteCell(Offset globalPosition) {
    final terminal = widget.session.terminal;
    final render = _viewKey.currentState?.renderTerminal;
    if (render == null || !render.attached) {
      return const CellOffset(0, 0);
    }
    final cell = render.getCellOffset(render.globalToLocal(globalPosition));
    return CellOffset(
      cell.x.clamp(0, terminal.viewWidth - 1),
      (cell.y - terminal.buffer.scrollBack).clamp(0, terminal.viewHeight - 1),
    );
  }

  void _leaveDragScrollMode() {
    _dragEnteredScrollMode = false;
    widget.session.sendText('q');
    widget.onExitTmuxScrollMode();
  }

  /// The terminal's shortcuts (the desktop set on Linux, Windows and
  /// macOS) with paste routed to [_pasteClipboard].
  static Map<ShortcutActivator, Intent> _imageAwareShortcuts() => {
    for (final entry
        in (desktopTerminalShortcuts() ?? defaultTerminalShortcuts).entries)
      entry.key: entry.value is PasteTextIntent
          ? const _PasteClipboardIntent()
          : entry.value,
  };

  Future<void> _pasteClipboard() async {
    if (await widget.onPasteImage?.call() ?? false) return;
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text != null && text.isNotEmpty && mounted) {
      widget.session.paste(text);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Actions(
      actions: {
        _PasteClipboardIntent: CallbackAction<_PasteClipboardIntent>(
          onInvoke: (_) => _pasteClipboard(),
        ),
      },
      child: _buildSurface(context),
    );
  }

  Widget _buildSurface(BuildContext context) {
    return ClipRect(
      child: Stack(
        children: [
          Listener(
            behavior: HitTestBehavior.translucent,
            onPointerHover: PlatformFeatures.isDesktop ? _handleHover : null,
            onPointerDown: _handlePointerDown,
            onPointerMove: _handlePointerMove,
            onPointerUp: _handlePointerEnd,
            onPointerCancel: _handlePointerEnd,
            // Output lays the terminal out again and repaints it every
            // frame while a program prints. Tight constraints make it a
            // relayout boundary and the RepaintBoundary a paint one, so
            // that work stops at the terminal instead of reaching the
            // chrome around it (toolbars, tabs, the shell's other panes).
            child: RepaintBoundary(
              child: SizedBox.expand(
                child: ListenableBuilder(
                  listenable: widget.session.terminalPaintListenable,
                  builder: (context, _) {
                    final overlays = widget.session.overlays;
                    return TerminalView(
                      widget.session.terminal,
                      key: _viewKey,
                      shortcuts: widget.onPasteImage == null
                          ? desktopTerminalShortcuts()
                          : _imageAwareShortcuts(),
                      controller: _terminalController,
                      onTapUp: _handleTapUp,
                      onSecondaryTapUp: PlatformFeatures.isDesktop
                          ? (details, offset) => unawaited(
                              _handleSecondaryTapUp(details, offset),
                            )
                          : null,
                      mouseCursor: _hoveringLink
                          ? SystemMouseCursors.click
                          : SystemMouseCursors.text,
                      focusNode: widget.focusNode,
                      onKeyEvent: widget.onKeyEvent,
                      autofocus: widget.focusNode != null,
                      deleteDetection: true,
                      keyboardType: TextInputType.visiblePassword,
                      theme: widget.palette.terminalThemeFor(widget.brightness),
                      overlays: overlays,
                      textStyle: TerminalStyle(
                        fontFamily: widget.fontFamily,
                        fontSize: widget.fontSize,
                      ),
                      padding: const EdgeInsets.fromLTRB(0, 6, 0, 4),
                      cursorType: overlays.isEmpty
                          ? TerminalCursorType.block
                          : TerminalCursorType.verticalBar,
                      alwaysShowCursor: true,
                      simulateScroll: !widget.tmuxScrollMode,
                    );
                  },
                ),
              ),
            ),
          ),
          if (PlatformFeatures.isDesktop)
            // Above the terminal view so it claims wheel and trackpad
            // scrolls that belong to the remote program before the view's
            // scrollables do. Local scrollback, clicks and selection pass
            // through untouched.
            Positioned.fill(
              child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerSignal: _handleDesktopWheel,
                child: RawGestureDetector(
                  behavior: HitTestBehavior.translucent,
                  gestures: {
                    _TrackpadScrollRecognizer:
                        GestureRecognizerFactoryWithHandlers<
                          _TrackpadScrollRecognizer
                        >(
                          () => _TrackpadScrollRecognizer(
                            claim: _claimTrackpadScroll,
                          ),
                          (recognizer) => recognizer
                            ..onStart = _handleTrackpadStart
                            ..onUpdate = _handleTrackpadUpdate
                            ..onEnd = _handleTrackpadEnd
                            ..onCancel = _desktopScroll.reset,
                        ),
                  },
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          if (widget.dragScrollsRemote)
            // Above the terminal view so it sees each move first: the
            // view's own scrollables would otherwise take the drag and, on
            // the alternate screen, send Shift+wheel (see
            // encodeWheelEvent). It only joins the arena for drags that
            // belong to the remote program, so local scrollback, taps and
            // long-press selection behave as before. It stays mounted in
            // scroll mode (declining every drag there) so a drag that
            // enters copy mode keeps going.
            Positioned.fill(
              child: RawGestureDetector(
                behavior: HitTestBehavior.translucent,
                gestures: {
                  _RemoteScrollDragRecognizer:
                      GestureRecognizerFactoryWithHandlers<
                        _RemoteScrollDragRecognizer
                      >(
                        () => _RemoteScrollDragRecognizer(
                          claim: _claimRemoteDrag,
                        ),
                        (recognizer) => _remoteDrag = recognizer
                          ..onStart = _handleRemoteDragStart
                          ..onUpdate = _handleRemoteDragUpdate
                          ..onEnd = _handleRemoteDragEnd
                          ..onCancel = _remoteScroll.reset,
                      ),
                },
                child: const SizedBox.expand(),
              ),
            ),
          if (widget.tmuxScrollMode)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onVerticalDragUpdate: _handleTmuxScrollDrag,
                onVerticalDragEnd: _handleTmuxScrollEnd,
                // Copy mode a drag opened on its own closes with a tap.
                onTap: _dragEnteredScrollMode ? _leaveDragScrollMode : null,
                child: const SizedBox.expand(),
              ),
            ),
        ],
      ),
    );
  }
}

/// A vertical drag that only takes pointers [claim] accepts, and steps
/// aside when a second finger lands before it has won.
class _RemoteScrollDragRecognizer extends VerticalDragGestureRecognizer {
  _RemoteScrollDragRecognizer({required this.claim})
    : super(supportedDevices: const {PointerDeviceKind.touch});

  final bool Function(PointerEvent event) claim;
  bool _dragging = false;

  @override
  bool isPointerAllowed(PointerEvent event) =>
      super.isPointerAllowed(event) && claim(event);

  @override
  void acceptGesture(int pointer) {
    _dragging = true;
    super.acceptGesture(pointer);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    _dragging = false;
    super.didStopTrackingLastPointer(pointer);
  }

  /// Gives the pointer up unless the drag already started.
  void yieldToMultiTouch() {
    if (!_dragging) {
      resolve(GestureDisposition.rejected);
    }
  }
}

/// A two-finger trackpad scroll (a pan/zoom gesture) that only starts when
/// [claim] says the remote program should scroll.
class _TrackpadScrollRecognizer extends VerticalDragGestureRecognizer {
  _TrackpadScrollRecognizer({required this.claim})
    : super(supportedDevices: const {PointerDeviceKind.trackpad});

  final bool Function() claim;

  @override
  bool isPointerPanZoomAllowed(PointerPanZoomStartEvent event) =>
      super.isPointerPanZoomAllowed(event) && claim();
}

enum _TerminalMenuAction { copy, paste, selectAll }

/// Paste from a key shortcut, handled by [TerminalSurface] so an image on
/// the clipboard can be uploaded instead of ignored.
class _PasteClipboardIntent extends Intent {
  const _PasteClipboardIntent();
}
