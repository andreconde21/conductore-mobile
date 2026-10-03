import 'package:conduit/core/theme/theme_controller.dart';
import 'package:conduit/core/theme/theme_preferences_repository.dart';
import 'package:conduit/features/desktop_shell/domain/project_layout.dart';
import 'package:conduit/features/sync/data/app_settings_codec.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

void main() {
  const prefs = ProjectPrefs(
    layout: ProjectLayout(
      groups: [
        ProjectDef(
          name: 'storefront',
          pinned: true,
          members: ['dev/w1:notes'],
          match: ['storefront'],
        ),
      ],
      ungrouped: ['dev/w9:old'],
    ),
    compact: true,
    collapsed: {'storefront': true},
    groupByProject: true,
  );

  test('the project view syncs with the other app settings', () async {
    final from = ThemeController(InMemoryThemePreferences());
    await from.load();
    await from.setProjectPrefs(prefs);
    final json = AppSettingsCodec.encode(from);
    expect(AppSettingsCodec.keys, contains('projects'));
    expect(json['projects'], prefs.toJson());

    final to = ThemeController(InMemoryThemePreferences());
    await to.load();
    await AppSettingsCodec.apply(to, json);
    expect(to.projectPrefs, prefs);
  });

  test('the project view is stored and read back', () async {
    final storage = InMemorySecureStorage();
    final controller = ThemeController(ThemePreferencesRepository(storage));
    await controller.load();
    expect(controller.projectPrefs, ProjectPrefs.defaults);
    await controller.setProjectPrefs(prefs);
    final again = ThemeController(ThemePreferencesRepository(storage));
    await again.load();
    expect(again.projectPrefs, prefs);
  });
}
