import 'package:conduit/core/theme/theme_controller.dart';
import 'package:conduit/features/sftp/domain/sftp_entry.dart';
import 'package:conduit/features/sftp/presentation/sftp_browser_page.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

const _desktops = TargetPlatformVariant({
  TargetPlatform.linux,
  TargetPlatform.windows,
  TargetPlatform.macOS,
});

void main() {
  late ThemeController themeController;

  setUp(() async {
    themeController = ThemeController(InMemoryThemePreferences());
    await themeController.load();
  });

  Future<void> pumpBrowser(
    WidgetTester tester, {
    Size size = const Size(1400, 1000),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final session = FakeSftpSession(
      home: '/home/u',
      tree: {
        '/home/u': const [
          SftpEntry(
            name: 'notes.txt',
            path: '/home/u/notes.txt',
            kind: SftpEntryKind.file,
            size: 3,
          ),
        ],
        '/home': const [
          SftpEntry(name: 'u', path: '/home/u', kind: SftpEntryKind.directory),
        ],
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => openSftpBrowser(
                context,
                host: buildHost('h'),
                repository: FakeSftpRepository(session),
                fileExport: RecordingFileExport(),
                themeController: themeController,
                bookmarksRepository: InMemorySftpBookmarks(),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('desktop: a dialog with header actions, right-click menu and '
      'Backspace to the parent folder', (tester) async {
    await pumpBrowser(tester);
    expect(find.byKey(const ValueKey('desktop-page-frame')), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsNothing);
    expect(find.byTooltip('New folder'), findsOneWidget);
    expect(find.byTooltip('Upload files'), findsOneWidget);
    expect(find.byTooltip('Back'), findsOneWidget);

    await tester.tap(find.text('notes.txt'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('adaptive-modal-popover')),
      findsOneWidget,
    );
    expect(find.text('Copy path'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Copy path'), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pumpAndSettle();
    expect(find.text('notes.txt'), findsNothing);
    expect(find.text('u'), findsWidgets);
  }, variant: _desktops);

  testWidgets('phones keep the full-screen page with floating buttons', (
    tester,
  ) async {
    await pumpBrowser(tester, size: const Size(400, 800));
    expect(find.byKey(const ValueKey('desktop-page-frame')), findsNothing);
    expect(find.byType(FloatingActionButton), findsNWidgets(2));
    expect(find.byTooltip('Upload files'), findsNothing);
    await tester.tap(find.text('notes.txt'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text('Copy path'), findsNothing);
  });
}
