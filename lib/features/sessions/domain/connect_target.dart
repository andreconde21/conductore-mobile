import 'package:conduit/features/agent_attention/data/remote_tool_command.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';

/// What a terminal session should attach to once the shell is up.
enum ConnectTargetKind {
  /// A plain login shell, exactly what connecting did before the picker.
  shell,

  /// `tmux new-session -A -s <name>`: attach to a tmux session, creating it
  /// if needed.
  tmux,

  /// Attach to a persistent Herdr session (the default one, or a named one),
  /// with one workspace (and optionally one tab and pane) focused first when
  /// a workspace id is given.
  herdr,

  /// A plain shell that starts with `cd <directory>` (a recent directory
  /// picked in the connect picker).
  directory,
}

/// The choice made in the connect picker for one host.
///
/// A target is applied to a [SavedHost] with [apply]: the resulting copy
/// carries a derived id (`<hostId>#<key>`, mirroring how the local shell
/// numbers its instances) so several sessions to the same machine can be
/// open at once, and a title that names the workspace, like Moshi does.
class ConnectTarget {
  const ConnectTarget._({
    required this.kind,
    this.name = '',
    this.label = '',
    this.tabId = '',
    this.session = '',
    this.paneId = '',
  });

  const ConnectTarget.shell() : this._(kind: ConnectTargetKind.shell);

  const ConnectTarget.tmux(String sessionName)
    : this._(kind: ConnectTargetKind.tmux, name: sessionName);

  const ConnectTarget.directory(String path)
    : this._(kind: ConnectTargetKind.directory, name: path);

  const ConnectTarget.herdr({
    required String workspaceId,
    String label = '',
    String tabId = '',
    String session = '',
    String paneId = '',
  }) : this._(
         kind: ConnectTargetKind.herdr,
         name: workspaceId,
         label: label,
         tabId: tabId,
         session: session,
         paneId: paneId,
       );

  final ConnectTargetKind kind;

  /// tmux session name, Herdr workspace id (empty for "just run herdr",
  /// which launches or attaches the default session) or directory path.
  final String name;

  /// Human label (Herdr workspace label); empty for tmux and shell.
  final String label;

  /// Optional Herdr tab id to focus inside the workspace.
  final String tabId;

  /// Named Herdr session (`herdr --session <name>`); empty for the default
  /// session.
  final String session;

  /// Optional Herdr pane to focus once attached (an agent's pane, for deep
  /// links). Not part of [key] or the saved form: it only steers this one
  /// attach.
  final String paneId;

  /// Identity of the Herdr server this target attaches to on its host.
  String get herdrServer => session;

  /// Separator between a saved host id and the target key in a session's
  /// derived host id.
  static const idSeparator = '#';

  /// Stable identity of the target on one host, used in derived host ids,
  /// recents deduplication and the picker's "Active" badges.
  String get key => switch (kind) {
    ConnectTargetKind.shell => 'shell',
    ConnectTargetKind.tmux => 'tmux:$name',
    ConnectTargetKind.herdr => _herdrKey(),
    ConnectTargetKind.directory => 'dir:$name',
  };

  String _herdrKey() {
    final base = session.isEmpty ? 'herdr' : 'herdr@$session';
    if (name.isEmpty) {
      return base;
    }
    return tabId.isEmpty ? '$base:$name' : '$base:$name:$tabId';
  }

  /// Short display name of the target: what the session tile and header show
  /// next to the host name.
  String get title => switch (kind) {
    ConnectTargetKind.shell => 'Shell',
    ConnectTargetKind.tmux => name,
    ConnectTargetKind.herdr =>
      label.isNotEmpty
          ? label
          : name.isNotEmpty
          ? name
          : 'Herdr',
    ConnectTargetKind.directory => _basename(name),
  };

  static String _basename(String path) {
    final segments = path.split('/').where((s) => s.isNotEmpty);
    return segments.isEmpty ? '/' : segments.last;
  }

  /// Command typed into the shell right after connecting, or null when the
  /// target is handled by the host's own tmux settings.
  String? get startupCommand => switch (kind) {
    ConnectTargetKind.shell || ConnectTargetKind.tmux => null,
    ConnectTargetKind.herdr => _herdrAttachCommand(),
    ConnectTargetKind.directory => 'cd ${shellQuote(name)}',
  };

  String _herdrAttachCommand() {
    final herdr = session.isEmpty
        ? 'herdr'
        : 'herdr --session ${shellQuote(session)}';
    // Focus over the socket API first (a no-op when the server is not up
    // yet), then attach the TUI. Herdr keeps one focus per server, and a
    // client that attaches shows whatever is focused (checked against
    // Herdr 0.9.1 with two clients), so this is what steers the new client.
    // Without `exec` a detach lands back in the shell, like the tmux path.
    final focus = [
      // `tab focus` switches the workspace too, so only one is needed.
      if (tabId.isNotEmpty)
        '$herdr tab focus ${shellQuote(tabId)}'
      else if (name.isNotEmpty)
        '$herdr workspace focus ${shellQuote(name)}',
      if (paneId.isNotEmpty) '$herdr agent focus ${shellQuote(paneId)}',
    ];
    if (focus.isEmpty) {
      return herdr;
    }
    return '${focus.map((command) => '$command >/dev/null 2>&1').join('; ')}'
        '; $herdr';
  }

