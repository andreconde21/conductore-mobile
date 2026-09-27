import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:conduit/core/platform_features.dart';
import 'package:conduit/core/presentation/adaptive_page.dart';
import 'package:conduit/features/share_target/domain/shared_payload.dart';
import 'package:conduit/features/terminal/domain/prompt_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Shows [image] full screen with a crop frame (a large dialog over the
/// window on desktop). Resolves to the normalized crop (the whole image
/// when untouched), or null when cancelled.
Future<Rect?> showImageCropPage(BuildContext context, SharedFile image) {
  final navigator = Navigator.of(context, rootNavigator: true);
  if (useDesktopPages(context)) {
    return navigator.push<Rect>(
      DesktopPageRoute(
        builder: (context) => ImageCropPage(image: image),
        barrierLabel: MaterialLocalizations.of(
          context,
        ).modalBarrierDismissLabel,
      ),
    );
  }
  return navigator.push<Rect>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (context) => ImageCropPage(image: image),
    ),
  );
}

/// A deliberately small crop UI: drag a corner to resize, drag inside the
/// frame to move it. No rotation or aspect presets; screenshots and photos
/// for an agent rarely need more.
class ImageCropPage extends StatefulWidget {
  const ImageCropPage({required this.image, super.key});

  final SharedFile image;

  @override
  State<ImageCropPage> createState() => _ImageCropPageState();
}

enum _DragTarget { topLeft, topRight, bottomLeft, bottomRight, move }

class _ImageCropPageState extends State<ImageCropPage> {
  static const _minFraction = 0.05;
  static const _handleReach = 36.0;

  Size? _imageSize;
  Object? _loadError;
  Rect _crop = fullImageCrop;
  _DragTarget? _dragTarget;
  // Desktop: the resize or move cursor for what the mouse is over.
  MouseCursor _cursor = MouseCursor.defer;

  @override
  void initState() {
    super.initState();
    _readSize();
  }

