import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_controller.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_page.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/share_target/data/sftp_share_uploader.dart';
import 'package:conduit/features/share_target/domain/share_target_source.dart';
import 'package:conduit/features/share_target/domain/share_uploader.dart';
import 'package:conduit/features/share_target/domain/shared_payload.dart';
import 'package:conduit/features/share_target/presentation/share_target_controller.dart';
import 'package:conduit/features/share_target/presentation/share_target_host.dart';
import 'package:conduit/features/share_target/presentation/share_target_scope.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

class _Source implements ShareTargetSource {
  final _shares = StreamController<SharedPayload>.broadcast();

  @override
  Stream<SharedPayload> get shares => _shares.stream;

  @override
  Future<List<SharedPayload>> takePending() async => const [];
}

/// An SFTP session whose writes can stall after the first chunk, like a
/// connection that died while the phone switched networks.
class _StallingSftpSession extends FakeSftpSession {
  _StallingSftpSession() : super(home: '/home/user', tree: {'/home/user': []});

  bool stall = true;
  int writes = 0;

  @override
  Future<void> write(
    String path,
    Stream<Uint8List> data,
    int length, {
    void Function(int bytesSent)? onProgress,
  }) async {
    writes += 1;
    if (!stall) {
      return super.write(path, data, length, onProgress: onProgress);
    }
    onProgress?.call(1);
    await Completer<void>().future;
  }
}

/// An uploader driven by the test: reports progress on demand and
/// finishes when told.
class _ScriptedUploader implements ShareUploader {
  Completer<List<String>> result = Completer();
  void Function(ShareUploadProgress progress)? report;

  /// Progress sent synchronously as the upload starts, before any frame.
  List<ShareUploadProgress> burst = const [];

  @override
  Future<List<String>> upload(
    SavedHost host,
    List<SharedFile> files, {
    void Function(ShareUploadProgress progress)? onProgress,
  }) {
    report = onProgress;
    for (final progress in burst) {
      onProgress?.call(progress);
    }
    return result.future;
  }
}

ShareUploadProgress _progress(int sent, [int total = 2 * 1024 * 1024]) =>
    ShareUploadProgress(
      fileName: 'photo.jpg',
      index: 0,
      count: 1,
      sent: sent,
      total: total,
    );

