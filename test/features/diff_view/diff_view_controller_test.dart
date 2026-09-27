import 'dart:async';

import 'package:conduit/core/app_failure.dart';
import 'package:conduit/features/diff_view/domain/git_diff_source.dart';
import 'package:conduit/features/diff_view/domain/unified_diff.dart';
import 'package:conduit/features/diff_view/presentation/diff_view_controller.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeGitDiffSource implements GitDiffSource {
  FakeGitDiffSource({this.detected = '/home/u/app'});

  String detected;
  final Map<String, Object> snapshots = {};
  final List<String> loaded = [];
  Completer<GitDiffSnapshot>? pending;
  int closeCount = 0;

  @override
  Future<String> detectWorkingDirectory() async => detected;

  @override
  Future<GitDiffSnapshot> load(String path) async {
    loaded.add(path);
    final gate = pending;
    if (gate != null) {
      return gate.future;
    }
    final snapshot = snapshots[path];
    if (snapshot is GitDiffSnapshot) {
      return snapshot;
    }
    if (snapshot is Object) {
      // ignore: only_throw_errors
      throw snapshot;
    }
    return GitDiffSnapshot(path: path, repositoryRoot: null);
  }

  @override
  Future<void> close() async => closeCount++;
}

UnifiedDiff diffOf(String path) => UnifiedDiff.parse('''
diff --git a/$path b/$path
--- a/$path
+++ b/$path
@@ -1 +1 @@
-a
+b
''');

void main() {
  late FakeGitDiffSource source;
  late DiffViewController controller;

  setUp(() {
    source = FakeGitDiffSource();
    source.snapshots['/home/u/app'] = GitDiffSnapshot(
      path: '/home/u/app',
      repositoryRoot: '/home/u/app',
      unstaged: diffOf('lib/a.dart'),
      staged: diffOf('lib/b.dart'),
      stagedTruncated: true,
    );
    controller = DiffViewController(source);
  });

  test('start detects the directory when none is given, then loads', () async {
    final phases = <DiffViewPhase>[];
    controller.addListener(() => phases.add(controller.phase));
    await controller.start();
    expect(controller.path, '/home/u/app');
    expect(source.loaded, ['/home/u/app']);
    expect(controller.phase, DiffViewPhase.ready);
    expect(phases, contains(DiffViewPhase.loading));
    expect(controller.diff?.files.single.displayPath, 'lib/a.dart');
  });

  test('start keeps an explicit initial path', () async {
    controller = DiffViewController(source, initialPath: '/other');
    await controller.start();
    expect(source.loaded, ['/other']);
    expect(controller.snapshot?.isGitRepository, isFalse);
  });

  test('the staged toggle switches the diff and the truncation flag', () async {
    await controller.start();
    expect(controller.showStaged, isFalse);
    expect(controller.diffTruncated, isFalse);
    controller.setShowStaged(true);
    expect(controller.diff?.files.single.displayPath, 'lib/b.dart');
    expect(controller.diffTruncated, isTrue);
  });

  test('collapse state is per file and per side', () async {
    await controller.start();
    final file = controller.diff!.files.single;
    expect(controller.isCollapsed(file), isFalse);
    controller.toggleCollapsed(file);
    expect(controller.isCollapsed(file), isTrue);
    expect(controller.collapseRevision, 1);
    controller.setShowStaged(true);
    expect(controller.isCollapsed(controller.diff!.files.single), isFalse);
  });

  test('absolutePathFor joins the repository root', () async {
    await controller.start();
    final file = controller.diff!.files.single;
    expect(controller.absolutePathFor(file), '/home/u/app/lib/a.dart');
  });

  test('failures are reported with the AppFailure message', () async {
    source.snapshots['/bad'] = const AppFailure('No such directory: /bad');
    await controller.load('/bad');
    expect(controller.phase, DiffViewPhase.failed);
    expect(controller.error, 'No such directory: /bad');
    expect(controller.path, '/bad');
  });

  test('a failure cause that is text is shown under the message', () async {
    source.snapshots['/x'] = const AppFailure(
      'git failed in /x.',
      'fatal: detected dubious ownership in repository at /x',
    );
    await controller.load('/x');
    expect(
      controller.error,
      'git failed in /x.\nfatal: detected dubious ownership in repository at /x',
    );
    source.snapshots['/y'] = AppFailure('Could not reach h.', StateError('x'));
    await controller.load('/y');
    expect(controller.error, 'Could not reach h.');
  });

  test('a newer load wins over a slower older one', () async {
    await controller.start();
    final gate = source.pending = Completer<GitDiffSnapshot>();
    final slow = controller.load('/slow');
    source.pending = null;
    await controller.load('/home/u/app');
    expect(controller.phase, DiffViewPhase.ready);
    // The stale request lands after the newer one and must be ignored.
    gate.complete(
      const GitDiffSnapshot(path: '/slow', repositoryRoot: '/slow'),
    );
    await slow;
    expect(controller.snapshot?.path, '/home/u/app');
    expect(controller.path, '/home/u/app');
  });

  test('dispose closes the source', () async {
    controller.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(source.closeCount, 1);
  });
}
