import 'package:conduit/core/app_failure.dart';
import 'package:conduit/features/agent_attention/data/remote_tool_command.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';

/// One tmux client (an attached terminal), from `tmux list-clients`.
class TmuxClient {
  const TmuxClient({
    required this.name,
    required this.sessionName,
    this.sessionId = '',
    this.windowId = '',
    this.paneId = '',
    this.activity = 0,
  });

  /// `#{client_name}`: the client's tty (`/dev/pts/3`), what `-c` and
  /// `detach-client -t` take.
  final String name;
  final String sessionName;
  final String sessionId;

  /// The window and pane the client is looking at.
  final String windowId;
  final String paneId;

  /// `#{client_activity}`: epoch seconds of the client's last input.
  final int activity;

  @override
  bool operator ==(Object other) =>
      other is TmuxClient &&
      other.name == name &&
      other.sessionName == sessionName &&
      other.sessionId == sessionId &&
      other.windowId == windowId &&
      other.paneId == paneId &&
      other.activity == activity;

  @override
  int get hashCode =>
      Object.hash(name, sessionName, sessionId, windowId, paneId, activity);

  @override
  String toString() => 'TmuxClient($name on $sessionName $paneId)';
}

/// One tmux pane, located as session › window › pane.
class TmuxPaneEntry {
  const TmuxPaneEntry({
    required this.sessionId,
    required this.sessionName,
    required this.windowId,
    required this.windowIndex,
    required this.windowName,
    required this.paneId,
    this.paneIndex = 0,
    this.windowActive = false,
    this.paneActive = false,
    this.zoomed = false,
    this.command = '',
    this.path = '',
    this.title = '',
  });

  final String sessionId;
  final String sessionName;
  final String windowId;
  final int windowIndex;
  final String windowName;

  /// `%12`: unique on the server, what every `-t` here takes.
  final String paneId;
  final int paneIndex;

  /// Whether this is the current window of its session.
  final bool windowActive;

  /// Whether this is the active pane of its window.
  final bool paneActive;

  /// Whether the pane's window is zoomed.
  final bool zoomed;

  /// `#{pane_current_command}` (`bash`, `claude`, `vim`).
  final String command;

  /// `#{pane_current_path}`.
  final String path;

  /// `#{pane_title}`; tmux defaults it to the host name.
  final String title;

  /// Current pane of its session: where a client on that session is.
  bool get current => windowActive && paneActive;

  /// `session › index:window › pane`.
  String get location =>
      '$sessionName › $windowIndex:$windowName › pane $paneIndex';

  @override
  bool operator ==(Object other) =>
      other is TmuxPaneEntry &&
      other.sessionId == sessionId &&
      other.sessionName == sessionName &&
      other.windowId == windowId &&
      other.windowIndex == windowIndex &&
      other.windowName == windowName &&
      other.paneId == paneId &&
      other.paneIndex == paneIndex &&
      other.windowActive == windowActive &&
      other.paneActive == paneActive &&
      other.zoomed == zoomed &&
      other.command == command &&
      other.path == path &&
      other.title == title;

  @override
  int get hashCode => Object.hash(
    sessionId,
    sessionName,
    windowId,
    windowIndex,
    windowName,
    paneId,
    paneIndex,
    windowActive,
    paneActive,
    zoomed,
    command,
    path,
    title,
  );

  @override
  String toString() => 'TmuxPaneEntry($paneId $location)';
}

/// Where a tmux action lands: the client this app session is attached
/// through (when one was found) and the pane, window and session it shows.
class TmuxTarget {
  const TmuxTarget({
    required this.sessionId,
    required this.windowId,
    required this.paneId,
    this.clientName,
  });

  /// Null when no client is attached to the session (the app has not
  /// attached yet): actions then act on the session's current pane.
  final String? clientName;
  final String sessionId;
  final String windowId;
  final String paneId;

  @override
  bool operator ==(Object other) =>
      other is TmuxTarget &&
      other.clientName == clientName &&
      other.sessionId == sessionId &&
      other.windowId == windowId &&
      other.paneId == paneId;

  @override
  int get hashCode => Object.hash(clientName, sessionId, windowId, paneId);

  @override
  String toString() =>
      'TmuxTarget(${clientName ?? 'no client'} $sessionId $windowId $paneId)';
}

/// Clients and panes of a tmux server, read in one command.
class TmuxSnapshot {
  const TmuxSnapshot({this.clients = const [], this.panes = const []});

  final List<TmuxClient> clients;

  /// In tmux's order: by session, then window index, then pane index.
  final List<TmuxPaneEntry> panes;

