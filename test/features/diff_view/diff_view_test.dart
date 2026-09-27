import 'dart:io';

import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/features/diff_view/domain/git_diff_source.dart';
import 'package:conduit/features/diff_view/domain/git_status.dart';
import 'package:conduit/features/diff_view/domain/unified_diff.dart';
import 'package:conduit/features/diff_view/presentation/diff_view.dart';
import 'package:conduit/features/diff_view/presentation/diff_view_controller.dart';
import 'package:conduit/features/diff_view/presentation/diff_view_rows.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'diff_view_controller_test.dart' show FakeGitDiffSource;

String fixture(String name) =>
    File('test/features/diff_view/fixtures/$name').readAsStringSync();

void main() {
  late FakeGitDiffSource source;
  late DiffViewController controller;
  final opened = <String>[];

  setUp(() {
    opened.clear();
    source = FakeGitDiffSource();
    source.snapshots['/home/u/app'] = GitDiffSnapshot(
      path: '/home/u/app',
      repositoryRoot: '/home/u/app',
      unstaged: UnifiedDiff.parse(fixture('sample.diff')),
      staged: UnifiedDiff.parse(
        'diff --git a/s.txt b/s.txt\n--- a/s.txt\n+++ b/s.txt\n'
        '@@ -1 +1 @@\n-old\n+new\n',
      ),
      status: GitStatus.parse(
        '# branch.head main\n# branch.ab +2 -0\n? notes.txt\n',
      ),
    );
    controller = DiffViewController(source);
  });

  tearDown(() => controller.dispose());

  Widget app() => MaterialApp(
    home: Scaffold(
      body: DiffView(
        controller: controller,
        palette: AppPalette.catppuccin,
        brightness: Brightness.dark,
        fontFamily: 'monospace',
        onOpenFile: opened.add,
      ),
    ),
  );

  Future<void> pumpReady(WidgetTester tester) async {
    await tester.pumpWidget(app());
    await controller.start();
    await tester.pump();
  }

  testWidgets('renders file headers, hunks and coloured lines', (tester) async {
    await pumpReady(tester);
    expect(find.text('/home/u/app'), findsOneWidget);
    expect(find.text('lib/app.dart'), findsOneWidget);
    expect(find.text('@@ -1,6 +1,7 @@ class App {'), findsOneWidget);
    expect(find.text('Unstaged 6'), findsOneWidget);
    expect(find.text('Staged 1'), findsOneWidget);
    expect(find.text('main ↑2'), findsOneWidget);

    final added = find.byWidgetPredicate(
      (widget) =>
          widget is Container &&
          widget.color == AppPalette.catppuccin.success.withValues(alpha: 0.14),
    );
    final removed = find.byWidgetPredicate(
      (widget) =>
          widget is Container &&
          widget.color == AppPalette.catppuccin.danger.withValues(alpha: 0.14),
    );
    expect(added, findsWidgets);
    expect(removed, findsWidgets);
  });

  testWidgets('word-level changes are highlighted inside a pair', (
    tester,
  ) async {
    await pumpReady(tester);
    final rich = tester
        .widgetList<Text>(find.byType(Text))
        .where((text) => text.textSpan != null)
        .map((text) => text.textSpan as TextSpan)
        .where((span) => span.children != null)
        .toList();
    final highlighted = rich
        .expand((span) => span.children!.cast<TextSpan>())
        .where((child) => child.style?.backgroundColor != null)
        .map((child) => child.text)
        .toList();
    expect(highlighted, containsAll(['Old', 'New']));
  });

  testWidgets('the chevron collapses a file and its lines disappear', (
    tester,
  ) async {
    await pumpReady(tester);
    expect(find.text('@@ -1,6 +1,7 @@ class App {'), findsOneWidget);
    await tester.tap(find.byTooltip('Collapse').first);
    await tester.pump();
    expect(find.text('@@ -1,6 +1,7 @@ class App {'), findsNothing);
    expect(find.byTooltip('Expand'), findsOneWidget);
  });

  testWidgets('tapping a file header opens it at its absolute path', (
    tester,
  ) async {
    await pumpReady(tester);
    await tester.tap(find.text('lib/app.dart'));
    await tester.pump();
    expect(opened, ['/home/u/app/lib/app.dart']);
  });

  testWidgets('the staged toggle swaps the diff', (tester) async {
    await pumpReady(tester);
    await tester.tap(find.text('Staged 1'));
    await tester.pump();
    expect(find.text('s.txt'), findsOneWidget);
    expect(find.text('lib/app.dart'), findsNothing);
  });

  testWidgets('the file list sheet lists changed and untracked files', (
    tester,
  ) async {
    // Tall enough that the sheet shows every entry without scrolling.
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await pumpReady(tester);
    await tester.tap(find.byTooltip('Changed files'));
    await tester.pumpAndSettle();
    expect(find.text('6 changed files'), findsOneWidget);
    expect(find.text('1 untracked'), findsOneWidget);
    await tester.tap(find.text('notes.txt'));
    await tester.pumpAndSettle();
    expect(opened, ['/home/u/app/notes.txt']);
  });

  testWidgets('refresh reloads the same directory', (tester) async {
    await pumpReady(tester);
    await tester.tap(find.byTooltip('Refresh'));
    await tester.pump();
    expect(source.loaded, ['/home/u/app', '/home/u/app']);
  });

  testWidgets('the directory can be edited from the toolbar', (tester) async {
    await pumpReady(tester);
    await tester.tap(find.text('/home/u/app'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '/tmp/elsewhere');
    await tester.tap(find.text('Load'));
    await tester.pumpAndSettle();
    expect(source.loaded.last, '/tmp/elsewhere');
    expect(find.text('Not a git repository'), findsOneWidget);
    expect(find.text('/tmp/elsewhere'), findsWidgets);
  });

  testWidgets('a failure shows the message and a retry button', (tester) async {
    source.snapshots['/home/u/app'] = Exception('boom');
    await pumpReady(tester);
    expect(find.text('Could not load the diff'), findsOneWidget);
    expect(find.textContaining('boom'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('an empty diff explains what is on the other side', (
    tester,
  ) async {
    source.snapshots['/home/u/app'] = GitDiffSnapshot(
      path: '/home/u/app',
      repositoryRoot: '/home/u/app',
      staged: UnifiedDiff.parse(
        'diff --git a/s b/s\n--- a/s\n+++ b/s\n@@ -1 +1 @@\n-a\n+b\n',
      ),
      status: GitStatus.parse('? x\n? y\n'),
    );
    await pumpReady(tester);
    expect(find.text('No unstaged changes'), findsOneWidget);
    expect(find.text('1 staged file · 2 untracked files'), findsOneWidget);
  });

  testWidgets('a truncated diff ends with a notice', (tester) async {
    source.snapshots['/home/u/app'] = GitDiffSnapshot(
      path: '/home/u/app',
      repositoryRoot: '/home/u/app',
      unstaged: UnifiedDiff.parse(
        'diff --git a/s b/s\n--- a/s\n+++ b/s\n@@ -1 +1 @@\n-a\n+b\n',
      ),
      unstagedTruncated: true,
    );
    await pumpReady(tester);
    expect(find.textContaining('Diff cut at 2 MB'), findsOneWidget);
  });

  test('DiffRows computes file offsets from fixed row heights', () {
    final diff = UnifiedDiff.parse(fixture('sample.diff'));
    final rows = DiffRows.build(diff, isCollapsed: (_) => false);
    final app = diff.files[0];
    final readme = diff.files[1];
    expect(rows.offsetOfFile(app), 0);
    final appLines = app.hunks.fold<int>(0, (n, hunk) => n + hunk.lines.length);
    expect(
      rows.offsetOfFile(readme),
      diffFileHeaderHeight +
          app.hunks.length * diffHunkHeaderHeight +
          appLines * diffLineHeight,
    );
    final collapsed = DiffRows.build(diff, isCollapsed: (file) => file == app);
    expect(collapsed.offsetOfFile(readme), diffFileHeaderHeight);
    expect(rows.maxLineLength, greaterThan(0));
  });
}
