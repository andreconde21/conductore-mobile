// Counts the mosh-servers a real machine is left with across the session
// lifecycle (CON-086). Opt-in: it needs a throwaway sshd + mosh container,
// see docs/mosh-sessions.md. Skipped unless CONDUCTORE_MOSH_DOCKER names
// one (`<container>@<ip>`) and CONDUCTORE_MOSH_KEY its private key.
@Tags(['docker'])
library;

import 'dart:async';
import 'dart:io';

import 'package:conduit/features/agent_attention/data/ssh_agent_command_runner.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:conduit/features/terminal/data/mosh_terminal_repository.dart';
import 'package:conduit/features/terminal/domain/host_key_verifier.dart';
import 'package:conduit/features/terminal/domain/mosh_server_ledger.dart';
import 'package:conduit/features/terminal/domain/network_connectivity.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final target = Platform.environment['CONDUCTORE_MOSH_DOCKER'];
  final keyPath = Platform.environment['CONDUCTORE_MOSH_KEY'];
  final skip = target == null || keyPath == null
      ? 'needs CONDUCTORE_MOSH_DOCKER and CONDUCTORE_MOSH_KEY'
      : null;
  final container = target?.split('@').first ?? '';
  final address = target?.split('@').last ?? '';

  // Stands for the app's stored ledger, which outlives a killed app; each
  // app run has a ledger of its own on top of it.
  final store = InMemoryMoshServerLedgerStore();
  var ledger = MoshServerLedger(store);

  SavedHost machine() => SavedHost(
    id: 'docker',
    name: 'docker',
    host: address,
    port: 22,
    username: 'dev',
    authMethod: SshAuthMethod.privateKey,
    privateKey: File(keyPath!).readAsStringSync(),
    useMosh: true,
  );

  MoshTerminalRepository repository({bool sideChannel = true}) =>
      MoshTerminalRepository(
        _TrustingVerifier(),
        cleanupRunner: sideChannel
            ? (host) => SshAgentCommandRunner(_TrustingVerifier(), host)
            : null,
        ledger: ledger,
      );

  Future<String> exec(String script) async {
    final result = await Process.run('docker', [
      'exec',
      container,
      'sh',
      '-c',
      script,
    ]);
    return result.stdout as String;
  }

  Future<int> count() async =>
      int.parse((await exec('pgrep -c -x mosh-server || true')).trim());

  /// The mosh-servers left once those told to end had [settle] to do so
  /// (one ending on SIGTERM first tries to tell its client, for a while).
  Future<int> servers({
    int atMost = 0,
    Duration settle = const Duration(seconds: 20),
  }) async {
    final deadline = DateTime.now().add(settle);
    await Future<void>.delayed(const Duration(seconds: 2));
    var left = await count();
    while (left > atMost && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      left = await count();
    }
    return left;
  }

  // A dead network: the container drops every packet but its loopback's.
  Future<void> dropNetwork() => exec(
    'iptables -I INPUT ! -i lo -j DROP && iptables -I OUTPUT ! -o lo -j DROP',
  );
  Future<void> restoreNetwork() =>
      exec('iptables -F INPUT; iptables -F OUTPUT');

  Future<TerminalSessionController> connected(
    TerminalWorkspaceController workspace,
    SavedHost host,
  ) async {
    // A Herdr session runs a Herdr client, as the app's connect flow does.
    final session = workspace.open(
      host,
      startupCommand: host.id.contains(ConnectTarget.idSeparator)
          ? 'herdr'
          : null,
    );
    await session.connect();
    expect(
      session.status,
      TerminalConnectionStatus.connected,
      reason: session.terminal.buffer.getText(),
    );
    return session;
  }

  final results = <String>[];
  tearDownAll(() {
    // ignore: avoid_print
    print(results.join('\n'));
  });

  for (final (label, host) in [
    ('shell', machine),
    (
      'herdr',
      () => const ConnectTarget.herdr(workspaceId: 'w1').apply(machine()),
    ),
  ]) {
    group(label, () {
      final workspaces = <TerminalWorkspaceController>[];
      final networkChanges = StreamController<void>.broadcast();
      TerminalWorkspaceController workspace({bool sideChannel = true}) {
        final created = TerminalWorkspaceController(
          repository(sideChannel: sideChannel),
          _Connectivity(networkChanges.stream),
        );
        workspaces.add(created);
        return created;
      }

      setUp(() async {
        await restoreNetwork();
        await exec('pkill -KILL -x mosh-server; true');
        store.entries.clear();
        ledger = MoshServerLedger(store);
      });
      tearDown(() async {
        await restoreNetwork();
        for (final created in workspaces) {
          created.dispose();
        }
        workspaces.clear();
      });

      /// Runs [body] on a machine with no mosh-server and checks that
      /// [expected] are left: one per session still open.
      void step(String name, int expected, Future<void> Function() body) =>
          test(
            name,
            () async {
              expect(await servers(), 0);
              await body();
              final left = await servers();
              results.add(
                '$label / $name: $left mosh-server(s), $expected expected',
              );
              expect(left, expected);
            },
            skip: skip,
            timeout: const Timeout(Duration(minutes: 2)),
          );

      step('connect', 1, () async {
        await connected(workspace(), host());
        if (label == 'herdr') {
          // Its client runs in the session.
          await Future<void>.delayed(const Duration(seconds: 2));
          expect(await exec('pgrep -u dev -x herdr || true'), isNotEmpty);
        }
      });

      step('reconnect after a network drop', 1, () async {
        final session = await connected(workspace(), host());
        await dropNetwork();
        // Reconnect while the old server cannot be reached...
        await session.disconnect();
        // ...and the network comes back for the new connection.
        await restoreNetwork();
        await session.connect();
        expect(session.status, TerminalConnectionStatus.connected);
      });

      step('network change (roaming)', 1, () async {
        final session = await connected(workspace(), host());
        await dropNetwork();
        await Future<void>.delayed(const Duration(seconds: 2));
        await restoreNetwork();
        networkChanges.add(null);
        expect(session.status, TerminalConnectionStatus.connected);
      });

      step('suspend and resume', 1, () async {
        final session = await connected(workspace(), host());
        // A suspended app sends nothing; the network is fine.
        await exec('iptables -I INPUT -p udp -j DROP');
        await Future<void>.delayed(const Duration(seconds: 3));
        await restoreNetwork();
        session.forceResize();
      });

      step('app killed, then restored', 1, () async {
        // The app goes away without closing anything (iOS kills it in
        // the background): its client is never closed and goes silent...
        final killed = workspace();
        await connected(killed, host());
        await exec('iptables -I INPUT -p udp -j DROP');
        // ...and the next run opens the session again.
        ledger = MoshServerLedger(store);
        await connected(workspace(), host());
        await restoreNetwork();
      });

      step('close', 0, () async {
        final opened = workspace();
        await opened.close(await connected(opened, host()));
      });

      step('close, ended by the Mosh shutdown request alone', 0, () async {
        // No SSH command channel to stop the server with.
        final opened = workspace(sideChannel: false);
        await opened.close(await connected(opened, host()));
        // The server answered the request: the ledger forgot it.
        await Future<void>.delayed(MoshTerminalSession.shutdownAckTimeout);
        expect(store.entries, isEmpty);
      });

      step('5 quick open/close cycles', 0, () async {
        final opened = workspace();
        for (var i = 0; i < 5; i++) {
          final quick = opened.open(host());
          final connecting = quick.connect();
          if (i.isEven) {
            // Closed while it is still connecting.
            await opened.close(quick);
            await connecting;
          } else {
            await connecting;
            await opened.close(quick);
          }
        }
      });
    });
  }
}

/// The throwaway container's host key is new on every run.
class _TrustingVerifier implements HostKeyVerifier {
  @override
  Future<List<HostKeyRecord>> loadTrustedKeys() async => const [];

  @override
  Future<void> saveTrustedKeys(List<HostKeyRecord> records) async {}

  @override
  Future<void> removeTrustedKey(String host, int port) async {}

  @override
  Future<bool> verify({
    required String host,
    required int port,
    required String type,
    required String fingerprint,
  }) async => true;
}

class _Connectivity implements NetworkConnectivity {
  _Connectivity(this.onNetworkChanged);

  @override
  final Stream<void> onNetworkChanged;
}
