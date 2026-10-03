import 'dart:convert';

import 'package:conduit/core/app_failure.dart';
import 'package:conduit/features/companion_setup/data/companion_probe.dart';
import 'package:conduit/features/companion_setup/domain/companion_status.dart';
import 'package:flutter_test/flutter_test.dart';

import 'companion_fakes.dart';

void main() {
  final now = DateTime(2026, 9, 25, 12);
  CompanionStatus classify(CompanionProbeResults probe) =>
      classifyCompanionStatus(probe, now: now);

  group('classifyCompanionStatus', () {
    test('version exit 127 is not installed', () {
      final status = classify(
        CompanionProbeResults(
          version: notFound,
          node: ok('v20.11.0'),
          claude: ok('2.1.0 (Claude Code)'),
        ),
      );
      expect(status.state, CompanionState.notInstalled);
      expect(status.nodeVersion, '20.11.0');
      expect(status.nodeSupported, isTrue);
      expect(status.claudeVersion, '2.1.0 (Claude Code)');
    });

    test('exit 127 from env missing node is an error, not "not installed"', () {
      final status = classify(
        CompanionProbeResults(
          version: failed(
            127,
            stderr: "/usr/bin/env: 'node': No such file or directory",
          ),
          node: failed(127),
        ),
      );
      expect(status.state, CompanionState.error);
      expect(status.message, contains('Node.js'));
      expect(status.nodeFound, isFalse);
    });

    test('old node is reported as unsupported', () {
      final status = classify(
        CompanionProbeResults(version: notFound, node: ok('v16.20.0')),
      );
      expect(status.nodeFound, isTrue);
      expect(status.nodeSupported, isFalse);
    });

    test('doctor missing hooks is hooks not registered', () {
      final status = classify(
        CompanionProbeResults(
          version: ok(versionJson()),
          doctor: ok(doctorJson(hooks: false)),
          status: ok(statusJson()),
        ),
      );
      expect(status.state, CompanionState.hooksMissing);
      expect(status.message, contains('missing: SessionStart, Stop'));
      expect(status.checks, hasLength(6));
      expect(status.user, 'andre');
    });

    test('a missing hook client also counts as hooks not registered', () {
      final status = classify(
        CompanionProbeResults(
          version: ok(versionJson()),
          doctor: ok(doctorJson(hookClient: false)),
          status: ok(statusJson()),
        ),
      );
      expect(status.state, CompanionState.hooksMissing);
    });

    test('hooked, daemon down, never an event: waiting for first event', () {
      final status = classify(
        CompanionProbeResults(
          version: ok(versionJson()),
          doctor: ok(doctorJson()),
          status: ok(statusJson()),
        ),
      );
      expect(status.state, CompanionState.waitingForFirstEvent);
      expect(status.everSawEvent, isFalse);
      expect(status.state.isWorking, isTrue);
    });

    test('daemon running is active', () {
      final status = classify(
        CompanionProbeResults(
          version: ok(versionJson()),
          doctor: ok(doctorJson(daemon: true)),
          status: ok(
            statusJson(
              source: 'daemon',
              seq: 5,
              agents: [
                agent('a', updatedAt: now.subtract(const Duration(minutes: 3))),
                agent(
                  'b',
                  state: 'ended',
                  updatedAt: now.subtract(const Duration(minutes: 30)),
                ),
              ],
            ),
          ),
        ),
      );
      expect(status.state, CompanionState.active);
      expect(status.daemonRunning, isTrue);
      expect(status.agentCount, 2);
      expect(status.liveAgentCount, 1);
      expect(status.lastEventAt, now.subtract(const Duration(minutes: 3)));
    });

    test('daemon down but an event within 24 h is active', () {
      final status = classify(
        CompanionProbeResults(
          version: ok(versionJson()),
          doctor: ok(doctorJson()),
          status: ok(
            statusJson(
              source: 'snapshot',
              seq: 9,
              agents: [
                agent('a', updatedAt: now.subtract(const Duration(hours: 23))),
              ],
            ),
          ),
        ),
      );
      expect(status.state, CompanionState.active);
      expect(status.daemonRunning, isFalse);
    });

    test('daemon down and last event older than 24 h is waiting', () {
      final status = classify(
        CompanionProbeResults(
          version: ok(versionJson()),
          doctor: ok(doctorJson()),
          status: ok(
            statusJson(
              source: 'snapshot',
              seq: 9,
              agents: [
                agent('a', updatedAt: now.subtract(const Duration(hours: 30))),
              ],
            ),
          ),
        ),
      );
      expect(status.state, CompanionState.waitingForFirstEvent);
      expect(status.everSawEvent, isTrue);
      expect(status.message, contains('last 24 hours'));
    });

    test('older version or protocol is outdated', () {
      final oldVersion = classify(
        CompanionProbeResults(
          version: ok(versionJson(version: '0.1.0')),
          doctor: ok(doctorJson()),
        ),
      );
      expect(oldVersion.state, CompanionState.outdated);
      expect(oldVersion.installedVersion, '0.1.0');

      final oldProtocol = classify(
        CompanionProbeResults(
          version: ok(versionJson(protocol: 0)),
          doctor: ok(doctorJson()),
        ),
      );
      expect(oldProtocol.state, CompanionState.outdated);
      expect(oldProtocol.state.needsInstall, isTrue);
    });

    test('a failing version command is an error with its stderr', () {
      final status = classify(
        CompanionProbeResults(
          version: failed(1, stdout: '{"error":"boom"}', stderr: 'trace'),
        ),
      );
      expect(status.state, CompanionState.error);
      expect(status.errorDetail, contains('boom'));
      expect(status.errorDetail, contains('trace'));
      expect(status.errorDetail, contains('exit 1'));
    });

    test('a doctor that prints no JSON is an error', () {
      final status = classify(
        CompanionProbeResults(
          version: ok(versionJson()),
          doctor: failed(1, stderr: 'SyntaxError: Unexpected token'),
        ),
      );
      expect(status.state, CompanionState.error);
      expect(status.errorDetail, contains('SyntaxError'));
      expect(status.installedVersion, '0.2.0');
    });

    test('an unreachable host is an error', () {
      final status = classify(
        const CompanionProbeResults(connectionError: 'Connection refused'),
      );
      expect(status.state, CompanionState.error);
      expect(status.errorDetail, 'Connection refused');
    });
  });

  test('output shaped like a real 0.2.0 install with a running daemon '
      'classifies as active', () {
    // Mirrors the shape of conductore-hostd on a live host (checked
    // 2026-09-25): 14 doctor checks, all passing, and three agents.
    const names = [
      'node',
      'hook client',
      'conductore-hostd on PATH',
      'conductore-hook on PATH',
      'settings.json',
      'hooks registered',
      'daemon',
      'socket mode',
      'state file',
      'log file',
      'tmux',
      'herdr',
      'claude',
    ];
    final doctor = jsonEncode({
      'ok': true,
      'user': 'user',
      'checks': [
        for (final name in names) {'name': name, 'ok': true, 'detail': '-'},
        {'name': 'log file', 'ok': true, 'detail': '-'},
      ],
    });
    final checkedAt = DateTime(2026, 9, 25, 12);
    final result = classifyCompanionStatus(
      CompanionProbeResults(
        version: ok('{"version":"0.2.0","protocol":1,"node":"22.23.1"}\n'),
        doctor: ok('$doctor\n'),
        status: ok(
          statusJson(
            source: 'daemon',
            seq: 893,
            agents: [
              agent(
                'a',
                updatedAt: checkedAt.subtract(const Duration(minutes: 1)),
              ),
              agent(
                'b',
                state: 'waiting_input',
                updatedAt: checkedAt.subtract(const Duration(minutes: 2)),
              ),
              agent(
                'c',
                state: 'ended',
                updatedAt: checkedAt.subtract(const Duration(minutes: 20)),
              ),
            ],
          ),
        ),
        node: ok('v22.23.1\n'),
        claude: ok('2.1.280 (Claude Code)\n'),
      ),
      now: checkedAt,
    );
    expect(result.state, CompanionState.active);
    expect(result.installedVersion, '0.2.0');
    expect(result.installedProtocol, 1);
    expect(result.daemonRunning, isTrue);
    expect(result.checks, hasLength(14));
    expect(result.agentCount, 3);
    expect(result.liveAgentCount, 2);
    expect(result.nodeSupported, isTrue);
    expect(result.claudeVersion, '2.1.280 (Claude Code)');
  });

  test('compareCompanionVersions compares numerically', () {
    expect(compareCompanionVersions('0.1.10', '0.1.9'), greaterThan(0));
    expect(compareCompanionVersions('0.1.0', '0.1'), 0);
    expect(compareCompanionVersions('v1.0.0-rc1', '1.0.0'), 0);
    expect(
      compareCompanionVersions('0.0.9', kCompanionMinVersion),
      lessThan(0),
    );
  });

  group('CompanionProbe', () {
    test('runs version, node and claude, then doctor and status', () async {
      final runner = MatchingRunner(healthyResponses());
      final status = await CompanionProbe(clock: () => now).check(runner);

      expect(status.state, CompanionState.active);
      expect(status.nodeVersion, '22.1.0');
      expect(runner.commands, hasLength(5));
      expect(runner.ran('conductore-hostd doctor'), isTrue);
      expect(runner.ran('conductore-hostd status'), isTrue);
      // Every command goes through sh with ~/.local/bin on PATH.
      for (final command in runner.commands) {
        expect(command, startsWith("sh -c 'PATH=\"\$HOME/.local/bin:"));
      }
    });

    test('stops after version when the CLI is missing', () async {
      final runner = MatchingRunner({
        'exec node --version': ok('v22.1.0'),
        'conductore-hostd version': notFound,
      });
      final status = await CompanionProbe(clock: () => now).check(runner);
      expect(status.state, CompanionState.notInstalled);
      expect(runner.ran('doctor'), isFalse);
    });

    test('a connection failure becomes an error status', () async {
      final runner = MatchingRunner({
        'conductore-hostd version': const AppFailure(
          'Could not reach box.',
          'Connection refused',
        ),
      });
      final status = await CompanionProbe(clock: () => now).check(runner);
      expect(status.state, CompanionState.error);
      expect(status.errorDetail, contains('Could not reach box.'));
      expect(status.errorDetail, contains('Connection refused'));
    });
  });

  test('checks the companion marks optional (agent adapters) never count '
      'as a failure', () {
    final checks = parseDoctorChecks(
      '{"ok":true,"checks":[{"name":"OpenCode plugin","ok":false,'
      '"detail":"missing: run install","optional":true},'
      '{"name":"hooks registered","ok":true,"detail":"11"}]}',
    );
    expect(checks.first.optional, isTrue);
    expect(checks.first.reportedOptional, isTrue);
    expect(checks.last.optional, isFalse);
  });
}
