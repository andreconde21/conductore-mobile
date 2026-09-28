import 'package:conduit/core/presentation/adaptive_modal.dart';
import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/features/snippets/domain/terminal_snippet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Built-in quick prompts for driving Claude Code from the toolbar palette.
enum ToolbarQuickPrompt {
  clear('/clear', 'Start a fresh conversation', text: '/clear'),
  compact('/compact', 'Summarize the context', text: '/compact'),
  help('/help', 'Show Claude Code help', text: '/help'),
  continuePrompt('continue', 'Tell the agent to keep going', text: 'continue'),
  yes('yes', 'Confirm the current question', text: 'yes'),
  escapeTwice('Esc Esc', 'Rewind or clear the input'),
  interrupt('Ctrl+C', 'Interrupt the running command');

  const ToolbarQuickPrompt(this.label, this.description, {this.text});

  final String label;
  final String description;

  /// The line to type and submit with Enter; null for key sequences.
  final String? text;
}

/// Opens the swipe-up palette: quick prompts first, then the host's and the
/// global saved snippets (the same lists the Snip key-row menu shows).
///
/// Selecting an entry pops the sheet and reports it through the callbacks.
Future<void> showToolbarSnippetPalette({
  required BuildContext context,
  required AppPalette palette,
  required Brightness brightness,
  required List<TerminalSnippet> hostSnippets,
  required List<TerminalSnippet> globalSnippets,
  required ValueChanged<ToolbarQuickPrompt> onQuickPrompt,
  required ValueChanged<TerminalSnippet> onSnippet,
  String hostPassword = '',
  ValueChanged<String>? onPassword,
  VoidCallback? onDictate,
}) {
  return showAdaptiveModal<void>(
    kind: AdaptiveModalKind.palette,
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    backgroundColor: palette.panelFor(brightness),
    builder: (context) => ToolbarSnippetPalette(
      palette: palette,
      brightness: brightness,
      hostSnippets: hostSnippets,
      globalSnippets: globalSnippets,
      hostPassword: hostPassword,
      onQuickPrompt: (prompt) {
        Navigator.of(context).pop();
        onQuickPrompt(prompt);
      },
      onSnippet: (snippet) {
        Navigator.of(context).pop();
        onSnippet(snippet);
      },
      onPassword: onPassword == null
          ? null
          : (password) {
              Navigator.of(context).pop();
              onPassword(password);
            },
      onDictate: onDictate == null
          ? null
          : () {
              Navigator.of(context).pop();
              onDictate();
            },
    ),
  );
}

class ToolbarSnippetPalette extends StatelessWidget {
  const ToolbarSnippetPalette({
    required this.palette,
    required this.brightness,
    required this.hostSnippets,
    required this.globalSnippets,
    required this.onQuickPrompt,
    required this.onSnippet,
    this.hostPassword = '',
    this.onPassword,
    this.onDictate,
    super.key,
  });

  final AppPalette palette;
  final Brightness brightness;
  final List<TerminalSnippet> hostSnippets;
  final List<TerminalSnippet> globalSnippets;
  final ValueChanged<ToolbarQuickPrompt> onQuickPrompt;
  final ValueChanged<TerminalSnippet> onSnippet;
  final String hostPassword;
  final ValueChanged<String>? onPassword;

  /// Opens the chat line with dictation running; null hides the chip.
  final VoidCallback? onDictate;

