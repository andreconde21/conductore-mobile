import 'package:conduit/features/diff_view/domain/unified_diff.dart';
import 'package:conduit/features/review/data/review_client.dart';
import 'package:conduit/features/review/domain/turn_review.dart';
import 'package:flutter_test/flutter_test.dart';

import 'review_fakes.dart';

void main() {
  group('parsing the companion contract', () {
    test('turns: newest reviewable turn, agent state, undo state', () {
      final runner = FakeReviewRunner();
      final list = TurnList.parse(
        FakeReviewRunner.ok({
          'sessionId': 's',
          'agent': {'state': 'working'},
          'pending': 1,
          'turns': [
            {
              'turn': 4,
              'prompt': 'second',
              'running': true,
              'before': {'skipped': 'repo too large'},
            },
            runner.turnJson(),
          ],
        }).stdout,
      )!;
      expect(list.agentBusy, isTrue);
      expect(list.pending, 1);
      expect(list.turns.first.canReview, isFalse);
      expect(list.turns.first.before!.skipped, 'repo too large');
      final latest = list.latest!;
      expect(latest.turn, 3);
      expect(latest.prompt, 'Fix the date parser');
      expect(latest.fileCount, 3);
      expect(latest.files.first.status, TurnFileStatus.modified);
      expect(latest.undone, isFalse);
      expect(TurnList.parse('{"error":"x"}'), isNull);
    });

    test('diff files become diff-view files with numbered lines', () {
      final runner = FakeReviewRunner();
      final diff = TurnDiff.parse(
        FakeReviewRunner.ok({
          'turn': 3,
          'files': [
            runner.fileJson('lib/a.dart'),
            runner.fileJson('logo.png'),
            {
              'path': 'new.txt',
              'status': 'A',
              'added': 1,
              'patch': '@@ -0,0 +1 @@\n+hello\n',
            },
          ],
        }).stdout,
      )!;
      expect(diff.added, 3);
      final code = diff.files[0].toDiffFile();
      expect(code.displayPath, 'lib/a.dart');
      expect(code.hunks.single.lines.map((l) => l.kind), [
        DiffLineKind.context,
        DiffLineKind.deletion,
        DiffLineKind.addition,
        DiffLineKind.addition,
        DiffLineKind.context,
      ]);
      expect(code.hunks.single.lines[2].newLineNumber, 2);
      final binary = diff.files[1].toDiffFile();
      expect(binary.binary, isTrue);
      expect(diff.files[1].newSize, 4096);
      final added = diff.files[2].toDiffFile();
      expect(added.status, DiffFileStatus.added);
      expect(added.displayPath, 'new.txt');
    });

    test('undo outcome: restored, deleted, redo, staged', () {
      final outcome = UndoOutcome.parse(
        FakeReviewRunner.ok({
          'ok': true,
          'restored': [
            {'path': 'a', 'action': 'write'},
            {'path': 'b', 'action': 'delete'},
          ],
          'skipped': [
            {'path': 'sub', 'reason': 'submodule'},
          ],
          'redo': {'ref': 'r'},
          'staged': ['a'],
          'laterTurns': [4, 5],
        }).stdout,
      )!;
      expect(outcome.restored.map((r) => (r.path, r.deleted)), [
        ('a', false),
        ('b', true),
      ]);
      expect(outcome.skipped.single.reason, 'submodule');
      expect(outcome.redoAvailable, isTrue);
      expect(outcome.staged, ['a']);
      expect(outcome.laterTurns, [4, 5]);
    });
  });

  test('the feedback prompt names reverted files and commented lines', () {
    expect(
      reviewFeedbackPrompt(
        text: 'Use the existing parser instead.',
        rejected: ['lib/a.dart'],
        comments: const [
          ReviewComment(path: 'lib/b.dart', line: 12, text: 'off by one'),
          ReviewComment(path: 'README.md', text: 'too long'),
        ],
      ),
      'Use the existing parser instead.\n\n'
      'I reverted your change to lib/a.dart.\n\n'
      'Review comments:\n'
      '- lib/b.dart:12: off by one\n'
      '- README.md: too long',
    );
    expect(reviewFeedbackPrompt(text: '  '), '');
    expect(
      reviewFeedbackPrompt(text: '', rejected: ['a', 'b']),
      'I reverted your changes to: a, b.',
    );
  });

  group('ConductoreReviewClient', () {
    test('commands quote the session and pass files and flags', () {
      expect(
        ConductoreReviewClient.undoCommand(
          'sess-1',
          3,
          files: ['lib/a b.dart'],
          dryRun: true,
        ),
        contains("undo sess-1 3 --file '\\''lib/a b.dart'\\'' --dry-run"),
      );
      expect(
        ConductoreReviewClient.diffCommand('sess-1', 2),
        contains('conductore-hostd diff sess-1 2'),
      );
    });

    test('a refusal keeps its code; an old companion is unsupported', () async {
      final runner = FakeReviewRunner(agentState: 'working');
      final client = ConductoreReviewClient(runner);
      await expectLater(
        client.undo(FakeReviewRunner.sessionId, 3),
        throwsA(
          isA<ReviewRefused>()
              .having((e) => e.busy, 'busy', isTrue)
              .having((e) => e.message, 'message', contains('working')),
        ),
      );
      runner.overrides['turns'] = FakeReviewRunner.refused(
        'unknown command turns\nusage: …',
      );
      await expectLater(client.turns('s'), throwsA(isA<ReviewUnsupported>()));
    });

    test('facts of the turn come from digest --since its start', () async {
      final runner = FakeReviewRunner();
      final facts = await ConductoreReviewClient(
        runner,
      ).facts(FakeReviewRunner.sessionId, DateTime.utc(2026, 9, 27, 12));
      expect(facts!.testRuns, 2);
      expect(facts.lastTestPassed, isTrue);
      expect(
        runner.commands.single,
        contains(
          'digest --since '
          '${DateTime.utc(2026, 9, 27, 12).millisecondsSinceEpoch}',
        ),
      );
    });
  });
}
