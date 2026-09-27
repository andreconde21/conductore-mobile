import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/domain/approval_rules.dart';
import 'package:conduit/features/agent_attention/presentation/approval_rules_page.dart';
import 'package:conduit/features/agent_attention/presentation/approval_sheets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The trust, batch-approve and rule-editor sheets: bottom sheets with
/// full-width buttons on phones; right-aligned dialogs where Enter saves on
/// desktop.
void main() {
  const desktops = TargetPlatformVariant({
    TargetPlatform.linux,
    TargetPlatform.windows,
    TargetPlatform.macOS,
  });
  const dialogKey = ValueKey('adaptive-modal-dialog');
  const request = PendingPermissionRequest(
    id: 'req-1',
    toolName: 'Bash',
    summary: 'git status',
    suggestedRules: ['Bash(git status *)'],
    repo: '/home/a/api',
  );

  /// Pumps a button that runs [open] and returns what it resolved to.
  Future<List<Object?>> pumpOpener(
    WidgetTester tester,
    Future<Object?> Function(BuildContext context) open,
  ) async {
    final results = <Object?>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async => results.add(await open(context)),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return results;
  }

  /// Whether [button] sits in an Expanded (the phone's full-width pair).
  bool expanded(WidgetTester tester, Finder button) => find
      .ancestor(of: button, matching: find.byType(Expanded))
      .evaluate()
      .isNotEmpty;

  group('trust sheet', () {
    testWidgets('desktop: a dialog, buttons right-aligned, Enter saves', (
      tester,
    ) async {
      final results = await pumpOpener(
        tester,
        (context) => showTrustSheet(context, request: request),
      );
      expect(find.byKey(dialogKey), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      final save = find.byKey(const ValueKey('trust-save'));
      expect(expanded(tester, save), isFalse);
      expect(
        find.ancestor(of: save, matching: find.byType(OverflowBar)),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('trust-rule-field')));
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(results.single, isA<TrustChoiceSave>());
    }, variant: desktops);

    testWidgets('phone: the bottom sheet, full-width buttons, Done stays', (
      tester,
    ) async {
      final results = await pumpOpener(
        tester,
        (context) => showTrustSheet(context, request: request),
      );
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.byKey(dialogKey), findsNothing);
      expect(
        expanded(tester, find.byKey(const ValueKey('trust-save'))),
        isTrue,
      );
      await tester.tap(find.byKey(const ValueKey('trust-rule-field')));
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(results, isEmpty);
      expect(find.byType(BottomSheet), findsOneWidget);
    });
  });

  group('batch approve', () {
    testWidgets('desktop: a dialog with right-aligned buttons', (tester) async {
      final results = await pumpOpener(
        tester,
        (context) => showBatchApproveSheet(context, const []),
      );
      expect(find.byKey(dialogKey), findsOneWidget);
      final confirm = find.byKey(const ValueKey('batch-confirm'));
      expect(expanded(tester, confirm), isFalse);
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(results.single, isTrue);
    }, variant: desktops);

    testWidgets('phone: the bottom sheet', (tester) async {
      await pumpOpener(
        tester,
        (context) => showBatchApproveSheet(context, const []),
      );
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(
        expanded(tester, find.byKey(const ValueKey('batch-confirm'))),
        isTrue,
      );
    });
  });

  group('rule editor', () {
    testWidgets('desktop: a dialog with Cancel, Enter saves', (tester) async {
      final results = await pumpOpener(
        tester,
        (context) => showRuleEditorSheet(context, repos: ['/home/a/api']),
      );
      expect(find.byKey(dialogKey), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Cancel'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('rule-editor-rule')));
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      final draft = results.single! as ApprovalRuleDraft;
      expect(draft.rule, 'Bash(npm test *)');
    }, variant: desktops);

    testWidgets('phone: the bottom sheet with a lone full-width Save', (
      tester,
    ) async {
      final results = await pumpOpener(
        tester,
        (context) => showRuleEditorSheet(context, repos: ['/home/a/api']),
      );
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Cancel'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('rule-editor-rule')));
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(results, isEmpty);
    });
  });
}
