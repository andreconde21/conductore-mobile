// Chat view under a long transcript: 2,000 items, polled every 2 s. Reports
// what one poll costs when nothing changed and when one message arrived:
// listener notifications, widget rebuilds, paints and the frame's time.

import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/chat_view/domain/chat_items.dart';
import 'package:conduit/features/chat_view/domain/chat_transcript.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_controller.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../features/chat_view/chat_fixtures.dart';
import 'perf_probe.dart';

/// One turn: a prompt, a reply with a command, its result, and a summary
/// (four chat items).
List<Map<String, Object?>> turn(int i) => [
  userLine(
    'u$i',
    'Prompt number $i: please fix the failing test in lib/a$i.dart',
  ),
  assistantLine('a$i', [
    text('Looking at **lib/a$i.dart** now.\n\n- first\n- second'),
    toolUse('t$i', 'Bash', {'command': 'flutter test test/a${i}_test.dart'}),
  ]),
  userLine('r$i', [toolResult('t$i', 'All tests passed! ($i)')]),
  assistantLine('s$i', [text('Fixed: the test passes now. Turn $i done.')]),
];

/// Answers the chat's polls: the whole transcript first, then nothing new
/// until [grow] queues more entries.
class _TranscriptRunner implements AgentCommandRunner {
  _TranscriptRunner(this.entries);

  final List<Map<String, Object?>> entries;
  final List<Map<String, Object?>> _queued = [];
  int _offset = 0;
  int runs = 0;

  void grow(List<Map<String, Object?>> more) => _queued.addAll(more);

  @override
  Future<AgentCommandResult> run(
    String command, {
    required Duration timeout,
  }) async {
    runs += 1;
    final String out;
    if (_offset == 0) {
      _offset = 100000;
      out = page(entries, offset: _offset);
    } else if (_queued.isNotEmpty) {
      _offset += 1000;
      out = page(List.of(_queued), offset: _offset);
      _queued.clear();
    } else {
      out = page(const [], offset: _offset);
    }
    return AgentCommandResult(stdout: out, stderr: '', exitCode: 0);
  }

  @override
  Future<void> close() async {}
}

void main() {
  const turns = 500;
  final entries = [for (var i = 0; i < turns; i++) ...turn(i)];

  test('ChatItemBuilder over a 2,000-item transcript', () {
    final parsed = TranscriptParser.parsePage(page(entries, offset: 1)).entries;
    final items = ChatItemBuilder.build(parsed);
    final us = bestMicros(() => ChatItemBuilder.build(parsed));
    perfReport('chat.items_build', {
      'entries': parsed.length,
      'items': items.length,
      'build_ms': (us / 1000).toStringAsFixed(2),
    });
    expect(items.length, greaterThanOrEqualTo(2000));
  });

  testWidgets('chat view: idle and growing polls over 2,000 items', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final runner = _TranscriptRunner(entries);
    final chat = ChatViewController(
      runner: runner,
      sessionId: 's-1',
      pollInterval: const Duration(seconds: 2),
    );
    var notifies = 0;
    chat.addListener(() => notifies += 1);
    await tester.pumpWidget(
      MaterialApp(
        home: ChatViewPage(controller: chat, onOpenTerminal: () {}),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(chat.items.length, greaterThanOrEqualTo(2000));

    final probe = FrameProbe()..install();
    try {
      // A minute of polls that bring nothing.
      notifies = 0;
      probe.reset();
      final idleWatch = Stopwatch()..start();
      final idleRuns = runner.runs;
      for (var s = 0; s < 60; s += 2) {
        await tester.pump(const Duration(seconds: 2));
      }
      final idleUs = idleWatch.elapsedMicroseconds;
      final idlePolls = runner.runs - idleRuns;
      final idle = (
        notifies: notifies,
        builds: probe.builds,
        paints: probe.paints,
        top: probe.top(),
      );

      // Ten polls that each bring one new turn (four items).
      notifies = 0;
      probe.reset();
      var growUs = 0;
      for (var i = 0; i < 10; i++) {
        runner.grow(turn(turns + i));
        final watch = Stopwatch()..start();
        await tester.pump(const Duration(seconds: 2));
        await tester.pump();
        growUs += watch.elapsedMicroseconds;
      }
      perfReport('chat.idle_minute', {
        'polls': idlePolls,
        'notifies': idle.notifies,
        'builds': idle.builds,
        'paints': idle.paints,
        'wall_ms': (idleUs / 1000).toStringAsFixed(1),
        'top': idle.top.replaceAll(' ', ','),
      });
      perfReport('chat.growing_poll', {
        'notifies_per_poll': (notifies / 10).toStringAsFixed(1),
        'builds_per_poll': (probe.builds / 10).toStringAsFixed(0),
        'paints_per_poll': (probe.paints / 10).toStringAsFixed(0),
        'frame_ms': (growUs / 10000).toStringAsFixed(1),
        'top': probe.top().replaceAll(' ', ','),
      });
      expect(chat.items.length, greaterThanOrEqualTo(2040));
    } finally {
      probe.uninstall();
    }
    // The page owns the controller and disposes it.
    await tester.pumpWidget(const SizedBox());
  });
}
