import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/core/theme/theme_controller.dart';
import 'package:conduit/core/theme/theme_preferences_repository.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/sftp/domain/sftp_repository.dart';
import 'package:conduit/features/sftp/domain/sftp_session.dart';
import 'package:conduit/features/share_target/domain/shared_payload.dart';
import 'package:conduit/features/terminal/data/prompt_image_preparer.dart';
import 'package:conduit/features/terminal/domain/clipboard_image_paste.dart';
import 'package:conduit/features/terminal/domain/prompt_image.dart';
import 'package:conduit/features/terminal/presentation/terminal_page.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

import '../../support/test_doubles.dart';

class _NoopWakelock extends WakelockPlusPlatformInterface {
  @override
  Future<void> toggle({required bool enable}) async {}

  @override
  Future<bool> get enabled async => false;
}

/// The phone clipboard: an image file, or nothing (text only).
class _ClipboardSource implements PromptImageSource {
  _ClipboardSource(this.image);

  SharedFile? image;
  final List<PromptImageOrigin> picks = [];

  @override
  Future<SharedFile?> pick(PromptImageOrigin origin) async {
    picks.add(origin);
    return origin == PromptImageOrigin.clipboard ? image : null;
  }
}

/// Tells when the terminal next sends something to the host.
class _WatchedTerminalSession extends TrackableTerminalSession {
  Completer<void>? _next;

  /// Completes on the next [send].
  Future<void> nextSend() => (_next = Completer<void>()).future;

  @override
  Future<void> send(List<int> data) {
    final sent = super.send(data);
    _next?.complete();
    _next = null;
    return sent;
  }
}

/// SFTP that fails to connect, and tells when it was asked to.
class _FailingSftpRepository extends ThrowingSftpRepository {
  Completer<void>? _next;

  /// Completes on the next [connect].
  Future<void> nextAttempt() => (_next = Completer<void>()).future;

  @override
  Future<SftpSession> connect(SavedHost host) {
    _next?.complete();
    _next = null;
    return super.connect(host);
  }
}

