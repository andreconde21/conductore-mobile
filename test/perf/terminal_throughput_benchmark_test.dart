// Terminal output throughput: 10 MB of typical output (coloured `ls -l`,
// build logs, some Unicode) through the string sequence filter, the VT
// parser and buffer (conduit_vt), and the TerminalView at frame pace.
import 'package:conduit/features/terminal/domain/terminal_string_sequence_filter.dart';
import 'package:conduit_vt/conduit_vt.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'perf_probe.dart';

const _megabytes = 10;

/// About [megabytes] MB of output, cut into [chunk]-sized writes the way an
/// SSH channel delivers them.
List<String> output({int megabytes = _megabytes, int chunk = 16 * 1024}) {
  final text = StringBuffer();
  var i = 0;
  while (text.length < megabytes * 1024 * 1024) {
    switch (i % 4) {
      case 0:
        text.write(
          '\x1b[01;34mdrwxr-xr-x\x1b[0m  2 dev dev  4096 Sep 27 12:00 '
          '\x1b[01;34mpackage_$i\x1b[0m\r\n',
        );
      case 1:
        text.write(
          '[${i.toString().padLeft(6)}] Compiling lib/features/module_$i.dart '
          '… ok (${i % 97} ms)\r\n',
        );
      case 2:
        text.write('\x1b[32m✓\x1b[0m test $i passed — café naïve 漢字\r\n');
      case 3:
        text.write(
          'plain log line number $i with some ordinary words in it\r\n',
        );
    }
    i += 1;
  }
  final all = text.toString();
  return [
    for (var start = 0; start < all.length; start += chunk)
      all.substring(
        start,
        start + chunk > all.length ? all.length : start + chunk,
      ),
  ];
}

double mbPerSecond(int chars, int micros) =>
    chars / (1024 * 1024) / (micros / 1e6);

void main() {
  final chunks = output();
  final chars = chunks.fold(0, (n, c) => n + c.length);

  test('string sequence filter', () {
    final us = bestMicros(() {
      final filter = TerminalStringSequenceFilter();
      for (final chunk in chunks) {
        filter.process(chunk);
      }
    }, runs: 3);
    perfReport('terminal.filter', {
      'mb': _megabytes,
      'mb_per_s': mbPerSecond(chars, us).toStringAsFixed(1),
    });
  });

  test('VT parser and buffer (conduit_vt Terminal.write)', () {
    final us = bestMicros(() {
      final terminal = Terminal(maxLines: 10000)..resize(120, 40);
      for (final chunk in chunks) {
        terminal.write(chunk);
      }
    }, runs: 2);
    perfReport('terminal.vt_write', {
      'mb': _megabytes,
      'mb_per_s': mbPerSecond(chars, us).toStringAsFixed(1),
    });
  });

  testWidgets('TerminalView receiving 10 MB at frame pace', (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final terminal = Terminal(maxLines: 10000);
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: TerminalView(terminal))),
    );
    final probe = FrameProbe()..install();
    final watch = Stopwatch()..start();
    // 64 KB per 16 ms frame: about 4 MB/s, a fast `cat`.
    final big = output(chunk: 64 * 1024);
    try {
      for (final chunk in big) {
        terminal.write(chunk);
        await tester.pump(const Duration(milliseconds: 16));
      }
    } finally {
      probe.uninstall();
    }
    final us = watch.elapsedMicroseconds;
    perfReport('terminal.view_10mb', {
      'frames': big.length,
      'builds': probe.builds,
      'paints': probe.paints,
      'mb_per_s': mbPerSecond(chars, us).toStringAsFixed(1),
      'ms_per_frame': (us / big.length / 1000).toStringAsFixed(2),
    });
  });
}
