import 'dart:collection';
import 'dart:typed_data';
import 'dart:ui';

import 'package:conduit_vt/src/core/buffer/line.dart';

/// Recorded pictures of the terminal's lines, so a frame replays the lines
/// that did not change instead of drawing every cell again. Scrolling and
/// streaming output then only record the lines that are new or changed,
/// like a native terminal's damage tracking.
///
/// A picture is reused only while its line holds exactly the cells it was
/// recorded from (compared cell by cell, so no mutation can be missed) and
/// the painter's [generation] is unchanged.
class LinePictureCache {
  final _entries = LinkedHashMap<BufferLine, _Entry>.identity();

  int get length => _entries.length;

  /// Lines recorded since the cache was created, for tests and benchmarks.
  int recorded = 0;

  /// The picture of [line], recording it with [record] when there is none
  /// or the line changed.
  Picture pictureOf(
    BufferLine line,
    int generation,
    Picture Function(BufferLine line) record,
  ) {
    final entry = _entries.remove(line);
    if (entry != null && entry.matches(line, generation)) {
      // Re-inserted at the end: least recently used lines come first.
      _entries[line] = entry;
      return entry.picture;
    }
    entry?.picture.dispose();
    final picture = record(line);
    recorded++;
    _entries[line] = _Entry(line, generation, picture);
    return picture;
  }

  /// Drops the least recently used pictures beyond [maxLines].
  void trim(int maxLines) {
    while (_entries.length > maxLines) {
      final line = _entries.keys.first;
      _entries.remove(line)!.picture.dispose();
    }
  }

  void clear() {
    for (final entry in _entries.values) {
      entry.picture.dispose();
    }
    _entries.clear();
  }
}

class _Entry {
  _Entry(BufferLine line, this.generation, this.picture)
      : length = line.length,
        cells = Uint32List.fromList(
          Uint32List.sublistView(line.data, 0, line.length * _intsPerCell),
        );

  static const _intsPerCell = 4;

  final int generation;
  final int length;
  final Uint32List cells;
  final Picture picture;

  bool matches(BufferLine line, int generation) {
    if (generation != this.generation || line.length != length) return false;
    final data = line.data;
    final cells = this.cells;
    for (var i = 0; i < cells.length; i++) {
      if (data[i] != cells[i]) return false;
    }
    return true;
  }
}
