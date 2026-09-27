import 'dart:io';

import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/sftp/data/dart_ssh_sftp_repository.dart';
import 'package:conduit/features/terminal/data/dart_ssh_terminal_repository.dart';
import 'package:conduit/features/terminal/data/mosh_terminal_repository.dart';
import 'package:conduit/features/terminal/data/ssh_client_factory.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

/// A server that accepts TCP connections but never sends an SSH banner.
class _SilentServer {
  late final ServerSocket _server;
  final sockets = <Socket>[];
  final closed = <Socket>{};

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((socket) {
      sockets.add(socket);
      socket.listen(
        (_) {},
        onDone: () => closed.add(socket),
        onError: (_) => closed.add(socket),
      );
    });
  }

  SavedHost host() => buildHost('h').copyWith(
    host: '127.0.0.1',
    port: _server.port,
    password: 'x',
    connectionTimeoutSeconds: 3,
  );

  Future<void> stop() async {
    for (final s in sockets) {
      s.destroy();
    }
    await _server.close();
  }
}

Future<void> _expectGivesUp(
  Future<Object?> Function(SavedHost host) connect,
) async {
  final server = _SilentServer();
  await server.start();
  addTearDown(server.stop);
  final sw = Stopwatch()..start();
  await expectLater(connect(server.host()), throwsA(anything));
  expect(sw.elapsed, lessThan(const Duration(seconds: 8)));
  await Future<void>.delayed(const Duration(milliseconds: 200));
  // The connection is closed, not left open.
  expect(server.sockets, hasLength(1));
  expect(server.closed, contains(server.sockets.single));
}

void main() {
  test(
    'a terminal gives up on a server that never speaks SSH',
    () async {
      await _expectGivesUp(
        (host) => DartSshTerminalRepository(
          NoopVerifier(),
        ).connect(host, columns: 80, rows: 24),
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'a Mosh bootstrap gives up on a server that never speaks SSH',
    () async {
      await _expectGivesUp(
        (host) => MoshTerminalRepository(
          NoopVerifier(),
        ).connect(host, columns: 80, rows: 24),
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'SFTP gives up on a server that never speaks SSH',
    () async {
      await _expectGivesUp(
        (host) => DartSshSftpRepository(NoopVerifier()).connect(host),
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test('sign-ins that wait on the user get longer', () {
    final host = buildHost('h').copyWith(connectionTimeoutSeconds: 12);
    expect(SshClientFactory.setupTimeoutFor(host), const Duration(seconds: 12));
    expect(
      SshClientFactory.setupTimeoutFor(
        host.copyWith(authMethod: SshAuthMethod.hardwareKey),
      ),
      SshClientFactory.interactiveSetupTimeout,
    );
  });
}