  /// [command] without the focus commands a Herdr attach starts with
  /// (see [startupCommand]): just the attach. Attaching does not move
  /// Herdr's shared focus (checked on Herdr 0.9.1); focusing does, for
  /// every screen on that server. Other commands come back unchanged.
  static String withoutHerdrFocus(String command) {
    if (!command.contains(' focus ')) {
      return command;
    }
    final attach = command.split('; ').last;
    return RegExp(r'^herdr( --session .+)?$').hasMatch(attach)
        ? attach
        : command;
  }

  /// The host a session should be opened with for this target.
  SavedHost apply(SavedHost host) {
    if (kind == ConnectTargetKind.shell) {
      return host;
    }
    final base = host.copyWith(
      id: '${host.id}$idSeparator$key',
      name: '${host.name}: $title',
    );
    return switch (kind) {
      ConnectTargetKind.tmux => base.copyWith(
        startTmuxOnConnect: true,
        tmuxSessionName: name,
      ),
      ConnectTargetKind.herdr ||
      ConnectTargetKind.directory => base.copyWith(startTmuxOnConnect: false),
      ConnectTargetKind.shell => base,
    };
  }

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'name': name,
    'label': label,
    'tabId': tabId,
    if (session.isNotEmpty) 'session': session,
  };

  static ConnectTarget? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final kind = ConnectTargetKind.values
        .where((value) => value.name == json['kind'])
        .firstOrNull;
    if (kind == null) {
      return null;
    }
    final name = json['name'];
    final label = json['label'];
    final tabId = json['tabId'];
    final session = json['session'];
    final target = ConnectTarget._(
      kind: kind,
      name: name is String ? name : '',
      label: label is String ? label : '',
      tabId: tabId is String ? tabId : '',
      session: kind == ConnectTargetKind.herdr && session is String
          ? session
          : '',
    );
    if ((kind == ConnectTargetKind.tmux ||
            kind == ConnectTargetKind.directory) &&
        target.name.isEmpty) {
      return null;
    }
    return target;
  }

  /// Parses the target key back out of a derived session host id; null for
  /// a plain (undecorated) host id.
  static String? keyFromSessionHostId(String sessionHostId) {
    final separator = sessionHostId.indexOf(idSeparator);
    if (separator == -1) {
      return null;
    }
    return sessionHostId.substring(separator + 1);
  }

  /// Rebuilds the target from a derived session host id. The Herdr label is
  /// not encoded in the key, so it comes back empty; callers that need it
  /// keep the original target.
  static ConnectTarget? fromSessionHostId(String sessionHostId) {
    final key = keyFromSessionHostId(sessionHostId);
    if (key == null) {
      return null;
    }
    if (key == 'shell') {
      return const ConnectTarget.shell();
    }
    if (key.startsWith('tmux:')) {
      final name = key.substring('tmux:'.length);
      return name.isEmpty ? null : ConnectTarget.tmux(name);
    }
    if (key.startsWith('dir:')) {
      final path = key.substring('dir:'.length);
      return path.isEmpty ? null : ConnectTarget.directory(path);
    }
    if (key == 'herdr' ||
        key.startsWith('herdr:') ||
        key.startsWith('herdr@')) {
      var rest = key.substring('herdr'.length);
      var session = '';
      if (rest.startsWith('@')) {
        final colon = rest.indexOf(':');
        session = colon == -1 ? rest.substring(1) : rest.substring(1, colon);
        rest = colon == -1 ? '' : rest.substring(colon);
        if (session.isEmpty) {
          return null;
        }
      }
      if (rest.isEmpty) {
        return ConnectTarget.herdr(workspaceId: '', session: session);
      }
      rest = rest.substring(1);
      final colon = rest.indexOf(':');
      final workspaceId = colon == -1 ? rest : rest.substring(0, colon);
      final tabId = colon == -1 ? '' : rest.substring(colon + 1);
      if (workspaceId.isEmpty) {
        return null;
      }
      return ConnectTarget.herdr(
        workspaceId: workspaceId,
        tabId: tabId,
        session: session,
      );
    }
    return null;
  }

  static final _unquoted = RegExp(r'^[A-Za-z0-9_~./:=+-]+$');

  /// Typed into the login shell, which may be fish: see
  /// [shellQuoteArgument].
  static String shellQuote(String value) =>
      _unquoted.hasMatch(value) ? value : shellQuoteArgument(value);

  @override
  bool operator ==(Object other) {
    return other is ConnectTarget &&
        other.kind == kind &&
        other.name == name &&
        other.label == label &&
        other.tabId == tabId &&
        other.session == session &&
        other.paneId == paneId;
  }

  @override
  int get hashCode => Object.hash(kind, name, label, tabId, session, paneId);

  @override
  String toString() => 'ConnectTarget($key)';
}

/// The saved host id behind a session's (possibly derived) host id.
String baseHostId(String sessionHostId) {
  final separator = sessionHostId.indexOf(ConnectTarget.idSeparator);
  return separator == -1
      ? sessionHostId
      : sessionHostId.substring(0, separator);
}
