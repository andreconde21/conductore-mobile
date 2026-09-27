import 'package:conduit/core/presentation/adaptive_modal.dart';
import 'package:conduit/features/quick_actions/domain/quick_action.dart';
import 'package:conduit/features/quick_actions/domain/quick_action_plan.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Where a new quick action is kept.
enum QuickActionHome {
  /// The repo's `.code-workspace` file (shared with the team and Lite).
  repo,

  /// Settings, synced across your devices.
  personal,
}

/// What the "Add action" form returns.
typedef QuickActionDraft = ({QuickAction action, QuickActionHome home});

/// A material icon for an action's `icon` name.
IconData quickActionIcon(QuickAction action) => switch (action.icon) {
  'play_arrow' => Icons.play_arrow_rounded,
  'build' => Icons.build_outlined,
  'bug_report' => Icons.bug_report_outlined,
  'science' => Icons.science_outlined,
  'rocket_launch' => Icons.rocket_launch_outlined,
  'cloud_upload' => Icons.cloud_upload_outlined,
  'sync' => Icons.sync_rounded,
  'terminal' => Icons.terminal_rounded,
  'code' => Icons.code_rounded,
  'description' => Icons.description_outlined,
  'public' => Icons.public_rounded,
  'smart_toy' => Icons.smart_toy_outlined,
  'cleaning_services' => Icons.cleaning_services_outlined,
  'restart_alt' => Icons.restart_alt_rounded,
  'bolt' => Icons.bolt_rounded,
  _ => switch (action.kind) {
    QuickActionKind.shell => Icons.play_arrow_rounded,
    QuickActionKind.prompt => Icons.smart_toy_outlined,
    QuickActionKind.url => Icons.public_rounded,
  },
};

/// The "Add action" form for [projectName]: a dialog on desktop, a sheet
/// on phones. [repoFile] names the file a repo action goes to (null when
/// the repo's folder is not known: only personal actions then).
Future<QuickActionDraft?> showQuickActionForm(
  BuildContext context, {
  required String projectName,
  required Iterable<String> takenIds,
  String? repoFile,
  QuickAction? initial,
}) {
  return showAdaptiveModal<QuickActionDraft>(
    context: context,
    kind: AdaptiveModalKind.dialog,
    desktopMaxWidth: 560,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => QuickActionForm(
      projectName: projectName,
      takenIds: takenIds.toSet(),
      repoFile: repoFile,
      initial: initial,
    ),
  );
}

class QuickActionForm extends StatefulWidget {
  const QuickActionForm({
    required this.projectName,
    required this.takenIds,
    this.repoFile,
    this.initial,
    super.key,
  });

  final String projectName;
  final Set<String> takenIds;
  final String? repoFile;
  final QuickAction? initial;

  @override
  State<QuickActionForm> createState() => _QuickActionFormState();
}

class _QuickActionFormState extends State<QuickActionForm> {
  late final _label = TextEditingController(text: widget.initial?.label);
  late final _command = TextEditingController(text: widget.initial?.command);
  late final _terminal = TextEditingController(
    text: widget.initial?.terminalName,
  );
  late final _cwd = TextEditingController(text: widget.initial?.cwd);
  late final _keys = TextEditingController(text: widget.initial?.keybinding);
  late QuickActionKind _kind = widget.initial?.kind ?? QuickActionKind.shell;
  late String? _icon = widget.initial?.icon;
  late bool _confirm = widget.initial?.confirm ?? false;
  late QuickActionHome _home = widget.repoFile == null
      ? QuickActionHome.personal
      : QuickActionHome.repo;
  bool _onlyThisProject = true;
  String? _error;

  @override
  void dispose() {
    _label.dispose();
    _command.dispose();
    _terminal.dispose();
    _cwd.dispose();
    _keys.dispose();
    super.dispose();
  }

