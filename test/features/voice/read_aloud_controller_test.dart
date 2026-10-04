import 'dart:async';

import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/chat_view/domain/chat_items.dart';
import 'package:conduit/features/voice/domain/speech_summary.dart';
import 'package:conduit/features/voice/domain/text_to_speech.dart';
import 'package:conduit/features/voice/domain/voice_preferences.dart';
import 'package:conduit/features/voice/presentation/read_aloud_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_tts.dart';

ChatAssistantText reply(String id, String text) =>
    ChatAssistantText(id, text: text);

ChatUserMessage prompt(String id) => ChatUserMessage(id, text: 'go');

ChatToolCall bash(String id) => ChatToolCall(
  id,
  name: 'Bash',
  input: const {'command': 'ls'},
  kind: ChatToolKind.bash,
);

const request = PendingPermissionRequest(
  id: 'p1',
  toolName: 'Bash',
  summary: 'npm test',
);

void main() {
  late FakeTts tts;
  late VoicePreferences prefs;
  late ReadAloudController controller;

  setUp(() {
    tts = FakeTts();
    prefs = VoicePreferences.defaults.copyWith(ttsRate: 1.3, ttsPitch: 0.8);
    controller = ReadAloudController(
      tts: tts,
      preferences: () => prefs,
      dictationLanguage: () => 'pt-PT',
      enabled: true,
    );
  });

  tearDown(() => controller.dispose());

  test('never re-reads the answer already on screen when opened', () async {
    final thread = [prompt('u1'), reply('a', 'Old answer.')];
    controller.observe(thread, const [], 'waiting_input');
    controller.observe(thread, const [], 'waiting_input');
    await pumpEventQueue();
    expect(tts.spoken, isEmpty);
  });

  test('reads only the final answer once the turn ends', () async {
    controller.observe([prompt('u1')], const [], 'working');
    final midTurn = [
      prompt('u1'),
      reply('a1', 'Let me look at the **tests**.'),
      bash('t1'),
      bash('t2'),
    ];
    controller.observe(midTurn, const [], 'working');
    await pumpEventQueue();
    expect(tts.spoken, isEmpty, reason: 'no chatter or tool output');

    final done = [
      ...midTurn,
      reply('a2', 'Fixed the `parser`.'),
      reply('a3', 'All tests pass.'),
    ];
    controller.observe(done, const [], 'working');
    await pumpEventQueue();
    expect(tts.spoken, isEmpty, reason: 'still working');

    controller.observe(done, const [], 'waiting_input');
    controller.observe(done, const [], 'waiting_input');
    await pumpEventQueue();
    expect(tts.spoken, ['Fixed the parser. All tests pass.']);
    expect(tts.languages, ['pt-PT']);
    expect(tts.rate, 1.3);
    expect(tts.pitch, 0.8);
  });

  test('brief (the default) reads the first sentences; more reads the '
      'rest', () async {
    controller.observe([prompt('u1')], const [], 'working');
    final long = List.filled(60, 'This sentence is filler.').join(' ');
    controller.observe([prompt('u1'), reply('a', long)], const [], 'ended');
    await pumpEventQueue();
    expect(
      tts.spoken.single,
      'This sentence is filler. This sentence is filler. '
      'This sentence is filler. More on screen.',
    );
    expect(controller.hasMore, isTrue);
    tts.done();
    await pumpEventQueue();
    expect(controller.more(), isTrue);
    await pumpEventQueue();
    expect(tts.spoken, hasLength(2));
    expect(tts.spoken.last, startsWith('This sentence is filler.'));
    expect(tts.spoken.last.length, lessThanOrEqualTo(240));
    expect(controller.hasMore, isFalse);
    expect(controller.more(), isFalse);
  });

  test('full reads the whole answer in sentence-sized utterances', () async {
    prefs = prefs.copyWith(readAloudLength: ReadAloudLength.full);
    controller.observe([prompt('u1')], const [], 'working');
    final long = List.filled(30, 'This sentence is filler.').join(' ');
    controller.observe([prompt('u1'), reply('a', long)], const [], 'ended');
    await pumpEventQueue();
    for (var i = 0; i < 10 && controller.busy; i++) {
      tts.done();
      await pumpEventQueue();
    }
    expect(tts.spoken.join(' '), long);
    expect(tts.spoken.every((u) => u.length <= 240), isTrue);
    expect(controller.hasMore, isFalse);
  });

  test('announces approvals once and open questions', () async {
    controller.observe([prompt('u1')], const [], 'working');
    controller.observe([prompt('u1')], const [request], 'needs_permission');
    controller.observe([prompt('u1')], const [request], 'needs_permission');
    await pumpEventQueue();
    expect(tts.spoken, ['The agent needs your approval to run npm test.']);
    tts.done();

    controller.observe(
      [
        prompt('u1'),
        const ChatQuestion(
          'q1',
          questions: [ChatQuestionPrompt(question: 'Ship it?')],
        ),
      ],
      const [],
      'waiting_input',
    );
    await pumpEventQueue();
    expect(tts.spoken.last, 'The agent is asking: Ship it?');
  });

  test('queues utterances and plays them one at a time', () async {
    controller.observe([prompt('u1')], const [], 'working');
    controller.observe(
      [prompt('u1'), reply('a', 'Answer.')],
      const [request],
      'needs_permission',
    );
    controller.observe(
      [prompt('u1'), reply('a', 'Answer.')],
      const [],
      'waiting_input',
    );
    await pumpEventQueue();
    expect(tts.spoken, ['The agent needs your approval to run npm test.']);
    expect(controller.busy, isTrue);
    tts.done();
    await pumpEventQueue();
    expect(tts.spoken.last, 'Answer.');
    tts.done();
    await pumpEventQueue();
    expect(controller.busy, isFalse);
  });

  test('dictation and stop drop speech; a turn that ended meanwhile is not '
      'read later', () async {
    controller.observe([prompt('u1')], const [], 'working');
    controller.observe([prompt('u1')], const [request], 'needs_permission');
    await pumpEventQueue();
    expect(tts.spoken, hasLength(1));

    controller.suppressed = true;
    expect(tts.stops, 1);
    expect(controller.busy, isFalse);
    final done = [prompt('u1'), reply('a', 'Missed.')];
    controller.observe(done, const [], 'waiting_input');
    controller.suppressed = false;
    controller.observe(done, const [], 'waiting_input');
    tts.done(); // A late "done" for the stopped utterance changes nothing.
    await pumpEventQueue();
    expect(tts.spoken, hasLength(1));
  });

  test('turning the toggle off stops at once', () async {
    controller.observe([prompt('u1')], const [], 'working');
    controller.observe(
      [prompt('u1'), reply('a', 'Speaking.')],
      const [],
      'waiting_input',
    );
    await pumpEventQueue();
    controller.setEnabled(false);
    expect(tts.stops, 1);
    controller.observe(
      [prompt('u1'), reply('a', 'Speaking.'), prompt('u2'), reply('b', 'No.')],
      const [],
      'waiting_input',
    );
    controller.setEnabled(true);
    await pumpEventQueue();
    expect(tts.spoken, ['Speaking.']);
  });

  test(
    'the Talk loop reads while the toggle is off, with answer hints',
    () async {
      controller
        ..setEnabled(false)
        ..conversation = true;
      controller.observe([prompt('u1')], const [], 'working');
      controller.observe([prompt('u1')], const [request], 'needs_permission');
      await pumpEventQueue();
      expect(
        tts.spoken.single,
        'The agent needs your approval to run npm test. '
        'Say allow, deny, or always.',
      );
    },
  );

  testWidgets('a stalled engine does not block the queue', (tester) async {
    final c = ReadAloudController(
      tts: tts,
      preferences: () => prefs,
      enabled: true,
    );
    c.observe([prompt('u1')], const [], 'working');
    c.observe([prompt('u1')], const [request], 'needs_permission');
    c.observe([prompt('u1'), reply('a', 'Second.')], const [], 'waiting_input');
    await tester.pump();
    expect(tts.spoken, hasLength(1));
    await tester.pump(const Duration(seconds: 30));
    expect(tts.spoken.last, 'Second.');
    c.dispose();
  });

  test('a new message arriving mid-speech queues behind it', () async {
    controller.observe([prompt('u1')], const [], 'working');
    final first = [prompt('u1'), reply('a', 'First answer.')];
    controller.observe(first, const [], 'waiting_input');
    await pumpEventQueue();
    expect(tts.spoken, ['First answer.']);
    tts.emit(TtsStarted(tts.ids.last));

    // More polls while it speaks: the agent flips back to working, a new
    // reply and an approval arrive.
    final second = [...first, prompt('u2'), reply('b', 'Second answer.')];
    controller.observe(second, const [], 'working');
    controller.observe(second, const [], 'waiting_input');
    controller.observe(second, const [request], 'needs_permission');
    await pumpEventQueue();
    expect(tts.stops, 0, reason: 'nothing is cut off');
    expect(tts.spoken, ['First answer.'], reason: 'nothing is flushed');
    expect(controller.speaking, isTrue);
    expect(controller.queued, 2);

    tts.done();
    await pumpEventQueue();
    expect(tts.spoken.last, 'Second answer.');
    tts.done();
    await pumpEventQueue();
    expect(tts.spoken.last, 'The agent needs your approval to run npm test.');
  });

  test('a short audio interruption (a notification, a ringtone) pauses and '
      'resumes from the sentence it cut, keeping the queue', () async {
    controller.observe([prompt('u1')], const [], 'working');
    controller.observe(
      [prompt('u1'), reply('a', 'One is done. Two is next. Three last.')],
      const [request],
      'needs_permission',
    );
    controller.observe(
      [prompt('u1'), reply('a', 'One is done. Two is next. Three last.')],
      const [],
      'waiting_input',
    );
    await pumpEventQueue();
    expect(tts.spoken, ['The agent needs your approval to run npm test.']);
    tts.done();
    await pumpEventQueue();
    expect(tts.spoken.last, 'One is done. Two is next. Three last.');
    final id = tts.ids.last;
    tts.emit(TtsStarted(id));

    // Cut in the middle of "Two is next".
    tts.emit(TtsPaused(id, offset: 17));
    tts.emit(TtsStopped(id)); // The engine reports the cut too.
    await pumpEventQueue();
    expect(controller.busy, isTrue, reason: 'the reply is kept');
    expect(controller.speaking, isFalse);
    expect(tts.spoken, hasLength(2), reason: 'waits for the audio back');
    expect(tts.stops, 0);

    tts.emit(const TtsResumed());
    await pumpEventQueue();
    expect(tts.spoken.last, 'Two is next. Three last.');
    tts.done();
    await pumpEventQueue();
    expect(controller.busy, isFalse);
  });

  test('a call or another app taking the audio for good stops', () async {
    controller.observe([prompt('u1')], const [], 'working');
    controller.observe([prompt('u1')], const [request], 'needs_permission');
    controller.observe(
      [prompt('u1'), reply('a', 'Answer.')],
      const [],
      'waiting_input',
    );
    await pumpEventQueue();
    tts.emit(const TtsInterrupted());
    await pumpEventQueue();
    expect(controller.busy, isFalse);
    expect(tts.spoken, hasLength(1));
  });

  testWidgets('audio that never comes back is given up after a while', (
    tester,
  ) async {
    final c = ReadAloudController(
      tts: tts,
      preferences: () => prefs,
      enabled: true,
    );
    c.observe([prompt('u1')], const [], 'working');
    c.observe([prompt('u1'), reply('a', 'Answer.')], const [], 'ended');
    await tester.pump();
    tts.emit(TtsPaused(tts.ids.last));
    await tester.pump(const Duration(minutes: 1));
    expect(c.busy, isTrue);
    await tester.pump(const Duration(minutes: 5));
    expect(c.busy, isFalse);
    expect(tts.spoken, hasLength(1));
    c.dispose();
  });

  testWidgets('the watchdog does not cut a long reply the engine started '
      'late', (tester) async {
    final c = ReadAloudController(
      tts: tts,
      preferences: () => prefs,
      enabled: true,
    );
    prefs = prefs.copyWith(readAloudLength: ReadAloudLength.full);
    final long = List.filled(9, 'This sentence is filler.').join(' ');
    c.observe([prompt('u1')], const [], 'working');
    c.observe([prompt('u1')], const [request], 'needs_permission');
    await tester.pump();
    tts.done();
    await tester.pump();
    expect(tts.spoken, hasLength(1));
    c.observe([prompt('u1'), reply('a', long)], const [], 'waiting_input');
    c.observe(
      [prompt('u1'), reply('a', long)],
      const [
        PendingPermissionRequest(id: 'p2', toolName: 'Bash', summary: 'ls'),
      ],
      'needs_permission',
    );
    await tester.pump();
    expect(tts.spoken, hasLength(2));
    // A slow engine (first use, a large voice) starts nine seconds late
    // and speaks slowly.
    await tester.pump(const Duration(seconds: 9));
    tts.emit(TtsStarted(tts.ids.last));
    await tester.pump(const Duration(seconds: 50));
    expect(tts.spoken, hasLength(2), reason: 'still speaking: never cut');
    tts.done();
    await tester.pump();
    expect(tts.spoken, hasLength(3));
    c.dispose();
  });

  group('Claude summary', () {
    late List<(String, Future<void>)> asked;
    late Completer<SpeechSummaryResult> answer;
    late List<String> notes;
    late ReadAloudController summarizing;
    var cancelled = 0;

    setUp(() {
      prefs = prefs.copyWith(readAloudLength: ReadAloudLength.summary);
      asked = [];
      notes = [];
      cancelled = 0;
      answer = Completer();
      summarizing = ReadAloudController(
        tts: tts,
        preferences: () => prefs,
        enabled: true,
        summarize: (text, cancel) {
          asked.add((text, cancel));
          unawaited(cancel.then((_) => cancelled += 1));
          return answer.future;
        },
        onNotice: notes.add,
      );
      summarizing.observe([prompt('u1')], const [], 'working');
    });

    tearDown(() => summarizing.dispose());

    final long = List.filled(8, 'This sentence is filler.').join(' ');
    final thread = [prompt('u1'), reply('a', long)];

    test('speaks nothing while fetching, then the summary; more reads the '
        'whole answer', () async {
      summarizing.observe(thread, const [], 'waiting_input');
      await pumpEventQueue();
      expect(asked.single.$1, long);
      expect(summarizing.summarizing, isTrue);
      expect(summarizing.busy, isTrue, reason: 'Talk waits for it');
      expect(tts.spoken, isEmpty);

      answer.complete(const SpeechSummary('Fillers, eight of them.'));
      await pumpEventQueue();
      expect(summarizing.summarizing, isFalse);
      expect(tts.spoken, ['Fillers, eight of them.']);
      expect(notes, isEmpty);
      tts.done();
      await pumpEventQueue();
      expect(summarizing.more(), isTrue);
      await pumpEventQueue();
      expect(tts.spoken.last, startsWith('This sentence is filler.'));
    });

    test(
      'a failure reads the brief version with a note, once per reason',
      () async {
        answer.complete(
          const SpeechSummaryFailed(SpeechSummaryFailed.outdated),
        );
        summarizing.observe(thread, const [], 'waiting_input');
        await pumpEventQueue();
        expect(tts.spoken.single, endsWith('More on screen.'));
        expect(notes.single, contains('0.7.0'));

        tts.done();
        final next = [...thread, prompt('u2'), reply('b', long)];
        summarizing.observe(next, const [], 'working');
        summarizing.observe(next, const [], 'waiting_input');
        await pumpEventQueue();
        expect(tts.spoken, hasLength(2));
        expect(notes, hasLength(1), reason: 'the note shows once');
      },
    );

    test('a throwing summarizer falls back too', () async {
      answer.completeError(StateError('runner closed'));
      summarizing.observe(thread, const [], 'waiting_input');
      await pumpEventQueue();
      expect(tts.spoken.single, endsWith('More on screen.'));
      expect(notes.single, contains('summary failed'));
    });

    test('the user acting cancels it and nothing is read', () async {
      summarizing.observe(thread, const [], 'waiting_input');
      await pumpEventQueue();
      summarizing.stop();
      await pumpEventQueue();
      expect(cancelled, 1);
      expect(summarizing.busy, isFalse);
      answer.complete(const SpeechSummary('Too late.'));
      await pumpEventQueue();
      expect(tts.spoken, isEmpty);
    });

    test('the session ending mid-summary cancels it', () async {
      summarizing.observe(thread, const [], 'waiting_input');
      await pumpEventQueue();
      summarizing.observe(thread, const [], 'ended');
      await pumpEventQueue();
      expect(cancelled, 1);
      answer.complete(const SpeechSummary('Too late.'));
      await pumpEventQueue();
      expect(tts.spoken, isEmpty);
      expect(summarizing.busy, isFalse);
    });

    test('without a summarizer it reads the brief version', () async {
      final plain = ReadAloudController(
        tts: tts,
        preferences: () => prefs,
        enabled: true,
        onNotice: notes.add,
      );
      addTearDown(plain.dispose);
      plain.observe([prompt('u1')], const [], 'working');
      plain.observe(thread, const [], 'waiting_input');
      await pumpEventQueue();
      expect(tts.spoken.single, endsWith('More on screen.'));
      expect(notes.single, contains('companion'));
    });
  });

  group('speech belongs to its chat', () {
    test('switching chats lets the utterance playing finish and drops the '
        'rest of the old chat', () async {
      final other = ReadAloudController(
        tts: tts,
        preferences: () => prefs,
        enabled: true,
      );
      addTearDown(other.dispose);
      controller.claim();
      other.observe([prompt('x1')], const [], 'working');
      controller.observe([prompt('u1')], const [], 'working');
      controller.observe([prompt('u1')], const [request], 'needs_permission');
      controller.observe(
        [prompt('u1'), reply('a', 'Old chat answer.')],
        const [],
        'waiting_input',
      );
      await pumpEventQueue();
      expect(tts.spoken, ['The agent needs your approval to run npm test.']);
      expect(controller.queued, 1);

      other.claim();
      expect(tts.stops, 0, reason: 'the sentence playing finishes');
      expect(controller.current, isFalse);
      expect(controller.busy, isFalse);
      other.observe(
        [prompt('x1'), reply('b', 'New chat answer.')],
        const [],
        'waiting_input',
      );
      await pumpEventQueue();
      expect(tts.spoken.last, 'New chat answer.');
      // The old chat keeps quiet: its news is not read on top.
      controller.observe(
        [prompt('u1'), reply('a', 'Old chat answer.'), reply('c', 'More.')],
        const [],
        'waiting_input',
      );
      tts.emit(TtsDone(tts.ids.first));
      await pumpEventQueue();
      expect(tts.spoken, [
        'The agent needs your approval to run npm test.',
        'New chat answer.',
      ]);
      // Stopping the quiet chat does not cut the new one.
      controller.stop();
      expect(tts.stops, 0);

      // Back to the old chat: it reads new items again.
      controller.claim();
      expect(other.current, isFalse);
      controller.observe(
        [prompt('u1'), reply('c', 'More.'), prompt('u2'), reply('d', 'Back.')],
        const [],
        'waiting_input',
      );
      await pumpEventQueue();
      expect(tts.spoken.last, 'Back.');
    });

    test('the session ending mid-reply finishes the utterance and drops the '
        'rest', () async {
      prefs = prefs.copyWith(readAloudLength: ReadAloudLength.full);
      controller.observe([prompt('u1')], const [], 'working');
      final long = List.filled(30, 'This sentence is filler.').join(' ');
      final thread = [prompt('u1'), reply('a', long)];
      controller.observe(thread, const [], 'waiting_input');
      await pumpEventQueue();
      expect(tts.spoken, hasLength(1));
      expect(controller.queued, greaterThan(0));

      controller.observe(thread, const [], 'ended');
      expect(tts.stops, 0, reason: 'not cut mid-sentence');
      expect(controller.busy, isFalse);
      tts.done();
      await pumpEventQueue();
      expect(tts.spoken, hasLength(1));
    });

    test('a reconnect that reloads the thread does not re-read', () async {
      controller.observe([prompt('u1')], const [], 'working');
      final thread = [prompt('u1'), reply('a', 'Heard once.')];
      controller.observe(thread, const [], 'waiting_input');
      await pumpEventQueue();
      tts.done();
      // The connection drops and the whole window comes back.
      controller.observe(const []);
      controller.observe([prompt('u0'), ...thread], const [], 'working');
      controller.observe([prompt('u0'), ...thread], const [], 'waiting_input');
      await pumpEventQueue();
      expect(tts.spoken, ['Heard once.']);
    });
  });
}
