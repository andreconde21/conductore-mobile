import 'package:conduit/core/app_failure.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/voice/domain/speech_event.dart';
import 'package:conduit/features/voice/domain/text_to_speech.dart';
import 'package:conduit/features/voice/domain/voice_preferences.dart';
import 'package:conduit/features/voice/presentation/dictation_controller.dart';
import 'package:conduit/features/voice/presentation/read_aloud_controller.dart';
import 'package:conduit/features/voice_guide/domain/approval_actions.dart';
import 'package:conduit/features/voice_guide/domain/guide_brain.dart';
import 'package:conduit/features/voice_guide/domain/guide_ports.dart';
import 'package:conduit/features/voice_guide/domain/guide_preferences.dart';
import 'package:conduit/features/voice_guide/domain/guide_world.dart';
import 'package:conduit/features/voice_guide/presentation/guide_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../voice/fake_speech_recognizer.dart';
import '../voice/fake_tts.dart';
import 'guide_fixtures.dart';

void main() {
  late FakeSpeechRecognizer mic;
  late FakeTts tts;
  late DictationController dictation;
  late ReadAloudController speaker;
  late GuideController guide;
  late GuideWorld now;
  late FakeApprovals approvals;
  late FakeNavigator navigator;
  late FakeMessenger messenger;
  late GuidePreferences prefs;
  FakeBrain? brain;
  var locked = false;

  Future<void> setUpGuide(
    WidgetTester tester, {
    GuideWorld? world,
    FakeApprovals? approvalActions,
    FakeBrain? withBrain,
    FakeAccounts? accounts,
    GuideCatchUpText? catchUp,
    FakeReviewer? reviewer,
  }) async {
    mic = FakeSpeechRecognizer();
    tts = FakeTts();
    now = world ?? fleet();
    approvals = approvalActions ?? FakeApprovals();
    navigator = FakeNavigator(now.screen);
    messenger = FakeMessenger();
    prefs = GuidePreferences.defaults;
    brain = withBrain;
    locked = false;
    dictation = DictationController(mic, language: () => 'en-US');
    speaker = ReadAloudController(
      tts: tts,
      preferences: () => VoicePreferences.defaults,
    );
    guide = GuideController(
      dictation: dictation,
      speaker: speaker,
      world: () => GuideWorld(
        machines: now.machines,
        agents: now.agents,
        screen: navigator.current,
      ),
      approvals: approvals,
      navigator: navigator,
      messenger: messenger,
      preferences: () => prefs,
      speechLanguage: () => 'en-US',
      brain: brain,
      usage: (_) => 'Five hour limit at 42 percent.',
      catchUp: catchUp,
      accounts: accounts,
      reviewer: reviewer,
      locked: () => locked,
      afterSpeechPause: Duration.zero,
      thinkingNotice: const Duration(seconds: 30),
    );
    addTearDown(() {
      guide.dispose();
      speaker.dispose();
      dictation.dispose();
    });
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 1));
    }
  }

  /// Says [text] into the open mic.
  Future<void> talk(WidgetTester tester, String text) async {
    expect(guide.phase, GuidePhase.listening, reason: 'the mic is open');
    mic.say(text);
    await settle(tester);
  }

  /// Lets the current utterance finish; the guide then listens again.
  Future<String> hear(WidgetTester tester) async {
    await settle(tester);
    final said = tts.spoken.last;
    tts.done();
    await settle(tester);
    return said;
  }

  Future<void> begin(WidgetTester tester) async {
    guide.start();
    await settle(tester);
  }

  testWidgets('what is waiting is read from the app, then it listens again', (
    tester,
  ) async {
    await setUpGuide(tester);
    await begin(tester);
    await talk(tester, "What's waiting?");
    expect(await hear(tester), 'One approval: api on VTM wants npm test.');
    expect(guide.phase, GuidePhase.listening);
    // Silence ends it.
    mic.emit(const SpeechError(code: SpeechError.speechTimeout, message: ''));
    await settle(tester);
    expect(guide.phase, GuidePhase.off);
  });

  testWidgets('catch me up speaks the dashboard, in the guide language', (
    tester,
  ) async {
    final asked = <String>[];
    await setUpGuide(
      tester,
      catchUp: (code) async {
        asked.add(code);
        return '1 needs you, 0 stuck, 2 working, 3 done.';
      },
    );
    await begin(tester);
    await talk(tester, 'catch me up');
    expect(await hear(tester), '1 needs you, 0 stuck, 2 working, 3 done.');
    expect(asked, ['en']);
    expect(guide.phase, GuidePhase.listening);
  });

  testWidgets('without a dashboard, catch me up says what is waiting', (
    tester,
  ) async {
    await setUpGuide(tester);
    await begin(tester);
    await talk(tester, 'catch me up');
    expect(await hear(tester), 'One approval: api on VTM wants npm test.');
  });

  testWidgets('approve asks for a yes, then approves exactly that request', (
    tester,
  ) async {
    await setUpGuide(tester);
    await begin(tester);
    await talk(tester, 'approve');
    expect(await hear(tester), 'Approve npm test for api on VTM? Say yes.');
    expect(approvals.decided, isEmpty);
    await talk(tester, 'yes');
    expect(approvals.decided, [('vtm', 'req-npm', PermissionVerdict.allow)]);
    expect(await hear(tester), 'Approved.');
  });

  testWidgets('a request only the terminal answers (Gemini CLI): no approve, '
      'deny, trust or approve all; it offers to open the agent', (
    tester,
  ) async {
    const write = PendingPermissionRequest(
      id: 'req-gem',
      toolName: 'Write',
      summary: '/work/proj/hello.txt',
      terminalOnly: true,
    );
    await setUpGuide(
      tester,
      world: GuideWorld(
        machines: const [vtm],
        agents: [
          agent('s-gem', project: 'proj', pending: const [write]),
        ],
      ),
      approvalActions: FakeApprovals(
        risks: {'req-gem': ApprovalRisk.low},
        smart: true,
      ),
    );
    await begin(tester);
    const offer =
        'proj takes its approvals in the terminal: answer it there. '
        'Open proj? Say yes.';
    await talk(tester, 'approve');
    expect(await hear(tester), offer);
    await talk(tester, 'no');
    await hear(tester);
    await talk(tester, 'deny');
    expect(await hear(tester), offer);
    await talk(tester, 'no');
    await hear(tester);
    await talk(tester, 'approve all safe');
    expect(await hear(tester), 'No low-risk requests are waiting.');
    await talk(tester, 'approve');
    expect(await hear(tester), offer);
    await talk(tester, 'yes');
    expect(navigator.opened.last, ('s-gem', null));
    await hear(tester);
    expect(approvals.decided, isEmpty);
    expect(approvals.batches, isEmpty);
    expect(approvals.trusted, isEmpty);
  });

  testWidgets('no, or two unclear answers, cancel without acting', (
    tester,
  ) async {
    await setUpGuide(tester);
    await begin(tester);
    await talk(tester, 'deny');
    await hear(tester);
    await talk(tester, 'no');
    expect(await hear(tester), 'Cancelled.');
    await talk(tester, 'approve');
    await hear(tester);
    await talk(tester, 'maybe');
    expect(await hear(tester), 'Say yes or no.');
    await talk(tester, 'hmm');
    expect(await hear(tester), 'Cancelled.');
    expect(approvals.decided, isEmpty);
  });

  testWidgets('low-risk approvals skip the question only when set so', (
    tester,
  ) async {
    await setUpGuide(
      tester,
      approvalActions: FakeApprovals(risks: {npmTest.id: ApprovalRisk.low}),
    );
    prefs = prefs.copyWith(confirm: GuideConfirm.skipLowRisk);
    await begin(tester);
    await talk(tester, 'approve');
    expect(approvals.decided, [('vtm', 'req-npm', PermissionVerdict.allow)]);
    expect(await hear(tester), 'Approved.');
  });

  testWidgets('high-risk approvals are always confirmed', (tester) async {
    await setUpGuide(
      tester,
      world: GuideWorld(
        machines: const [vtm],
        agents: [
          agent('s-api', project: 'api', pending: const [rmRf]),
        ],
      ),
      approvalActions: FakeApprovals(risks: {rmRf.id: ApprovalRisk.high}),
    );
    prefs = prefs.copyWith(confirm: GuideConfirm.skipLowRisk);
    await begin(tester);
    await talk(tester, 'approve');
    expect(await hear(tester), 'Approve rm -rf build for api on VTM? Say yes.');
    expect(approvals.decided, isEmpty);
  });

  testWidgets('the agent ends while the question is asked: says so', (
    tester,
  ) async {
    await setUpGuide(tester);
    await begin(tester);
    await talk(tester, 'tell api to run the tests');
    expect(await hear(tester), 'Send to api: Run the tests? Say yes.');
    // Claude exits on the machine meanwhile.
    now = GuideWorld(
      machines: now.machines,
      agents: [
        agent('s-api', project: 'api', state: AgentAttentionState.finished),
        now.agents.last,
      ],
    );
    await talk(tester, 'yes');
    expect(messenger.sent, isEmpty);
    expect(await hear(tester), 'api has ended.');
    // And vanished entirely.
    await talk(tester, 'tell web to open a pull request');
    await hear(tester);
    now = GuideWorld(machines: now.machines);
    await talk(tester, 'yes');
    expect(messenger.sent, isEmpty);
    expect(await hear(tester), "That's gone.");
  });

  testWidgets('the request is answered elsewhere while the question is asked', (
    tester,
  ) async {
    await setUpGuide(tester);
    await begin(tester);
    await talk(tester, 'approve');
    await hear(tester);
    now = GuideWorld(
      machines: now.machines,
      agents: [
        agent('s-api', project: 'api'),
        now.agents.last,
      ],
    );
    await talk(tester, 'yes');
    expect(approvals.decided, isEmpty);
    expect(
      await hear(tester),
      'That request was already answered or timed out.',
    );
  });

  testWidgets(
    'a new agent with the same name appears: yes still means the one asked about',
    (tester) async {
      await setUpGuide(tester);
      await begin(tester);
      await talk(tester, 'approve');
      await hear(tester);
      // A second api session starts, with its own request.
      now = GuideWorld(
        machines: now.machines,
        agents: [
          agent(
            's-api-2',
            project: 'api',
            pending: const [
              PendingPermissionRequest(
                id: 'req-2',
                toolName: 'Bash',
                summary: 'rm -rf /',
              ),
            ],
          ),
          ...now.agents,
        ],
      );
      await talk(tester, 'yes');
      expect(approvals.decided, [('vtm', 'req-npm', PermissionVerdict.allow)]);
      expect(await hear(tester), 'Approved.');
    },
  );

  testWidgets('with several requests waiting it asks which, never guesses', (
    tester,
  ) async {
    await setUpGuide(
      tester,
      world: GuideWorld(
        machines: const [vtm, laptop],
        agents: [
          agent('s-api', project: 'api', pending: const [npmTest]),
          agent(
            's-web',
            hostId: 'laptop',
            machine: 'Laptop',
            project: 'website',
            pending: const [rmRf],
          ),
        ],
      ),
    );
    await begin(tester);
    await talk(tester, 'approve');
    expect(
      await hear(tester),
      '2 approvals are waiting. Say approve and the agent name.',
    );
    await talk(tester, 'approve for website');
    expect(
      await hear(tester),
      'Approve rm -rf build for website on Laptop? Say yes.',
    );
  });

  testWidgets('a failed decision is said, not thrown', (tester) async {
    await setUpGuide(tester);
    approvals.failWith = const AppFailure(
      'This request was already answered or timed out. If the agent still '
      'waits, answer it in the terminal.',
    );
    await begin(tester);
    await talk(tester, 'approve');
    await hear(tester);
    await talk(tester, 'yes');
    expect(
      await hear(tester),
      'That request was already answered or timed out.',
    );
    expect(guide.phase, GuidePhase.listening);
  });

  testWidgets(
    'approve all safe and trust: not available yet without smart approvals',
    (tester) async {
      await setUpGuide(tester);
      await begin(tester);
      await talk(tester, 'approve all safe');
      expect(await hear(tester), "Approve all safe isn't available yet.");
      await talk(tester, 'trust this for 15 minutes');
      expect(await hear(tester), "Trusting an agent isn't available yet.");
      await talk(tester, 'switch to the work account');
      expect(await hear(tester), "Switching accounts isn't available yet.");
    },
  );

  testWidgets(
    'approve all safe with smart approvals: counts, confirms, never high risk',
    (tester) async {
      await setUpGuide(
        tester,
        world: GuideWorld(
          machines: const [vtm],
          agents: [
            agent('s-api', project: 'api', pending: const [npmTest, rmRf]),
          ],
        ),
        approvalActions: FakeApprovals(
          smart: true,
          risks: {npmTest.id: ApprovalRisk.low, rmRf.id: ApprovalRisk.high},
        ),
      );
      await begin(tester);
      await talk(tester, 'approve all safe');
      expect(await hear(tester), 'Approve one low-risk request? Say yes.');
      await talk(tester, 'yes');
      expect(approvals.batches, [
        ['req-npm'],
      ]);
      expect(await hear(tester), 'Approved one.');
    },
  );

  testWidgets(
    'trust with smart approvals: the request and its kind, confirmed; never high risk',
    (tester) async {
      await setUpGuide(
        tester,
        world: GuideWorld(
          machines: const [vtm],
          agents: [
            agent('s-api', project: 'api', pending: const [npmTest]),
            agent('s-ops', project: 'ops', pending: const [rmRf]),
          ],
          screen: const GuideScreen(
            GuideView.chat,
            hostId: 'vtm',
            agentId: 's-api',
          ),
        ),
        approvalActions: FakeApprovals(
          smart: true,
          risks: {npmTest.id: ApprovalRisk.low, rmRf.id: ApprovalRisk.high},
        ),
      );
      await begin(tester);
      await talk(tester, 'trust this for 15 minutes');
      expect(
        await hear(tester),
        'Trust api to run npm test and the like for 15 minutes? Say yes.',
      );
      await talk(tester, 'yes');
      expect(approvals.trusted, [
        ('vtm', 'req-npm', const Duration(minutes: 15)),
      ]);
      expect(await hear(tester), 'Trusting api for 15 minutes.');
      await talk(tester, 'trust ops for an hour');
      expect(await hear(tester), startsWith('That request is high risk'));
      expect(approvals.trusted, hasLength(1));
    },
  );

  testWidgets(
    'switch account: matched by label, confirmed, on the machines that can',
    (tester) async {
      final fake = FakeAccounts();
      await setUpGuide(tester, accounts: fake);
      await begin(tester);
      await talk(tester, 'switch to the work account');
      expect(
        await hear(tester),
        'Switch new Claude sessions to Work on VTM and Laptop? Say yes.',
      );
      await talk(tester, 'yes');
      expect(fake.switched, ['Work']);
      expect(
        await hear(tester),
        'New Claude sessions on VTM and Laptop now use Work.',
      );
      await talk(tester, 'switch to the personal account');
      expect(await hear(tester), 'Personal is already the active account.');
      await talk(tester, 'switch to the boss account');
      expect(
        await hear(tester),
        "I can't find the account boss. The accounts are Work and Personal.",
      );
      fake.available = false;
      await talk(tester, 'muda para a conta work');
      expect(await hear(tester), "Switching accounts isn't available yet.");
    },
  );

  testWidgets('open, chat, terminal, home, read and more', (tester) async {
    await setUpGuide(tester);
    await begin(tester);
    await talk(tester, 'open website');
    expect(await hear(tester), 'Opening website on Laptop.');
    expect(navigator.opened.last, ('s-web', null));
    await talk(tester, 'go to terminal');
    expect(await hear(tester), 'Terminal of website.');
    expect(navigator.opened.last, ('s-web', GuideView.terminal));
    await talk(tester, 'read the last reply');
    expect(
      await hear(tester),
      startsWith('website says: Done. The build is green.'),
    );
    await talk(tester, 'more');
    expect(await hear(tester), contains('pull request'));
    await talk(tester, 'home');
    expect(await hear(tester), 'Home.');
    expect(navigator.homes, 1);
    await talk(tester, 'go to chat');
    expect(await hear(tester), 'No agent is on screen. Say open and a name.');
    await talk(tester, "what's my usage");
    expect(await hear(tester), 'Five hour limit at 42 percent.');
    await talk(tester, 'stop');
    expect(await hear(tester), 'OK.');
    expect(guide.phase, GuidePhase.off);
  });

  testWidgets('the brain: context in, one validated action out', (
    tester,
  ) async {
    final fake = FakeBrain(
      (context) => GuideBrainAction(
        action: 'send',
        target: agentIdFor(context, 'website'),
        text: 'How far are you?',
        speak: 'Asking.',
      ),
    );
    await setUpGuide(tester, withBrain: fake);
    await begin(tester);
    await talk(tester, 'ask web how far it is');
    expect(fake.asked.single.$1, 'ask web how far it is');
    expect(await hear(tester), 'Send to website: How far are you? Say yes.');
    await talk(tester, 'yes');
    expect(messenger.sent, [('s-web', 'How far are you?')]);
    expect(await hear(tester), 'Sent.');
  });

  testWidgets('the brain naming an id it was not given does nothing', (
    tester,
  ) async {
    final fake = FakeBrain(
      (_) => const GuideBrainAction(
        action: 'open',
        target: 'a42',
        speak: 'Opening.',
      ),
    );
    await setUpGuide(tester, withBrain: fake);
    await begin(tester);
    await talk(tester, 'open the thing from yesterday please now');
    expect(navigator.opened, isEmpty);
    expect(
      await hear(tester),
      "Sorry, I didn't get that. Say help for the commands.",
    );
  });

  testWidgets('the brain failing is said', (tester) async {
    final fake = FakeBrain(
      (_) => const GuideBrainFailed(GuideBrainFailed.outdated),
    );
    await setUpGuide(tester, withBrain: fake);
    await begin(tester);
    await talk(tester, 'why is the build red');
    expect(await hear(tester), 'The brain machine needs a companion update.');
    expect(guide.phase, GuidePhase.listening);
  });

  testWidgets('without a brain only the phrases work', (tester) async {
    await setUpGuide(tester);
    await begin(tester);
    await talk(tester, 'why is the build red');
    expect(await hear(tester), startsWith('I only know the simple commands'));
    // A name nobody has is said as not found, not sent anywhere.
    await talk(tester, 'open the thing from yesterday');
    expect(await hear(tester), "I can't find thing from yesterday.");
  });

  testWidgets('off in settings, or locked: it only says so', (tester) async {
    await setUpGuide(tester);
    prefs = prefs.copyWith(enabled: false);
    guide.start();
    await settle(tester);
    expect(guide.phase, GuidePhase.off);
    expect(tts.spoken.last, 'The voice guide is off in Settings.');
    tts.done();
    await settle(tester);
    prefs = prefs.copyWith(enabled: true);
    locked = true;
    guide.start();
    await settle(tester);
    expect(guide.phase, GuidePhase.off);
    expect(tts.spoken.last, 'Unlock Conductore first.');
    tts.done();
    await settle(tester);
    expect(mic.starts, isEmpty);
  });

  testWidgets('a busy mic (a call) is retried twice, then it gives up', (
    tester,
  ) async {
    await setUpGuide(tester);
    guide.start();
    await settle(tester);
    for (var i = 0; i < 3; i++) {
      expect(guide.phase, GuidePhase.listening);
      mic.emit(const SpeechError(code: 3, message: 'Audio busy.'));
      await settle(tester);
      if (i < 2) {
        expect(guide.phase, GuidePhase.paused);
        await tester.pump(const Duration(seconds: 5));
        await settle(tester);
      }
    }
    expect(await hear(tester), 'The microphone is busy. Guide off.');
    expect(guide.phase, GuidePhase.off);
    expect(mic.starts.length, 3);
  });

  testWidgets('speech paused by a call resumes before the mic opens', (
    tester,
  ) async {
    await setUpGuide(tester);
    await begin(tester);
    await talk(tester, "what's waiting");
    await settle(tester);
    final id = tts.ids.last;
    tts.emit(TtsPaused(id, offset: 3));
    await settle(tester);
    expect(guide.phase, GuidePhase.speaking, reason: 'waits for the audio');
    final startsBefore = mic.starts.length;
    tts.emit(const TtsResumed());
    await settle(tester);
    tts.done();
    await settle(tester);
    expect(guide.phase, GuidePhase.listening);
    expect(mic.starts.length, startsBefore + 1);
  });

  testWidgets(
    'pressing again while it speaks barges in and keeps the question',
    (tester) async {
      await setUpGuide(tester);
      await begin(tester);
      await talk(tester, 'approve');
      await settle(tester);
      expect(guide.phase, GuidePhase.speaking);
      guide.start();
      await settle(tester);
      expect(guide.phase, GuidePhase.listening);
      expect(guide.confirming, isTrue);
      await talk(tester, 'yes');
      expect(approvals.decided, hasLength(1));
      expect(await hear(tester), 'Approved.');
    },
  );

  group('review and undo', () {
    GuideWorld onChat(AgentAttentionState state) => GuideWorld(
      machines: const [vtm],
      agents: [agent('s-api', project: 'api', state: state)],
      screen: const GuideScreen(
        GuideView.chat,
        hostId: 'vtm',
        agentId: 's-api',
      ),
    );

    testWidgets('undo that asks with the turn and file count, then undoes '
        'exactly that turn', (tester) async {
      final reviewer = FakeReviewer();
      await setUpGuide(
        tester,
        world: onChat(AgentAttentionState.needsInput),
        reviewer: reviewer,
      );
      await begin(tester);
      await talk(tester, 'undo that');
      expect(
        await hear(tester),
        "Undo api's last turn, \"Fix the date parser\", and restore 3 "
        'files? Say yes.',
      );
      expect(reviewer.undone, isEmpty);
      await talk(tester, 'yes');
      expect(
        await hear(tester),
        'Undone: 3 files of api restored. Say review to redo it.',
      );
      expect(reviewer.undone, [('s-api', 4)]);
    });

    testWidgets('no, and a working agent, undo nothing', (tester) async {
      final reviewer = FakeReviewer();
      await setUpGuide(
        tester,
        world: onChat(AgentAttentionState.needsInput),
        reviewer: reviewer,
      );
      await begin(tester);
      await talk(tester, 'desfaz isso');
      await hear(tester);
      await talk(tester, 'no');
      expect(await hear(tester), 'Cancelled.');
      expect(reviewer.undone, isEmpty);

      now = onChat(AgentAttentionState.working);
      await talk(tester, 'undo the last turn');
      expect(
        await hear(tester),
        'api is still working. Undo when its turn ends.',
      );
      expect(reviewer.undone, isEmpty);
    });

    testWidgets('nothing to undo, and a machine without snapshots', (
      tester,
    ) async {
      final reviewer = FakeReviewer()..last = null;
      await setUpGuide(
        tester,
        world: onChat(AgentAttentionState.needsInput),
        reviewer: reviewer,
      );
      await begin(tester);
      await talk(tester, 'undo that');
      expect(await hear(tester), 'api has no turn to undo.');
      reviewer.undoable = false;
      await talk(tester, 'undo that');
      expect(
        await hear(tester),
        "Review isn't available for api. Update the agent hooks on its "
        'machine.',
      );
    });

    testWidgets('review opens Review of the agent on screen, or a named one', (
      tester,
    ) async {
      final reviewer = FakeReviewer();
      await setUpGuide(
        tester,
        world: onChat(AgentAttentionState.needsInput),
        reviewer: reviewer,
      );
      await begin(tester);
      await talk(tester, 'review');
      expect(await hear(tester), 'Reviewing api.');
      await talk(tester, 'revê o api');
      expect(await hear(tester), 'Reviewing api.');
      expect(reviewer.reviewed, ['s-api', 's-api']);
    });

    testWidgets('without a reviewer the guide says it is not available', (
      tester,
    ) async {
      await setUpGuide(tester, world: onChat(AgentAttentionState.idle));
      await begin(tester);
      await talk(tester, 'review the changes');
      expect(
        await hear(tester),
        "Review isn't available for api. Update the agent hooks on its "
        'machine.',
      );
    });
  });
}
