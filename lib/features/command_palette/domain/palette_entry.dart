import 'package:conduit/features/session_navigation/presentation/quick_switcher_model.dart'
    show fuzzyScore;
import 'package:flutter/widgets.dart';

/// What a palette row stands for; the prefixes narrow the list to some of
/// them (see [PaletteScope]).
enum PaletteKind {
  /// An agent waiting on the user, or any agent.
  agent('Agent'),

  /// A session open in the app.
  session('Session'),

  /// A Herdr workspace or tmux session that is not open.
  workspace('Workspace'),

  /// A recent connect target.
  recent('Recent'),

  /// A project (repo) across machines.
  project('Project'),

  /// A project's quick action.
  quickAction('Quick action'),

  /// A split layout: a preset or a saved one.
  layout('Layout'),

  /// A Settings page.
  settings('Settings'),

  /// Everything else the app does.
  command('Command');

  const PaletteKind(this.label);

  final String label;
}

/// Which rows a query lists, chosen by its first character.
enum PaletteScope {
  /// No prefix: everything, places first.
  all(''),

  /// `>`: commands, layouts, settings, quick actions.
  commands('>'),

  /// `@`: agents.
  agents('@'),

  /// `#`: sessions, workspaces, recents and projects.
  places('#');

  const PaletteScope(this.prefix);

  final String prefix;

  bool includes(PaletteKind kind) => switch (this) {
    PaletteScope.all => true,
    PaletteScope.commands =>
      kind == PaletteKind.command ||
          kind == PaletteKind.layout ||
          kind == PaletteKind.settings ||
          kind == PaletteKind.quickAction,
    PaletteScope.agents => kind == PaletteKind.agent,
    PaletteScope.places =>
      kind == PaletteKind.session ||
          kind == PaletteKind.workspace ||
          kind == PaletteKind.recent ||
          kind == PaletteKind.project,
  };

  /// The hint of the search field in this scope.
  String get hint => switch (this) {
    PaletteScope.all =>
      'Search sessions, agents, commands…   > commands  @ agents  # places',
    PaletteScope.commands => 'Run a command, layout or setting',
    PaletteScope.agents => 'Go to an agent',
    PaletteScope.places => 'Go to a session, workspace or project',
  };
}

/// A query split into its scope and the words searched.
typedef PaletteQuery = ({PaletteScope scope, String text});

/// Reads the scope prefix off [raw] (`>`, `@` or `#`).
PaletteQuery parsePaletteQuery(String raw) {
  final trimmed = raw.trimLeft();
  for (final scope in PaletteScope.values) {
    if (scope.prefix.isNotEmpty && trimmed.startsWith(scope.prefix)) {
      return (scope: scope, text: trimmed.substring(1).trim());
    }
  }
  return (scope: PaletteScope.all, text: raw.trim());
}

/// One row of the command palette.
@immutable
class PaletteEntry {
  const PaletteEntry({
    required this.id,
    required this.title,
    required this.kind,
    required this.run,
    this.subtitle = '',
    this.icon,
    this.leading,
    this.shortcut,
    this.keywords = const [],
    this.enabled = true,
    this.urgent = false,
  });

  /// Stable id, for recents and widget keys (`command:settings`,
  /// `session:<host id>`…).
  final String id;
  final String title;
  final String subtitle;
  final PaletteKind kind;
  final IconData? icon;

  /// Drawn instead of [icon] (a multiplexer logo, an agent badge).
  final Widget? leading;

  /// The keys that do the same, shown at the right ("Ctrl+Shift+T").
  final String? shortcut;

  /// Extra words a search matches (synonyms, machine names).
  final List<String> keywords;

  /// Greyed out and not run (a split with six panes already).
  final bool enabled;

  /// Waits on the user: listed first when nothing is typed.
  final bool urgent;

  /// Runs it; the palette is closed by then.
  final Future<void> Function() run;

  /// What a search looks in: the title first, then the rest.
  List<String> get searchTerms => [
    title,
    if (subtitle.isNotEmpty) subtitle,
    kind.label,
    ...keywords,
  ];
}

/// How well [entry] matches [text]: every word must match one of its
/// search terms (the title counts most). Null when a word does not.
int? paletteMatch(PaletteEntry entry, String text) {
  final words = text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
  var total = 0;
  for (final word in words) {
    int? best;
    final terms = entry.searchTerms;
    for (var i = 0; i < terms.length; i += 1) {
      final score = fuzzyScore(word, terms[i]);
      if (score == null) continue;
      // The title outranks subtitles and keywords.
      final weighted = i == 0 ? score + 150 : score;
      if (best == null || weighted > best) best = weighted;
    }
    if (best == null) return null;
    total += best;
  }
  // The whole query as typed, in the title: "side by side" finds the
  // layout before "Sidebar: group by project".
  final phrase = text.trim().toLowerCase();
  if (phrase.contains(' ') && entry.title.toLowerCase().contains(phrase)) {
    total += 600;
  }
  return total;
}

/// The rows [raw] lists from [entries], best first.
///
/// With nothing typed: what waits on the user, then the recently run
/// entries ([recents], most recent first), then the rest in the given
/// order. With a query: by match score, recently run ones a little
/// higher; ties keep the given order.
List<PaletteEntry> rankPalette(
  List<PaletteEntry> entries,
  String raw, {
  List<String> recents = const [],
}) {
  final query = parsePaletteQuery(raw);
  final inScope = [
    for (final entry in entries)
      if (query.scope.includes(entry.kind)) entry,
  ];
  final order = {for (final (i, entry) in inScope.indexed) entry.id: i};
  int recency(PaletteEntry entry) {
    final index = recents.indexOf(entry.id);
    return index < 0 ? 0 : 200 - (index * 20).clamp(0, 180);
  }

  if (query.text.isEmpty) {
    final urgent = [
      for (final entry in inScope)
        if (entry.urgent) entry,
    ];
    final recent = [
      for (final id in recents)
        ?inScope.where((entry) => entry.id == id && !entry.urgent).firstOrNull,
    ];
    final shown = {...urgent, ...recent};
    return [
      ...urgent,
      ...recent,
      for (final entry in inScope)
        if (!shown.contains(entry)) entry,
    ];
  }
  final scored = <(PaletteEntry, int)>[];
  for (final entry in inScope) {
    final score = paletteMatch(entry, query.text);
    if (score != null) scored.add((entry, score + recency(entry)));
  }
  scored.sort((a, b) {
    final byScore = b.$2.compareTo(a.$2);
    return byScore != 0 ? byScore : order[a.$1.id]!.compareTo(order[b.$1.id]!);
  });
  return [for (final (entry, _) in scored) entry];
}

/// The recents list after running [id]: it moves to the front, and only
/// the [max] most recent are kept.
List<String> notePaletteRecent(
  List<String> recents,
  String id, {
  int max = 20,
}) {
  return [id, ...recents.where((other) => other != id)].take(max).toList();
}
