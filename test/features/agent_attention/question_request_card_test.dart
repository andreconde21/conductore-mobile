import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/presentation/widgets/agent_inbox_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// CON-062: questions Claude asks (AskUserQuestion) are answered from the
// phone with their options, several picks for multiSelect, and "Other".
void main() {
  const single = PendingQuestion(
    question: 'Which DB?',
    options: [
      PendingQuestionOption(label: 'Postgres'),
      PendingQuestionOption(label: 'SQLite'),
    ],
  );
  const multi = PendingQuestion(
    question: 'Which checks?',
    header: 'CI',
    multiSelect: true,
    options: [
      PendingQuestionOption(label: 'lint'),
      PendingQuestionOption(label: 'tests'),
      PendingQuestionOption(label: 'e2e'),
    ],
  );
  const count = PendingQuestion(
    question: 'How many slides?',
    kind: 'number',
    unit: 'slides',
  );

  PendingPermissionRequest request(List<PendingQuestion> questions) =>
      PendingPermissionRequest(
        id: 'q1',
        toolName: 'AskUserQuestion',
        summary: questions.isEmpty ? '{"questions":' : questions.first.question,
        questions: questions,
      );

  Future<(List<Map<String, String>>, List<PermissionVerdict>)> pump(
    WidgetTester tester,
    PendingPermissionRequest request,
  ) async {
    final answers = <Map<String, String>>[];
    final verdicts = <PermissionVerdict>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: PendingRequestCard(
              request: request,
              busy: false,
              onDecide: verdicts.add,
              onAnswer: answers.add,
            ),
          ),
        ),
      ),
    );
    return (answers, verdicts);
  }

  testWidgets('one single-select question: a tap answers it', (tester) async {
    final (answers, verdicts) = await pump(tester, request([single]));
    // No Allow / Always: they mean nothing to a question.
    expect(find.text('Allow'), findsNothing);
    expect(find.text('Always'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('question-option-SQLite')));
    await tester.pump();
    expect(answers, [
      {'Which DB?': 'SQLite'},
    ]);
    expect(verdicts, isEmpty);
  });

  testWidgets('several questions: picks, multiSelect, Other and a number, '
      'then Send', (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final (answers, _) = await pump(tester, request([single, multi, count]));
    final send = find.byKey(const ValueKey('question-send-q1'));
    expect(tester.widget<FilledButton>(send).onPressed, isNull);
    await tester.tap(find.byKey(const ValueKey('question-option-Postgres')));
    await tester.tap(find.byKey(const ValueKey('question-option-lint')));
    await tester.tap(find.byKey(const ValueKey('question-option-e2e')));
    await tester.tap(find.byKey(const ValueKey('question-option-e2e')));
    await tester.tap(find.byKey(const ValueKey('question-option-tests')));
    await tester.enterText(
      find.byKey(const ValueKey('question-other-Which checks?')),
      'smoke only',
    );
    await tester.enterText(
      find.byKey(const ValueKey('question-other-How many slides?')),
      '12',
    );
    await tester.pump();
    expect(find.text('slides'), findsOneWidget);
    await tester.tap(send);
    await tester.pump();
    expect(answers, [
      {
        'Which DB?': 'Postgres',
        'Which checks?': 'lint, tests, smoke only',
        'How many slides?': '12',
      },
    ]);
  });

  testWidgets('typing an answer of your own replaces a single pick', (
    tester,
  ) async {
    final (answers, _) = await pump(tester, request([single, count]));
    await tester.tap(find.byKey(const ValueKey('question-option-SQLite')));
    await tester.enterText(
      find.byKey(const ValueKey('question-other-Which DB?')),
      'DuckDB',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('question-send-q1')));
    await tester.pump();
    expect(answers, [
      {'Which DB?': 'DuckDB'},
    ]);
  });

  testWidgets('Decline denies it', (tester) async {
    final (_, verdicts) = await pump(tester, request([single]));
    await tester.tap(find.byKey(const ValueKey('question-decline-q1')));
    expect(verdicts, [PermissionVerdict.deny]);
  });

  testWidgets('an older companion: says why the options cannot be picked', (
    tester,
  ) async {
    await pump(tester, request(const []));
    expect(
      find.byKey(const ValueKey('question-not-answerable')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('question-send-q1')), findsNothing);
  });
}
