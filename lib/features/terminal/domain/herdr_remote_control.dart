import 'dart:async';
import 'dart:convert';

import 'package:conduit/core/app_failure.dart';
import 'package:conduit/features/agent_attention/data/herdr_attention_provider.dart';
import 'package:conduit/features/agent_attention/data/remote_tool_command.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/sessions/domain/remote_session_listing.dart';
import 'package:conduit/features/terminal/domain/herdr_keymap.dart';

/// How a Herdr focus command went.
enum HerdrFocusOutcome {
  /// Herdr focused it.
  focused,

  /// Herdr has no such workspace (or tab, or pane) any more.
  missing,

  /// The command did not get through, or Herdr refused it for another
  /// reason.
  failed,
}

/// A neighbour direction for `herdr pane focus --direction`.
enum HerdrDirection { left, right, up, down }

/// The one-tap ways to open a new shell in Herdr, each in the focused
/// pane's working directory.
enum HerdrNewPane {
  /// `herdr pane split <focused> --direction right`.
  splitRight,

  /// `herdr pane split <focused> --direction down`.
  splitDown,

  /// `herdr tab create --workspace <focused workspace>`.
  newTab,

  /// `herdr workspace create`.
  newWorkspace,
}

/// The pane Herdr has focused, as `herdr pane list` reports it.
class HerdrFocusedPane {
  const HerdrFocusedPane({
    required this.paneId,
    this.workspaceId = '',
    this.tabId = '',
    this.cwd = '',
  });

  final String paneId;
  final String workspaceId;
  final String tabId;

  /// The pane's working directory; empty when Herdr did not report one.
  final String cwd;

  @override
  bool operator ==(Object other) =>
      other is HerdrFocusedPane &&
      other.paneId == paneId &&
      other.workspaceId == workspaceId &&
      other.tabId == tabId &&
      other.cwd == cwd;

  @override
  int get hashCode => Object.hash(paneId, workspaceId, tabId, cwd);

  @override
  String toString() => 'HerdrFocusedPane($paneId in $cwd)';
}

/// Herdr CLI commands for one Herdr server (the default session, or a named
/// one via `--session`), wrapped for a non-interactive SSH shell.
///
/// Every command here was checked against Herdr 0.9.1 (each command's
/// `--help`), and the pane and zoom commands were run against a live
/// server: without `--pane`/`--current` they act on the UI-focused pane,
/// which is what a phone gesture means.
class HerdrCommands {
  const HerdrCommands([this.session = '']);

  /// Named Herdr session; empty for the default one.
  final String session;

  String _herdr(String args) => HerdrAttentionProvider.remoteCommand(
    session.isEmpty ? args : '--session ${shellQuoteArgument(session)} $args',
  );

  String get workspaceList => _herdr('workspace list');
  String get tabList => _herdr('tab list');
  String get paneList => _herdr('pane list');
  String get agentList => _herdr('agent list');

  String workspaceFocus(String workspaceId) =>
      _herdr('workspace focus ${shellQuoteArgument(workspaceId)}');

  String tabFocus(String tabId) =>
      _herdr('tab focus ${shellQuoteArgument(tabId)}');

  /// `herdr tab rename <tab_id> <label>`.
  String tabRename(String tabId, String label) => _herdr(
    'tab rename ${shellQuoteArgument(tabId)} ${shellQuoteArgument(label)}',
  );

  /// `herdr tab close <tab_id>`. Herdr 0.9.1 has no command that moves a
  /// tab, so the tab strip offers no reordering for Herdr.
  String tabClose(String tabId) =>
      _herdr('tab close ${shellQuoteArgument(tabId)}');

  /// `herdr agent focus <pane_id>`: switches workspace and tab as needed.
  String agentFocus(String paneId) =>
      _herdr('agent focus ${shellQuoteArgument(paneId)}');

  String paneFocus(HerdrDirection direction) =>
      _herdr('pane focus --direction ${direction.name}');

  String paneZoom({required bool on}) =>
      _herdr('pane zoom ${on ? '--on' : '--off'}');

