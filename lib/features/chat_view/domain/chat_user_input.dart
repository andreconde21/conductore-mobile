import 'dart:convert';

/// One piece of a transcript `user` line. Claude Code writes several
/// inputs that are not the human typing as `user` lines: messages from
/// teammates and other sessions, background task notifications, system
/// reminders, `!` shell commands and their output, slash commands.
sealed class UserInputPart {
  const UserInputPart();
}

/// What the user actually typed, with any pasted blocks set apart.
class UserTextPart extends UserInputPart {
  const UserTextPart(this.text, {this.pasted = const []});

  final String text;
  final List<String> pasted;
}

/// `/command args`.
class SlashCommandPart extends UserInputPart {
  const SlashCommandPart(this.command);

  final String command;
}

/// A `!` shell command the user ran.
class ShellInputPart extends UserInputPart {
  const ShellInputPart(this.command);

  final String command;
}

/// The output of the preceding `!` command.
class ShellOutputPart extends UserInputPart {
  const ShellOutputPart({required this.stdout, required this.stderr});

  final String stdout;
  final String stderr;
}

/// A message from a teammate agent or another Claude session.
class AgentMessagePart extends UserInputPart {
  const AgentMessagePart({
    required this.from,
    required this.body,
    this.summary,
    this.idle = false,
    this.session = false,
  });

  final String from;
  final String? summary;
  final String body;
  final bool idle;
  final bool session;
}

/// A background task finished.
class TaskPart extends UserInputPart {
  const TaskPart({required this.summary, this.status});

  final String summary;
  final String? status;
}

/// Splits a `user` line's text into what the human wrote and what agents
/// and the harness injected. Tolerant: anything it does not recognise
/// stays as the user's text.
abstract final class ChatUserInput {
  static final _systemReminder = RegExp(
    r'<system-reminder>[\s\S]*?</system-reminder>',
  );

  /// A reminder cut off by the host's line cap (no closing tag). Only at
  /// the start of a line, where the harness puts them: the user writing
  /// about the tag mid-sentence must not lose the rest of the prompt.
  static final _openSystemReminder = RegExp(
    r'(^|\n)[ \t]*<system-reminder>[\s\S]*$',
  );

  /// The paragraph Claude Code appends to a message from another session
  /// ("This came from another Claude session — not typed by your user…"):
  /// its opening sentence up to the end of the paragraph, whatever
  /// follows the first sentence.
  static final _peerTrailer = RegExp(
    r'(^|\n)[ \t]*This came from another Claude session\b[^\n]*'
    r'(\n[ \t]*\S[^\n]*)*',
  );
  static final _agentMessage = RegExp(
    r'<(teammate-message|cross-session-message)\b([^>]*)>([\s\S]*?)</\1>',
  );

  /// A message cut off by the host's line cap (no closing tag), at the
  /// start of a line like the harness writes it.
  static final _openAgentMessage = RegExp(
    r'(?:^|\n)[ \t]*<(teammate-message|cross-session-message)\b([^>]*)>'
    r'([\s\S]*)$',
  );
  static final _attribute = RegExp(r'([\w-]+)="([^"]*)"');
  static final _task = RegExp(
    r'<task-notification>([\s\S]*?)</task-notification>',
  );
  static final _pasted = RegExp(
    r'<pasted_content\b[^>]*>([\s\S]*?)</pasted_content>',
  );

  /// Stands in for a pasted block while the harness tags are stripped, so
  /// whatever the user pasted (a log full of tags, a transcript) is never
  /// taken for injected content.
  static final _pastedSlot = RegExp('\u0000(\\d+)\u0000');
  static final _whileWorking = RegExp(
    r'^\s*The user sent a new message while you were working:\s*([\s\S]*?)'
    r'(?:\n\s*\n\s*IMPORTANT:[\s\S]*)?$',
  );

  /// Tags that only carry harness noise; their lines are hidden.
  static const _hiddenTags = [
    'local-command-stdout',
    'local-command-stderr',
    'local-command-caveat',
    'command-message',
    'command-args',
  ];

  static const _agentPrefix = 'Another Claude session sent a message:';
  static const _systemNotification = '[SYSTEM NOTIFICATION - NOT USER INPUT]';

