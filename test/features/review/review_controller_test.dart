import 'package:conduit/features/review/data/review_client.dart';
import 'package:conduit/features/review/domain/turn_review.dart';
import 'package:conduit/features/review/presentation/review_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'review_fakes.dart';

void main() {
  late FakeReviewRunner runner;
  late List<String> sent;

  ReviewController make({bool snapshots = true}) {
    runner = FakeReviewRunner();
    sent = [];
    return ReviewController(
      client: ConductoreReviewClient(runner),
      sessionId: FakeReviewRunner.sessionId,
      agentName: 'api',
      snapshots: snapshots,
      fallback: snapshots ? null : FakeDiffSource(),
      fallbackPath: '/home/a/api',
      send: (text) async => sent.add(text),
      onClose: runner.close,
    );
  }

  test('loads the newest turn, its files and the tests of that turn', () async {
    final review = make();
    await review.load();
    await Future<void>.delayed(Duration.zero);
    expect(review.phase, ReviewPhase.ready);
    expect(review.turn!.turn, 3);
    expect(review.files.map((f) => f.path), [
      'lib/a.dart',
      'README.md',
      'assets/logo.png',
    ]);
    expect(review.files.last.diff.binary, isTrue);
    expect(review.facts!.testsFailed, 1);
    expect(review.canChange, isTrue);
    review.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(runner.closed, isTrue);
  });

  test(
    'accept moves on; reject reverts only that file, redo puts it back',
    () async {
      final review = make();
      await review.load();
      review.accept(0);
      expect(review.files[0].verdict, FileVerdict.accepted);
      expect(review.index, 1);
      expect(await review.reject(1), isTrue);
      expect(review.files[1].verdict, FileVerdict.rejected);
      expect(review.index, 2);
      final undo = runner.commands.lastWhere((c) => c.contains('hostd undo'));
      expect(undo, contains('--file README.md'));
      expect(undo, isNot(contains('--dry-run')));
      expect(review.redoAvailable, isTrue);
      await review.redo();
      expect(review.files[1].verdict, FileVerdict.pending);
      expect(runner.commands.last, contains('hostd redo sess-1 3'));
    },
  );

  test('undo this turn: a dry run first, then the undo, then redo', () async {
    final review = make();
    await review.load();
    final preview = await review.previewUndo();
    expect(preview!.dryRun, isTrue);
    expect(preview.restored, hasLength(3));
    expect(review.undone, isFalse);
    final outcome = await review.undoTurn();
    expect(outcome!.redoAvailable, isTrue);
    expect(review.undone, isTrue);
    expect(review.canChange, isFalse);
    expect(
      review.files.every((f) => f.verdict == FileVerdict.rejected),
      isTrue,
    );
    await review.redo();
    expect(review.undone, isFalse);
    expect(review.files.every((f) => f.verdict == FileVerdict.pending), isTrue);
  });

  test(
    'refused while the agent works: the reason is kept, nothing changes',
    () async {
      final review = make();
      await review.load();
      runner.agentState = 'working';
      expect(await review.reject(0), isFalse);
      expect(review.files[0].verdict, FileVerdict.pending);
      expect(review.message, contains('agent is working'));
      expect(await review.undoTurn(), isNull);
      expect(review.undone, isFalse);
    },
  );

  test(
    'feedback: comments and reverted files go into the next prompt',
    () async {
      final review = make();
      await review.load();
      await review.reject(0);
      review.addComment(
        const ReviewComment(path: 'README.md', line: 2, text: 'typo here'),
      );
      expect(await review.sendFeedback('Keep the old API.'), isTrue);
      expect(sent.single, contains('Keep the old API.'));
      expect(sent.single, contains('I reverted your change to lib/a.dart.'));
      expect(sent.single, contains('- README.md:2: typo here'));
      expect(review.done, isTrue);
      expect(review.comments, isEmpty);
    },
  );

  test('looks good accepts everything left', () async {
    final review = make();
    await review.load();
    review.looksGood();
    expect(review.count(FileVerdict.accepted), 3);
    expect(review.done, isTrue);
    expect(review.onSummary, isTrue);
  });

  test('an older companion: the working tree diff, read-only', () async {
    final review = make(snapshots: false);
    await review.load();
    expect(review.phase, ReviewPhase.ready);
    expect(review.needsUpdate, isTrue);
    expect(review.files.single.path, 'x.txt');
    expect(review.canChange, isFalse);
    expect(await review.reject(0), isFalse);
    expect(runner.commands, isEmpty);
  });

  test('no snapshot yet: empty with the reason', () async {
    final review = make();
    runner.overrides['turns'] = FakeReviewRunner.ok({
      'sessionId': 's',
      'turns': [
        {
          'turn': 1,
          'before': {'skipped': 'repo too large'},
        },
      ],
    });
    await review.load();
    expect(review.phase, ReviewPhase.empty);
    expect(review.message, contains('repo too large'));
  });
}
