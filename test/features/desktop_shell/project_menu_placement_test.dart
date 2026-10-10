import 'package:conduit/core/theme/theme_controller.dart';
import 'package:conduit/features/desktop_shell/presentation/project_layout_controller.dart';
import 'package:conduit/features/desktop_shell/presentation/widgets/project_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

void main() {
  testWidgets('the project view menu sits at the right edge of its bar', (
    tester,
  ) async {
    final theme = ThemeController(InMemoryThemePreferences());
    await theme.load();
    final controller = ProjectLayoutController(theme: theme);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 360,
              child: ProjectViewBar(controller: controller, needsYou: 0),
            ),
          ),
        ),
      ),
    );
    final bar = tester.getRect(find.byType(ProjectViewBar));
    final menu = tester.getRect(
      find.byKey(const ValueKey('project-view-menu')),
    );
    // Only the icon's own padding separates it from the edge.
    expect(bar.right - menu.right, lessThanOrEqualTo(1));
    final icon = tester.getRect(find.byIcon(Icons.more_vert_rounded));
    expect(bar.right - icon.right, lessThanOrEqualTo(4));
  });
}
