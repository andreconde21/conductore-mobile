import 'package:conduit/core/presentation/multiplexer_icon.dart';
import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/features/agent_attention/presentation/widgets/agent_inbox_widgets.dart';
import 'package:conduit/features/command_palette/domain/palette_entry.dart';
import 'package:conduit/features/desktop_shell/domain/layout_presets.dart';
import 'package:conduit/features/desktop_shell/presentation/desktop_shell_controller.dart';
import 'package:conduit/features/session_navigation/presentation/quick_switcher_model.dart';
import 'package:conduit/features/settings/presentation/settings_catalog.dart';
import 'package:conduit/features/terminal/presentation/desktop_shortcuts.dart';
import 'package:conduit/features/usage/domain/usage_range.dart';
import 'package:conduit/features/voice/domain/voice_preferences.dart';
import 'package:flutter/material.dart';

/// What the desktop shell's palette can do, handed in by the shell.
class ShellPaletteActions {
  const ShellPaletteActions({
    required this.newSession,
    required this.openSettings,
    required this.addMachine,
    required this.showShortcuts,
    required this.showHome,
    required this.openItem,
    required this.applyPreset,
    required this.restoreLayout,
    required this.saveLayout,
    required this.openUsage,
    required this.setPalette,
    required this.setVoice,
    required this.nextUnread,
    this.lock,
    this.closeFocused,
    this.extra = const [],
  });

  final Future<void> Function() newSession;
  final Future<void> Function(SettingsSection? section) openSettings;
  final Future<void> Function() addMachine;
  final Future<void> Function() showShortcuts;
  final VoidCallback showHome;

  /// Opens a session, agent, workspace or recent target.
  final Future<void> Function(SwitcherItem item) openItem;
  final void Function(ShellLayoutPreset preset) applyPreset;
  final Future<void> Function(SavedShellLayout saved) restoreLayout;
  final Future<void> Function() saveLayout;
  final void Function(UsageRangePreset? preset) openUsage;
  final Future<void> Function(AppPalette palette) setPalette;
  final Future<void> Function(VoicePreferences voice) setVoice;
  final Future<void> Function()? lock;
  final VoidCallback nextUnread;

  /// Closes the focused tab, when one is open.
  final Future<void> Function()? closeFocused;

  /// More rows (projects and their quick actions).
  final List<PaletteEntry> extra;
}

