import 'package:conduit/features/desktop_shell/domain/shell_layout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ShellLayout', () {
    test('reveal puts a view in the focused pane or focuses its pane', () {
      var layout = ShellLayout.single('a');
      layout = layout.reveal('b');
      expect(layout.panes.single.view, 'b');

      layout = layout.split('p1', ShellEdge.right, 'a');
      expect(layout.panes.map((pane) => pane.view), ['b', 'a']);
      expect(layout.focusedView, 'a');

      layout = layout.reveal('b');
      expect(layout.focusedPaneId, 'p1');
      expect(layout.panes.map((pane) => pane.view), ['b', 'a']);
    });

    test('split at each edge places the new pane there', () {
      final base = ShellLayout.single('a');
      final left = base.split('p1', ShellEdge.left, 'b');
      expect(left.panes.map((pane) => pane.view), ['b', 'a']);
      expect((left.root as ShellSplit).axis, ShellSplitAxis.horizontal);

      final bottom = base.split('p1', ShellEdge.bottom, 'b');
      expect(bottom.panes.map((pane) => pane.view), ['a', 'b']);
      expect((bottom.root as ShellSplit).axis, ShellSplitAxis.vertical);

      final top = base.split('p1', ShellEdge.top, 'b');
      expect(top.panes.map((pane) => pane.view), ['b', 'a']);
    });

    test('a view lives in one pane: splitting moves it', () {
      var layout = ShellLayout.single(
        'a',
      ).split('p1', ShellEdge.right, 'b').split('p2', ShellEdge.bottom, 'c');
      expect(layout.panes.map((pane) => pane.view), ['a', 'b', 'c']);
      // Dragging b to the left of a: b's old pane closes.
      layout = layout.split('p1', ShellEdge.left, 'b');
      expect(layout.panes.map((pane) => pane.view), ['b', 'a', 'c']);
      expect(layout.panes.length, 3);
    });

    test('never more than six panes', () {
      var layout = ShellLayout.single('a')
          .split('p1', ShellEdge.right, 'b')
          .split('p1', ShellEdge.bottom, 'c')
          .split('p2', ShellEdge.bottom, 'd')
          .split('p3', ShellEdge.right, 'e')
          .split('p4', ShellEdge.right, 'f');
      expect(layout.panes.length, 6);
      expect(layout.canSplit, isFalse);
      layout = layout.split('p1', ShellEdge.right, 'g');
      expect(layout.panes.length, 6);
      // The seventh view replaced the target pane's instead.
      expect(layout.paneShowing('g')?.id, 'p1');
    });

    test('splitting the only pane with its own view needs another view', () {
      final layout = ShellLayout.single('a');
      expect(layout.split('p1', ShellEdge.right, 'a'), layout);
      final split = layout.split('p1', ShellEdge.right, 'a', fallbackView: 'b');
      expect(split.panes.map((pane) => pane.view), ['b', 'a']);
    });

    test('closing a view closes its pane; the last pane is emptied', () {
      var layout = ShellLayout.single('a').split('p1', ShellEdge.right, 'b');
      layout = layout.removeView('b');
      expect(layout.panes.single.view, 'a');
      expect(layout.focusedPaneId, 'p1');
      layout = layout.removeView('a', replacement: 'c');
      expect(layout.panes.single.view, 'c');
      layout = layout.removeView('c');
      expect(layout.panes.single.view, isNull);
    });

    test('pruned drops panes whose views are gone', () {
      final layout = ShellLayout.single(
        'a',
      ).split('p1', ShellEdge.right, 'b').split('p2', ShellEdge.bottom, 'c');
      final pruned = layout.pruned({'a', 'c'});
      expect(pruned.panes.map((pane) => pane.view), ['a', 'c']);
      expect(layout.pruned({}).panes.single.view, isNull);
    });

    test('Alt+arrows find the neighbouring pane', () {
      // a | b
      //   | c
      var layout = ShellLayout.single(
        'a',
      ).split('p1', ShellEdge.right, 'b').split('p2', ShellEdge.bottom, 'c');
      expect(layout.focusedView, 'c');
      expect(layout.neighbor(ShellDirection.up), 'p2');
      expect(layout.neighbor(ShellDirection.left), 'p1');
      expect(layout.neighbor(ShellDirection.right), isNull);
      expect(layout.neighbor(ShellDirection.down), isNull);
      layout = layout.focus('p1');
      expect(layout.neighbor(ShellDirection.right), isNotNull);
      expect(layout.neighbor(ShellDirection.left), isNull);
    });

    test('resize clamps the divider', () {
      final layout = ShellLayout.single('a').split('p1', ShellEdge.right, 'b');
      expect((layout.resize(const [], 0.7).root as ShellSplit).ratio, 0.7);
      expect(
        (layout.resize(const [], 0.99).root as ShellSplit).ratio,
        1 - ShellSplit.minRatio,
      );
      final nested = layout.split('p2', ShellEdge.bottom, 'c');
      final resized = nested.resize(const [1], 0.3);
      final inner = (resized.root as ShellSplit).second as ShellSplit;
      expect(inner.ratio, 0.3);
    });

    test('round-trips through JSON and rejects broken layouts', () {
      final layout = ShellLayout.single('a')
          .split('p1', ShellEdge.right, 'b')
          .split('p2', ShellEdge.bottom, 'c')
          .resize(const [], 0.4);
      expect(ShellLayout.fromJson(layout.toJson()), layout);
      expect(ShellLayout.fromJson(null), ShellLayout.single());
      expect(
        ShellLayout.fromJson({
          'root': {
            'type': 'split',
            'first': {'type': 'pane', 'id': 'p1', 'view': 'a'},
            'second': {'type': 'pane', 'id': 'p1', 'view': 'b'},
          },
        }),
        ShellLayout.single(),
      );
      expect(
        ShellLayout.fromJson({
          'root': {
            'type': 'split',
            'first': {'type': 'pane', 'id': 'p1', 'view': 'a'},
            'second': {'type': 'pane', 'id': 'p2', 'view': 'a'},
          },
        }),
        ShellLayout.single(),
      );
    });
  });
}
