import 'package:conduit/features/chat_view/domain/chat_items.dart';
import 'package:conduit/features/chat_view/domain/chat_search_text.dart';
import 'package:conduit/features/chat_view/presentation/chat_message_content.dart';
import 'package:flutter/foundation.dart';

/// One occurrence of the search text: in [itemId]'s row, text run
/// [segment] (see [chatSearchSegments]), the [occurrence]-th match there.
@immutable
class ChatSearchMatch {
  const ChatSearchMatch(this.itemId, this.segment, this.occurrence);

  final String itemId;
  final int segment;
  final int occurrence;

  @override
  bool operator ==(Object other) =>
      other is ChatSearchMatch &&
      other.itemId == itemId &&
      other.segment == segment &&
      other.occurrence == occurrence;

  @override
  int get hashCode => Object.hash(itemId, segment, occurrence);
}

/// The find bar's state: the query, its matches in the thread as shown
/// (oldest first) and which one is current.
///
/// [update] runs with every build of the thread; it searches again only
/// when the query or the thread changed, and keeps the current match
/// across that. A new query starts at the newest match. [takeReveal] says
/// when the page should scroll the current match into view.
class ChatSearch extends ChangeNotifier {
  bool _open = false;
  String _query = '';
  List<ChatSearchMatch> _matches = const [];
  Map<String, List<ChatSearchMatch>> _byItem = const {};
  int _current = -1;
  Object? _signature;
  String? _searched;
  bool _reveal = false;
  bool _searchingEarlier = false;
  bool _noEarlier = false;

  bool get isOpen => _open;
  String get query => _query;
  bool get active => _open && _query.trim().isNotEmpty;
  List<ChatSearchMatch> get matches => _matches;
  int get current => _current;
  ChatSearchMatch? get currentMatch =>
      _current >= 0 && _current < _matches.length ? _matches[_current] : null;

  /// Older transcript pages are being loaded to look further back.
  bool get searchingEarlier => _searchingEarlier;

  /// Looking further back found nothing more.
  bool get noEarlier => _noEarlier;

  set searchingEarlier(bool value) {
    if (_searchingEarlier == value) return;
    _searchingEarlier = value;
    notifyListeners();
  }

  set noEarlier(bool value) {
    if (_noEarlier == value) return;
    _noEarlier = value;
    notifyListeners();
  }

  void open() {
    if (_open) return;
    _open = true;
    notifyListeners();
  }

  void close() {
    if (!_open) return;
    _open = false;
    _query = '';
    _matches = const [];
    _byItem = const {};
    _current = -1;
    _searched = null;
    _noEarlier = false;
    notifyListeners();
  }

  set query(String value) {
    if (value == _query) return;
    _query = value;
    _noEarlier = false;
    notifyListeners();
  }

  /// Searches [items] (the thread as shown, oldest first) when [signature]
  /// or the query changed since the last call. No notification: this runs
  /// during build.
  void update(Object signature, List<ChatItem> Function() items) {
    if (!active) {
      _matches = const [];
      _byItem = const {};
      _current = -1;
      _searched = null;
      return;
    }
    if (signature == _signature && _query == _searched) return;
    final newQuery = _query != _searched;
    final previous = currentMatch;
    _signature = signature;
    _searched = _query;
    final matches = <ChatSearchMatch>[];
    for (final item in items()) {
      final segments = chatSearchSegments(item);
      for (var s = 0; s < segments.length; s++) {
        final count = chatSearchRanges(segments[s], _query).length;
        for (var o = 0; o < count; o++) {
          matches.add(ChatSearchMatch(item.id, s, o));
        }
      }
    }
    _matches = matches;
    _byItem = {};
    for (final match in matches) {
      (_byItem[match.itemId] ??= []).add(match);
    }
    if (newQuery || previous == null) {
      _current = matches.length - 1;
      _reveal = matches.isNotEmpty;
    } else {
      final kept = matches.indexOf(previous);
      _current = kept != -1 ? kept : matches.length - 1;
    }
  }

  bool hasMatch(String itemId) => _byItem.containsKey(itemId);

  /// The current match's (segment, occurrence) when it is in [itemId].
  (int, int)? currentIn(String itemId) {
    final match = currentMatch;
    return match == null || match.itemId != itemId
        ? null
        : (match.segment, match.occurrence);
  }

  /// Whether the current match is the oldest one.
  bool get atOldest => _current <= 0;

  /// Moves to the next older match, wrapping to the newest.
  void previous() => _select(
    _matches.isEmpty ? -1 : (_current - 1 + _matches.length) % _matches.length,
  );

  /// Moves to the next newer match, wrapping to the oldest.
  void next() =>
      _select(_matches.isEmpty ? -1 : (_current + 1) % _matches.length);

  /// Makes match [index] current and asks for it to be shown.
  void select(int index) => _select(index);

  void _select(int index) {
    if (index < 0 || index >= _matches.length) return;
    _current = index;
    _reveal = true;
    notifyListeners();
  }

  /// Whether the current match should be scrolled into view (once).
  bool takeReveal() {
    final reveal = _reveal;
    _reveal = false;
    return reveal;
  }
}
