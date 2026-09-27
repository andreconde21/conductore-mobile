import 'dart:io';

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Counts widget rebuilds and render object paints while installed (debug
/// builds only, which is what `flutter test` runs), for the benchmarks in
/// this folder.
///
/// Numbers are for comparing before and after a change on this machine,
/// not absolute device timings: tests run in debug mode (JIT, asserts on).
class FrameProbe {
  int builds = 0;
  int paints = 0;
  final Map<String, int> buildsByType = {};
  final Map<String, int> paintsByType = {};

  void install() {
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      builds += 1;
      final type = element.widget.runtimeType.toString();
      buildsByType[type] = (buildsByType[type] ?? 0) + 1;
    };
    debugOnProfilePaint = (renderObject) {
      paints += 1;
      final type = renderObject.runtimeType.toString();
      paintsByType[type] = (paintsByType[type] ?? 0) + 1;
    };
  }

  /// Must run before the test ends: the binding checks these are unset.
  void uninstall() {
    debugOnRebuildDirtyWidget = null;
    debugOnProfilePaint = null;
  }

  void reset() {
    builds = 0;
    paints = 0;
    buildsByType.clear();
    paintsByType.clear();
  }

  /// The [count] widget types rebuilt most, for reports.
  String top([int count = 6]) => _top(buildsByType, count);

  /// The [count] render object types painted most, for reports.
  String topPaints([int count = 6]) => _top(paintsByType, count);

  static String _top(Map<String, int> counts, int count) {
    final sorted = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return sorted.take(count).map((e) => '${e.key}:${e.value}').join(' ');
  }
}

/// One benchmark line, `PERF <name> key=value …`, on stdout and appended to
/// `$CONDUCTORE_PERF_LOG` when set (the baseline report is built from it).
void perfReport(String name, Map<String, Object> values) {
  final line =
      'PERF $name ${values.entries.map((e) => '${e.key}=${e.value}').join(' ')}';
  // ignore: avoid_print
  print(line);
  final log = Platform.environment['CONDUCTORE_PERF_LOG'];
  if (log != null && log.isNotEmpty) {
    File(log).writeAsStringSync('$line\n', mode: FileMode.append);
  }
}

/// Microseconds [body] takes, the best of [runs] (after one warm-up).
int bestMicros(void Function() body, {int runs = 5}) {
  body();
  var best = -1;
  for (var i = 0; i < runs; i++) {
    final watch = Stopwatch()..start();
    body();
    final us = watch.elapsedMicroseconds;
    if (best < 0 || us < best) best = us;
  }
  return best;
}
