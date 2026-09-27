/// Redacts what must never leave the device from free text (exception
/// messages, the few strings a crash report carries): machine names,
/// addresses, users, paths, keys and tokens.
///
/// Conductore is an SSH client, so an error message can quote anything the
/// user typed or a server printed. The rules are deliberately greedy; a
/// report that lost a file name is still useful, a leaked host is not.
class TelemetryScrubber {
  TelemetryScrubber({Iterable<String> Function()? sensitiveTerms})
    : _sensitiveTerms = sensitiveTerms ?? (() => const []);

  /// Longest kept exception message, in characters and lines.
  static const maxLength = 500;
  static const maxLines = 8;

  final Iterable<String> Function() _sensitiveTerms;

  // `package:` and `dart:` URIs name the app's own code, never user data,
  // and keep stack references readable.
  static final _codeUri = RegExp(r'\b(?:package|dart):[\w/.\-]+');
  static final _pem = RegExp(
    r'-----BEGIN [A-Z0-9 ]+-----[\s\S]*?(?:-----END [A-Z0-9 ]+-----|$)',
  );
  static final _sshKey = RegExp(
    r'\b(?:ssh|ecdsa|sk)-[\w@.-]+\s+[A-Za-z0-9+/=]{16,}',
  );
  static final _url = RegExp(
    r'\b[A-Za-z][A-Za-z0-9+.\-]*://[^\s'
    "'"
    r'"`<>]+',
  );
  static final _userAtHost = RegExp(
    r'[\w.+\-]+@(?:\d{1,3}(?:\.\d{1,3}){3}|\[[0-9A-Fa-f:.]+\]|'
    r'(?=[\w.\-]*[A-Za-z])[\w.\-]+)',
  );
  static final _windowsPath = RegExp(
    r'(?<![\w])[A-Za-z]:[\\/][^\s'
    "'"
    r'"`,;()\[\]<>]*',
  );
  static final _uncPath = RegExp(
    r'\\\\[^\s'
    "'"
    r'"`,;()\[\]<>]+',
  );
  static final _unixPath = RegExp(
    r'(?<![\w.~/\-<])~?/[^\s'
    "'"
    r'"`,;()\[\]<>]+',
  );
  static final _ipv4 = RegExp(r'(?<![\w.])\d{1,3}(?:\.\d{1,3}){3}(?![\w.])');
  static final _ipv6 = RegExp(
    r'(?<![\w:])(?:[0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4}'
    r'(?:%[\w.]+)?(?![\w:])',
  );
  static final _port = RegExp(
    r'(\bport\s*[=:]\s*|(?<![\w-])(?:-p|--port)[\s=]*)\d{1,5}\b',
    caseSensitive: false,
  );
  static final _placeholderPort = RegExp(
    r'(<(?:ip|host|redacted|user@host)>):\d{1,5}\b',
  );
  // MD5 fingerprints, MAC addresses.
  static final _colonHex = RegExp(
    r'(?<![\w:])(?:[0-9A-Fa-f]{2}:){5,}[0-9A-Fa-f]{2}(?![\w:])',
  );
  static final _hex = RegExp(r'\b[0-9A-Fa-f]{16,}\b');
  static final _token = RegExp(r'[A-Za-z0-9+/_\-]{20,}={0,2}');
  static final _dottedName = RegExp(
    r'(?<![\w.<])(?=[\w\-]*[A-Za-z])[\w\-]+(?:\.[\w\-]+)+(?![\w])',
  );
  static final _quoted = RegExp(r'"[^"\n]{1,300}"');
  // Single quotes, but not apostrophes ("can't ... don't").
  static final _singleQuoted = RegExp(
    r"(?<![A-Za-z0-9])'([^'\n]{1,300})'(?![A-Za-z0-9])",
  );
  // Dart quotes identifiers and types in its own messages: `'_field@123'`,
  // `'String'`, `'List<int>'`, `'dispose()'`. Placeholders stay too.
  static final _codeLike = RegExp(
    r'^(?:_\w*|[\w$]+@\d+|[A-Z]\w*(?:<[\w<>, ?]*>)?\??|[\w.$]+\(\)|<\w+(?:@\w+)?>)$',
  );
  // Paths without a leading slash: `src/app/main.dart`, `feature/acme`.
  static final _relativePath = RegExp(
    r'(?<![\w.~/\-<>:@])[\w.\-]+(?:/[\w.\-]+)+/?',
  );
  // A machine name without dots, where a message names one.
  static final _namedHost = RegExp(
    r"(\b(?:host\s*lookup|hostname|host)\s*[:=]\s*'?)"
    r'(?!<)([A-Za-z0-9][\w\-]*)',
    caseSensitive: false,
  );

