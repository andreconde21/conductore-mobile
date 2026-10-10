import 'package:conduit/features/sessions/domain/new_workspace.dart';
import 'package:flutter/material.dart';

/// Lists the folders under [folder] (the project roots when null), as
/// absolute paths. Throws when the machine cannot be asked.
typedef FolderLister = Future<List<String>> Function(String? folder);

/// Opens the folder picker as a full-height bottom sheet: [recents] first,
/// then the project folders [list] finds, a step into any folder's
/// subfolders, and what is typed to filter them (or to use as it is).
/// Resolves with the chosen folder, or null when dismissed.
Future<String?> showFolderPickerSheet(
  BuildContext context, {
  required List<String> recents,
  FolderLister? list,
  String initialQuery = '',
}) => showModalBottomSheet<String>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (context) => FolderPickerSheet(
    recents: recents,
    list: list,
    initialQuery: initialQuery,
  ),
);

class FolderPickerSheet extends StatefulWidget {
  const FolderPickerSheet({
    required this.recents,
    this.list,
    this.initialQuery = '',
    super.key,
  });

  final List<String> recents;

  /// How to list folders; null offers the recent folders only.
  final FolderLister? list;
  final String initialQuery;

  @override
  State<FolderPickerSheet> createState() => _FolderPickerSheetState();
}

class _FolderPickerSheetState extends State<FolderPickerSheet> {
  late final _query = TextEditingController(text: widget.initialQuery);

  /// The folders stepped into, outermost first; empty at the top level.
  final _path = <String>[];
  List<String>? _listed;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  String? get _current => _path.isEmpty ? null : _path.last;

  Future<void> _load() async {
    final list = widget.list;
    final folder = _current;
    setState(() {
      _listed = null;
      _failed = false;
    });
    if (list == null) {
      setState(() => _listed = const []);
      return;
    }
    List<String>? found;
    try {
      found = await list(folder);
    } catch (_) {
      found = null;
    }
    // A later step replaced this answer.
    if (!mounted || folder != _current) return;
    setState(() {
      _listed = found ?? const [];
      _failed = found == null;
    });
  }

  void _step(List<String> path) {
    _path
      ..clear()
      ..addAll(path);
    _query.clear();
    _load();
  }

  /// Recent folders (top level only) and then the listed ones, those
  /// matching what is typed.
  List<String> get _rows {
    final query = _query.text.trim().toLowerCase();
    final all = [
      if (_path.isEmpty) ...widget.recents,
      for (final folder in _listed ?? const <String>[])
        if (!(_path.isEmpty && widget.recents.contains(folder))) folder,
    ];
    return [
      for (final folder in all)
        if (query.isEmpty || folder.toLowerCase().contains(query)) folder,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final typed = _query.text.trim();
    final rows = _rows;
    final loading = _listed == null;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        key: const ValueKey('folder-picker'),
        height: MediaQuery.sizeOf(context).height,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
              child: Row(
                children: [
                  if (_path.isNotEmpty)
                    IconButton(
                      key: const ValueKey('folder-picker-up'),
                      tooltip: 'Up',
                      icon: const Icon(Icons.arrow_back),
                      onPressed: () =>
                          _step(_path.sublist(0, _path.length - 1)),
                    ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Text(
                        _current ?? 'Starting folder',
                        style: theme.textTheme.titleMedium,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  if (_current case final current?)
                    TextButton(
                      key: const ValueKey('folder-picker-use-current'),
                      onPressed: () => Navigator.of(context).pop(current),
                      child: const Text('Use this folder'),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: TextField(
                key: const ValueKey('folder-picker-search'),
                controller: _query,
                autofocus: true,
                autocorrect: false,
                enableSuggestions: false,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Search, or type a path',
                ),
              ),
            ),
            if (loading)
              const LinearProgressIndicator(
                key: ValueKey('folder-picker-loading'),
              ),
            if (_failed)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  'Could not list this machine\'s folders. Type a path '
                  'instead.',
                  key: const ValueKey('folder-picker-failed'),
                  style: theme.textTheme.bodySmall,
                ),
              ),
            Expanded(
              child: ListView(
                children: [
                  if (typed.isNotEmpty && !rows.contains(typed))
                    ListTile(
                      key: const ValueKey('folder-picker-use-typed'),
                      leading: const Icon(Icons.edit_outlined),
                      title: Text('Use "$typed"'),
                      onTap: () => Navigator.of(context).pop(typed),
                    ),
                  for (final folder in rows)
                    ListTile(
                      key: ValueKey('folder-picker-row-$folder'),
                      leading: Icon(
                        widget.recents.contains(folder) && _path.isEmpty
                            ? Icons.history
                            : Icons.folder_outlined,
                      ),
                      title: Text(NewWorkspaceCommands.folderName(folder)),
                      subtitle: Text(
                        folder,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => Navigator.of(context).pop(folder),
                      trailing: widget.list == null
                          ? null
                          : IconButton(
                              key: ValueKey('folder-picker-open-$folder'),
                              tooltip: 'Open',
                              icon: const Icon(Icons.chevron_right),
                              onPressed: () => _step([..._path, folder]),
                            ),
                    ),
                  if (!loading && rows.isEmpty && typed.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                        'No folders found.',
                        key: ValueKey('folder-picker-empty'),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
