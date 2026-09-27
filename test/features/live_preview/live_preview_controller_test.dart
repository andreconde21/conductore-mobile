import 'dart:async';

import 'package:conduit/core/app_failure.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/live_preview/domain/live_preview_port_store.dart';
import 'package:conduit/features/live_preview/domain/port_forward.dart';
import 'package:conduit/features/live_preview/presentation/live_preview_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

class FakeLocalPortForward implements LocalPortForward {
  FakeLocalPortForward(this.remotePort, this.localPort);

  @override
  final int remotePort;

  @override
  final int localPort;

  final errors = StreamController<String>.broadcast();
  bool closed = false;

  @override
  Stream<String> get connectionErrors => errors.stream;

  @override
  Future<void> close() async {
    closed = true;
    await errors.close();
  }
}

class FakePortForwarder implements PortForwarder {
  final List<int> requested = [];
  final List<FakeLocalPortForward> opened = [];
  final Set<int> refused = {};
  AppFailure? failure;
  Completer<void>? gate;
  int nextLocalPort = 40000;
  bool closed = false;

  @override
  Future<LocalPortForward> open(int remotePort) async {
    requested.add(remotePort);
    await gate?.future;
    final failure = this.failure;
    if (failure != null) {
      throw failure;
    }
    if (refused.contains(remotePort)) {
      throw AppFailure('Nothing is listening on port $remotePort on Host h.');
    }
    final forward = FakeLocalPortForward(remotePort, nextLocalPort++);
    opened.add(forward);
    return forward;
  }

  @override
  Future<void> close() async => closed = true;
}

class FakeSession extends ChangeNotifier {
  bool connected = true;

  void disconnect() {
    connected = false;
    notifyListeners();
  }
}

