import 'dart:async';

import 'package:conduit/features/agent_attention/data/conductore_host_attention_provider.dart';
import 'package:conduit/features/agent_attention/data/herdr_attention_provider.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/agent_attention/domain/agent_permission_actions.dart';
import 'package:conduit/features/agent_attention/domain/launcher_prompt.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/agent_attention/presentation/agent_permission_action_listener.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

class _QueueSource implements AgentPermissionActionSource {
  final List<AgentPermissionAction> queue = [];
  bool Function()? listener;

  @override
  Future<List<AgentPermissionAction>> consumeActions() async {
    final taken = List.of(queue);
    queue.clear();
    return taken;
  }

  @override
  void setListener(bool Function()? listener) => this.listener = listener;
}

class _LauncherSource implements LauncherActionSource {
  Future<String?> Function(AgentPermissionAction action)? listener;
  void Function()? queuedListener;

  /// Held on the platform; [taken] are in flight (still held).
  final List<QueuedLauncherAnswer> held = [];
  final Set<String> taken = {};

  @override
  void setListener(
    Future<String?> Function(AgentPermissionAction action)? listener,
  ) => this.listener = listener;

  @override
  void setQueuedListener(void Function()? listener) =>
      queuedListener = listener;

  @override
  Future<List<QueuedLauncherAnswer>> takeQueued() async {
    final out = [
      for (final answer in held)
        if (!taken.contains(answer.key)) answer,
    ];
    taken.addAll(out.map((answer) => answer.key));
    return out;
  }

  @override
  Future<void> resolveQueued(String key) async {
    held.removeWhere((answer) => answer.key == key);
    taken.remove(key);
  }

  @override
  Future<void> releaseQueued(List<String> keys) async => taken.removeAll(keys);
}

