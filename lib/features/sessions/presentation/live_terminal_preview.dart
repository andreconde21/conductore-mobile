import 'dart:math' as math;

import 'package:conduit/features/sessions/presentation/terminal_preview.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:conduit_vt/conduit_vt.dart';
import 'package:flutter/material.dart';

/// Renders a [StyledTerminalPreview] the way the terminal draws it: the
/// theme's palette, bold/faint/inverse, and a monospace font scaled so the
/// whole screen width fits the available width. When the screen is taller
/// than the box, the bottom rows (where prompts and the cursor are) win.
class LiveTerminalPreview extends StatelessWidget {
  const LiveTerminalPreview({
    required this.preview,
    required this.theme,
    required this.fontFamily,
    this.lineHeight = 1.18,
    this.placeholder,
    this.placeholderColor,
    super.key,
  });

  final StyledTerminalPreview preview;
  final TerminalTheme theme;
  final String fontFamily;
  final double lineHeight;

  /// Shown centred while the screen is empty.
  final String? placeholder;
  final Color? placeholderColor;

  /// Font size that fits [columns] cells of [fontFamily] into [width].
  static double fitFontSize({
    required double width,
    required int columns,
    required String fontFamily,
  }) {
    final advance = _advanceRatio(fontFamily);
    return math.max(2, width / (math.max(1, columns) * advance));
  }

  /// Rows of [fontSize] text that fit into [height].
  static int fitRows({
    required double height,
    required double fontSize,
    double lineHeight = 1.18,
  }) => math.max(1, (height / (fontSize * lineHeight)).floor());

  static final Map<String, double> _advanceCache = {};

  /// Width of one cell per unit of font size, measured once per family.
  static double _advanceRatio(String fontFamily) {
    return _advanceCache.putIfAbsent(fontFamily, () {
      const sample = 'MMMMMMMMMMMMMMMMMMMM';
      final painter = TextPainter(
        text: TextSpan(
          text: sample,
          style: TextStyle(fontFamily: fontFamily, fontSize: 100),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      final ratio = painter.width / (sample.length * 100);
      painter.dispose();
      return ratio > 0 ? ratio : 0.6;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (preview.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Text(
            placeholder ?? 'Waiting for output…',
            textAlign: TextAlign.center,
            style: TextStyle(
              color:
                  placeholderColor ?? theme.foreground.withValues(alpha: 0.6),
              fontSize: 11,
            ),
          ),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final fontSize = fitFontSize(
          width: width,
          columns: preview.columns,
          fontFamily: fontFamily,
        );
        final rows = constraints.hasBoundedHeight
            ? fitRows(
                height: constraints.maxHeight,
                fontSize: fontSize,
                lineHeight: lineHeight,
              )
            : preview.rows.length;
        final visible = preview.rows.length > rows
            ? preview.rows.sublist(preview.rows.length - rows)
            : preview.rows;
        final colors = _PreviewColors.of(theme);
        final base = TextStyle(
          fontFamily: fontFamily,
          fontSize: fontSize,
          height: lineHeight,
          color: theme.foreground,
          leadingDistribution: TextLeadingDistribution.even,
        );
        final spans = <InlineSpan>[];
        for (var index = 0; index < visible.length; index++) {
          if (index > 0) spans.add(const TextSpan(text: '\n'));
          for (final run in visible[index]) {
            spans.add(TextSpan(text: run.text, style: colors.styleFor(run)));
          }
        }
        return ClipRect(
          child: OverflowBox(
            alignment: Alignment.topLeft,
            maxWidth: width,
            maxHeight: double.infinity,
            child: RichText(
              key: const ValueKey('live-preview-text'),
              softWrap: false,
              text: TextSpan(style: base, children: spans),
            ),
          ),
        );
      },
    );
  }
}

/// Resolves raw cell colours against a [TerminalTheme] (the same mapping as
/// the terminal painter), cached per theme.
class _PreviewColors {
  _PreviewColors(this.theme) : palette = _buildPalette(theme);

  final TerminalTheme theme;
  final List<Color> palette;

  static _PreviewColors? _last;

  static _PreviewColors of(TerminalTheme theme) {
    final last = _last;
    if (last != null && identical(last.theme, theme)) return last;
    return _last = _PreviewColors(theme);
  }

  TextStyle? styleFor(PreviewRun run) {
    final flags = run.flags;
    final inverse = flags & CellFlags.inverse != 0;
    final hasBackground =
        run.background & CellColor.typeMask != CellColor.normal;
    var foreground = inverse
        ? _resolve(run.background, theme.background)
        : _resolve(run.foreground, theme.foreground);
    final background = inverse
        ? _resolve(run.foreground, theme.foreground)
        : hasBackground
        ? _resolve(run.background, theme.background)
        : null;
    if (flags & CellFlags.faint != 0) {
      foreground = foreground.withValues(alpha: foreground.a * 0.5);
    }
    if (flags & CellFlags.invisible != 0) {
      foreground = background ?? theme.background;
    }
    final bold = flags & CellFlags.bold != 0;
    final italic = flags & CellFlags.italic != 0;
    return TextStyle(
      color: foreground,
      backgroundColor: background,
      fontWeight: bold ? FontWeight.bold : null,
      fontStyle: italic ? FontStyle.italic : null,
    );
  }

  Color _resolve(int cellColor, Color fallback) {
    final type = cellColor & CellColor.typeMask;
    final value = cellColor & CellColor.valueMask;
    switch (type) {
      case CellColor.normal:
        return fallback;
      case CellColor.named:
      case CellColor.palette:
        return palette[value.clamp(0, 255)];
      default:
        return Color(value | 0xFF000000);
    }
  }

  static List<Color> _buildPalette(TerminalTheme theme) {
    final named = [
      theme.black,
      theme.red,
      theme.green,
      theme.yellow,
      theme.blue,
      theme.magenta,
      theme.cyan,
      theme.white,
      theme.brightBlack,
      theme.brightRed,
      theme.brightGreen,
      theme.brightYellow,
      theme.brightBlue,
      theme.brightMagenta,
      theme.brightCyan,
      theme.brightWhite,
    ];
    const steps = [0, 95, 135, 175, 215, 255];
    return List<Color>.generate(256, (index) {
      if (index < 16) return named[index];
      if (index < 232) {
        final cube = index - 16;
        return Color.fromARGB(
          0xFF,
          steps[cube ~/ 36],
          steps[(cube ~/ 6) % 6],
          steps[cube % 6],
        );
      }
      final gray = 8 + (index - 232) * 10;
      return Color.fromARGB(0xFF, gray, gray, gray);
    }, growable: false);
  }
}

/// The refresh pace of the live previews below it: each tick lets a
/// [TerminalSnapshotBuilder] whose terminal printed something since its
/// last capture capture again. The page ticks it while it is on screen.
class PreviewClock extends InheritedWidget {
  const PreviewClock({required this.ticks, required super.child, super.key});

  final Listenable ticks;

  static Listenable? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PreviewClock>()?.ticks;

  @override
  bool updateShouldNotify(PreviewClock oldWidget) => ticks != oldWidget.ticks;
}

/// Builds a snapshot of [terminal] (a preview) in its own repaint layer,
/// and builds it again on a [PreviewClock] tick only when the terminal
/// changed: an idle session costs nothing between ticks, and a busy one
/// redraws alone instead of with its page. Without a clock it builds
/// with its parent, as a plain builder.
class TerminalSnapshotBuilder extends StatefulWidget {
  const TerminalSnapshotBuilder({
    required this.terminal,
    required this.builder,
    super.key,
  });

  final Terminal terminal;
  final WidgetBuilder builder;

  @override
  State<TerminalSnapshotBuilder> createState() =>
      _TerminalSnapshotBuilderState();
}

class _TerminalSnapshotBuilderState extends State<TerminalSnapshotBuilder> {
  Listenable? _clock;
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    widget.terminal.addListener(_onOutput);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final clock = PreviewClock.maybeOf(context);
    if (clock == _clock) return;
    _clock?.removeListener(_onTick);
    _clock = clock?..addListener(_onTick);
  }

  @override
  void didUpdateWidget(TerminalSnapshotBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.terminal != widget.terminal) {
      oldWidget.terminal.removeListener(_onOutput);
      widget.terminal.addListener(_onOutput);
      _changed = false;
    }
  }

  void _onOutput() => _changed = true;

  void _onTick() {
    if (!_changed || !mounted) return;
    setState(() => _changed = false);
  }

  @override
  void dispose() {
    widget.terminal.removeListener(_onOutput);
    _clock?.removeListener(_onTick);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _changed = false;
    return RepaintBoundary(child: Builder(builder: widget.builder));
  }
}

/// Builds [session]'s preview: live from its terminal, or from its
/// [SharedViewSnapshot] while its screen mirrors another session's Herdr
/// workspace (see [TerminalSessionController.sharedView]). [builder] gets
/// the snapshot too, null while the preview is live.
class SessionPreviewBuilder extends StatelessWidget {
  const SessionPreviewBuilder({
    required this.session,
    required this.builder,
    super.key,
  });

