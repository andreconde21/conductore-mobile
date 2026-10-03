import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/domain/agent_kinds.dart';
import 'package:conduit/features/live/domain/live_host_model.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:flutter/foundation.dart';

/// Where a session whose pane runs Claude opens: its terminal (the TUI) or
/// the Chat View.
enum SessionView {
  terminal,
  chat;

  String get label => switch (this) {
    SessionView.terminal => 'Terminal',
    SessionView.chat => 'Chat View',
  };

  static SessionView? fromName(Object? name) =>
      SessionView.values.where((view) => view.name == name).firstOrNull;
}

/// The key a session's view choice is kept under: the saved host id plus
/// the connect target's key (`<hostId>#tmux:work`, `<hostId>#herdr:w1`),
/// or the saved host id alone for a plain shell.
///
/// A Herdr session is one workspace however it was reached, so the tab a
/// deep link focused is left out of the key.
String sessionViewKey(String sessionHostId) {
  final base = baseHostId(sessionHostId);
  final target = ConnectTarget.fromSessionHostId(sessionHostId);
  if (target == null || target.kind == ConnectTargetKind.shell) {
    return base;
  }
  final normalized = target.kind == ConnectTargetKind.herdr
      ? ConnectTarget.herdr(workspaceId: target.name, session: target.session)
      : target;
  return '$base${ConnectTarget.idSeparator}${normalized.key}';
}

/// Whether [agent] is a Claude Code session (the companion also reports
/// Codex, OpenCode and others, which have no Chat View).
bool isClaudeAgent(AgentInfo agent) {
  // Seen only by Herdr: no hooks, so no transcript for a chat view.
  if (isHerdrOnlyAgent(agent)) return false;
  final kind = agent.kind.trim().toLowerCase();
  return kind.isEmpty || kind.startsWith('claude');
}

/// Whether [agent] has a Chat View: its kind reports a transcript format
/// the app renders ([catalog]: the companion's per-kind capabilities,
/// `AgentAttentionController.agentKinds`). With the legacy catalog this is
/// exactly [isClaudeAgent].
bool supportsChatView(
  AgentInfo agent, [
  AgentKindCatalog catalog = AgentKindCatalog.legacy,
]) {
  // Seen only by Herdr: no hooks, so no transcript for a chat view.
  if (isHerdrOnlyAgent(agent)) return false;
  final chat = catalog.of(agent.kind).chat;
  return chat != null && renderableChatFormats.contains(chat);
}

/// The global "Open Claude sessions in" setting and the per-session
/// overrides from long-press › Open in.
@immutable
class SessionViewPreferences {
  const SessionViewPreferences({
    this.defaultView = SessionView.terminal,
    this.overrides = const {},
  });

  static const version = 1;

  final SessionView defaultView;

  /// Per [sessionViewKey]: the view that session always opens in.
  final Map<String, SessionView> overrides;

  SessionView? overrideFor(String sessionHostId) =>
      overrides[sessionViewKey(sessionHostId)];

  /// The view [sessionHostId] opens in: the terminal unless its pane runs
  /// Claude ([runsClaude]); then its override, else the default.
  SessionView resolve(String sessionHostId, {required bool runsClaude}) {
    if (!runsClaude) return SessionView.terminal;
    return overrideFor(sessionHostId) ?? defaultView;
  }

  SessionViewPreferences copyWith({SessionView? defaultView}) =>
      SessionViewPreferences(
        defaultView: defaultView ?? this.defaultView,
        overrides: overrides,
      );

  /// Sets (or with null, clears) the override of [sessionHostId].
  SessionViewPreferences withOverride(String sessionHostId, SessionView? view) {
    final key = sessionViewKey(sessionHostId);
    final next = Map<String, SessionView>.of(overrides);
    if (view == null) {
      next.remove(key);
    } else {
      next[key] = view;
    }
    return SessionViewPreferences(
      defaultView: defaultView,
      overrides: Map.unmodifiable(next),
    );
  }

  Map<String, Object?> toJson() => {
    'version': version,
    'default': defaultView.name,
    'overrides': {
      for (final MapEntry(:key, :value) in overrides.entries) key: value.name,
    },
  };

  static SessionViewPreferences fromJson(Object? json) {
    if (json is! Map || json['version'] != version) {
      return const SessionViewPreferences();
    }
    final raw = json['overrides'];
    return SessionViewPreferences(
      defaultView:
          SessionView.fromName(json['default']) ?? SessionView.terminal,
      overrides: Map.unmodifiable({
        if (raw is Map)
          for (final MapEntry(:key, :value) in raw.entries)
            if (key is String && SessionView.fromName(value) != null)
              key: SessionView.fromName(value)!,
      }),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SessionViewPreferences &&
      other.defaultView == defaultView &&
      mapEquals(other.overrides, overrides);

  @override
  int get hashCode => Object.hash(
    defaultView,
    Object.hashAllUnordered([
      for (final MapEntry(:key, :value) in overrides.entries) (key, value),
    ]),
  );
}

/// Where [SessionViewPreferences] are kept between app runs.
abstract interface class SessionViewPreferencesRepository {
  Future<SessionViewPreferences> load();

  Future<void> save(SessionViewPreferences preferences);
}

/// Keeps the preferences for the app run only (tests, no storage).
class InMemorySessionViewPreferencesRepository
    implements SessionViewPreferencesRepository {
  InMemorySessionViewPreferencesRepository([
    this.stored = const SessionViewPreferences(),
  ]);

  SessionViewPreferences stored;

  @override
  Future<SessionViewPreferences> load() async => stored;

  @override
  Future<void> save(SessionViewPreferences preferences) async {
    stored = preferences;
  }
}
