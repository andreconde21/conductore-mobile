import 'dart:async';

import 'package:conduit/core/app_failure.dart';
import 'package:conduit/core/theme/theme_controller.dart';
import 'package:conduit/core/theme/theme_preferences_repository.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_controller.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_page.dart';
import 'package:conduit/features/voice/domain/speech_event.dart';
import 'package:conduit/features/voice/domain/voice_preferences.dart';
import 'package:conduit/features/voice/presentation/dictation_controller.dart';
import 'package:conduit/features/voice/presentation/voice_settings_scope.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';
import '../voice/fake_speech_recognizer.dart';
import '../voice/fake_tts.dart';
import 'chat_fixtures.dart';

/// Scripted polls, plus `summarize` answered by [onSummarize].
class SummarizingRunner extends ScriptedAgentCommandRunner
    implements StdinAgentCommandRunner {
  SummarizingRunner(super.script, this.onSummarize);

  final Future<AgentCommandResult> Function(String stdin, Future<void>? cancel)
  onSummarize;
  final List<String> summarized = [];

  @override
  Future<AgentCommandResult> runWithStdin(
    String command, {
    required String stdin,
    required Duration timeout,
    Future<void>? cancel,
  }) {
    expect(command, contains('summarize --max-words 45'));
    summarized.add(stdin);
    return onSummarize(stdin, cancel);
  }
}

AgentCommandResult ok(String stdout) =>
    AgentCommandResult(stdout: stdout, stderr: '', exitCode: 0);