  /// Reads the dimensions from the header without decoding the pixels.
  Future<void> _readSize() async {
    try {
      final bytes = await File(widget.image.path).readAsBytes();
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      final size = Size(
        descriptor.width.toDouble(),
        descriptor.height.toDouble(),
      );
      descriptor.dispose();
      buffer.dispose();
      if (mounted) {
        setState(() => _imageSize = size);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _loadError = error);
      }
    }
  }

  Rect _fitted(Size box, Size image) {
    final scale = math.min(box.width / image.width, box.height / image.height);
    final width = image.width * scale;
    final height = image.height * scale;
    return Rect.fromLTWH(
      (box.width - width) / 2,
      (box.height - height) / 2,
      width,
      height,
    );
  }

  Rect _toScreen(Rect frame) => Rect.fromLTRB(
    frame.left + _crop.left * frame.width,
    frame.top + _crop.top * frame.height,
    frame.left + _crop.right * frame.width,
    frame.top + _crop.bottom * frame.height,
  );

  void _handlePanStart(DragStartDetails details, Rect frame) {
    _dragTarget = _targetAt(details.localPosition, frame);
  }

  /// The corner within reach of [point], else the frame when [point] is
  /// inside it, else null.
  _DragTarget? _targetAt(Offset point, Rect frame) {
    final rect = _toScreen(frame);
    final corners = {
      _DragTarget.topLeft: rect.topLeft,
      _DragTarget.topRight: rect.topRight,
      _DragTarget.bottomLeft: rect.bottomLeft,
      _DragTarget.bottomRight: rect.bottomRight,
    };
    _DragTarget? nearest;
    var best = _handleReach;
    corners.forEach((target, corner) {
      final distance = (corner - point).distance;
      if (distance <= best) {
        best = distance;
        nearest = target;
      }
    });
    return nearest ??
        (rect.inflate(8).contains(point) ? _DragTarget.move : null);
  }

  void _handleHover(PointerHoverEvent event, Rect frame) {
    final cursor = switch (_targetAt(event.localPosition, frame)) {
      _DragTarget.topLeft ||
      _DragTarget.bottomRight => SystemMouseCursors.resizeUpLeftDownRight,
      _DragTarget.topRight ||
      _DragTarget.bottomLeft => SystemMouseCursors.resizeUpRightDownLeft,
      _DragTarget.move => SystemMouseCursors.move,
      null => MouseCursor.defer,
    };
    if (cursor != _cursor) setState(() => _cursor = cursor);
  }

  void _attach() =>
      Navigator.of(context).pop(_loadError != null ? fullImageCrop : _crop);

  void _handlePanUpdate(DragUpdateDetails details, Rect frame) {
    final target = _dragTarget;
    if (target == null || frame.width <= 0 || frame.height <= 0) {
      return;
    }
    final dx = details.delta.dx / frame.width;
    final dy = details.delta.dy / frame.height;
    var crop = _crop;
    switch (target) {
      case _DragTarget.move:
        final moveX = dx.clamp(-crop.left, 1 - crop.right);
        final moveY = dy.clamp(-crop.top, 1 - crop.bottom);
        crop = crop.shift(Offset(moveX, moveY));
      case _DragTarget.topLeft:
        crop = Rect.fromLTRB(
          (crop.left + dx).clamp(0.0, crop.right - _minFraction),
          (crop.top + dy).clamp(0.0, crop.bottom - _minFraction),
          crop.right,
          crop.bottom,
        );
      case _DragTarget.topRight:
        crop = Rect.fromLTRB(
          crop.left,
          (crop.top + dy).clamp(0.0, crop.bottom - _minFraction),
          (crop.right + dx).clamp(crop.left + _minFraction, 1.0),
          crop.bottom,
        );
      case _DragTarget.bottomLeft:
        crop = Rect.fromLTRB(
          (crop.left + dx).clamp(0.0, crop.right - _minFraction),
          crop.top,
          crop.right,
          (crop.bottom + dy).clamp(crop.top + _minFraction, 1.0),
        );
      case _DragTarget.bottomRight:
        crop = Rect.fromLTRB(
          crop.left,
          crop.top,
          (crop.right + dx).clamp(crop.left + _minFraction, 1.0),
          (crop.bottom + dy).clamp(crop.top + _minFraction, 1.0),
        );
    }
    setState(() => _crop = crop);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final imageSize = _imageSize;
    final page = Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Attach image'),
        actions: [
          TextButton(
            onPressed: isFullImageCrop(_crop)
                ? null
                : () => setState(() => _crop = fullImageCrop),
            child: const Text('Reset'),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: _loadError != null
                  ? Center(
                      child: Text(
                        'This image cannot be shown. It can still be '
                        'attached uncropped.',
                        style: TextStyle(color: colorScheme.error),
                        textAlign: TextAlign.center,
                      ),
                    )
                  : imageSize == null
                  ? const Center(child: CircularProgressIndicator())
                  : Padding(
                      padding: const EdgeInsets.all(16),
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final frame = _fitted(constraints.biggest, imageSize);
                          final area = GestureDetector(
                            key: const ValueKey('image-crop-area'),
                            onPanStart: (details) =>
                                _handlePanStart(details, frame),
                            onPanUpdate: (details) =>
                                _handlePanUpdate(details, frame),
                            onPanEnd: (_) => _dragTarget = null,
                            child: Stack(
                              children: [
                                Positioned.fromRect(
                                  rect: frame,
                                  child: Image.file(
                                    File(widget.image.path),
                                    fit: BoxFit.fill,
                                    gaplessPlayback: true,
                                  ),
                                ),
                                Positioned.fill(
                                  child: CustomPaint(
                                    painter: _CropPainter(
                                      crop: _toScreen(frame),
                                      frame: frame,
                                      accent: colorScheme.primary,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          );
                          if (!PlatformFeatures.isDesktop) return area;
                          return MouseRegion(
                            cursor: _cursor,
                            onHover: (event) => _handleHover(event, frame),
                            child: area,
                          );
                        },
                      ),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Drag the corners to crop, or attach as is.',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.75),
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _attach,
                    icon: const Icon(Icons.attach_file_rounded),
                    label: const Text('Attach'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    if (!PlatformFeatures.isDesktop) return page;
    // Desktop: Enter attaches, Esc cancels.
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter): _attach,
        const SingleActivator(LogicalKeyboardKey.numpadEnter): _attach,
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).maybePop(),
      },
      child: Focus(autofocus: true, child: page),
    );
  }
}

class _CropPainter extends CustomPainter {
  _CropPainter({required this.crop, required this.frame, required this.accent});

  final Rect crop;
  final Rect frame;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final shade = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(frame)
      ..addRect(crop);
    canvas.drawPath(
      shade,
      Paint()..color = Colors.black.withValues(alpha: 0.55),
    );
    canvas.drawRect(
      crop,
      Paint()
        ..color = accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    final handle = Paint()..color = accent;
    for (final corner in [
      crop.topLeft,
      crop.topRight,
      crop.bottomLeft,
      crop.bottomRight,
    ]) {
      canvas.drawCircle(corner, 9, handle);
    }
  }

  @override
  bool shouldRepaint(_CropPainter oldDelegate) =>
      oldDelegate.crop != crop ||
      oldDelegate.frame != frame ||
      oldDelegate.accent != accent;
}
