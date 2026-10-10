import 'package:conduit/features/hosts/domain/home_preferences.dart';
import 'package:conduit/features/hosts/presentation/widgets/home_chrome.dart';
import 'package:conduit/features/hosts/presentation/widgets/machine_switcher.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'every top-bar button fits a 360 dp phone, search and the mode switch included',
    (tester) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      var searches = 0;
      HomeMode? picked;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HomeTopBar(
              onLock: () {},
              onSettings: () {},
              onSwitcher: () {},
              onSearch: () => searches += 1,
              onGuide: () {},
              onAgents: () {},
              agentsBadge: 3,
              mode: HomeMode.projects,
              onMode: (mode) => picked = mode,
              machine: MachineChip(
                label: 'All machines · a long name',
                live: true,
                otherAttentionCount: 2,
                onTap: () {},
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    // The mode switch leaves the machine chip room (compact buttons).
    expect(
      tester.getSize(find.byType(MachineChip)).width,
      greaterThanOrEqualTo(48),
    );
      await tester.tap(find.byKey(const ValueKey('home-search')));
      expect(searches, 1);
      await tester.tap(find.byKey(const ValueKey('home-mode-switch')));
      expect(picked, HomeMode.openClosed);
    },
  );
}