  final TerminalSessionController session;
  final Widget Function(
    BuildContext context,
    StyledTerminalPreview preview,
    SharedViewSnapshot? shared,
  )
  builder;

  /// What a preview says while it has no snapshot of its own workspace.
  static const sharedPlaceholder =
      'Shared Herdr view: open this session to show its workspace';

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<SharedViewSnapshot?>(
      valueListenable: session.sharedView,
      builder: (context, shared, _) {
        if (shared != null) {
          return RepaintBoundary(
            key: const ValueKey('shared-view-preview'),
            child: builder(context, shared.preview, shared),
          );
        }
        return TerminalSnapshotBuilder(
          terminal: session.terminal,
          builder: (context) => builder(
            context,
            StyledTerminalPreview.capture(session.terminal),
            null,
          ),
        );
      },
    );
  }
}

/// The small "Herdr · 05:54" caption on a preview that shows a
/// [SharedViewSnapshot]: when its screen was last its own.
class SharedViewCaption extends StatelessWidget {
  const SharedViewCaption({
    required this.shared,
    required this.background,
    required this.foreground,
    super.key,
  });

  final SharedViewSnapshot shared;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    final text = shared.preview.isEmpty
        ? 'Herdr'
        : 'Herdr · ${shared.timeLabel}';
    return Tooltip(
      message: shared.preview.isEmpty
          ? 'This session shares its Herdr server with the one in use, '
                'which shows another workspace. Open it to show its own.'
          : 'Last seen at ${shared.timeLabel}. This session shares its '
                'Herdr server with the one in use, which shows another '
                'workspace. Open it to show its own.',
      child: DecoratedBox(
        key: const ValueKey('shared-view-caption'),
        decoration: BoxDecoration(
          color: background.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
          child: Text(
            text,
            style: TextStyle(
              color: foreground.withValues(alpha: 0.8),
              fontSize: 10,
            ),
          ),
        ),
      ),
    );
  }
}