  @override
  Widget build(BuildContext context) {
    // A command palette on desktop: a filter field and keyboard picking.
    if (useDesktopModals(context)) return _DesktopSnippetPalette(this);
    final theme = Theme.of(context);
    final foreground = palette.foregroundFor(brightness);
    final muted = palette.mutedForegroundFor(brightness);
    final host = hostSnippets.where((snippet) => snippet.isValid).toList();
    final global = globalSnippets.where((snippet) => snippet.isValid).toList();
    final hasPassword = hostPassword.isNotEmpty && onPassword != null;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.7;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
        children: [
          Text(
            'Quick prompts',
            style: theme.textTheme.titleSmall?.copyWith(color: foreground),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (onDictate != null)
                Tooltip(
                  message: 'Speak a line into the chat line',
                  child: ActionChip(
                    key: const ValueKey('palette-dictate'),
                    avatar: Icon(Icons.mic_none_rounded, color: foreground),
                    label: const Text('Dictate'),
                    labelStyle: TextStyle(
                      color: foreground,
                      fontWeight: FontWeight.w700,
                    ),
                    backgroundColor: palette.panelElevatedFor(brightness),
                    side: BorderSide(color: palette.hairlineFor(brightness)),
                    onPressed: onDictate,
                  ),
                ),
              for (final prompt in ToolbarQuickPrompt.values)
                Tooltip(
                  message: prompt.description,
                  child: ActionChip(
                    label: Text(prompt.label),
                    labelStyle: TextStyle(
                      color: foreground,
                      fontWeight: FontWeight.w700,
                    ),
                    backgroundColor: palette.panelElevatedFor(brightness),
                    side: BorderSide(color: palette.hairlineFor(brightness)),
                    onPressed: () => onQuickPrompt(prompt),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 18),
          Text(
            'Snippets',
            style: theme.textTheme.titleSmall?.copyWith(color: foreground),
          ),
          const SizedBox(height: 4),
          if (host.isEmpty && global.isEmpty && !hasPassword)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'No snippets saved. Add global snippets in Settings › Terminal, or '
                'per-machine snippets when editing a machine.',
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
            ),
          if (host.isNotEmpty) ...[
            _SectionLabel('Host', color: muted),
            for (final snippet in host)
              _SnippetTile(
                snippet: snippet,
                foreground: foreground,
                muted: muted,
                onTap: () => onSnippet(snippet),
              ),
          ],
          if (global.isNotEmpty) ...[
            _SectionLabel('Global', color: muted),
            for (final snippet in global)
              _SnippetTile(
                snippet: snippet,
                foreground: foreground,
                muted: muted,
                onTap: () => onSnippet(snippet),
              ),
          ],
          if (hasPassword)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.visibility_off_rounded, color: muted),
              title: Text('Password', style: TextStyle(color: foreground)),
              subtitle: Text(
                'Types the saved host password',
                style: TextStyle(color: muted),
              ),
              onTap: () => onPassword!(hostPassword),
            ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text, {required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 2),
      child: Text(
        text,
        style: Theme.of(
          context,
        ).textTheme.labelSmall?.copyWith(color: color, letterSpacing: 0.6),
      ),
    );
  }
}

class _SnippetTile extends StatelessWidget {
  const _SnippetTile({
    required this.snippet,
    required this.foreground,
    required this.muted,
    required this.onTap,
  });

  final TerminalSnippet snippet;
  final Color foreground;
  final Color muted;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final preview = snippet.hidden || snippet.text.isEmpty
        ? null
        : snippet.submit
        ? '${snippet.text} + Enter'
        : snippet.text;
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        snippet.hidden ? Icons.visibility_off_rounded : Icons.code_rounded,
        color: muted,
      ),
      title: Text(
        snippet.label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: foreground),
      ),
      subtitle: preview == null
          ? null
          : Text(
              preview,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: muted),
            ),
      onTap: onTap,
    );
  }
}

/// One row of the desktop palette.
class _PaletteEntry {
  const _PaletteEntry({
    required this.label,
    required this.icon,
    required this.onSelect,
    this.detail,
    this.section,
  });

  final String label;
  final String? detail;
  final IconData icon;
  final VoidCallback onSelect;

  /// Shown above the first entry of a section.
  final String? section;

  bool matches(String query) =>
      query.isEmpty ||
      label.toLowerCase().contains(query) ||
      (detail?.toLowerCase().contains(query) ?? false);
}

/// The desktop form of [ToolbarSnippetPalette]: every quick prompt and
/// snippet as a row under an autofocused filter; Up and Down move the
/// highlight, Enter runs it.
class _DesktopSnippetPalette extends StatefulWidget {
  const _DesktopSnippetPalette(this.palette);

  final ToolbarSnippetPalette palette;

  @override
  State<_DesktopSnippetPalette> createState() => _DesktopSnippetPaletteState();
}

