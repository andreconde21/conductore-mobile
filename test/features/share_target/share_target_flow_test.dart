import 'dart:async';
import 'dart:io';

import 'package:conduit/core/theme/theme_controller.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/sftp/domain/sftp_entry.dart';
import 'package:conduit/features/share_target/data/sftp_share_uploader.dart';
import 'package:conduit/features/share_target/domain/share_target_source.dart';
import 'package:conduit/features/share_target/domain/shared_payload.dart';
import 'package:conduit/features/share_target/presentation/share_target_controller.dart';
import 'package:conduit/features/share_target/presentation/share_target_host.dart';
import 'package:conduit/features/share_target/presentation/share_target_scope.dart';
import 'package:conduit/features/terminal/presentation/terminal_page.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

import '../../support/test_doubles.dart';

class _NoopWakelock extends WakelockPlusPlatformInterface {
  @override
  Future<void> toggle({required bool enable}) async {}

  @override
  Future<bool> get enabled async => false;
}

class FakeShareTargetSource implements ShareTargetSource {
  final _controller = StreamController<SharedPayload>.broadcast();
  final List<SharedPayload> pending = [];

  @override
  Stream<SharedPayload> get shares => _controller.stream;

  @override
  Future<List<SharedPayload>> takePending() async {
    final drained = List<SharedPayload>.from(pending);
    pending.clear();
    return drained;
  }

  void add(SharedPayload payload) => _controller.add(payload);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  WakelockPlusPlatformInterface.instance = _NoopWakelock();

  late TerminalWorkspaceController workspace;
  late FakeSftpSession sftpSession;
  late FakeShareTargetSource source;
  late ShareTargetController controller;
  late ThemeController themeController;

  Future<TerminalSessionController> openSession(
    WidgetTester tester,
    String id, {
    bool connect = true,
  }) async {
    final session = workspace.open(buildHost(id));
    if (connect) {
      // connect() must run outside the fake-async zone.
      await tester.runAsync(session.connect);
    }
    return session;
  }