  /// The client this app session drives, for a session attached as
  /// [sessionName] (the host's tmux session name).
  ///
  /// The app cannot see which tty its own SSH channel got, so it picks the
  /// most recently active client attached to [sessionName]: the phone is the
  /// one being used while the navigator is open. When no client is on that
  /// session (the user moved with `choose-tree`), the most recently active
  /// client of any session. Null when nothing is attached.
  TmuxClient? clientFor(String sessionName) {
    TmuxClient? best;
    for (final client in clients) {
      if (client.sessionName == sessionName &&
          (best == null || client.activity > best.activity)) {
        best = client;
      }
    }
    if (best != null) {
      return best;
    }
    for (final client in clients) {
      if (best == null || client.activity > best.activity) {
        best = client;
      }
    }
    return best;
  }

  /// Where actions for the app session on [sessionName] land: its client's
  /// pane, else the current pane of [sessionName], else null.
  TmuxTarget? targetFor(String sessionName) {
    final client = clientFor(sessionName);
    if (client != null && client.paneId.isNotEmpty) {
      return TmuxTarget(
        clientName: client.name,
        sessionId: client.sessionId,
        windowId: client.windowId,
        paneId: client.paneId,
      );
    }
    for (final pane in panes) {
      if (pane.sessionName == sessionName && pane.current) {
        return TmuxTarget(
          clientName: client?.name,
          sessionId: pane.sessionId,
          windowId: pane.windowId,
          paneId: pane.paneId,
        );
      }
    }
    return null;
  }
}

/// Outcome of listing a host's tmux panes.
sealed class TmuxListing {
  const TmuxListing();
}

class TmuxPanesAvailable extends TmuxListing {
  const TmuxPanesAvailable(this.snapshot);

  final TmuxSnapshot snapshot;
}

/// tmux is not installed, or not on the PATH of a non-interactive shell.
class TmuxNotFound extends TmuxListing {
  const TmuxNotFound();
}

/// tmux is installed but no server is running.
class TmuxNotRunning extends TmuxListing {
  const TmuxNotRunning();
}

class TmuxListingFailed extends TmuxListing {
  const TmuxListingFailed(this.message);

  final String message;
}

/// The navigator's one-tap tmux actions.
enum TmuxQuickAction {
  splitRight,
  splitDown,
  newWindow,
  zoom,
  killPane,
  detach,
}

/// tmux CLI commands, wrapped for a non-interactive SSH shell.
///
/// Every command was checked against tmux 3.4 on an isolated server with a
/// real attached client: `switch-client -c <tty> -t %N` moves that client to
/// the pane's session, window and pane; `split-window -t %N -c
/// '#{pane_current_path}'` opens in that pane's live directory;
/// `new-window` refuses a pane target ("can't specify pane here"), so it
/// takes the window id.
abstract final class TmuxCommands {
  /// Field separator in the list formats. tmux 3.3+ prints a tab as `_`
  /// when it takes the client for non-UTF-8 (LANG unset or C, common on an
  /// SSH exec channel), so every command runs `tmux -u`, which passes
  /// tabs through on every version; [TmuxNavigator.parse] still reads the
  /// `_` form. Free text goes last so a tab in a pane title cannot shift
  /// the fields.
  static const separator = '\t';

  static String _tmux(String args) => remoteToolCommand('tmux', '-u $args');

  static String _q(String value) => shellQuoteArgument(value);

  static const _clientFields = [
    '#{client_name}',
    '#{client_session}',
    '#{session_id}',
    '#{window_id}',
    '#{pane_id}',
    '#{client_activity}',
  ];

  static const _paneFields = [
    '#{session_id}',
    '#{session_name}',
    '#{window_id}',
    '#{window_index}',
    '#{window_active}',
    '#{pane_id}',
    '#{pane_index}',
    '#{pane_active}',
    '#{window_zoomed_flag}',
    '#{pane_current_command}',
    '#{pane_current_path}',
    '#{window_name}',
    // Free text last: a stray separator in it is folded back in.
    '#{pane_title}',
  ];

  static String _format(String tag, List<String> fields) =>
      '"\$(printf \'$tag\\t${fields.join(r'\t')}\')"';

  /// `tmux list-clients -F … ';' list-panes -a -F …`: clients (lines
  /// tagged `C`) then every pane (tagged `P`), in one round trip.
  static final listing = _tmux(
    'list-clients -F ${_format('C', _clientFields)} '
    "';' list-panes -a -F ${_format('P', _paneFields)}",
  );

