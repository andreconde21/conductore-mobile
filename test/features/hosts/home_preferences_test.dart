import 'package:conduit/features/hosts/domain/home_preferences.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('round-trips through JSON', () {
    const preferences = HomePreferences(
      machineFilter: {'b', 'a', 'local'},
      sessionsView: HomeSessionsView.list,
      workspacesView: HomeWorkspacesView.list,
    );
    final json = preferences.toJson();
    expect(json['machineFilter'], ['a', 'b', 'local']);
    expect(HomePreferences.fromJson(json), preferences);
  });

  test('unknown or missing values fall back to the defaults', () {
    expect(HomePreferences.fromJson(null), const HomePreferences());
    expect(
      HomePreferences.fromJson(const {
        'machineFilter': ['a', 3],
        'sessionsView': 'mosaic',
      }),
      const HomePreferences(machineFilter: {'a'}),
    );
  });

  test('the home mode round-trips, and older saves have none', () {
    const projects = HomePreferences(mode: HomeMode.projects);
    expect(projects.toJson()['mode'], 'projects');
    expect(HomePreferences.fromJson(projects.toJson()), projects);
    expect(
      HomePreferences.fromJson(
        const HomePreferences(mode: HomeMode.openClosed).toJson(),
      ).mode,
      HomeMode.openClosed,
    );
    // Saved before CON-105: no key, no mode (the page picks one).
    expect(const HomePreferences().toJson().containsKey('mode'), isFalse);
    expect(
      HomePreferences.fromJson(const {
        'sessionsView': 'list',
        'workspacesView': 'grid',
      }).mode,
      isNull,
    );
    expect(HomePreferences.fromJson(const {'mode': 'tiles'}).mode, isNull);
  });
}
