import 'package:conduit/features/chat_view/domain/chat_items.dart';

/// Where a message sent from the chat view stands.
enum ChatSendState {
  /// On its way to the host.
  sending,

  /// Typed into the session; the transcript has not shown it yet.
  sent,

  /// The host refused it or could not be reached; nothing was typed.
  failed,
}

/// A prompt, or a question answer, sent from the chat view, shown at once
/// as a pending bubble until the transcript brings the real entry.
///
/// Not a [ChatItem]: read-aloud, Talk and the working state only ever see
/// the transcript, so a pending bubble is never spoken or counted.
class ChatOutgoing {
  const ChatOutgoing({
    required this.id,
    required this.text,
    required this.state,
    this.error,
    this.late = false,
    this.answer = false,
    this.confirmedId,
  });

  /// Stable while it is shown (widget key).
  final String id;

  /// What was typed; for an answer, what is shown (`2. Yes`).
  final String text;
  final ChatSendState state;

  /// Why it failed.
  final String? error;

  /// Sent a while ago and still not in the transcript.
  final bool late;

  /// An answer to a question the agent asked, not a prompt.
  final bool answer;

  /// The transcript item that confirmed it; null while pending.
  final String? confirmedId;

  bool get pending => confirmedId == null;
}

/// Tells whether a transcript item is the prompt the user sent.
///
/// The transcript does not hold the text exactly as typed: Claude Code may
/// set a paste apart (`<pasted_content>`), turn an image path into
/// `[Image #1]` plus an image, wrap it for a prompt typed mid-turn, and the
/// host caps long text. So both sides are compared as words, without image
/// placeholders or image paths.
abstract final class ChatOutgoingMatch {
  static final _placeholder = RegExp(
    r'\[(?:Image|Pasted text|Pasted image) #\d+[^\]]*\]',
  );
  static final _imagePath = RegExp(
    r'''(?:^|(?<=\s))['"]?\S+\.(?:png|jpe?g|gif|webp|heic|bmp)['"]?(?=\s|$)''',
    caseSensitive: false,
  );
  static final _space = RegExp(r'\s+');

  static String normalize(String text) => text
      .replaceAll(_placeholder, ' ')
      .replaceAll(_imagePath, ' ')
      .replaceAll(_space, ' ')
      .trim();

  /// Whether [item] shows the prompt [sent].
  static bool matches(String sent, ChatItem item) {
    final String shown;
    var truncated = false;
    switch (item) {
      case ChatUserMessage():
        shown = [item.text, ...item.pasted].join(' ');
        truncated = item.truncated;
      case ChatShellCommand(:final command):
        // `!cmd` is recorded as the command alone.
        final typed = sent.trimLeft();
        return typed.startsWith('!') &&
            normalize(typed.substring(1)) == normalize(command);
      default:
        return false;
    }
    final want = normalize(sent);
    final got = normalize(shown);
    if (want == got) return true;
    if (want.isEmpty || got.isEmpty) {
      return false;
    }
    if (truncated || got.endsWith('…')) {
      final head = got.endsWith('…') ? got.substring(0, got.length - 1) : got;
      final flat = head.replaceAll(' ', '');
      if (flat.length >= 16 && want.replaceAll(' ', '').startsWith(flat)) {
        return true;
      }
    }
    // Pasted blocks may come back out of place: the same words suffice.
    final a = want.split(' ')..sort();
    final b = got.split(' ')..sort();
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
