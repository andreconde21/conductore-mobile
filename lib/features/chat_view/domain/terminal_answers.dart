import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/chat_view/domain/chat_items.dart';

/// The companion capability that types answers into Claude Code's own
/// dialog in the agent's pane (`terminal-answer`, CON-096).
const terminalAnswersCapability = 'terminal-answers';

/// The transcript's question as a request card can show it: answered by
/// typing into the terminal's form ([PendingPermissionRequest.terminalOnly]).
PendingPermissionRequest questionRequestOf(ChatQuestion item) =>
    PendingPermissionRequest(
      id: item.id,
      toolName: PendingPermissionRequest.questionTool,
      summary: item.questions.firstOrNull?.question ?? 'Question',
      questions: [
        for (final q in item.questions)
          PendingQuestion(
            question: q.question,
            header: q.header,
            multiSelect: q.multiSelect,
            options: [
              for (final o in q.options)
                PendingQuestionOption(
                  label: o.label,
                  description: o.description,
                ),
            ],
          ),
      ],
      terminalOnly: true,
    );

/// The questions as `terminal-answer` takes them (the AskUserQuestion
/// input's shape).
List<Map<String, Object?>> terminalQuestions(List<PendingQuestion> questions) =>
    [
      for (final q in questions)
        {
          'question': q.question,
          if (q.header != null) 'header': q.header,
          'multiSelect': q.multiSelect,
          'options': [
            for (final o in q.options) {'label': o.label},
          ],
        },
    ];

/// The card's answers (question -> text, a multiSelect question's picks and
/// own text joined with ", ") as `terminal-answer` takes them: question ->
/// the picked labels in order, then the own text. The card joins picks
/// first and its own text last, so labels are matched from the front
/// (longest first, a label may hold ", ") and the rest is the own text.
Map<String, List<String>> terminalAnswerParts(
  List<PendingQuestion> questions,
  Map<String, String> answers,
) {
  final out = <String, List<String>>{};
  for (final q in questions) {
    final answer = answers[q.question];
    if (answer == null || answer.trim().isEmpty) continue;
    if (!q.multiSelect) {
      out[q.question] = [answer.trim()];
      continue;
    }
    final labels = [for (final o in q.options) o.label]
      ..sort((a, b) => b.length.compareTo(a.length));
    final parts = <String>[];
    var rest = answer.trim();
    while (rest.isNotEmpty) {
      final label = labels
          .where((l) => rest == l || rest.startsWith('$l, '))
          .firstOrNull;
      if (label == null) break;
      parts.add(label);
      rest = rest == label ? '' : rest.substring(label.length + 2);
    }
    if (rest.isNotEmpty) parts.add(rest);
    out[q.question] = parts;
  }
  return out;
}

/// The answers in an AskUserQuestion's tool result (`… "question"="answer",
/// "question"="answer". …`), by question; empty when it reads otherwise
/// (declined, an error).
Map<String, String> answeredInResult(
  List<ChatQuestionPrompt> questions,
  String result,
) {
  final out = <String, String>{};
  for (final q in questions) {
    final start = result.indexOf('"${q.question}"="');
    if (start == -1) continue;
    final from = start + q.question.length + 4;
    // The answer runs to the quote before the next pair or the sentence end.
    final end = RegExp(
      r'"(?:, "|\.\s|\.$|$)',
    ).firstMatch(result.substring(from));
    if (end == null) continue;
    out[q.question] = result.substring(from, from + end.start);
  }
  return out;
}
