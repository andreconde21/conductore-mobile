// The phone smoke test (CON-114), run by tools/smoke-test.sh before a
// release: the real app on an Android emulator against a throwaway machine
// (tools/smoke/machine: sshd, Herdr, the companion and two fake agents in
// two Herdr workspaces both labelled "shop"; one waits for a permission,
// the other asks a question). One screenshot per step.
//
// Not part of `flutter test`: it needs the device and the machine.

import 'package:conduit/main.dart' as app;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// The machine as the emulator sees it: the host's loopback is 10.0.2.2.
const _host = String.fromEnvironment('SMOKE_HOST', defaultValue: '10.0.2.2');
const _port = String.fromEnvironment('SMOKE_PORT', defaultValue: '2222');
const _chat = 'Chat. Long-press for the composer';
const _agentRow = 'tab 1 · smoke';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('main flows on a phone', (tester) async {
    app.main();
    final errors = _ErrorWatch()..install();
    final steps = _Steps(tester, binding);

    await tester.pump(const Duration(seconds: 3));
    // Screenshots on Android need the Flutter surface as an image.
    await binding.convertFlutterSurfaceToImage();

    // The emulator has no screen lock: the app lock offers to go on.
    await steps.waitFor(find.text('Continue without auth'));
    await tester.tap(find.text('Continue without auth'));
    await steps.waitFor(find.text('No saved machines yet'));
    await steps.done('home-empty');

    // 1. Add the machine.
    await tester.tap(find.text('Add machine'));
    final hostField = find.widgetWithText(TextFormField, 'Host or IP');
    await steps.waitFor(hostField);
    Future<void> fill(String label, String text) =>
        tester.enterText(find.widgetWithText(TextFormField, label), text);
    await fill('Display name', 'smoke');
    await fill('Host or IP', _host);
    await fill('Port', _port);
    await fill('Username', 'smoke');
    await fill('Password', 'smoke');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await steps.done('add-machine-form');
    final add = find.widgetWithText(FilledButton, 'Add machine');
    await tester.scrollUntilVisible(
      add,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(add);
    await steps.waitFor(find.text('List workspaces'));
    if (find.text('OK').evaluate().isNotEmpty) {
      await tester.tap(find.text('OK')); // the telemetry notice
    }
    await tester.tap(find.text('List workspaces'));
    await steps.waitFor(find.text('Trust this host?'));
    await steps.done('host-key');
    await tester.tap(find.text('Trust'));

    // 2. Home, Open mode: both Herdr workspaces, same label, both waiting.
    await steps.waitFor(find.text('1 agent · 1 tab'), count: 2);
    expect(find.text('shop'), findsNWidgets(2));
    await steps.done('home-open');
    // Projects mode: one project, an agent row per workspace (named
    // "claude in shop" until the companion names it after the workspace).
    await tester.tap(find.byKey(const ValueKey('home-mode-projects')));
    await steps.waitFor(find.text(_agentRow), count: 2);
    await steps.done('home-projects');

    // 3. Search.
    final search = find.descendant(
      of: find.byKey(const ValueKey('home-workspace-search')),
      matching: find.byType(TextField),
    );
    await tester.enterText(search, 'nomatch');
    await steps.waitFor(find.text('No workspace matches the search.'));
    await steps.done('search-no-match');
    await tester.enterText(search, 'shop');
    await steps.waitFor(find.text(_agentRow), count: 2);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await steps.done('search-shop');

    // 4. Open an agent: its Herdr workspace in a terminal tab.
    await tester.tap(find.text(_agentRow).first);
    await steps.waitFor(find.byTooltip(_chat));
    await tester.pump(const Duration(seconds: 3));
    await steps.done('agent-terminal');

    // 5. Chat View: the transcript and the waiting permission.
    await tester.tap(find.byTooltip(_chat));
    await steps.waitFor(find.text('Run the shop tests'));
    await steps.waitFor(find.text('Allow Bash?'));
    await steps.done('chat-view');

    // 6. Approve the permission. A first-run hint covers the buttons for a
    // few seconds, so wait until Allow takes the tap.
    final allow = find.text('Allow').hitTestable();
    await steps.waitFor(allow);
    await tester.tap(allow.first);
    await steps.waitFor(find.text('Allow Bash?'), absent: true);
    await steps.waitFor(find.textContaining('Idle'));
    await steps.done('permission-approved');

    // 7. Switch Herdr workspace: the other "shop", from the switcher.
    await tester.tap(find.text('Terminal'));
    await steps.waitFor(find.byTooltip('Sessions'));
    await tester.tap(find.byTooltip('Sessions'));
    await steps.waitFor(find.text('OTHER WORKSPACES'));
    await steps.done('workspace-switcher');
    await tester.tap(find.text('smoke · 1 agent · 1 tab'));
    await steps.waitFor(find.text('OTHER WORKSPACES'), absent: true);
    await tester.pump(const Duration(seconds: 3));
    await steps.done('workspace-switched');

    // 8. Answer the question of the agent in that workspace.
    await tester.tap(find.byTooltip(_chat));
    await steps.waitFor(find.text('Claude Code asks'));
    await steps.done('question');
    // The first-run hint may cover the choices for a few seconds.
    final postgres = find.text('Postgres').hitTestable();
    await steps.waitFor(postgres);
    await tester.tap(postgres.first);
    // One single-choice question is sent by the tap; otherwise Send.
    await tester.pump(const Duration(seconds: 2));
    final send = find.text('Send').hitTestable();
    if (find.text('Claude Code asks').evaluate().isNotEmpty &&
        send.evaluate().isNotEmpty) {
      await tester.tap(send.first);
    }
    // Answered: the request is gone and the agent went idle after it.
    await steps.waitFor(find.text('Claude Code asks'), absent: true);
    await steps.waitFor(find.textContaining('Idle'));
    await steps.done('question-answered');

    // 9. Settings › Security.
    for (
      var i = 0;
      i < 4 && find.byTooltip('Settings').evaluate().isEmpty;
      i++
    ) {
      final up = find.byTooltip('Machines').evaluate().isNotEmpty
          ? find.byTooltip('Machines')
          : find.byTooltip('Back');
      await tester.tap(up.first);
      await tester.pump(const Duration(seconds: 1));
    }
    await steps.waitFor(find.byTooltip('Settings'));
    await tester.tap(find.byTooltip('Settings'));
    await steps.waitFor(find.text('Security'));
    await tester.tap(find.text('Security'));
    await steps.waitFor(find.text('Security'));
    await tester.pump(const Duration(seconds: 1));
    await steps.done('settings-security');

    errors.report();
  });
}

