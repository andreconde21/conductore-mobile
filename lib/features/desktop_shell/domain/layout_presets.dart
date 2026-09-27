import 'package:conduit/features/desktop_shell/domain/shell_layout.dart';
import 'package:flutter/foundation.dart';

/// The layouts the toolbar's layout picker offers, for laying out several
/// sessions with the mouse (Conductore Lite's presets).
enum ShellLayoutPreset {
  single('Single', 1),
  sideBySide('Two side by side', 2),
  stacked('Two stacked', 2),
  onePlusTwo('One and two', 3),
  grid2x2('2 × 2', 4),
  grid3x2('3 × 2', 6);

  const ShellLayoutPreset(this.label, this.paneCount);

  final String label;
  final int paneCount;

  static ShellLayoutPreset? byName(Object? name) =>
      values.where((preset) => preset.name == name).firstOrNull;

  /// The empty tree of this preset: its panes are slots (they stay when
  /// empty) numbered p1… in reading order.
  ShellNode get tree {
    ShellPane pane(int n) => ShellPane.slot('p$n');
    ShellSplit row(ShellNode a, ShellNode b, [double ratio = 0.5]) =>
        ShellSplit(
          axis: ShellSplitAxis.horizontal,
          first: a,
          second: b,
          ratio: ratio,
        );
    ShellSplit column(ShellNode a, ShellNode b) =>
        ShellSplit(axis: ShellSplitAxis.vertical, first: a, second: b);
    return switch (this) {
      ShellLayoutPreset.single => pane(1),
      ShellLayoutPreset.sideBySide => row(pane(1), pane(2)),
      ShellLayoutPreset.stacked => column(pane(1), pane(2)),
      ShellLayoutPreset.onePlusTwo => row(pane(1), column(pane(2), pane(3))),
      ShellLayoutPreset.grid2x2 => column(
        row(pane(1), pane(2)),
        row(pane(3), pane(4)),
      ),
      ShellLayoutPreset.grid3x2 => column(
        row(pane(1), row(pane(2), pane(3)), 1 / 3),
        row(pane(4), row(pane(5), pane(6)), 1 / 3),
      ),
    };
  }

  /// This preset showing [views] in reading order (the focused view
  /// first is the caller's choice); panes beyond the views stay empty,
  /// the first pane has the focus. A single pane is an ordinary pane.
  ShellLayout apply(List<String> views) {
    final layout = ShellLayout.of(tree, 'p1').fill(views);
    if (this != ShellLayoutPreset.single) return layout;
    return ShellLayout.single(layout.panes.first.view);
  }

  /// The preset [layout] has the shape of, or null for a hand-made one.
  static ShellLayoutPreset? of(ShellLayout layout) {
    final shape = _shape(layout.root);
    for (final preset in values) {
      if (_shape(preset.tree) == shape) return preset;
    }
    return null;
  }

  static String _shape(ShellNode node) => switch (node) {
    ShellPane() => 'p',
    ShellSplit(:final axis, :final first, :final second) =>
      '${axis.name[0]}(${_shape(first)},${_shape(second)})',
  };
}

/// The views to show when switching to a preset: those on screen now (in
/// reading order, the focused one first), then the most recently used
/// ones that are on no pane.
List<String> viewsForPreset(ShellLayout current, List<String> recent) {
  final focused = current.focusedView;
  return [
    ?focused,
    for (final pane in current.panes)
      if (pane.view != null && pane.view != focused) pane.view!,
    for (final view in recent)
      if (!current.visibleViews.contains(view)) view,
  ];
}

/// A layout the user saved under a name ("Morning check"): the split tree
/// with the views it showed, restorable from the palette and the toolbar.
@immutable
class SavedShellLayout {
  const SavedShellLayout({
    required this.id,
    required this.name,
    required this.layout,
  });

  final String id;
  final String name;
  final ShellLayout layout;

  /// The views it shows, in reading order.
  List<String> get views => [
    for (final pane in layout.panes)
      if (pane.view != null) pane.view!,
  ];

  SavedShellLayout rename(String name) =>
      SavedShellLayout(id: id, name: name, layout: layout);

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'layout': layout.toJson(),
  };

  static SavedShellLayout? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final name = json['name'];
    if (id is! String || id.isEmpty || name is! String || name.isEmpty) {
      return null;
    }
    return SavedShellLayout(
      id: id,
      name: name,
      layout: ShellLayout.fromJson(json['layout']),
    );
  }

  /// Every readable layout of [json] (a list); broken ones are dropped.
  static List<SavedShellLayout> listFromJson(Object? json) => [
    if (json is List)
      for (final item in json) ?SavedShellLayout.fromJson(item),
  ];

  @override
  bool operator ==(Object other) =>
      other is SavedShellLayout &&
      other.id == id &&
      other.name == name &&
      other.layout == layout;

  @override
  int get hashCode => Object.hash(id, name, layout);
}
