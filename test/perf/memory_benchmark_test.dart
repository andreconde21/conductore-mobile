// What stays in memory: a full terminal scrollback per session, the home
// page's preview captures (made every refresh, per tile), and the Chat
// view's transcript as a session grows.
import 'package:conduit/features/chat_view/domain/chat_items.dart';
import 'package:conduit/features/chat_view/domain/chat_transcript.dart';
import 'package:conduit/features/sessions/presentation/terminal_preview.dart';
import 'package:conduit_vt/conduit_vt.dart';
import 'package:flutter_test/flutter_test.dart';

import '../features/chat_view/chat_fixtures.dart';
import 'perf_probe.dart';

int scrollbackBytes(Terminal terminal) {
  var bytes = 0;
  for (var i = 0; i < terminal.buffer.lines.length; i++) {
    bytes += terminal.buffer.lines[i].data.lengthInBytes;
  }
  return bytes;
}

void main() {
  test('terminal scrollback per session (10,000 lines)', () {
    for (final columns in [80, 120, 200]) {
      final terminal = Terminal(maxLines: 10000)..resize(columns, 40);
      for (var i = 0; i < 10500; i++) {
        terminal.write('line $i of the scrollback with some text\r\n');
      }
      perfReport('memory.scrollback', {
        'columns': columns,
        'lines': terminal.buffer.lines.length,
        'mb': (scrollbackBytes(terminal) / (1024 * 1024)).toStringAsFixed(1),
      });
    }
  });

  test('home preview capture of one tile', () {
    final terminal = Terminal(maxLines: 10000)..resize(120, 40);
    for (var i = 0; i < 200; i++) {
      terminal.write('\x1b[32mok\x1b[0m line $i of a busy session\r\n');
    }
    final us = bestMicros(() => StyledTerminalPreview.capture(terminal));
    final preview = StyledTerminalPreview.capture(terminal);
    perfReport('memory.preview_capture', {
      'rows': preview.rows.length,
      'runs': preview.rows.fold<int>(0, (n, row) => n + row.length),
      'capture_us': us,
    });
  });

  test('chat transcript kept as a session grows', () {
    final entries = [
      for (var i = 0; i < 5000; i++) ...[
        userLine('u$i', 'Prompt $i ${'x' * 200}'),
        assistantLine('a$i', [text('Answer $i ${'y' * 800}')]),
      ],
    ];
    final parsed = TranscriptParser.parsePage(page(entries, offset: 1)).entries;
    final items = ChatItemBuilder.build(parsed);
    final chars = parsed.fold<int>(
      0,
      (n, e) =>
          n +
          e.blocks.whereType<TextBlock>().fold(0, (m, b) => m + b.text.length),
    );
    perfReport('memory.chat_transcript', {
      'entries': parsed.length,
      'items': items.length,
      'text_mb_retained': (chars * 2 / (1024 * 1024)).toStringAsFixed(1),
    });
  });
}
