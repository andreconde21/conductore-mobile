import 'dart:async';
import 'dart:convert';

import 'package:conduit/features/agent_attention/data/conductore_host_attention_provider.dart';
import 'package:conduit/features/agent_attention/data/remote_tool_command.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/live/domain/live_host_model.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Where a task started from the phone (CON-037) puts its git worktree.
/// Stored only; starting tasks is a later card.
enum WorktreeLocationKind {
  /// `../<repo>-wt/<branch>`, beside the repository (the default).
  nextToRepo,

  /// Herdr's own default, `~/.herdr/worktrees/<repo>/<branch>`.
  herdr,

  /// A path template with `<repo>` and `<branch>`.
  custom,
}

/// The worktree location setting.
@immutable
class WorktreeLocation {
  const WorktreeLocation.nextToRepo()
    : kind = WorktreeLocationKind.nextToRepo,
      template = '';
  const WorktreeLocation.herdr()
    : kind = WorktreeLocationKind.herdr,
      template = '';
  const WorktreeLocation.custom(this.template)
    : kind = WorktreeLocationKind.custom;

  final WorktreeLocationKind kind;

  /// For [WorktreeLocationKind.custom]: e.g. `~/wt/<repo>/<branch>`.
  final String template;

  /// Whether [template] can be used: it names the branch, one line.
  static bool validTemplate(String template) =>
      template.contains('<branch>') &&
      template.length <= 400 &&
      !template.contains('\n');

  /// As the companion's `config set worktree-location` takes it.
  String get wire => switch (kind) {
    WorktreeLocationKind.nextToRepo => 'next-to-repo',
    WorktreeLocationKind.herdr => 'herdr',
    WorktreeLocationKind.custom => template,
  };

  static WorktreeLocation parse(Object? raw) => switch (raw) {
    'herdr' => const WorktreeLocation.herdr(),
    final String t when t != 'next-to-repo' && validTemplate(t) =>
      WorktreeLocation.custom(t),
    _ => const WorktreeLocation.nextToRepo(),
  };

  /// Where [repo]'s worktree for [branch] goes, for display.
  String describe({String repo = '<repo>', String branch = '<branch>'}) =>
      switch (kind) {
        WorktreeLocationKind.nextToRepo => '../$repo-wt/$branch',
        WorktreeLocationKind.herdr => '~/.herdr/worktrees/$repo/$branch',
        WorktreeLocationKind.custom =>
          template.replaceAll('<repo>', repo).replaceAll('<branch>', branch),
      };

  @override
  bool operator ==(Object other) =>
      other is WorktreeLocation &&
      other.kind == kind &&
      other.template == template;

  @override
  int get hashCode => Object.hash(kind, template);
}

/// This device's choices the companions act on: Conductore in Herdr's
/// sidebar (on by default), live tmux updates (off by default: the control
/// client shows in the user's tmux), and the worktree location (next to
/// the repo by default). A change goes to every monitored machine whose companion takes
/// `config`; a machine that connects later gets them once, when they are
/// not the defaults. Read lazily (never at app start).
class CompanionPreferences extends ChangeNotifier {
  CompanionPreferences({
    required this.load,
    required this.save,
    this.attention,
  });

  /// In secure storage under its own key.
  factory CompanionPreferences.secure(
    FlutterSecureStorage storage, {
    AgentAttentionController? attention,
  }) {
    const key = 'conductore.companion_preferences.v1';
    return CompanionPreferences(
      load: () => storage.read(key: key),
      save: (value) => storage.write(key: key, value: value),
      attention: attention,
    );
  }

  /// The app's one instance (Settings reads it; main wires it).
  static CompanionPreferences? instance;

  final Future<String?> Function() load;
  final Future<void> Function(String value) save;
  final AgentAttentionController? attention;

  bool _herdrSidebar = true;
  bool _liveTmux = false;
  WorktreeLocation _worktree = const WorktreeLocation.nextToRepo();
  Future<void>? _loading;
  bool _loaded = false;

  bool get herdrSidebar => _herdrSidebar;

  /// Whether the companion pushes tmux through a hidden control client
  /// (`tmux-live`). Off, the phone lists tmux itself, as before.
  bool get liveTmux => _liveTmux;
  WorktreeLocation get worktreeLocation => _worktree;
  bool get loaded => _loaded;

  Future<void> ensureLoaded() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final raw = await load();
      final decoded = raw == null ? null : jsonDecode(raw);
      if (decoded is Map) {
        _herdrSidebar = decoded['herdrSidebar'] != false;
        _liveTmux = decoded['liveTmux'] == true;
        _worktree = WorktreeLocation.parse(decoded['worktreeLocation']);
      }
    } catch (_) {
      // Unreadable: the defaults.
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> setHerdrSidebar(bool on) async {
    await ensureLoaded();
    if (_herdrSidebar == on) return;
    _herdrSidebar = on;
    await _changed(['herdr-sidebar']);
  }

  Future<void> setLiveTmux(bool on) async {
    await ensureLoaded();
    if (_liveTmux == on) return;
    _liveTmux = on;
    await _changed(['tmux-live']);
  }

  Future<void> setWorktreeLocation(WorktreeLocation location) async {
    await ensureLoaded();
    if (_worktree == location) return;
    if (location.kind == WorktreeLocationKind.custom &&
        !WorktreeLocation.validTemplate(location.template)) {
      return;
    }
    _worktree = location;
    await _changed(['worktree-location']);
  }

  Future<void> _changed(List<String> keys) async {
    notifyListeners();
    await save(
      jsonEncode({
        'herdrSidebar': _herdrSidebar,
        'liveTmux': _liveTmux,
        'worktreeLocation': _worktree.wire,
      }),
    );
    final attention = this.attention;
    if (attention == null) return;
    for (final host in attention.monitoredHosts) {
      if (attention.companionSupports(host.id, companionConfigCapability)) {
        unawaited(_push(host, keys));
      }
    }
  }

  /// A machine's companion reported its capabilities: it gets the
  /// settings that differ from its defaults.
  Future<void> hostConnected(SavedHost host, Set<String> capabilities) async {
    if (!capabilities.contains(companionConfigCapability)) return;
    await ensureLoaded();
    final keys = [
      if (!_herdrSidebar) 'herdr-sidebar',
      if (_liveTmux) 'tmux-live',
      if (_worktree.kind != WorktreeLocationKind.nextToRepo)
        'worktree-location',
    ];
    if (keys.isNotEmpty) await _push(host, keys);
  }

  /// `config set` commands for [keys].
  List<String> commandsFor(List<String> keys) => [
    for (final key in keys)
      ConductoreHostAttentionProvider.remoteCommand(
        'config set $key ${shellQuoteArgument(switch (key) {
          'herdr-sidebar' => _herdrSidebar ? 'on' : 'off',
          'tmux-live' => _liveTmux ? 'on' : 'off',
          _ => _worktree.wire,
        })}',
      ),
  ];

  Future<void> _push(SavedHost host, List<String> keys) async {
    final attention = this.attention;
    if (attention == null) return;
    final (runner, :owned) = attention.runnerFor(host);
    try {
      for (final command in commandsFor(keys)) {
        await runner.run(command, timeout: const Duration(seconds: 10));
      }
    } catch (_) {
      // Best effort: the next connection sends it again.
    } finally {
      if (owned) unawaited(runner.close());
    }
  }
}