  /// [input] with every sensitive part replaced by a `<placeholder>`,
  /// capped at [maxLines] lines and [maxLength] characters.
  String scrub(String input) {
    if (input.isEmpty) return input;
    final terms = _termPatterns();
    final buffer = StringBuffer();
    var last = 0;
    for (final match in _codeUri.allMatches(input)) {
      buffer
        ..write(_scrubText(input.substring(last, match.start), terms))
        ..write(match.group(0));
      last = match.end;
    }
    buffer.write(_scrubText(input.substring(last), terms));
    return _cap(buffer.toString());
  }

  String _scrubText(String text, List<RegExp> terms) {
    if (text.isEmpty) return text;
    var out = text
        .replaceAll(_pem, '<key>')
        .replaceAll(_sshKey, '<key>')
        .replaceAll(_url, '<url>')
        .replaceAll(_userAtHost, '<user@host>')
        .replaceAll(_uncPath, '<path>')
        .replaceAll(_windowsPath, '<path>')
        .replaceAll(_unixPath, '<path>')
        .replaceAll(_relativePath, '<path>');
    for (final term in terms) {
      out = out.replaceAll(term, '<redacted>');
    }
    out = out
        .replaceAll(_quoted, '"<text>"')
        .replaceAllMapped(
          _singleQuoted,
          (m) => _codeLike.hasMatch(m[1]!) ? m[0]! : "'<text>'",
        )
        .replaceAllMapped(_namedHost, (m) => '${m[1]}<host>')
        .replaceAll(_colonHex, '<hex>')
        .replaceAll(_ipv4, '<ip>')
        .replaceAllMapped(
          _ipv6,
          // Needs a hex digit: "a::b" in prose is rare, "::" alone is not
          // an address.
          (m) => RegExp(r'[0-9A-Fa-f]').hasMatch(m[0]!) && m[0]!.length > 2
              ? '<ip>'
              : m[0]!,
        )
        .replaceAll(_hex, '<hex>')
        .replaceAllMapped(
          _token,
          (m) => _looksRandom(m[0]!) ? '<token>' : m[0]!,
        )
        .replaceAll(_dottedName, '<host>')
        .replaceAllMapped(_port, (m) => '${m[1]}<port>')
        .replaceAllMapped(_placeholderPort, (m) => m[1]!);
    return out;
  }

  /// A long run with digits and letters of both cases (or base64
  /// punctuation): a key, token or hash. Plain identifiers like
  /// `_TerminalWorkspaceControllerState` have no digits.
  static bool _looksRandom(String run) {
    final digits = RegExp(r'\d').allMatches(run).length;
    if (digits == 0) return false;
    final letters = RegExp(r'[A-Za-z]').hasMatch(run);
    return letters && (digits >= 3 || RegExp(r'[+/]').hasMatch(run));
  }

  List<RegExp> _termPatterns() {
    final terms = <String>{};
    for (final raw in _sensitiveTerms()) {
      final term = raw.trim();
      if (term.length >= 2) terms.add(term);
    }
    final sorted = terms.toList()..sort((a, b) => b.length - a.length);
    return [
      for (final term in sorted)
        RegExp(
          '(?<![A-Za-z0-9_])${RegExp.escape(term)}(?![A-Za-z0-9_])',
          caseSensitive: false,
        ),
    ];
  }

  static String _cap(String text) {
    var lines = text.split('\n');
    var capped = lines.length > maxLines;
    if (capped) lines = lines.take(maxLines).toList();
    var out = lines.join('\n');
    if (out.length > maxLength) {
      out = out.substring(0, maxLength);
      capped = true;
    }
    return capped ? '$out…' : out;
  }
}
