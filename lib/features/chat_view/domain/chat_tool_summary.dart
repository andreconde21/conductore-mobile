import 'package:conduit/features/chat_view/domain/chat_items.dart';

/// One line of an Edit/Write preview.
class ChatDiffLine {
  const ChatDiffLine(this.sign, this.text);

  /// `+`, `-`, or ` ` for an elision marker.
  final String sign;
  final String text;
}

/// How a tool call reads in one compact card.
class ChatToolSummary {
  const ChatToolSummary({
    required this.title,
    required this.subject,
    this.detail,
    this.diff = const [],
    this.resultPreview,
    this.exitCode,
  });

  /// Short tool label, e.g. `Bash`, `Edit`, `github: create_issue`.
  final String title;

  /// One line: the command, file path, pattern, URL or description.
  final String subject;

  /// Secondary line (Bash description, Grep scope, subagent type).
  final String? detail;
  final List<ChatDiffLine> diff;

  /// A few lines of the result for the collapsed card (Bash output tail,
  /// match counts), or null.
  final String? resultPreview;

  /// Bash exit code when the result states one.
  final int? exitCode;

  static const _diffLines = 12;
  static const _previewLines = 6;

  static ChatToolSummary of(ChatToolCall call) {
    final input = call.input;
    String? str(String key) {
      final value = input[key];
      return value is String && value.trim().isNotEmpty ? value : null;
    }

    final result = call.result;
    switch (call.name) {
      case 'Bash':
        final exit = _exitCode(result);
        return ChatToolSummary(
          title: 'Bash',
          subject: _firstLine(str('command') ?? ''),
          detail: str('description'),
          exitCode: exit,
          resultPreview: result == null ? null : _tail(result.content),
        );
      case 'Edit':
        return ChatToolSummary(
          title: 'Edit',
          subject: str('file_path') ?? '',
          detail: input['replace_all'] == true ? 'replace all' : null,
          diff: _diff(str('old_string') ?? '', str('new_string') ?? ''),
          resultPreview: _errorPreview(result),
        );
      case 'MultiEdit':
        final edits = input['edits'];
        final first = edits is List && edits.isNotEmpty && edits.first is Map
            ? edits.first as Map
            : const <Object?, Object?>{};
        return ChatToolSummary(
          title: 'MultiEdit',
          subject: str('file_path') ?? '',
          detail: edits is List ? '${edits.length} edits' : null,
          diff: _diff(
            first['old_string'] is String ? first['old_string'] as String : '',
            first['new_string'] is String ? first['new_string'] as String : '',
          ),
          resultPreview: _errorPreview(result),
        );
      case 'NotebookEdit':
        return ChatToolSummary(
          title: 'NotebookEdit',
          subject: str('notebook_path') ?? '',
          diff: _diff('', str('new_source') ?? ''),
          resultPreview: _errorPreview(result),
        );
      case 'Write':
        final content = str('content') ?? '';
        final lines = content.split('\n').length;
        return ChatToolSummary(
          title: 'Write',
          subject: str('file_path') ?? '',
          detail: '$lines line${lines == 1 ? '' : 's'}',
          diff: _diff('', content),
          resultPreview: _errorPreview(result),
        );
      case 'Read':
        final range = [
          if (input['offset'] != null) 'from line ${input['offset']}',
          if (input['limit'] != null) '${input['limit']} lines',
        ].join(', ');
        return ChatToolSummary(
          title: 'Read',
          subject: str('file_path') ?? str('notebook_path') ?? '',
          detail: range.isEmpty ? null : range,
          resultPreview: _errorPreview(result),
        );
      case 'Grep':
        return ChatToolSummary(
          title: 'Grep',
          subject: str('pattern') ?? '',
          detail: [
            if (str('path') case final path?) 'in $path',
            ?str('glob'),
            ?str('type'),
          ].join(' · ').ifEmptyNull,
          resultPreview: _countPreview(result),
        );
      case 'Glob':
        return ChatToolSummary(
          title: 'Glob',
          subject: str('pattern') ?? '',
          detail: str('path') == null ? null : 'in ${str('path')}',
          resultPreview: _countPreview(result),
        );
      case 'WebFetch':
        return ChatToolSummary(
          title: 'Fetch',
          subject: str('url') ?? '',
          resultPreview: _errorPreview(result),
        );
      case 'WebSearch':
        return ChatToolSummary(
          title: 'Search the web',
          subject: str('query') ?? '',
          resultPreview: _errorPreview(result),
        );
      case 'Task':
      case 'Agent':
        return ChatToolSummary(
          title: str('subagent_type') ?? 'Agent',
          subject: str('description') ?? _firstLine(str('prompt') ?? ''),
          detail: str('name'),
          resultPreview: result == null
              ? null
              : _head(result.content, _previewLines),
        );
    }
    // Other agents' tools (neutral items) by their kind: a command, or a
    // patch (Codex's apply_patch).
    if (call.kind == ChatToolKind.bash && str('command') != null) {
      return ChatToolSummary(
        title: 'Shell',
        subject: _firstLine(str('command')!),
        detail: str('description'),
        exitCode: _exitCode(result),
        resultPreview: result == null ? null : _tail(result.content),
      );
    }
    if (call.kind == ChatToolKind.edit && str('patch') != null) {
      final files = input['files'];
      return ChatToolSummary(
        title: 'Edit',
        subject: files is List ? files.whereType<String>().join(', ') : '',
        diff: _patchDiff(str('patch')!),
        resultPreview: _errorPreview(result),
      );
    }
    final title = call.name.startsWith('mcp__')
        ? call.name.substring(5).replaceFirst('__', ': ')
        : call.name;
    final subject = input.values
        .whereType<String>()
        .where((value) => value.trim().isNotEmpty)
        .map(_firstLine)
        .firstOrNull;
    return ChatToolSummary(
      title: title,
      subject: subject ?? '',
      resultPreview: _errorPreview(result),
    );
  }

