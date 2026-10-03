import 'dart:convert';

import 'package:conduit/features/agent_attention/data/companion_reply.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:flutter/foundation.dart';

/// One content block of a transcript message, as `conductore-hostd
/// transcript` reports it (already capped on the host).
sealed class TranscriptBlock {
  const TranscriptBlock();
}

class TextBlock extends TranscriptBlock {
  const TextBlock(this.text, {this.truncated = false});

  final String text;
  final bool truncated;
}

/// Model reasoning. The host never sends its text, only whether there was
/// any.
class ThinkingBlock extends TranscriptBlock {
  const ThinkingBlock({required this.hasText});

  final bool hasText;
}

class ToolUseBlock extends TranscriptBlock {
  const ToolUseBlock({
    required this.id,
    required this.name,
    required this.input,
    this.truncated = false,
  });

  final String id;
  final String name;

  /// The tool input object; empty when the host sent none. A host-truncated
  /// input keeps its long string fields cut, or becomes `{_truncated,
  /// preview}` when even that was too large.
  final Map<String, Object?> input;
  final bool truncated;
}

class ToolResultBlock extends TranscriptBlock {
  const ToolResultBlock({
    required this.toolUseId,
    required this.isError,
    required this.content,
    this.images = 0,
    this.truncated = false,
  });

  final String toolUseId;
  final bool isError;

  /// The result text (joined text parts), capped at 4 KB by the host.
  final String content;

  /// Number of images the host dropped from the result.
  final int images;
  final bool truncated;
}

/// An image the user attached; the host drops the bytes.
class ImageBlock extends TranscriptBlock {
  const ImageBlock({this.mediaType});

  final String? mediaType;
}

class UnknownBlock extends TranscriptBlock {
  const UnknownBlock(this.type);

  final String type;
}

enum TranscriptEntryType { user, assistant, system, summary }

/// One line of a Claude Code transcript that the chat view renders.
class TranscriptEntry {
  const TranscriptEntry({
    required this.type,
    this.uuid,
    this.parentUuid,
    this.timestamp,
    this.isSidechain = false,
    this.isMeta = false,
    this.isCompactSummary = false,
    this.isApiError = false,
    this.blocks = const [],
    this.subtype,
    this.text,
  });

  final TranscriptEntryType type;
  final String? uuid;
  final String? parentUuid;
  final DateTime? timestamp;

  /// Written by a subagent (Task/Agent tool) rather than the main thread.
  final bool isSidechain;

  /// Injected context (skill bodies, caveats), not something anyone typed.
  final bool isMeta;
  final bool isCompactSummary;
  final bool isApiError;

  /// Message content; a plain-string message becomes one [TextBlock].
  final List<TranscriptBlock> blocks;

  /// `system` lines: their subtype (e.g. `compact_boundary`).
  final String? subtype;

  /// `system` content or `summary` text.
  final String? text;
}

/// The agent's live status as `transcript` reports it alongside the lines.
class ChatAgentStatus {
  const ChatAgentStatus({
    required this.state,
    this.name,
    this.lastMessage,
    this.startedAt,
    this.updatedAt,
    this.endedAt,
    this.pending = const [],
    this.lastEvent,
    this.lastToolName,
  });

  /// `working`, `waiting_input`, `needs_permission` or `ended`.
  final String state;
  final String? name;
  final String? lastMessage;

  /// The last hook event seen (`UserPromptSubmit`, `PreToolUse`,
  /// `PostToolUse`, `Stop`, ...), when the companion reports it.
  final String? lastEvent;

  /// The tool of the last `PreToolUse`/`PostToolUse`, when reported.
  final String? lastToolName;
  final DateTime? startedAt;
  final DateTime? updatedAt;
  final DateTime? endedAt;
  final List<PendingPermissionRequest> pending;