  Future<void> pumpHost(WidgetTester tester) async {
    await tester.pumpWidget(
      ShareTargetScope(
        controller: controller,
        child: MaterialApp(
          home: ShareTargetHost(
            controller: controller,
            workspace: workspace,
            terminalPageBuilder: (_) => TerminalPage(
              workspace: workspace,
              themeController: themeController,
              sftpRepository: NoNetworkSftpRepository(),
            ),
            child: const Scaffold(body: Center(child: Text('home'))),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  // pumpAndSettle never settles under the terminal's blinking cursor, so
  // route transitions are advanced with bounded pumps instead.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i += 1) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// Runs the share outside the fake-async zone so file IO completes, then
  /// waits for the controller to leave the transient phases.
  Future<void> share(WidgetTester tester, SharedPayload payload) async {
    await tester.runAsync(() async {
      source.add(payload);
      for (var i = 0; i < 200; i += 1) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        if (controller.phase != ShareTargetPhase.uploading &&
            controller.pending == null) {
          return;
        }
        if (controller.phase == ShareTargetPhase.failed ||
            controller.phase == ShareTargetPhase.choosingSession ||
            controller.phase == ShareTargetPhase.waitingForSession) {
          return;
        }
      }
    });
    await tester.pump();
  }

  /// Confirms the upload by picking [hostName] in the picker.
  Future<void> confirmUpload(WidgetTester tester, String hostName) async {
    await settle(tester);
    expect(controller.phase, ShareTargetPhase.choosingSession);
    expect(find.text('Upload to which machine?'), findsOneWidget);
    await tester.tap(find.text(hostName));
    // The upload starts in the test's fake-async zone: pump it along.
    for (var i = 0; i < 200; i += 1) {
      await tester.pump(const Duration(milliseconds: 5));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 2)),
      );
      if (controller.pending == null ||
          controller.phase == ShareTargetPhase.failed) {
        break;
      }
    }
  }

  setUp(() {
    workspace = TerminalWorkspaceController(
      ImmediateTerminalRepository(TrackableTerminalSession()),
    );
    sftpSession = FakeSftpSession(home: '/home/user', tree: {'/home/user': []});
    source = FakeShareTargetSource();
    themeController = ThemeController(InMemoryThemePreferences());
    controller = ShareTargetController(
      source: source,
      workspace: workspace,
      uploader: SftpShareUploader(FakeSftpRepository(sftpSession)),
    );
    unawaited(controller.start());
  });

  tearDown(() {
    controller.dispose();
    workspace.dispose();
  });

  testWidgets('uploads a shared file to the inbox and opens the composer '
      'with its remote path', (tester) async {
    final temp = Directory.systemTemp.createTempSync('conductore-share');
    addTearDown(() {
      // The uploader removes the cache copy and its emptied directory.
      if (temp.existsSync()) {
        temp.deleteSync(recursive: true);
      }
    });
    final cached = File('${temp.path}/photo.png')..writeAsBytesSync([1, 2, 3]);
    final session = await openSession(tester, 'a');
    await pumpHost(tester);

    await share(
      tester,
      SharedPayload(
        text: 'Look at this',
        files: [SharedFile(path: cached.path, name: 'photo.png', size: 3)],
      ),
    );
    // Files never go anywhere without the user picking the machine.
    expect(sftpSession.writtenFiles, isEmpty);
    await confirmUpload(tester, 'Host a');

    expect(controller.phase, ShareTargetPhase.idle);
    expect(sftpSession.madeDirectories, ['/home/user/conductore-inbox']);
    expect(sftpSession.writtenFiles['/home/user/conductore-inbox/photo.png'], [
      1,
      2,
      3,
    ]);
    expect(cached.existsSync(), isFalse, reason: 'cache copy is cleaned up');
    expect(sftpSession.closeCalls, 1);
    expect(workspace.activeSession, session);

    // No terminal page was showing, so the host pushes one; the page moves
    // the draft into Chat mode and opens the composer.
    await settle(tester);
    expect(find.byType(TerminalPage), findsOneWidget);
    expect(find.text('Chat mode'), findsOneWidget);
    final field = tester.widget<TextField>(
      find.descendant(
        of: find.byType(BottomSheet),
        matching: find.byType(TextField),
      ),
    );
    expect(
      field.controller!.text,
      'Look at this\n\n/home/user/conductore-inbox/photo.png',
    );
    expect(controller.hasDraft('a'), isFalse);
  });

  testWidgets('uses the per-host inbox directory and avoids overwriting', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync('conductore-share');
    addTearDown(() {
      // The uploader removes the cache copy and its emptied directory.
      if (temp.existsSync()) {
        temp.deleteSync(recursive: true);
      }
    });
    final cached = File('${temp.path}/notes.txt')..writeAsStringSync('hi');
    sftpSession.tree['/home/user/drop'] = [entry(SftpEntryKind.file)];
    workspace.open(buildHost('a').copyWith(shareInboxDirectory: '~/drop'));
    await tester.runAsync(workspace.sessions.single.connect);
    await pumpHost(tester);

    await share(
      tester,
      SharedPayload(
        files: [SharedFile(path: cached.path, name: 'x', size: 2)],
      ),
    );
    await confirmUpload(tester, 'Host a');

    expect(sftpSession.madeDirectories, isEmpty);
    expect(sftpSession.writtenFiles.keys, ['/home/user/drop/x (2)']);
    await settle(tester);
    // Once in the inline bar's draft, once in the composer sheet.
    expect(find.text('/home/user/drop/x (2)'), findsNWidgets(2));
  });

  testWidgets('parks the share behind a banner until a session connects', (
    tester,
  ) async {
    await pumpHost(tester);

    await share(tester, const SharedPayload(text: 'later'));

    expect(controller.phase, ShareTargetPhase.waitingForSession);
    expect(find.text('Shared content waiting'), findsOneWidget);
    expect(find.byType(TerminalPage), findsNothing);

    final session = await openSession(tester, 'b', connect: false);
    await tester.pump();
    expect(controller.phase, ShareTargetPhase.waitingForSession);

    await tester.runAsync(session.connect);
    await tester.pump();
    expect(controller.phase, ShareTargetPhase.idle);
    expect(find.text('Shared content waiting'), findsNothing);

    await settle(tester);
    expect(find.byType(TerminalPage), findsOneWidget);
    expect(find.text('Chat mode'), findsOneWidget);
    // Once in the inline bar's draft, once in the composer sheet.
    expect(find.text('later'), findsNWidgets(2));
  });

