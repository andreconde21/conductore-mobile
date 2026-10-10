import 'dart:io';

import 'package:conduit/core/presentation/multiplexer_icon.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/sessions/data/workspace_creator.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:conduit/features/sessions/domain/new_workspace.dart';
import 'package:conduit/features/sessions/presentation/folder_picker_sheet.dart';
import 'package:conduit/features/sessions/presentation/new_workspace_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

const _roots = [
  '/home/a/Projects/app',
  '/home/a/Projects/website',
  '/home/a/Documents',
];

Future<List<String>> _fakeListing(String? folder) async => switch (folder) {
  null => _roots,
  '/home/a/Projects/app' => [
    '/home/a/Projects/app/lib',
    '/home/a/Projects/app/docs',
  ],
  _ => throw const NewWorkspaceFailure('nope'),
};

/// Opens the dialog; [request] is what Create asked for.
Future<List<NewWorkspaceRequest>> _pump(
  WidgetTester tester, {
  List<String> folders = const [],
  FolderLister? listFolders = _fakeListing,
}) async {
  final requests = <NewWorkspaceRequest>[];
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showNewWorkspaceDialog(
              context,
              kind: MultiplexerKind.herdr,
              folders: folders,
              listFolders: listFolders,
              create: (request) async {
                requests.add(request);
                return const ConnectTarget.tmux('x');
              },
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('new-workspace-browse')));
  await tester.pumpAndSettle();
  return requests;
}

Finder _row(String folder) => find.byKey(ValueKey('folder-picker-row-$folder'));

