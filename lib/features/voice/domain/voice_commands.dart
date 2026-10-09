/// What a spoken command at the end of a dictation does (CON-098).
enum VoiceCommand {
  /// Sends the message without the command words.
  send,

  /// Discards the message.
  cancel,
}

/// A trailing command found in a dictation: what to do, and the text that
/// came before it.
typedef TrailingVoiceCommand = ({VoiceCommand command, String message});

/// The words that act as commands at the end of a dictation, in every
/// language at once (the user may switch dictation languages; a list per
/// language would miss the other one). Each entry is one or more words
/// ("send it").
class VoiceCommandWords {
  const VoiceCommandWords({required this.send, required this.cancel});

  /// Parses the comma-separated lists stored in the settings.
  factory VoiceCommandWords.parse({
    required String send,
    required String cancel,
  }) => VoiceCommandWords(send: _phrases(send), cancel: _phrases(cancel));

  static const defaultSend = 'send, send it, enviar, envia, envie';
  static const defaultCancel = 'cancel, cancelar';

  static final defaults = VoiceCommandWords.parse(
    send: defaultSend,
    cancel: defaultCancel,
  );

  final List<List<String>> send;
  final List<List<String>> cancel;

  bool get isEmpty => send.isEmpty && cancel.isEmpty;

  static List<List<String>> _phrases(String raw) => [
    for (final phrase in raw.split(RegExp(r'[,;\n]')))
      if (normalizeSpeechWords(phrase).isNotEmpty) normalizeSpeechWords(phrase),
  ];

  /// The command [text] ends with, longest phrase first ("send it" before
  /// "send"); null when it ends with none. The message keeps its own
  /// punctuation but drops a comma or dash that led into the command.
  TrailingVoiceCommand? trailing(String text) {
    final tokens = _tokens(text);
    if (tokens.isEmpty) return null;
    TrailingVoiceCommand? best;
    var bestLength = 0;
    void consider(VoiceCommand command, List<List<String>> phrases) {
      for (final phrase in phrases) {
        if (phrase.length <= bestLength || phrase.length > tokens.length) {
          continue;
        }
        final tail = tokens.sublist(tokens.length - phrase.length);
        var matches = true;
        for (var i = 0; i < phrase.length; i++) {
          if (tail[i].word != phrase[i]) {
            matches = false;
            break;
          }
        }
        if (!matches) continue;
        bestLength = phrase.length;
        final message = text
            .substring(0, tail.first.start)
            .replaceFirst(RegExp(r'[\s,;:\-–—]+$'), '');
        best = (command: command, message: message);
      }
    }

    consider(VoiceCommand.send, send);
    consider(VoiceCommand.cancel, cancel);
    return best;
  }

  static List<({String word, int start})> _tokens(String text) => [
    for (final match in RegExp(r'\S+').allMatches(text))
      if (_word(match.group(0)!).isNotEmpty)
        (word: _word(match.group(0)!), start: match.start),
  ];

  static String _word(String raw) => raw.toLowerCase().replaceAll(
    RegExp(r'^[^\p{L}\p{N}]+|[^\p{L}\p{N}]+$', unicode: true),
    '',
  );
}

/// Lower-case words without punctuation, for comparing what a recognizer
/// heard at two moments (it may add a comma or capital letter later).
List<String> normalizeSpeechWords(String text) => [
  for (final raw in text.split(RegExp(r'\s+')))
    if (VoiceCommandWords._word(raw).isNotEmpty) VoiceCommandWords._word(raw),
];