  /// Shows [paneId] in the client [clientName] (switching session and
  /// window too); without a client, makes it the current pane of its
  /// session, which is what a client attaching next will show.
  static String focusPane(String paneId, {String? clientName}) {
    if (clientName != null && clientName.isNotEmpty) {
      return _tmux('switch-client -c ${_q(clientName)} -t ${_q(paneId)}');
    }
    return _tmux(
      "select-window -t ${_q(paneId)} ';' select-pane -t ${_q(paneId)}",
    );
  }

  /// Window [index] of the target's session (`select-window -t '$1:3'`).
  static String selectWindow(TmuxTarget target, int index) =>
      _tmux('select-window -t ${_q('${target.sessionId}:$index')}');

  /// The neighbouring pane in [direction] (`L`, `R`, `U`, `D`).
  static String selectPane(TmuxTarget target, String direction) =>
      _tmux('select-pane -$direction -t ${_q(target.paneId)}');

  /// [action] at [target]; null when it needs a client and none is
  /// attached.
  static String? action(TmuxQuickAction action, TmuxTarget target) {
    final pane = _q(target.paneId);
    const cwd = "'#{pane_current_path}'";
    return switch (action) {
      TmuxQuickAction.splitRight => _tmux('split-window -h -t $pane -c $cwd'),
      TmuxQuickAction.splitDown => _tmux('split-window -v -t $pane -c $cwd'),
      TmuxQuickAction.newWindow => _tmux(
        'new-window -a -t ${_q(target.windowId)} -c $cwd',
      ),
      TmuxQuickAction.zoom => _tmux('resize-pane -Z -t $pane'),
      TmuxQuickAction.killPane => _tmux('kill-pane -t $pane'),
      TmuxQuickAction.detach =>
        target.clientName == null
            ? null
            : _tmux('detach-client -t ${_q(target.clientName!)}'),
    };
  }
}

/// Lists tmux panes and acts on them over a non-interactive command runner,
/// never through the terminal the user types in.
abstract final class TmuxNavigator {
  static const _timeout = Duration(seconds: 10);

  /// Reads the server's clients and panes.
  static Future<TmuxListing> load(AgentCommandRunner runner) async {
    try {
      return interpret(
        await runner.run(TmuxCommands.listing, timeout: _timeout),
      );
    } on AppFailure catch (failure) {
      return TmuxListingFailed(failure.message);
    } catch (error) {
      return TmuxListingFailed('$error');
    }
  }

  static TmuxListing interpret(AgentCommandResult result) {
    final stderr = result.stderr.trim();
    if (result.exitCode == 127 ||
        stderr.contains('tmux: not found') ||
        stderr.contains('tmux: command not found')) {
      return const TmuxNotFound();
    }
    if (result.exitCode != null && result.exitCode != 0) {
      if (stderr.contains('no server running') ||
          stderr.contains('error connecting') ||
          stderr.contains('No such file or directory')) {
        return const TmuxNotRunning();
      }
      return TmuxListingFailed(
        stderr.isEmpty ? 'tmux exited with ${result.exitCode}.' : stderr,
      );
    }
    return TmuxPanesAvailable(parse(result.stdout));
  }

  /// Parses [TmuxCommands.listing] output; lines that do not fit are
  /// skipped.
  static TmuxSnapshot parse(String raw) {
    final clients = <TmuxClient>[];
    final panes = <TmuxPaneEntry>[];
    const sep = TmuxCommands.separator;
    for (final line in raw.split('\n')) {
      final fields = line.contains(sep) ? line.split(sep) : _unmangle(line);
      if (fields.first == 'C' && fields.length >= 7) {
        clients.add(
          TmuxClient(
            name: fields[1],
            sessionName: fields[2],
            sessionId: fields[3],
            windowId: fields[4],
            paneId: fields[5],
            activity: int.tryParse(fields[6].trim()) ?? 0,
          ),
        );
      } else if (fields.first == 'P' && fields.length >= 14) {
        panes.add(
          TmuxPaneEntry(
            sessionId: fields[1],
            sessionName: fields[2],
            windowId: fields[3],
            windowIndex: int.tryParse(fields[4]) ?? 0,
            windowActive: fields[5] == '1',
            paneId: fields[6],
            paneIndex: int.tryParse(fields[7]) ?? 0,
            paneActive: fields[8] == '1',
            zoomed: fields[9] == '1',
            command: fields[10],
            path: fields[11],
            windowName: fields[12],
            title: fields.sublist(13).join(sep),
          ),
        );
      }
    }
    return TmuxSnapshot(clients: clients, panes: panes);
  }

