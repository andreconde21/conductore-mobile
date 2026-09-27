import 'dart:async';

import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/sftp/domain/remote_file_kind.dart';
import 'package:conduit/features/sftp/domain/sftp_repository.dart';
import 'package:conduit/features/sftp/domain/sftp_session.dart';
import 'package:conduit/features/sftp/presentation/file_viewer/sftp_file_viewer.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// A file opened from terminal output, shown as a tab beside session tabs.
///
/// Subclasses host other per-host views (a git diff, a live preview) in the
/// same tab strip; they override [title], [icon] and [dispose].
class TerminalFileTab {
  TerminalFileTab({required this.host, required this.path});

  final SavedHost host;
  final String path;
  final GlobalKey<SftpFileViewerState> viewerKey = GlobalKey();

  String get title => remoteFileName(path);

  IconData get icon => Icons.description_rounded;

  /// Shown on long-press of the tab: the remote path for files.
  String get tooltip => path;

  /// Notifies when [title] may have changed; null for a static title.
  Listenable? get listenable => null;

  /// What kind of view this is, for [viewId]: `file`, `diff`, `preview`,
  /// `chat`.
  String get viewKind => 'file';

  /// Stable identity of the view across rebuilds and app runs (the desktop
  /// shell's panes remember views by it).
  String get viewId => '$viewKind:${host.id}:$path';

  /// Whether [other] shows the same thing, so opening it again re-activates
  /// this tab instead of adding a duplicate.
  bool matches(TerminalFileTab other) =>
      other.runtimeType == runtimeType &&
      other.host.id == host.id &&
      other.path == path;

  /// Builds the tab's content for views the terminal page does not know
  /// (Chat View in the desktop shell); null for files, diffs and previews,
  /// which the page builds itself.
  WidgetBuilder? get viewBuilder => null;

  /// Releases resources when the tab is closed or the workspace goes away.
  void dispose() {}
}

/// Viewer tabs for the terminal workspace, with one pooled SFTP session per
/// host that is closed when the host's last tab closes.
class TerminalFileTabsController extends ChangeNotifier {
  TerminalFileTabsController(this._repository);

  final SftpRepository _repository;
  final List<TerminalFileTab> _tabs = [];
  final Map<String, Future<SftpSession>> _sessions = {};
  final Map<String, String> _resolvedPaths = {};
  TerminalFileTab? _active;

  List<TerminalFileTab> get tabs => List.unmodifiable(_tabs);
  TerminalFileTab? get active => _active;

  TerminalFileTab open(SavedHost host, String path) =>
      add(TerminalFileTab(host: host, path: path));

  /// Adds [tab] and activates it, or activates the existing tab it
  /// [TerminalFileTab.matches] (disposing the redundant [tab]).
  TerminalFileTab add(TerminalFileTab tab) {
    final existing = _tabs.where((other) => other.matches(tab)).firstOrNull;
    if (existing != null) {
      tab.dispose();
    } else {
      _tabs.add(tab);
    }
    _active = existing ?? tab;
    notifyListeners();
    return _active!;
  }

  void activate(TerminalFileTab? tab) {
    if (tab == _active || (tab != null && !_tabs.contains(tab))) {
      return;
    }
    _active = tab;
    notifyListeners();
  }

  void close(TerminalFileTab tab) {
    if (!_tabs.remove(tab)) {
      return;
    }
    if (_active == tab) {
      _active = null;
    }
    if (_tabs.every((other) => other.host.id != tab.host.id)) {
      _closeSession(tab.host.id);
    }
    tab.dispose();
    notifyListeners();
  }

  Future<Uint8List> read(
    TerminalFileTab tab,
    void Function(int bytesRead, int? total)? onProgress,
  ) => _withSession(tab, (session, path) {
    return session.read(
      path,
      onProgress: onProgress,
      maxBytes: remoteFileViewerMaxBytes,
    );
  });

  /// Saves [tab]'s file; completes with the save's notice for the user.
  Future<String?> write(TerminalFileTab tab, Uint8List bytes) =>
      _withSession(tab, (session, path) async {
        return (await session.save(path, bytes)).notice;
      });

  /// Runs [action] on [tab]'s pooled session. When it fails the session is
  /// dropped from the pool and closed, so the next read or save of any of
  /// the host's tabs reconnects instead of reusing a session that died (a
  /// network change). A plain file error only costs that reconnect.
  Future<T> _withSession<T>(
    TerminalFileTab tab,
    Future<T> Function(SftpSession session, String path) action,
  ) async {
    final pooled = _session(tab.host);
    final session = await pooled;
    try {
      return await action(session, await _resolve(session, tab));
    } catch (_) {
      if (identical(_sessions[tab.host.id], pooled)) {
        unawaited(_sessions.remove(tab.host.id));
        unawaited(session.close().catchError((Object _) {}));
      }
      rethrow;
    }
  }

  /// Shell output often prints paths relative to `~`; SFTP wants absolute
  /// ones. Resolution happens server-side against the SFTP home directory.
  Future<String> _resolve(SftpSession session, TerminalFileTab tab) async {
    if (tab.path.startsWith('/')) {
      return tab.path;
    }
    final key = '${tab.host.id}:${tab.path}';
    final cached = _resolvedPaths[key];
    if (cached != null) {
      return cached;
    }
    final relative = tab.path.startsWith('~/')
        ? tab.path.substring(2)
        : tab.path;
    final resolved = await session.resolve(relative);
    _resolvedPaths[key] = resolved;
    return resolved;
  }

  Future<SftpSession> _session(SavedHost host) {
    final existing = _sessions[host.id];
    if (existing != null) {
      return existing;
    }
    final future = _repository.connect(host);
    _sessions[host.id] = future;
    // Drop a failed connection from the pool so a viewer retry reconnects.
    unawaited(
      future.then<void>(
        (_) {},
        onError: (Object _) {
          if (identical(_sessions[host.id], future)) {
            _sessions.remove(host.id);
          }
        },
      ),
    );
    return future;
  }

  void _closeSession(String hostId) {
    final future = _sessions.remove(hostId);
    if (future == null) {
      return;
    }
    unawaited(
      future.then<void>((session) => session.close(), onError: (Object _) {}),
    );
  }

  @override
  void dispose() {
    for (final hostId in List.of(_sessions.keys)) {
      _closeSession(hostId);
    }
    for (final tab in _tabs) {
      tab.dispose();
    }
    _tabs.clear();
    super.dispose();
  }
}