void main() {
  late FakePortForwarder forwarder;
  late InMemoryLivePreviewPortStore store;
  late LivePreviewController controller;

  setUp(() {
    forwarder = FakePortForwarder();
    store = InMemoryLivePreviewPortStore();
    controller = LivePreviewController(
      forwarder,
      hostId: 'h',
      portStore: store,
    );
  });

  test(
    'suggestedPort falls back to 3000 and then to the remembered port',
    () async {
      expect(await controller.suggestedPort(), livePreviewDefaultPort);
      await controller.start(5173);
      expect(await controller.suggestedPort(), 5173);
      expect(store.ports['h'], 5173);
    },
  );

  test('start opens the forward and exposes the loopback URL', () async {
    final phases = <LivePreviewPhase>[];
    controller.addListener(() => phases.add(controller.phase));
    await controller.start(3000);
    expect(phases, [LivePreviewPhase.connecting, LivePreviewPhase.ready]);
    expect(forwarder.requested, [3000]);
    expect(controller.localPort, 40000);
    expect(controller.url, Uri.parse('http://127.0.0.1:40000/'));
    controller.setPath('about?x=1');
    expect(controller.url, Uri.parse('http://127.0.0.1:40000/about?x=1'));
  });

  test('a WebView report after the tab closed is ignored', () async {
    await controller.start(3000);
    controller.dispose();
    // A disposed ChangeNotifier asserts when it notifies.
    expect(() => controller.setPath('/late'), returnsNormally);
  });

  test('a refused port fails with the forwarder message', () async {
    forwarder.refused.add(9999);
    await controller.start(9999);
    expect(controller.phase, LivePreviewPhase.failed);
    expect(controller.error, 'Nothing is listening on port 9999 on Host h.');
    expect(controller.url, isNull);
  });

  test(
    'a connection failure shows why the host could not be reached',
    () async {
      forwarder.failure = const AppFailure(
        'Could not reach Host h.',
        'Authentication failed. Check the username and key.',
      );
      await controller.start(3000);
      expect(controller.phase, LivePreviewPhase.failed);
      expect(
        controller.error,
        'Could not reach Host h.\n'
        'Authentication failed. Check the username and key.',
      );
    },
  );

  test('out-of-range ports are rejected without touching the host', () async {
    await controller.start(70000);
    expect(controller.phase, LivePreviewPhase.failed);
    expect(forwarder.requested, isEmpty);
  });

  test('starting again closes the previous forward', () async {
    await controller.start(3000);
    final first = forwarder.opened.single;
    await controller.start(8080);
    expect(first.closed, isTrue);
    expect(controller.remotePort, 8080);
    expect(controller.localPort, 40001);
  });

  test('a superseded start does not leak its forward', () async {
    forwarder.gate = Completer<void>();
    final slow = controller.start(3000);
    forwarder.gate = null;
    await controller.start(8080);
    final gate = Completer<void>();
    // Release the first start now that the second has landed.
    forwarder.gate = gate;
    forwarder.gate = null;
    gate.complete();
    await slow;
    expect(controller.remotePort, 8080);
    expect(
      forwarder.opened
          .where((forward) => forward.remotePort == 3000)
          .single
          .closed,
      isTrue,
    );
  });

  test('restart re-opens the current port after a failure', () async {
    forwarder.refused.add(3000);
    await controller.start(3000);
    expect(controller.phase, LivePreviewPhase.failed);
    forwarder.refused.clear();
    await controller.restart();
    expect(controller.phase, LivePreviewPhase.ready);
    expect(forwarder.requested, [3000, 3000]);
  });

  test('stop closes the forward and keeps the reason', () async {
    await controller.start(3000);
    await controller.stop(reason: 'Done.');
    expect(controller.phase, LivePreviewPhase.closed);
    expect(controller.error, 'Done.');
    expect(forwarder.opened.single.closed, isTrue);
    expect(controller.url, isNull);
  });

  test('a session disconnect closes the forward', () async {
    final session = FakeSession();
    controller.attachSession(session, () => session.connected);
    await controller.start(3000);
    session.disconnect();
    await Future<void>.delayed(Duration.zero);
    expect(controller.phase, LivePreviewPhase.closed);
    expect(controller.error, 'The session disconnected.');
    expect(forwarder.opened.single.closed, isTrue);
  });

  test('connection errors surface and can be cleared', () async {
    await controller.start(3000);
    forwarder.opened.single.errors.add('Port 3000 refused the connection.');
    await Future<void>.delayed(Duration.zero);
    expect(controller.connectionError, 'Port 3000 refused the connection.');
    controller.clearConnectionError();
    expect(controller.connectionError, isNull);
  });

  test('detectPorts parses ss output and swallows failures', () async {
    final runner = ScriptedAgentCommandRunner([
      const AgentCommandResult(
        stdout: 'LISTEN 0 1 0.0.0.0:3000 0.0.0.0:*\n',
        stderr: '',
        exitCode: 0,
      ),
      const AppFailure('unreachable'),
    ]);
    controller = LivePreviewController(
      forwarder,
      hostId: 'h',
      portStore: store,
      commandRunner: runner,
    );
    final ports = await controller.detectPorts();
    expect(ports.single.port, 3000);
    expect(runner.commands.single, contains('ss -ltn'));
    expect(await controller.detectPorts(), isEmpty);
  });

  test('without a runner detectPorts is empty', () async {
    expect(await controller.detectPorts(), isEmpty);
  });

  test('normalizePath always yields a leading slash and drops the origin', () {
    expect(LivePreviewController.normalizePath(''), '/');
    expect(LivePreviewController.normalizePath('about'), '/about');
    expect(LivePreviewController.normalizePath('/a?b=1'), '/a?b=1');
    expect(
      LivePreviewController.normalizePath('http://127.0.0.1:4000/x?y=2'),
      '/x?y=2',
    );
    expect(LivePreviewController.normalizePath('http://localhost:3000'), '/');
  });

  test('dispose closes the forward, the forwarder and the runner', () async {
    final runner = ScriptedAgentCommandRunner([]);
    controller = LivePreviewController(
      forwarder,
      hostId: 'h',
      portStore: store,
      commandRunner: runner,
    );
    await controller.start(3000);
    controller.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(forwarder.opened.single.closed, isTrue);
    expect(forwarder.closed, isTrue);
    expect(runner.closeCount, 1);
  });
}
