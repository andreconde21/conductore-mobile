import 'dart:async';

import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/features/prompt_menus/domain/prompt_menu_detector.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:conduit_vt/conduit_vt.dart';
import 'package:flutter/material.dart';

/// A compact row of buttons for the choice prompt currently on screen.
///
/// Watches the session's terminal, re-runs [detectPromptMenu] over the
/// visible rows after output settles, and shows one button per option plus
/// an Esc chip when the prompt mentions it. Tapping a button sends the
/// keystrokes the prompt expects and hides the strip until the screen moves
/// on, so a double tap cannot answer twice. The strip collapses to nothing
/// when no prompt is visible.
class PromptMenuStrip extends StatefulWidget {
  const PromptMenuStrip({
    required this.session,
    required this.palette,
    required this.brightness,
    this.onSent,
    this.debounce = defaultDebounce,
    super.key,
  });

  static const defaultDebounce = Duration(milliseconds: 150);

  /// How long an answered menu stays hidden while the screen is unchanged,
  /// after which it is offered again in case the keystrokes were lost.
  static const answeredGrace = Duration(seconds: 2);

  final TerminalSessionController session;
  final AppPalette palette;
  final Brightness brightness;

  /// Called after keystrokes were sent, so the page can return focus to the
  /// terminal.
  final VoidCallback? onSent;

  /// Delay between the last screen update and the next detection pass.
  final Duration debounce;

  @override
  State<PromptMenuStrip> createState() => _PromptMenuStripState();
}

class _PromptMenuStripState extends State<PromptMenuStrip> {
  PromptMenu? _menu;
  PromptMenu? _answered;
  Timer? _debounceTimer;
  Timer? _graceTimer;

  @override
  void initState() {
    super.initState();
    _listen(widget.session);
    _scan();
  }

  @override
  void didUpdateWidget(covariant PromptMenuStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) {
      _unlisten(oldWidget.session);
      _listen(widget.session);
      _answered = null;
      _scan();
    }
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _graceTimer?.cancel();
    _unlisten(widget.session);
    super.dispose();
  }

  void _listen(TerminalSessionController session) {
    session.terminal.addListener(_scheduleScan);
    session.addListener(_scheduleScan);
  }

  void _unlisten(TerminalSessionController session) {
    session.terminal.removeListener(_scheduleScan);
    session.removeListener(_scheduleScan);
  }

  void _scheduleScan() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(widget.debounce, _scan);
  }

  /// The visible rows of the active buffer, top to bottom.
  static List<String> visibleRows(Terminal terminal) {
    final buffer = terminal.buffer;
    final lines = buffer.lines;
    final start = buffer.scrollBack.clamp(0, lines.length);
    return [
      for (var row = start; row < lines.length; row++) lines[row].getText(),
    ];
  }

  void _scan() {
    _debounceTimer = null;
    if (!mounted) {
      return;
    }
    final terminal = widget.session.terminal;
    PromptMenu? menu;
    if (widget.session.isConnected) {
      try {
        menu = detectPromptMenu(
          visibleRows(terminal),
          cursorRow: terminal.buffer.cursorY,
        );
      } catch (error, stack) {
        // Menu buttons are a convenience: an unexpected screen must never
        // take the terminal page down. Report it and show no strip.
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stack,
            library: 'prompt menus',
            context: ErrorDescription('while detecting a prompt menu'),
          ),
        );
      }
    }
    if (_answered != null && menu != _answered) {
      // The screen moved on from the menu that was answered.
      _answered = null;
      _graceTimer?.cancel();
      _graceTimer = null;
    }
    if (menu == _menu) {
      return;
    }
    setState(() => _menu = menu);
  }

  void _choose(PromptMenu menu, PromptMenuOption option) {
    _send(menu, menu.keystrokesFor(option));
  }

  /// Answers through [TerminalSessionController.sendAppText] and
  /// [TerminalSessionController.sendAppKeys], in order: an answer typed
  /// into another Herdr workspace would answer the wrong agent, and those
  /// reach the session's own pane (or take its focus back first).
  static Future<void> _deliver(
    TerminalSessionController session,
    List<PromptMenuKeystroke> keystrokes,
  ) async {
    final keys = <TerminalKey>[];
    Future<void> flushKeys() async {
      if (keys.isEmpty) return;
      final batch = List.of(keys);
      keys.clear();
      await session.sendAppKeys(batch);
    }

    for (final keystroke in keystrokes) {
      switch (keystroke) {
        case PromptMenuText(:final text):
          await flushKeys();
          await session.sendAppText(text);
        case PromptMenuKey.enter:
          keys.add(TerminalKey.enter);
        case PromptMenuKey.arrowUp:
          keys.add(TerminalKey.arrowUp);
        case PromptMenuKey.arrowDown:
          keys.add(TerminalKey.arrowDown);
        case PromptMenuKey.escape:
          keys.add(TerminalKey.escape);
      }
    }
    await flushKeys();
  }

  void _escape(PromptMenu menu) {
    _send(menu, const [PromptMenuKey.escape]);
  }

  void _send(PromptMenu menu, List<PromptMenuKeystroke> keystrokes) {
    unawaited(_deliver(widget.session, keystrokes));
    setState(() => _answered = menu);
    _graceTimer?.cancel();
    _graceTimer = Timer(PromptMenuStrip.answeredGrace, () {
      _graceTimer = null;
      if (!mounted || _answered == null) {
        return;
      }
      // Still the same screen: the answer may not have landed. Offer again.
      setState(() => _answered = null);
    });
    widget.onSent?.call();
  }

  @override
  Widget build(BuildContext context) {
    final menu = _menu;
    if (menu == null || menu == _answered) {
      return const SizedBox.shrink();
    }
    final palette = widget.palette;
    final brightness = widget.brightness;
    return Material(
      color: palette.panelFor(brightness),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(6, 5, 6, 5),
        // Every option stays on screen: chips wrap onto a second row
        // instead of scrolling off the right edge of a phone.
        child: Wrap(
          key: const ValueKey('prompt-menu-chips'),
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 2),
              child: Icon(
                Icons.list_alt_rounded,
                size: 16,
                color: palette.mutedForegroundFor(brightness),
              ),
            ),
            for (final option in menu.options)
              _MenuButton(
                palette: palette,
                brightness: brightness,
                label: _captionFor(menu, option),
                detail: option.text,
                selected: option.selected,
                onPressed: () => _choose(menu, option),
              ),
            if (menu.hasEscape)
              _MenuButton(
                palette: palette,
                brightness: brightness,
                label: 'Esc',
                detail: 'Send Escape',
                onPressed: () => _escape(menu),
              ),
          ],
        ),
      ),
    );
  }

  static String _captionFor(PromptMenu menu, PromptMenuOption option) {
    switch (menu.input) {
      case PromptMenuInput.digit:
      case PromptMenuInput.digitEnter:
        return '${option.index + 1}  ${compactPromptLabel(option.label)}';
      case PromptMenuInput.arrows:
      case PromptMenuInput.word:
        return compactPromptLabel(option.label);
    }
  }
}

