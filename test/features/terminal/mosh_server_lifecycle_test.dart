import 'dart:io';
import 'dart:typed_data';

import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/terminal/data/mosh_shutdown.dart';
import 'package:conduit/features/terminal/data/mosh_terminal_repository.dart';
import 'package:conduit/features/terminal/domain/mosh_server_cleanup.dart';
import 'package:conduit/features/terminal/domain/mosh_server_ledger.dart';
import 'package:dart_mosh/dart_mosh.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

const _ok = AgentCommandResult(stdout: '', stderr: '', exitCode: 0);
const _key = 'AAAAAAAAAAAAAAAAAAAAAA';

/// A mosh-server on the loopback that decodes what clients send it and
/// answers what a test tells it to.
class _FakeServer {
  _FakeServer._(this._socket) {
    _socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? datagram;
      while ((datagram = _socket.receive()) != null) {
        _client = (datagram!.address, datagram.port);
        final packet = MoshTransportPacket.decode(
          _cipher.decrypt(datagram.data),
        );
        final assembled = _assembly.add(MoshFragment.decode(packet.payload));
        if (assembled == null) continue;
        final instruction = MoshTransportInstruction.decode(
          moshDecompress(assembled),
        );
        received.add(instruction);
        if (instruction.isShutdown && acknowledges) {
          _send(_ackShutdown);
        }
      }
    });
  }

  static Future<_FakeServer> start() async => _FakeServer._(
    await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0),
  );

  final RawDatagramSocket _socket;
  final _cipher = MoshPacketCipher.aesOcb(MoshKey.parse(_key));
  final _assembly = MoshFragmentAssembly();
  final received = <MoshTransportInstruction>[];
  (InternetAddress, int)? _client;
  var _sequence = 0;
  var _fragment = 0;

  /// Whether it answers a shutdown request, as mosh-server does.
  bool acknowledges = true;

  int get port => _socket.port;

  MoshServerConfig get config =>
      MoshServerConfig(host: '127.0.0.1', port: port, key: MoshKey.parse(_key));

  Iterable<MoshTransportInstruction> get shutdownRequests =>
      received.where((instruction) => instruction.isShutdown);

  /// An instruction acknowledging the client's shutdown: ack `uint64(-1)`.
  static final _ackShutdown = Uint8List.fromList([
    0x08, 2, // protocol version
    0x20, ...List.filled(9, 0xff), 0x01, // ack_num = uint64(-1)
  ]);

  /// Ends the session from the server's side (its shell exited).
  void endSession() =>
      _send(MoshServerShutdown.shutdownInstruction(0)); // new_num = -1

  void _send(Uint8List instruction) {
    final client = _client;
    if (client == null) return;
    for (final fragment in moshFragments(
      _fragment++,
      moshCompress(instruction),
      moshDefaultSendMtu,
    )) {
      _socket.send(
        _cipher.encrypt(
          nonce: _sequence++,
          plaintext: MoshTransportPacket(
            timestamp: 0,
            timestampReply: MoshTransportPacket.noTimestamp,
            payload: fragment.encode(),
          ).encode(),
        ),
        client.$1,
        client.$2,
      );
    }
  }

  void close() => _socket.close();
}

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  const machine = 'user@m:22';

  group('MoshServerLedger', () {
    test('a server held by a session of this run is never abandoned', () async {
      final ledger = MoshServerLedger(InMemoryMoshServerLedgerStore());
      await ledger.record(machine, const MoshServerHandle(port: 1, pid: 10));
      expect(await ledger.abandoned(machine), isEmpty);
    });

    test(
      'one its client let go of is abandoned until it is forgotten',
      () async {
        final ledger = MoshServerLedger(InMemoryMoshServerLedgerStore());
        await ledger.record(machine, const MoshServerHandle(port: 1, pid: 10));
        await ledger.release(machine, 10);
        expect([for (final h in await ledger.abandoned(machine)) h.pid], [10]);
        expect(await ledger.abandoned('user@other:22'), isEmpty);
        await ledger.forget(machine, [10]);
        expect(await ledger.abandoned(machine), isEmpty);
      },
    );

    test('the next app run finds the servers a killed one left', () async {
      final store = InMemoryMoshServerLedgerStore();
      final killed = MoshServerLedger(store);
      await killed.record(machine, const MoshServerHandle(port: 1, pid: 10));
      await killed.record(machine, const MoshServerHandle(port: 2, pid: 11));
      await killed.forget(machine, [11]);

      final next = MoshServerLedger(store);
      expect([for (final h in await next.abandoned(machine)) h.pid], [10]);
    });

    test('servers not seen for twice the idle timeout are dropped', () async {
      var now = DateTime(2026, 10, 5);
      final store = InMemoryMoshServerLedgerStore();
      final ledger = MoshServerLedger(store, clock: () => now);
      await ledger.record(machine, const MoshServerHandle(port: 1, pid: 10));
      await ledger.release(machine, 10);
      now = now.add(moshServerNetworkTimeout * 2 + const Duration(minutes: 1));
      expect(await ledger.abandoned(machine), isEmpty);
      await ledger.record(machine, const MoshServerHandle(port: 1, pid: 12));
      expect([for (final entry in store.entries) entry.pid], [12]);
    });

    test('keeps the newest servers per machine', () async {
      final store = InMemoryMoshServerLedgerStore();
      final ledger = MoshServerLedger(store);
      for (var pid = 0; pid < MoshServerLedger.maxPerMachine + 3; pid++) {
        await ledger.record(machine, MoshServerHandle(port: 1, pid: pid));
      }
      expect(store.entries, hasLength(MoshServerLedger.maxPerMachine));
      expect(store.entries.first.pid, 3);
    });

    test('a server without a pid is not kept (it cannot be ended)', () async {
      final store = InMemoryMoshServerLedgerStore();
      await MoshServerLedger(
        store,
      ).record(machine, const MoshServerHandle(port: 60001));
      expect(store.entries, isEmpty);
    });

    test('entries survive a round trip through JSON', () {
      final entry = MoshServerLedgerEntry(
        machine: machine,
        pid: 10,
        port: 60001,
        seenAt: DateTime.utc(2026, 10, 5, 12),
      );
      final back = MoshServerLedgerEntry.fromJson(entry.toJson())!;
      expect(
        (back.machine, back.pid, back.port, back.seenAt),
        (machine, 10, 60001, DateTime.utc(2026, 10, 5, 12)),
      );
      expect(MoshServerLedgerEntry.fromJson({'pid': 'x'}), isNull);
    });

    test('machineOf: the user, host and SSH port', () {
      expect(
        MoshServerLedger.machineOf(
          buildHost('a').copyWith(host: ' Box.LAN ', port: 2222),
        ),
        'user@box.lan:2222',
      );
    });
  });

  test('the shutdown request decodes as mosh-server reads it', () {
    final instruction = MoshTransportInstruction.decode(
      MoshServerShutdown.shutdownInstruction(5),
    );
    expect(instruction.protocolVersion, moshProtocolVersion);
    expect(instruction.oldNum, 5);
    expect(instruction.isShutdown, isTrue);
    expect(instruction.ackNum, 0);
    expect(instruction.throwawayNum, 0);
  });

  group('MoshTerminalSession.close', () {
    late _FakeServer server;
    late MoshServerLedger ledger;
    late InMemoryMoshServerLedgerStore store;
    const handle = MoshServerHandle(port: 60001, pid: 4242);

    setUp(() async {
      server = await _FakeServer.start();
      store = InMemoryMoshServerLedgerStore();
      ledger = MoshServerLedger(store);
      await ledger.record(machine, handle);
    });
    tearDown(() => server.close());

    Future<MoshTerminalSession> open({
      AgentCommandRunner Function()? cleanupRunner,
      bool shutdown = true,
    }) async {
      final cipher = MoshPacketCipher.aesOcb(MoshKey.parse(_key));
      final session = MoshTerminalSession(
        await MoshSession.connect(
          server: server.config,
          cipher: cipher,
          address: InternetAddress.loopbackIPv4,
        ),
        server: handle,
        cleanupRunner: cleanupRunner,
        shutdown: shutdown
            ? await MoshServerShutdown.bind(
                address: InternetAddress.loopbackIPv4,
                port: server.port,
                cipher: cipher,
              )
            : null,
        ledger: ledger,
        machine: machine,
      );
      // The client's first packet: the server knows where it is.
      await _until(() => server.received.isNotEmpty);
      return session;
    }

    test('asks the server to end, which answers: nothing else to do', () async {
      final runner = ScriptedAgentCommandRunner([_ok]);
      final session = await open(cleanupRunner: () => runner);
      await session.close();
      await session.serverSettled;

      final request = server.shutdownRequests.first;
      expect(request.oldNum, 0);
      expect(runner.commands, isEmpty);
      expect(store.entries, isEmpty);
    });

    test('no answer: the server is stopped over SSH', () async {
      server.acknowledges = false;
      final runner = ScriptedAgentCommandRunner([_ok]);
      final session = await open(cleanupRunner: () => runner);
      await session.close();
      await session.serverSettled;

      expect(server.shutdownRequests, isNotEmpty);
      expect(runner.commands.single, handle.killCommand());
      expect(store.entries, isEmpty);
    });

    test('no answer and no SSH: left for the next connection to end', () async {
      server.acknowledges = false;
      final session = await open(
        cleanupRunner: () =>
            ScriptedAgentCommandRunner([StateError('unreachable')]),
      );
      await session.close();
      await session.serverSettled;

      expect([for (final h in await ledger.abandoned(machine)) h.pid], [4242]);
    });

    test('a server that ended the session itself is not asked again', () async {
      final runner = ScriptedAgentCommandRunner([_ok]);
      final session = await open(cleanupRunner: () => runner);
      server.endSession();
      await session.done.timeout(const Duration(seconds: 5));
      await session.close();
      await session.serverSettled;

      expect(server.shutdownRequests, isEmpty);
      expect(runner.commands, isEmpty);
      expect(store.entries, isEmpty);
    });

    test('is based on the newest input states the server may hold', () async {
      final session = await open();
      session.sendWithInputState([0x61]);
      session.sendWithInputState([0x62]);
      await session.close();
      await session.serverSettled;

      expect(
        {for (final request in server.shutdownRequests) request.oldNum},
        {2, 1, 0},
      );
    });
  });

  group('MoshTerminalRepository.connect', () {
    late _FakeServer server;
    setUp(() async => server = await _FakeServer.start());
    tearDown(() => server.close());

    test('ends the abandoned servers in the bootstrap, records the new one, '
        'and its close ends it', () async {
      final host = buildHost('m').copyWith(host: '127.0.0.1', useMosh: true);
      final machine = MoshServerLedger.machineOf(host);
      final store = InMemoryMoshServerLedgerStore();
      final killed = MoshServerLedger(store);
      await killed.record(machine, const MoshServerHandle(port: 60001, pid: 7));

      final ledger = MoshServerLedger(store);
      final runner = ScriptedAgentCommandRunner([
        AgentCommandResult(
          stdout: 'MOSH CONNECT ${server.port} $_key\n',
          stderr: '[mosh-server detached, pid = 8]\n',
          exitCode: 0,
        ),
      ]);
      final repository = MoshTerminalRepository(
        NoopVerifier(),
        cleanupRunner: (_) => runner,
        ledger: ledger,
      );

      final session =
          await repository.connect(host, columns: 80, rows: 24)
              as MoshTerminalSession;

      expect(
        runner.commands.single,
        MoshTerminalRepository.bootstrapCommand(
          host,
          abandoned: const [MoshServerHandle(port: 60001, pid: 7)],
        ),
      );
      expect([for (final entry in store.entries) entry.pid], [8]);
      expect(await ledger.abandoned(machine), isEmpty);
      expect(session.server?.pid, 8);

      await _until(() => server.received.isNotEmpty);
      await session.close();
      await session.serverSettled;
      expect(server.shutdownRequests, isNotEmpty);
      expect(store.entries, isEmpty);
    });
  });
}