  @override
  bool operator ==(Object other) =>
      other is ChatAgentStatus &&
      other.state == state &&
      other.name == name &&
      other.lastMessage == lastMessage &&
      other.lastEvent == lastEvent &&
      other.lastToolName == lastToolName &&
      other.startedAt == startedAt &&
      other.updatedAt == updatedAt &&
      other.endedAt == endedAt &&
      listEquals(other.pending, pending);

  @override
  int get hashCode => Object.hash(
    state,
    name,
    lastMessage,
    lastEvent,
    lastToolName,
    startedAt,
    updatedAt,
    endedAt,
    Object.hashAll(pending),
  );
}

/// One `transcript` reply.
class TranscriptPage {
  const TranscriptPage({
    required this.offset,
    required this.size,
    required this.start,
    required this.entries,
    this.reset = false,
    this.agent,
    this.items,
    this.cursor,
    this.startCursor,
    this.more = false,
  });

  /// Byte offset to continue from with `--since` (or, for a `--before`
  /// read, the end of the window).
  final int offset;

  /// File size when it was read; `offset < size` means more is waiting.
  final int size;

  /// Offset of the first line returned; 0 means the beginning of the file.
  final int start;
  final List<TranscriptEntry> entries;

  /// The file was replaced; this page is a fresh tail read.
  final bool reset;
  final ChatAgentStatus? agent;

  /// A neutral page (`format: "items"`, every agent but Claude Code): its
  /// items as sent (`NeutralChatItems` turns them into chat rows), null
  /// for Claude Code's entries.
  final List<Map<Object?, Object?>>? items;

  /// Opaque cursors of a neutral page: `--cursor` continues after it,
  /// `--before-cursor` [startCursor] reads the page before it (null: this
  /// page starts the session).
  final String? cursor;
  final String? startCursor;

  /// Another neutral page follows at once.
  final bool more;

  bool get isNeutral => items != null;
}

/// Parses `conductore-hostd transcript` JSON. Unknown line and block types
/// are tolerated so a newer host can add them.
class TranscriptParser {
  const TranscriptParser._();

  static TranscriptPage parsePage(String raw) {
    final decoded = jsonDecode(unpackCompanionReply(raw).trim());
    if (decoded is! Map) {
      throw const FormatException('transcript output is not an object');
    }
    final entries = <TranscriptEntry>[
      if (decoded['entries'] case final List<Object?> list)
        for (final item in list) ?parseEntry(item),
    ];
    final neutral = decoded['format'] == 'items';
    return TranscriptPage(
      offset: _int(decoded['offset']) ?? 0,
      size: _int(decoded['size']) ?? 0,
      start: _int(decoded['start']) ?? 0,
      reset: decoded['reset'] == true,
      entries: entries,
      agent: _agent(decoded['agent']),
      items: neutral
          ? [
              if (decoded['items'] case final List<Object?> list)
                for (final item in list)
                  if (item is Map<Object?, Object?>) item,
            ]
          : null,
      cursor: neutral ? _string(decoded['cursor']) : null,
      startCursor: neutral ? _string(decoded['startCursor']) : null,
      more: neutral && decoded['more'] == true,
    );
  }

  static TranscriptEntry? parseEntry(Object? item) {
    if (item is! Map) {
      return null;
    }
    final type = switch (item['type']) {
      'user' => TranscriptEntryType.user,
      'assistant' => TranscriptEntryType.assistant,
      'system' => TranscriptEntryType.system,
      'summary' => TranscriptEntryType.summary,
      _ => null,
    };
    if (type == null) {
      return null;
    }
    if (type == TranscriptEntryType.summary) {
      return TranscriptEntry(type: type, text: _string(item['summary']));
    }
    final message = item['message'];
    final blocks = <TranscriptBlock>[];
    if (message is Map) {
      final content = message['content'];
      if (content is String) {
        blocks.add(TextBlock(content, truncated: message['truncated'] == true));
      } else if (content is List) {
        for (final block in content) {
          final parsed = _block(block);
          if (parsed != null) {
            blocks.add(parsed);
          }
        }
      }
    }
    return TranscriptEntry(
      type: type,
      uuid: _string(item['uuid']),
      parentUuid: _string(item['parentUuid']),
      timestamp: _date(item['timestamp']),
      isSidechain: item['isSidechain'] == true,
      isMeta: item['isMeta'] == true,
      isCompactSummary: item['isCompactSummary'] == true,
      isApiError: item['isApiErrorMessage'] == true,
      blocks: blocks,
      subtype: _string(item['subtype']),
      text: item['content'] is String ? item['content'] as String : null,
    );
  }

