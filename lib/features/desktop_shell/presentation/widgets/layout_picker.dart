import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/features/desktop_shell/domain/layout_presets.dart';
import 'package:conduit/features/desktop_shell/domain/shell_layout.dart';
import 'package:flutter/material.dart';

/// What the layout picker asks for.
sealed class LayoutPick {
  const LayoutPick();
}

class LayoutPickPreset extends LayoutPick {
  const LayoutPickPreset(this.preset);

  final ShellLayoutPreset preset;
}

class LayoutPickSaved extends LayoutPick {
  const LayoutPickSaved(this.saved);

  final SavedShellLayout saved;
}

class LayoutPickSave extends LayoutPick {
  const LayoutPickSave();
}

class LayoutPickDelete extends LayoutPick {
  const LayoutPickDelete(this.saved);

  final SavedShellLayout saved;
}

/// The toolbar's layout button: a popover with the presets drawn as
/// little diagrams (single, two side by side, two stacked, one and two,
/// 2×2, 3×2), the saved layouts, and "Save this layout…".
class LayoutPickerButton extends StatelessWidget {
  const LayoutPickerButton({
    required this.current,
    required this.saved,
    required this.onPick,
    super.key,
  });

  /// The preset the main area has now, if any (drawn selected).
  final ShellLayoutPreset? current;
  final List<SavedShellLayout> saved;
  final ValueChanged<LayoutPick> onPick;

  Future<void> _open(BuildContext context) async {
    final box = context.findRenderObject()! as RenderBox;
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final rect = box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
    final pick = await showMenu<LayoutPick>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(rect.left, rect.bottom, rect.width, 0),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem<LayoutPick>(
          enabled: false,
          padding: EdgeInsets.zero,
          child: _PresetGrid(
            current: current,
            onPick: (preset) =>
                Navigator.of(context).pop(LayoutPickPreset(preset)),
          ),
        ),
        if (saved.isNotEmpty) const PopupMenuDivider(),
        for (final layout in saved)
          PopupMenuItem<LayoutPick>(
            key: ValueKey('layout-saved-${layout.id}'),
            value: LayoutPickSaved(layout),
            height: 36,
            child: _SavedRow(
              layout: layout,
              onDelete: () =>
                  Navigator.of(context).pop(LayoutPickDelete(layout)),
            ),
          ),
        const PopupMenuDivider(),
        const PopupMenuItem<LayoutPick>(
          key: ValueKey('layout-save'),
          value: LayoutPickSave(),
          height: 36,
          child: Row(
            children: [
              Icon(Icons.bookmark_add_outlined, size: 18),
              SizedBox(width: 10),
              Flexible(
                child: Text(
                  'Save this layout…',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ],
    );
    if (pick != null) onPick(pick);
  }

  @override
  Widget build(BuildContext context) {
    return Builder(
      builder: (context) => IconButton(
        key: const ValueKey('shell-layout-picker'),
        tooltip: 'Layout: split into panes, saved layouts',
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 38, height: 40),
        icon: const Icon(Icons.dashboard_outlined, size: 19),
        onPressed: () => _open(context),
      ),
    );
  }
}

class _PresetGrid extends StatelessWidget {
  const _PresetGrid({required this.current, required this.onPick});

  final ShellLayoutPreset? current;
  final ValueChanged<ShellLayoutPreset> onPick;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'LAYOUT',
            style: TextStyle(
              color: palette.mutedForeground,
              fontSize: 11,
              letterSpacing: 1.1,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final preset in ShellLayoutPreset.values)
                _PresetTile(
                  preset: preset,
                  selected: preset == current,
                  onTap: () => onPick(preset),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PresetTile extends StatelessWidget {
  const _PresetTile({
    required this.preset,
    required this.selected,
    required this.onTap,
  });

  final ShellLayoutPreset preset;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Tooltip(
      message: preset.label,
      child: Material(
        color: selected
            ? palette.accent.withValues(alpha: 0.16)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          key: ValueKey('layout-preset-${preset.name}'),
          borderRadius: BorderRadius.circular(6),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(5),
            child: LayoutDiagram(
              root: preset.tree,
              size: const Size(44, 30),
              color: selected ? palette.accent : palette.mutedForeground,
            ),
          ),
        ),
      ),
    );
  }
}

class _SavedRow extends StatelessWidget {
  const _SavedRow({required this.layout, required this.onDelete});

  final SavedShellLayout layout;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Row(
      children: [
        LayoutDiagram(
          root: layout.layout.root,
          size: const Size(24, 16),
          color: palette.mutedForeground,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            layout.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        IconButton(
          tooltip: 'Delete ${layout.name}',
          iconSize: 15,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 26, height: 26),
          onPressed: onDelete,
          icon: const Icon(Icons.delete_outline_rounded),
        ),
      ],
    );
  }
}

/// A split tree drawn as outlined rectangles, like a layout's icon.
class LayoutDiagram extends StatelessWidget {
  const LayoutDiagram({
    required this.root,
    required this.size,
    required this.color,
    super.key,
  });

  final ShellNode root;
  final Size size;
  final Color color;

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: size,
    painter: _DiagramPainter(ShellLayout.of(root, '').paneRects(), color),
  );
}

class _DiagramPainter extends CustomPainter {
  _DiagramPainter(this.rects, this.color);

  final Map<String, Rect> rects;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;
    final fill = Paint()..color = color.withValues(alpha: 0.12);
    for (final rect in rects.values) {
      final scaled = Rect.fromLTRB(
        rect.left * size.width,
        rect.top * size.height,
        rect.right * size.width,
        rect.bottom * size.height,
      ).deflate(1.5);
      final rounded = RRect.fromRectAndRadius(scaled, const Radius.circular(2));
      canvas
        ..drawRRect(rounded, fill)
        ..drawRRect(rounded, paint);
    }
  }

  @override
  bool shouldRepaint(_DiagramPainter old) =>
      old.color != color || old.rects.length != rects.length;
}
