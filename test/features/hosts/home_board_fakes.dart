import 'dart:convert';

import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';

/// Canned `herdr` output for the home board tests.
abstract final class HerdrFixtures {
  static const workspaces =
      '{"id":"1","result":{"workspaces":['
      '{"workspace_id":"w1","label":"Infrastructure","number":1,'
      '"agent_status":"working","focused":true,"tab_count":2,'
      '"active_tab_id":"w1:t1"},'
      '{"workspace_id":"w2","label":"TheCalendar","number":2,'
      '"agent_status":"idle","tab_count":1}]}}';

  static const tabs =
      '{"id":"2","result":{"tabs":['
      '{"tab_id":"w1:t1","workspace_id":"w1","label":"main","number":1},'
      '{"tab_id":"w1:t2","workspace_id":"w1","label":"review","number":2},'
      '{"tab_id":"w2:t1","workspace_id":"w2","label":"","number":1}]}}';

  static const agents =
      '{"id":"3","result":{"agents":['
      '{"agent":"claude","pane_id":"w1:p2","tab_id":"w1:t2",'
      '"workspace_id":"w1","agent_status":"blocked",'
      '"terminal_title_stripped":"Proofing PR 398"},'
      '{"agent":"claude","pane_id":"w1:p1","tab_id":"w1:t1",'
      '"workspace_id":"w1","agent_status":"working",'
      '"terminal_title_stripped":"Deploying images"},'
      '{"agent":"codex","pane_id":"w2:p1","tab_id":"w2:t1",'
      '"workspace_id":"w2","agent_status":"done",'
      '"terminal_title_stripped":"Nightly E2E"}]}}';

  static const notRunning =
      '{"error":{"code":"server_not_running","message":"no server"}}';
}

/// Canned `tmux` output (tab-separated `list-sessions` / `list-windows`).
abstract final class TmuxFixtures {
  static const sessions =
      'main\t1\t3\t1790229500\n'
      'build\t0\t1\t1790229600\n';

  static const windows =
      '0\tzsh\t1\t0\n'
      '1\tclaude\t2\t1\n'
      '2\tlogs\t1\t0\n';

  static const noServer = 'no server running on /tmp/tmux-1000/default';
}

/// Herdr answers of a machine without Herdr (`command not found`).
abstract final class HerdrMissing {
  static const stderr = 'sh: 1: herdr: not found';
  static const exitCode = 127;
}

/// Answers `herdr` and `tmux` commands by what they ask for; records every
/// command.
class HerdrFakeRunner implements AgentCommandRunner {
  HerdrFakeRunner({
    this.workspaces = HerdrFixtures.workspaces,
    this.tabs = HerdrFixtures.tabs,
    this.agents = HerdrFixtures.agents,
    this.workspaceExitCode = 0,
    this.workspaceStderr = '',
    this.tmuxSessions = '',
    this.tmuxExitCode = 0,
    this.tmuxStderr = '',
    this.tmuxWindows = TmuxFixtures.windows,
    this.error,
  });

  /// A machine with tmux only: Herdr is not installed.
  HerdrFakeRunner.tmuxOnly({this.tmuxSessions = TmuxFixtures.sessions})
    : workspaces = '',
      tabs = '',
      agents = '',
      workspaceExitCode = HerdrMissing.exitCode,
      workspaceStderr = HerdrMissing.stderr,
      tmuxExitCode = 0,
      tmuxStderr = '',
      tmuxWindows = TmuxFixtures.windows;

  String workspaces;
  String tabs;
  String agents;
  int workspaceExitCode;
  String workspaceStderr;
  String tmuxSessions;
  int tmuxExitCode;
  String tmuxStderr;
  String tmuxWindows;

  /// Thrown by every call when set (a dead connection).
  Object? error;

  final List<String> commands = [];
  int closeCount = 0;

  @override
  Future<AgentCommandResult> run(
    String command, {
    required Duration timeout,
  }) async {
    commands.add(command);
    final failure = error;
    if (failure != null) {
      // ignore: only_throw_errors
      throw failure;
    }
    if (command.startsWith('tmux -u list-sessions')) {
      return AgentCommandResult(
        stdout: tmuxSessions,
        stderr: tmuxStderr,
        exitCode: tmuxExitCode,
      );
    }
    if (command.startsWith('tmux list-windows')) {
      return AgentCommandResult(stdout: tmuxWindows, stderr: '', exitCode: 0);
    }
    if (command.contains('workspace list')) {
      return AgentCommandResult(
        stdout: workspaces,
        stderr: workspaceStderr,
        exitCode: workspaceExitCode,
      );
    }
    if (workspaceExitCode == HerdrMissing.exitCode &&
        command.contains('herdr')) {
      return AgentCommandResult(
        stdout: '',
        stderr: workspaceStderr,
        exitCode: workspaceExitCode,
      );
    }
    if (command.contains('tab list')) {
      return AgentCommandResult(stdout: tabs, stderr: '', exitCode: 0);
    }
    if (command.contains('agent list')) {
      return AgentCommandResult(stdout: agents, stderr: '', exitCode: 0);
    }
    return const AgentCommandResult(stdout: '', stderr: '', exitCode: 0);
  }

