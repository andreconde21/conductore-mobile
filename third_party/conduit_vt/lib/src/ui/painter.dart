import 'dart:math' show max;
import 'dart:ui';
import 'dart:ui' as ui;
import 'package:flutter/painting.dart';

import 'package:conduit_vt/src/ui/palette_builder.dart';
import 'package:conduit_vt/src/ui/paragraph_cache.dart';
import 'package:conduit_vt/xterm.dart';

/// Encapsulates the logic for painting various terminal elements.
class TerminalPainter {
  TerminalPainter({
    required TerminalTheme theme,
    required TerminalStyle textStyle,
    required TextScaler textScaler,
  })  : _textStyle = textStyle,
        _theme = theme,
        _textScaler = textScaler;

  /// A lookup table from terminal colors to Flutter colors.
  late var _colorPalette = PaletteBuilder(_theme).build();

  /// Size of each character in the terminal, snapped to whole device pixels
  /// (see [_measureCharSize]).
  late var _cellSize = _measureCharSize();

  /// The cached for cells in the terminal. Should be cleared when the same
  /// cell no longer produces the same visual output. For example, when
  /// [_textStyle] is changed, or when the system font changes.
  final _paragraphCache = ParagraphCache(10240);

  /// Bumped whenever the same line would paint differently (style, scale,
  /// theme, pixel ratio, fonts), so recorded lines can tell they are stale.
  int get generation => _generation;
  int _generation = 0;

  TerminalStyle get textStyle => _textStyle;
  TerminalStyle _textStyle;
  set textStyle(TerminalStyle value) {
    if (value == _textStyle) return;
    _textStyle = value;
    _invalidateMetrics();
  }

  TextScaler get textScaler => _textScaler;
  TextScaler _textScaler = TextScaler.linear(1.0);
  set textScaler(TextScaler value) {
    if (value == _textScaler) return;
    _textScaler = value;
    _invalidateMetrics();
  }

  /// Device pixels per logical pixel of the window the terminal is shown
  /// in. Cells, lines and glyph origins are placed on whole device pixels,
  /// as native terminals do, so text stays sharp at 1x, 2x and fractional
  /// scales such as 1.25 or 1.5.
  double get devicePixelRatio => _devicePixelRatio;
  double _devicePixelRatio = 1.0;
  set devicePixelRatio(double value) {
    if (value == _devicePixelRatio || value <= 0) return;
    _devicePixelRatio = value;
    _invalidateMetrics();
  }

  TerminalTheme get theme => _theme;
  TerminalTheme _theme;
  set theme(TerminalTheme value) {
    if (value == _theme) return;
    _theme = value;
    _colorPalette = PaletteBuilder(value).build();
    _paragraphCache.clear();
    _runStyles.clear();
    _generation++;
  }

  void _invalidateMetrics() {
    _runAdvances = List.filled(4, _unmeasured);
    _runStyles.clear();
    _cellSize = _measureCharSize();
    _paragraphCache.clear();
    _generation++;
  }

  /// [value] rounded to the nearest device pixel.
  double snap(double value) =>
      (value * _devicePixelRatio).roundToDouble() / _devicePixelRatio;

  /// The height of a glyph's paragraph before the cell height was snapped.
  var _glyphHeight = 0.0;

  /// How far below a cell's top its glyph is drawn: the snapped cell height
  /// splits the rounding between above and below the glyph.
  var _glyphTop = 0.0;

  Size _measureCharSize() {
    const test = 'mmmmmmmmmm';

    final textStyle = _textStyle.toTextStyle();
    final builder = ParagraphBuilder(textStyle.getParagraphStyle());
    builder.pushStyle(textStyle.getTextStyle(textScaler: _textScaler));
    builder.addText(test);

    final paragraph = builder.build();
    paragraph.layout(ParagraphConstraints(width: double.infinity));

    final advance = paragraph.maxIntrinsicWidth / test.length;
    _glyphHeight = paragraph.height;
    paragraph.dispose();

    // Whole device pixels, like Alacritty and Ghostty: with a fractional
    // width every column starts at a different sub-pixel phase, glyphs are
    // rasterized differently from column to column, and cell backgrounds
    // get anti-aliased seams. The glyph keeps its natural size; only the
    // grid rounds (by at most half a device pixel per cell).
    final ratio = _devicePixelRatio;
    final result = Size(
      max(1.0, (advance * ratio).roundToDouble()) / ratio,
      max(1.0, (_glyphHeight * ratio).roundToDouble()) / ratio,
    );
    _glyphTop = snap((result.height - _glyphHeight) / 2);
    return result;
  }

