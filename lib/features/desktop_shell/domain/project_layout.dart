import 'package:flutter/foundation.dart';

/// One project of the project layout (sheprd's `[[group]]`): a name,
/// pinned to the top or not, substring rules that catch workspaces by name
/// or folder, explicit members in display order and a short tag.
@immutable
class ProjectDef {
  const ProjectDef({
    required this.name,
    this.pinned = false,
    this.collapsed = false,
    this.members = const [],
    this.match = const [],
    this.short,
  });

  final String name;
  final bool pinned;

  /// Collapsed in sheprd. The app keeps its own collapsed state (see
  /// `ProjectPrefs.collapsed`) and only starts from this one.
  final bool collapsed;

  /// Workspace keys (`machine/<id>:<label>` or `machine/<label>`), in
  /// display order. See [ProjectKeys].
  final List<String> members;

  /// Lower-cased substrings of a workspace's name or folder.
  final List<String> match;

  /// Two-letter tag; derived from [name] when unset ([tag]).
  final String? short;

  String get tag => projectTag(name, short);

  ProjectDef copyWith({
    String? name,
    bool? pinned,
    bool? collapsed,
    List<String>? members,
    List<String>? match,
    String? short,
    bool clearShort = false,
  }) => ProjectDef(
    name: name ?? this.name,
    pinned: pinned ?? this.pinned,
    collapsed: collapsed ?? this.collapsed,
    members: members ?? this.members,
    match: match ?? this.match,
    short: clearShort ? null : (short ?? this.short),
  );

  /// sheprd's spelling: `match`, and false / empty values left out.
  Map<String, Object?> toJson() => {
    'name': name,
    if (pinned) 'pinned': true,
    if (collapsed) 'collapsed': true,
    if (members.isNotEmpty) 'members': members,
    if (match.isNotEmpty) 'match': match,
    if (short != null) 'short': short,
  };

