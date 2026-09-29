// Opening a Herdr workspace against a real machine (CON-058): the timeline
// from the tap to Herdr on screen, with every side-channel command.
//
// Needs a disposable SSH server with Herdr running (never a machine whose
// Herdr someone uses: with the focus setting on, it moves the focus):
//
//   CONDUCTORE_BENCH_HOST=dev@10.0.0.2 CONDUCTORE_BENCH_KEY=/path/key \
//   CONDUCTORE_BENCH_WORKSPACE=w2 [CONDUCTORE_BENCH_MOSH=1] \
//   [CONDUCTORE_BENCH_MOVE_FOCUS=1] [CONDUCTORE_BENCH_RUNS=5] \
//   [CONDUCTORE_BENCH_PASSPHRASE=...] \
//   flutter test test/perf/workspace_open_live_benchmark_test.dart
//
// Skipped without CONDUCTORE_BENCH_HOST.

import 'dart:async';
import 'dart:io';

import 'package:conduit/features/agent_attention/data/shared_command_runners.dart';
import 'package:conduit/features/agent_attention/data/ssh_agent_command_runner.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/sessions/presentation/herdr_session_focus.dart';
import 'package:conduit/features/terminal/data/dart_ssh_terminal_repository.dart';
import 'package:conduit/features/terminal/data/mosh_terminal_repository.dart';
import 'package:conduit/features/terminal/data/routing_terminal_repository.dart';
import 'package:conduit/features/terminal/domain/host_key_verifier.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:conduit_vt/conduit_vt.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/test_doubles.dart';

class _TrustAll implements HostKeyVerifier {
  @override
  Future<bool> verify({
    required String host,
    required int port,
    required String type,
    required String fingerprint,
  }) async => true;

  @override
  Future<List<HostKeyRecord>> loadTrustedKeys() async => const [];

  @override
  Future<void> saveTrustedKeys(List<HostKeyRecord> records) async {}

  @override
  Future<void> removeTrustedKey(String host, int port) async {}
}

/// Logs every side-channel command with when it started and ended.
class _Logged implements AgentCommandRunner {
  _Logged(this._inner, this._log, this._clock);

  final AgentCommandRunner _inner;
  final List<String> _log;
  final Stopwatch _clock;

  @override
  Future<AgentCommandResult> run(
    String command, {
    required Duration timeout,
  }) async {
    final start = _clock.elapsedMilliseconds;
    try {
      return await _inner.run(command, timeout: timeout);
    } finally {
      final shown = RegExp(r'exec (herdr [^\x27]*)').firstMatch(command);
      _log.add(
        '  side channel ${shown?.group(1) ?? command.split(' ').take(3).join(' ')}'
        ': $start -> ${_clock.elapsedMilliseconds} ms',
      );
    }
  }

  @override
  Future<void> close() => _inner.close();
}

void main() {
  final env = Platform.environment;
  final target = env['CONDUCTORE_BENCH_HOST'];
  final skip = target == null
      ? 'Set CONDUCTORE_BENCH_HOST to run against a real machine.'
      : null;

  test(
    'opening a Herdr workspace, tap to Herdr on screen',
    () async {
      final at = target!.indexOf('@');
      final address = target.substring(at + 1).split(':');
      final host = buildHost('bench').copyWith(
        username: target.substring(0, at),
        host: address.first,
        port: address.length > 1 ? int.parse(address[1]) : 22,
        authMethod: SshAuthMethod.privateKey,
        privateKey: File(env['CONDUCTORE_BENCH_KEY']!).readAsStringSync(),
        passphrase: env['CONDUCTORE_BENCH_PASSPHRASE'] ?? '',
        password: '',
        useMosh: env['CONDUCTORE_BENCH_MOSH'] == '1',
      );
      final workspaceId = env['CONDUCTORE_BENCH_WORKSPACE'] ?? 'w2';
      final moveFocus = env['CONDUCTORE_BENCH_MOVE_FOCUS'] == '1';
      final runs = int.parse(env['CONDUCTORE_BENCH_RUNS'] ?? '3');
      final verifier = _TrustAll();
      final shared = SharedCommandRunners(
        (host) => SshAgentCommandRunner(verifier, host),
      );
      // The home board keeps the machine's side connection open.
      final board = shared.lease(host);
      await board.run('true', timeout: const Duration(seconds: 20));

      final totals = <String, List<int>>{};
      for (var run = 0; run < runs; run++) {
        final clock = Stopwatch();
        final log = <String>[];
        final workspace = TerminalWorkspaceController(
          RoutingTerminalRepository(
            ssh: DartSshTerminalRepository(verifier),
            // As the app wires it: the side connection starts mosh-server.
            mosh: MoshTerminalRepository(verifier, cleanupRunner: shared.lease),
            local: NoNetworkTerminalRepository(),
          ),
        );
        final focus = HerdrSessionFocus(
          workspace: workspace,
          runnerFactory: (host) => _Logged(shared.lease(host), log, clock),
          mayMoveFocus: () => moveFocus,
        );
        final marks = <String, int>{};
        void mark(String name) =>
            marks.putIfAbsent(name, () => clock.elapsedMilliseconds);

        clock.start();
        final session = (await focus.openAgentLocation(
          host,
          workspaceId: workspaceId,
          label: 'bench',
          open: (target) => workspace.open(
            target.apply(host),
            startupCommand: target.startupCommand,
            target: target,
          ),
        ))!;
        mark('session opened');
        final done = Completer<void>();
        void watch() {
          final terminal = session.terminal;
          if (session.status == TerminalConnectionStatus.connected) {
            mark('connected (startup command sent)');
          }
          final text = terminal.buffer.lines
              .toList()
              .map((line) => line.toString())
              .join('\n');
          if (text.contains(r'$')) mark('shell prompt');
          if (!terminal.isUsingAltBuffer &&
              terminal.mouseMode == MouseMode.none &&
              text.contains('herdr')) {
            mark(
              session.startupCover.value
                  ? 'herdr command text in the buffer (covered)'
                  : 'herdr command text VISIBLE',
            );
          }
          if (terminal.isUsingAltBuffer ||
              terminal.mouseMode != MouseMode.none) {
            mark('Herdr on screen');
            if (!done.isCompleted) done.complete();
          }
        }

        session.addListener(watch);
        session.terminalPaintListenable.addListener(watch);
        final poll = Timer.periodic(const Duration(milliseconds: 2), (_) {
          watch();
        });
        unawaited(session.connect());
        await done.future.timeout(const Duration(seconds: 20));
        poll.cancel();
        // Let the side channel finish what the open started.
        await Future<void>.delayed(const Duration(milliseconds: 2500));

        stdout.writeln(
          'run ${run + 1} (${host.useMosh ? 'mosh' : 'ssh'}, '
          'move focus ${moveFocus ? 'on' : 'off'}, RTT as configured):',
        );
        final ordered = marks.entries.toList()
          ..sort((a, b) => a.value.compareTo(b.value));
        for (final entry in ordered) {
          stdout.writeln(
            '  ${entry.value.toString().padLeft(5)} ms  ${entry.key}',
          );
          (totals[entry.key] ??= []).add(entry.value);
        }
        log.forEach(stdout.writeln);

        await session.disconnect();
        await focus.dispose();
        workspace.dispose();
      }
      stdout.writeln('median over $runs runs:');
      for (final entry in totals.entries) {
        final values = entry.value..sort();
        stdout.writeln(
          '  ${values[values.length ~/ 2].toString().padLeft(5)} ms  ${entry.key}',
        );
      }
      await board.close();
      await shared.dispose();
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