void main() {
  const tap = AgentPermissionAction(
    notificationId: 'agent:h:s-1',
    hostId: 'h',
    requestId: 'req-1',
    agentId: 's-1',
    verdict: 'allow',
  );

  Future<
    (
      _QueueSource,
      ScriptedAgentCommandRunner,
      RecordingAgentNotifier,
      Completer<void>,
    )
  >
  pump(
    WidgetTester tester, {
    List<AgentPermissionAction> queued = const [],
    bool Function()? mayAct,
  }) async {
    final source = _QueueSource()..queue.addAll(queued);
    final runner = ScriptedAgentCommandRunner([
      const AgentCommandResult(stdout: '{"ok":true}', stderr: '', exitCode: 0),
    ]);
    final notifier = RecordingAgentNotifier();
    final workspace = TerminalWorkspaceController(FreshTerminalRepository());
    final controller = AgentAttentionController(
      workspace: workspace,
      runnerFactory: (_) => runner,
      provider: const HerdrAttentionProvider(),
      companionProvider: const ConductoreHostAttentionProvider(),
      notifier: notifier,
      pollInterval: const Duration(days: 1),
    );
    addTearDown(controller.dispose);
    addTearDown(workspace.dispose);
    final hostsLoaded = Completer<void>();
    final host = buildHost('h');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentPermissionActionListener(
            source: source,
            mayAct: mayAct ?? () => true,
            agentAttention: controller,
            findHost: (hostId) async {
              await hostsLoaded.future;
              return hostId == host.id ? host : null;
            },
            child: const SizedBox(),
          ),
        ),
      ),
    );
    return (source, runner, notifier, hostsLoaded);
  }

  testWidgets('a tap queued before start completes once hosts are loaded', (
    tester,
  ) async {
    final (_, runner, notifier, hostsLoaded) = await pump(
      tester,
      queued: const [tap],
    );
    await tester.runAsync(pumpEventQueue);
    // Still waiting for the saved hosts: nothing sent, nothing failed.
    expect(runner.commands, isEmpty);
    expect(notifier.shown, isEmpty);

    hostsLoaded.complete();
    await tester.runAsync(pumpEventQueue);
    await tester.pump();

    expect(runner.commands.single, contains('decide req-1 allow'));
    expect(runner.closeCount, 1);
    expect(notifier.agentCancelled, ['agent:h:s-1']);
    expect(find.text('Allowed the permission request on Host h.'), findsOne);
  });

  testWidgets('a ping while mounted drains the queue and says so', (
    tester,
  ) async {
    final (source, runner, notifier, hostsLoaded) = await pump(tester);
    hostsLoaded.complete();
    source.queue.add(tap);

    expect(source.listener?.call(), isTrue);
    await tester.runAsync(pumpEventQueue);
    await tester.pump();
    expect(runner.commands.single, contains('decide req-1 allow'));
    expect(notifier.agentCancelled, ['agent:h:s-1']);

    // Unmounted (e.g. the app locked): the platform is told nobody listens.
    await tester.pumpWidget(const SizedBox());
    expect(source.listener, isNull);
  });

  testWidgets('a closed app lock leaves taps queued, answered after unlock', (
    tester,
  ) async {
    var unlocked = false;
    final (source, runner, _, hostsLoaded) = await pump(
      tester,
      queued: const [tap],
      mayAct: () => unlocked,
    );
    hostsLoaded.complete();
    await tester.runAsync(pumpEventQueue);
    // Mounted but the app lock refuses (away past its delay): nothing is
    // decided, the tap stays queued and the platform is told so.
    expect(runner.commands, isEmpty);
    expect(source.queue, [tap]);
    expect(source.listener?.call(), isFalse);
    await tester.runAsync(pumpEventQueue);
    expect(runner.commands, isEmpty);
    expect(source.queue, [tap]);

    unlocked = true;
    expect(source.listener?.call(), isTrue);
    await tester.runAsync(pumpEventQueue);
    await tester.pump();
    expect(runner.commands.single, contains('decide req-1 allow'));
  });

  testWidgets('the app lock is re-checked right before each answer', (
    tester,
  ) async {
    var checks = 0;
    final (_, runner, _, hostsLoaded) = await pump(
      tester,
      queued: const [tap],
      // Open when the queue is read, closed by the time it would answer.
      mayAct: () => ++checks == 1,
    );
    hostsLoaded.complete();
    await tester.runAsync(pumpEventQueue);
    await tester.pump();
    expect(checks, greaterThanOrEqualTo(2));
    expect(runner.commands, isEmpty);
  });

  testWidgets('launcher answers need the app lock open', (tester) async {
    final launcher = _LauncherSource();
    final runner = ScriptedAgentCommandRunner(const []);
    final workspace = TerminalWorkspaceController(FreshTerminalRepository());
    final controller = AgentAttentionController(
      workspace: workspace,
      runnerFactory: (_) => runner,
      provider: const HerdrAttentionProvider(),
      companionProvider: const ConductoreHostAttentionProvider(),
      pollInterval: const Duration(days: 1),
    );
    addTearDown(controller.dispose);
    addTearDown(workspace.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: AgentPermissionActionListener(
          source: _QueueSource(),
          launcherActions: launcher,
          agentAttention: controller,
          mayAct: () => false,
          findHost: (hostId) async => buildHost(hostId),
          child: const SizedBox(),
        ),
      ),
    );
    final error = await tester.runAsync(() => launcher.listener!(tap));
    expect(error, 'Unlock Conductore first');
    expect(runner.commands, isEmpty);
  });

  testWidgets('takes launcher answers only while mounted', (tester) async {
    final launcher = _LauncherSource();
    final workspace = TerminalWorkspaceController(FreshTerminalRepository());
    final controller = AgentAttentionController(
      workspace: workspace,
      runnerFactory: (_) => ScriptedAgentCommandRunner(const []),
      provider: const HerdrAttentionProvider(),
      companionProvider: const ConductoreHostAttentionProvider(),
      pollInterval: const Duration(days: 1),
    );
    addTearDown(controller.dispose);
    addTearDown(workspace.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: AgentPermissionActionListener(
          source: _QueueSource(),
          launcherActions: launcher,
          agentAttention: controller,
          findHost: (hostId) async => buildHost(hostId),
          child: const SizedBox(),
        ),
      ),
    );
    expect(launcher.listener, isNotNull);
    // Nothing monitors the host: the launcher is told why.
    final error = await tester.runAsync(() => launcher.listener!(tap));
    expect(error, 'Conductore is not monitoring that machine');

    await tester.pumpWidget(const SizedBox());
    expect(launcher.listener, isNull);
  });

  group('answers held while locked (CON-119)', () {
    QueuedLauncherAnswer held({
      String hostId = 'h',
      DateTime? queuedAt,
      String key = 'h/s-1@1',
    }) => QueuedLauncherAnswer(
      key: key,
      action: AgentPermissionAction(
        notificationId: '',
        hostId: hostId,
        agentId: 's-1',
        requestId: 'req-1',
        verdict: 'allow',
      ),
      title: 'api',
      host: 'dev',
      queuedAt: queuedAt ?? DateTime.now(),
    );

    Future<(_LauncherSource, ValueNotifier<bool>)> pumpHeld(
      WidgetTester tester, {
      List<QueuedLauncherAnswer> queued = const [],
      bool unlocked = true,
      Future<SavedHost?> Function(String hostId)? findHost,
    }) async {
      final launcher = _LauncherSource()..held.addAll(queued);
      final lock = ValueNotifier(unlocked);
      addTearDown(lock.dispose);
      final workspace = TerminalWorkspaceController(FreshTerminalRepository());
      final controller = AgentAttentionController(
        workspace: workspace,
        runnerFactory: (_) => ScriptedAgentCommandRunner(const []),
        provider: const HerdrAttentionProvider(),
        companionProvider: const ConductoreHostAttentionProvider(),
        pollInterval: const Duration(days: 1),
      );
      addTearDown(controller.dispose);
      addTearDown(workspace.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AgentPermissionActionListener(
              source: _QueueSource(),
              launcherActions: launcher,
              agentAttention: controller,
              mayAct: () => lock.value,
              lockChanges: lock,
              // Only "h" is saved.
              findHost:
                  findHost ??
                  (hostId) async => hostId == 'h' ? buildHost('h') : null,
              child: const SizedBox(),
            ),
          ),
        ),
      );
      return (launcher, lock);
    }

    testWidgets('they wait for the unlock, then say how they went', (
      tester,
    ) async {
      final (launcher, lock) = await pumpHeld(
        tester,
        unlocked: false,
        queued: [held(hostId: 'gone')],
      );
      await tester.runAsync(pumpEventQueue);
      // Locked: still held on the platform.
      expect(launcher.held, hasLength(1));

      lock.value = true;
      await tester.runAsync(pumpEventQueue);
      await tester.pump();
      expect(launcher.held, isEmpty);
      expect(
        find.text(
          "Your answer to api on dev wasn't sent: "
          'The machine is no longer saved.',
        ),
        findsOne,
      );
    });

    testWidgets('an expired one is dropped and the user told', (tester) async {
      await pumpHeld(
        tester,
        queued: [
          held(queuedAt: DateTime.now().subtract(const Duration(minutes: 16))),
        ],
      );
      await tester.runAsync(pumpEventQueue);
      await tester.pump();
      expect(
        find.text(
          "Your answer to api on dev wasn't sent: "
          'it waited more than 15 minutes.',
        ),
        findsOne,
      );
    });

    testWidgets("the platform's ping sends one held while unlocked", (
      tester,
    ) async {
      final (launcher, _) = await pumpHeld(tester);
      await tester.runAsync(pumpEventQueue);
      launcher.held.add(held(hostId: 'gone'));
      launcher.queuedListener!();
      await tester.runAsync(pumpEventQueue);
      await tester.pump();
      expect(launcher.held, isEmpty);
      expect(
        find.textContaining("Your answer to api on dev wasn't sent"),
        findsOne,
      );

      await tester.pumpWidget(const SizedBox());
      expect(launcher.queuedListener, isNull);
    });

    testWidgets('locked again before sending: still held, sent after the '
        'next unlock', (tester) async {
      final hostsLoaded = Completer<void>();
      final (launcher, lock) = await pumpHeld(
        tester,
        queued: [
          held(hostId: 'gone', key: 'a'),
          held(hostId: 'gone', key: 'b'),
        ],
        findHost: (hostId) async {
          await hostsLoaded.future;
          return null;
        },
      );
      await tester.runAsync(pumpEventQueue);
      // Taken (in flight) but not sent yet.
      expect(launcher.taken, {'a', 'b'});
      lock.value = false;
      hostsLoaded.complete();
      await tester.runAsync(pumpEventQueue);
      await tester.pump();
      // Nothing sent and nothing lost: both held, takeable again.
      expect(launcher.held.map((answer) => answer.key), ['a', 'b']);
      expect(launcher.taken, isEmpty);
      expect(find.byType(SnackBar), findsNothing);

      lock.value = true;
      await tester.runAsync(pumpEventQueue);
      await tester.pump();
      // Its machine is gone: dropped on purpose, and the user told.
      expect(launcher.held, isEmpty);
      expect(launcher.taken, isEmpty);
      expect(
        find.textContaining("Your answer to api on dev wasn't sent"),
        findsOne,
      );
    });

    test('which outcomes drop a held answer', () {
      expect(heldAnswerSettled(null), isTrue);
      expect(heldAnswerSettled(QueuedLauncherAnswer.expiredError), isTrue);
      expect(heldAnswerSettled(LauncherPrompt.staleError), isTrue);
      expect(heldAnswerSettled(LauncherPrompt.highRiskNote), isTrue);
      expect(
        heldAnswerSettled(AgentAttentionController.machineGoneError),
        isTrue,
      );
      // Not monitored yet, or the send failed: kept for the next unlock.
      expect(
        heldAnswerSettled(AgentAttentionController.notMonitoringError),
        isFalse,
      );
      expect(heldAnswerSettled('Connection reset'), isFalse);
      expect(
        heldAnswerMessage(held(), AgentAttentionController.notMonitoringError),
        'Your answer to api on dev is still waiting: Conductore is not '
        'monitoring that machine. Conductore tries again after the next '
        'unlock.',
      );
    });

    test('the messages', () {
      final answer = held();
      expect(
        heldAnswerMessage(answer, null),
        'Sent your answer to api on dev.',
      );
      expect(
        heldAnswerMessage(answer, LauncherPrompt.staleError),
        "Your answer to api on dev wasn't sent: it was answered elsewhere.",
      );
      expect(
        heldAnswerMessage(
          QueuedLauncherAnswer(action: answer.action, queuedAt: DateTime(2026)),
          LauncherPrompt.terminalNote,
        ),
        "Your answer to an agent wasn't sent: Answer it in the terminal.",
      );
    });
  });
}
