import 'dart:async';

import 'package:conduit/core/platform_features.dart';
import 'package:conduit/core/presentation/multiplexer_icon.dart';
import 'package:conduit/core/presentation/system_navigation_insets.dart';
import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/core/theme/app_theme.dart';
import 'package:conduit/core/theme/terminal_appearance.dart';
import 'package:conduit/core/theme/terminal_pill_items.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/live/presentation/live_host_hub.dart';
import 'package:conduit/features/snippets/domain/terminal_snippet.dart';
import 'package:conduit/features/terminal/presentation/multiplexer_pill_actions.dart';
import 'package:conduit/features/terminal/presentation/terminal_keyboard_bar.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:conduit/features/terminal/presentation/widgets/pill_configurator_sheet.dart';
import 'package:conduit/features/terminal/presentation/widgets/toolbar_arrow_pad.dart';
import 'package:conduit/features/terminal/presentation/widgets/toolbar_snippet_palette.dart';
import 'package:conduit_vt/conduit_vt.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Height of the pill itself, buttons included.
const floatingToolbarPillHeight = 40.0;

/// Height and width of an icon button inside the pill.
const floatingToolbarButtonSize = 36.0;

/// Gap between the pill and whatever is below it (the navigation bar or the
/// soft keyboard).
const floatingToolbarBottomGap = 8.0;

/// Runs non-interactive commands on a host (the Herdr pane list).
typedef PillCommandRunnerFactory = AgentCommandRunner Function(SavedHost host);

/// Delay between a quick prompt's text and its Enter, kept as a separate
/// write so TUIs do not classify the line as a paste (see the compose bar).
const floatingToolbarSubmitDelay = Duration(milliseconds: 120);

/// Moshi-style floating input toolbar: a rounded pill of the keys that drive
/// an agent session from a phone, sitting above the soft keyboard and clear
/// of the Android navigation bar.
///
/// The pill wraps the classic [TerminalKeyboardBar] ([keyRows]) rather than
/// replacing it: the ⋯ button expands the configured key rows inline above
/// the pill, so custom keys and the Herdr, Tmux, Touch and Snip menus stay
/// one tap away. Session, focus and palette come from [keyRows] too, so the
/// page passes a single, already configured bar.
///
/// Gestures:
/// * Ctrl: tap arms ctrl for the next key; long-press latches it until the
///   next tap on Ctrl.
/// * Esc: tap sends Escape; long-press sends Ctrl+C.
/// * Tab: tap sends Tab; long-press sends Shift+Tab (Claude Code cycles its
///   permission mode with it).
/// * ^L: tap redraws the screen (Ctrl+L); long-press reconnects the
///   session. The ↻ glyph is kept for Reconnect, as everywhere else.
/// * Herdr: opens the pane switcher and Herdr shortcuts.
/// * Long-press the pill (or ⋯): choose and order the buttons.
///
/// There is no swipe on the pill (CON-106): the quick prompt and snippet
/// palette opens from the Snippets button, and the mic is in the chat
/// line.
class FloatingTerminalToolbar extends StatefulWidget {
  const FloatingTerminalToolbar({
    required this.keyRows,
    this.onReconnect,
    this.items = defaultTerminalPillItems,
    this.onItemsChanged,
    this.runnerFactory,
    this.liveFeed,
    super.key,
  });

  /// The classic key-row bar for this session, shown behind the ⋯ button.
  final TerminalKeyboardBar keyRows;

  /// Long-press on the ^L button. When null the button only redraws.
  final Future<void> Function()? onReconnect;

  /// The buttons to show, in order; the ⋯ button always follows.
  final List<TerminalPillItem> items;

  /// Saves the configurator's result. When null the pill cannot be
  /// configured.
  final ValueChanged<List<TerminalPillItem>>? onItemsChanged;

  /// Opens the command channel the Herdr pane list runs over. Null limits
  /// the Herdr navigator to its shortcuts.
  final PillCommandRunnerFactory? runnerFactory;

  /// The machine's pushed Herdr state, when its companion pushes it: the
  /// navigator lists from it instead of running `herdr` commands.
  final LiveHostFeed? Function(SavedHost host)? liveFeed;

  @override
  State<FloatingTerminalToolbar> createState() =>
      _FloatingTerminalToolbarState();
}

