import 'package:conduit/features/review/data/review_client.dart';
import 'package:conduit/features/review/presentation/review_controller.dart';
import 'package:conduit/features/review/presentation/review_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'review_fakes.dart';

void main() {
  late FakeReviewRunner runner;
  late List<String> sent;
  late ReviewController review;

  Future<void> pumpReview(
    WidgetTester tester, {
    Size size = const Size(400, 800),
  }) async {
    tester.view.physicalSize = size * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    runner = FakeReviewRunner();
    sent = [];
    review = ReviewController(
      client: ConductoreReviewClient(runner),
      sessionId: FakeReviewRunner.sessionId,
      agentName: 'api',
      send: (text) async => sent.add(text),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => ReviewPage(controller: review),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('phone: one card per file, accept and reject move on', (
    tester,
  ) async {
    await pumpReview(tester);
    expect(find.byKey(const ValueKey('review-card-0')), findsOneWidget);
    expect(find.text('a.dart'), findsOneWidget);
    expect(find.text('1 of 3'), findsOneWidget);
    // Syntax-coloured diff rows of the card.
    expect(
      find.textContaining('final a = 2;', findRichText: true),
      findsWidgets,
    );

    await tester.tap(find.byKey(const ValueKey('review-accept')).first);
    await tester.pumpAndSettle();
    expect(review.files[0].verdict, FileVerdict.accepted);
    expect(find.text('2 of 3'), findsOneWidget);

    // Reject reverts just that file.
    final card = find.byKey(const ValueKey('review-card-1'));
    await tester.tap(
      find.descendant(
        of: card,
        matching: find.byKey(const ValueKey('review-reject')),
      ),
    );
    await tester.pumpAndSettle();
    expect(review.files[1].verdict, FileVerdict.rejected);
    expect(runner.commands.last, contains('undo sess-1 3 --file README.md'));
    expect(find.text('Reverted README.md'), findsOneWidget);
    expect(find.text('3 of 3'), findsOneWidget);
  });

  testWidgets('phone: swiping the action bar right accepts, left rejects', (
    tester,
  ) async {
    await pumpReview(tester);
    await tester.drag(
      find.byKey(const ValueKey('review-swipe-0')),
      const Offset(300, 0),
    );
    await tester.pumpAndSettle();
    expect(review.files[0].verdict, FileVerdict.accepted);
    await tester.drag(
      find.byKey(const ValueKey('review-swipe-1')),
      const Offset(-300, 0),
    );
    await tester.pumpAndSettle();
    expect(review.files[1].verdict, FileVerdict.rejected);
  });

  testWidgets('summary: tests, looks good and feedback with comments', (
    tester,
  ) async {
    await pumpReview(tester);
    // Comment on a line: tap it.
    await tester.tap(
      find.textContaining('final b = 3;', findRichText: true).first,
    );
    await tester.pumpAndSettle();
    expect(find.text('Comment on a.dart:3'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('review-text-field')),
      'b should stay 2',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('review-text-submit')));
    await tester.pumpAndSettle();
    expect(review.comments.single.line, 3);

    review.goTo(3);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('review-summary')), findsOneWidget);
    expect(
      find.text('Tests: 2 runs, 1 passed, 1 failed · last run passed'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('review-send-feedback')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('review-text-field')),
      'Please keep b.',
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('review-feedback-preview')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('review-text-submit')));
    await tester.pumpAndSettle();
    expect(
      sent.single,
      'Please keep b.\n\nReview comments:\n- lib/a.dart:3: b should stay 2',
    );
    expect(review.done, isTrue);
  });

  testWidgets('undo this turn asks first, lists the files, and offers redo', (
    tester,
  ) async {
    await pumpReview(tester);
    review.goTo(3);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('review-undo-turn')));
    await tester.pumpAndSettle();
    expect(find.text('Undo this turn?'), findsOneWidget);
    expect(find.text('restore lib/a.dart'), findsOneWidget);
    expect(runner.commands.last, contains('--dry-run'));
    // Cancel: nothing happens.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(runner.undone, isFalse);

    await tester.tap(find.byKey(const ValueKey('review-undo-turn')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('review-undo-confirm')));
    await tester.pumpAndSettle();
    expect(runner.undone, isTrue);
    expect(review.undone, isTrue);
    expect(find.text('Turn undone: 3 files restored'), findsOneWidget);
    expect(find.byKey(const ValueKey('review-undo-turn')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('review-redo')));
    await tester.pumpAndSettle();
    expect(runner.undone, isFalse);
    expect(review.undone, isFalse);
    expect(runner.commands.last, contains('redo sess-1 3'));
  });

  testWidgets('desktop: file list beside the diff, j / k and a / r keys', (
    tester,
  ) async {
    await pumpReview(tester, size: const Size(1400, 900));
    expect(find.byKey(const ValueKey('review-file-list')), findsOneWidget);
    expect(find.byKey(const ValueKey('review-cards')), findsNothing);
    expect(find.byKey(const ValueKey('review-file-tile-2')), findsOneWidget);
    // No swipe on desktop.
    expect(find.byType(Dismissible), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
    await tester.pumpAndSettle();
    expect(review.index, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.pumpAndSettle();
    expect(review.files[1].verdict, FileVerdict.accepted);
    expect(review.index, 2);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.pumpAndSettle();
    expect(review.index, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    await tester.pumpAndSettle();
    expect(review.files[0].verdict, FileVerdict.rejected);
    await tester.tap(find.byKey(const ValueKey('review-file-tile-summary')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('review-summary')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('review-page')), findsNothing);
  });

  testWidgets(
    'a companion without the turn commands: says so, offers the update',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      final old = FakeReviewRunner()
        ..overrides['turns'] = FakeReviewRunner.refused(
          'unknown command turns\nusage: …',
        );
      final controller = ReviewController(
        client: ConductoreReviewClient(old),
        sessionId: 's',
        agentName: 'api',
        send: (_) async {},
      );
      await tester.pumpWidget(
        MaterialApp(home: ReviewPage(controller: controller)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Could not load the review'), findsOneWidget);
      expect(find.text('Update agent hooks'), findsOneWidget);
    },
  );

  testWidgets(
    'without snapshots: the working tree diff, read-only, with a hint',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      final controller = ReviewController(
        client: ConductoreReviewClient(FakeReviewRunner()),
        sessionId: 's',
        agentName: 'api',
        snapshots: false,
        fallback: FakeDiffSource(),
        fallbackPath: '/home/a/api',
        send: (_) async {},
      );
      await tester.pumpWidget(
        MaterialApp(home: ReviewPage(controller: controller)),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('review-update-hint')), findsOneWidget);
      expect(find.text('x.txt'), findsOneWidget);
      final reject = tester.widget<OutlinedButton>(
        find.byKey(const ValueKey('review-reject')),
      );
      expect(reject.onPressed, isNull);
      controller.goTo(1);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('review-undo-turn')), findsNothing);
    },
  );
}