const _remotePath = '/home/user/conductore-inbox/image-20260925-143005.png';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  WakelockPlusPlatformInterface.instance = _NoopWakelock();

  late Directory temp;
  late File clipboardFile;
  String? clipboardText;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('image-paste');
    clipboardFile = File('${temp.path}/clipboard/clipboard.png')
      ..createSync(recursive: true)
      ..writeAsBytesSync([0x89, 0x50, 0x4e, 0x47, 1, 2, 3]);
    clipboardText = 'hello';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.getData') {
            return clipboardText == null ? null : {'text': clipboardText};
          }
          return null;
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    if (temp.existsSync()) await temp.delete(recursive: true);
  });

  SharedFile clipboardImage() => SharedFile(
    path: clipboardFile.path,
    name: 'clipboard.png',
    size: 7,
    mimeType: 'image/png',
  );

  Future<({_WatchedTerminalSession remote, FakeSftpSession sftp})> pumpPage(
    WidgetTester tester, {
    required _ClipboardSource source,
    SftpRepository? sftpRepository,
    bool pasteImages = true,
    bool bracketedPaste = false,
  }) async {
    final remote = _WatchedTerminalSession();
    final workspace = TerminalWorkspaceController(
      ImmediateTerminalRepository(remote),
    );
    addTearDown(workspace.dispose);
    final themeController = ThemeController(InMemoryThemePreferences());
    await themeController.setPasteImagesAsFiles(pasteImages);
    final session = workspace.open(buildHost('a'));
    await tester.runAsync(session.connect);
    workspace.activate(session);
    if (bracketedPaste) session.terminal.write('\x1b[?2004h');
    final sftp = FakeSftpSession(home: '/home/user', tree: {'/home/user': []});
    await tester.pumpWidget(
      MaterialApp(
        home: TerminalPage(
          workspace: workspace,
          themeController: themeController,
          sftpRepository: sftpRepository ?? FakeSftpRepository(sftp),
          promptImageSource: source,
          promptImagePreparer: PromptImagePreparer(
            tempRoot: () async => temp,
            clock: () => DateTime(2026, 9, 25, 14, 30, 5),
          ),
        ),
      ),
    );
    await tester.pump();
    remote.sent.clear();
    return (remote: remote, sftp: sftp);
  }

  /// Taps Paste and waits, in real time (the image is copied and read
  /// from disk), until the paste reached its end, as [until] tells. The
  /// timeout only turns a hang into a failure; no test depends on how
  /// long the paste takes.
  Future<void> tapPaste(
    WidgetTester tester, {
    required Future<void> Function() until,
  }) async {
    await tester.runAsync(() async {
      // Made here, not in the test's fake-async zone, whose microtasks
      // only run on a pump.
      final done = until();
      await tester.tap(find.byKey(const ValueKey('toolbar-paste')));
      await done.timeout(const Duration(seconds: 30));
      // What follows in the same flow (the snackbar, clearing the status
      // chip) is microtasks, which all run before this timer.
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();
  }

  String typed(_WatchedTerminalSession remote) =>
      utf8.decode(remote.sent.expand((chunk) => chunk).toList());

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('an image on the clipboard is uploaded and its path pasted '
      'as a bracketed paste, without Enter', (tester) async {
    final (:remote, :sftp) = await pumpPage(
      tester,
      source: _ClipboardSource(clipboardImage()),
      bracketedPaste: true,
    );
    await tapPaste(tester, until: remote.nextSend);

    expect(sftp.writtenFiles.keys, [_remotePath]);
    expect(sftp.writtenFiles[_remotePath], [0x89, 0x50, 0x4e, 0x47, 1, 2, 3]);
    expect(typed(remote), '\x1b[200~$_remotePath\x1b[201~');
    expect(find.byKey(const ValueKey('paste-status-chip')), findsNothing);
    await finish(tester);
  });

  testWidgets('without bracketed paste the path is typed as is', (
    tester,
  ) async {
    final (:remote, sftp: _) = await pumpPage(
      tester,
      source: _ClipboardSource(clipboardImage()),
    );
    await tapPaste(tester, until: remote.nextSend);
    expect(typed(remote), _remotePath);
    await finish(tester);
  });

  testWidgets('a text clipboard pastes the text as before', (tester) async {
    final source = _ClipboardSource(null);
    final (:remote, :sftp) = await pumpPage(tester, source: source);
    await tapPaste(tester, until: remote.nextSend);
    expect(source.picks, [PromptImageOrigin.clipboard]);
    expect(sftp.writtenFiles, isEmpty);
    expect(typed(remote), 'hello');
    await finish(tester);
  });

  testWidgets('with the setting off an image is not even looked for', (
    tester,
  ) async {
    final source = _ClipboardSource(clipboardImage());
    final (:remote, :sftp) = await pumpPage(
      tester,
      source: source,
      pasteImages: false,
    );
    await tapPaste(tester, until: remote.nextSend);
    expect(source.picks, isEmpty);
    expect(sftp.writtenFiles, isEmpty);
    expect(typed(remote), 'hello');
    await finish(tester);
  });

  testWidgets('a failed upload says so and types nothing', (tester) async {
    final sftpRepository = _FailingSftpRepository();
    final (:remote, sftp: _) = await pumpPage(
      tester,
      source: _ClipboardSource(clipboardImage()),
      sftpRepository: sftpRepository,
    );
    await tapPaste(tester, until: sftpRepository.nextAttempt);
    expect(find.byKey(const ValueKey('paste-image-failed')), findsOneWidget);
    expect(find.textContaining('Could not paste the image'), findsOneWidget);
    expect(typed(remote), isEmpty);
    await finish(tester);
  });

  test('"Paste images as uploaded files" defaults on and persists', () async {
    final repository = ThemePreferencesRepository(InMemorySecureStorage());
    expect((await repository.load()).pasteImagesAsFiles, isTrue);
    await repository.save(
      const ThemePreferences(
        themeMode: ThemeMode.dark,
        palette: AppPalette.everforest,
        pasteImagesAsFiles: false,
      ),
    );
    expect((await repository.load()).pasteImagesAsFiles, isFalse);
  });

  group('ClipboardImagePaster', () {
    test('no image: null, nothing uploaded', () async {
      var uploads = 0;
      var uploading = 0;
      final paster = ClipboardImagePaster(
        read: () async => null,
        prepare: (image) async => image,
        upload: (image) async {
          uploads++;
          return '/x';
        },
      );
      expect(await paster.paste(onUploading: () => uploading++), isNull);
      expect(uploads, 0);
      expect(uploading, 0);
    });

    test('image: prepared, uploaded, path returned', () async {
      const image = SharedFile(path: '/c/clipboard.png', name: 'clipboard.png');
      const prepared = SharedFile(path: '/t/image-1.png', name: 'image-1.png');
      final uploaded = <SharedFile>[];
      var uploading = 0;
      final paster = ClipboardImagePaster(
        read: () async => image,
        prepare: (file) async => prepared,
        upload: (file) async {
          uploaded.add(file);
          return '/home/u/conductore-inbox/image-1.png';
        },
      );
      expect(
        await paster.paste(onUploading: () => uploading++),
        '/home/u/conductore-inbox/image-1.png',
      );
      expect(uploaded.single.path, prepared.path);
      expect(uploading, 1);
    });

    test('an upload failure propagates', () async {
      final paster = ClipboardImagePaster(
        read: () async => const SharedFile(path: '/c/a.png', name: 'a.png'),
        prepare: (file) async => file,
        upload: (file) async => throw StateError('no sftp'),
      );
      await expectLater(paster.paste(), throwsStateError);
    });
  });
}
