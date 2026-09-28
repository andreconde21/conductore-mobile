import 'package:conduit/core/presentation/adaptive_modal.dart';
import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/core/theme/app_theme.dart';
import 'package:conduit/features/command_palette/domain/palette_entry.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Opens the command palette at the top of the window and resolves with
/// the entry picked (null when dismissed); the caller runs it.
///
/// [initialQuery] can start it in a scope (`>` for commands). [entries] is
/// read again whenever [changes] fires, so agents and sessions stay live.
Future<PaletteEntry?> showCommandPalette(
  BuildContext context, {
  required List<PaletteEntry> Function() entries,
  Listenable? changes,
  String initialQuery = '',
  List<String> recents = const [],
}) {
  return showAdaptiveModal<PaletteEntry>(
    context: context,
    kind: AdaptiveModalKind.palette,
    desktopMaxWidth: 680,
    desktopFill: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => CommandPalette(
      entries: entries,
      changes: changes,
      initialQuery: initialQuery,
      recents: recents,
      onPick: (entry) => Navigator.of(context).pop(entry),
    ),
  );
}

/// The palette itself: a search field (with the `>`, `@` and `#` scope
/// prefixes) over the ranked rows. Up and Down move, Enter runs, a click
/// runs; each row shows its kind and its keyboard shortcut.
class CommandPalette extends StatefulWidget {
  const CommandPalette({
    required this.entries,
    required this.onPick,
    this.changes,
    this.initialQuery = '',
    this.recents = const [],
    super.key,
  });

  final List<PaletteEntry> Function() entries;
  final Listenable? changes;
  final String initialQuery;
  final List<String> recents;
  final ValueChanged<PaletteEntry> onPick;

  static const rowHeight = 40.0;

  @override
  State<CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends State<CommandPalette> {
  late final _search = TextEditingController(text: widget.initialQuery)
    ..selection = TextSelection.collapsed(offset: widget.initialQuery.length);
  final _scroll = ScrollController();
  int _highlight = 0;
  List<PaletteEntry> _visible = const [];
  bool _picked = false;

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _pick(PaletteEntry entry) {
    if (_picked || !entry.enabled) return;
    _picked = true;
    widget.onPick(entry);
  }

  void _pickHighlighted() {
    if (_visible.isEmpty) return;
    _pick(_visible[_highlight.clamp(0, _visible.length - 1)]);
  }

  void _move(int delta) {
    if (_visible.isEmpty) return;
    setState(() {
      _highlight = (_highlight + delta).clamp(0, _visible.length - 1);
    });
    if (!_scroll.hasClients) return;
    final top = _highlight * CommandPalette.rowHeight;
    final bottom = top + CommandPalette.rowHeight;
    final position = _scroll.position;
    if (top < position.pixels) {
      _scroll.jumpTo(top);
    } else if (bottom > position.pixels + position.viewportDimension) {
      _scroll.jumpTo(bottom - position.viewportDimension);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final scope = parsePaletteQuery(_search.text).scope;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowDown): () => _move(1),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () => _move(-1),
        const SingleActivator(LogicalKeyboardKey.pageDown): () => _move(8),
        const SingleActivator(LogicalKeyboardKey.pageUp): () => _move(-8),
        const SingleActivator(LogicalKeyboardKey.enter): _pickHighlighted,
        const SingleActivator(LogicalKeyboardKey.numpadEnter): _pickHighlighted,
      },
      child: Column(
        key: const ValueKey('command-palette'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            child: TextField(
              key: const ValueKey('command-palette-search'),
              controller: _search,
              autofocus: true,
              style: const TextStyle(fontSize: 14),
              onChanged: (_) => setState(() => _highlight = 0),
              onSubmitted: (_) => _pickHighlighted(),
              decoration: InputDecoration(
                isDense: true,
                hintText: scope.hint,
                prefixIcon: Icon(switch (scope) {
                  PaletteScope.commands => Icons.chevron_right_rounded,
                  PaletteScope.agents => Icons.alternate_email_rounded,
                  PaletteScope.places => Icons.tag_rounded,
                  PaletteScope.all => Icons.search_rounded,
                }, size: 18),
                border: OutlineInputBorder(borderRadius: AppTheme.borderRadius),
              ),
            ),
          ),
          Divider(height: 1, color: palette.hairline),
          Expanded(
            child: ListenableBuilder(
              listenable: widget.changes ?? _never,
              builder: (context, _) {
                _visible = rankPalette(
                  widget.entries(),
                  _search.text,
                  recents: widget.recents,
                );
                if (_visible.isEmpty) {
                  return Center(
                    child: Text(
                      'Nothing matches.',
                      style: TextStyle(color: palette.mutedForeground),
                    ),
                  );
                }
                final highlight = _highlight.clamp(0, _visible.length - 1);
                return ListView.builder(
                  key: const ValueKey('command-palette-list'),
                  controller: _scroll,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemExtent: CommandPalette.rowHeight,
                  itemCount: _visible.length,
                  itemBuilder: (context, index) => _PaletteRow(
                    key: ValueKey('palette-${_visible[index].id}'),
                    entry: _visible[index],
                    highlighted: index == highlight,
                    onHover: () {
                      if (_highlight != index) {
                        setState(() => _highlight = index);
                      }
                    },
                    onTap: () => _pick(_visible[index]),
                  ),
                );
              },
            ),
          ),
          const _Footer(),
        ],
      ),
    );
  }

  static final Listenable _never = ChangeNotifier();
}

class _PaletteRow extends StatelessWidget {
  const _PaletteRow({
    required this.entry,
    required this.highlighted,
    required this.onHover,
    required this.onTap,
    super.key,
  });

  final PaletteEntry entry;
  final bool highlighted;
  final VoidCallback onHover;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final muted = palette.mutedForeground;
    final enabled = entry.enabled;
    return MouseRegion(
      onHover: (_) => onHover(),
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? onTap : null,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 6),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: highlighted
                ? palette.accent.withValues(alpha: 0.16)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Opacity(
            opacity: enabled ? 1 : 0.45,
            child: Row(
              children: [
                SizedBox(
                  width: 22,
                  child: Center(
                    child:
                        entry.leading ??
                        Icon(
                          entry.icon ?? Icons.bolt_rounded,
                          size: 17,
                          color: entry.urgent ? palette.attention : muted,
                        ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: entry.title,
                          style: TextStyle(
                            color: palette.foreground,
                            fontWeight: FontWeight.w600,
                            fontSize: 13.5,
                          ),
                        ),
                        if (entry.subtitle.isNotEmpty)
                          TextSpan(
                            text: '   ${entry.subtitle}',
                            style: TextStyle(color: muted, fontSize: 12),
                          ),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (entry.shortcut case final keys?) ...[
                  const SizedBox(width: 8),
                  _Keys(keys),
                ],
                const SizedBox(width: 10),
                SizedBox(
                  width: 78,
                  child: Text(
                    entry.kind.label,
                    textAlign: TextAlign.end,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: muted, fontSize: 11),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A keyboard shortcut drawn as a key cap.
class _Keys extends StatelessWidget {
  const _Keys(this.keys);

  final String keys;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: palette.canvas,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: palette.hairline),
      ),
      child: Text(
        keys,
        style: TextStyle(
          color: palette.mutedForeground,
          fontSize: 11,
          fontFamily: 'monospace',
        ),
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer();

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final style = TextStyle(color: palette.mutedForeground, fontSize: 11);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: palette.hairline)),
      ),
      child: Text(
        '↑↓ move   Enter run   Esc close   '
        '> commands   @ agents   # places',
        style: style,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}