void main() {
  late Directory temp;
  late TerminalWorkspaceController workspace;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('conductore-share-hang');
    workspace = TerminalWorkspaceController(
      ImmediateTerminalRepository(TrackableTerminalSession()),
    );
  });

  tearDown(() {
    workspace.dispose();
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  SharedFile cachedFile([String name = 'photo.jpg']) {
    final file = File('${temp.path}/$name')..writeAsBytesSync([1, 2, 3]);
    return SharedFile(path: file.path, name: name, size: 3);
  }

  group('controller', () {
    test('a parked file share asks for the machine once one session '
        'connects (it used to wait forever)', () async {
      final session = _StallingSftpSession()..stall = false;
      final controller = ShareTargetController(
        source: _Source(),
        workspace: workspace,
        uploader: SftpShareUploader(FakeSftpRepository(session)),
      );
      addTearDown(controller.dispose);
      // Shared from the gallery with nothing open: parked.
      controller.receive(SharedPayload(files: [cachedFile()]));
      expect(controller.phase, ShareTargetPhase.waitingForSession);

      // The user opens a workspace from home; it connects.
      final terminal = workspace.open(buildHost('a'));
      await terminal.connect();

      expect(controller.phase, ShareTargetPhase.choosingSession);
      await controller.deliverTo(terminal);
      expect(controller.phase, ShareTargetPhase.idle);
      expect(session.writtenFiles.keys, [
        '/home/user/conductore-inbox/photo.jpg',
      ]);
      expect(
        controller.takeDraft('a'),
        '/home/user/conductore-inbox/photo.jpg',
      );
    });

    test('a stalled upload times out with a clear error, and Retry '
        'uploads it', () async {
      final session = _StallingSftpSession();
      final controller = ShareTargetController(
        source: _Source(),
        workspace: workspace,
        uploader: SftpShareUploader(
          FakeSftpRepository(session),
          stallTimeout: const Duration(milliseconds: 50),
        ),
      );
      addTearDown(controller.dispose);
      final terminal = workspace.open(buildHost('a'));
      await terminal.connect();
      controller.receive(SharedPayload(files: [cachedFile()]));
      expect(controller.phase, ShareTargetPhase.choosingSession);

      await controller.deliverTo(terminal);

      expect(controller.phase, ShareTargetPhase.failed);
      expect(controller.error, contains('stalled'));
      expect(controller.error, contains('Host a'));
      expect(controller.canRetry, isTrue);
      expect(session.closeCalls, 1, reason: 'the dead session is closed');

      session.stall = false;
      await controller.retry();

      expect(controller.phase, ShareTargetPhase.idle);
      expect(session.writes, 2);
      expect(
        controller.takeDraft('a'),
        '/home/user/conductore-inbox/photo.jpg',
      );
    });

    test('a share whose stream could not be read says so, without Retry '
        '(lost URI grant)', () {
      final controller = ShareTargetController(
        source: _Source(),
        workspace: workspace,
        uploader: _ScriptedUploader(),
      );
      addTearDown(controller.dispose);
      final payload = SharedPayload.fromMap({
        'files': <Object?>[],
        'unreadable': ['IMG_0042.jpg'],
      });
      expect(payload, isNotNull);

      controller.receive(payload!);

      expect(controller.phase, ShareTargetPhase.failed);
      expect(controller.error, contains('IMG_0042.jpg'));
      expect(controller.canRetry, isFalse);
      controller.discard();
      expect(controller.phase, ShareTargetPhase.idle);
    });

    test('a cached copy that is gone fails at once, without Retry', () async {
      final controller = ShareTargetController(
        source: _Source(),
        workspace: workspace,
        uploader: SftpShareUploader(
          FakeSftpRepository(_StallingSftpSession()..stall = false),
        ),
      );
      addTearDown(controller.dispose);
      final terminal = workspace.open(buildHost('a'));
      await terminal.connect();
      controller.receive(
        SharedPayload(
          files: [SharedFile(path: '${temp.path}/gone.jpg', name: 'gone.jpg')],
        ),
      );

      await controller.deliverTo(terminal);

      expect(controller.phase, ShareTargetPhase.failed);
      expect(controller.error, contains('gone.jpg'));
      expect(controller.canRetry, isFalse);
    });

    test('an open Chat View of the host takes the draft', () async {
      final uploader = _ScriptedUploader();
      final controller = ShareTargetController(
        source: _Source(),
        workspace: workspace,
        uploader: uploader,
      );
      addTearDown(controller.dispose);
      final received = <String>[];
      controller.addDraftReceiver((hostId, draft) {
        if (hostId != 'a') return false;
        received.add(draft);
        return true;
      });
      final terminal = workspace.open(buildHost('a'));
      await terminal.connect();
      controller.receive(SharedPayload(files: [cachedFile()]));
      final delivery = controller.deliverTo(terminal);
      uploader.result.complete(['/home/user/conductore-inbox/photo.jpg']);
      await delivery;

      expect(received, ['/home/user/conductore-inbox/photo.jpg']);
      expect(controller.hasDraft('a'), isFalse);
      expect(controller.takeReadyHostId(), isNull);
    });
  });

  group('progress dialog', () {
    late _ScriptedUploader uploader;
    late ShareTargetController controller;

    Future<TerminalSessionController> pumpHost(WidgetTester tester) async {
      uploader = _ScriptedUploader();
      controller = ShareTargetController(
        source: _Source(),
        workspace: workspace,
        uploader: uploader,
      );
      addTearDown(controller.dispose);
      final terminal = workspace.open(buildHost('a'));
      await tester.runAsync(terminal.connect);
      await tester.pumpWidget(
        ShareTargetScope(
          controller: controller,
          child: MaterialApp(
            home: ShareTargetHost(
              controller: controller,
              workspace: workspace,
              terminalPageBuilder: (_) => const Scaffold(body: Text('term')),
              child: const Scaffold(body: Text('home')),
            ),
          ),
        ),
      );
      return terminal;
    }

    // The indeterminate "Connecting…" bar never settles.
    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 10; i += 1) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Future<void> pickHost(WidgetTester tester) async {
      await tester.pumpAndSettle();
      expect(find.text('Upload to which machine?'), findsOneWidget);
      await tester.tap(find.text('Host a'));
      await settle(tester);
    }

    testWidgets('shows connecting, then real byte progress, and closes on '
        'success', (tester) async {
      await pumpHost(tester);
      controller.receive(SharedPayload(files: [cachedFile()]));
      await pickHost(tester);

      expect(find.text('Connecting to Host a…'), findsOneWidget);
      uploader.report!(_progress(512 * 1024));
      await tester.pump();
      expect(find.text('photo.jpg'), findsOneWidget);
      expect(find.text('512 KB of 2.0 MB'), findsOneWidget);
      final bar = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(bar.value, closeTo(0.25, 0.001));

      uploader.result.complete(['/home/user/conductore-inbox/photo.jpg']);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('share-progress')), findsNothing);
      expect(find.text('term'), findsOneWidget);
    });

    testWidgets('progress arriving before the dialog is built opens one '
        'dialog, which closes (it used to leave a "Connecting…" dialog '
        'stuck)', (tester) async {
      await pumpHost(tester);
      controller.receive(SharedPayload(files: [cachedFile()]));
      uploader.burst = [_progress(0), _progress(1024), _progress(4096)];
      await pickHost(tester);

      expect(find.byKey(const ValueKey('share-progress')), findsOneWidget);
      uploader.result.complete(['/home/user/conductore-inbox/photo.jpg']);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('share-progress')), findsNothing);
      expect(find.text('Connecting…'), findsNothing);
    });

    testWidgets('Cancel gives up on a hung upload and offers Retry', (
      tester,
    ) async {
      await pumpHost(tester);
      controller.receive(SharedPayload(files: [cachedFile()]));
      await pickHost(tester);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(controller.phase, ShareTargetPhase.failed);
      expect(find.byKey(const ValueKey('share-progress')), findsNothing);
      expect(find.text('The upload was cancelled.'), findsOneWidget);

      // The abandoned upload finishing late changes nothing.
      uploader.result.complete(['/late']);
      await tester.pump();
      expect(controller.phase, ShareTargetPhase.failed);

      uploader.result = Completer();
      await tester.tap(find.text('Retry'));
      await settle(tester);
      expect(find.byKey(const ValueKey('share-progress')), findsOneWidget);
      uploader.result.complete(['/home/user/conductore-inbox/photo.jpg']);
      await tester.pumpAndSettle();
      expect(controller.phase, ShareTargetPhase.idle);
    });

    testWidgets('an unreadable share offers only Discard', (tester) async {
      await pumpHost(tester);
      controller.receive(const SharedPayload(unreadable: ['IMG_0042.jpg']));
      await tester.pumpAndSettle();

      expect(find.text('Could not send the shared content'), findsOneWidget);
      expect(find.textContaining('IMG_0042.jpg'), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();
      expect(controller.phase, ShareTargetPhase.idle);
    });

    testWidgets('with Chat View open for that machine, the path lands in '
        'its composer', (tester) async {
      final terminal = await pumpHost(tester);
      final chat = ChatViewController(
        runner: ScriptedAgentCommandRunner([
          const AgentCommandResult(stdout: '{}', stderr: '', exitCode: 0),
        ]),
        sessionId: 's-1',
        pollInterval: const Duration(days: 1),
      );
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      unawaited(
        navigator.push(
          MaterialPageRoute<void>(
            builder: (_) => ChatViewPage(
              controller: chat,
              onOpenTerminal: () {},
              hostId: 'a',
              initialDraft: 'See',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      controller.receive(SharedPayload(files: [cachedFile()]));
      await pickHost(tester);
      uploader.result.complete(['/home/user/conductore-inbox/photo.jpg']);
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('chat-composer-field')),
      );
      expect(
        field.controller!.text,
        'See\n\n/home/user/conductore-inbox/photo.jpg',
      );
      expect(find.text('term'), findsNothing, reason: 'Chat View stays');
      expect(workspace.activeSession, terminal);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
