import 'dart:io';
import 'dart:ui' as ui;

import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/features/live_preview/data/preview_screen_capture.dart';
import 'package:conduit/features/live_preview/data/preview_screenshot_sender.dart';
import 'package:conduit/features/live_preview/domain/live_preview_port_store.dart';
import 'package:conduit/features/live_preview/domain/preview_screenshot.dart';
import 'package:conduit/features/live_preview/domain/preview_viewport.dart';
import 'package:conduit/features/live_preview/presentation/live_preview_controller.dart';
import 'package:conduit/features/live_preview/presentation/live_preview_view.dart';
import 'package:conduit/features/live_preview/presentation/preview_annotate_page.dart';
import 'package:conduit/features/share_target/domain/shared_payload.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import 'live_preview_controller_test.dart' show FakePortForwarder;
import 'live_preview_view_test.dart' show FakeWebViewPlatform;

class _FakeCapture implements PreviewScreenCapture {
  _FakeCapture(this.result);

  final Object result;
  int calls = 0;

  @override
  Future<Uint8List> capture(
    RenderRepaintBoundary boundary,
    double pixelRatio,
  ) async {
    calls++;
    final result = this.result;
    if (result is Uint8List) return result;
    throw result;
  }
}

/// A [width]×[height] PNG filled with [color].
Future<Uint8List> _png(int width, int height, Color color) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = color,
  );
  final image = await recorder.endRecording().toImage(width, height);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return bytes!.buffer.asUint8List();
}

Future<Color> _pixel(Uint8List png, int x, int y) async {
  final codec = await ui.instantiateImageCodec(png);
  final frame = await codec.getNextFrame();
  final data = (await frame.image.toByteData())!;
  final width = frame.image.width;
  frame.image.dispose();
  final offset = (y * width + x) * 4;
  return Color.fromARGB(
    data.getUint8(offset + 3),
    data.getUint8(offset),
    data.getUint8(offset + 1),
    data.getUint8(offset + 2),
  );
}