class _DesktopSnippetPaletteState extends State<_DesktopSnippetPalette> {
  final _query = TextEditingController();
  final _highlightedKey = GlobalKey();
  int _highlighted = 0;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  List<_PaletteEntry> _entries() {
    final p = widget.palette;
    final hasPassword = p.hostPassword.isNotEmpty && p.onPassword != null;
    String? preview(TerminalSnippet snippet) =>
        snippet.hidden || snippet.text.isEmpty
        ? null
        : snippet.submit
        ? '${snippet.text} + Enter'
        : snippet.text;
    final host = p.hostSnippets.where((snippet) => snippet.isValid).toList();
    final global = p.globalSnippets
        .where((snippet) => snippet.isValid)
        .toList();
    return [
      if (p.onDictate case final onDictate?)
        _PaletteEntry(
          label: 'Dictate',
          detail: 'Speak a line into the chat line',
          icon: Icons.mic_none_rounded,
          onSelect: onDictate,
          section: 'Quick prompts',
        ),
      for (final (i, prompt) in ToolbarQuickPrompt.values.indexed)
        _PaletteEntry(
          label: prompt.label,
          detail: prompt.description,
          icon: Icons.bolt_rounded,
          onSelect: () => p.onQuickPrompt(prompt),
          section: i == 0 && p.onDictate == null ? 'Quick prompts' : null,
        ),
      for (final (i, snippet) in host.indexed)
        _PaletteEntry(
          label: snippet.label,
          detail: preview(snippet),
          icon: snippet.hidden
              ? Icons.visibility_off_rounded
              : Icons.code_rounded,
          onSelect: () => p.onSnippet(snippet),
          section: i == 0 ? 'Host' : null,
        ),
      for (final (i, snippet) in global.indexed)
        _PaletteEntry(
          label: snippet.label,
          detail: preview(snippet),
          icon: snippet.hidden
              ? Icons.visibility_off_rounded
              : Icons.code_rounded,
          onSelect: () => p.onSnippet(snippet),
          section: i == 0 ? 'Global' : null,
        ),
      if (hasPassword)
        _PaletteEntry(
          label: 'Password',
          detail: 'Types the saved host password',
          icon: Icons.visibility_off_rounded,
          onSelect: () => p.onPassword!(p.hostPassword),
          section: host.isEmpty && global.isEmpty ? 'Snippets' : null,
        ),
    ];
  }

  List<_PaletteEntry> _visible() {
    final query = _query.text.trim().toLowerCase();
    return [
      for (final entry in _entries())
        if (entry.matches(query)) entry,
    ];
  }

  void _move(int delta) {
    final count = _visible().length;
    if (count == 0) return;
    setState(() => _highlighted = (_highlighted + delta).clamp(0, count - 1));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _highlightedKey.currentContext;
      if (target != null && target.mounted) {
        Scrollable.ensureVisible(target, alignment: 0.5);
      }
    });
  }

  void _run() {
    final visible = _visible();
    if (visible.isEmpty) return;
    visible[_highlighted.clamp(0, visible.length - 1)].onSelect();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final theme = Theme.of(context);
    final foreground = p.palette.foregroundFor(p.brightness);
    final muted = p.palette.mutedForegroundFor(p.brightness);
    final visible = _visible();
    final highlighted = visible.isEmpty
        ? -1
        : _highlighted.clamp(0, visible.length - 1);
    final query = _query.text.trim();
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowDown): () => _move(1),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () => _move(-1),
        const SingleActivator(LogicalKeyboardKey.enter): _run,
        const SingleActivator(LogicalKeyboardKey.numpadEnter): _run,
      },
      child: Column(
        key: const ValueKey('snippet-palette-desktop'),
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
            child: TextField(
              key: const ValueKey('snippet-palette-filter'),
              controller: _query,
              autofocus: true,
              decoration: const InputDecoration(
                isDense: true,
                prefixIcon: Icon(Icons.search_rounded),
                hintText: 'Filter prompts and snippets',
              ),
              onChanged: (_) => setState(() => _highlighted = 0),
            ),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
              children: [
                if (visible.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      query.isEmpty
                          ? 'No snippets saved. Add global snippets in '
                                'Settings › Terminal, or per-machine snippets '
                                'when editing a machine.'
                          : 'Nothing matches "$query".',
                      style: theme.textTheme.bodySmall?.copyWith(color: muted),
                    ),
                  ),
                for (final (i, entry) in visible.indexed) ...[
                  if (entry.section != null && query.isEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 8, 8, 2),
                      child: _SectionLabel(entry.section!, color: muted),
                    ),
                  ListTile(
                    key: i == highlighted ? _highlightedKey : null,
                    dense: true,
                    selected: i == highlighted,
                    selectedTileColor: p.palette.accent.withValues(alpha: 0.14),
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.all(Radius.circular(8)),
                    ),
                    leading: Icon(entry.icon, color: muted, size: 18),
                    title: Text(
                      entry.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: foreground),
                    ),
                    subtitle: entry.detail == null
                        ? null
                        : Text(
                            entry.detail!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: muted),
                          ),
                    onTap: entry.onSelect,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