  String paneClose(String paneId) =>
      _herdr('pane close ${shellQuoteArgument(paneId)}');

  /// `herdr pane split <pane> --direction right|down --cwd <dir> --focus`.
  /// Herdr 0.9.1 needs the pane id: without one (and outside a Herdr pane)
  /// it answers `pane_not_found`. The new pane inherits the source pane's
  /// directory anyway; [cwd] makes that explicit.
  String paneSplit(String paneId, {required bool down, String cwd = ''}) =>
      _herdr(
        'pane split ${shellQuoteArgument(paneId)} '
        '--direction ${down ? 'down' : 'right'}${_cwd(cwd)} --focus',
      );

  /// `herdr tab create [--workspace <id>] [--cwd <dir>] --focus`.
  String tabCreate({String workspaceId = '', String cwd = ''}) => _herdr(
    'tab create'
    '${workspaceId.isEmpty ? '' : ' --workspace ${shellQuoteArgument(workspaceId)}'}'
    '${_cwd(cwd)} --focus',
  );

  /// `herdr workspace create [--cwd <dir>] --focus`; Herdr labels it after
  /// the directory.
  String workspaceCreate({String cwd = ''}) =>
      _herdr('workspace create${_cwd(cwd)} --focus');

  /// The command that opens [kind] next to [focused]; null when it needs a
  /// focused pane and there is none.
  String? newPane(HerdrNewPane kind, HerdrFocusedPane? focused) {
    final cwd = focused?.cwd ?? '';
    return switch (kind) {
      HerdrNewPane.splitRight || HerdrNewPane.splitDown =>
        focused == null
            ? null
            : paneSplit(
                focused.paneId,
                down: kind == HerdrNewPane.splitDown,
                cwd: cwd,
              ),
      HerdrNewPane.newTab => tabCreate(
        workspaceId: focused?.workspaceId ?? '',
        cwd: cwd,
      ),
      HerdrNewPane.newWorkspace => workspaceCreate(cwd: cwd),
    };
  }

  static String _cwd(String cwd) =>
      cwd.isEmpty ? '' : ' --cwd ${shellQuoteArgument(cwd)}';
}

/// Drives one Herdr server over a dedicated command channel (never the
/// terminal the user types in).
///
/// The channel is opened on first use and kept for [idleTimeout] so a burst
/// of gestures shares one SSH connection. Commands run one at a time in the
/// order they were asked for, so "remember where the old tab was, then
/// focus the new one" cannot overtake itself.
class HerdrRemoteControl {
  HerdrRemoteControl({
    required this.runnerFactory,
    this.session = '',
    this.idleTimeout = const Duration(minutes: 2),
  }) : commands = HerdrCommands(session);

  static const _timeout = Duration(seconds: 10);

  /// Opens the command channel; called again after an idle close.
  final AgentCommandRunner Function() runnerFactory;
  final String session;
  final HerdrCommands commands;
  final Duration idleTimeout;

  AgentCommandRunner? _runner;
  Timer? _idle;
  Future<void> _queue = Future<void>.value();
  bool _closed = false;

  /// Runs [command] and hands back its output; null when the channel
  /// failed or is closed.
  Future<AgentCommandResult?> query(String command) => _enqueue(command);

  /// Whether [result] is a success (exit status, and no error envelope).
  static bool succeeded(AgentCommandResult result) => _succeeded(result);

  /// Runs [command]; true when Herdr accepted it.
  Future<bool> run(String command) async {
    final result = await _enqueue(command);
    return result != null && _succeeded(result);
  }

  Future<AgentCommandResult?> _enqueue(String command) {
    final completer = Completer<AgentCommandResult?>();
    _queue = _queue.then((_) async {
      completer.complete(await _runNow(command));
    });
    return completer.future;
  }

