/// Talkbawt links and server addresses (CON-050).
///
/// A link is `https://<server>/t/g_<32 hex>` (share: read, and reply on a
/// thread) or `/t/o_<32 hex>` (owner: also revoke and the access log). The
/// server must be `https://`; plain `http://` only for this machine or the
/// tailnet (the companion's bundled server). The companion applies the same
/// rules (host/lib/talkbawt.js).
library;

/// The server the app and companions use unless the user picks another.
const defaultTalkbawtServer = 'https://talkbawt.outsmartis.dev';

/// Why a server URL or link was refused.
class TalkbawtAddressError implements Exception {
  const TalkbawtAddressError(this.message);

  final String message;

  @override
  String toString() => message;
}

bool _isLoopback(String host) =>
    host == 'localhost' ||
    host == '::1' ||
    RegExp(r'^127\.\d{1,3}\.\d{1,3}\.\d{1,3}$').hasMatch(host);

/// Tailscale's 100.64.0.0/10, fd7a:115c:a1e0::/48 and MagicDNS names.
bool isTailnetAddress(String host) {
  final v4 = RegExp(
    r'^(\d{1,3})\.(\d{1,3})\.\d{1,3}\.\d{1,3}$',
  ).firstMatch(host);
  if (v4 != null) {
    final second = int.parse(v4.group(2)!);
    return int.parse(v4.group(1)!) == 100 && second >= 64 && second <= 127;
  }
  if (host.toLowerCase().startsWith('fd7a:115c:a1e0:')) return true;
  return host.toLowerCase().endsWith('.ts.net');
}

String _origin(Uri uri) {
  final defaultPort =
      (uri.scheme == 'https' && uri.port == 443) ||
      (uri.scheme == 'http' && uri.port == 80);
  final host = uri.host.contains(':') ? '[${uri.host}]' : uri.host;
  return '${uri.scheme}://${host.toLowerCase()}'
      '${uri.hasPort && !defaultPort ? ':${uri.port}' : ''}';
}

/// The origin of a Talkbawt server ("https://talkbawt.example.com"), or a
/// [TalkbawtAddressError] saying why it cannot be used.
String talkbawtServerOrigin(String raw) {
  final text = raw.trim();
  final uri = Uri.tryParse(text);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
    throw const TalkbawtAddressError(
      'Enter the server address, like https://talkbawt.example.com.',
    );
  }
  if (uri.userInfo.isNotEmpty) {
    throw const TalkbawtAddressError(
      'The server address must not carry a login.',
    );
  }
  if ((uri.path.isNotEmpty && uri.path != '/') ||
      uri.hasQuery ||
      uri.hasFragment) {
    throw const TalkbawtAddressError(
      'Only the server address, without a path: https://talkbawt.example.com.',
    );
  }
  if (uri.scheme == 'https') return _origin(uri);
  if (uri.scheme == 'http' &&
      (_isLoopback(uri.host) || isTailnetAddress(uri.host))) {
    return _origin(uri);
  }
  throw const TalkbawtAddressError(
    'The server must use https://. Plain http:// works only for localhost '
    'or a tailnet address (a machine\'s bundled server).',
  );
}

/// Whose link it is.
enum TalkbawtRole {
  /// A share link: read, and reply on a thread.
  guest,

  /// An owner link: also revoke, and see who opened it.
  owner,
}

/// A parsed Talkbawt link.
class TalkbawtLink {
  const TalkbawtLink({
    required this.origin,
    required this.token,
    required this.role,
  });

  /// The server it lives on, like "https://talkbawt.outsmartis.dev".
  final String origin;
  final String token;
  final TalkbawtRole role;

  String get url => '$origin/t/$token';

  /// The server's host name, for "this link is on talkbawt.example.com".
  String get host => Uri.parse(origin).host;

  /// Null when [raw] is not a Talkbawt link (surrounding whitespace is
  /// allowed, nothing else). Throws [TalkbawtAddressError] for a link on a
  /// plain-http public server.
  static TalkbawtLink? tryParse(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
    if (uri.hasQuery || uri.hasFragment) return null;
    final match = RegExp(r'^/t/([go]_[0-9a-f]{32})/?$').firstMatch(uri.path);
    if (match == null) return null;
    final origin = talkbawtServerOrigin(_origin(uri));
    final token = match.group(1)!;
    return TalkbawtLink(
      origin: origin,
      token: token,
      role: token.startsWith('o_') ? TalkbawtRole.owner : TalkbawtRole.guest,
    );
  }

  /// The first Talkbawt link in [text] (a shared message: "Handoff for
  /// you: https://…/t/g_… — open it"), or null.
  static TalkbawtLink? find(String text) {
    for (final match in RegExp(
      r'https?://[^\s/]+/t/[go]_[0-9a-f]{32}',
    ).allMatches(text)) {
      try {
        final link = tryParse(match.group(0)!);
        if (link != null) return link;
      } on TalkbawtAddressError {
        continue;
      }
    }
    return null;
  }

  /// "…/t/g_…abcd": what the UI shows of a link it does not need whole.
  String get redacted =>
      '$origin/t/${token.substring(0, 2)}…${token.substring(token.length - 4)}';

  @override
  bool operator ==(Object other) =>
      other is TalkbawtLink && other.origin == origin && other.token == token;

  @override
  int get hashCode => Object.hash(origin, token);
}
