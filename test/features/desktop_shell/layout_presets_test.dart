import 'package:conduit/features/desktop_shell/domain/layout_presets.dart';
import 'package:conduit/features/desktop_shell/domain/shell_layout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  List<String?> views(ShellLayout layout) => [
    for (final pane in layout.panes) pane.view,
  ];

  test('every preset has its pane count, in reading order', () {
    for (final preset in ShellLayoutPreset.values) {
      final layout = preset.apply(const []);
      expect(layout.panes.length, preset.paneCount, reason: preset.name);
      expect(ShellLayoutPreset.of(layout), preset, reason: preset.name);
      expect(layout.panes.length, lessThanOrEqualTo(ShellLayout.maxPanes));
    }
    final rects = ShellLayoutPreset.grid3x2.apply(const []).paneRects();
    // Three equal columns on two rows.
    expect(rects['p1']!.width, closeTo(1 / 3, 1e-9));
    expect(rects['p3']!.left, closeTo(2 / 3, 1e-9));
    expect(rects['p4']!.top, 0.5);
    final twoByTwo = ShellLayoutPreset.grid2x2.apply(const []).paneRects();
    expect(twoByTwo['p2']!.topLeft, const Offset(0.5, 0));
    expect(twoByTwo['p3']!.topLeft, const Offset(0, 0.5));
  });

  test('a preset fills its panes with the views given; the rest wait', () {
    final layout = ShellLayoutPreset.grid2x2.apply(['a', 'b']);
    expect(views(layout), ['a', 'b', null, null]);
    expect(layout.focusedPaneId, 'p1');
    // Empty slots survive pruning, unlike ordinary empty panes.
    final pruned = layout.pruned({'a', 'b'});
    expect(pruned.panes.length, 4);
    // A view closing empties its slot instead of closing it.
    expect(views(layout.pruned({'a'})), ['a', null, null, null]);
    expect(views(layout.removeView('b')), ['a', null, null, null]);
    // Too many views: the extra ones are left out.
    expect(views(ShellLayoutPreset.sideBySide.apply(['a', 'b', 'c'])), [
      'a',
      'b',
    ]);
    // Single is an ordinary pane.
    expect(ShellLayoutPreset.single.apply(['a']), ShellLayout.single('a'));
  });

  test('switching keeps the views on screen first, focused one leading', () {
    final current = ShellLayout.single('a').split('p1', ShellEdge.right, 'b');
    expect(current.focusedView, 'b');
    expect(viewsForPreset(current, ['c', 'a', 'd']), ['b', 'a', 'c', 'd']);
  });

  test('revealing a view lands in the focused empty slot', () {
    var layout = ShellLayoutPreset.sideBySide.apply(['a']).focus('p2');
    layout = layout.reveal('b');
    expect(views(layout), ['a', 'b']);
  });

  test('swap exchanges two panes; moving a slot view empties it', () {
    final layout = ShellLayoutPreset.onePlusTwo.apply(['a', 'b', 'c']);
    final swapped = layout.swap('p1', 'p3');
    expect(views(swapped), ['c', 'b', 'a']);
    expect(swapped.focusedPaneId, 'p3');
    // A view shown in a new split leaves an empty slot behind.
    final moved = layout.split('p2', ShellEdge.bottom, 'a');
    expect(moved.panes.length, 4);
    expect(views(moved), [null, 'b', 'a', 'c']);
    // Filling puts views in the empty panes only.
    expect(views(moved.fill(['x', 'b'])), ['x', 'b', 'a', 'c']);
  });

  test('slots round-trip through JSON; asSlots keeps a hand-made shape', () {
    final layout = ShellLayoutPreset.grid3x2.apply(['a', 'b', 'c']);
    expect(ShellLayout.fromJson(layout.toJson()), layout);
    final hand = ShellLayout.single('a').split('p1', ShellEdge.bottom, 'b');
    expect(hand.pruned({'a'}).panes.length, 1);
    expect(hand.asSlots().pruned({'a'}).panes.length, 2);
  });

  test('saved layouts round-trip and skip broken entries', () {
    final saved = SavedShellLayout(
      id: 'l1',
      name: 'Morning check',
      layout: ShellLayoutPreset.stacked.apply(['a', 'b']),
    );
    final list = SavedShellLayout.listFromJson([
      saved.toJson(),
      {'id': '', 'name': 'x'},
      'junk',
    ]);
    expect(list, [saved]);
    expect(list.single.views, ['a', 'b']);
  });
}
