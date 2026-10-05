import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit/features/agent_attention/data/conductore_host_attention_provider.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_controller.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_launcher.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_page.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/share_target/domain/shared_payload.dart';
import 'package:conduit/features/terminal/data/keyboard_image_file.dart';
import 'package:conduit/features/terminal/domain/prompt_image.dart';
import 'package:conduit/features/terminal/presentation/prompt_image_scope.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:conduit/features/terminal/presentation/widgets/prompt_composer_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

class _Source implements PromptImageSource {
  _Source(this.image);

  final SharedFile? image;
  final List<PromptImageOrigin> origins = [];

  @override
  Future<SharedFile?> pick(PromptImageOrigin origin) async {
    origins.add(origin);
    return image;
  }
}

PromptImageAttacher _attacher(
  SharedFile? image,
  List<String> uploads, {
  _Source? source,
  List<Rect>? crops,
}) => PromptImageAttacher(
  source: source ?? _Source(image),
  crop: (image) async => const Rect.fromLTRB(0, 0, 0.5, 0.5),
  prepare: (image, crop) async {
    crops?.add(crop);
    return image;
  },
  upload: (image) async {
    uploads.add(image.name);
    return '/home/u/conductore-inbox/image-20260925-143005.png';
  },
);

ChatViewController _chat() => ChatViewController(
  runner: ScriptedAgentCommandRunner([
    const AgentCommandResult(stdout: '{}', stderr: '', exitCode: 0),
  ]),
  sessionId: 's-1',
  pollInterval: const Duration(days: 1),
);

const _path = '/home/u/conductore-inbox/image-20260925-143005.png';
final _field = find.byKey(const ValueKey('chat-composer-field'));

const _image = SharedFile(path: '/c/clipboard.png', name: 'clipboard.png');