/// A chip-sized caption for a menu option: short labels stay as they are;
/// longer ones drop the filler "and" after a comma, then parenthesised
/// hints, then are cut at a word boundary within [maxChars]. The full text
/// is one long-press away.
String compactPromptLabel(String label, {int maxChars = 22}) {
  var text = label.trim();
  if (text.endsWith('…')) {
    text = text.substring(0, text.length - 1).trimRight();
  }
  final cut = text.length != label.trim().length;
  if (!cut && text.length <= maxChars) {
    return text;
  }
  text = text
      .replaceAll(RegExp(r',\s+and\s+', caseSensitive: false), ', ')
      .replaceAll(RegExp(r'\s+'), ' ');
  if (text.length > maxChars) {
    text = text
        .replaceAll(RegExp(r'\s*\([^)]*\)'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }
  if (text.length <= maxChars) {
    return cut ? '$text…' : text;
  }
  var end = text.lastIndexOf(' ', maxChars);
  if (end <= 0) {
    end = maxChars;
  }
  final head = text.substring(0, end).replaceAll(RegExp(r'[\s,;:.\-–—]+$'), '');
  return '$head…';
}

class _MenuButton extends StatelessWidget {
  const _MenuButton({
    required this.palette,
    required this.brightness,
    required this.label,
    required this.detail,
    required this.onPressed,
    this.selected = false,
  });

  final AppPalette palette;
  final Brightness brightness;
  final String label;
  final String detail;
  final bool selected;
  final VoidCallback onPressed;

  static const _maxWidth = 200.0;

  @override
  Widget build(BuildContext context) {
    final foreground = selected
        ? palette.accent
        : palette.foregroundFor(brightness);
    final background = selected
        ? Color.alphaBlend(
            palette.accent.withValues(alpha: 0.22),
            palette.panelFor(brightness),
          )
        : palette.panelElevatedFor(brightness);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: Tooltip(
        message: detail,
        triggerMode: TooltipTriggerMode.longPress,
        showDuration: const Duration(seconds: 4),
        child: Material(
          color: background,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: onPressed,
            child: Container(
              constraints: const BoxConstraints(
                minWidth: 40,
                maxWidth: _maxWidth,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: selected
                      ? palette.accent.withValues(alpha: 0.7)
                      : palette.hairlineFor(brightness),
                  width: selected ? 1.3 : 1,
                ),
              ),
              child: Text(
                label,
                style: TextStyle(
                  color: foreground,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                softWrap: false,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