void main() {
  testWidgets('recents come first, then the listed folders', (tester) async {
    await _pump(tester, folders: ['/srv/old', '/home/a/Projects/app']);
    final order = [
      '/srv/old',
      '/home/a/Projects/app',
      '/home/a/Projects/website',
      '/home/a/Documents',
    ];
    final tops = [
      for (final folder in order) tester.getTopLeft(_row(folder)).dy,
    ];
    expect(tops, [...tops]..sort());
    // The recent folder is not repeated from the listing.
    expect(_row('/home/a/Projects/app'), findsOneWidget);
  });

  testWidgets('a machine with no recents lists the project folders', (
    tester,
  ) async {
    await _pump(tester);
    expect(_row('/home/a/Projects/website'), findsOneWidget);
    expect(find.byKey(const ValueKey('folder-picker-empty')), findsNothing);
  });

  testWidgets('picking a folder fills the folder and the name', (tester) async {
    final requests = await _pump(tester);
    await tester.tap(_row('/home/a/Projects/website'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('new-workspace-create')));
    await tester.pumpAndSettle();
    expect(requests.single.folder, '/home/a/Projects/website');
    expect(requests.single.name, 'website');
  });

  testWidgets('typing filters the list; an unknown path can be used', (
    tester,
  ) async {
    final requests = await _pump(tester);
    await tester.enterText(
      find.byKey(const ValueKey('folder-picker-search')),
      'WEB',
    );
    await tester.pump();
    expect(_row('/home/a/Projects/website'), findsOneWidget);
    expect(_row('/home/a/Documents'), findsNothing);

    await tester.enterText(
      find.byKey(const ValueKey('folder-picker-search')),
      '~/Projects/brand-new',
    );
    await tester.pump();
    expect(_row('/home/a/Projects/website'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('folder-picker-use-typed')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('new-workspace-create')));
    await tester.pumpAndSettle();
    expect(requests.single.folder, '~/Projects/brand-new');
    expect(requests.single.name, 'brand-new');
  });

  testWidgets('the folder typed in the dialog is where the search starts', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NewWorkspaceDialog(
            kind: MultiplexerKind.tmux,
            create: (_) async => const ConnectTarget.tmux('x'),
            listFolders: _fakeListing,
          ),
        ),
      ),
    );
    await tester.enterText(
      find.byKey(const ValueKey('new-workspace-folder')),
      'doc',
    );
    await tester.tap(find.byKey(const ValueKey('new-workspace-browse')));
    await tester.pumpAndSettle();
    expect(_row('/home/a/Documents'), findsOneWidget);
    expect(_row('/home/a/Projects/app'), findsNothing);
  });

  testWidgets('stepping into a folder lists its subfolders and goes back', (
    tester,
  ) async {
    final requests = await _pump(tester);
    await tester.tap(
      find.byKey(const ValueKey('folder-picker-open-/home/a/Projects/app')),
    );
    await tester.pumpAndSettle();
    expect(_row('/home/a/Projects/app/lib'), findsOneWidget);
    expect(_row('/home/a/Documents'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('folder-picker-up')));
    await tester.pumpAndSettle();
    expect(_row('/home/a/Documents'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('folder-picker-open-/home/a/Projects/app')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('folder-picker-use-current')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('new-workspace-create')));
    await tester.pumpAndSettle();
    expect(requests.single.folder, '/home/a/Projects/app');
  });

  testWidgets('a listing that fails still offers recents and free text', (
    tester,
  ) async {
    final requests = await _pump(
      tester,
      folders: ['/srv/old'],
      listFolders: (_) async => throw const NewWorkspaceFailure('timed out'),
    );
    expect(find.byKey(const ValueKey('folder-picker-failed')), findsOneWidget);
    expect(_row('/srv/old'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('folder-picker-search')),
      '/opt/thing',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('folder-picker-use-typed')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('new-workspace-create')));
    await tester.pumpAndSettle();
    expect(requests.single.folder, '/opt/thing');
  });

  testWidgets('without a lister only the recents are offered', (tester) async {
    await _pump(tester, folders: ['/srv/old'], listFolders: null);
    expect(_row('/srv/old'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('folder-picker-open-/srv/old')),
      findsNothing,
    );
  });

  group('the listing command', () {
    late Directory home;
    setUp(() {
      home = Directory.systemTemp.createTempSync('con117');
      for (final path in [
        'Projects/app/.git',
        'Projects/org/repo/.git',
        'Projects/org/plain/src',
        'Documents',
        '.cache/hidden',
      ]) {
        Directory('${home.path}/$path').createSync(recursive: true);
      }
    });
    tearDown(() => home.deleteSync(recursive: true));

    Future<ProcessResult> run(String command) =>
        Process.run('sh', ['-c', command], environment: {'HOME': home.path});

    test('roots: subfolders of ~/Projects and ~, then repos below', () async {
      final result = await run(NewWorkspaceCommands.listFolders());
      expect(result.exitCode, 0);
      final folders = NewWorkspaceCommands.parseFolders(
        result.stdout as String,
      );
      final p = home.path;
      expect(folders, [
        '$p/Projects/app',
        '$p/Projects/org',
        '$p/Documents',
        '$p/Projects',
        '$p/Projects/org/repo',
      ]);
    });

    test('a folder lists its subfolders; a missing one exits 3', () async {
      final result = await run(
        NewWorkspaceCommands.listFolders('${home.path}/Projects/org'),
      );
      expect(NewWorkspaceCommands.parseFolders(result.stdout as String), [
        '${home.path}/Projects/org/plain',
        '${home.path}/Projects/org/repo',
      ]);
      final missing = await run(
        NewWorkspaceCommands.listFolders('${home.path}/nope'),
      );
      expect(missing.exitCode, NewWorkspaceCommands.missingFolderExit);
      final tilde = await run(NewWorkspaceCommands.listFolders('~/Documents'));
      expect(tilde.exitCode, 0);
    });
  });

  test(
    'WorkspaceCreator.listFolders runs one command with a timeout',
    () async {
      final runner = ScriptedAgentCommandRunner([
        const AgentCommandResult(
          stdout: '/a\n/b\n/a\n',
          stderr: '',
          exitCode: 0,
        ),
        const AgentCommandResult(stdout: '', stderr: 'x', exitCode: 3),
        const AgentCommandResult(stdout: '', stderr: 'boom', exitCode: 1),
      ]);
      final creator = WorkspaceCreator(runner);
      expect(await creator.listFolders(), ['/a', '/b']);
      expect(runner.commands, hasLength(1));
      await expectLater(
        creator.listFolders('/gone'),
        throwsA(isA<NewWorkspaceFailure>()),
      );
      await expectLater(
        creator.listFolders(),
        throwsA(isA<NewWorkspaceFailure>()),
      );
    },
  );
}
