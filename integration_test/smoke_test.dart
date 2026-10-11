import 'package:conduit/main.dart' as app;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const smokeHost = String.fromEnvironment('SMOKE_HOST', defaultValue: '10.0.2.2');
const smokePort = String.fromEnvironment('SMOKE_PORT', defaultValue: '2222');

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('explore', (tester) async {
    app.main();
    var n = 0;
    Future<void> shot(String name) async {
      await tester.pump(const Duration(milliseconds: 300));
      await binding.takeScreenshot('${(n++).toString().padLeft(2, '0')}-$name');
      final texts = find.byType(Text).evaluate().map((e) => (e.widget as Text).data).whereType<String>().toList();
      debugPrint('SMOKE $name texts: $texts');
      final tips = find.byType(Tooltip).evaluate().map((e) => (e.widget as Tooltip).message).toList();
      debugPrint('SMOKE $name tooltips: $tips');
    }

    Future<void> waitFor(Finder f, {int seconds = 20}) async {
      for (var i = 0; i < seconds * 5; i++) {
        await tester.pump(const Duration(milliseconds: 200));
        if (f.evaluate().isNotEmpty) return;
      }
      await shot('timeout');
      fail('timed out waiting for $f');
    }

    await tester.pump(const Duration(seconds: 3));
    await binding.convertFlutterSurfaceToImage();
    await waitFor(find.text('Continue without auth'));
    await shot('lock');
    await tester.tap(find.text('Continue without auth'));
    await waitFor(find.text('Add machine'));
    await shot('home-empty');
    await tester.tap(find.text('Add machine'));
    await waitFor(find.widgetWithText(TextFormField, 'Host or IP'));
    await tester.enterText(find.widgetWithText(TextFormField, 'Display name'), 'smoke');
    await tester.enterText(find.widgetWithText(TextFormField, 'Host or IP'), smokeHost);
    await tester.enterText(find.widgetWithText(TextFormField, 'Port'), smokePort);
    await tester.enterText(find.widgetWithText(TextFormField, 'Username'), 'smoke');
    await tester.enterText(find.widgetWithText(TextFormField, 'Password'), 'smoke');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await shot('form');
    final add = find.widgetWithText(FilledButton, 'Add machine');
    await tester.scrollUntilVisible(add, 300, scrollable: find.byType(Scrollable).first);
    await tester.tap(add);
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(seconds: 2));
      await shot('after-add-$i');
    }
  });
}
