import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/domain/agent_kinds.dart';
import 'package:conduit/features/chat_view/domain/chat_items.dart';
import 'package:conduit/features/chat_view/domain/markdown_table.dart';

/// Turns chat content into text that sounds natural when spoken: Markdown
/// syntax is dropped, code blocks become a short cue, lists become
/// sentences, and tool activity collapses into one line.
abstract final class SpeechText {
  /// Longest single utterance handed to the engine (Android caps input at
  /// about 4000 characters).
  static const maxUtterance = 3000;

  static final _fence = RegExp(r'^\s*(```|~~~)');
  static final _heading = RegExp(r'^\s{0,3}#{1,6}\s+');
  static final _bullet = RegExp(
    r'^\s*(?:[-*+]|\d{1,3}[.)])\s+(?:\[[ xX]\]\s+)?',
  );
  static final _quote = RegExp(r'^\s*>+\s?');
  static final _rule = RegExp(r'^\s*(?:[-*_]\s*){3,}$');
  static final _tableRow = RegExp(r'^\s*\|.*\|\s*$');
  static final _sentenceEnd = RegExp(r'[.!?:;…]$');

  /// Plain speech for a Markdown reply.
  static String fromMarkdown(String markdown) {
    final sentences = <String>[];
    final paragraph = <String>[];

    void flushParagraph() {
      if (paragraph.isEmpty) return;
      _addSentence(sentences, paragraph.join(' '));
      paragraph.clear();
    }

    var inFence = false;
    var inTable = false;
    final lines = markdown.replaceAll('\r\n', '\n').split('\n');
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (_fence.hasMatch(line)) {
        if (!inFence) {
          flushParagraph();
          sentences.add('Code block.');
        }
        inFence = !inFence;
        continue;
      }
      if (inFence) continue;
      if (MarkdownTables.tryParse(lines, i) case (final table, final span)?) {
        // The shape, never the cells.
        flushParagraph();
        final rows = table.rows.length;
        sentences.add('Table with $rows row${rows == 1 ? '' : 's'}.');
        i += span - 1;
        continue;
      }
      if (_tableRow.hasMatch(line)) {
        if (!inTable) {
          flushParagraph();
          sentences.add('Table.');
          inTable = true;
        }
        continue;
      }
      inTable = false;
      if (line.trim().isEmpty || _rule.hasMatch(line)) {
        flushParagraph();
        continue;
      }
      if (_heading.hasMatch(line)) {
        flushParagraph();
        _addSentence(sentences, line.replaceFirst(_heading, ''));
        continue;
      }
      if (_bullet.hasMatch(line)) {
        flushParagraph();
        _addSentence(sentences, line.replaceFirst(_bullet, ''));
        continue;
      }
      paragraph.add(line.replaceFirst(_quote, ''));
    }
    flushParagraph();
    return sentences.join(' ');
  }

  static void _addSentence(List<String> sentences, String raw) {
    final text = inline(raw).trim();
    if (text.isEmpty) return;
    sentences.add(_sentenceEnd.hasMatch(text) ? text : '$text.');
  }

  static final _image = RegExp(r'!\[([^\]]*)\]\([^)]*\)');
  static final _link = RegExp(r'\[([^\]]+)\]\([^)]*\)');
  static final _refLink = RegExp(r'\[([^\]]+)\]\[[^\]]*\]');
  static final _autoLink = RegExp(r'<(https?://[^>\s]+)>');
  static final _url = RegExp(r'https?://[^\s)>\]]+');
  static final _code = RegExp(r'`+([^`]+?)`+');
  static final _html = RegExp(r'</?[a-zA-Z][^>]*>');
  static final _strong = RegExp(r'(\*\*|__)(.+?)\1');
  static final _em = RegExp(r'(?<![\w*])\*(?!\s)([^*]+?)\*(?!\w)');
  static final _underscoreEm = RegExp(r'(?<!\w)_(?!\s)([^_]+?)_(?!\w)');
  static final _strike = RegExp(r'~~(.+?)~~');
  static final _spaces = RegExp(r'\s+');

  /// Inline Markdown to words: links read as their text, URLs as their
  /// host, inline code as words, emphasis markers dropped.
  static String inline(String text) {
    var out = text
        .replaceAllMapped(_image, (m) => m[1]!)
        .replaceAllMapped(_link, (m) => m[1]!)
        .replaceAllMapped(_refLink, (m) => m[1]!)
        .replaceAllMapped(_autoLink, (m) => _host(m[1]!))
        .replaceAllMapped(_url, (m) => _host(m[0]!));
    // Code before emphasis, so `snake_case` is not read as emphasis.
    out = out.replaceAllMapped(_code, (m) => codeWords(m[1]!));
    out = out
        .replaceAll(_html, '')
        .replaceAllMapped(_strong, (m) => m[2]!)
        .replaceAllMapped(_strike, (m) => m[1]!)
        .replaceAllMapped(_em, (m) => m[1]!)
        .replaceAllMapped(_underscoreEm, (m) => m[1]!)
        .replaceAll(r'\', '');
    return out.replaceAll(_spaces, ' ').trim();
  }

  static String _host(String url) {
    final uri = Uri.tryParse(url);
    final host = uri?.host ?? '';
    if (host.isEmpty) return 'a link';
    return host.startsWith('www.') ? host.substring(4) : host;
  }

  static final _camel = RegExp(r'(?<=[a-z0-9])(?=[A-Z])');

  /// Inline code as words: `snake_case` → "snake case", `camelCase` →
  /// "camel Case", `lib/foo/bar.dart` → "lib foo bar.dart", `run()` → "run".
  static String codeWords(String code) {
    return code
        .replaceAll('()', '')
        .replaceAll(RegExp(r'[_/\\]+'), ' ')
        .replaceAll(RegExp(r'(?<!\w)--?(?=\w)'), '')
        .replaceAll(RegExp(r'[{}\[\]<>()$`|;=*#"]'), ' ')
        .split(_camel)
        .join(' ')
        .replaceAll(_spaces, ' ')
        .trim();
  }

  /// Splits [text] into utterances no longer than [maxUtterance], breaking
  /// at sentence ends, then at spaces.
  static List<String> chunk(String text, {int max = maxUtterance}) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return const [];
    if (trimmed.length <= max) return [trimmed];
    final chunks = <String>[];
    var rest = trimmed;
    while (rest.length > max) {
      final window = rest.substring(0, max);
      var cut = window.lastIndexOf(RegExp(r'[.!?]\s'));
      if (cut < max ~/ 3) cut = window.lastIndexOf(' ');
      if (cut <= 0) cut = max - 1;
      chunks.add(rest.substring(0, cut + 1).trim());
      rest = rest.substring(cut + 1).trim();
    }
    if (rest.isNotEmpty) chunks.add(rest);
    return chunks;
  }

  /// Brief mode: at most this many sentences...
  static const briefSentences = 3;

  /// ...and about this many characters.
  static const briefChars = 250;

  /// Ends a brief reading that left something out.
  static const moreOnScreen = 'More on screen.';

  static final _sentenceBreak = RegExp(r'(?<=[.!?…])\s+(?=[^a-z])');

  /// [speech] (plain, see [fromMarkdown]) split into sentences. A full
  /// stop before a lowercase word ("e.g. this") does not end one.
  static List<String> sentences(String speech) => [
    for (final part in speech.trim().split(_sentenceBreak))
      if (part.trim().isNotEmpty) part.trim(),
  ];

  /// The first two or three sentences of [speech], up to about
  /// [maxChars]; when something was left out, the spoken text ends with
  /// [moreOnScreen] and [rest] holds the remainder (Talk reads it on
  /// "more").
  static ({String spoken, String? rest}) brief(
    String speech, {
    int maxSentences = briefSentences,
    int maxChars = briefChars,
  }) {
    final all = sentences(speech);
    if (all.isEmpty) return (spoken: '', rest: null);
    final head = <String>[];
    var length = 0;
    for (final sentence in all) {
      if (head.length == maxSentences) break;
      if (head.isNotEmpty && length + 1 + sentence.length > maxChars) break;
      head.add(sentence);
      length += (head.length > 1 ? 1 : 0) + sentence.length;
    }
    var spoken = head.join(' ');
    final restParts = all.skip(head.length).toList();
    if (spoken.length > maxChars) {
      // One very long first sentence: cut it between words.
      var cut = spoken.lastIndexOf(' ', maxChars);
      if (cut <= 0) cut = maxChars;
      restParts.insert(0, spoken.substring(cut).trim());
      spoken = '${spoken.substring(0, cut).trimRight()}…';
    }
    final rest = restParts.join(' ').trim();
    if (rest.isEmpty) return (spoken: spoken, rest: null);
    return (spoken: '$spoken $moreOnScreen', rest: rest);
  }

  /// The final answer of the latest turn: the assistant text after the
  /// last tool call, question or prompt (thinking and notices skipped).
  static List<ChatAssistantText> finalAnswer(List<ChatItem> items) {
    final answer = <ChatAssistantText>[];
    for (var i = items.length - 1; i >= 0; i--) {
      final item = items[i];
      if (item is ChatThinking || item is ChatNotice) continue;
      if (item is! ChatAssistantText) break;
      answer.insert(0, item);
    }
    return answer;
  }

  static const _maxSummary = 160;

  /// "Codex needs your approval to run npm test." ([agent]: the agent's
  /// name for people, "The agent" when unknown). With [hint], adds how to
  /// answer by voice.
  static String approval(
    PendingPermissionRequest request, {
    bool hint = false,
    String? agent,
  }) {
    final summary = _clip(inline(request.summary));
    final tool = request.toolName.startsWith('mcp__')
        ? request.toolName.substring(5).replaceFirst('__', ' ')
        : request.toolName;
    final what = switch (request.toolName) {
      _ when summary.isEmpty || summary == tool => 'to use $tool',
      'Bash' => 'to run $summary',
      'Edit' || 'MultiEdit' || 'Write' || 'NotebookEdit' => 'to edit $summary',
      'WebFetch' => 'to fetch $summary',
      _ => 'to use $tool: $summary',
    };
    final sentence = _end('${agentSubject(agent)} needs your approval $what');
    return hint ? '$sentence Say allow, deny, or always.' : sentence;
  }

  /// "Codex is asking: Which database? Options: Postgres, or SQLite."
  /// With [hint], options are numbered and it says how to answer.
  static String? question(
    ChatQuestion question, {
    bool hint = false,
    String? agent,
  }) {
    final prompts = question.questions;
    if (prompts.isEmpty) return null;
    final parts = <String>[];
    for (final prompt in prompts) {
      final text = _end(_clip(inline(prompt.question)));
      final labels = [
        for (final option in prompt.options.take(hint ? 9 : 4))
          inline(option.label),
      ].where((label) => label.isNotEmpty).toList();
      if (labels.isEmpty) {
        parts.add(text);
      } else if (hint) {
        final numbered = [
          for (var i = 0; i < labels.length; i++) '${i + 1}, ${labels[i]}',
        ].join('; ');
        parts.add('$text Options: $numbered.');
      } else {
        parts.add(
          '$text Options: ${labels.length == 1 ? labels.single : '${labels.sublist(0, labels.length - 1).join(', ')}, or ${labels.last}'}.',
        );
      }
    }
    final spoken = '${agentSubject(agent)} is asking: ${parts.join(' ')}';
    return hint ? '$spoken Say the number or the name.' : spoken;
  }

  /// A pending ExitPlanMode.
  static String planReady({String? agent}) =>
      '${agentSubject(agent)} has a plan ready for your review.';

  static String _clip(String text) => text.length <= _maxSummary
      ? text
      : '${text.substring(0, _maxSummary).trimRight()}…';

  static String _end(String text) =>
      text.isEmpty || _sentenceEnd.hasMatch(text) ? text : '$text.';
}