void main() {
  late FakeWebViewPlatform platform;
  late FakePortForwarder forwarder;
  late InMemoryLivePreviewPortStore store;
  late LivePreviewController controller;

  setUp(() {
    platform = FakeWebViewPlatform();
    WebViewPlatform.instance = platform;
    forwarder = FakePortForwarder();
    store = InMemoryLivePreviewPortStore();
    controller = LivePreviewController(
      forwarder,
      hostId: 'h',
      portStore: store,
    );
  });

  tearDown(() => controller.dispose());

  Widget app({
    Future<void> Function(PreviewScreenshot shot)? onScreenshot,
    PreviewScreenCapture? capture,
    PreviewAnnotator? annotate,
  }) => MaterialApp(
    home: Scaffold(
      body: LivePreviewView(
        controller: controller,
        palette: AppPalette.catppuccin,
        brightness: Brightness.dark,
        onChangePort: () {},
        onScreenshot: onScreenshot,
        screenCapture: capture ?? _FakeCapture(Uint8List(0)),
        annotate:
            annotate ??
            (context, png) async =>
                PreviewAnnotateResult(png: png, note: 'the header overlaps'),
      ),
    ),
  );

  group('viewport toggle', () {
    testWidgets('desktop lays the page out at 1280 px, sends a desktop user '
        'agent, reloads, and is remembered for the port', (tester) async {
      await tester.pumpWidget(app());
      await controller.start(5173);
      await tester.pump();
      expect(
        find.byKey(const ValueKey('preview-viewport-frame')),
        findsNothing,
      );
      expect(platform.controller!.userAgents, isEmpty);

      await tester.tap(find.byKey(const ValueKey('preview-viewport')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Desktop · 1280 px'));
      await tester.pumpAndSettle();

      expect(controller.viewport, PreviewViewport.desktop);
      expect(store.viewports['h:5173'], PreviewViewport.desktop);
      expect(platform.controller!.userAgents, [
        PreviewViewport.desktop.userAgent,
      ]);
      expect(platform.controller!.reloads, 1);
      final webview = tester.getSize(find.byKey(const Key('webview')));
      expect(webview.width, 1280);
      // Scaled to the 800 px test screen.
      final frame = tester.getSize(
        find.byKey(const ValueKey('preview-viewport-frame')),
      );
      expect(frame.width, 800);

      // Back to phone: default user agent again.
      await tester.tap(find.byKey(const ValueKey('preview-viewport')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Phone'));
      await tester.pumpAndSettle();
      expect(platform.controller!.userAgents.last, isNull);
      expect(store.viewports['h:5173'], PreviewViewport.phone);
    });

    testWidgets('a port opens with the viewport chosen for it', (tester) async {
      store.viewports['h:3000'] = PreviewViewport.tablet;
      await tester.pumpWidget(app());
      await controller.start(3000);
      await tester.pump();
      await tester.pump();
      expect(controller.viewport, PreviewViewport.tablet);
      expect(platform.controller!.userAgents, [
        PreviewViewport.tablet.userAgent,
      ]);
      expect(tester.getSize(find.byKey(const Key('webview'))).width, 820);
      await controller.start(4000);
      await tester.pump();
      expect(controller.viewport, PreviewViewport.phone);
    });

    test('scaleFor never enlarges', () {
      expect(PreviewViewport.desktop.scaleFor(640), 0.5);
      expect(PreviewViewport.tablet.scaleFor(2000), 1);
      expect(PreviewViewport.phone.scaleFor(320), 1);
      expect(PreviewViewport.fromName('nope'), PreviewViewport.phone);
    });
  });

  group('screenshot', () {
    testWidgets('capture, annotate, then hand the shot on', (tester) async {
      final shots = <PreviewScreenshot>[];
      final png = Uint8List.fromList([1, 2, 3]);
      final capture = _FakeCapture(png);
      await tester.pumpWidget(
        app(onScreenshot: (shot) async => shots.add(shot), capture: capture),
      );
      await controller.start(5173);
      controller.setPath('/about');
      controller.setViewport(PreviewViewport.tablet);
      await tester.pump();
      await tester.tap(find.byTooltip('Screenshot to the agent'));
      await tester.pump();
      expect(capture.calls, 1);
      expect(shots.single.png, png);
      expect(shots.single.port, 5173);
      expect(shots.single.path, '/about');
      expect(shots.single.viewport, PreviewViewport.tablet);
      expect(shots.single.note, 'the header overlaps');
    });

    testWidgets('cancelling the annotate step sends nothing', (tester) async {
      final shots = <PreviewScreenshot>[];
      await tester.pumpWidget(
        app(
          onScreenshot: (shot) async => shots.add(shot),
          capture: _FakeCapture(Uint8List.fromList([1])),
          annotate: (context, png) async => null,
        ),
      );
      await controller.start(5173);
      await tester.pump();
      await tester.tap(find.byTooltip('Screenshot to the agent'));
      await tester.pump();
      expect(shots, isEmpty);
    });

    testWidgets('a failed capture says so', (tester) async {
      await tester.pumpWidget(
        app(
          onScreenshot: (shot) async {},
          capture: _FakeCapture(
            const PreviewCaptureException('blank on this device'),
          ),
        ),
      );
      await controller.start(5173);
      await tester.pump();
      await tester.tap(find.byTooltip('Screenshot to the agent'));
      await tester.pump();
      expect(
        find.text('Could not capture the page: blank on this device'),
        findsOneWidget,
      );
    });

    testWidgets('no camera without a place to send to', (tester) async {
      await tester.pumpWidget(app());
      await controller.start(5173);
      await tester.pump();
      expect(find.byTooltip('Screenshot to the agent'), findsNothing);
    });

    test('isBlank spots a transparent capture', () {
      expect(PlatformPreviewScreenCapture.isBlank(ByteData(4 * 500)), isTrue);
      final drawn = ByteData(4 * 500)..setUint8(3, 255);
      expect(PlatformPreviewScreenCapture.isBlank(drawn), isFalse);
    });
  });

  group('sender', () {
    test('writes, uploads, and returns the draft', () async {
      final root = await Directory.systemTemp.createTemp('preview-shot');
      addTearDown(() => root.delete(recursive: true));
      final uploaded = <SharedFile>[];
      final sender = PreviewScreenshotSender(
        tempRoot: () async => root,
        clock: () => DateTime(2026, 9, 25, 14, 30, 5),
        upload: (file) async {
          uploaded.add(file);
          expect(await File(file.path).readAsBytes(), [9, 9]);
          return '/home/u/.conductore/inbox/${file.name}';
        },
      );
      final draft = await sender.send(
        PreviewScreenshot(
          png: Uint8List.fromList([9, 9]),
          port: 5173,
          path: '/about',
          viewport: PreviewViewport.desktop,
          note: 'Fix the overlap.',
        ),
      );
      expect(uploaded.single.name, 'preview-5173-20260925-143005.png');
      expect(uploaded.single.mimeType, 'image/png');
      expect(
        draft,
        '/home/u/.conductore/inbox/preview-5173-20260925-143005.png\n'
        'Screenshot of http://localhost:5173/about in the phone\'s Live '
        'preview at desktop width (1280px). Fix the overlap.',
      );
    });

    test('phone width and no note keep the draft short', () {
      expect(
        previewScreenshotDraft(
          '/i/a.png',
          PreviewScreenshot(png: Uint8List(0), port: 3000, path: '/'),
        ),
        '/i/a.png\nScreenshot of http://localhost:3000/ in the phone\'s Live '
        'preview.',
      );
    });
  });

  group('annotate', () {
    testWidgets('burns the marks in at full resolution', (tester) async {
      await tester.runAsync(() async {
        final png = await _png(200, 100, const Color(0xFFFFFFFF));
        final codec = await ui.instantiateImageCodec(png);
        final image = (await codec.getNextFrame()).image;
        final out = await renderAnnotatedPng(image, const [
          PreviewAnnotation(
            kind: PreviewAnnotationKind.rectangle,
            start: Offset(0.1, 0.1),
            end: Offset(0.9, 0.9),
          ),
        ]);
        image.dispose();
        // On the rectangle's left edge: red. In the middle: still white.
        final edge = await _pixel(out, 20, 50);
        expect(edge.r, greaterThan(0.9));
        expect(edge.g, lessThan(0.4));
        final middle = await _pixel(out, 100, 50);
        expect(middle, const Color(0xFFFFFFFF));
      });
    });

    testWidgets('drag draws, the note and image come back on send', (
      tester,
    ) async {
      final png = (await tester.runAsync(
        () => _png(400, 300, const Color(0xFF3366FF)),
      ))!;
      PreviewAnnotateResult? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async =>
                  result = await showPreviewAnnotatePage(context, png),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      // Decoding the image needs real async.
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      final canvas = find.byKey(const ValueKey('annotate-canvas'));
      expect(canvas, findsOneWidget);
      // Phones: a full-screen page, not the desktop dialog.
      expect(find.byKey(const ValueKey('desktop-page-frame')), findsNothing);
      await tester.tap(find.byTooltip('Arrow'));
      await tester.pump();
      final center = tester.getCenter(canvas);
      await tester.dragFrom(center, const Offset(80, 40));
      await tester.pump();
      expect(find.byTooltip('Undo'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('annotate-note')),
        'This arrow',
      );
      await tester.tap(find.byKey(const ValueKey('annotate-send')));
      // Encoding the annotated PNG is real async work; slow CI runners need
      // longer than a fixed delay, so wait for the result itself (max ~10 s).
      for (var i = 0; i < 100 && result == null; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump();
      }
      await tester.pump(const Duration(milliseconds: 400));
      expect(result?.note, 'This arrow');
      expect(result?.png, isNot(png));
    });
    testWidgets(
      'desktop: a dialog; Ctrl/Cmd+Z undoes, Ctrl/Cmd+Enter sends',
      (tester) async {
        tester.view.physicalSize = const Size(1400, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final png = (await tester.runAsync(
          () => _png(400, 300, const Color(0xFF3366FF)),
        ))!;
        PreviewAnnotateResult? result;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () async =>
                    result = await showPreviewAnnotatePage(context, png),
                child: const Text('open'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        for (var i = 0; i < 5; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump();
        }
        expect(
          find.byKey(const ValueKey('desktop-page-frame')),
          findsOneWidget,
        );
        final canvas = find.byKey(const ValueKey('annotate-canvas'));
        IconButton undo() => tester.widget<IconButton>(
          find.ancestor(
            of: find.byIcon(Icons.undo_rounded),
            matching: find.byType(IconButton),
          ),
        );
        await tester.dragFrom(tester.getCenter(canvas), const Offset(80, 40));
        await tester.pump();
        expect(undo().onPressed, isNotNull);
        final modifier = defaultTargetPlatform == TargetPlatform.macOS
            ? LogicalKeyboardKey.metaLeft
            : LogicalKeyboardKey.controlLeft;
        Future<void> chord(LogicalKeyboardKey key) async {
          await tester.sendKeyDownEvent(modifier);
          await tester.sendKeyEvent(key);
          await tester.sendKeyUpEvent(modifier);
          await tester.pump();
        }

        await chord(LogicalKeyboardKey.keyZ);
        expect(undo().onPressed, isNull);
        await chord(LogicalKeyboardKey.enter);
        for (var i = 0; i < 100 && result == null; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)),
          );
          await tester.pump();
        }
        await tester.pump(const Duration(milliseconds: 400));
        expect(result?.png, png);
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.linux,
        TargetPlatform.windows,
        TargetPlatform.macOS,
      }),
    );
  });
}
