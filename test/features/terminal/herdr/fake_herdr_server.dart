import 'dart:async';
import 'dart:convert';

import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/terminal/domain/ssh_terminal_repository.dart';
import 'package:conduit/features/terminal/domain/ssh_terminal_session.dart';

/// A tiny stateful Herdr server: `workspace focus`, `tab focus` and
/// `agent focus` move the focus, and `workspace list` reports it, so tests
/// can check where a sequence of commands leaves Herdr.
class FakeHerdrServer {
  FakeHerdrServer({
    this.workspaces = const ['w1', 'w2', 'w3'],
    this.focusedWorkspace = 'w1',
  });

  final List<String> workspaces;
  String focusedWorkspace;
  String focusedTab = '';
  String focusedPane = '';
  final List<String> commands = [];
  int runnersOpened = 0;
  int runnersClosed = 0;

  /// The herdr arguments of each command, without the PATH wrapper.
  List<String> get herdrArgs => [
    for (final command in commands)
      RegExp(r"exec herdr ([^']*)").firstMatch(command)?.group(1) ?? command,
  ];

  AgentCommandRunner runner() {
    runnersOpened += 1;
    return _FakeHerdrServerRunner(this);
  }

  AgentCommandResult handle(String command) {
    commands.add(command);
    final args = RegExp(r"exec herdr ([^']*)").firstMatch(command)?.group(1);
    if (args == null) {
      return const AgentCommandResult(stdout: '', stderr: '', exitCode: 0);
    }
    final parts = args.split(' ');
    if (args.contains('workspace list')) {
      final items = [
        for (final (index, id) in workspaces.indexed)
          '{"workspace_id":"$id","label":"W$id","number":${index + 1},'
              '"focused":${id == focusedWorkspace},"tab_count":1,'
              '"active_tab_id":"$id:t1"}',
      ];
      return AgentCommandResult(
        stdout: '{"result":{"workspaces":[${items.join(',')}]}}',
        stderr: '',
        exitCode: 0,
      );
    }
    if (args.contains('workspace focus')) {
      final id = parts.last;
      if (!workspaces.contains(id)) {
        return _notFound;
      }
      focusedWorkspace = id;
    } else if (args.contains('tab focus')) {
      focusedTab = parts.last;
      focusedWorkspace = focusedTab.split(':').first;
    } else if (args.contains('agent focus')) {
      focusedPane = parts.last;
      focusedWorkspace = focusedPane.split(':').first;
    }
    return const AgentCommandResult(stdout: '{}', stderr: '', exitCode: 0);
  }

  static const _notFound = AgentCommandResult(
    stdout: '{"error":{"code":"workspace_not_found"}}',
    stderr: '',
    exitCode: 1,
  );
}

class _FakeHerdrServerRunner implements AgentCommandRunner {
  _FakeHerdrServerRunner(this._server);

  final FakeHerdrServer _server;

  @override
  Future<AgentCommandResult> run(
    String command, {
    required Duration timeout,
  }) async => _server.handle(command);

  @override
  Future<void> close() async {
    _server.runnersClosed += 1;
  }
}

/// A [FakeHerdrServer] whose clients share its focus the way Herdr 0.9.1's
/// do: every app session connected through [clients] types into whichever
/// workspace is focused right now, and a session's startup command
/// (`herdr workspace focus <id>; herdr`) moves that focus as it attaches.
///
/// [events] logs focus changes and typed text in order ("focus w1",
/// "type w1: ls"), so tests can check that a focus came before the input.
class SharedFocusHerdrServer extends FakeHerdrServer {
  SharedFocusHerdrServer({super.workspaces, super.focusedWorkspace});

  final List<String> events = [];

  /// Text typed into each workspace.
  final Map<String, String> typed = {};

  Completer<void>? _focusGate;

  /// Focus commands wait until [releaseFocus]: the round trip is in flight.
  void holdFocus() => _focusGate ??= Completer<void>();

  void releaseFocus() {
    _focusGate?.complete();
    _focusGate = null;
  }

  /// Another client (the laptop) focuses [workspaceId].
  void focusFromElsewhere(String workspaceId) {
    focusedWorkspace = workspaceId;
    events.add('focus $workspaceId (elsewhere)');
  }

  /// The terminal connections of the app's sessions.
  SshTerminalRepository get clients => _SharedFocusClients(this);

  static final _startupFocus = RegExp(
    r"herdr (?:--session \S+ )?workspace focus '?([^' ]+)'?",
  );

  void _receive(String data) {
    final startup = _startupFocus.firstMatch(data);
    if (startup != null) {
      final id = startup.group(1)!;
      if (workspaces.contains(id)) {
        focusedWorkspace = id;
        events.add('focus $id (attach)');
      }
      return;
    }
    typed[focusedWorkspace] = (typed[focusedWorkspace] ?? '') + data;
    events.add('type $focusedWorkspace: $data');
  }

  @override
  AgentCommandRunner runner() {
    runnersOpened += 1;
    return _GatedRunner(this);
  }

  @override
  AgentCommandResult handle(String command) {
    final result = super.handle(command);
    if (command.contains('workspace focus') && result.exitCode == 0) {
      events.add('focus $focusedWorkspace');
    }
    return result;
  }
}

class _GatedRunner implements AgentCommandRunner {
  _GatedRunner(this._server);

  final SharedFocusHerdrServer _server;

  @override
  Future<AgentCommandResult> run(
    String command, {
    required Duration timeout,
  }) async {
    final gate = _server._focusGate;
    if (gate != null && command.contains('focus')) await gate.future;
    return _server.handle(command);
  }

  @override
  Future<void> close() async {
    _server.runnersClosed += 1;
  }
}

class _SharedFocusClients implements SshTerminalRepository {
  _SharedFocusClients(this._server);

  final SharedFocusHerdrServer _server;

  @override
  Future<SshTerminalSession> connect(
    SavedHost host, {
    required int columns,
    required int rows,
  }) async => _SharedFocusClient(_server);
}

class _SharedFocusClient implements SshTerminalSession {
  _SharedFocusClient(this._server);

  final SharedFocusHerdrServer _server;
  final _done = Completer<void>();

  @override
  Future<void> get done => _done.future;

  @override
  Stream<List<int>> get stderr => const Stream.empty();

  @override
  Stream<List<int>> get stdout => const Stream.empty();

  @override
  Future<void> close() async {
    if (!_done.isCompleted) _done.complete();
  }

  @override
  void resize(int columns, int rows, int pixelWidth, int pixelHeight) {}

  @override
  Future<void> send(List<int> data) async =>
      _server._receive(utf8.decode(data));
}