  @override
  Future<void> close() async {
    closeCount += 1;
  }
}

/// A companion that pushes Herdr and tmux (`status --live`), showing the
/// same board as [HerdrFixtures] and [TmuxFixtures].
abstract final class LiveFixtures {
  static const entities =
      '{"srv:herdr":{"kind":"server","id":"herdr","type":"herdr",'
      '"default":true,"session":"","state":"up","mode":"events"},'
      '"srv:tmux":{"kind":"server","id":"tmux","type":"tmux","default":true,'
      '"session":"","state":"up","mode":"control"},'
      '"ws:herdr:w1":{"kind":"workspace","server":"herdr","id":"w1",'
      '"label":"Infrastructure","number":1,"focused":true,'
      '"agentStatus":"working","activeTabId":"w1:t1","tabCount":2},'
      '"ws:herdr:w2":{"kind":"workspace","server":"herdr","id":"w2",'
      '"label":"TheCalendar","number":2,"focused":false,'
      '"agentStatus":"idle","activeTabId":"w2:t1","tabCount":1},'
      '"tab:herdr:w1:t1":{"kind":"tab","server":"herdr","id":"w1:t1",'
      '"workspaceId":"w1","label":"main","number":1,"focused":true,'
      '"agentStatus":"working","paneCount":1},'
      '"tab:herdr:w1:t2":{"kind":"tab","server":"herdr","id":"w1:t2",'
      '"workspaceId":"w1","label":"review","number":2,"focused":false,'
      '"agentStatus":"blocked","paneCount":1},'
      '"tab:herdr:w2:t1":{"kind":"tab","server":"herdr","id":"w2:t1",'
      '"workspaceId":"w2","label":"","number":1,"focused":false,'
      '"agentStatus":"done","paneCount":1},'
      '"pane:herdr:w1:p1":{"kind":"pane","server":"herdr","id":"w1:p1",'
      '"workspaceId":"w1","tabId":"w1:t1","focused":true,'
      '"title":"Deploying images","cwd":"/srv","agent":"claude",'
      '"agentStatus":"working","name":null,"sessionId":null,"seq":3},'
      '"pane:herdr:w1:p2":{"kind":"pane","server":"herdr","id":"w1:p2",'
      '"workspaceId":"w1","tabId":"w1:t2","focused":false,'
      '"title":"Proofing PR 398","cwd":"/srv","agent":"claude",'
      '"agentStatus":"blocked","name":null,"sessionId":null,"seq":2},'
      '"pane:herdr:w2:p1":{"kind":"pane","server":"herdr","id":"w2:p1",'
      '"workspaceId":"w2","tabId":"w2:t1","focused":false,'
      '"title":"Nightly E2E","cwd":"/cal","agent":"codex",'
      '"agentStatus":"done","name":null,"sessionId":null,"seq":1},'
      r'"tses:tmux:$0":{"kind":"tmuxSession","server":"tmux","id":"$0",'
      '"name":"main","windows":3,"attached":1,"activity":1790229500,'
      '"created":1790229000},'
      r'"twin:tmux:$0:@1":{"kind":"tmuxWindow","server":"tmux","id":"@1",'
      r'"sessionId":"$0","session":"main","index":0,"name":"zsh",'
      '"active":false,"panes":1,"activity":1790229400,'
      '"activityFlag":false,"bellFlag":false},'
      r'"twin:tmux:$0:@2":{"kind":"tmuxWindow","server":"tmux","id":"@2",'
      r'"sessionId":"$0","session":"main","index":1,"name":"claude",'
      '"active":true,"panes":2,"activity":1790229500,'
      '"activityFlag":false,"bellFlag":false}}';

  /// `status --live` of a companion with `tmux-live` off (the default):
  /// Herdr pushed, tmux left to the phone.
  static String get statusTmuxOff {
    final doc = jsonDecode(status) as Map<String, Object?>;
    final live = doc['live']! as Map<String, Object?>;
    final entities = (live['entities']! as Map<String, Object?>)
      ..removeWhere(
        (key, _) => key.startsWith('tses:') || key.startsWith('twin:'),
      )
      ..['srv:tmux'] = {
        'kind': 'server',
        'id': 'tmux',
        'type': 'tmux',
        'default': true,
        'session': '',
        'state': 'off',
        'mode': 'poll',
      };
    live['entities'] = entities;
    return jsonEncode(doc);
  }

  /// `status --live` with `tmux-live` on.
  static const status =
      '{"version":1,"seq":7,"agents":[],"source":"daemon",'
      '"capabilities":["live"],"live":{"running":true,"entities":$entities}}';
}
