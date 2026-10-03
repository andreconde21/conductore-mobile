import 'package:conduit/features/hosts/presentation/widgets/home_chrome.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('every top-bar button fits a 360 dp phone, search included', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    var searches = 0;
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
            machine: const Text('All machines · a long name'),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('home-search')));
    expect(searches, 1);
  });
}