/// Every row of the desktop shell's command palette: agents waiting on the
/// user, open sessions, other workspaces and recents (the quick switcher's
/// rows), then projects, layouts, commands, settings pages, themes,
/// toggles and usage ranges.
List<PaletteEntry> buildShellPaletteEntries({
  required DesktopShellController controller,
  required List<SwitcherItem> places,
  required ShellPaletteActions actions,
  required AppPalette selectedPalette,
  required VoicePreferences voice,
  bool hasUsage = false,
  bool hasViews = false,
}) {
  Future<void> run(VoidCallback callback) async => callback();
  final entries = <PaletteEntry>[
    for (final item in places) _placeEntry(item, actions),
    ...actions.extra,
  ];

  // Layouts.
  final current = ShellLayoutPreset.of(controller.layout.value);
  for (final preset in ShellLayoutPreset.values) {
    entries.add(
      PaletteEntry(
        id: 'layout:${preset.name}',
        title: 'Layout: ${preset.label}',
        subtitle: preset == current ? 'current' : '',
        kind: PaletteKind.layout,
        icon: Icons.dashboard_outlined,
        keywords: ['split', 'panes', '${preset.paneCount} panes', 'grid'],
        run: () => run(() => actions.applyPreset(preset)),
      ),
    );
  }
  for (final saved in controller.savedLayouts) {
    entries.add(
      PaletteEntry(
        id: 'saved-layout:${saved.id}',
        title: 'Layout: ${saved.name}',
        subtitle: '${saved.layout.panes.length} panes, saved',
        kind: PaletteKind.layout,
        icon: Icons.bookmark_outline_rounded,
        keywords: const ['saved', 'restore', 'workspace'],
        run: () => actions.restoreLayout(saved),
      ),
    );
  }
  entries.add(
    PaletteEntry(
      id: 'command:save-layout',
      title: 'Save this layout…',
      kind: PaletteKind.layout,
      icon: Icons.bookmark_add_outlined,
      keywords: const ['name', 'remember', 'layout'],
      run: actions.saveLayout,
    ),
  );

  // App commands.
  entries.addAll([
    PaletteEntry(
      id: 'command:new-session',
      title: 'New session',
      kind: PaletteKind.command,
      icon: Icons.add_rounded,
      shortcut: desktopShortcutKeys(DesktopAction.newSession),
      keywords: const ['connect', 'terminal', 'open'],
      run: actions.newSession,
    ),
    if (actions.closeFocused case final close? when hasViews)
      PaletteEntry(
        id: 'command:close-tab',
        title: 'Close the focused tab',
        kind: PaletteKind.command,
        icon: Icons.close_rounded,
        shortcut: desktopShortcutKeys(DesktopAction.closeSession),
        keywords: const ['session', 'detach'],
        run: close,
      ),
    PaletteEntry(
      id: 'command:home',
      title: 'Go to the dashboard',
      kind: PaletteKind.command,
      icon: Icons.space_dashboard_outlined,
      keywords: const ['home', 'overview'],
      run: () => run(actions.showHome),
    ),
    PaletteEntry(
      id: 'command:add-machine',
      title: 'Add machine…',
      kind: PaletteKind.command,
      icon: Icons.add_to_queue_rounded,
      keywords: const ['host', 'ssh', 'server', 'new'],
      run: actions.addMachine,
    ),
    PaletteEntry(
      id: 'command:toggle-sidebar',
      title: controller.sidebarCollapsed
          ? 'Show the sidebar'
          : 'Hide the sidebar',
      kind: PaletteKind.command,
      icon: Icons.view_sidebar_outlined,
      shortcut: desktopShortcutKeys(DesktopAction.toggleSidebar),
      keywords: const ['collapse', 'expand', 'toggle'],
      run: () => run(controller.toggleSidebar),
    ),
    PaletteEntry(
      id: 'command:sidebar-projects',
      title: controller.sidebarTab == ShellSidebarTab.projects
          ? 'Sidebar: group by machine'
          : 'Sidebar: group by project',
      kind: PaletteKind.command,
      icon: controller.sidebarTab == ShellSidebarTab.projects
          ? Icons.dns_outlined
          : Icons.folder_copy_outlined,
      keywords: const ['projects', 'repos', 'machines', 'tab'],
      run: () => run(() {
        controller.sidebarCollapsed = false;
        controller.sidebarTab =
            controller.sidebarTab == ShellSidebarTab.projects
            ? ShellSidebarTab.machines
            : ShellSidebarTab.projects;
      }),
    ),
    PaletteEntry(
      id: 'command:agents-panel',
      title: controller.rightPanel == ShellRightPanel.agents
          ? 'Hide the agents panel'
          : 'Show the agents panel',
      kind: PaletteKind.command,
      icon: Icons.monitor_heart_outlined,
      keywords: const ['inbox', 'approvals', 'right panel'],
      run: () => run(() => controller.toggleRightPanel(ShellRightPanel.agents)),
    ),
    PaletteEntry(
      id: 'command:preview-panel',
      title: controller.rightPanel == ShellRightPanel.preview
          ? 'Hide the live preview panel'
          : 'Show the live preview panel',
      kind: PaletteKind.command,
      icon: Icons.public_rounded,
      keywords: const ['web', 'browser', 'port', 'right panel'],
      run: () =>
          run(() => controller.toggleRightPanel(ShellRightPanel.preview)),
    ),
    PaletteEntry(
      id: 'command:next-unread',
      title: 'Next unread',
      kind: PaletteKind.command,
      icon: Icons.mark_email_unread_outlined,
      shortcut: desktopShortcutKeys(DesktopAction.nextUnread),
      keywords: const ['new output', 'finished', 'jump'],
      enabled: controller.unread.unreadKeys.isNotEmpty,
      run: () => run(actions.nextUnread),
    ),
    PaletteEntry(
      id: 'command:shortcuts',
      title: 'Keyboard shortcuts',
      kind: PaletteKind.command,
      icon: Icons.keyboard_outlined,
      shortcut: desktopShortcutKeys(DesktopAction.showShortcuts),
      keywords: const ['keys', 'help', 'bindings'],
      run: actions.showShortcuts,
    ),
    if (actions.lock case final lock?)
      PaletteEntry(
        id: 'command:lock',
        title: 'Lock the app',
        kind: PaletteKind.command,
        icon: Icons.lock_outline_rounded,
        keywords: const ['security', 'away'],
        run: lock,
      ),
  ]);

  // Toggles.
  entries.addAll([
    PaletteEntry(
      id: 'toggle:read-aloud',
      title: voice.readAloudByDefault
          ? 'Turn off reading replies aloud'
          : 'Turn on reading replies aloud',
      subtitle: 'Chat View default',
      kind: PaletteKind.command,
      icon: voice.readAloudByDefault
          ? Icons.volume_off_outlined
          : Icons.volume_up_outlined,
      keywords: const ['speech', 'tts', 'voice', 'toggle'],
      run: () => actions.setVoice(
        voice.copyWith(readAloudByDefault: !voice.readAloudByDefault),
      ),
    ),
    for (final activity in ToolActivity.values)
      if (activity != voice.toolActivity)
        PaletteEntry(
          id: 'toggle:tool-activity:${activity.name}',
          title: 'Tool activity: ${activity.label}',
          subtitle: 'Chat View, now ${voice.toolActivity.label.toLowerCase()}',
          kind: PaletteKind.command,
          icon: Icons.construction_outlined,
          keywords: const ['tools', 'calls', 'chat', 'toggle'],
          run: () => actions.setVoice(voice.copyWith(toolActivity: activity)),
        ),
  ]);

  // Usage.
  if (hasUsage) {
    for (final preset in UsageRangePreset.values) {
      if (preset == UsageRangePreset.custom) continue;
      entries.add(
        PaletteEntry(
          id: 'usage:${preset.name}',
          title: 'Usage: ${preset.label}',
          kind: PaletteKind.command,
          icon: Icons.insights_rounded,
          keywords: const ['tokens', 'cost', 'limits', 'explorer', 'stats'],
          run: () => run(() => actions.openUsage(preset)),
        ),
      );
    }
  }

  // Settings pages, then single settings.
  entries.add(
    PaletteEntry(
      id: 'settings:open',
      title: 'Settings',
      kind: PaletteKind.settings,
      icon: Icons.settings_outlined,
      shortcut: desktopShortcutKeys(DesktopAction.openSettings),
      keywords: const ['preferences', 'options'],
      run: () => actions.openSettings(null),
    ),
  );
  for (final section in SettingsSection.values) {
    entries.add(
      PaletteEntry(
        id: 'settings:${section.name}',
        title: 'Settings: ${section.title}',
        subtitle: section.subtitle,
        kind: PaletteKind.settings,
        icon: section.icon,
        run: () => actions.openSettings(section),
      ),
    );
  }
  final seenSettings = <String>{};
  for (final setting in settingsCatalog) {
    if (!seenSettings.add('${setting.section.name}/${setting.title}')) {
      continue;
    }
    entries.add(
      PaletteEntry(
        id: 'setting:${setting.section.name}/${setting.title}',
        title: setting.title,
        subtitle: 'Settings › ${setting.section.title}',
        kind: PaletteKind.settings,
        icon: Icons.tune_rounded,
        keywords: setting.keywords,
        run: () => actions.openSettings(setting.section),
      ),
    );
  }

  // Themes.
  for (final palette in AppPalette.values) {
    entries.add(
      PaletteEntry(
        id: 'theme:${palette.id}',
        title: 'Theme: ${palette.label}',
        subtitle: palette == selectedPalette ? 'current' : '',
        kind: PaletteKind.command,
        icon: Icons.palette_outlined,
        keywords: const ['colours', 'colors', 'appearance', 'omarchy'],
        run: () => actions.setPalette(palette),
      ),
    );
  }
  return entries;
}

