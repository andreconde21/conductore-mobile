part of 'desktop_home.dart';

/// The Projects tab and quick actions of the desktop shell (CON-032,
/// CON-036), kept apart from the machine tree.
extension _ShellProjects on DesktopHomeState {
  /// Every agent the monitor reports, per saved machine.
  Map<String, List<AgentInfo>> _agentsByMachine() {
    final attention = widget.agentAttention;
    final result = <String, List<AgentInfo>>{};
    for (final host in attention.monitoredHosts) {
      final agents = attention.statusFor(host.id)?.agents;
      if (agents == null || agents.isEmpty) continue;
      (result[baseHostId(host.id)] ??= []).addAll(agents);
    }
    return result;
  }

  /// The project layout (sheprd's sidebar.toml, or the app's), if any.
  ProjectLayoutController? get _projectLayout =>
      widget.projectLayout ?? ProjectLayoutController.instance;

  List<ProjectGroup> _buildProjects() =>
      _projectLayout?.build(
        _tree,
        agentsByMachine: _agentsByMachine(),
        hosts: widget.hostsController.machines,
      ) ??
      ProjectTreeBuilder.build(_tree, agentsByMachine: _agentsByMachine());

  /// The project the focused session belongs to.
  ProjectGroup? _focusedProject() {
    final key = _selectedKey;
    if (key == null) return null;
    for (final project in _projects) {
      if (project.members.any((node) => SidebarKeys.isUnder(key, node.key))) {
        return project;
      }
    }
    return null;
  }

  /// The repo's actions, then the personal ones for this project.
  List<QuickAction> _actionsFor(ProjectGroup project) => [
    ...?_projectFiles.filesFor(project)?.actions,
    for (final action in widget.themeController.quickActions)
      if (action.appliesTo(project.name)) action,
  ];

  /// An agent of [project] to send prompts to: one waiting, else any.
  (AgentInfo, SavedHost)? _agentOf(ProjectGroup project) {
    final attention = widget.agentAttention;
    (AgentInfo, SavedHost)? fallback;
    for (final (machineId, agent) in project.agents) {
      final host = attention.monitoredHosts
          .where((host) => baseHostId(host.id) == machineId)
          .firstOrNull;
      if (host == null) continue;
      if (agent.state.needsAttention) return (agent, host);
      fallback ??= (agent, host);
    }
    return fallback;
  }

