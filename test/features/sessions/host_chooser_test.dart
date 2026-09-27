import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/hosts/presentation/hosts_controller.dart';
import 'package:conduit/features/sessions/presentation/session_connect_flow.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

void main() {
  Future<List<SavedHost?>> pumpChooser(WidgetTester tester) async {
    final controller = HostsController(
      FakeHostsRepository()
        ..persisted = [
          buildHost('a').copyWith(name: 'alpha'),
          buildHost('b').copyWith(name: 'bravo'),
        ],
    );
    await controller.load();
    final picked = <SavedHost?>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async => picked.add(
                await Navigator.of(context).push<SavedHost>(
                  MaterialPageRoute(
                    builder: (_) => Scaffold(
                      body: HostChooser(hostsController: controller),
                    ),
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return picked;
  }

  testWidgets(
    'desktop filters the machines and Enter picks the first',
    (tester) async {
      final picked = await pumpChooser(tester);
      expect(find.text('alpha'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('host-chooser-filter')),
        'bra',
      );
      await tester.pumpAndSettle();
      expect(find.text('alpha'), findsNothing);
      expect(find.text('bravo'), findsOneWidget);
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await tester.pumpAndSettle();
      expect(picked.single?.name, 'bravo');
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.linux,
      TargetPlatform.windows,
      TargetPlatform.macOS,
    }),
  );

  testWidgets('phones list the machines without a filter', (tester) async {
    await pumpChooser(tester);
    expect(find.byKey(const ValueKey('host-chooser-filter')), findsNothing);
    expect(find.text('alpha'), findsOneWidget);
    expect(find.text('bravo'), findsOneWidget);
  });
}
