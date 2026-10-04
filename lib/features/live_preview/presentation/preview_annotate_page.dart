import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:conduit/core/platform_features.dart';
import 'package:conduit/core/presentation/adaptive_page.dart';
import 'package:conduit/features/live_preview/domain/preview_screenshot.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// What the annotate screen hands back: the image to send and a note.
class PreviewAnnotateResult {
  const PreviewAnnotateResult({required this.png, required this.note});

  final Uint8List png;
  final String note;
}

/// Shows [png] full screen with rectangle and arrow tools and a note
/// field. Resolves to the image with the shapes burnt in (the original
/// bytes when nothing was drawn), or null when cancelled.
Future<PreviewAnnotateResult?> showPreviewAnnotatePage(
  BuildContext context,
  Uint8List png,
) {
  // Phones: full screen; desktop: a large dialog over the shell (Esc and
  // a click outside cancel it).
  return pushAdaptivePage<PreviewAnnotateResult>(
    context,
    fullscreenDialog: true,
    desktopMaxWidth: 1100,
    builder: (_) => PreviewAnnotatePage(png: png),
  );
}

const _markColor = Color(0xFFFF3B30);

class PreviewAnnotatePage extends StatefulWidget {
  const PreviewAnnotatePage({required this.png, super.key});

  final Uint8List png;

  @override
  State<PreviewAnnotatePage> createState() => _PreviewAnnotatePageState();
}

class _PreviewAnnotatePageState extends State<PreviewAnnotatePage> {
  final _note = TextEditingController();
  final _noteFocus = FocusNode();
  final List<PreviewAnnotation> _shapes = [];
  PreviewAnnotationKind _tool = PreviewAnnotationKind.rectangle;
  PreviewAnnotation? _drawing;
  ui.Image? _image;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  Future<void> _decode() async {
    final codec = await ui.instantiateImageCodec(widget.png);
    final frame = await codec.getNextFrame();
    codec.dispose();
    if (!mounted) {
      frame.image.dispose();
      return;
    }
    setState(() => _image = frame.image);
  }

  @override
  void dispose() {
    _note.dispose();
    _noteFocus.dispose();
    _image?.dispose();
    super.dispose();
  }

  Offset _normalized(Offset local, Size size) => Offset(
    (local.dx / size.width).clamp(0.0, 1.0),
    (local.dy / size.height).clamp(0.0, 1.0),
  );

  void _undo() {
    _shapes.removeLast();
    setState(() {});
  }

  Future<void> _send() async {
    final image = _image;
    if (image == null || _sending) return;
    setState(() => _sending = true);
    final png = _shapes.isEmpty
        ? widget.png
        : await renderAnnotatedPng(image, _shapes);
    if (!mounted) return;
    Navigator.of(
      context,
    ).pop(PreviewAnnotateResult(png: png, note: _note.text.trim()));
  }