  /// Runs [action] for [project], asking first when it says so.
  Future<void> _runQuickAction(ProjectGroup project, QuickAction action) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (action.confirm) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Run ${action.label}?'),
          content: Text(action.command),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: const ValueKey('quick-action-run'),
              autofocus: true,
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Run'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    final location = _projectFiles.locationOf(project);
    final machineId = location?.machineId ?? project.members.first.machineId;
    final machine = widget.hostsController.findById(machineId);
    if (machine == null) return;
    final agent = _agentOf(project);
    try {
      final message = await _quickActions.run(
        action,
        QuickActionContext(
          machine: machine,
          root: _projectFiles.filesFor(project)?.root ?? location?.path,
          agent: agent?.$1,
          agentHost: agent?.$2,
        ),
      );
      if (action.kind == QuickActionKind.shell) _controller.showHome = false;
      messenger?.showSnackBar(SnackBar(content: Text(message)));
    } on Object catch (error) {
      messenger?.showSnackBar(
        SnackBar(content: Text('${action.label}: ${_describe(error)}')),
      );
    }
  }

  static String _describe(Object error) =>
      error is StateError ? error.message : '$error';

  /// "Add action…": the form, then the repo file (after asking) or
  /// Settings.
  Future<void> _addQuickAction(ProjectGroup project) async {
    final files = _projectFiles.filesFor(project);
    final location = _projectFiles.locationOf(project);
    final draft = await showQuickActionForm(
      context,
      projectName: project.name,
      takenIds: _actionsFor(project).map((action) => action.id),
      repoFile: files?.workspaceFileOrDefault,
    );
    if (draft == null || !mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (draft.home == QuickActionHome.personal) {
      await widget.themeController.setQuickActions([
        ...widget.themeController.quickActions,
        draft.action,
      ]);
      messenger?.showSnackBar(
        SnackBar(content: Text('Added ${draft.action.label} to your actions.')),
      );
      return;
    }
    if (files == null || location == null) return;
    final machine =
        widget.hostsController.findById(location.machineId)?.name ??
        location.machineId;
    final path = '${files.root}/${files.workspaceFileOrDefault}';
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Write to the repo?'),
        content: Text(
          'This adds "${draft.action.label}" to $path on $machine. '
          'The file goes to everyone who pulls the repo; the old one is '
          'kept as .bak.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('quick-action-write'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Write'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await _projectFiles.saveActions(project, [
        ...files.actions,
        draft.action,
      ]);
      messenger?.showSnackBar(
        SnackBar(content: Text('Added ${draft.action.label} to $path.')),
      );
    } on Object catch (error) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Could not save: ${_describe(error)}')),
      );
    }
  }

  /// Opens every workspace of [project] (up to six) side by side.
  Future<void> _openProjectLayout(ProjectGroup project) async {
    final members = project.members.take(ShellLayout.maxPanes).toList();
    for (final node in members) {
      await open(node);
      if (!mounted) return;
    }
    final preset = switch (members.length) {
      <= 1 => ShellLayoutPreset.single,
      2 => ShellLayoutPreset.sideBySide,
      3 => ShellLayoutPreset.onePlusTwo,
      4 => ShellLayoutPreset.grid2x2,
      _ => ShellLayoutPreset.grid3x2,
    };
    final views = [
      for (final session in widget.workspace.sessions)
        if (members.any((node) => keyForSession(session) == node.key))
          sessionViewId(session),
    ];
    _controller.replaceLayout(preset.apply(views));
    _controller.showHome = false;
  }

  /// A project's menu: its quick actions, then Add action, open all,
  /// reload.
  Future<void> _showProjectMenu(ProjectGroup project, Offset? position) async {
    if (project.isOther) return;
    _projectFiles.ensure(project);
    final actions = _actionsFor(project);
    final layout = _projectLayout;
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final at = position ?? overlay.size.center(Offset.zero);
    final picked = await showMenu<Object>(
      context: context,
      position: RelativeRect.fromRect(
        at & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        for (final action in actions)
          PopupMenuItem<Object>(
            value: action,
            child: _MenuRow(quickActionIcon(action), action.label),
          ),
        if (actions.isNotEmpty) const PopupMenuDivider(),
        const PopupMenuItem<Object>(
          value: 'add',
          child: _MenuRow(Icons.add_rounded, 'Add action…'),
        ),
        PopupMenuItem<Object>(
          value: 'layout',
          child: _MenuRow(
            Icons.dashboard_outlined,
            'Open all ${project.members.length} side by side',
          ),
        ),
        const PopupMenuItem<Object>(
          value: 'reload',
          child: _MenuRow(Icons.refresh_rounded, 'Reload icon and actions'),
        ),
        if (layout != null) ...[
          const PopupMenuDivider(),
          ...projectGroupMenuItems<Object>(
            project,
            value: (action) => action,
            editable: layout.canEditLayout,
            controller: layout,
          ),
        ],
      ],
    );
    if (!mounted) return;
    switch (picked) {
      case final ProjectGroupAction action when layout != null:
        await runProjectGroupAction(context, layout, project, action);
      case final QuickAction action:
        await _runQuickAction(project, action);
      case 'add':
        await _addQuickAction(project);
      case 'layout':
        await _openProjectLayout(project);
      case 'reload':
        _projectFiles.refresh(project);
    }
  }

  /// The toolbar's buttons for the focused session's project: its first
  /// actions, and a menu with the rest.
  List<Widget> _quickActionButtons() {
    final project = _focusedProject();
    if (project == null) return const [];
    if (!project.isOther) _projectFiles.ensure(project);
    final actions = _actionsFor(project);
    return [
      for (final action in actions.take(3))
        IconButton(
          key: ValueKey('quick-action-${action.id}'),
          tooltip: [
            action.label,
            if (QuickActionKeys.parse(action.keybinding) case final keys?)
              '(${keys.label})',
          ].join(' '),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 34, height: 40),
          icon: Icon(quickActionIcon(action), size: 18),
          onPressed: () => unawaited(_runQuickAction(project, action)),
        ),
      Builder(
        builder: (context) => IconButton(
          key: const ValueKey('quick-actions-menu'),
          tooltip: 'Quick actions for ${project.name}',
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 34, height: 40),
          icon: const Icon(Icons.bolt_rounded, size: 19),
          onPressed: () {
            final box = context.findRenderObject()! as RenderBox;
            unawaited(
              _showProjectMenu(
                project,
                box.localToGlobal(box.size.bottomLeft(Offset.zero)),
              ),
            );
          },
        ),
      ),
    ];
  }

  /// Palette rows: each project, and each project's quick actions.
  List<PaletteEntry> _projectPaletteEntries() => [
    for (final project in _projects) ...[
      PaletteEntry(
        id: 'project:${project.key}',
        title: project.name,
        subtitle: [
          '${project.members.length} workspaces',
          if (project.needsYou > 0) '${project.needsYou} need you',
          if (project.working > 0) '${project.working} working',
        ].join(' · '),
        kind: PaletteKind.project,
        leading: ProjectIcon(
          name: project.name,
          icon: _projectFiles.filesFor(project)?.icon,
          size: 16,
        ),
        urgent: project.needsYou > 0,
        run: () async {
          if (project.members.length == 1) {
            await open(project.members.single);
            return;
          }
          _controller
            ..sidebarCollapsed = false
            ..sidebarTab = ShellSidebarTab.projects
            ..updatePrefs(
              (prefs) =>
                  prefs.setExpanded(ProjectSidebar.expandKey(project), true),
            );
        },
      ),
      for (final action in _actionsFor(project))
        PaletteEntry(
          id: 'quick-action:${project.key}/${action.id}',
          title: '${project.name}: ${action.label}',
          subtitle: action.command,
          kind: PaletteKind.quickAction,
          icon: quickActionIcon(action),
          shortcut: QuickActionKeys.parse(action.keybinding)?.label,
          keywords: [action.label, project.name, 'run'],
          run: () => _runQuickAction(project, action),
        ),
      PaletteEntry(
        id: 'quick-action-add:${project.key}',
        title: '${project.name}: Add action…',
        kind: PaletteKind.quickAction,
        icon: Icons.add_rounded,
        keywords: const ['new', 'quick action', 'command'],
        run: () => _addQuickAction(project),
      ),
    ],
  ];

  /// The focused project's action bound to [event]'s keys, if any.
  (ProjectGroup, QuickAction)? _quickActionForKey(KeyEvent event) {
    if (event is! KeyDownEvent) return null;
    final project = _focusedProject();
    if (project == null) return null;
    final pressed = HardwareKeyboard.instance.logicalKeysPressed;
    for (final action in _actionsFor(project)) {
      final keys = QuickActionKeys.parse(action.keybinding);
      if (keys != null && keys.safe && keys.matches(event, pressed: pressed)) {
        return (project, action);
      }
    }
    return null;
  }

  Widget _projectSidebar() {
    final projects = _projects;
    for (final project in projects) {
      if (!project.isOther) _projectFiles.ensure(project);
    }
    final layout = _projectLayout;
    if (layout != null) unawaited(layout.refresh());
    final usage = UsageScope.maybeOf(context);
    return ListenableBuilder(
      listenable: Listenable.merge([
        _projectFiles,
        widget.themeController,
        ?usage,
      ]),
      builder: (context, _) => ProjectSidebar(
        layout: layout,
        tokensToday: layout == null || usage == null
            ? const {}
            : layout.tokensToday(projects, usage.summary),
        onEntryMenu: layout == null
            ? null
            : (entry, project, position, row) => unawaited(
                showNodeMenu(row, position, entry: entry, project: project),
              ),
        onNeedsYou: () {
          for (final project in projects) {
            for (final entry in project.entries) {
              if (entry.hidden) continue;
              for (final node in [...entry.agentRows, entry.node]) {
                if (node.dot == SidebarDot.needsYou) {
                  unawaited(open(node));
                  return;
                }
              }
            }
          }
        },
        key: const ValueKey('shell-project-sidebar'),
        controller: _controller,
        projects: projects,
        machineNames: {for (final node in _tree) node.machineId: node.label},
        iconFor: (project) => _projectFiles.filesFor(project)?.icon,
        selectedKey: _selectedKey,
        onOpen: (node) => unawaited(open(node)),
        onContextMenu: (node, position) =>
            unawaited(showNodeMenu(node, position)),
        onProjectMenu: (project, position) =>
            unawaited(_showProjectMenu(project, position)),
        header: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _sidebarHeader(),
            SidebarTabs(controller: _controller),
          ],
        ),
        footer: _sidebarFooter(),
      ),
    );
  }
}