  Future<AgentCommandResult?> _runNow(String command) async {
    if (_closed) {
      return null;
    }
    _idle?.cancel();
    try {
      final runner = _runner ??= runnerFactory();
      return await runner.run(command, timeout: _timeout);
    } on AppFailure {
      return null;
    } catch (_) {
      return null;
    } finally {
      if (!_closed) {
        _idle = Timer(idleTimeout, () => unawaited(_dropRunner()));
      }
    }
  }

  static bool _succeeded(AgentCommandResult result) {
    if (result.exitCode != null && result.exitCode != 0) {
      return false;
    }
    // Herdr 0.9.1 exits 1 on API errors; the error envelope is a second
    // signal in case a wrapper swallows the status.
    return !result.stdout.trimLeft().startsWith('{"error"');
  }

  Future<bool> focusWorkspace(String workspaceId) =>
      run(commands.workspaceFocus(workspaceId));

  /// [focusWorkspace], telling a closed workspace apart from a failure.
  Future<HerdrFocusOutcome> focusWorkspaceOutcome(String workspaceId) async {
    final result = await _enqueue(commands.workspaceFocus(workspaceId));
    if (result == null) {
      return HerdrFocusOutcome.failed;
    }
    if (_succeeded(result)) {
      return HerdrFocusOutcome.focused;
    }
    // Herdr 0.9.1: `{"error":{"code":"workspace_not_found",…}}`, on stderr
    // from the CLI.
    return '${result.stdout}${result.stderr}'.contains('not_found')
        ? HerdrFocusOutcome.missing
        : HerdrFocusOutcome.failed;
  }

  Future<bool> focusTab(String tabId) => run(commands.tabFocus(tabId));

  Future<bool> focusPane(HerdrDirection direction) =>
      run(commands.paneFocus(direction));

  Future<bool> setZoom({required bool on}) => run(commands.paneZoom(on: on));

  /// Focuses the exact place an agent is in: its pane when known (which
  /// switches workspace and tab too), else its tab, else its workspace.
  Future<bool> focusLocation({
    String workspaceId = '',
    String tabId = '',
    String paneId = '',
  }) async {
    if (paneId.isNotEmpty && await run(commands.agentFocus(paneId))) {
      return true;
    }
    if (tabId.isNotEmpty && await focusTab(tabId)) {
      return true;
    }
    return workspaceId.isNotEmpty && await focusWorkspace(workspaceId);
  }

  /// Reads the machine's Herdr keymap (read-only); null when that failed.
  Future<HerdrKeymap?> readKeymap() async =>
      HerdrKeymapReader.interpret(await _enqueue(HerdrKeymapReader.command));

  /// Lists the server's workspaces in Herdr's order; null when that failed.
  Future<List<HerdrWorkspaceInfo>?> workspaces() async {
    final result = await _enqueue(commands.workspaceList);
    if (result == null) {
      return null;
    }
    final listing = RemoteSessionListing.interpretHerdrWorkspaces(result);
    return listing is RemoteListingAvailable<HerdrWorkspaceInfo>
        ? listing.items
        : null;
  }

  /// Id of the workspace Herdr has focused; null when unknown.
  Future<String?> focusedWorkspaceId() async {
    final items = await workspaces();
    if (items == null) {
      return null;
    }
    for (final workspace in items) {
      if (workspace.focused) {
        return workspace.id;
      }
    }
    return null;
  }

  /// Focuses the workspace [delta] places after the focused one, wrapping
  /// around. Returns the id it focused, or null when nothing changed.
  Future<String?> focusAdjacentWorkspace(int delta) async {
    final items = await workspaces();
    if (items == null || items.length < 2) {
      return null;
    }
    final current = items.indexWhere((workspace) => workspace.focused);
    final start = current == -1 ? 0 : current;
    final next = (start + delta) % items.length;
    final target = items[next < 0 ? next + items.length : next];
    return await focusWorkspace(target.id) ? target.id : null;
  }

  /// The pane Herdr has focused right now (`herdr pane list`); null when
  /// that could not be read.
  Future<HerdrFocusedPane?> readFocusedPane() async {
    final result = await _enqueue(commands.paneList);
    if (result == null || !_succeeded(result)) {
      return null;
    }
    return focusedPane(result.stdout);
  }

