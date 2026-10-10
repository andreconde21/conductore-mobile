import 'package:conduit/features/hosts/presentation/widgets/home_chrome.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the top bar has four controls and fits a 360 dp phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    var searches = 0;
    var agents = 0;
    var settings = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomeTopBar(
            onSettings: () => settings += 1,
            onSearch: () => searches += 1,
            onAgents: () => agents += 1,
            agentsBadge: 3,
            machine: const Text('All machines · a long name'),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    // The machine chip plus three icons: Agents, Search, Settings.
    expect(find.byType(IconButton), findsNWidgets(3));
    expect(find.text('All machines · a long name'), findsOneWidget);
    expect(find.byTooltip('Lock'), findsNothing);
    expect(find.byTooltip('Switch sessions'), findsNothing);
    expect(find.byTooltip('Voice guide'), findsNothing);
    await tester.tap(find.byTooltip('Switch to…'));
    await tester.tap(find.byTooltip('Agents dashboard'));
    await tester.tap(find.byTooltip('Settings'));
    expect([searches, agents, settings], [1, 1, 1]);
  });
}
