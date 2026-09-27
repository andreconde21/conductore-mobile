/// Where [query] occurs in [text], ignoring case: (start, end) pairs in
/// order, not overlapping. An empty or blank query matches nothing.
List<(int, int)> chatSearchRanges(String text, String query) {
  if (query.trim().isEmpty || text.isEmpty) return const [];
  return [
    for (final match in RegExp(
      RegExp.escape(query),
      caseSensitive: false,
    ).allMatches(text))
      if (match.end > match.start) (match.start, match.end),
  ];
}

/// [text] as a Markdown quote, one `> ` per line.
String chatQuote(String text) => text
    .trim()
    .split('\n')
    .map((line) => line.trimRight().isEmpty ? '>' : '> ${line.trimRight()}')
    .join('\n');

/// A message passed on to another agent, saying where it comes from:
/// "From api on VTM:" and the text quoted under it.
String chatForwardPrompt(String text, {required String from, String? host}) {
  final source = host == null || host.isEmpty ? from : '$from on $host';
  return 'From $source:\n${chatQuote(text)}';
}