  /// The size of each character in the terminal.
  Size get cellSize => _cellSize;

  /// When the set of font available to the system changes, call this method to
  /// clear cached state related to font rendering.
  void clearFontCache() {
    _invalidateMetrics();
  }

  /// Paints the cursor based on the current cursor type.
  void paintCursor(
    Canvas canvas,
    Offset offset, {
    required TerminalCursorType cursorType,
    bool hasFocus = true,
  }) {
    final paint = Paint()
      ..color = _theme.cursor
      ..strokeWidth = 1;

    if (!hasFocus) {
      paint.style = PaintingStyle.stroke;
      canvas.drawRect(offset & _cellSize, paint);
      return;
    }

    switch (cursorType) {
      case TerminalCursorType.block:
        paint.style = PaintingStyle.fill;
        canvas.drawRect(offset & _cellSize, paint);
        return;
      case TerminalCursorType.underline:
        return canvas.drawLine(
          Offset(offset.dx, offset.dy + _cellSize.height - 1),
          Offset(
            offset.dx + _cellSize.width,
            offset.dy + _cellSize.height - 1,
          ),
          paint,
        );
      case TerminalCursorType.verticalBar:
        return canvas.drawLine(
          offset,
          Offset(offset.dx, offset.dy + _cellSize.height),
          paint,
        );
    }
  }

  @pragma('vm:prefer-inline')
  void paintHighlight(Canvas canvas, Offset offset, int length, Color color) {
    final endOffset = offset.translate(
      length * _cellSize.width,
      _cellSize.height,
    );

    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;

    canvas.drawRect(Rect.fromPoints(offset, endOffset), paint);
  }

  /// Paints [line] to [canvas] at [offset]. The x offset of [offset] is usually
  /// 0, and the y offset is the top of the line.
  void paintLine(Canvas canvas, Offset offset, BufferLine line) {
    canvas.save();
    canvas.translate(offset.dx, offset.dy);
    _paintLineBackground(canvas, line);
    // One cached paragraph per glyph: the cheapest to draw for a line that
    // is shown once (see RenderTerminal's streaming output).
    final cellData = CellData.empty();
    final cellWidth = _cellSize.width;
    for (var i = 0; i < line.length; i++) {
      line.getCellData(i, cellData);
      paintCellForeground(canvas, Offset(i * cellWidth, 0), cellData);
      if (cellData.content >> CellContent.widthShift == 2) i++;
    }
    canvas.restore();
  }


  void paintOverlayText(
    Canvas canvas,
    Offset offset, {
    required String text,
    Color? foreground,
    Color? background,
    double opacity = 1,
    bool erase = false,
  }) {
    if (text.isEmpty && !erase) return;

    final effectiveOpacity = opacity.clamp(0.0, 1.0);
    final backgroundColor = background ?? (erase ? _theme.background : null);
    if (backgroundColor != null) {
      final paint = Paint()
        ..color = backgroundColor.withValues(
          alpha: backgroundColor.a * effectiveOpacity,
        );
      canvas.drawRect(offset & _cellSize, paint);
    }

    if (text.isEmpty) return;

    final style = _textStyle.toTextStyle(
      color: (foreground ?? _theme.foreground).withValues(
        alpha: effectiveOpacity,
      ),
    );
    final builder = ParagraphBuilder(style.getParagraphStyle())
      ..pushStyle(style.getTextStyle(textScaler: _textScaler))
      ..addText(text);
    final paragraph = builder.build()
      ..layout(ParagraphConstraints(width: _cellSize.width));

    canvas.drawParagraph(paragraph, offset);
    paragraph.dispose();
  }

  @pragma('vm:prefer-inline')
  void paintCell(Canvas canvas, Offset offset, CellData cellData) {
    paintCellBackground(canvas, offset, cellData);
    paintCellForeground(canvas, offset, cellData);
  }