  /// Desktop keys: Ctrl/Cmd+Enter sends, Ctrl/Cmd+Z undoes the last mark
  /// (in the note field Ctrl+Z stays the field's own undo).
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    final primary = defaultTargetPlatform == TargetPlatform.macOS
        ? keys.isMetaPressed
        : keys.isControlPressed;
    if (!primary || keys.isAltPressed || keys.isShiftPressed) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      if (_image != null && !_sending) unawaited(_send());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyZ && !_noteFocus.hasFocus) {
      if (_shapes.isNotEmpty) _undo();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final page = _page(context);
    if (!PlatformFeatures.isDesktop) return page;
    return Focus(autofocus: true, onKeyEvent: _onKey, child: page);
  }

  Widget _page(BuildContext context) {
    final image = _image;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Screenshot'),
        actions: [
          SegmentedButton<PreviewAnnotationKind>(
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: const [
              ButtonSegment(
                value: PreviewAnnotationKind.rectangle,
                icon: Icon(Icons.crop_square_rounded, size: 18),
                tooltip: 'Rectangle',
              ),
              ButtonSegment(
                value: PreviewAnnotationKind.arrow,
                icon: Icon(Icons.north_east_rounded, size: 18),
                tooltip: 'Arrow',
              ),
            ],
            selected: {_tool},
            onSelectionChanged: (value) => setState(() => _tool = value.first),
          ),
          IconButton(
            tooltip: 'Undo',
            icon: const Icon(Icons.undo_rounded),
            onPressed: _shapes.isEmpty ? null : _undo,
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: image == null
                  ? const Center(child: CircularProgressIndicator())
                  : Center(
                      child: AspectRatio(
                        aspectRatio: image.width / image.height,
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final size = constraints.biggest;
                            return GestureDetector(
                              key: const ValueKey('annotate-canvas'),
                              onPanStart: (details) {
                                final at = _normalized(
                                  details.localPosition,
                                  size,
                                );
                                setState(
                                  () => _drawing = PreviewAnnotation(
                                    kind: _tool,
                                    start: at,
                                    end: at,
                                  ),
                                );
                              },
                              onPanUpdate: (details) => setState(
                                () => _drawing = _drawing?.copyWith(
                                  end: _normalized(details.localPosition, size),
                                ),
                              ),
                              onPanEnd: (_) => setState(() {
                                final shape = _drawing;
                                _drawing = null;
                                if (shape != null && !shape.isTiny) {
                                  _shapes.add(shape);
                                }
                              }),
                              child: CustomPaint(
                                size: size,
                                painter: PreviewAnnotationPainter(
                                  image: image,
                                  shapes: [..._shapes, ?_drawing],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('annotate-note'),
                      controller: _note,
                      focusNode: _noteFocus,
                      // Desktop: Enter in the note sends, like the button.
                      onSubmitted: PlatformFeatures.isDesktop && image != null
                          ? (_) => unawaited(_send())
                          : null,
                      minLines: 1,
                      maxLines: 3,
                      textInputAction: TextInputAction.done,
                      decoration: const InputDecoration(
                        isDense: true,
                        hintText: 'Note for the agent (optional)',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    key: const ValueKey('annotate-send'),
                    onPressed: image == null || _sending ? null : _send,
                    icon: _sending
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send_rounded, size: 18),
                    label: const Text('To the agent'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Paints [image] scaled to the canvas with [shapes] on top.
class PreviewAnnotationPainter extends CustomPainter {
  const PreviewAnnotationPainter({required this.image, required this.shapes});

  final ui.Image image;
  final List<PreviewAnnotation> shapes;

  @override
  void paint(Canvas canvas, Size size) {
    paintImage(
      canvas: canvas,
      rect: Offset.zero & size,
      image: image,
      fit: BoxFit.fill,
    );
    paintAnnotations(canvas, size, shapes);
  }

  @override
  bool shouldRepaint(PreviewAnnotationPainter oldDelegate) =>
      oldDelegate.image != image || oldDelegate.shapes != shapes;
}

/// Draws [shapes] (0..1 coordinates) onto a canvas of [size]; the stroke
/// scales with the canvas so a burnt-in mark looks like the one on screen.
void paintAnnotations(
  Canvas canvas,
  Size size,
  List<PreviewAnnotation> shapes,
) {
  final stroke = math.max(3.0, size.shortestSide / 110);
  final paint = Paint()
    ..color = _markColor
    ..style = PaintingStyle.stroke
    ..strokeWidth = stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  Offset at(Offset p) => Offset(p.dx * size.width, p.dy * size.height);
  for (final shape in shapes) {
    final start = at(shape.start);
    final end = at(shape.end);
    switch (shape.kind) {
      case PreviewAnnotationKind.rectangle:
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromPoints(start, end),
            Radius.circular(stroke),
          ),
          paint,
        );
      case PreviewAnnotationKind.arrow:
        canvas.drawLine(start, end, paint);
        final angle = (end - start).direction;
        final head = stroke * 5;
        for (final side in [-1, 1]) {
          canvas.drawLine(
            end,
            end - Offset.fromDirection(angle + side * math.pi / 7, head),
            paint,
          );
        }
    }
  }
}

/// [image] at full resolution with [shapes] drawn in, as PNG.
Future<Uint8List> renderAnnotatedPng(
  ui.Image image,
  List<PreviewAnnotation> shapes,
) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final size = Size(image.width.toDouble(), image.height.toDouble());
  canvas.drawImage(image, Offset.zero, Paint());
  paintAnnotations(canvas, size, shapes);
  final picture = recorder.endRecording();
  final rendered = await picture.toImage(image.width, image.height);
  picture.dispose();
  try {
    final bytes = await rendered.toByteData(format: ui.ImageByteFormat.png);
    return bytes!.buffer.asUint8List();
  } finally {
    rendered.dispose();
  }
}
