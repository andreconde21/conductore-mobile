import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/chat_view/domain/chat_items.dart';
import 'package:conduit/features/voice/domain/speech_event.dart';
import 'package:conduit/features/voice/domain/voice_preferences.dart';
import 'package:conduit/features/voice/presentation/dictation_controller.dart';
import 'package:conduit/features/voice/presentation/read_aloud_controller.dart';
import 'package:conduit/features/voice/presentation/talk_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_speech_recognizer.dart';
import 'fake_tts.dart';

ChatUserMessage prompt(String id, String text) =>
    ChatUserMessage(id, text: text);

ChatAssistantText reply(String id, String text) =>
    ChatAssistantText(id, text: text);

const request = PendingPermissionRequest(
  id: 'p1',
  toolName: 'Bash',
  summary: 'npm test',
);

void main() {
  late FakeSpeechRecognizer mic;
  late FakeTts tts;
  late DictationController dictation;
  late ReadAloudController readAloud;
  late TalkController talk;
  late List<String> sent;
  late List<(String, PermissionVerdict)> decided;
  late List<int> answered;

  /// Feeds a poll to the reader and the loop, as the page does.
  void poll(
    List<ChatItem> items, [
    List<PendingPermissionRequest> pending = const [],
    String state = 'waiting_input',
  ]) {
    readAloud.observe(items, pending, state);
    talk.update(items, pending, state);
  }

  Future<void> settle(
    WidgetTester tester, [
    Duration by = Duration.zero,
  ]) async {
    await tester.pump(by);
    await tester.pump();
  }

  Future<void> setUpTalk(WidgetTester tester) async {
    mic = FakeSpeechRecognizer();
    tts = FakeTts();
    sent = [];
    decided = [];
    answered = [];
    dictation = DictationController(mic, language: () => 'en-US');
    readAloud = ReadAloudController(
      tts: tts,
      preferences: () => VoicePreferences.defaults,
    );
    talk = TalkController(
      dictation: dictation,
      readAloud: readAloud,
      send: (text) async => sent.add(text),
      decide: (r, v) async => decided.add((r.id, v)),
      answer: (n) async => answered.add(n),
      options: () => const DictationOptions(
        continuous: true,
        silenceTimeout: Duration(seconds: 2),
      ),
    );
    addTearDown(() {
      talk.dispose();
      readAloud.dispose();
      dictation.dispose();
    });
    // The page primes the reader with the thread on open.
    poll([prompt('u0', 'hi'), reply('a0', 'Hello.')]);
  }

  testWidgets('listen, pause, countdown, send, stay quiet, read the final '
      'answer, listen again', (tester) async {
    await setUpTalk(tester);
    talk.start();
    await settle(tester);
    expect(talk.phase, TalkPhase.listening);
    expect(mic.starts.single.continuous, isTrue);

    // Nothing said yet: silence does not end the turn.
    await settle(tester, const Duration(seconds: 5));
    expect(talk.phase, TalkPhase.listening);

    mic.emit(const SpeechReady());
    mic.emit(const SpeechPartial('run the'));
    await settle(tester);
    expect(talk.transcript, 'run the');
    mic.emit(const SpeechResult('run the tests'));
    await settle(tester, const Duration(seconds: 3));
    expect(talk.phase, TalkPhase.confirming);
    expect(talk.transcript, 'run the tests');
    expect(sent, isEmpty);
    await settle(tester, const Duration(seconds: 1));
    expect(talk.countdown.inMilliseconds, lessThan(2000));
    await settle(tester, const Duration(seconds: 2));
    expect(sent, ['run the tests']);
    expect(talk.phase, TalkPhase.waiting);

    // Claude works: nothing is spoken.
    final working = [
      prompt('u0', 'hi'),
      reply('a0', 'Hello.'),
      prompt('u1', 'run the tests'),
      reply('a1', 'Running them.'),
      ChatToolCall(
        't1',
        name: 'Bash',
        input: const {'command': 'npm test'},
        kind: ChatToolKind.bash,
      ),
    ];
    poll(working, const [], 'working');
    await settle(tester);
    expect(tts.spoken, isEmpty);
    expect(talk.phase, TalkPhase.waiting);

    // The turn ends: only the final answer is read, then it listens again.
    final startsBefore = mic.starts.length;
    poll([...working, reply('a2', 'All **12** tests pass.')]);
    await settle(tester);
    expect(talk.phase, TalkPhase.speaking);
    expect(tts.spoken, ['All 12 tests pass.']);
    expect(
      mic.starts,
      hasLength(startsBefore),
      reason: 'the mic waits for the voice',
    );
    tts.done();
    await settle(tester, const Duration(milliseconds: 500));
    expect(talk.phase, TalkPhase.listening);
    expect(mic.starts, hasLength(startsBefore + 1));
    expect(mic.starts.last.restart, isFalse);
    talk.stop();
  });

  testWidgets('an answer arriving just after the turn ended is heard out '
      'before the mic opens', (tester) async {
    await setUpTalk(tester);
    talk.start();
    await settle(tester);
    mic.say('run the tests');
    await settle(tester, const Duration(seconds: 5));
    expect(sent, ['run the tests']);
    final working = [
      prompt('u0', 'hi'),
      reply('a0', 'Hello.'),
      prompt('u1', 'run the tests'),
      ChatToolCall(
        't1',
        name: 'Bash',
        input: const {'command': 'npm test'},
        kind: ChatToolKind.bash,
      ),
    ];
    poll(working, const [], 'working');
    await settle(tester);

    // The agent reports the turn over one poll before its final text
    // reaches the transcript: nothing to read yet, so the loop schedules
    // the mic...
    final startsBefore = mic.starts.length;
    poll(working);
    await settle(tester, const Duration(milliseconds: 100));
    // ...and the answer lands before the mic opened.
    poll([...working, reply('a1', 'All green.')]);
    await settle(tester);
    expect(tts.spoken, ['All green.']);

    await settle(tester, const Duration(milliseconds: 500));
    expect(
      mic.starts,
      hasLength(startsBefore),
      reason: 'the mic must not open over the voice',
    );
    expect(tts.stops, 0);
    expect(readAloud.speaking, isTrue);

    tts.done();
    await settle(tester, const Duration(milliseconds: 500));
    expect(talk.phase, TalkPhase.listening);
    expect(mic.starts, hasLength(startsBefore + 1));
    talk.stop();
  });

  testWidgets('cancelling in the countdown keeps the text unsent', (
    tester,
  ) async {
    await setUpTalk(tester);
    talk.start();
    await settle(tester);
    mic.say('delete everything');
    await settle(tester, const Duration(seconds: 3));
    expect(talk.phase, TalkPhase.confirming);
    expect(talk.stop(), 'delete everything');
    await settle(tester, const Duration(seconds: 3));
    expect(sent, isEmpty);
    expect(talk.phase, TalkPhase.off);
    expect(readAloud.conversation, isFalse);
  });

  testWidgets('approvals are announced and answered by voice', (tester) async {
    await setUpTalk(tester);
    talk.start();
    await settle(tester);
    mic.say('clean the build');
    await settle(tester, const Duration(seconds: 5));
    expect(sent, ['clean the build']);

    final thread = [
      prompt('u0', 'hi'),
      reply('a0', 'Hello.'),
      prompt('u1', 'x'),
    ];
    poll(thread, const [request], 'needs_permission');
    await settle(tester);
    expect(
      tts.spoken.single,
      'Claude needs your approval to run npm test. '
      'Say allow, deny, or always.',
    );
    tts.done();
    await settle(tester, const Duration(milliseconds: 500));
    expect(talk.phase, TalkPhase.listening);
    expect(talk.target, isA<TalkApproval>());

    // Unclear: it asks again.
    mic.say('hmm maybe');
    await settle(tester, const Duration(seconds: 3));
    expect(tts.spoken.last, 'Say allow, deny, or always.');
    tts.done();
    await settle(tester, const Duration(milliseconds: 500));
    mic.say('yes allow it');
    await settle(tester, const Duration(seconds: 3));
    expect(decided, [('p1', PermissionVerdict.allow)]);
    expect(talk.phase, TalkPhase.waiting);
    talk.stop();
  });

  testWidgets('questions are answered by option number or name', (
    tester,
  ) async {
    await setUpTalk(tester);
    talk.start();
    await settle(tester);
    mic.say('set up the database');
    await settle(tester, const Duration(seconds: 5));
    poll([
      prompt('u0', 'hi'),
      reply('a0', 'Hello.'),
      prompt('u1', 'set up the database'),
      const ChatQuestion(
        'q1',
        questions: [
          ChatQuestionPrompt(
            question: 'Which database?',
            options: [
              ChatQuestionOption(label: 'Postgres'),
              ChatQuestionOption(label: 'SQLite'),
            ],
          ),
        ],
      ),
    ]);
    await settle(tester);
    expect(tts.spoken.single, contains('Options: 1, Postgres; 2, SQLite.'));
    tts.done();
    await settle(tester, const Duration(milliseconds: 500));
    expect(talk.target, isA<TalkQuestion>());
    mic.say('SQLite');
    await settle(tester, const Duration(seconds: 3));
    expect(answered, [2]);
    talk.stop();
  });

  testWidgets('an ended session ends the loop after the answer', (
    tester,
  ) async {
    await setUpTalk(tester);
    talk.start();
    await settle(tester);
    mic.say('wrap up');
    await settle(tester, const Duration(seconds: 5));
    poll(
      [
        prompt('u0', 'hi'),
        reply('a0', 'Hello.'),
        prompt('u1', 'wrap up'),
        reply('a1', 'Bye.'),
      ],
      const [],
      'ended',
    );
    await settle(tester);
    tts.done();
    await settle(tester, const Duration(milliseconds: 500));
    expect(tts.spoken, ['Bye.', 'That session ended.']);
    expect(talk.phase, TalkPhase.speaking);
    final starts = mic.starts.length;
    tts.done();
    await settle(tester, const Duration(milliseconds: 500));
    expect(talk.phase, TalkPhase.off);
    expect(mic.starts, hasLength(starts), reason: 'no listening to it');
    expect(readAloud.conversation, isFalse);
  });

  testWidgets('a session that ends while listening says so and stops', (
    tester,
  ) async {
    await setUpTalk(tester);
    talk.start();
    await settle(tester);
    expect(talk.phase, TalkPhase.listening);
    final thread = [prompt('u0', 'hi'), reply('a0', 'Hello.')];
    poll(thread, const [], 'ended');
    await settle(tester);
    expect(dictation.isActive, isFalse);
    expect(tts.spoken, ['That session ended.']);
    tts.done();
    await settle(tester, const Duration(milliseconds: 500));
    expect(talk.phase, TalkPhase.off);
    // Later polls of the dead session do nothing.
    poll(thread, const [], 'ended');
    await settle(tester, const Duration(seconds: 30));
    expect(tts.spoken, hasLength(1));
    expect(talk.phase, TalkPhase.off);
  });

  testWidgets('"more" reads the rest of a brief reply instead of sending', (
    tester,
  ) async {
    await setUpTalk(tester);
    talk.start();
    await settle(tester);
    mic.say('explain the plan');
    await settle(tester, const Duration(seconds: 5));
    expect(sent, ['explain the plan']);
    final working = [
      prompt('u0', 'hi'),
      reply('a0', 'Hello.'),
      prompt('u1', 'explain the plan'),
    ];
    poll(working, const [], 'working');
    await settle(tester);
    poll([...working, reply('a1', 'One. Two. Three. Four is the last part.')]);
    await settle(tester);
    expect(tts.spoken, ['One. Two. Three. More on screen.']);
    tts.done();
    await settle(tester, const Duration(milliseconds: 500));
    expect(talk.phase, TalkPhase.listening);

    mic.say('read more');
    await settle(tester, const Duration(seconds: 3));
    expect(tts.spoken.last, 'Four is the last part.');
    expect(talk.phase, TalkPhase.speaking);
    tts.done();
    await settle(tester, const Duration(milliseconds: 500));
    expect(talk.phase, TalkPhase.listening);
    expect(sent, ['explain the plan'], reason: '"more" is not a prompt');

    // Nothing more to read: "continue" goes to Claude.
    mic.say('continue');
    await settle(tester, const Duration(seconds: 5));
    expect(sent, ['explain the plan', 'continue']);
    talk.stop();
  });

  testWidgets('another mic taking the recognizer stops Talk without sending '
      'what it had heard', (tester) async {
    await setUpTalk(tester);
    final terminal = DictationController(mic, language: () => 'en-US');
    addTearDown(terminal.dispose);
    talk.start();
    await settle(tester);
    mic.emit(const SpeechReady());
    mic.emit(const SpeechPartial('delete the'));
    await settle(tester);
    expect(talk.transcript, 'delete the');

    final heard = <String>[];
    await terminal.start(
      DictationSink(
        onBegin: () {},
        onPartial: (_) {},
        onFinish: heard.add,
        onCancel: () {},
      ),
    );
    await settle(tester, const Duration(seconds: 5));
    expect(sent, isEmpty, reason: 'a cut-off phrase is not a prompt');
    expect(talk.phase, TalkPhase.off);
    expect(talk.message, TalkController.takenOver);
    expect(dictation.isActive, isFalse);
    expect(terminal.isActive, isTrue);
  });

  testWidgets('nothing heard yet: Talk stops instead of listening again '
      'beside the other mic', (tester) async {
    await setUpTalk(tester);
    final terminal = DictationController(mic, language: () => 'en-US');
    addTearDown(terminal.dispose);
    talk.start();
    await settle(tester);
    await terminal.start(
      DictationSink(
        onBegin: () {},
        onPartial: (_) {},
        onFinish: (_) {},
        onCancel: () {},
      ),
    );
    await settle(tester, const Duration(seconds: 5));
    expect(talk.phase, TalkPhase.off);
    expect(dictation.isActive, isFalse);
    expect(terminal.isActive, isTrue);
  });

  testWidgets('an approval answered elsewhere while listening: the mic '
      'closes and the loop waits for the turn, then reads it', (tester) async {
    await setUpTalk(tester);
    talk.start();
    await settle(tester);
    mic.say('clean the build');
    await settle(tester, const Duration(seconds: 5));
    final thread = [
      prompt('u0', 'hi'),
      reply('a0', 'Hello.'),
      prompt('u1', 'x'),
    ];
    poll(thread, const [request], 'needs_permission');
    await settle(tester);
    tts.done();
    await settle(tester, const Duration(milliseconds: 500));
    expect(talk.target, isA<TalkApproval>());
    expect(dictation.isActive, isTrue);

    // Allowed from the notification; the user had started to answer.
    mic.emit(const SpeechPartial('uh'));
    poll(thread, const [], 'working');
    await settle(tester);
    expect(talk.phase, TalkPhase.waiting);
    expect(dictation.isActive, isFalse);
    expect(decided, isEmpty);

    poll([...thread, reply('a1', 'Build cleaned.')]);
    await settle(tester);
    expect(tts.spoken.last, 'Build cleaned.');
    tts.done();
    await settle(tester, const Duration(milliseconds: 500));
    expect(talk.phase, TalkPhase.listening);
    expect(talk.target, isA<TalkPrompt>());
    talk.stop();
  });

  testWidgets('a turn that finishes while listening is read, then the loop '
      'listens again', (tester) async {
    await setUpTalk(tester);
    talk.start();
    await settle(tester);
    mic.say('run the tests');
    await settle(tester, const Duration(seconds: 5));
    expect(sent, ['run the tests']);
    // Claude does not visibly start in time: the loop listens again.
    await settle(tester, const Duration(seconds: 21));
    await settle(tester, const Duration(milliseconds: 500));
    expect(talk.phase, TalkPhase.listening);

    final working = [
      prompt('u0', 'hi'),
      reply('a0', 'Hello.'),
      prompt('u1', 'run the tests'),
    ];
    poll(working, const [], 'working');
    await settle(tester);
    expect(talk.phase, TalkPhase.listening);

    final startsBefore = mic.starts.length;
    poll([...working, reply('a1', 'All green.')]);
    await settle(tester);
    expect(tts.spoken, ['All green.']);
    expect(talk.phase, TalkPhase.speaking);
    expect(dictation.isActive, isFalse, reason: 'the mic must not hear it');
    tts.done();
    await settle(tester, const Duration(milliseconds: 500));
    expect(talk.phase, TalkPhase.listening);
    expect(mic.starts, hasLength(startsBefore + 1));
    talk.stop();
  });

  testWidgets('no microphone permission stops the loop', (tester) async {
    await setUpTalk(tester);
    mic.permission = false;
    talk.start();
    await settle(tester);
    expect(talk.phase, TalkPhase.off);
    expect(talk.message, contains('Microphone'));
  });
}