  /// Paints the character in the cell represented by [cellData] to [canvas] at
  /// [offset].
  @pragma('vm:prefer-inline')
  void paintCellForeground(Canvas canvas, Offset offset, CellData cellData) {
    final charCode = cellData.content & CellContent.codepointMask;
    if (charCode == 0) return;

    final cacheKey = cellData.getHash() ^ _textScaler.hashCode;
    var paragraph = _paragraphCache.getLayoutFromCache(cacheKey);

    if (paragraph == null) {
      final cellFlags = cellData.flags;

      var color = cellFlags & CellFlags.inverse == 0
          ? resolveForegroundColor(cellData.foreground)
          : resolveBackgroundColor(cellData.background);

      if (cellData.flags & CellFlags.faint != 0) {
        color = color.withValues(alpha: color.a * 0.5);
      }

      final style = _textStyle.toTextStyle(
        color: color,
        bold: cellFlags & CellFlags.bold != 0,
        italic: cellFlags & CellFlags.italic != 0,
        underline: cellFlags & CellFlags.underline != 0,
      );

      // Flutter does not draw an underline below a space which is not between
      // other regular characters. As only single characters are drawn, this
      // will never produce an underline below a space in the terminal. As a
      // workaround the regular space CodePoint 0x20 is replaced with
      // the CodePoint 0xA0. This is a non breaking space and a underline can be
      // drawn below it.
      var char = String.fromCharCode(charCode);
      if (cellFlags & CellFlags.underline != 0 && charCode == 0x20) {
        char = String.fromCharCode(0xA0);
      }

      paragraph = _paragraphCache.performAndCacheLayout(
        char,
        style,
        _textScaler,
        cacheKey,
      );
    }

    canvas.drawParagraph(paragraph, offset.translate(0, _glyphTop));
    debugParagraphsDrawn++;
  }

  /// Paints the background of a cell represented by [cellData] to [canvas] at
  /// [offset].
  @pragma('vm:prefer-inline')
  void paintCellBackground(Canvas canvas, Offset offset, CellData cellData) {
    late Color color;
    final colorType = cellData.background & CellColor.typeMask;

    if (cellData.flags & CellFlags.inverse != 0) {
      color = resolveForegroundColor(cellData.foreground);
    } else if (colorType == CellColor.normal) {
      return;
    } else {
      color = resolveBackgroundColor(cellData.background);
    }

    final paint = Paint()..color = color;
    final doubleWidth = cellData.content >> CellContent.widthShift == 2;
    final widthScale = doubleWidth ? 2 : 1;
    final size = Size(_cellSize.width * widthScale + 1, _cellSize.height);
    canvas.drawRect(offset & size, paint);
  }

  /// Records [line] (backgrounds, then glyphs) as a picture with its top
  /// left corner at the origin, for [RenderTerminal] to replay while the
  /// line stays the same.
  ///
  /// Backgrounds are merged into one rectangle per run of the same colour,
  /// and printable ASCII of one style is drawn as one paragraph per run
  /// (letter-spaced onto the cell grid) instead of one per cell. Other
  /// characters (wide, non-ASCII, symbols from fallback fonts) keep their
  /// own cached paragraph at their cell, as before.
  Picture recordLine(BufferLine line) {
    final recorder = PictureRecorder();
    final canvas = Canvas(recorder);
    _paintLineBackground(canvas, line);
    _paintLineForeground(canvas, line);
    return recorder.endRecording();
  }

  void _paintLineBackground(Canvas canvas, BufferLine line) {
    final cellWidth = _cellSize.width;
    final height = _cellSize.height;
    final length = line.length;
    Color? runColor;
    var runStart = 0;
    var runEnd = 0;

    void flush() {
      final color = runColor;
      if (color == null) return;
      canvas.drawRect(
        Rect.fromLTRB(runStart * cellWidth, 0, runEnd * cellWidth, height),
        Paint()..color = color,
      );
    }

    for (var i = 0; i < length; i++) {
      final flags = line.getAttributes(i);
      final background = line.getBackground(i);
      final Color? color;
      if (flags & CellFlags.inverse != 0) {
        color = resolveForegroundColor(line.getForeground(i));
      } else if (background & CellColor.typeMask == CellColor.normal) {
        color = null;
      } else {
        color = resolveBackgroundColor(background);
      }
      if (color != runColor || runEnd != i) {
        flush();
        runColor = color;
        runStart = i;
      }
      final wide = line.getWidth(i) == 2;
      runEnd = wide ? i + 2 : i + 1;
      if (wide) i++;
    }
    flush();
  }

