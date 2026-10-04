import 'package:conduit/core/theme/app_theme.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/domain/agent_kinds.dart';
import 'package:flutter/material.dart';

/// A question Claude asked (AskUserQuestion) and is waiting on, answered
/// from the phone through the companion (`decide <id> answer`).
///
/// Each question shows its options (a check per option for multiSelect)
/// and a field for an answer of the user's own ("Other"); text and number
/// questions show the field only. One single-select question is answered
/// by tapping an option; anything else by Send. Decline answers the
/// request with a deny (Claude carries on without the answer).
///
/// When the companion did not send the questions (an older one), the
/// options cannot be answered here and the card says so.
class QuestionRequestCard extends StatefulWidget {
  const QuestionRequestCard({
    required this.request,
    required this.busy,
    required this.onAnswer,
    required this.onDecline,
    this.margin = EdgeInsets.zero,
    this.agentName,
    super.key,
  });

  final PendingPermissionRequest request;

  /// The asking agent's name for people ("Claude Code", "Codex"); null
  /// when its kind is not known.
  final String? agentName;
  final bool busy;

  /// Question -> answer (several picks joined with ", ").
  final ValueChanged<Map<String, String>> onAnswer;
  final VoidCallback onDecline;
  final EdgeInsetsGeometry margin;

  @override
  State<QuestionRequestCard> createState() => _QuestionRequestCardState();
}

class _QuestionRequestCardState extends State<QuestionRequestCard> {
  final _picked = <String, Set<String>>{};
  final _other = <String, TextEditingController>{};

  @override
  void dispose() {
    for (final controller in _other.values) {
      controller.dispose();
    }
    super.dispose();
  }

  TextEditingController _otherOf(PendingQuestion question) =>
      _other.putIfAbsent(question.question, TextEditingController.new);

  bool get _oneTap {
    final questions = widget.request.questions;
    return questions.length == 1 &&
        !questions.single.multiSelect &&
        questions.single.options.isNotEmpty;
  }

  /// What would be sent now: every question with a pick or its own text.
  Map<String, String> get _answers => {
    for (final question in widget.request.questions)
      if (_answerOf(question) case final answer? when answer.isNotEmpty)
        question.question: answer,
  };

  String? _answerOf(PendingQuestion question) {
    final own = _other[question.question]?.text.trim() ?? '';
    final picked = [
      for (final option in question.options)
        if (_picked[question.question]?.contains(option.label) ?? false)
          option.label,
    ];
    if (!question.multiSelect) {
      return own.isNotEmpty ? own : picked.firstOrNull;
    }
    return [...picked, if (own.isNotEmpty) own].join(', ');
  }

  void _toggle(PendingQuestion question, String label) {
    if (_oneTap) {
      widget.onAnswer({question.question: label});
      return;
    }
    setState(() {
      final picked = _picked.putIfAbsent(question.question, () => {});
      if (question.multiSelect) {
        if (!picked.remove(label)) picked.add(label);
      } else {
        final had = picked.contains(label);
        picked.clear();
        if (!had) picked.add(label);
        // A pick replaces what was typed for a single answer.
        _other[question.question]?.clear();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final request = widget.request;
    final busy = widget.busy;
    final answers = _answers;
    return Container(
      key: ValueKey('question-request-${request.id}'),
      margin: widget.margin,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(AppTheme.radius),
        border: Border.all(color: scheme.primary),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.help_outline_rounded, size: 18, color: scheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  request.questions.length > 1
                      ? '${agentSubject(widget.agentName)} asks '
                            '${request.questions.length} questions'
                      : '${agentSubject(widget.agentName)} asks',
                  style: theme.textTheme.titleSmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          if (!request.answerable) ...[
            Text(request.summary, style: theme.textTheme.bodyMedium),
            const SizedBox(height: 6),
            Text(
              'This machine\'s Conductore companion is too old to answer '
              'questions from the phone. Update it, or answer in the '
              'terminal.',
              key: const ValueKey('question-not-answerable'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ] else
            for (final question in request.questions)
              _QuestionBlock(
                question: question,
                picked: _picked[question.question] ?? const {},
                other: _otherOf(question),
                enabled: !busy,
                onToggle: (label) => _toggle(question, label),
                onOtherChanged: () => setState(() {
                  if (!question.multiSelect &&
                      _otherOf(question).text.trim().isNotEmpty) {
                    _picked[question.question]?.clear();
                  }
                }),
              ),
          const SizedBox(height: 4),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            children: [
              TextButton(
                key: ValueKey('question-decline-${request.id}'),
                onPressed: busy ? null : widget.onDecline,
                child: const Text('Decline'),
              ),
              if (request.answerable)
                FilledButton(
                  key: ValueKey('question-send-${request.id}'),
                  onPressed: busy || answers.isEmpty
                      ? null
                      : () => widget.onAnswer(answers),
                  child: Text(
                    request.questions.length > 1 ? 'Send answers' : 'Send',
                  ),
                ),
            ],
          ),
          if (busy)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: LinearProgressIndicator(),
            ),
        ],
      ),
    );
  }
}

class _QuestionBlock extends StatelessWidget {
  const _QuestionBlock({
    required this.question,
    required this.picked,
    required this.other,
    required this.enabled,
    required this.onToggle,
    required this.onOtherChanged,
  });

  final PendingQuestion question;
  final Set<String> picked;
  final TextEditingController other;
  final bool enabled;
  final ValueChanged<String> onToggle;
  final VoidCallback onOtherChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final choice = question.options.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (question.header case final header?)
            Text(header, style: theme.textTheme.labelMedium),
          Text(question.question, style: theme.textTheme.bodyMedium),
          if (question.description case final description?)
            Text(description, style: theme.textTheme.bodySmall),
          if (question.multiSelect)
            Text('Pick any', style: theme.textTheme.bodySmall),
          const SizedBox(height: 6),
          for (final option in question.options)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: _OptionButton(
                key: ValueKey('question-option-${option.label}'),
                option: option,
                selected: picked.contains(option.label),
                multiSelect: question.multiSelect,
                onPressed: enabled ? () => onToggle(option.label) : null,
              ),
            ),
          TextField(
            key: ValueKey('question-other-${question.question}'),
            controller: other,
            enabled: enabled,
            minLines: 1,
            maxLines: 4,
            keyboardType: question.kind == 'number'
                ? const TextInputType.numberWithOptions(
                    decimal: true,
                    signed: true,
                  )
                : TextInputType.text,
            decoration: InputDecoration(
              isDense: true,
              hintText: choice
                  ? 'Other: type your own answer'
                  : question.placeholder ?? 'Your answer',
              suffixText: question.unit,
            ),
            onChanged: (_) => onOtherChanged(),
          ),
        ],
      ),
    );
  }
}

class _OptionButton extends StatelessWidget {
  const _OptionButton({
    required this.option,
    required this.selected,
    required this.multiSelect,
    required this.onPressed,
    super.key,
  });

  final PendingQuestionOption option;
  final bool selected;
  final bool multiSelect;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final icon = multiSelect
        ? (selected
              ? Icons.check_box_rounded
              : Icons.check_box_outline_blank_rounded)
        : (selected
              ? Icons.radio_button_checked_rounded
              : Icons.radio_button_unchecked_rounded);
    return OutlinedButton(
      style: OutlinedButton.styleFrom(
        alignment: Alignment.centerLeft,
        backgroundColor: selected ? scheme.primaryContainer : null,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      ),
      onPressed: onPressed,
      child: Row(
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(option.label),
                if (option.description case final description?)
                  Text(description, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