  void _save() {
    final label = _label.text.trim();
    final command = _command.text.trim();
    final keys = _keys.text.trim();
    String? error;
    if (label.isEmpty) {
      error = 'Give it a name.';
    } else if (command.isEmpty) {
      error = switch (_kind) {
        QuickActionKind.shell => 'Type the command to run.',
        QuickActionKind.prompt => 'Type the prompt to send.',
        QuickActionKind.url => 'Type the address to open.',
      };
    } else if (keys.isNotEmpty) {
      final parsed = QuickActionKeys.parse(keys);
      if (parsed == null) {
        error = 'Keys look like ctrl+shift+b or f5.';
      } else if (!parsed.safe) {
        error = 'Add Ctrl, Alt or Cmd: a plain key would stop typing.';
      }
    }
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    final action = QuickAction(
      id: widget.initial?.id ?? QuickAction.newId(label, widget.takenIds),
      label: label,
      command: command,
      kind: _kind,
      terminalName:
          _kind == QuickActionKind.shell && _terminal.text.trim().isNotEmpty
          ? _terminal.text.trim()
          : null,
      cwd: _kind == QuickActionKind.shell && _cwd.text.trim().isNotEmpty
          ? _cwd.text.trim()
          : null,
      icon: _icon,
      keybinding: keys.isEmpty ? null : keys,
      confirm: _confirm,
      onWorktreeCreate: widget.initial?.onWorktreeCreate ?? false,
      project: _home == QuickActionHome.personal && _onlyThisProject
          ? widget.projectName
          : null,
    );
    Navigator.of(context).pop((action: action, home: _home));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final repoFile = widget.repoFile;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, control: true): _save,
        const SingleActivator(LogicalKeyboardKey.enter, meta: true): _save,
      },
      child: SingleChildScrollView(
        key: const ValueKey('quick-action-form'),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.initial == null
                  ? 'Add a quick action to ${widget.projectName}'
                  : 'Edit ${widget.initial!.label}',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 14),
            SegmentedButton<QuickActionKind>(
              key: const ValueKey('quick-action-kind'),
              segments: const [
                ButtonSegment(
                  value: QuickActionKind.shell,
                  icon: Icon(Icons.terminal_rounded, size: 16),
                  label: Text('Command'),
                ),
                ButtonSegment(
                  value: QuickActionKind.prompt,
                  icon: Icon(Icons.smart_toy_outlined, size: 16),
                  label: Text('Prompt'),
                ),
                ButtonSegment(
                  value: QuickActionKind.url,
                  icon: Icon(Icons.public_rounded, size: 16),
                  label: Text('Link'),
                ),
              ],
              selected: {_kind},
              onSelectionChanged: (kinds) =>
                  setState(() => _kind = kinds.first),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('quick-action-label'),
              controller: _label,
              autofocus: true,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'Name',
                hintText: 'Dev server, Tests, Deploy…',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              key: const ValueKey('quick-action-command'),
              controller: _command,
              minLines: 1,
              maxLines: _kind == QuickActionKind.prompt ? 4 : 1,
              textInputAction: _kind == QuickActionKind.prompt
                  ? TextInputAction.newline
                  : TextInputAction.done,
              onSubmitted: (_) => _save(),
              style: _kind == QuickActionKind.shell
                  ? const TextStyle(fontFamily: 'monospace')
                  : null,
              decoration: InputDecoration(
                labelText: switch (_kind) {
                  QuickActionKind.shell => 'Command',
                  QuickActionKind.prompt => 'Prompt for the agent',
                  QuickActionKind.url => 'Address',
                },
                hintText: switch (_kind) {
                  QuickActionKind.shell => 'npm run dev',
                  QuickActionKind.prompt => 'Run the tests and fix what fails',
                  QuickActionKind.url => 'https://localhost:3000',
                },
              ),
            ),
            if (_kind == QuickActionKind.shell) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('quick-action-terminal'),
                      controller: _terminal,
                      onSubmitted: (_) => _save(),
                      decoration: const InputDecoration(
                        labelText: 'Terminal name (optional)',
                        hintText: 'Reuses it when open',
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      key: const ValueKey('quick-action-cwd'),
                      controller: _cwd,
                      onSubmitted: (_) => _save(),
                      decoration: const InputDecoration(
                        labelText: 'Folder (optional)',
                        hintText: 'src, relative to the repo',
                      ),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('quick-action-keys'),
                    controller: _keys,
                    onSubmitted: (_) => _save(),
                    decoration: const InputDecoration(
                      labelText: 'Keys (optional)',
                      hintText: 'ctrl+alt+t',
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                DropdownButton<String?>(
                  key: const ValueKey('quick-action-icon'),
                  value: _icon,
                  hint: const Text('Icon'),
                  onChanged: (value) => setState(() => _icon = value),
                  items: [
                    const DropdownMenuItem(child: Text('Default')),
                    for (final name in QuickAction.iconNames)
                      DropdownMenuItem(
                        value: name,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              quickActionIcon(
                                QuickAction(
                                  id: '',
                                  label: '',
                                  command: '',
                                  icon: name,
                                ),
                              ),
                              size: 18,
                            ),
                            const SizedBox(width: 8),
                            Text(name.replaceAll('_', ' ')),
                          ],
                        ),
                      ),
                  ],
                ),
              ],
            ),
            CheckboxListTile(
              key: const ValueKey('quick-action-confirm'),
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: _confirm,
              onChanged: (value) => setState(() => _confirm = value ?? false),
              title: const Text('Ask before running'),
            ),
            const Divider(),
            Text('Keep it in', style: theme.textTheme.labelLarge),
            RadioGroup<QuickActionHome>(
              groupValue: _home,
              onChanged: (value) {
                if (value != null) setState(() => _home = value);
              },
              child: Column(
                children: [
                  RadioListTile<QuickActionHome>(
                    key: const ValueKey('quick-action-home-repo'),
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    enabled: repoFile != null,
                    value: QuickActionHome.repo,
                    title: const Text('The repo, for everyone'),
                    subtitle: Text(
                      repoFile == null
                          ? 'The repo folder is not known yet.'
                          : '$repoFile (asks before writing)',
                    ),
                  ),
                  const RadioListTile<QuickActionHome>(
                    key: ValueKey('quick-action-home-personal'),
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    value: QuickActionHome.personal,
                    title: Text('My actions'),
                    subtitle: Text('Settings, synced to your devices'),
                  ),
                ],
              ),
            ),
            if (_home == QuickActionHome.personal)
              CheckboxListTile(
                key: const ValueKey('quick-action-only-project'),
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: _onlyThisProject,
                onChanged: (value) =>
                    setState(() => _onlyThisProject = value ?? true),
                title: Text('Only for ${widget.projectName}'),
              ),
            if (_error case final error?)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  error,
                  key: const ValueKey('quick-action-error'),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            const SizedBox(height: 12),
            OverflowBar(
              alignment: MainAxisAlignment.end,
              spacing: 8,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  key: const ValueKey('quick-action-save'),
                  onPressed: _save,
                  child: const Text('Save'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