  void _paintLineForeground(Canvas canvas, BufferLine line) {
    final cellData = CellData.empty();
    final cellWidth = _cellSize.width;
    final run = StringBuffer();
    var runStart = -1;
    // Length of the run up to its last character that is not a space:
    // trailing spaces draw nothing and are left out.
    var runLength = 0;
    var runColor = const Color(0x00000000);
    var runFlags = 0;

    void flush() {
      if (runStart < 0) return;
      final text = run.toString().substring(0, runLength);
      run.clear();
      final start = runStart;
      runStart = -1;
      if (text.isEmpty) return;
      final paragraph = _layoutRun(text, runColor, runFlags);
      // The text engine puts half the letter spacing before each glyph;
      // undo that so every glyph starts exactly at its cell.
      final spacing = _cellSize.width - _runAdvance(runFlags)!;
      canvas.drawParagraph(
        paragraph,
        Offset(start * cellWidth - spacing / 2, _glyphTop),
      );
      debugParagraphsDrawn++;
      paragraph.dispose();
    }

    for (var i = 0; i < line.length; i++) {
      line.getCellData(i, cellData);
      final content = cellData.content;
      final charCode = content & CellContent.codepointMask;
      final wide = content >> CellContent.widthShift == 2;
      final flags = cellData.flags & _runFlagsMask;

      if (charCode >= 0x20 &&
          charCode < 0x7f &&
          !wide &&
          _runAdvance(flags) != null) {
        final color = _glyphColor(cellData);
        final underline = flags & CellFlags.underline != 0;
        if (runStart >= 0 &&
            (flags != runFlags ||
                // A space shows no colour, so it joins any run.
                (color != runColor && (charCode != 0x20 || underline)))) {
          flush();
        }
        if (runStart < 0) {
          // A run starts at its first glyph; leading spaces draw nothing
          // (an underlined space draws its underline, so it counts).
          if (charCode == 0x20 && !underline) continue;
          runStart = i;
          runLength = 0;
          runColor = color;
          runFlags = flags;
        }
        // Flutter draws no underline below a space that ends the text, so
        // an underlined space is a no-break space, as in paintCellForeground.
        run.writeCharCode(charCode == 0x20 && underline ? 0xA0 : charCode);
        if (charCode != 0x20 || underline) runLength = run.length;
        continue;
      }

      flush();
      if (charCode != 0) {
        paintCellForeground(canvas, Offset(i * cellWidth, 0), cellData);
      }
      if (wide) i++;
    }
    flush();
  }

  /// The style bits a run keeps the same; other attributes do not change
  /// how a glyph is drawn.
  static const _runFlagsMask =
      CellFlags.bold | CellFlags.italic | CellFlags.underline;

  /// The colour a cell's glyph is drawn in (inverse and faint applied).
  Color _glyphColor(CellData cellData) {
    final cellFlags = cellData.flags;
    var color = cellFlags & CellFlags.inverse == 0
        ? resolveForegroundColor(cellData.foreground)
        : resolveBackgroundColor(cellData.background);
    if (cellFlags & CellFlags.faint != 0) {
      color = color.withValues(alpha: color.a * 0.5);
    }
    return color;
  }

  static const _unmeasured = -1.0;

  /// The advance of one ASCII glyph per bold/italic combination, measured
  /// on first use; [_unmeasured] until then and 0 when the font is not
  /// monospaced for ASCII in that style (its runs then fall back to one
  /// paragraph per cell).
  var _runAdvances = List.filled(4, _unmeasured);

  /// Draws each glyph with its own paragraph, as before glyph runs, for
  /// benchmarks that compare the two.
  static bool debugDisableGlyphRuns = false;

  /// Paragraphs drawn for glyphs so far (each one is a separate text draw
  /// for the rasterizer), for tests and benchmarks.
  static int debugParagraphsDrawn = 0;

  double? _runAdvance(int flags) {
    if (debugDisableGlyphRuns) return null;
    final index = (flags & CellFlags.bold != 0 ? 1 : 0) +
        (flags & CellFlags.italic != 0 ? 2 : 0);
    var advance = _runAdvances[index];
    if (advance == _unmeasured) {
      advance = _measureRunAdvance(
        bold: index & 1 != 0,
        italic: index & 2 != 0,
      );
      _runAdvances[index] = advance;
    }
    return advance > 0 ? advance : null;
  }