  static ProjectDef? fromJson(Object? json) {
    if (json is! Map) return null;
    final name = json['name'];
    if (name is! String || name.trim().isEmpty) return null;
    final short = json['short'];
    return ProjectDef(
      name: name.trim(),
      pinned: json['pinned'] == true,
      collapsed: json['collapsed'] == true,
      members: _strings(json['members']),
      match: _strings(json['match']),
      short: short is String && short.trim().isNotEmpty ? short.trim() : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ProjectDef &&
      other.name == name &&
      other.pinned == pinned &&
      other.collapsed == collapsed &&
      listEquals(other.members, members) &&
      listEquals(other.match, match) &&
      other.short == short;

  @override
  int get hashCode => Object.hash(
    name,
    pinned,
    collapsed,
    Object.hashAll(members),
    Object.hashAll(match),
    short,
  );

  @override
  String toString() => 'ProjectDef($name)';
}

/// Which projects exist and what goes in them: sheprd's `sidebar.toml`
/// (`hidden`, `ungrouped`, `[[group]]`) plus its view settings, in the
/// same JSON spelling the companion's `sidebar-layout` reports, so a
/// layout read from a machine and one edited in the app are one model.
@immutable
class ProjectLayout {
  const ProjectLayout({
    this.groups = const [],
    this.hidden = const [],
    this.ungrouped = const [],
    this.compact,
    this.activeOnly,
    this.recentHours,
    this.otherCollapsed = false,
  });

  static const empty = ProjectLayout();

  /// Projects in file order; [displayOrder] puts the pinned ones first.
  final List<ProjectDef> groups;

  /// Workspace keys left out of the view.
  final List<String> hidden;

  /// Workspace keys moved to Other: no rule pulls them into a project.
  final List<String> ungrouped;

  /// View settings as sheprd saved them; null where it did not say.
  final bool? compact;
  final bool? activeOnly;
  final int? recentHours;
  final bool otherCollapsed;

  bool get isEmpty => groups.isEmpty && hidden.isEmpty && ungrouped.isEmpty;

  /// Group indices in display order: pinned first, else file order.
  List<int> get displayOrder {
    final order = [for (var i = 0; i < groups.length; i++) i];
    // A stable sort: List.sort is not.
    return [
      for (final i in order)
        if (groups[i].pinned) i,
      for (final i in order)
        if (!groups[i].pinned) i,
    ];
  }

  ProjectDef? byName(String name) => groups
      .where((group) => group.name.toLowerCase() == name.trim().toLowerCase())
      .firstOrNull;

  bool isHidden(String key) =>
      hidden.any((entry) => ProjectKeys.same(entry, key));

  bool isUngrouped(String key) =>
      ungrouped.any((entry) => ProjectKeys.same(entry, key));

  /// The group [key] is an explicit member of.
  int? explicitGroup(String key) {
    for (var i = 0; i < groups.length; i++) {
      if (groups[i].members.any((member) => ProjectKeys.same(member, key))) {
        return i;
      }
    }
    return null;
  }

  /// The group of a workspace: none when it was moved to Other, else the
  /// group listing it, else the first whose rule is a substring of its
  /// name or of one of its folders ([haystack]).
  int? groupOf(String key, Iterable<String> haystack) {
    if (isUngrouped(key)) return null;
    final explicit = explicitGroup(key);
    if (explicit != null) return explicit;
    final texts = [for (final text in haystack) text.toLowerCase()];
    for (var i = 0; i < groups.length; i++) {
      for (final rule in groups[i].match) {
        final needle = rule.trim().toLowerCase();
        if (needle.isEmpty) continue;
        if (texts.any((text) => text.contains(needle))) return i;
      }
    }
    return null;
  }

  /// Rank of [key] inside group [index]: explicit members first, in
  /// member order; rule matches after them.
  int memberRank(int index, String key) {
    final at = groups[index].members.indexWhere(
      (member) => ProjectKeys.same(member, key),
    );
    return at < 0 ? 1 << 30 : at;
  }

  ProjectLayout copyWith({
    List<ProjectDef>? groups,
    List<String>? hidden,
    List<String>? ungrouped,
    bool? otherCollapsed,
  }) => ProjectLayout(
    groups: groups ?? this.groups,
    hidden: hidden ?? this.hidden,
    ungrouped: ungrouped ?? this.ungrouped,
    compact: compact,
    activeOnly: activeOnly,
    recentHours: recentHours,
    otherCollapsed: otherCollapsed ?? this.otherCollapsed,
  );

  /// Moves workspace [key] into project [name] (made when missing), at
  /// the end of its members; an empty name moves it to Other, where no
  /// rule catches it again until it is moved into a project.
  ProjectLayout assign(String key, String name) {
    final target = name.trim();
    final cleaned = [
      for (final group in groups)
        group.copyWith(
          members: [
            for (final member in group.members)
              if (!ProjectKeys.same(member, key)) member,
          ],
        ),
    ];
    final ungroupedNow = [
      for (final entry in ungrouped)
        if (!ProjectKeys.same(entry, key)) entry,
    ];
    if (target.isEmpty) {
      return copyWith(groups: cleaned, ungrouped: [...ungroupedNow, key]);
    }
    final at = cleaned.indexWhere(
      (group) => group.name.toLowerCase() == target.toLowerCase(),
    );
    final next = at < 0
        ? [
            ...cleaned,
            ProjectDef(name: target, members: [key]),
          ]
        : [
            for (var i = 0; i < cleaned.length; i++)
              i == at
                  ? cleaned[i].copyWith(members: [...cleaned[i].members, key])
                  : cleaned[i],
          ];
    return copyWith(groups: next, ungrouped: ungroupedNow);
  }

  ProjectLayout toggleHidden(String key) => copyWith(
    hidden: isHidden(key)
        ? [
            for (final entry in hidden)
              if (!ProjectKeys.same(entry, key)) entry,
          ]
        : [...hidden, key],
  );

  ProjectLayout _edit(String name, ProjectDef Function(ProjectDef) edit) =>
      copyWith(
        groups: [
          for (final group in groups) group.name == name ? edit(group) : group,
        ],
      );

  ProjectLayout setPinned(String name, bool pinned) =>
      _edit(name, (group) => group.copyWith(pinned: pinned));

  /// The rules, lower-cased, blanks and repeats dropped.
  ProjectLayout setRules(String name, List<String> rules) => _edit(
    name,
    (group) => group.copyWith(
      match: {
        for (final rule in rules)
          if (rule.trim().isNotEmpty) rule.trim().toLowerCase(),
      }.toList(),
    ),
  );

  ProjectLayout rename(String name, String to) {
    final next = to.trim();
    if (next.isEmpty || (byName(next) != null && byName(next)!.name != name)) {
      return this;
    }
    return _edit(name, (group) => group.copyWith(name: next));
  }

  /// Deletes project [name]; its workspaces go to Other (or to another
  /// project whose rule catches them).
  ProjectLayout remove(String name) => copyWith(
    groups: [
      for (final group in groups)
        if (group.name != name) group,
    ],
  );

  /// Adds project [name] with [rules] (or only the rules, when it exists).
  ProjectLayout add(String name, {List<String> rules = const []}) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return this;
    final existing = byName(trimmed);
    final withGroup = existing != null
        ? this
        : copyWith(
            groups: [
              ...groups,
              ProjectDef(name: trimmed),
            ],
          );
    final current = withGroup.byName(trimmed)!;
    return withGroup.setRules(current.name, [...current.match, ...rules]);
  }

  /// This layout as read from machine [machineKey]: sheprd's `local/`
  /// (the machine holding the file) becomes that machine's key.
  ProjectLayout localized(String machineKey) {
    String fix(String key) => key.toLowerCase().startsWith('local/')
        ? '$machineKey/${key.substring('local/'.length)}'
        : key;
    return ProjectLayout(
      groups: [
        for (final group in groups)
          group.copyWith(members: [for (final m in group.members) fix(m)]),
      ],
      hidden: [for (final key in hidden) fix(key)],
      ungrouped: [for (final key in ungrouped) fix(key)],
      compact: compact,
      activeOnly: activeOnly,
      recentHours: recentHours,
      otherCollapsed: otherCollapsed,
    );
  }

  /// Several machines' layouts as one: projects of the same name (any
  /// case) merge their members, rules and pin; lists are joined; view
  /// settings come from the first layout that has them.
  static ProjectLayout merge(Iterable<ProjectLayout> layouts) {
    final list = layouts.toList();
    if (list.isEmpty) return empty;
    if (list.length == 1) return list.single;
    final groups = <String, ProjectDef>{};
    final hidden = <String>[];
    final ungrouped = <String>[];
    for (final layout in list) {
      for (final group in layout.groups) {
        final id = group.name.toLowerCase();
        final known = groups[id];
        groups[id] = known == null
            ? group
            : known.copyWith(
                pinned: known.pinned || group.pinned,
                collapsed: known.collapsed && group.collapsed,
                members: {...known.members, ...group.members}.toList(),
                match: {...known.match, ...group.match}.toList(),
                short: known.short ?? group.short,
              );
      }
      for (final key in layout.hidden) {
        if (!hidden.contains(key)) hidden.add(key);
      }
      for (final key in layout.ungrouped) {
        if (!ungrouped.contains(key)) ungrouped.add(key);
      }
    }
    T? first<T extends Object>(T? Function(ProjectLayout layout) of) {
      for (final layout in list) {
        final value = of(layout);
        if (value != null) return value;
      }
      return null;
    }

    return ProjectLayout(
      groups: groups.values.toList(),
      hidden: hidden,
      ungrouped: ungrouped,
      compact: first((layout) => layout.compact),
      activeOnly: first((layout) => layout.activeOnly),
      recentHours: first((layout) => layout.recentHours),
      otherCollapsed: list.every((layout) => layout.otherCollapsed),
    );
  }

  /// sheprd's spelling (`group`, `active_only`, `recent_hours`, ...).
  Map<String, Object?> toJson() => {
    if (compact != null) 'compact': compact,
    if (activeOnly != null) 'active_only': activeOnly,
    if (recentHours != null) 'recent_hours': recentHours,
    if (otherCollapsed) 'other_collapsed': true,
    if (hidden.isNotEmpty) 'hidden': hidden,
    if (ungrouped.isNotEmpty) 'ungrouped': ungrouped,
    if (groups.isNotEmpty) 'group': [for (final g in groups) g.toJson()],
  };

  static ProjectLayout fromJson(Object? json) {
    if (json is! Map) return empty;
    final rawGroups = json['group'];
    final hours = json['recent_hours'];
    final compact = json['compact'];
    final active = json['active_only'];
    final seen = <String>{};
    return ProjectLayout(
      groups: [
        if (rawGroups is List)
          for (final raw in rawGroups)
            if (ProjectDef.fromJson(raw) case final group?
                when seen.add(group.name.toLowerCase()))
              group,
      ],
      hidden: _strings(json['hidden']),
      ungrouped: _strings(json['ungrouped']),
      compact: compact is bool ? compact : null,
      activeOnly: active is bool ? active : null,
      recentHours: hours is int && hours > 0 ? hours : null,
      otherCollapsed: json['other_collapsed'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ProjectLayout &&
      listEquals(other.groups, groups) &&
      listEquals(other.hidden, hidden) &&
      listEquals(other.ungrouped, ungrouped) &&
      other.compact == compact &&
      other.activeOnly == activeOnly &&
      other.recentHours == recentHours &&
      other.otherCollapsed == otherCollapsed;

  @override
  int get hashCode => Object.hash(
    Object.hashAll(groups),
    Object.hashAll(hidden),
    Object.hashAll(ungrouped),
    compact,
    activeOnly,
    recentHours,
    otherCollapsed,
  );
}

/// Workspace keys as sheprd writes them: `machine/<id>:<label>` for a
/// Herdr workspace (the id survives renames; the label keeps the file
/// readable), `machine/<label>` for everything else and in older files.
/// The machine part is the machine's name, lower-cased; sheprd's `local`
/// is resolved by [ProjectLayout.localized].
abstract final class ProjectKeys {
  static String herdr(String machine, String workspaceId, String label) =>
      '${machine.toLowerCase()}/$workspaceId:$label';

  static String named(String machine, String label) =>
      '${machine.toLowerCase()}/$label';

  static (String, String)? _splitId(String rest) {
    final at = rest.indexOf(':');
    if (at < 2) return null;
    final id = rest.substring(0, at);
    if (!RegExp(r'^w[A-Za-z0-9]+$').hasMatch(id)) return null;
    return (id, rest.substring(at + 1));
  }

  /// Whether stored [entry] (either form) names workspace [key].
  static bool same(String entry, String key) {
    final e = entry.indexOf('/');
    final k = key.indexOf('/');
    if (e < 0 || k < 0) return entry == key;
    if (entry.substring(0, e).toLowerCase() !=
        key.substring(0, k).toLowerCase()) {
      return false;
    }
    final entryRest = entry.substring(e + 1);
    final rest = key.substring(k + 1);
    final entryId = _splitId(entryRest);
    final keyId = _splitId(rest);
    if (entryId != null && keyId != null) return entryId.$1 == keyId.$1;
    if (entryId == null && keyId != null) return entryRest == keyId.$2;
    if (entryId != null && keyId == null) return entryId.$2 == rest;
    return entryRest == rest;
  }

  /// The machine part of [key].
  static String machineOf(String key) {
    final at = key.indexOf('/');
    return at < 0 ? '' : key.substring(0, at);
  }
}

/// sheprd's rail tag: [short] when set, else the first letters of the
/// first two words ("Outsmartis ops" → "OO"), else two capitals
/// ("TheCalendar" → "TC"), else the first two letters ("Infra" → "In").
String projectTag(String name, [String? short]) {
  String take(String text, int n) => String.fromCharCodes(text.runes.take(n));
  final own = short?.trim() ?? '';
  if (own.isNotEmpty) return take(own, 2);
  final words = name.trim().split(RegExp(r'\s+'))
    ..removeWhere((word) => word.isEmpty);
  if (words.length >= 2) {
    return words.take(2).map((word) => take(word, 1).toUpperCase()).join();
  }
  final letters = [for (final rune in name.runes) String.fromCharCode(rune)];
  final capitals = letters
      .where((c) => c != c.toLowerCase() && c == c.toUpperCase())
      .take(2)
      .toList();
  if (capitals.length == 2) return capitals.join();
  if (letters.isEmpty) return '';
  return letters.first.toUpperCase() +
      (letters.length > 1 ? letters[1].toLowerCase() : '');
}

/// The app's own choices for the project view, synced with the other
/// app settings: the layout once edited here (null follows the
/// machines' sidebar.toml), the view, the filter, collapsed projects and
/// whether the phone home and the agents dashboard group by project.
@immutable
class ProjectPrefs {
  const ProjectPrefs({
    this.layout,
    this.compact,
    this.activeOnly,
    this.recentHours,
    this.collapsed = const {},
    this.groupByProject = false,
    this.showHidden = false,
  });

  static const defaults = ProjectPrefs();
  static const defaultRecentHours = 24;

  /// Edited in the app; null until then, so the layout read from the
  /// machines (sheprd's sidebar.toml) is used.
  final ProjectLayout? layout;

  /// Null: as sheprd's file says, else detailed / all.
  final bool? compact;
  final bool? activeOnly;
  final int? recentHours;

  /// Per project name (lower-cased) and `\u0000other`: collapsed or not.
  final Map<String, bool> collapsed;

  /// The phone home and the agents dashboard group by project.
  final bool groupByProject;
  final bool showHidden;

  static const otherKey = '\u0000other';

  ProjectPrefs copyWith({
    ProjectLayout? layout,
    bool clearLayout = false,
    bool? compact,
    bool? activeOnly,
    int? recentHours,
    Map<String, bool>? collapsed,
    bool? groupByProject,
    bool? showHidden,
  }) => ProjectPrefs(
    layout: clearLayout ? null : (layout ?? this.layout),
    compact: compact ?? this.compact,
    activeOnly: activeOnly ?? this.activeOnly,
    recentHours: recentHours ?? this.recentHours,
    collapsed: collapsed ?? this.collapsed,
    groupByProject: groupByProject ?? this.groupByProject,
    showHidden: showHidden ?? this.showHidden,
  );

  Map<String, Object?> toJson() => {
    if (layout != null) 'layout': layout!.toJson(),
    if (compact != null) 'compact': compact,
    if (activeOnly != null) 'activeOnly': activeOnly,
    if (recentHours != null) 'recentHours': recentHours,
    if (collapsed.isNotEmpty) 'collapsed': collapsed,
    if (groupByProject) 'groupByProject': true,
    if (showHidden) 'showHidden': true,
  };

  static ProjectPrefs fromJson(Object? json) {
    if (json is! Map) return defaults;
    final collapsed = <String, bool>{};
    final raw = json['collapsed'];
    if (raw is Map) {
      for (final MapEntry(:key, :value) in raw.entries) {
        if (key is String && value is bool) collapsed[key] = value;
      }
    }
    final compact = json['compact'];
    final active = json['activeOnly'];
    final hours = json['recentHours'];
    return ProjectPrefs(
      layout: json['layout'] is Map
          ? ProjectLayout.fromJson(json['layout'])
          : null,
      compact: compact is bool ? compact : null,
      activeOnly: active is bool ? active : null,
      recentHours: hours is int && hours > 0 ? hours : null,
      collapsed: collapsed,
      groupByProject: json['groupByProject'] == true,
      showHidden: json['showHidden'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ProjectPrefs &&
      other.layout == layout &&
      other.compact == compact &&
      other.activeOnly == activeOnly &&
      other.recentHours == recentHours &&
      mapEquals(other.collapsed, collapsed) &&
      other.groupByProject == groupByProject &&
      other.showHidden == showHidden;

  @override
  int get hashCode => Object.hash(
    layout,
    compact,
    activeOnly,
    recentHours,
    collapsed.length,
    groupByProject,
    showHidden,
  );
}

List<String> _strings(Object? raw) => [
  if (raw is List)
    for (final item in raw)
      if (item is String && item.isNotEmpty) item,
];
