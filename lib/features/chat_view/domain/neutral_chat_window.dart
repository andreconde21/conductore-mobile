import 'package:conduit/features/chat_view/domain/chat_items.dart';
import 'package:conduit/features/chat_view/domain/chat_transcript.dart';
import 'package:conduit/features/chat_view/domain/neutral_chat_items.dart';

/// The loaded part of a neutral transcript (`format: "items"`, every agent
/// but Claude Code), paged by the companion's opaque cursors: what the chat
/// view keeps between polls instead of Claude Code's byte offsets.
///
/// Items are kept in order by id. A page may send an item again (the
/// companion re-reads the last message, which can grow): it replaces the
/// old one in place.
class NeutralChatWindow {
  final List<String> _order = [];
  final Map<String, Map<Object?, Object?>> _byId = {};

  /// Where the next poll reads on from (`--cursor`); null before the first
  /// page.
  String? cursor;

  /// The page before the loaded window (`--before-cursor`); null when the
  /// window reaches the start of the session.
  String? startCursor;

  bool get isEmpty => _order.isEmpty;

  /// Applies a page read with [cursor] (or the first page). Returns
  /// whether anything changed.
  bool apply(TranscriptPage page) {
    final items = page.neutralItems ?? const [];
    var changed = false;
    if (page.reset || cursor == null) {
      changed = _order.isNotEmpty || cursor == null;
      _order.clear();
      _byId.clear();
      startCursor = page.startCursor;
    }
    for (final item in items) {
      changed = _put(item) || changed;
    }
    if (page.cursor != null) {
      cursor = page.cursor;
    }
    return changed;
  }

  /// Puts an older page ([TranscriptPage.startCursor] read with
  /// `--before-cursor`) in front of the window. Returns whether it brought
  /// anything.
  bool applyOlder(TranscriptPage page) {
    final fresh = [
      for (final item in page.neutralItems ?? const <Map<Object?, Object?>>[])
        if (_id(item) case final id? when !_byId.containsKey(id)) item,
    ];
    startCursor = page.startCursor;
    for (final item in fresh) {
      _byId[_id(item)!] = item;
    }
    _order.insertAll(0, [for (final item in fresh) _id(item)!]);
    return fresh.isNotEmpty;
  }

  /// The chat rows of the window.
  List<ChatItem> build() =>
      NeutralChatItems.parse([for (final id in _order) _byId[id]]);

  bool _put(Map<Object?, Object?> item) {
    final id = _id(item);
    if (id == null) {
      return false;
    }
    final old = _byId[id];
    if (old == null) {
      _order.add(id);
    } else if (_same(old, item)) {
      return false;
    }
    _byId[id] = item;
    return true;
  }

  static String? _id(Map<Object?, Object?> item) =>
      item['id'] is String && (item['id'] as String).isNotEmpty
      ? item['id'] as String
      : null;

  static bool _same(Map<Object?, Object?> a, Map<Object?, Object?> b) =>
      a.toString() == b.toString();
}