/// Opens or closes a popup menu without waiting for the working dots.
Future<void> settleMenu(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  late FakeTts tts;
  late ThemeController settings;

  setUp(() async {
    tts = FakeTts();
    settings = ThemeController(
      ThemePreferencesRepository(InMemorySecureStorage()),
    );
    await settings.load();
  });

  Future<ChatViewController> pumpPage(
    WidgetTester tester,
    List<Object> script, {
    DictationController? dictation,
    ScriptedAgentCommandRunner? runner,
  }) async {
    final controller = ChatViewController(
      runner: runner ?? ScriptedAgentCommandRunner(script),
      sessionId: 's-1',
      pollInterval: const Duration(days: 1),
    );
    await tester.pumpWidget(
      VoiceSettingsScope(
        settings: settings,
        child: MaterialApp(
          home: ChatViewPage(
            controller: controller,
            onOpenTerminal: () {},
            textToSpeech: tts,
            dictation: dictation,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    addTearDown(() => tester.pumpWidget(const SizedBox()));
    return controller;
  }

  final history = [
    userLine('u1', 'hello'),
    assistantLine('a1', [text('An old answer.')]),
  ];

  testWidgets('the speaker toggle reads only new replies and is remembered '
      'per session', (tester) async {
    final chat = await pumpPage(tester, [
      ok(page(history)),
      ok(
        page([
          assistantLine('a2', [
            toolUse('t1', 'Bash', {'command': 'ls'}),
            toolUse('t2', 'Bash', {'command': 'pwd'}),
            text('All **done**, see `todos.ts`.'),
          ]),
        ], offset: 200),
      ),
    ]);
    final toggle = find.byKey(const ValueKey('chat-read-aloud'));
    expect(toggle, findsOneWidget);
    expect(find.byTooltip('Read replies aloud'), findsOneWidget);

    await tester.tap(toggle);
    await tester.pump();
    expect(find.byTooltip('Stop reading replies aloud'), findsOneWidget);
    expect(settings.voice.readAloudFor('s-1'), isTrue);
    expect(settings.voice.readAloudFor('other'), isFalse);
    expect(tts.spoken, isEmpty, reason: 'history is never read');

    await chat.refresh();
    await tester.pump();
    // Only the turn's final answer; the commands are never read.
    expect(tts.spoken, ['All done, see todos.ts.']);

    await tester.tap(toggle);
    await tester.pump();
    expect(tts.stops, 1, reason: 'turning it off stops at once');
    expect(settings.voice.readAloudFor('s-1'), isFalse);
  });

  testWidgets('the default setting turns it on and sending stops speech', (
    tester,
  ) async {
    await settings.setVoice(settings.voice.copyWith(readAloudByDefault: true));
    final chat = await pumpPage(tester, [
      ok(page(history)),
      ok(
        page([
          assistantLine('a2', [text('First reply.'), text('Second reply.')]),
        ], offset: 200),
      ),
      ok('{"ok":true}'),
      ok(page([], offset: 200)),
    ]);
    expect(find.byTooltip('Stop reading replies aloud'), findsOneWidget);

    await chat.refresh();
    await tester.pump();
    expect(tts.spoken, ['First reply. Second reply.']);

    await tester.enterText(
      find.byKey(const ValueKey('chat-composer-field')),
      'go on',
    );
    await tester.tap(find.byTooltip('Send'));
    await tester.pump();
    expect(tts.stops, 1);
    tts.done();
    await tester.pump();
    expect(tts.spoken, ['First reply. Second reply.']);
  });

  testWidgets('announces approvals', (tester) async {
    await settings.setVoice(settings.voice.copyWith(readAloudByDefault: true));
    final chat = await pumpPage(tester, [
      ok(page(history)),
      ok(
        page(
          [],
          offset: 200,
          state: 'needs_permission',
          pending: [
            {'id': 'req-1', 'toolName': 'Bash', 'summary': 'npm test'},
          ],
        ),
      ),
    ]);
    await chat.refresh();
    await tester.pump();
    expect(tts.spoken, ['Claude needs your approval to run npm test.']);
  });

  testWidgets('screen off keeps reading; leaving the app stops', (
    tester,
  ) async {
    await settings.setVoice(settings.voice.copyWith(readAloudByDefault: true));
    final chat = await pumpPage(tester, [
      ok(page(history)),
      ok(
        page([
          assistantLine('a2', [text('Hi.')]),
        ], offset: 200),
      ),
    ]);
    await chat.refresh();
    await tester.pump();
    expect(tts.spoken, ['Hi.']);

    tts.interactive = false;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(tts.stops, 0);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    tts.interactive = true;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    expect(tts.stops, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
  });

  testWidgets('the screen waking (a notification, unlocking) does not cut '
      'the voice', (tester) async {
    await settings.setVoice(settings.voice.copyWith(readAloudByDefault: true));
    final chat = await pumpPage(tester, [
      ok(page(history)),
      ok(
        page([
          assistantLine('a2', [text('A long answer.')]),
        ], offset: 200),
      ),
      ok(page([], offset: 200)),
    ]);
    await chat.refresh();
    await tester.pump();
    expect(tts.spoken, ['A long answer.']);

    // Screen off with the chat on top: it keeps reading.
    tts.interactive = false;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();

    // The agent-attention notification for the new message wakes the
    // screen and the activity starts again: Flutter passes through
    // `hidden` on the way up, with the screen already on.
    tts.interactive = true;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(tts.stops, 0, reason: 'coming back is not leaving');
    expect(find.byTooltip('Stop reading replies aloud'), findsOneWidget);
  });

  testWidgets('Talk: speak, auto-send, stay quiet, hear the answer, touch '
      'to stop', (tester) async {
    await settings.setVoice(settings.voice.copyWith(talkSendSilenceSeconds: 2));
    final mic = FakeSpeechRecognizer();
    final dictation = DictationController(mic, language: () => 'en-US');
    addTearDown(dictation.dispose);
    final runner = ScriptedAgentCommandRunner([
      ok(page(history)),
      ok('{"ok":true}'), // send
      ok(
        page([userLine('u2', 'run the tests')], offset: 200, state: 'working'),
      ),
      ok(
        page([
          assistantLine('a2', [text('All green.')]),
        ], offset: 300),
      ),
    ]);
    final chat = await pumpPage(
      tester,
      const [],
      dictation: dictation,
      runner: runner,
    );

    await tester.tap(find.byKey(const ValueKey('chat-talk')));
    await tester.pump();
    expect(find.byKey(const ValueKey('talk-panel')), findsOneWidget);
    expect(find.text('Listening…'), findsOneWidget);

    mic.say('run the tests');
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    expect(find.byKey(const ValueKey('talk-countdown')), findsOneWidget);
    expect(find.text('run the tests'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    expect(runner.commands.any((c) => c.contains('send s-1')), isTrue);
    await tester.pump();
    expect(find.text('Claude is working…'), findsOneWidget);

    // Sending polled at once: Claude works, nothing is read.
    expect(tts.spoken, isEmpty);
    await chat.refresh(); // Turn over: the final answer is read.
    await tester.pump();
    expect(tts.spoken, ['All green.']);
    tts.done();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Listening…'), findsOneWidget);

    // Speaking, then touching the thread: the loop ends and what was
    // said goes to the composer.
    mic.emit(const SpeechPartial('and deploy'));
    await tester.pump();
    await tester.tapAt(const Offset(200, 200));
    await tester.pump();
    expect(find.byKey(const ValueKey('talk-panel')), findsNothing);
    final field = find.byKey(const ValueKey('chat-composer-field'));
    expect(tester.widget<TextField>(field).controller!.text, 'and deploy');
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('Talk listening still hears an approval: the reader is not '
      'muted by Talk\'s own mic', (tester) async {
    final mic = FakeSpeechRecognizer();
    final dictation = DictationController(mic, language: () => 'en-US');
    addTearDown(dictation.dispose);
    final chat = await pumpPage(tester, [
      ok(page(history)),
      ok(
        page(
          [],
          offset: 200,
          state: 'needs_permission',
          pending: [
            {'id': 'req-1', 'toolName': 'Bash', 'summary': 'npm test'},
          ],
        ),
      ),
    ], dictation: dictation);

    await tester.tap(find.byKey(const ValueKey('chat-talk')));
    await tester.pump();
    expect(find.text('Listening…'), findsOneWidget);
    expect(dictation.isActive, isTrue);

    await chat.refresh();
    await tester.pump();
    expect(tts.spoken, [
      'Claude needs your approval to run npm test. '
          'Say allow, deny, or always.',
    ]);
    expect(dictation.isActive, isFalse, reason: 'the mic closes to hear it');
    tts.done();
    await tester.pump(const Duration(milliseconds: 500));
    expect(dictation.isActive, isTrue);
    expect(find.text('Say allow, deny, or always.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('chat-talk-toggle')));
    await tester.pump(const Duration(seconds: 5));
  });

  group('header toggles', () {
    IconButton readAloudButton(WidgetTester tester) => tester
        .widget<IconButton>(find.byKey(const ValueKey('chat-read-aloud')));

    testWidgets('read aloud is always in the header on a phone, filled '
        'while on, and says what it did', (tester) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await pumpPage(tester, [ok(page(history))]);

      expect(find.byKey(const ValueKey('chat-read-aloud')), findsOneWidget);
      expect(tester.takeException(), isNull, reason: 'no header overflow');
      expect(find.byTooltip('Terminal'), findsOneWidget);
      expect(readAloudButton(tester).isSelected, isFalse);

      await tester.tap(find.byKey(const ValueKey('chat-read-aloud')));
      await tester.pump();
      expect(find.text('Reading replies aloud'), findsOneWidget);
      expect(readAloudButton(tester).isSelected, isTrue);
      expect(find.byTooltip('Stop reading replies aloud'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('chat-read-aloud')));
      await tester.pump();
      expect(find.text('Stopped reading aloud'), findsOneWidget);
      expect(readAloudButton(tester).isSelected, isFalse);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('without a speech engine it shows muted and explains', (
      tester,
    ) async {
      tts.available = false;
      await pumpPage(tester, [ok(page(history))]);
      await tester.pump();

      expect(find.byTooltip('Read aloud unavailable'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('chat-read-aloud')));
      await tester.pump();
      expect(find.textContaining('text-to-speech engine'), findsOneWidget);
      expect(settings.voice.readAloudFor('s-1'), isFalse);

      // Installed meanwhile: a tap looks again and finds it.
      tts.available = true;
      await tester.tap(find.byKey(const ValueKey('chat-read-aloud')));
      await tester.pump(const Duration(seconds: 5));
      expect(find.byTooltip('Read replies aloud'), findsOneWidget);
    });

    testWidgets('Talk mode shows as on in the header and ends from there', (
      tester,
    ) async {
      final mic = FakeSpeechRecognizer();
      final dictation = DictationController(mic, language: () => 'en-US');
      addTearDown(dictation.dispose);
      await pumpPage(tester, [ok(page(history))], dictation: dictation);

      final toggle = find.byKey(const ValueKey('chat-talk-toggle'));
      expect(toggle, findsNothing);
      await tester.tap(find.byKey(const ValueKey('chat-talk')));
      await tester.pump();
      expect(toggle, findsOneWidget);
      expect(find.byTooltip('End Talk mode'), findsOneWidget);
      expect(find.byKey(const ValueKey('talk-panel')), findsOneWidget);

      mic.emit(const SpeechPartial('and deploy'));
      await tester.pump();
      await tester.tap(toggle);
      await tester.pump();
      expect(toggle, findsNothing);
      expect(find.byKey(const ValueKey('talk-panel')), findsNothing);
      expect(dictation.isActive, isFalse);
      final field = find.byKey(const ValueKey('chat-composer-field'));
      expect(tester.widget<TextField>(field).controller!.text, 'and deploy');
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('read-aloud length', () {
    final longAnswer = [
      assistantLine('a2', [
        text(
          'First point. Second point. Third point. A fourth point with '
          'the details.',
        ),
      ]),
    ];

    testWidgets('Claude summary: quiet "Summarizing…", then the summary', (
      tester,
    ) async {
      await settings.setVoice(
        settings.voice.copyWith(
          readAloudByDefault: true,
          readAloudLength: ReadAloudLength.summary,
        ),
      );
      final reply = Completer<AgentCommandResult>();
      final runner = SummarizingRunner([
        ok(page(history)),
        ok(page(longAnswer, offset: 200)),
      ], (_, _) => reply.future);
      final chat = await pumpPage(tester, const [], runner: runner);
      await chat.refresh();
      await tester.pump();
      expect(
        runner.summarized.single,
        'First point. Second point. Third point. A fourth point with the '
        'details.',
      );
      expect(tts.spoken, isEmpty);
      expect(find.byTooltip('Summarizing…'), findsOneWidget);

      reply.complete(
        ok('{"schema":1,"summary":"Four points, mostly details.","ms":900}'),
      );
      await tester.pump();
      await tester.pump();
      expect(tts.spoken, ['Four points, mostly details.']);
      expect(find.byTooltip('Summarizing…'), findsNothing);
    });

    testWidgets('an older companion falls back to brief with a note', (
      tester,
    ) async {
      await settings.setVoice(
        settings.voice.copyWith(
          readAloudByDefault: true,
          readAloudLength: ReadAloudLength.summary,
        ),
      );
      final runner = SummarizingRunner(
        [ok(page(history)), ok(page(longAnswer, offset: 200))],
        (_, _) async => const AgentCommandResult(
          stdout: '',
          stderr: 'conductore-hostd: unknown command "summarize"',
          exitCode: 2,
        ),
      );
      final chat = await pumpPage(tester, const [], runner: runner);
      await chat.refresh();
      await tester.pump();
      await tester.pump();
      expect(tts.spoken, [
        'First point. Second point. Third point. More on screen.',
      ]);
      expect(find.textContaining('0.7.0 or later'), findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
    });

    testWidgets('sending cancels a summary on its way', (tester) async {
      await settings.setVoice(
        settings.voice.copyWith(
          readAloudByDefault: true,
          readAloudLength: ReadAloudLength.summary,
        ),
      );
      Future<void>? cancelled;
      final reply = Completer<AgentCommandResult>();
      final runner = SummarizingRunner(
        [
          ok(page(history)),
          ok(page(longAnswer, offset: 200)),
          ok('{"ok":true}'),
          ok(page([], offset: 200)),
        ],
        (_, cancel) {
          cancelled = cancel;
          return reply.future;
        },
      );
      final chat = await pumpPage(tester, const [], runner: runner);
      await chat.refresh();
      await tester.pump();
      var cancelledNow = false;
      unawaited(cancelled!.then((_) => cancelledNow = true));

      await tester.enterText(
        find.byKey(const ValueKey('chat-composer-field')),
        'next',
      );
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      expect(cancelledNow, isTrue);
      reply.complete(ok('{"schema":1,"summary":"Too late."}'));
      await tester.pump();
      expect(tts.spoken, isEmpty);
    });

    testWidgets('the header menu switches the length and Tool activity', (
      tester,
    ) async {
      final chat = await pumpPage(tester, [
        ok(page(history)),
        ok(
          page(
            [
              assistantLine('a2', [
                toolUse('t1', 'Bash', {'command': 'make'}),
                toolUse('t2', 'Bash', {'command': 'make test'}),
              ]),
            ],
            offset: 200,
            state: 'working',
          ),
        ),
      ]);
      await chat.refresh();
      await tester.pump();
      expect(find.text('Ran 2 commands'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('chat-menu')));
      await settleMenu(tester);
      await tester.tap(find.byKey(const ValueKey('chat-menu-tools-all')));
      await settleMenu(tester);
      expect(settings.voice.toolActivity, ToolActivity.all);
      expect(find.text('Ran 2 commands'), findsNothing);
      expect(find.text('make test'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('chat-menu')));
      await settleMenu(tester);
      await tester.tap(find.byKey(const ValueKey('chat-menu-length-full')));
      await settleMenu(tester);
      expect(settings.voice.readAloudLength, ReadAloudLength.full);
    });

    testWidgets('Hidden drops tool rows; approvals and questions stay', (
      tester,
    ) async {
      await settings.setVoice(
        settings.voice.copyWith(toolActivity: ToolActivity.hidden),
      );
      await pumpPage(tester, [
        ok(
          page(
            [
              userLine('u1', 'clean up'),
              assistantLine('a1', [
                toolUse('t1', 'Bash', {'command': 'ls build'}),
                toolUse('t2', 'Bash', {'command': 'du -sh build'}),
                toolUse('q1', 'AskUserQuestion', {
                  'questions': [
                    {
                      'question': 'Delete build too?',
                      'options': [
                        {'label': 'Yes'},
                        {'label': 'No'},
                      ],
                    },
                  ],
                }),
              ]),
            ],
            state: 'needs_permission',
            pending: [
              {'id': 'req-1', 'toolName': 'Bash', 'summary': 'rm -rf build'},
            ],
          ),
        ),
      ]);
      expect(find.text('ls build'), findsNothing);
      expect(find.textContaining('Ran 2'), findsNothing);
      expect(find.text('Allow Bash?'), findsOneWidget);
      expect(find.text('Delete build too?'), findsOneWidget);
    });
  });

  group('speech follows the chat on screen', () {
    testWidgets('opening another chat on top leaves the old one quiet', (
      tester,
    ) async {
      await settings.setVoice(
        settings.voice.copyWith(readAloudByDefault: true),
      );
      final chat = await pumpPage(tester, [
        ok(page(history)),
        ok(
          page(
            [
              assistantLine('a2', [text('Old chat.')]),
            ],
            offset: 200,
            state: 'needs_permission',
            pending: [
              {'id': 'req-1', 'toolName': 'Bash', 'summary': 'npm test'},
            ],
          ),
        ),
        ok(page([], offset: 200)),
      ]);
      await chat.refresh();
      await tester.pump();
      expect(tts.spoken, ['Claude needs your approval to run npm test.']);

      // Another agent's chat opens on top.
      final other = ChatViewController(
        runner: ScriptedAgentCommandRunner([ok(page(history))]),
        sessionId: 's-2',
        pollInterval: const Duration(days: 1),
      );
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      unawaited(
        navigator.push(
          MaterialPageRoute<void>(
            builder: (_) => ChatViewPage(
              controller: other,
              onOpenTerminal: () {},
              textToSpeech: tts,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tts.stops, 0, reason: 'the sentence playing finishes');

      // The old chat's turn ends underneath: not read over the new one.
      await chat.refresh();
      tts.done();
      await tester.pump();
      expect(tts.spoken, ['Claude needs your approval to run npm test.']);
      navigator.pop();
      await tester.pumpAndSettle();
    });

    testWidgets('a reconnect that reloads the thread reads nothing again', (
      tester,
    ) async {
      await settings.setVoice(
        settings.voice.copyWith(readAloudByDefault: true),
      );
      final answered = [
        ...history,
        userLine('u2', 'go'),
        assistantLine('a2', [text('Done once.')]),
      ];
      final chat = await pumpPage(tester, [
        ok(page(history)),
        ok(page(answered.skip(2).toList(), offset: 200)),
        const AppFailure('Could not reach dev.'),
        ok(page(answered, offset: 300, reset: true)),
      ]);
      await chat.refresh();
      await tester.pump();
      expect(tts.spoken, ['Done once.']);
      tts.done();
      await chat.refresh();
      await tester.pump();
      expect(chat.error, isNotNull);
      await chat.refresh();
      await tester.pump();
      expect(chat.error, isNull);
      expect(tts.spoken, ['Done once.']);
    });
  });
}