/// Steps with a screenshot each, and waits that fail with one.
class _Steps {
  _Steps(this.tester, this.binding);

  final WidgetTester tester;
  final IntegrationTestWidgetsFlutterBinding binding;
  var _n = 0;

  Future<void> done(String name) async {
    await tester.pump(const Duration(milliseconds: 400));
    final file = '${(++_n).toString().padLeft(2, '0')}-$name';
    await binding.takeScreenshot(file);
    debugPrint('SMOKE step $file: ok');
  }

  /// Pumps until [finder] finds [count] widgets or more (none: [absent]).
  Future<void> waitFor(
    Finder finder, {
    int count = 1,
    bool absent = false,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 250));
      final found = finder.evaluate().length;
      if (absent ? found == 0 : found >= count) return;
    }
    final texts = find
        .byType(Text)
        .evaluate()
        .map((e) => (e.widget as Text).data)
        .whereType<String>()
        .join(' | ');
    final file = '${(++_n).toString().padLeft(2, '0')}-FAILED';
    await binding.takeScreenshot(file);
    debugPrint('SMOKE step $file: on screen: $texts');
    fail('timed out waiting for ${absent ? 'no ' : ''}$finder');
  }
}

/// Every Flutter error fails the test through the test framework's
/// handler (a RenderFlex overflow included), except one known framework
/// assertion, which is only logged.
class _ErrorWatch {
  var known = 0;

  void install() {
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      if (_isKnown(details)) {
        known++;
        debugPrint('SMOKE known error (not failing): semantics geometry');
        return;
      }
      previous?.call(details);
    };
  }

  /// Flutter's semantics geometry assertion ("identical(childRenderObject,
  /// parentRenderObject)" in computeChildGeometry), thrown in debug builds
  /// while the terminal swaps to the read-only screen of another Herdr
  /// workspace. Debug-only and inside the framework.
  static bool _isKnown(FlutterErrorDetails details) =>
      details.exceptionAsString().contains(
        'identical(childRenderObject, parentRenderObject)',
      ) &&
      details.stack.toString().contains('computeChildGeometry');

  void report() => debugPrint('SMOKE known errors: $known');
}