void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.getData') return {'text': 'hello'};
          if (call.method == 'Clipboard.hasStrings') return {'value': true};
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets('Chat View: "Paste image" in the field menu inserts the '
      'uploaded path', (tester) async {
    final uploads = <String>[];
    final chat = ChatViewController(
      runner: ScriptedAgentCommandRunner([
        const AgentCommandResult(stdout: '{}', stderr: '', exitCode: 0),
      ]),
      sessionId: 's-1',
      pollInterval: const Duration(days: 1),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ChatViewPage(
          controller: chat,
          onOpenTerminal: () {},
          initialDraft: 'Look at',
          imageAttacher: _attacher(_image, uploads),
          clipboardHasImage: () async => true,
        ),
      ),
    );
    await tester.pump();
    final field = find.byKey(const ValueKey('chat-composer-field'));
    await tester.tap(field);
    await tester.pump();
    await tester.longPress(field);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Paste image'));
    await tester.pumpAndSettle();
    expect(uploads, ['clipboard.png']);
    expect(
      tester.widget<TextField>(field).controller!.text,
      'Look at /home/u/conductore-inbox/image-20260925-143005.png ',
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Chat View: no "Paste image" without an image', (tester) async {
    final chat = ChatViewController(
      runner: ScriptedAgentCommandRunner([
        const AgentCommandResult(stdout: '{}', stderr: '', exitCode: 0),
      ]),
      sessionId: 's-1',
      pollInterval: const Duration(days: 1),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ChatViewPage(
          controller: chat,
          onOpenTerminal: () {},
          initialDraft: 'x',
          imageAttacher: _attacher(_image, []),
          clipboardHasImage: () async => false,
        ),
      ),
    );
    await tester.pump();
    final field = find.byKey(const ValueKey('chat-composer-field'));
    await tester.tap(field);
    await tester.pump();
    await tester.longPress(field);
    await tester.pumpAndSettle();
    expect(find.text('Paste image'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  Future<TextEditingController> openSheet(
    WidgetTester tester,
    PromptImageAttacher attacher, {
    bool pasteImages = true,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showPromptComposerSheet(
              context: context,
              initialText: '',
              onDraftChanged: (_) {},
              onSend: (text, {required submit}) async {},
              submitEnter: false,
              onSubmitEnterChanged: (_) {},
              isConnected: () => true,
              imageAttacher: attacher,
              pasteImages: pasteImages,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Paste clipboard'));
    await tester.pumpAndSettle();
    return tester
        .widget<TextField>(
          find.descendant(
            of: find.byType(BottomSheet),
            matching: find.byType(TextField),
          ),
        )
        .controller!;
  }

  testWidgets('Chat mode composer: Paste puts an image in as its path', (
    tester,
  ) async {
    final uploads = <String>[];
    final text = await openSheet(tester, _attacher(_image, uploads));
    expect(uploads, ['clipboard.png']);
    expect(text.text, '/home/u/conductore-inbox/image-20260925-143005.png ');
  });

  testWidgets('Chat mode composer: Paste without an image pastes text', (
    tester,
  ) async {
    final uploads = <String>[];
    final text = await openSheet(tester, _attacher(null, uploads));
    expect(uploads, isEmpty);
    expect(text.text, 'hello');
  });

  testWidgets('Chat mode composer: the setting off keeps Paste text-only', (
    tester,
  ) async {
    final uploads = <String>[];
    final text = await openSheet(
      tester,
      _attacher(_image, uploads),
      pasteImages: false,
    );
    expect(uploads, isEmpty);
    expect(text.text, 'hello');
  });

  testWidgets('Chat View: "Paste image" appears when the image was copied '
      'after the field got focus (stale probe)', (tester) async {
    final uploads = <String>[];
    var probes = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: ChatViewPage(
          controller: _chat(),
          onOpenTerminal: () {},
          initialDraft: 'x',
          imageAttacher: _attacher(_image, uploads),
          // Nothing when the field gains focus; the image is copied after.
          clipboardHasImage: () async => probes++ > 0,
        ),
      ),
    );
    await tester.pump();
    await tester.tap(_field);
    await tester.pump();
    expect(probes, 1);
    await tester.longPress(_field);
    await tester.pumpAndSettle();
    expect(probes, 2, reason: 'the menu asks again as it opens');
    await tester.tap(find.text('Paste image'));
    await tester.pumpAndSettle();
    expect(uploads, ['clipboard.png']);
    await tester.pumpWidget(const SizedBox());
  });

  group('Chat View attach icon', () {
    Future<void> attach(WidgetTester tester, String choice) async {
      await tester.tap(find.byKey(const ValueKey('chat-attach-image')));
      await tester.pumpAndSettle();
      expect(find.text('Paste image from clipboard'), findsOneWidget);
      expect(find.text('Pick a photo'), findsOneWidget);
      await tester.tap(find.text(choice));
      await tester.pumpAndSettle();
    }

    testWidgets('"Pick a photo" crops, uploads and inserts the path', (
      tester,
    ) async {
      final uploads = <String>[];
      final crops = <Rect>[];
      final source = _Source(
        const SharedFile(path: '/c/IMG_1.jpg', name: 'IMG_1.jpg'),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: ChatViewPage(
            controller: _chat(),
            onOpenTerminal: () {},
            initialDraft: 'Look at',
            imageAttacher: _attacher(
              null,
              uploads,
              source: source,
              crops: crops,
            ),
            clipboardHasImage: () async => false,
          ),
        ),
      );
      await tester.pump();
      await attach(tester, 'Pick a photo');
      expect(source.origins, [PromptImageOrigin.gallery]);
      expect(crops, [const Rect.fromLTRB(0, 0, 0.5, 0.5)]);
      expect(uploads, ['IMG_1.jpg']);
      expect(
        tester.widget<TextField>(_field).controller!.text,
        'Look at $_path ',
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('"Paste image from clipboard" uploads the clipboard image, '
        'and says so when there is none', (tester) async {
      final uploads = <String>[];
      final source = _Source(null);
      await tester.pumpWidget(
        MaterialApp(
          home: ChatViewPage(
            controller: _chat(),
            onOpenTerminal: () {},
            imageAttacher: _attacher(null, uploads, source: source),
            clipboardHasImage: () async => false,
          ),
        ),
      );
      await tester.pump();
      await attach(tester, 'Paste image from clipboard');
      expect(source.origins, [PromptImageOrigin.clipboard]);
      expect(uploads, isEmpty);
      expect(find.text('There is no image on the clipboard.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('is absent without an attacher', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ChatViewPage(controller: _chat(), onOpenTerminal: () {}),
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('chat-attach-image')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  });

  testWidgets('Chat View: an image from the keyboard (commitContent) is '
      'uploaded and its path inserted', (tester) async {
    final uploads = <String>[];
    final inserted = <KeyboardInsertedContent>[];
    await tester.pumpWidget(
      MaterialApp(
        home: ChatViewPage(
          controller: _chat(),
          onOpenTerminal: () {},
          initialDraft: 'See',
          imageAttacher: _attacher(null, uploads),
          clipboardHasImage: () async => false,
          keyboardImage: (content) async {
            inserted.add(content);
            return const SharedFile(
              path: '/c/keyboard.gif',
              name: 'keyboard.gif',
            );
          },
        ),
      ),
    );
    await tester.pump();
    await tester.tap(_field);
    await tester.pump();

    const uri = 'content://com.samsung.android.honeyboard.provider/clip.gif';
    final message = const JSONMessageCodec().encodeMessage(<String, dynamic>{
      'args': <dynamic>[
        -1,
        'TextInputAction.commitContent',
        jsonDecode(
          '{"mimeType": "image/gif", "data": [71,73,70], "uri": "$uri"}',
        ),
      ],
      'method': 'TextInputClient.performAction',
    });
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'flutter/textinput',
      message,
      (_) {},
    );
    await tester.pumpAndSettle();

    expect(inserted.single.uri, uri);
    expect(inserted.single.mimeType, 'image/gif');
    expect(uploads, ['keyboard.gif']);
    expect(tester.widget<TextField>(_field).controller!.text, 'See $_path ');
    await tester.pumpWidget(const SizedBox());
  });

  test(
    'keyboardImageFile writes the inserted bytes under prompt-images',
    () async {
      final temp = Directory.systemTemp.createTempSync('conductore-kbd');
      addTearDown(() => temp.deleteSync(recursive: true));
      final file = await keyboardImageFile(
        KeyboardInsertedContent(
          mimeType: 'image/jpeg',
          uri: 'content://x/1',
          data: Uint8List.fromList([1, 2, 3]),
        ),
        tempDirectory: () async => temp,
      );
      expect(file!.name, 'keyboard.jpg');
      expect(file.path, startsWith('${temp.path}/prompt-images/'));
      expect(File(file.path).readAsBytesSync(), [1, 2, 3]);
      expect(
        await keyboardImageFile(
          const KeyboardInsertedContent(mimeType: 'image/png', uri: 'c://x'),
          tempDirectory: () async => temp,
        ),
        isNull,
        reason: 'no bytes, nothing to upload',
      );
    },
  );

  testWidgets('Chat View opened from home (no attacher of its own) gets '
      "the app's images and paste setting", (tester) async {
    final host = buildHost('h').copyWith(
      agentAttentionEnabled: true,
      agentMonitor: AgentMonitorKind.companion,
    );
    final workspace = TerminalWorkspaceController(
      ImmediateTerminalRepository(TrackableTerminalSession()),
    );
    const status = AgentCommandResult(
      stdout:
          '{"version":1,"seq":2,"agents":[{"sessionId":"s-1","name":"api",'
          '"cwd":"/home/a/api","state":"working","kind":"claude",'
          '"pending":[]}]}',
      stderr: '',
      exitCode: 0,
    );
    final attention = AgentAttentionController(
      workspace: workspace,
      runnerFactory: (_) => ScriptedAgentCommandRunner([status, status]),
      provider: const ConductoreHostAttentionProvider(),
      pollInterval: const Duration(days: 1),
    )..setLongPoll(false);
    addTearDown(attention.dispose);
    addTearDown(workspace.dispose);
    await tester.runAsync(workspace.open(host).connect);
    await tester.runAsync(pumpEventQueue);
    final asked = <SavedHost>[];
    final uploads = <String>[];

    await tester.pumpWidget(
      PromptImageScope(
        attacherFor: (host, context) {
          asked.add(host);
          return _attacher(_image, uploads);
        },
        pasteImages: () => false,
        child: MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => unawaited(
                openChatView(
                  context: context,
                  attention: attention,
                  host: host,
                  agent: const AgentInfo(
                    id: 's-1',
                    name: 'api',
                    state: AgentAttentionState.working,
                    kind: 'claude',
                  ),
                  onOpenTerminal: () {},
                ),
              ),
              child: const Text('go'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    for (var i = 0; i < 6; i += 1) {
      await tester.pump(const Duration(milliseconds: 200));
    }

    final page = tester.widget<ChatViewPage>(find.byType(ChatViewPage));
    expect(page.imageAttacher, isNotNull);
    expect(page.pasteImages, isFalse);
    expect(asked.single.id, 'h');
    expect(find.byKey(const ValueKey('chat-attach-image')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
