import 'package:flutter/foundation.dart';

/// How the home page lays out open sessions.
enum HomeSessionsView {
  /// Live preview tiles, two columns on a phone.
  grid,

  /// Live preview tiles, one column on a phone.
  large,

  /// Compact rows.
  list,
}

/// How the home page lays out the other (not open) workspaces.
enum HomeWorkspacesView { grid, list }

/// What the home page shows (CON-105), switched in its top bar.
enum HomeMode {
  /// Everything by project: one box per project group, open and closed
  /// workspaces together, the open ones marked in place.
  projects,

  /// Open sessions first, then the other workspaces by machine.
  openClosed,
}

/// The home page's remembered choices.
@immutable
class HomePreferences {
  const HomePreferences({
    this.machineFilter = const {},
    this.sessionsView = HomeSessionsView.grid,
    this.workspacesView = HomeWorkspacesView.grid,
    this.mode,
  });

  factory HomePreferences.fromJson(Object? json) {
    if (json is! Map) return const HomePreferences();
    final filter = json['machineFilter'];
    return HomePreferences(
      machineFilter: filter is List ? filter.whereType<String>().toSet() : {},
      sessionsView:
          HomeSessionsView.values
              .where((value) => value.name == json['sessionsView'])
              .firstOrNull ??
          HomeSessionsView.grid,
      workspacesView:
          HomeWorkspacesView.values
              .where((value) => value.name == json['workspacesView'])
              .firstOrNull ??
          HomeWorkspacesView.grid,
      mode: HomeMode.values
          .where((value) => value.name == json['mode'])
          .firstOrNull,
    );
  }

  /// Keys of the machines the page is filtered to (saved host ids, and
  /// `local` for the on-device shells); empty means every machine.
  final Set<String> machineFilter;
  final HomeSessionsView sessionsView;
  final HomeWorkspacesView workspacesView;

  /// The mode last picked; null until the user picks one, when the page
  /// chooses (Projects with a project layout, else Open / Closed).
  final HomeMode? mode;

  HomePreferences copyWith({
    Set<String>? machineFilter,
    HomeSessionsView? sessionsView,
    HomeWorkspacesView? workspacesView,
    HomeMode? mode,
  }) {
    return HomePreferences(
      machineFilter: machineFilter ?? this.machineFilter,
      sessionsView: sessionsView ?? this.sessionsView,
      workspacesView: workspacesView ?? this.workspacesView,
      mode: mode ?? this.mode,
    );
  }

  Map<String, Object?> toJson() => {
    'machineFilter': machineFilter.toList()..sort(),
    'sessionsView': sessionsView.name,
    'workspacesView': workspacesView.name,
    if (mode != null) 'mode': mode!.name,
  };

  @override
  bool operator ==(Object other) =>
      other is HomePreferences &&
      setEquals(other.machineFilter, machineFilter) &&
      other.sessionsView == sessionsView &&
      other.workspacesView == workspacesView &&
      other.mode == mode;

  @override
  int get hashCode => Object.hash(
    Object.hashAllUnordered(machineFilter),
    sessionsView,
    workspacesView,
    mode,
  );
}

/// Where [HomePreferences] are kept.
abstract interface class HomePreferencesRepository {
  Future<HomePreferences> load();

  Future<void> save(HomePreferences preferences);
}

/// Keeps preferences for the app's lifetime only (tests, previews).
class InMemoryHomePreferencesRepository implements HomePreferencesRepository {
  InMemoryHomePreferencesRepository([this.stored = const HomePreferences()]);

  HomePreferences stored;
  int saves = 0;

  @override
  Future<HomePreferences> load() async => stored;

  @override
  Future<void> save(HomePreferences preferences) async {
    stored = preferences;
    saves += 1;
  }
}