class _FloatingTerminalToolbarState extends State<FloatingTerminalToolbar>
    with WidgetsBindingObserver, MultiplexerPillActions {
  bool _rowsExpanded = false;

  /// Set when the user hid the soft keyboard from the pill: key presses then
  /// stop re-requesting focus, which would pop the keyboard straight back.
  bool _keyboardHidden = false;

  TerminalSessionController get _controller => widget.keyRows.controller;
  FocusNode get _focusNode => widget.keyRows.focusNode;
  AppPalette get _palette => widget.keyRows.palette;
  Brightness get _brightness => widget.keyRows.brightness;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    // The soft keyboard changes the view insets; the Scaffold strips those
    // from the body's MediaQuery, so watch the raw view instead.
    setState(() {});
  }

  bool get _keyboardVisible => View.of(context).viewInsets.bottom > 0;

  @override
  Widget build(BuildContext context) {
    final keyboardVisible = _keyboardVisible;
    if (keyboardVisible && _keyboardHidden) {
      // The keyboard came back by other means (a tap on the terminal), so
      // the pill no longer needs to keep it away.
      _keyboardHidden = false;
    }
    return ListenableBuilder(
      listenable: _controller.keyboard,
      builder: (context, _) {
        return DecoratedBox(
          decoration: BoxDecoration(color: _palette.canvasFor(_brightness)),
          child: SafeArea(
            top: false,
            bottom: shouldApplyBottomSafeArea(context),
            left: false,
            right: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_rowsExpanded)
                  MediaQuery.removePadding(
                    context: context,
                    removeBottom: true,
                    child: widget.keyRows,
                  ),
                GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onLongPress: widget.onItemsChanged == null
                      ? null
                      : _openConfigurator,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      8,
                      4,
                      8,
                      floatingToolbarBottomGap,
                    ),
                    child: _buildPill(context, keyboardVisible),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildPill(BuildContext context, bool keyboardVisible) {
    final buttons = <Widget>[
      for (final item in widget.items) ?_buildItem(item, keyboardVisible),
      _PillButton(
        key: const ValueKey('toolbar-more'),
        icon: Icons.more_horiz_rounded,
        tooltip: _rowsExpanded
            ? 'Hide key rows. Long-press to customize'
            : 'Show key rows. Long-press to customize',
        palette: _palette,
        brightness: _brightness,
        selected: _rowsExpanded,
        onTap: () => setState(() => _rowsExpanded = !_rowsExpanded),
        onLongPress: widget.onItemsChanged == null ? null : _openConfigurator,
      ),
    ];
    return Material(
      key: const ValueKey('floating-toolbar-pill'),
      color: _palette.panelFor(_brightness).withValues(alpha: 0.9),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radius),
        side: BorderSide(color: _palette.hairlineFor(_brightness)),
      ),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        height: floatingToolbarPillHeight,
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Narrow phones and landscape with system insets: scroll the
            // pill sideways instead of squeezing the buttons below a
            // finger's width.
            return SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minWidth: (constraints.maxWidth - 12).clamp(
                    0,
                    double.infinity,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    for (final (index, button) in buttons.indexed) ...[
                      if (index > 0) const SizedBox(width: 2),
                      button,
                    ],
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget? _buildItem(TerminalPillItem item, bool keyboardVisible) {
    final customKeyId = item.customKeyId;
    if (customKeyId != null) {
      final key = _customKey(customKeyId);
      if (key == null) {
        return null;
      }
      return KeyedSubtree(
        key: ValueKey('toolbar-custom-$customKeyId'),
        child: widget.keyRows.buildKey(key),
      );
    }
    final keyboard = _controller.keyboard;
    return switch (item.button!) {
      TerminalPillButton.ctrl => _PillButton(
        key: const ValueKey('toolbar-ctrl'),
        label: 'Ctrl',
        tooltip: 'Ctrl. Long-press to latch',
        palette: _palette,
        brightness: _brightness,
        selected: keyboard.ctrl,
        emphasized: keyboard.ctrlLatched,
        onTap: _tapCtrl,
        onLongPress: _latchCtrl,
      ),
      TerminalPillButton.esc => _PillButton(
        key: const ValueKey('toolbar-esc'),
        label: 'Esc',
        tooltip: 'Escape. Long-press for Ctrl+C',
        palette: _palette,
        brightness: _brightness,
        onTap: () => _sendKey(TerminalKey.escape),
        onLongPress: () => _sendControl(TerminalKey.keyC),
      ),
      TerminalPillButton.tab => _PillButton(
        key: const ValueKey('toolbar-tab'),
        label: 'Tab',
        tooltip: 'Tab. Long-press for Shift+Tab',
        palette: _palette,
        brightness: _brightness,
        onTap: () => _sendKey(TerminalKey.tab),
        onLongPress: () => _sendKey(TerminalKey.backtab),
      ),
      TerminalPillButton.arrows => ToolbarArrowPad(
        key: const ValueKey('toolbar-arrows'),
        palette: _palette,
        brightness: _brightness,
        size: const Size(40, floatingToolbarButtonSize),
        onArrow: _sendKey,
      ),
      TerminalPillButton.herdr => Builder(
        key: const ValueKey('toolbar-herdr'),
        builder: (buttonContext) {
          final tmux = pillMultiplexer == PillMultiplexer.tmux;
          return _PillButton(
            logo: MultiplexerIcon(
              tmux ? MultiplexerKind.tmux : MultiplexerKind.herdr,
              size: 20,
              semanticLabel: '',
            ),
            tooltip: tmux
                ? 'tmux panes and actions. Long-press for a new pane'
                : 'Herdr panes and shortcuts. Long-press for a new pane',
            palette: _palette,
            brightness: _brightness,
            onTap: () => unawaited(openMultiplexerNavigator()),
            onLongPress: () =>
                unawaited(openMultiplexerQuickMenu(buttonContext)),
          );
        },
      ),
      TerminalPillButton.reconnect => _PillButton(
        key: const ValueKey('toolbar-redraw'),
        label: '^L',
        tooltip: widget.onReconnect == null
            ? 'Redraw screen (Ctrl+L)'
            : 'Redraw screen (Ctrl+L). Long-press to reconnect',
        palette: _palette,
        brightness: _brightness,
        onTap: () => _sendControl(TerminalKey.keyL),
        onLongPress: widget.onReconnect == null ? null : _reconnect,
      ),
      TerminalPillButton.paste => _PillButton(
        key: const ValueKey('toolbar-paste'),
        icon: Icons.content_paste_rounded,
        tooltip: 'Paste',
        palette: _palette,
        brightness: _brightness,
        onTap: _paste,
      ),
      TerminalPillButton.chat => _PillButton(
        key: const ValueKey('toolbar-chat'),
        icon: Icons.chat_bubble_outline_rounded,
        tooltip: widget.keyRows.onChatButton == null
            ? 'Chat mode'
            : 'Chat. Long-press for the composer',
        palette: _palette,
        brightness: _brightness,
        selected: widget.keyRows.composeActive,
        onTap: widget.keyRows.onChatButton ?? widget.keyRows.onToggleCompose,
        onLongPress: widget.keyRows.onChatButton == null
            ? null
            : widget.keyRows.onToggleCompose,
      ),
      TerminalPillButton.dictate =>
        widget.keyRows.onDictate == null
            ? const SizedBox.shrink(key: ValueKey('toolbar-dictate'))
            : _PillButton(
                key: const ValueKey('toolbar-dictate'),
                icon: Icons.mic_none_rounded,
                tooltip: 'Dictate into the chat line',
                palette: _palette,
                brightness: _brightness,
                onTap: widget.keyRows.onDictate,
              ),
      TerminalPillButton.keyboard => _PillButton(
        key: const ValueKey('toolbar-keyboard'),
        icon: keyboardVisible
            ? Icons.keyboard_hide_rounded
            : Icons.keyboard_rounded,
        tooltip: keyboardVisible ? 'Hide keyboard' : 'Show keyboard',
        palette: _palette,
        brightness: _brightness,
        onTap: () => _toggleKeyboard(keyboardVisible),
      ),
      TerminalPillButton.tmux => KeyedSubtree(
        key: const ValueKey('toolbar-tmux'),
        child: widget.keyRows.buildKey(
          const TerminalKeyboardItem.builtIn(TerminalKeyboardAction.tmuxMenu),
        ),
      ),
      TerminalPillButton.touch => KeyedSubtree(
        key: const ValueKey('toolbar-touch'),
        child: widget.keyRows.buildKey(
          const TerminalKeyboardItem.builtIn(TerminalKeyboardAction.touchMode),
        ),
      ),
      TerminalPillButton.snippets => _PillButton(
        key: const ValueKey('toolbar-snippets'),
        icon: Icons.bolt_rounded,
        tooltip: 'Quick prompts and snippets',
        palette: _palette,
        brightness: _brightness,
        onTap: () => unawaited(_openPalette()),
      ),
      TerminalPillButton.fullscreen => _PillButton(
        key: const ValueKey('toolbar-fullscreen'),
        icon: widget.keyRows.fullscreen
            ? Icons.fullscreen_exit_rounded
            : Icons.fullscreen_rounded,
        tooltip: widget.keyRows.fullscreen ? 'Exit fullscreen' : 'Fullscreen',
        palette: _palette,
        brightness: _brightness,
        onTap: () {
          widget.keyRows.onToggleFullscreen();
          _focusTerminal();
        },
      ),
    };
  }

  /// Custom keys defined in the key rows, the only ones the pill can host.
  List<TerminalKeyboardItem> get _customKeys => [
    for (final row in widget.keyRows.rows)
      for (final item in row.items)
        if (item.kind != TerminalKeyboardItemKind.builtIn) item,
  ];

  TerminalKeyboardItem? _customKey(String id) {
    for (final item in _customKeys) {
      if (item.id == id) {
        return item;
      }
    }
    return null;
  }

  Future<void> _openConfigurator() async {
    final onItemsChanged = widget.onItemsChanged;
    if (onItemsChanged == null) {
      return;
    }
    unawaited(HapticFeedback.mediumImpact());
    final items = await showPillConfigurator(
      context: context,
      items: widget.items,
      customKeys: _customKeys,
    );
    if (items != null) {
      onItemsChanged(items);
    }
  }

  // The multiplexer button (Herdr or tmux navigator, long-press "new pane"
  // menu) lives in MultiplexerPillActions.
  @override
  TerminalKeyboardBar get multiplexerKeyRows => widget.keyRows;

  @override
  PillCommandRunnerFactory? get multiplexerRunnerFactory =>
      widget.runnerFactory;

  @override
  LiveHostFeed? Function(SavedHost host)? get multiplexerLiveFeed =>
      widget.liveFeed;

  @override
  void focusTerminalAfterMultiplexer() => _focusTerminal();

  Future<void> _openPalette() async {
    await showToolbarSnippetPalette(
      context: context,
      palette: _palette,
      brightness: _brightness,
      hostSnippets: _controller.host.snippets,
      globalSnippets: widget.keyRows.globalSnippets,
      hostPassword: _controller.host.password,
      onQuickPrompt: _runQuickPrompt,
      onSnippet: _sendSnippet,
      onPassword: _sendText,
    );
    if (mounted) _focusTerminal();
  }

  void _runQuickPrompt(ToolbarQuickPrompt prompt) {
    final text = prompt.text;
    if (text != null) {
      _submitLine(text);
      return;
    }
    switch (prompt) {
      case ToolbarQuickPrompt.escapeTwice:
        _controller.sendKey(TerminalKey.escape);
        _controller.sendKey(TerminalKey.escape);
      case ToolbarQuickPrompt.interrupt:
        _controller.sendControl(TerminalKey.keyC);
      case ToolbarQuickPrompt.clear:
      case ToolbarQuickPrompt.compact:
      case ToolbarQuickPrompt.help:
      case ToolbarQuickPrompt.continuePrompt:
      case ToolbarQuickPrompt.yes:
        break;
    }
    _focusTerminal();
  }

  void _sendSnippet(TerminalSnippet snippet) {
    if (snippet.text.isEmpty) {
      _focusTerminal();
      return;
    }
    unawaited(_controller.sendAppText(snippet.text, submit: snippet.submit));
    _focusTerminal();
  }

  /// Types [line] and presses Enter in a separate write shortly after, the
  /// same trick the chat bar uses so readline-style TUIs treat the Enter as
  /// a keypress instead of the tail of a paste.
  void _submitLine(String line) {
    _controller.sendText(line);
    Future.delayed(floatingToolbarSubmitDelay, () {
      _controller.sendKey(TerminalKey.enter);
    });
    _focusTerminal();
  }

  void _tapCtrl() {
    final keyboard = _controller.keyboard;
    if (keyboard.ctrlLatched) {
      keyboard.ctrlLatched = false;
    } else {
      keyboard.ctrl = !keyboard.ctrl;
    }
    _focusTerminal();
  }

  void _latchCtrl() {
    final keyboard = _controller.keyboard;
    keyboard.ctrlLatched = !keyboard.ctrlLatched;
    _focusTerminal();
  }

  Future<void> _reconnect() async {
    final reconnect = widget.onReconnect;
    if (reconnect == null) {
      return;
    }
    await reconnect();
    if (mounted) {
      _focusTerminal();
    }
  }

  void _toggleKeyboard(bool keyboardVisible) {
    if (keyboardVisible) {
      _keyboardHidden = true;
      unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.hide'));
      return;
    }
    _keyboardHidden = false;
    if (_focusNode.canRequestFocus) {
      _focusNode.requestFocus();
    }
    unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.show'));
  }

  void _sendKey(TerminalKey key) {
    _controller.sendKey(key);
    _focusTerminal();
  }

  void _sendControl(TerminalKey key) {
    _controller.sendControl(key);
    _focusTerminal();
  }

  void _sendText(String text) {
    _controller.sendText(text);
    _focusTerminal();
  }

  Future<void> _paste() async {
    if (await widget.keyRows.onPasteImage?.call() ?? false) {
      _focusTerminal();
      return;
    }
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text != null && text.isNotEmpty) {
      _controller.paste(text);
    }
    _focusTerminal();
  }

  void _focusTerminal() {
    if (_keyboardHidden) {
      return;
    }
    if (_focusNode.canRequestFocus) {
      _focusNode.requestFocus();
    }
  }
}

/// Lets the terminal page keep its fully configured [TerminalKeyboardBar]
/// expression untouched and only append the style decision.
extension FloatingToolbarStyle on TerminalKeyboardBar {
  /// This bar as the user's chosen toolbar: itself for
  /// [TerminalToolbarStyle.keyRows], otherwise wrapped in the floating pill
  /// with the key rows behind the ⋯ button.
  Widget withToolbarStyle(
    TerminalToolbarStyle style, {
    Future<void> Function()? onReconnect,
    List<TerminalPillItem> pillItems = defaultTerminalPillItems,
    ValueChanged<List<TerminalPillItem>>? onPillItemsChanged,
    PillCommandRunnerFactory? runnerFactory,
    LiveHostFeed? Function(SavedHost host)? liveFeed,
  }) {
    if (style == TerminalToolbarStyle.keyRows) {
      return this;
    }
    return FloatingTerminalToolbar(
      keyRows: this,
      onReconnect: onReconnect,
      items: pillItems,
      onItemsChanged: onPillItemsChanged,
      runnerFactory: runnerFactory,
      liveFeed: liveFeed,
    );
  }
}

/// One rounded-square key inside the pill. Long-press, when wired, gives
/// haptic feedback so the alternate action is felt before it is seen.
class _PillButton extends StatelessWidget {
  const _PillButton({
    required this.palette,
    required this.brightness,
    required this.tooltip,
    this.label,
    this.icon,
    this.logo,
    this.onTap,
    this.onLongPress,
    this.selected = false,
    this.emphasized = false,
    super.key,
  });

  final AppPalette palette;
  final Brightness brightness;
  final String tooltip;
  final String? label;
  final IconData? icon;

  /// A brand logo shown instead of [icon] (the tmux or Herdr mark).
  final Widget? logo;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool selected;

  /// Stronger highlight than [selected], used for the latched Ctrl.
  final bool emphasized;

  static const _height = floatingToolbarButtonSize;
  static const _iconWidth = floatingToolbarButtonSize;
  static const _labelMinWidth = 40.0;

  @override
  Widget build(BuildContext context) {
    final accent = palette.accent;
    final enabled = onTap != null || onLongPress != null;
    final baseForeground = enabled
        ? palette.foregroundFor(brightness)
        : palette.mutedForegroundFor(brightness);
    final foreground = emphasized
        ? palette.canvasFor(brightness)
        : selected
        ? accent
        : baseForeground;
    final background = emphasized
        ? accent
        : selected
        ? Color.alphaBlend(
            accent.withValues(alpha: 0.22),
            palette.panelElevatedFor(brightness),
          )
        : palette.panelElevatedFor(brightness);
    final isIcon = icon != null || logo != null;
    // A desktop reaches the long-press action with a right-click.
    final desktop = PlatformFeatures.isDesktop;
    return Tooltip(
      message: desktop
          ? tooltip.replaceAll('Long-press', 'Right-click')
          : tooltip,
      child: Material(
        color: background,
        borderRadius: BorderRadius.circular(AppTheme.radius),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          // One deliberate haptic per long-press, below, instead of the
          // platform default that fires on top of it.
          enableFeedback: false,
          onTap: onTap,
          onLongPress: onLongPress == null
              ? null
              : () {
                  unawaited(HapticFeedback.mediumImpact());
                  onLongPress!();
                },
          onSecondaryTap: desktop ? onLongPress : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            height: _height,
            constraints: BoxConstraints(
              minWidth: isIcon ? _iconWidth : _labelMinWidth,
            ),
            padding: EdgeInsets.symmetric(horizontal: isIcon ? 0 : 6),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppTheme.radius),
              border: selected && !emphasized
                  ? Border.all(color: accent.withValues(alpha: 0.7), width: 1.2)
                  : null,
            ),
            child: isIcon
                ? logo ?? Icon(icon, color: foreground, size: 20)
                : Text(
                    label ?? '',
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.visible,
                    style: TextStyle(
                      color: foreground,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.2,
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}