  testWidgets('the banner can discard a parked share', (tester) async {
    await pumpHost(tester);
    await share(tester, const SharedPayload(text: 'later'));
    expect(find.text('Shared content waiting'), findsOneWidget);

    await tester.tap(find.text('Discard'));
    await tester.pump();

    expect(controller.pending, isNull);
    expect(controller.phase, ShareTargetPhase.idle);
    expect(find.text('Shared content waiting'), findsNothing);
  });

  testWidgets('asks which session to use when several are open', (
    tester,
  ) async {
    await openSession(tester, 'a');
    final second = await openSession(tester, 'b');
    await pumpHost(tester);

    await share(tester, const SharedPayload(text: 'pick one'));
    await settle(tester);

    expect(controller.phase, ShareTargetPhase.choosingSession);
    expect(find.text('Send to which session?'), findsOneWidget);

    await tester.tap(find.text('Host b'));
    await settle(tester);

    expect(controller.phase, ShareTargetPhase.idle);
    expect(workspace.activeSession, second);
    expect(find.byType(TerminalPage), findsOneWidget);
    // Once in the inline bar's draft, once in the composer sheet.
    expect(find.text('pick one'), findsNWidgets(2));
  });

  testWidgets('a failed upload offers retry or discard', (tester) async {
    controller.dispose();
    controller = ShareTargetController(
      source: source,
      workspace: workspace,
      uploader: SftpShareUploader(ThrowingSftpRepository()),
    );
    unawaited(controller.start());
    final temp = Directory.systemTemp.createTempSync('conductore-share');
    addTearDown(() => temp.deleteSync(recursive: true));
    final cached = File('${temp.path}/file.bin')..writeAsBytesSync([1]);
    await openSession(tester, 'a');
    await pumpHost(tester);

    await share(
      tester,
      SharedPayload(
        files: [SharedFile(path: cached.path, name: 'file.bin', size: 1)],
      ),
    );
    await confirmUpload(tester, 'Host a');
    await settle(tester);

    expect(controller.phase, ShareTargetPhase.failed);
    expect(find.text('Could not send the shared content'), findsOneWidget);

    await tester.tap(find.text('Discard'));
    await settle(tester);

    expect(controller.phase, ShareTargetPhase.idle);
    expect(controller.pending, isNull);
    expect(find.byType(TerminalPage), findsNothing);
  });

  testWidgets('local shells receive the cached path without an upload', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync('conductore-share');
    addTearDown(() => temp.deleteSync(recursive: true));
    final cached = File('${temp.path}/a.txt')..writeAsStringSync('a');
    workspace.open(SavedHost.localShell(id: 'local-1', name: 'Local'));
    await tester.runAsync(workspace.sessions.single.connect);
    await pumpHost(tester);

    await share(
      tester,
      SharedPayload(
        files: [SharedFile(path: cached.path, name: 'a.txt')],
      ),
    );
    await confirmUpload(tester, 'Local');
    await settle(tester);

    expect(sftpSession.writtenFiles, isEmpty);
    // Once in the inline bar's draft, once in the composer sheet.
    expect(find.text(cached.path), findsNWidgets(2));
  });

  testWidgets('dismissing the upload picker uploads nothing', (tester) async {
    final temp = Directory.systemTemp.createTempSync('conductore-share');
    addTearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });
    final cached = File('${temp.path}/id_ed25519')..writeAsStringSync('k');
    await openSession(tester, 'a');
    await pumpHost(tester);

    await share(
      tester,
      SharedPayload(
        files: [SharedFile(path: cached.path, name: 'id_ed25519', size: 1)],
      ),
    );
    await settle(tester);
    expect(find.text('Upload to which machine?'), findsOneWidget);

    await tester.tapAt(const Offset(5, 5));
    await settle(tester);

    expect(sftpSession.writtenFiles, isEmpty);
    expect(controller.pending, isNull);
    expect(controller.phase, ShareTargetPhase.idle);
  });
}
