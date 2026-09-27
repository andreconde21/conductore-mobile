import 'dart:convert';
import 'dart:typed_data';

import 'package:conduit/core/app_failure.dart';
import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/features/sftp/presentation/file_viewer/sftp_file_viewer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';

void main() {
  final viewerKey = GlobalKey<SftpFileViewerState>();
  Uint8List? written;
  String? saveNotice;

  Widget build({
    required String path,
    required Future<Uint8List> Function() read,
    bool writable = true,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: SftpFileViewer(
          key: viewerKey,
          path: path,
          palette: AppPalette.catppuccin,
          brightness: Brightness.dark,
          fontFamily: 'monospace',
          read: (_) => read(),
          write: writable
              ? (bytes) async {
                  written = bytes;
                  return saveNotice;
                }
              : null,
        ),
      ),
    );
  }

  setUp(() {
    written = null;
    saveNotice = null;
  });

  testWidgets('shows text and saves edits back', (tester) async {
    await tester.pumpWidget(
      build(
        path: '/etc/motd',
        read: () async => Uint8List.fromList(utf8.encode('hello\nworld\n')),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(CodeEditor), findsOneWidget);
    expect(viewerKey.currentState!.isDirty, isFalse);
    final save = tester.widget<IconButton>(
      find.ancestor(
        of: find.byTooltip('Save to server'),
        matching: find.byType(IconButton),
      ),
    );
    expect(save.onPressed, isNull);

    final editor = tester.widget<CodeEditor>(find.byType(CodeEditor));
    editor.controller!.text = 'hello\nthere\n';
    await tester.pump();
    expect(viewerKey.currentState!.isDirty, isTrue);
    expect(find.text('motd •'), findsOneWidget);

    await tester.tap(find.byTooltip('Save to server'));
    await tester.pumpAndSettle();

    expect(utf8.decode(written!), 'hello\nthere\n');
    expect(viewerKey.currentState!.isDirty, isFalse);
    expect(viewerKey.currentState!.hasSaved, isTrue);
    expect(find.text('Saved motd'), findsOneWidget);
  });

  testWidgets('tells how the file was saved when that matters', (tester) async {
    saveNotice = 'It has other hard links.';
    await tester.pumpWidget(
      build(
        path: '/etc/motd',
        read: () async => Uint8List.fromList(utf8.encode('hello\n')),
      ),
    );
    await tester.pumpAndSettle();

    final editor = tester.widget<CodeEditor>(find.byType(CodeEditor));
    editor.controller!.text = 'bye\n';
    await tester.pump();
    await tester.tap(find.byTooltip('Save to server'));
    await tester.pumpAndSettle();

    expect(find.text('Saved motd. It has other hard links.'), findsOneWidget);
  });

  testWidgets('keeps CRLF line endings and is not dirty on open', (
    tester,
  ) async {
    await tester.pumpWidget(
      build(
        path: '/srv/app.ini',
        read: () async => Uint8List.fromList(utf8.encode('a=1\r\nb=2\r\n')),
      ),
    );
    await tester.pumpAndSettle();

    final editor = tester.widget<CodeEditor>(find.byType(CodeEditor));
    // A cursor move notifies listeners without changing content.
    editor.controller!.selection = const CodeLineSelection.collapsed(
      index: 1,
      offset: 1,
    );
    await tester.pump();
    expect(viewerKey.currentState!.isDirty, isFalse);

    editor.controller!.text = 'a=1\nb=3\n';
    await tester.pump();
    await tester.tap(find.byTooltip('Save to server'));
    await tester.pumpAndSettle();

    expect(utf8.decode(written!), 'a=1\r\nb=3\r\n');
  });

  testWidgets('reload asks before discarding edits', (tester) async {
    var reads = 0;
    await tester.pumpWidget(
      build(
        path: '/etc/motd',
        read: () async {
          reads++;
          return Uint8List.fromList(utf8.encode('one\n'));
        },
      ),
    );
    await tester.pumpAndSettle();
    final editor = tester.widget<CodeEditor>(find.byType(CodeEditor));
    editor.controller!.text = 'two\n';
    await tester.pump();

    await tester.tap(find.byTooltip('Reload from server'));
    await tester.pumpAndSettle();
    expect(find.text('Discard changes?'), findsOneWidget);
    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle();
    expect(reads, 1);
    expect(viewerKey.currentState!.isDirty, isTrue);

    await tester.tap(find.byTooltip('Reload from server'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    expect(reads, 2);
    expect(viewerKey.currentState!.isDirty, isFalse);
  });

  testWidgets('binary content is not opened in the editor', (tester) async {
    await tester.pumpWidget(
      build(
        path: '/usr/bin/true',
        read: () async => Uint8List.fromList([0x7f, 0x45, 0x4c, 0x46, 0, 1]),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Binary file'), findsOneWidget);
    expect(find.byType(CodeEditor), findsNothing);
    expect(find.byTooltip('Save to server'), findsNothing);
  });

  testWidgets('read failures show the message with a retry', (tester) async {
    var attempts = 0;
    await tester.pumpWidget(
      build(
        path: '/var/log/huge.log',
        read: () async {
          attempts++;
          if (attempts == 1) {
            throw const AppFailure('File is larger than 24 MB.');
          }
          return Uint8List.fromList(utf8.encode('ok'));
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Could not open file'), findsOneWidget);
    expect(find.textContaining('larger than 24 MB'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.byType(CodeEditor), findsOneWidget);
  });

  testWidgets('read-only viewer has no save button', (tester) async {
    await tester.pumpWidget(
      build(
        path: '/etc/motd',
        read: () async => Uint8List.fromList(utf8.encode('x')),
        writable: false,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(CodeEditor), findsOneWidget);
    expect(find.byTooltip('Save to server'), findsOneWidget);
    final save = tester.widget<IconButton>(
      find.ancestor(
        of: find.byTooltip('Save to server'),
        matching: find.byType(IconButton),
      ),
    );
    expect(save.onPressed, isNull);
  });
}