  static List<UserInputPart> parse(String raw) {
    if (raw.trimLeft().startsWith(_systemNotification)) {
      return const [];
    }
    final parts = <UserInputPart>[];
    final pastes = <String>[];
    String restore(String text) => text.replaceAllMapped(
      _pastedSlot,
      (match) => pastes[int.parse(match[1]!)],
    );
    var text = raw
        .replaceAllMapped(_pasted, (match) {
          pastes.add(match[0]!);
          return '\u0000${pastes.length - 1}\u0000';
        })
        .replaceAll(_systemReminder, '')
        .replaceAll(_openSystemReminder, '');

    // Messages from other agents (several may share one line).
    var fromAgents = false;
    if (_agentMessage.hasMatch(text)) {
      for (final match in _agentMessage.allMatches(text)) {
        parts.add(_agentPart(match, restore));
      }
      text = text.replaceAll(_agentMessage, '');
      fromAgents = true;
    }
    final open = _openAgentMessage.firstMatch(text);
    if (open != null) {
      parts.add(_agentPart(open, restore));
      text = text.substring(0, open.start);
      fromAgents = true;
    }
    // The harness's framing around agent messages. Without one, only a
    // trailer that is the whole line is dropped (it can arrive alone); the
    // user quoting either sentence keeps it.
    if (fromAgents) {
      text = text.replaceAll(_agentPrefix, '').replaceAll(_peerTrailer, '');
    } else if (text.replaceAll(_peerTrailer, '').trim().isEmpty) {
      text = '';
    }

    for (final match in _task.allMatches(text)) {
      final body = match[1]!;
      final summary = _tag(body, 'summary');
      final status = _tag(body, 'status');
      parts.add(
        TaskPart(
          summary: summary ?? 'Background task ${status ?? 'finished'}',
          status: status,
        ),
      );
    }
    text = text.replaceAll(_task, '');

    final bashInput = _tag(text, 'bash-input');
    if (bashInput != null) {
      parts.add(ShellInputPart(bashInput));
    }
    final stdout = _tag(text, 'bash-stdout');
    final stderr = _tag(text, 'bash-stderr');
    if (stdout != null || stderr != null) {
      parts.add(ShellOutputPart(stdout: stdout ?? '', stderr: stderr ?? ''));
    }
    text = _strip(text, ['bash-input', 'bash-stdout', 'bash-stderr']);

    final command = _tag(text, 'command-name');
    if (command != null) {
      final args = _tag(text, 'command-args') ?? '';
      final name = command.startsWith('/') ? command : '/$command';
      parts.add(SlashCommandPart(args.isEmpty ? name : '$name $args'));
      text = _strip(text, ['command-name']);
    }
    text = _strip(text, _hiddenTags);

    final working = _whileWorking.firstMatch(text);
    if (working != null) {
      text = working[1]!;
    }

    text = restore(text);
    final pasted = [
      for (final match in _pasted.allMatches(text)) match[1]!.trim(),
    ];
    text = text.replaceAll(_pasted, '').trim();
    if (text.isNotEmpty || pasted.isNotEmpty) {
      parts.add(UserTextPart(text, pasted: pasted));
    }
    return parts;
  }

  static AgentMessagePart _agentPart(
    RegExpMatch match,
    String Function(String) restore,
  ) {
    final session = match[1] == 'cross-session-message';
    final attributes = {
      for (final a in _attribute.allMatches(match[2]!)) a[1]!: a[2]!,
    };
    final from =
        attributes['teammate_id'] ?? attributes['from'] ?? 'another agent';
    // A cut-off message runs to the end of the line, trailer included.
    final body = restore(match[3]!.replaceAll(_peerTrailer, '')).trim();
    if (body.startsWith('{')) {
      try {
        final json = jsonDecode(body);
        if (json is Map) {
          final type = json['type'];
          final result = json['result'];
          if (type == 'idle_notification') {
            return AgentMessagePart(
              from: json['from'] is String ? json['from'] as String : from,
              body: result is String ? result.trim() : '',
              idle: true,
              session: session,
            );
          }
          if (type is String) {
            return AgentMessagePart(
              from: from,
              summary: type.replaceAll('_', ' '),
              body: result is String ? result.trim() : '',
              session: session,
            );
          }
        }
      } on FormatException {
        // Not JSON after all: show it as text.
      }
    }
    return AgentMessagePart(
      from: from,
      summary: attributes['summary'],
      body: body,
      session: session,
    );
  }

  static String? _tag(String text, String name) =>
      RegExp('<$name>([\\s\\S]*?)</$name>').firstMatch(text)?[1]?.trim();

  static String _strip(String text, List<String> names) {
    var out = text;
    for (final name in names) {
      out = out.replaceAll(RegExp('<$name>[\\s\\S]*?</$name>'), '');
    }
    return out;
  }
}