PaletteEntry _placeEntry(SwitcherItem item, ShellPaletteActions actions) {
  Future<void> open() => actions.openItem(item);
  switch (item) {
    case SwitcherAgentItem(:final agent, :final machineName, :final asks):
      return PaletteEntry(
        id: 'agent:${item.key}',
        title: item.title,
        subtitle: '$machineName · $asks',
        kind: PaletteKind.agent,
        leading: AgentKindBadge(kind: agent.kind, size: 17),
        keywords: [agent.name, ...item.searchTerms],
        urgent: true,
        run: open,
      );
    case SwitcherSessionItem(:final info, :final machineName):
      return PaletteEntry(
        id: 'session:${item.key}',
        title: item.title,
        subtitle: [
          if (info.targetLabel.isNotEmpty && info.targetLabel != item.title)
            info.targetLabel,
          machineName,
        ].join(' · '),
        kind: PaletteKind.session,
        leading: info.multiplexer == null
            ? const Icon(Icons.terminal_rounded, size: 16)
            : MultiplexerIcon(info.multiplexer!, size: 15, semanticLabel: ''),
        keywords: item.searchTerms,
        run: open,
      );
    case SwitcherWorkspaceItem(:final kind, :final machineName, :final details):
      return PaletteEntry(
        id: 'workspace:${item.key}',
        title: item.title,
        subtitle: [machineName, if (details.isNotEmpty) details].join(' · '),
        kind: PaletteKind.workspace,
        leading: MultiplexerIcon(kind, size: 15, semanticLabel: ''),
        keywords: item.searchTerms,
        run: open,
      );
    case SwitcherRecentItem(:final multiplexer, :final machineName):
      return PaletteEntry(
        id: 'recent:${item.key}',
        title: item.title,
        subtitle: machineName,
        kind: PaletteKind.recent,
        leading: multiplexer == null
            ? const Icon(Icons.history_rounded, size: 16)
            : MultiplexerIcon(multiplexer, size: 15, semanticLabel: ''),
        keywords: item.searchTerms,
        run: open,
      );
  }
}
