/// How an agent is named wherever the app lists it: session tiles, the
/// dashboard and the notifications (CON-079). Pure.
///
/// An agent is its project (the repository it works in), never a folder
/// hash: a Claude Code worktree (`<repo>/.claude/worktrees/agent-<hex>`)
/// or a Herdr one (`~/.herdr/worktrees/<repo>/<branch>`) names the
/// repository above it.
library;

/// The project a working directory belongs to: its basename, or the
/// repository above a worktree directory. Null for no path.
String? projectFromPath(String? path) {
  if (path == null) return null;
  final parts = path.split('/').where((part) => part.isNotEmpty).toList();
  if (parts.isEmpty) return null;
  for (var i = parts.length - 1; i > 0; i--) {
    if (parts[i] != 'worktrees') continue;
    final owner = parts[i - 1];
    // <repo>/.claude/worktrees/<x>, <repo>/.worktrees/<x> style.
    if (owner == '.claude' || owner == '.codex' || owner == '.cursor') {
      if (i >= 2) return parts[i - 2];
    }
    // ~/.herdr/worktrees/<repo>/<branch>.
    if (owner == '.herdr' && i + 1 < parts.length) return parts[i + 1];
  }
  for (var i = parts.length - 1; i > 0; i--) {
    if (parts[i] == '.worktrees') return parts[i - 1];
  }
  // A machine-made directory name says nothing: name its parent.
  var last = parts.length - 1;
  while (last > 0 && isOpaqueName(parts[last])) {
    last -= 1;
  }
  return parts[last];
}

/// Whether [name] is a generated id rather than a name a person gave:
/// `agent-a205b124f4354e391`, a UUID, a bare hex hash.
bool isOpaqueName(String name) => _opaque.hasMatch(name.trim());

final _opaque = RegExp(
  r'^(?:(?:agent|subagent|worktree|wt|task)[-_])?'
  r'(?:[0-9a-f]{12,}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$',
  caseSensitive: false,
);

/// The name to show for an agent: its [project] label, else its own
/// [name] unless that is a generated id, else "Agent".
String agentDisplayName({String? project, String? name}) {
  for (final candidate in [project, name]) {
    final trimmed = candidate?.trim();
    if (trimmed != null && trimmed.isNotEmpty && !isOpaqueName(trimmed)) {
      return trimmed;
    }
  }
  return 'Agent';
}

/// What an agent is about, for a line under or after its name: the
/// dashboard's [summary], else its [lastMessage] unless that is only the
/// agent's generic notice ("Claude is waiting for your input"). Null when
/// neither says anything.
String? agentTopic({String? summary, String? lastMessage}) {
  final digest = summary?.trim();
  if (digest != null && digest.isNotEmpty) return digest;
  final message = lastMessage?.trim() ?? '';
  if (message.isEmpty || isGenericNotice(message)) return null;
  return message;
}

/// "Claude is waiting for your input", "Codex needs your permission":
/// the agent's notification text, which names nothing.
bool isGenericNotice(String message) => _genericNotice.hasMatch(message.trim());

final _genericNotice = RegExp(
  r'^\w+( \w+)? (is waiting for your input|needs your (permission|attention))',
  caseSensitive: false,
);