  /// Closes the focused pane (looked up with `herdr pane list`).
  Future<bool> closeFocusedPane() async {
    final result = await _enqueue(commands.paneList);
    if (result == null || !_succeeded(result)) {
      return false;
    }
    final paneId = focusedPaneId(result.stdout);
    return paneId != null && await run(commands.paneClose(paneId));
  }

  /// [closeFocusedPane] over a runner someone else owns (the navigator's).
  static Future<bool> closeFocusedPaneOn(
    AgentCommandRunner runner, [
    HerdrCommands commands = const HerdrCommands(),
  ]) async {
    try {
      final list = await runner.run(commands.paneList, timeout: _timeout);
      if (!_succeeded(list)) {
        return false;
      }
      final paneId = focusedPaneId(list.stdout);
      if (paneId == null) {
        return false;
      }
      final close = await runner.run(
        commands.paneClose(paneId),
        timeout: _timeout,
      );
      return _succeeded(close);
    } catch (_) {
      return false;
    }
  }

  /// The focused pane's id in `herdr pane list` output (the
  /// `{"result": {"panes": [...]}}` envelope of Herdr 0.9, or a bare
  /// `{"panes": [...]}` object); null when none is focused or the output is
  /// not JSON.
  static String? focusedPaneId(String raw) => focusedPane(raw)?.paneId;

  /// The focused pane in `herdr pane list` output, with its workspace, tab
  /// and working directory (`cwd`, else `foreground_cwd`).
  static HerdrFocusedPane? focusedPane(String raw) {
    Object? decoded;
    try {
      decoded = jsonDecode(raw.trim());
    } catch (_) {
      return null;
    }
    Object? panes;
    if (decoded is Map) {
      final result = decoded['result'];
      panes = result is Map ? result['panes'] : decoded['panes'];
    }
    if (panes is! List) {
      return null;
    }
    String text(Map<Object?, Object?> pane, String key) {
      final value = pane[key];
      return value is String ? value : '';
    }

    for (final pane in panes) {
      if (pane is Map && pane['focused'] == true) {
        final id = text(pane, 'pane_id');
        if (id.isEmpty) {
          continue;
        }
        final cwd = text(pane, 'cwd');
        return HerdrFocusedPane(
          paneId: id,
          workspaceId: text(pane, 'workspace_id'),
          tabId: text(pane, 'tab_id'),
          cwd: cwd.isNotEmpty ? cwd : text(pane, 'foreground_cwd'),
        );
      }
    }
    return null;
  }

  /// Opens [kind] next to the focused pane, in its directory. False when
  /// Herdr could not (no server, an older Herdr, nothing focused to split),
  /// so the caller can fall back to the machine's key binding.
  Future<bool> createPane(HerdrNewPane kind) async {
    final list = await _enqueue(commands.paneList);
    final focused = list != null && _succeeded(list)
        ? focusedPane(list.stdout)
        : null;
    final command = commands.newPane(kind, focused);
    return command != null && await run(command);
  }

  /// [createPane] over a runner someone else owns (the navigator's).
  static Future<bool> createPaneOn(
    AgentCommandRunner runner,
    HerdrNewPane kind, [
    HerdrCommands commands = const HerdrCommands(),
  ]) async {
    try {
      final list = await runner.run(commands.paneList, timeout: _timeout);
      final focused = _succeeded(list) ? focusedPane(list.stdout) : null;
      final command = commands.newPane(kind, focused);
      if (command == null) {
        return false;
      }
      return _succeeded(await runner.run(command, timeout: _timeout));
    } catch (_) {
      return false;
    }
  }

  Future<void> _dropRunner() async {
    final runner = _runner;
    _runner = null;
    if (runner != null) {
      try {
        await runner.close();
      } catch (_) {
        // Already gone.
      }
    }
  }

  /// Closes the channel; later calls do nothing and report failure.
  Future<void> close() async {
    _closed = true;
    _idle?.cancel();
    await _queue;
    await _dropRunner();
  }
}