  static TranscriptBlock? _block(Object? block) {
    if (block is! Map) {
      return null;
    }
    return switch (block['type']) {
      'text' => TextBlock(
        block['text'] is String ? block['text'] as String : '',
        truncated: block['truncated'] == true,
      ),
      'thinking' => ThinkingBlock(hasText: block['hasText'] == true),
      'tool_use' => ToolUseBlock(
        id: _string(block['id']) ?? '',
        name: _string(block['name']) ?? 'tool',
        input: block['input'] is Map
            ? Map<String, Object?>.from(block['input'] as Map)
            : const {},
        truncated: block['truncated'] == true,
      ),
      'tool_result' => ToolResultBlock(
        toolUseId: _string(block['tool_use_id']) ?? '',
        isError: block['is_error'] == true,
        content: block['content'] is String ? block['content'] as String : '',
        images: _int(block['images']) ?? 0,
        truncated: block['truncated'] == true,
      ),
      'image' => ImageBlock(mediaType: _string(block['mediaType'])),
      final Object? other => UnknownBlock('$other'),
    };
  }

  static ChatAgentStatus? _agent(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final pending = <PendingPermissionRequest>[
      if (raw['pending'] case final List<Object?> list)
        for (final entry in list)
          if (entry is Map && _string(entry['id']) != null) _request(entry),
    ];
    return ChatAgentStatus(
      state: _string(raw['state']) ?? 'unknown',
      name: _string(raw['name']),
      lastMessage: _string(raw['lastMessage']),
      startedAt: _millis(raw['startedAt']),
      updatedAt: _millis(raw['updatedAt']),
      endedAt: _millis(raw['endedAt']),
      pending: pending,
      lastEvent: _string(raw['lastEvent']),
      lastToolName: _string(raw['lastToolName']),
    );
  }

  static PendingPermissionRequest _request(Map<Object?, Object?> entry) {
    final info = parsePendingApprovalInfo(entry);
    return PendingPermissionRequest(
      id: _string(entry['id'])!,
      toolName: _string(entry['toolName']) ?? 'tool',
      summary:
          _string(entry['summary']) ?? _string(entry['toolName']) ?? 'tool',
      toolInput: _formatInput(entry['toolInput']),
      createdAt: _millis(entry['createdAt']),
      risk: info.risk,
      batchable: info.batchable,
      suggestedRules: info.suggestedRules,
      repo: info.repo,
      questions: parsePendingQuestions(entry['questions']),
    );
  }

  static String _formatInput(Object? input) {
    if (input == null) {
      return '';
    }
    final text = input is String
        ? input
        : const JsonEncoder.withIndent('  ').convert(input);
    const limit = PendingPermissionRequest.maxToolInputLength;
    return text.length <= limit ? text : '${text.substring(0, limit)}\n…';
  }

  static String? _string(Object? value) =>
      value is String && value.isNotEmpty ? value : null;

  static int? _int(Object? value) => switch (value) {
    final int v => v,
    final num v => v.toInt(),
    final String v => int.tryParse(v),
    _ => null,
  };

  static DateTime? _date(Object? value) =>
      value is String ? DateTime.tryParse(value)?.toUtc() : null;

  static DateTime? _millis(Object? value) {
    final millis = _int(value);
    if (millis == null || millis <= 0) {
      return null;
    }
    return DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true);
  }
}
