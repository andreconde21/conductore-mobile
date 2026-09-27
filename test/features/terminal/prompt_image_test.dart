import 'dart:io';
import 'dart:ui' as ui;

import 'package:conduit/features/share_target/domain/shared_payload.dart';
import 'package:conduit/features/terminal/data/prompt_image_preparer.dart';
import 'package:conduit/features/terminal/domain/prompt_image.dart';
import 'package:conduit/features/terminal/presentation/widgets/image_crop_page.dart';
import 'package:conduit/features/terminal/presentation/widgets/prompt_composer_sheet.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class _FakeSource implements PromptImageSource {
  _FakeSource(this.result);

  SharedFile? result;
  final picked = <PromptImageOrigin>[];

  @override
  Future<SharedFile?> pick(PromptImageOrigin origin) async {
    picked.add(origin);
    return result;
  }
}

Future<List<int>> _png(int width, int height) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = const ui.Color(0xFF3366FF),
  );
  final image = await recorder.endRecording().toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

Future<ui.Size> _sizeOf(String path) async {
  final codec = await ui.instantiateImageCodec(await File(path).readAsBytes());
  final frame = await codec.getNextFrame();
  final size = ui.Size(
    frame.image.width.toDouble(),
    frame.image.height.toDouble(),
  );
  frame.image.dispose();
  codec.dispose();
  return size;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('prompt image helpers', () {
    test('file names are sortable and space free', () {
      expect(
        promptImageFileName(DateTime(2026, 9, 5, 7, 3, 9), '.JPG'),
        'image-20260905-070309.jpg',
      );
      expect(promptImageFileName(DateTime(2026), ''), endsWith('.png'));
    });

    test('the path is inserted as its own word', () {
      expect(insertPromptImagePath('', 0, 0, '/i/a.png'), (
        text: '/i/a.png ',
        cursor: 9,
      ));
      expect(insertPromptImagePath('look at', 7, 7, '/i/a.png'), (
        text: 'look at /i/a.png ',
        cursor: 17,
      ));
      expect(
        insertPromptImagePath('see  here', 4, 4, '/a.png').text,
        'see /a.png here',
      );
      expect(insertPromptImagePath('x\ny', 2, 2, '/a.png').text, 'x\n/a.png y');
      expect(
        insertPromptImagePath('replace ME', 8, 10, '/a.png').text,
        'replace /a.png ',
      );
    });

    test('full crop detection tolerates rounding', () {
      expect(isFullImageCrop(fullImageCrop), isTrue);
      expect(
        isFullImageCrop(const Rect.fromLTRB(0.0005, 0, 1, 0.9995)),
        isTrue,
      );
      expect(isFullImageCrop(const Rect.fromLTRB(0.1, 0, 1, 1)), isFalse);
    });
  });

  group('PromptImagePreparer', () {
    late Directory temp;

    setUp(() => temp = Directory.systemTemp.createTempSync('prompt-image'));
    tearDown(() => temp.deleteSync(recursive: true));

    PromptImagePreparer preparer({int maxDimension = 2048}) =>
        PromptImagePreparer(
          tempRoot: () async => temp,
          clock: () => DateTime(2026, 9, 25, 14, 30, 5),
          maxDimension: maxDimension,
        );

    testWidgets('copies an uncropped image and removes the picked copy', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final pickedDir = Directory(p.join(temp.path, 'picker'))..createSync();
        final picked = File(p.join(pickedDir.path, 'IMG_1.jpg'))
          ..writeAsBytesSync([1, 2, 3]);
        final prepared = await preparer().prepare(
          SharedFile(path: picked.path, name: 'IMG_1.jpg', size: 3),
          fullImageCrop,
        );
        expect(prepared.name, 'image-20260925-143005.jpg');
        expect(File(prepared.path).readAsBytesSync(), [1, 2, 3]);
        expect(
          p.basename(p.dirname(p.dirname(prepared.path))),
          'prompt-images',
        );
        expect(picked.existsSync(), isFalse);
      });
    });

    testWidgets('crops to the region and caps the longest edge', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final source = File(p.join(temp.path, 'shot.png'))
          ..writeAsBytesSync(await _png(400, 200));
        final half = await preparer().prepare(
          SharedFile(path: source.path, name: 'shot.png'),
          const Rect.fromLTRB(0.5, 0, 1, 0.5),
        );
        expect(half.mimeType, 'image/png');
        expect(await _sizeOf(half.path), const ui.Size(200, 100));

        final again = File(p.join(temp.path, 'shot2.png'))
          ..writeAsBytesSync(await _png(400, 200));
        final capped = await preparer(maxDimension: 100).prepare(
          SharedFile(path: again.path, name: 'shot2.png'),
          const Rect.fromLTRB(0, 0, 1, 0.5),
        );
        expect(await _sizeOf(capped.path), const ui.Size(100, 25));
      });
    });
  });

  group('composer image button', () {
    Future<void> pumpComposer(
      WidgetTester tester,
      PromptImageAttacher attacher, {
      String initialText = '',
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PromptComposerSheet(
              initialText: initialText,
              onDraftChanged: (_) {},
              onSend: (text, {required submit}) async {},
              submitEnter: false,
              onSubmitEnterChanged: (_) {},
              isConnected: () => true,
              imageAttacher: attacher,
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('picks, crops, uploads and inserts the remote path', (
      tester,
    ) async {
      const picked = SharedFile(path: '/cache/a.jpg', name: 'a.jpg');
      final source = _FakeSource(picked);
      final prepared = <(SharedFile, Rect)>[];
      final uploaded = <SharedFile>[];
      await pumpComposer(
        tester,
        PromptImageAttacher(
          source: source,
          crop: (image) async => const Rect.fromLTRB(0, 0, 0.5, 0.5),
          prepare: (image, crop) async {
            prepared.add((image, crop));
            return const SharedFile(
              path: '/cache/prompt-images/x/image.png',
              name: 'image.png',
            );
          },
          upload: (image) async {
            uploaded.add(image);
            return '/home/u/conductore-inbox/image.png';
          },
        ),
        initialText: 'What is wrong here?',
      );

      await tester.tap(find.byTooltip('Attach image'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Gallery'));
      await tester.pumpAndSettle();

      expect(source.picked, [PromptImageOrigin.gallery]);
      expect(prepared.single.$2, const Rect.fromLTRB(0, 0, 0.5, 0.5));
      expect(uploaded.single.name, 'image.png');
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(
        field.controller!.text,
        'What is wrong here? /home/u/conductore-inbox/image.png ',
      );
    });

    testWidgets('an empty clipboard says so and a cancelled crop uploads '
        'nothing', (tester) async {
      final source = _FakeSource(null);
      var uploads = 0;
      Rect? cropResult;
      await pumpComposer(
        tester,
        PromptImageAttacher(
          source: source,
          crop: (image) async => cropResult,
          prepare: (image, crop) async => image,
          upload: (image) async {
            uploads++;
            return '/x.png';
          },
        ),
      );

      await tester.tap(find.byTooltip('Attach image'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Paste image'));
      await tester.pumpAndSettle();
      expect(find.text('There is no image on the clipboard.'), findsOneWidget);

      source.result = const SharedFile(path: '/c/a.png', name: 'a.png');
      await tester.tap(find.byTooltip('Attach image'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Camera'));
      await tester.pumpAndSettle();
      expect(source.picked.last, PromptImageOrigin.camera);
      expect(uploads, 0);
    });

    testWidgets('iOS has no clipboard image bridge, so no Paste image', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        await pumpComposer(
          tester,
          PromptImageAttacher(
            source: _FakeSource(null),
            crop: (image) async => fullImageCrop,
            prepare: (image, crop) async => image,
            upload: (image) async => '/x.png',
          ),
        );
        await tester.tap(find.byTooltip('Attach image'));
        await tester.pumpAndSettle();
        expect(find.text('Gallery'), findsOneWidget);
        expect(find.text('Camera'), findsOneWidget);
        expect(find.text('Paste image'), findsNothing);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('upload failures stay inside the sheet', (tester) async {
      await pumpComposer(
        tester,
        PromptImageAttacher(
          source: _FakeSource(const SharedFile(path: '/a.png', name: 'a.png')),
          crop: (image) async => fullImageCrop,
          prepare: (image, crop) async => image,
          upload: (image) async => throw StateError('no inbox'),
        ),
      );
      await tester.tap(find.byTooltip('Attach image'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Gallery'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Could not attach the image'), findsOneWidget);
    });
  });

  testWidgets('the crop page returns the dragged frame, or the whole image', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync('crop-page');
    addTearDown(() => temp.deleteSync(recursive: true));
    final file = File(p.join(temp.path, 'shot.png'));
    await tester.runAsync(
      () async => file.writeAsBytesSync(await _png(400, 400)),
    );
    final image = SharedFile(path: file.path, name: 'shot.png');

    // The size is read from the file header with real I/O, off the fake
    // clock.
    Future<void> waitForCropArea() async {
      final area = find.byKey(const ValueKey('image-crop-area'));
      for (var i = 0; i < 50 && area.evaluate().isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
    }

    Rect? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async =>
                result = await showImageCropPage(context, image),
            child: const Text('go'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await waitForCropArea();
    expect(find.byKey(const ValueKey('image-crop-area')), findsOneWidget);

    await tester.tap(find.text('Attach'));
    await tester.pumpAndSettle();
    expect(result, fullImageCrop);

    await tester.tap(find.text('go'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await waitForCropArea();
    final area = tester.getRect(find.byKey(const ValueKey('image-crop-area')));
    // The square image fits the narrower side; its bottom-right corner is
    // at the area centre plus half that side.
    final side = area.width < area.height ? area.width : area.height;
    final corner = area.center + Offset(side / 2, side / 2);
    final gesture = await tester.startGesture(corner - const Offset(2, 2));
    await gesture.moveBy(Offset(-side / 4, 0));
    await gesture.moveBy(Offset(-side / 4, -side / 2));
    await gesture.up();
    await tester.pump();
    await tester.tap(find.text('Attach'));
    await tester.pumpAndSettle();
    expect(result!.left, 0);
    expect(result!.top, 0);
    expect(result!.right, closeTo(0.5, 0.05));
    expect(result!.bottom, closeTo(0.5, 0.05));
  });

  Future<void> openCrop(WidgetTester tester) async {
    await tester.tap(find.text('go'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final area = find.byKey(const ValueKey('image-crop-area'));
    for (var i = 0; i < 50 && area.evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
  }

  testWidgets(
    'desktop: the crop page is a dialog; Enter attaches, Esc cancels',
    (tester) async {
      final temp = Directory.systemTemp.createTempSync('crop-desktop');
      addTearDown(() => temp.deleteSync(recursive: true));
      final file = File(p.join(temp.path, 'shot.png'));
      await tester.runAsync(
        () async => file.writeAsBytesSync(await _png(40, 40)),
      );
      final image = SharedFile(path: file.path, name: 'shot.png');
      Rect? result;
      var done = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                done = false;
                result = await showImageCropPage(context, image);
                done = true;
              },
              child: const Text('go'),
            ),
          ),
        ),
      );
      await openCrop(tester);
      expect(find.byKey(const ValueKey('desktop-page-frame')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(done, isTrue);
      expect(result, fullImageCrop);

      await openCrop(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(done, isTrue);
      expect(result, isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.linux,
      TargetPlatform.windows,
      TargetPlatform.macOS,
    }),
  );

  testWidgets('phone: the crop page is a full-screen page', (tester) async {
    final temp = Directory.systemTemp.createTempSync('crop-phone');
    addTearDown(() => temp.deleteSync(recursive: true));
    final file = File(p.join(temp.path, 'shot.png'));
    await tester.runAsync(
      () async => file.writeAsBytesSync(await _png(40, 40)),
    );
    final image = SharedFile(path: file.path, name: 'shot.png');
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showImageCropPage(context, image),
            child: const Text('go'),
          ),
        ),
      ),
    );
    await openCrop(tester);
    expect(find.byType(ImageCropPage), findsOneWidget);
    expect(find.byKey(const ValueKey('desktop-page-frame')), findsNothing);
    expect(
      ModalRoute.of(tester.element(find.byType(ImageCropPage))),
      isA<MaterialPageRoute<Rect>>(),
    );
  });
}
