import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/presentation/widgets/agent_inbox_widgets.dart';
import 'package:conduit/features/chat_view/presentation/widgets/chat_thread_items.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../screenshots/screenshot_harness.dart';

const _labels = ['Deny', 'Trust…', 'Always', 'Allow'];

const _request = PendingPermissionRequest(
  id: 'req-1',
  toolName: 'Bash',
  summary: 'npm test -- due-date',
  toolInput: '{"command": "npm test -- due-date"}',
  risk: PermissionRisk(
    PermissionRiskLevel.low,
    'Runs tests: npm test -- due-date',
  ),
);

/// A phone or desktop [width] dp wide at 1 px/dp, [scale] text scale.
Future<void> _pump(
  WidgetTester tester,
  Widget card, {
  required double width,
  double scale = 1,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    shotApp(
      systemBars: false,
      home: MediaQuery.withClampedTextScaling(
        minScaleFactor: scale,
        maxScaleFactor: scale,
        child: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: card,
          ),
        ),
      ),
    ),
  );
}

/// Every label is drawn whole on one line, and inside the screen.
void _expectWholeLabels(WidgetTester tester, List<String> labels) {
  final screen = tester.view.physicalSize.width;
  for (final label in labels) {
    final paragraph = tester.renderObject<RenderParagraph>(find.text(label));
    expect(paragraph.didExceedMaxLines, isFalse, reason: '"$label" fits');
    final painter = TextPainter(
      text: paragraph.text,
      textDirection: TextDirection.ltr,
      textScaler: paragraph.textScaler,
    )..layout();
    expect(
      paragraph.size.height,
      lessThan(painter.height * 1.5),
      reason: '"$label" is one line',
    );
    painter.dispose();
    final rect = tester.getRect(find.text(label));
    expect(rect.left, greaterThanOrEqualTo(0));
    expect(rect.right, lessThanOrEqualTo(screen));
  }
}

/// No two buttons overlap; Deny and Allow share the bottom row, Deny
/// first.
void _expectSaneButtons(WidgetTester tester, List<String> labels) {
  final rects = [
    for (final label in labels)
      tester.getRect(
        find.ancestor(
          of: find.text(label),
          matching: find.bySubtype<ButtonStyleButton>(),
        ),
      ),
  ];
  for (var i = 0; i < rects.length; i++) {
    for (var j = i + 1; j < rects.length; j++) {
      expect(
        rects[i].overlaps(rects[j]),
        isFalse,
        reason: '${labels[i]} and ${labels[j]} overlap',
      );
    }
  }
  final deny = rects.first;
  final allow = rects.last;
  expect(deny.center.dy, moreOrLessEquals(allow.center.dy));
  expect(deny.right, lessThanOrEqualTo(allow.left));
  for (final rect in rects) {
    expect(rect.bottom, lessThanOrEqualTo(allow.bottom + 0.5));
  }
}

/// The paragraph drawing [text] (inside a SelectionArea's Text too).
RenderParagraph _paragraph(WidgetTester tester, String text) =>
    tester.renderObject<RenderParagraph>(
      find.descendant(of: find.text(text), matching: find.byType(RichText)),
    );

void main() {
  setUpAll(loadShotFonts);

  final cards = <String, Widget Function()>{
    'ChatApprovalCard': () => ChatApprovalCard(
      request: _request,
      busy: false,
      onDecide: (_) {},
      onTrust: () {},
    ),
    'PendingRequestCard': () => PendingRequestCard(
      request: _request,
      busy: false,
      onDecide: (_) {},
      onTrust: () {},
    ),
  };

  for (final MapEntry(key: name, value: card) in cards.entries) {
    group('$name answers', () {
      for (final (width, scale) in [
        (320.0, 1.0),
        (320.0, 1.3),
        (411.0, 1.0),
        (411.0, 1.3),
        (1280.0, 1.0),
        (1280.0, 1.3),
      ]) {
        testWidgets('whole labels at $width dp, text x$scale', (tester) async {
          await _pump(tester, card(), width: width, scale: scale);
          expect(tester.takeException(), isNull);
          _expectWholeLabels(tester, _labels);
          _expectSaneButtons(tester, _labels);
        });
      }

      testWidgets('one row on desktop, two on a phone', (tester) async {
        double rows() => _labels
            .map((l) => tester.getCenter(find.text(l)).dy.roundToDouble())
            .toSet()
            .length
            .toDouble();
        await _pump(tester, card(), width: 1280);
        expect(rows(), 1);
        await _pump(tester, card(), width: 411);
        expect(rows(), 2);
        // Trust… and Always above Deny and Allow.
        expect(
          tester.getCenter(find.text('Always')).dy,
          lessThan(tester.getCenter(find.text('Allow')).dy),
        );
      });
    });
  }

  testWidgets('the plan approval keeps whole labels at 320 dp, x1.3', (
    tester,
  ) async {
    const plan = PendingPermissionRequest(
      id: 'plan-1',
      toolName: 'ExitPlanMode',
      summary: 'plan',
    );
    await _pump(
      tester,
      ChatApprovalCard(request: plan, busy: false, onDecide: (_) {}),
      width: 320,
      scale: 1.3,
    );
    expect(tester.takeException(), isNull);
    const labels = ['Keep planning', 'Approve, auto-edit', 'Approve'];
    _expectWholeLabels(tester, labels);
  });

  group('PendingRequestCard command', () {
    double lineHeight(WidgetTester tester, RenderParagraph paragraph) {
      final painter = TextPainter(
        text: TextSpan(text: 'x', style: paragraph.text.style),
        textDirection: TextDirection.ltr,
        textScaler: paragraph.textScaler,
      )..layout();
      final height = painter.height;
      painter.dispose();
      return height;
    }

    for (final width in [320.0, 411.0, 1280.0]) {
      testWidgets('hugs a one-line command at $width dp', (tester) async {
        const request = PendingPermissionRequest(
          id: 'req-2',
          toolName: 'Bash',
          summary: 'git push origin due-date',
          toolInput: '{"command": "git push origin due-date"}',
        );
        await _pump(
          tester,
          PendingRequestCard(request: request, busy: false, onDecide: (_) {}),
          width: width,
        );
        expect(tester.takeException(), isNull);
        final paragraph = _paragraph(tester, request.summary);
        final line = lineHeight(tester, paragraph);
        // 320 dp may wrap the command once; never the empty third line.
        expect(
          paragraph.size.height,
          lessThan(line * (width < 400 ? 2.5 : 1.5)),
        );
      });

      testWidgets('caps a long command at three lines at $width dp', (
        tester,
      ) async {
        final request = PendingPermissionRequest(
          id: 'req-3',
          toolName: 'Bash',
          summary: List.filled(60, 'echo x &&').join(' '),
          toolInput: 'x',
        );
        await _pump(
          tester,
          PendingRequestCard(request: request, busy: false, onDecide: (_) {}),
          width: width,
        );
        expect(tester.takeException(), isNull);
        final paragraph = _paragraph(tester, request.summary);
        expect(paragraph.didExceedMaxLines, isTrue);
        expect(
          paragraph.size.height,
          lessThan(lineHeight(tester, paragraph) * 3.5),
        );
        // Tool input shows it all.
        await tester.tap(find.text('Tool input'));
        await tester.pump();
        expect(_paragraph(tester, request.summary).didExceedMaxLines, isFalse);
      });
    }
  });
}