  static String _firstLine(String text) {
    final trimmed = text.trim();
    final newline = trimmed.indexOf('\n');
    return newline == -1 ? trimmed : '${trimmed.substring(0, newline)} …';
  }

  static String? _tail(String text) {
    final lines = text.trimRight().split('\n');
    if (lines.length == 1 && lines.first.trim().isEmpty) {
      return null;
    }
    if (lines.length <= _previewLines) {
      return lines.join('\n');
    }
    return '…\n${lines.sublist(lines.length - _previewLines).join('\n')}';
  }

  static String? _head(String text, int count) {
    final lines = text.trim().split('\n');
    if (lines.length == 1 && lines.first.isEmpty) {
      return null;
    }
    return lines.length <= count
        ? lines.join('\n')
        : '${lines.take(count).join('\n')}\n…';
  }

  static String? _errorPreview(ChatToolResult? result) =>
      result != null && result.isError ? _head(result.content, 4) : null;

  static String? _countPreview(ChatToolResult? result) {
    if (result == null) {
      return null;
    }
    if (result.isError) {
      return _head(result.content, 4);
    }
    final lines = result.content
        .trim()
        .split('\n')
        .where((line) => line.trim().isNotEmpty)
        .toList();
    if (lines.isEmpty) {
      return 'No matches';
    }
    if (lines.first.startsWith('Found ') || lines.first.startsWith('No ')) {
      return lines.first;
    }
    return '${lines.length} result${lines.length == 1 ? '' : 's'}';
  }

  static int? _exitCode(ChatToolResult? result) {
    if (result == null) {
      return null;
    }
    final match = RegExp(r'^Exit code (\d+)').firstMatch(result.content);
    if (match != null) {
      return int.tryParse(match.group(1)!);
    }
    return result.isError ? null : 0;
  }

  /// The changed lines of a patch (`*** Begin Patch` format or a unified
  /// diff), headers left out.
  static List<ChatDiffLine> _patchDiff(String patch) {
    final changed = [
      for (final line in patch.split('\n'))
        if ((line.startsWith('+') || line.startsWith('-')) &&
            !line.startsWith('+++') &&
            !line.startsWith('---'))
          ChatDiffLine(line[0], line.substring(1)),
    ];
    if (changed.length <= _diffLines) {
      return changed;
    }
    return [
      ...changed.take(_diffLines),
      ChatDiffLine(' ', '… ${changed.length - _diffLines} more'),
    ];
  }

  static List<ChatDiffLine> _diff(String before, String after) {
    final removed = before.isEmpty ? <String>[] : before.split('\n');
    final added = after.isEmpty ? <String>[] : after.split('\n');
    final lines = <ChatDiffLine>[];
    final removedShown = removed.length <= _diffLines ~/ 2
        ? removed.length
        : _diffLines ~/ 2;
    for (final line in removed.take(removedShown)) {
      lines.add(ChatDiffLine('-', line));
    }
    if (removed.length > removedShown) {
      lines.add(ChatDiffLine(' ', '… ${removed.length - removedShown} more'));
    }
    final addedShown = (_diffLines - removedShown).clamp(0, added.length);
    for (final line in added.take(addedShown)) {
      lines.add(ChatDiffLine('+', line));
    }
    if (added.length > addedShown) {
      lines.add(ChatDiffLine(' ', '… ${added.length - addedShown} more'));
    }
    return lines;
  }
}

extension on String {
  String? get ifEmptyNull => isEmpty ? null : this;
}