  double _measureRunAdvance({required bool bold, required bool italic}) {
    // A proportional fallback (the configured font missing) would put run
    // glyphs off the grid, so runs need every probe to have one advance.
    const probes = ['i', 'M', 'W', '.', '0', '@', ' '];
    double? advance;
    for (final probe in probes) {
      final paragraph = _buildRunParagraph(
        probe * 8,
        const Color(0xFF000000),
        bold: bold,
        italic: italic,
        underline: false,
        letterSpacing: 0,
      );
      final width = paragraph.maxIntrinsicWidth / 8;
      paragraph.dispose();
      if (advance == null) {
        advance = width;
      } else if ((width - advance).abs() > 0.01) {
        return 0;
      }
    }
    return advance ?? 0;
  }

  /// Run styles by colour and style bits: a screen uses a handful, and
  /// building them is most of the cost of a short run.
  final _runStyles = <(int, int), (ui.ParagraphStyle, ui.TextStyle)>{};

  Paragraph _layoutRun(String text, Color color, int flags) {
    final (paragraphStyle, textStyle) = _runStyles[(
      color.toARGB32(),
      flags,
    )] ??= _runStyle(
      color,
      bold: flags & CellFlags.bold != 0,
      italic: flags & CellFlags.italic != 0,
      underline: flags & CellFlags.underline != 0,
      letterSpacing: _cellSize.width - _runAdvance(flags)!,
    );
    final builder = ParagraphBuilder(paragraphStyle)
      ..pushStyle(textStyle)
      ..addText(text);
    return builder.build()
      ..layout(const ParagraphConstraints(width: double.infinity));
  }

  /// Ligatures and kerning off: a terminal draws each character in its
  /// own cell, as the per-cell paragraphs always did.
  static const _gridFeatures = [
    FontFeature.disable('liga'),
    FontFeature.disable('calt'),
    FontFeature.disable('kern'),
  ];

  Paragraph _buildRunParagraph(
    String text,
    Color color, {
    required bool bold,
    required bool italic,
    required bool underline,
    required double letterSpacing,
  }) {
    final (paragraphStyle, textStyle) = _runStyle(
      color,
      bold: bold,
      italic: italic,
      underline: underline,
      letterSpacing: letterSpacing,
    );
    final builder = ParagraphBuilder(paragraphStyle)
      ..pushStyle(textStyle)
      ..addText(text);
    return builder.build()
      ..layout(const ParagraphConstraints(width: double.infinity));
  }

  (ui.ParagraphStyle, ui.TextStyle) _runStyle(
    Color color, {
    required bool bold,
    required bool italic,
    required bool underline,
    required double letterSpacing,
  }) {
    final style = _textStyle
        .toTextStyle(
          color: color,
          bold: bold,
          italic: italic,
          underline: underline,
        )
        .copyWith(letterSpacing: letterSpacing, fontFeatures: _gridFeatures);
    return (
      style.getParagraphStyle(),
      style.getTextStyle(textScaler: _textScaler),
    );
  }

  /// Get the effective foreground color for a cell from information encoded in
  /// [cellColor].
  @pragma('vm:prefer-inline')
  Color resolveForegroundColor(int cellColor) {
    final colorType = cellColor & CellColor.typeMask;
    final colorValue = cellColor & CellColor.valueMask;

    switch (colorType) {
      case CellColor.normal:
        return _theme.foreground;
      case CellColor.named:
      case CellColor.palette:
        return _colorPalette[colorValue];
      case CellColor.rgb:
      default:
        return Color(colorValue | 0xFF000000);
    }
  }

  /// Get the effective background color for a cell from information encoded in
  /// [cellColor].
  @pragma('vm:prefer-inline')
  Color resolveBackgroundColor(int cellColor) {
    final colorType = cellColor & CellColor.typeMask;
    final colorValue = cellColor & CellColor.valueMask;

    switch (colorType) {
      case CellColor.normal:
        return _theme.background;
      case CellColor.named:
      case CellColor.palette:
        return _colorPalette[colorValue];
      case CellColor.rgb:
      default:
        return Color(colorValue | 0xFF000000);
    }
  }
}