  /// A listing line whose tabs tmux printed as `_` (see
  /// [TmuxCommands.separator]), split by the shape of its fixed fields
  /// (`$1`, `@2`, `%3`, numbers, flags); `[line]` when it has none. A
  /// pane's command, path, window name and title cannot be told apart in
  /// that form: the command keeps what comes before the path, the rest
  /// is left empty.
  static List<String> _unmangle(String line) {
    final client = _mangledClient.firstMatch(line);
    if (client != null) {
      final names = client[1]!;
      final cut = names.indexOf('_');
      return [
        'C',
        if (cut < 0) ...[
          names,
          '',
        ] else ...[
          names.substring(0, cut),
          names.substring(cut + 1),
        ],
        for (var i = 2; i <= 5; i++) client[i]!,
      ];
    }
    final pane = _mangledPane.firstMatch(line);
    if (pane != null) {
      final rest = pane[10]!;
      final pathAt = rest.indexOf('_/');
      return [
        'P',
        for (var i = 1; i <= 9; i++) pane[i]!,
        if (pathAt < 0) rest else rest.substring(0, pathAt),
        '',
        '',
        '',
      ];
    }
    return [line];
  }

  static final _mangledClient = RegExp(r'^C_(.*)_(\$\d+)_(@\d+)_(%\d+)_(\d+)$');
  static final _mangledPane = RegExp(
    r'^P_(\$\d+)_(.*?)_(@\d+)_(\d+)_([01])_(%\d+)_(\d+)_([01])_([01])_(.*)$',
  );

  static Future<bool> _run(AgentCommandRunner runner, String? command) async {
    if (command == null) {
      return false;
    }
    try {
      final result = await runner.run(command, timeout: _timeout);
      return result.exitCode == null || result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// Reads the snapshot and resolves the app session's target; null when
  /// tmux could not be read or nothing matches.
  static Future<TmuxTarget?> resolveTarget(
    AgentCommandRunner runner,
    String sessionName,
  ) async {
    final listing = await load(runner);
    return listing is TmuxPanesAvailable
        ? listing.snapshot.targetFor(sessionName)
        : null;
  }

  /// Switches the app's client to [pane].
  static Future<bool> focus(
    AgentCommandRunner runner,
    TmuxPaneEntry pane, {
    TmuxTarget? target,
  }) => _run(
    runner,
    TmuxCommands.focusPane(pane.paneId, clientName: target?.clientName),
  );

  /// Runs [action] at [target], or at the target resolved for
  /// [sessionName] when none is given. False when the CLI could not do it,
  /// so the caller can fall back to the prefix key.
  static Future<bool> perform(
    AgentCommandRunner runner,
    TmuxQuickAction action, {
    TmuxTarget? target,
    String sessionName = '',
  }) async {
    final resolved = target ?? await resolveTarget(runner, sessionName);
    if (resolved == null) {
      return false;
    }
    return _run(runner, TmuxCommands.action(action, resolved));
  }

  /// Window [index] (1–9) of the app's session.
  static Future<bool> selectWindow(
    AgentCommandRunner runner,
    int index, {
    TmuxTarget? target,
    String sessionName = '',
  }) async {
    final resolved = target ?? await resolveTarget(runner, sessionName);
    if (resolved == null) {
      return false;
    }
    return _run(runner, TmuxCommands.selectWindow(resolved, index));
  }

  /// Deep links: makes [paneId] the current pane of its session, so the
  /// app tab attached to that session shows it (the same as
  /// `conductore-hostd focus`).
  static Future<bool> focusAgentPane(
    AgentCommandRunner runner,
    String paneId,
  ) => _run(runner, TmuxCommands.focusPane(paneId));
}

/// A companion agent's tmux location: the tmux session and pane it runs in.
///
/// The companion (`conductore-hostd`) reports it as `tab` =
/// `<session>:<window>` and `pane` = `%N`. tmux pane ids always start with
/// `%` (Herdr's look like `w1:p2`), which is what tells the two apart.
class TmuxAgentLocation {
  const TmuxAgentLocation({required this.sessionName, required this.paneId});

  final String sessionName;
  final String paneId;

  static final _paneIdPattern = RegExp(r'^%\d+$');

  /// Null unless [pane] is a tmux pane id and [tab] names its session.
  /// tmux forbids `:` in session names, so the part before the first `:`
  /// is the session.
  static TmuxAgentLocation? parse({String? tab, String? pane}) {
    if (pane == null || !_paneIdPattern.hasMatch(pane)) {
      return null;
    }
    final session = (tab ?? '').split(':').first.trim();
    if (session.isEmpty) {
      return null;
    }
    return TmuxAgentLocation(sessionName: session, paneId: pane);
  }

  @override
  bool operator ==(Object other) =>
      other is TmuxAgentLocation &&
      other.sessionName == sessionName &&
      other.paneId == paneId;

  @override
  int get hashCode => Object.hash(sessionName, paneId);
}
