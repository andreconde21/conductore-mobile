import 'dart:async';

import 'package:conduit/core/platform_features.dart';
import 'package:conduit/core/presentation/adaptive_page.dart';
import 'package:conduit/core/presentation/theme_sheet.dart';
import 'package:conduit/core/telemetry/telemetry.dart';
import 'package:conduit/core/theme/terminal_appearance.dart';
import 'package:conduit/core/theme/theme_controller.dart';
import 'package:conduit/features/agent_attention/domain/agent_inbox.dart';
import 'package:conduit/features/agent_attention/presentation/approval_rules_page.dart';
import 'package:conduit/features/agent_attention/presentation/widgets/agent_usage_tab.dart';
import 'package:conduit/features/agents_digest/presentation/digest_settings.dart';
import 'package:conduit/features/app_lock/domain/app_lock_preferences.dart';
import 'package:conduit/features/app_lock/presentation/app_lock_controller.dart';
import 'package:conduit/features/backup/presentation/backup_sheet.dart';
import 'package:conduit/features/companion_setup/presentation/companion_setup_controller.dart';
import 'package:conduit/features/companion_setup/presentation/companion_setup_page.dart';
import 'package:conduit/features/home_widget/data/platform_agent_status_widget_channel.dart';
import 'package:conduit/features/home_widget/presentation/quick_settings_tile_controls.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/hosts/presentation/hosts_controller.dart';
import 'package:conduit/features/quick_actions/presentation/personal_quick_actions_card.dart';
import 'package:conduit/features/session_navigation/presentation/session_view_widgets.dart';
import 'package:conduit/features/settings/presentation/privacy_settings.dart';
import 'package:conduit/features/settings/presentation/settings_catalog.dart';
import 'package:conduit/features/settings/presentation/settings_services.dart';
import 'package:conduit/features/snippets/presentation/snippet_editor.dart';
import 'package:conduit/features/sync/domain/sync_category.dart';
import 'package:conduit/features/sync/presentation/sync_scope.dart';
import 'package:conduit/features/terminal/presentation/gestures/terminal_gestures_settings.dart';
import 'package:conduit/features/terminal/presentation/trusted_keys_page.dart';
import 'package:conduit/features/terminal/presentation/widgets/desktop_shortcuts_sheet.dart';
import 'package:conduit/features/terminal/presentation/widgets/pill_configurator_sheet.dart';
import 'package:conduit/features/this_computer/domain/local_shell_launch.dart';
import 'package:conduit/features/usage/presentation/usage_widgets.dart';
import 'package:conduit/features/voice/domain/voice_preferences.dart';
import 'package:conduit/features/voice/presentation/speech_settings_controls.dart';
import 'package:conduit/features/voice_guide/presentation/guide_settings.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// The settings of one [section], as a scrolling column of cards.
class SettingsSectionBody extends StatelessWidget {
  const SettingsSectionBody({
    required this.section,
    required this.services,
    this.padding = const EdgeInsets.fromLTRB(18, 4, 18, 28),
    super.key,
  });

  final SettingsSection section;
  final SettingsServices services;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: services.theme,
      builder: (context, _) => ListView(
        key: ValueKey('settings-body-${section.name}'),
        padding: padding,
        children: _children(context),
      ),
    );
  }

  List<Widget> _children(BuildContext context) {
    final theme = services.theme;
    return switch (section) {
      SettingsSection.appearance => _appearance(theme),
      SettingsSection.terminal => _terminal(theme),
      SettingsSection.input => _input(context, theme),
      SettingsSection.chatVoice => _chatVoice(theme),
      SettingsSection.agents => _agents(context),
      SettingsSection.syncBackup => _syncBackup(context),
      SettingsSection.security => _security(context),
      SettingsSection.privacy => [
        PrivacySettingsControls(telemetry: Telemetry.instance),
      ],
      SettingsSection.about => const [AboutControls()],
    };
  }

  List<Widget> _appearance(ThemeController theme) => [
    if (theme.omarchySync case final sync?) ...[
      SettingsCard(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: OmarchySyncControls(sync: sync),
        ),
      ),
      _gap,
    ],
    const SettingsHeading('Themes'),
    ThemeGrid(controller: theme),
    _gap,
    const SettingsHeading('Terminal font'),
    TerminalFontControls(controller: theme),
    _gap,
    // The proot local shell is Android's; desktops have This computer.
    if (PlatformFeatures.prootLocalShell)
      SettingsSwitchCard(
        icon: Icons.terminal_rounded,
        title: 'Show local shell',
        subtitle: 'Show the local terminal shortcut on the home screen.',
        value: theme.showLocalShell,
        onChanged: theme.setShowLocalShell,
      ),
  ];

  List<Widget> _terminal(ThemeController theme) => [
    if (services.hostsController case final hosts?
        when showsWindowsShellSetting(hosts)) ...[
      ListenableBuilder(
        listenable: hosts,
        builder: (context, _) => SettingsSegmentCard<WindowsShellKind>(
          key: const ValueKey('settings-windows-shell'),
          icon: Icons.computer_rounded,
          title: 'This computer: shell',
          description:
              'What a local session on this PC opens. Kept on this device, '
              'never synced.',
          values: WindowsShellKind.values,
          label: (value) => value.label,
          selected: hosts.windowsShell,
          onChanged: hosts.setWindowsShell,
        ),
      ),
      _gap,
    ],
    SettingsSegmentCard<TerminalEnterSequence>(
      icon: Icons.keyboard_return_rounded,
      title: 'Enter sends',
      description: theme.terminalEnterSequence.description,
      values: TerminalEnterSequence.values,
      label: (value) => value.label,
      selected: theme.terminalEnterSequence,
      onChanged: theme.setTerminalEnterSequence,
    ),
    _gap,
    SettingsSwitchCard(
      icon: Icons.mouse_rounded,
      title: 'Send mouse taps',
      subtitle:
          'Forward terminal taps as mouse clicks when apps enable mouse '
          'tracking.',
      value: theme.terminalMouseInput,
      onChanged: theme.setTerminalMouseInput,
    ),
    _gap,
    SettingsSwitchCard(
      icon: Icons.content_paste_go_rounded,
      title: 'Remote clipboard',
      subtitle:
          'Let programs on the host copy to this device (OSC 52: vim, '
          'tmux with set-clipboard on). The host can never read it.',
      value: theme.remoteClipboardEnabled,
      onChanged: theme.setRemoteClipboardEnabled,
    ),
    _gap,
    SettingsSwitchCard(
      icon: Icons.smart_button_rounded,
      title: 'Menu buttons',
      subtitle:
          'Answer numbered menus and y/n prompts (Claude Code, installers) '
          'with buttons above the keyboard bar.',
      value: theme.menuButtonsEnabled,
      onChanged: theme.setMenuButtonsEnabled,
    ),
    _gap,
    SettingsSwitchCard(
      switchKey: const ValueKey('paste-images-as-files'),
      icon: Icons.image_outlined,
      title: 'Paste images as uploaded files',
      subtitle:
          "Pasting an image uploads it to the machine's share inbox and "
          'pastes its path, which Claude Code reads as an image. Off: '
          'paste text only.',
      value: theme.pasteImagesAsFiles,
      onChanged: theme.setPasteImagesAsFiles,
    ),
    _gap,
    SettingsSwitchCard(
      switchKey: const ValueKey('restore-sessions-switch'),
      icon: Icons.restore_page_rounded,
      title: 'Restore sessions on launch',
      subtitle:
          'Bring back the open sessions after the app restarts. tmux and '
          'Herdr sessions reattach; plain shells start fresh.',
      value: theme.restoreSessionsOnLaunch,
      onChanged: theme.setRestoreSessionsOnLaunch,
    ),
    _gap,
    // Brings its own bottom gap (and nothing without a SessionViewScope).
    const SessionViewSettingsTile(),
    SettingsSegmentCard<MultiplexerTabsMode>(
      key: const ValueKey('multiplexer-tabs-setting'),
      icon: Icons.tab_rounded,
      title: 'Multiplexer tabs on phone',
      description:
          'Herdr tabs and tmux windows. Compact names the current one in the '
          'session tab (tap it for the list) and costs no screen space; '
          'Strip adds a row, for tablets. A computer always shows the strip.',
      values: MultiplexerTabsMode.values,
      label: (value) => value.label,
      selected: theme.multiplexerTabs,
      onChanged: theme.setMultiplexerTabs,
    ),
    _gap,
    SettingsCard(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: SnippetListEditor(
          title: 'Global snippets',
          caption: 'Shown from the Snip key-row menu on every machine.',
          snippets: theme.terminalSnippets,
          onChanged: theme.setTerminalSnippets,
        ),
      ),
    ),
    _gap,
    SettingsCard(child: PersonalQuickActionsCard(theme: theme)),
  ];

  List<Widget> _input(BuildContext context, ThemeController theme) => [
    SettingsSegmentCard<TerminalToolbarStyle>(
      icon: Icons.space_bar_rounded,
      title: 'Toolbar style',
      description: theme.terminalToolbarStyle.description,
      values: TerminalToolbarStyle.values,
      label: (value) => value.label,
      selected: theme.terminalToolbarStyle,
      onChanged: theme.setTerminalToolbarStyle,
    ),
    _gap,
    SettingsCard(
      child: ListTile(
        key: const ValueKey('settings-pill-buttons'),
        leading: const Icon(Icons.view_week_outlined),
        title: const Text('Pill buttons'),
        subtitle: Text(
          '${theme.terminalPillItems.length} buttons on the floating pill. '
          'Long-press the pill in a session to change them there too.',
        ),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: () => _configurePill(context, theme),
      ),
    ),
    _gap,
    KeyRowsTile(controller: theme),
    _gap,
    if (PlatformFeatures.isDesktop) ...[
      SettingsCard(
        child: ListTile(
          key: const ValueKey('settings-keyboard-shortcuts'),
          leading: const Icon(Icons.keyboard_outlined),
          title: const Text('Keyboard shortcuts'),
          subtitle: const Text(
            'Every desktop shortcut: tabs, panes, zoom, the quick switcher.',
          ),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => showDesktopShortcutsSheet(context),
        ),
      ),
      _gap,
    ],
    const SettingsHeading('Gestures'),
    TerminalGesturesSettings(controller: theme),
  ];

  static Future<void> _configurePill(
    BuildContext context,
    ThemeController theme,
  ) async {
    final items = await showPillConfigurator(
      context: context,
      items: theme.terminalPillItems,
      customKeys: [
        for (final row in theme.terminalKeyboardRows)
          for (final item in row.items)
            if (item.kind != TerminalKeyboardItemKind.builtIn) item,
      ],
    );
    if (items != null) await theme.setTerminalPillItems(items);
  }

  List<Widget> _chatVoice(ThemeController theme) => [
    SettingsSwitchCard(
      switchKey: const ValueKey('compose-submit-enter'),
      icon: Icons.keyboard_return_rounded,
      title: 'Press Enter after inserting',
      subtitle:
          'The prompt composer inserts your text and presses Enter, so the '
          'agent gets it right away. Off: the text is only inserted.',
      value: theme.composeSubmitEnter,
      onChanged: theme.setComposeSubmitEnter,
    ),
    _gap,
    SettingsSegmentCard<ToolActivity>(
      key: const ValueKey('chat-tool-activity'),
      icon: Icons.handyman_outlined,
      title: 'Tool activity',
      description: switch (theme.voice.toolActivity) {
        ToolActivity.all => 'Chat mode shows every tool call as its own card.',
        ToolActivity.collapsed =>
          'Tool calls in a row fold into one line, like "Ran 4 commands, '
              'edited 2 files". Tap it to see them.',
        ToolActivity.hidden =>
          'Tool calls are not shown. Approvals, questions and errors always '
              'are.',
      },
      values: ToolActivity.values,
      label: (mode) => mode.label,
      selected: theme.voice.toolActivity,
      onChanged: (mode) =>
          theme.setVoice(theme.voice.copyWith(toolActivity: mode)),
    ),
    _gap,
    SettingsSegmentCard<ReviewOpens>(
      key: const ValueKey('chat-review-opens'),
      icon: Icons.rate_review_outlined,
      title: 'Review changes',
      description: switch (theme.voice.reviewOpens) {
        ReviewOpens.onDemand =>
          'Review opens from its button in Chat View, the Agents dashboard '
              'and the inbox, or when you tell the voice guide "review".',
        ReviewOpens.afterEachTurn =>
          'When a turn ends in Chat View, Review opens with a card per '
              'changed file: accept, reject, comment, or undo the turn.',
      },
      values: ReviewOpens.values,
      label: (mode) => mode.label,
      selected: theme.voice.reviewOpens,
      onChanged: (mode) =>
          theme.setVoice(theme.voice.copyWith(reviewOpens: mode)),
    ),
    _gap,
    if (PlatformFeatures.dictation || PlatformFeatures.textToSpeech) ...[
      const SettingsHeading('Where to find voice'),
      const SettingsNote(
        'Dictate: tap the mic next to any chat field (the terminal chat '
        'line from the pill\'s Chat button, the prompt composer, Chat '
        'View). Add a Dictate button to the pill (long-press the pill), '
        'or swipe up on the pill and pick Dictate.\n'
        'Talk: the speaking-head button in Chat View\'s composer runs a '
        'hands-free conversation with Claude. Long-press it for the voice '
        'guide, which talks to all your agents (also the headset-mic button at '
        'the top of home and the Voice guide quick-settings tile).\n'
        'A crossed-out mic means this phone has no speech recognizer yet; '
        'tap it to see how to get one.',
      ),
      _gap,
      const SettingsHeading('Dictation and read aloud'),
      SpeechSettingsControls(controller: theme),
      if (PlatformFeatures.dictation && PlatformFeatures.textToSpeech) ...[
        _gap,
        const SettingsHeading('Voice guide'),
        GuideSettingsControls(theme: theme, hosts: services.hostsController),
      ],
    ] else
      const SettingsNote(
        'Dictation, read aloud and Talk use the phone\'s speech services, '
        'so they are not available on this device.',
      ),
  ];

  List<Widget> _agents(BuildContext context) {
    final hosts = services.hostsController;
    final attention = services.agentAttention;
    return [
      if (hosts != null)
        ListenableBuilder(
          listenable: hosts,
          builder: (context, _) {
            final machines = [
              for (final host in hosts.sortedHosts)
                if (!host.isLocal) host,
            ];
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SettingsHeading('Agent hooks'),
                const SettingsNote(
                  'The Conductore companion reports Claude Code sessions, '
                  'approvals and usage from each machine. Set it up per '
                  'machine, and pick how loudly each one notifies.',
                ),
                const SizedBox(height: 10),
                if (machines.isEmpty)
                  const SettingsNote('Add a machine to set up agent hooks.'),
                for (final host in machines) ...[
                  _AgentMachineCard(
                    host: host,
                    onNotifyLevel: (level) =>
                        hosts.upsert(host.copyWith(agentNotifyLevel: level)),
                  ),
                  const SizedBox(height: 10),
                ],
                if (attention != null) ...[
                  const SettingsHeading('Approval rules'),
                  const SettingsNote(
                    'Rules and time-boxed trust the companion answers by '
                    'itself, per machine. High-risk requests always ask.',
                  ),
                  const SizedBox(height: 6),
                  if (machines.isNotEmpty)
                    SettingsCard(
                      child: Column(
                        children: [
                          for (final host in machines)
                            ListTile(
                              key: ValueKey(
                                'settings-approval-rules-${host.id}',
                              ),
                              leading: const Icon(Icons.rule_rounded),
                              title: Text(
                                host.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: const Icon(Icons.chevron_right_rounded),
                              onTap: () => unawaited(
                                showApprovalRules(
                                  context,
                                  controller: attention,
                                  host: host,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 10),
                ],
                const SettingsHeading('Notifications'),
                SettingsNote(
                  [
                    for (final level in AgentNotifyLevel.values)
                      '${level.label}: ${level.description}',
                  ].join('\n'),
                ),
              ],
            );
          },
        ),
      if (services.digest case final digest?) ...[
        _gap,
        const SettingsHeading('Dashboard'),
        const SettingsNote(
          'The Agents dashboard (home bar) shows what every agent did '
          'since you last looked: files, tests, failures, waiting time, '
          'agents that look stuck, and a short summary.',
        ),
        const SizedBox(height: 6),
        DigestSettingsCards(controller: digest),
      ],
      if (PlatformFeatures.agentNotifications)
        if (UsageScope.maybeOf(context) case final usage?) ...[
          _gap,
          ListenableBuilder(
            listenable: usage,
            builder: (context, _) => SettingsSwitchCard(
              key: const ValueKey('settings-usage-alert'),
              icon: Icons.notifications_active_outlined,
              title: 'Alert near the 5-hour limit',
              subtitle:
                  'Notify when 80% of the Claude 5-hour window is used, once '
                  'per window, with the time it resets. This device only.',
              value: usage.preferences.alertEnabled,
              onChanged: usage.setAlertEnabled,
            ),
          ),
        ],
      if (attention != null) ...[
        _gap,
        const SettingsHeading('Usage'),
        ListenableBuilder(
          listenable: attention,
          builder: (context, _) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: buildAgentUsageChildren(context, <AgentInboxHostInput>[
              for (final host in attention.monitoredHosts)
                (
                  hostId: host.id,
                  hostName: host.name,
                  agents: attention.statusFor(host.id)?.agents ?? const [],
                ),
            ]),
          ),
        ),
      ],
      if (PlatformFeatures.homeWidget) ...[
        _gap,
        QuickSettingsTileControls(
          channel: PlatformAgentStatusWidgetChannel.instance,
        ),
      ],
    ];
  }

  List<Widget> _syncBackup(BuildContext context) {
    final backup = services.backupService;
    return [
      if (services.hostsController case final hosts?
          when showsSelfMachineSetting(hosts))
        ListenableBuilder(
          listenable: hosts,
          builder: (context, _) => switch (hosts.selfMachine) {
            final self? => Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: SelfMachineCard(
                name: self.name,
                showSeparately: hosts.showSelfSeparately,
                onChanged: hosts.setShowSelfSeparately,
              ),
            ),
            null => const SizedBox.shrink(),
          },
        ),
      if (services.hasSync) ...[
        SettingsCard(
          child: ListTile(
            key: const ValueKey('settings-device-sync'),
            leading: const Icon(Icons.devices_rounded),
            title: const Text('Device sync'),
            subtitle: const Text(
              'Keep machines and settings the same on every device, end-to-'
              'end encrypted through one of your machines. Devices and '
              'pairing live here.',
            ),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => showSyncPage(context),
          ),
        ),
        _gap,
      ],
      const SettingsHeading('What syncs'),
      SettingsCard(
        child: Column(
          children: [
            for (final category in SyncCategory.values)
              ListTile(
                dense: true,
                title: Text(category.label),
                subtitle: Text(category.description),
              ),
          ],
        ),
      ),
      if (backup != null) ...[
        _gap,
        const SettingsHeading('Backup file'),
        const SettingsNote(backupCoverage),
        const SizedBox(height: 10),
        BackupActions(backupService: backup),
      ],
    ];
  }

  List<Widget> _security(BuildContext context) {
    final verifier = services.hostKeyVerifier;
    final lockNow = services.onLockNow;
    return [
      SettingsCard(
        child: ListTile(
          leading: const Icon(Icons.fingerprint_rounded),
          title: const Text('App lock'),
          subtitle: Text(
            PlatformFeatures.appLock
                ? 'On. Conductore asks for your fingerprint, face or device '
                      'PIN when it opens, and closes sessions while locked.'
                : 'Not available on this platform.',
          ),
        ),
      ),
      if (services.appLock case final appLock?) ...[
        _gap,
        SettingsCard(child: _RelockDelayTile(controller: appLock)),
      ],
      if (lockNow != null) ...[
        _gap,
        SettingsCard(
          child: ListTile(
            key: const ValueKey('settings-lock-now'),
            leading: const Icon(Icons.lock_outline_rounded),
            title: const Text('Lock now'),
            subtitle: const Text('Closes every session until you unlock.'),
            onTap: () async {
              Navigator.of(context).popUntil((route) => route.isFirst);
              await lockNow();
            },
          ),
        ),
      ],
      if (verifier != null) ...[
        _gap,
        SettingsCard(
          child: ListTile(
            key: const ValueKey('settings-trusted-keys'),
            leading: const Icon(Icons.key_rounded),
            title: const Text('Trusted host keys'),
            subtitle: const Text('Servers Conductore has connected to before.'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => pushAdaptivePage<void>(
              context,
              desktopMaxWidth: 760,
              builder: (_) => TrustedKeysPage(
                verifier: verifier,
                themeController: services.theme,
              ),
            ),
          ),
        ),
      ],
    ];
  }

  static const _gap = SizedBox(height: 14);
}

/// Whether Settings › Terminal offers the Windows shell of "This
/// computer" (a Windows desktop with its local machine entry).
bool showsWindowsShellSetting(HostsController hosts) =>
    defaultTargetPlatform == TargetPlatform.windows &&
    hosts.thisComputer != null;

/// Whether Settings › Sync & backup shows how "This computer" treats the
/// synced machine that is this device: a desktop that found one.
bool showsSelfMachineSetting(HostsController hosts) =>
    hosts.thisComputer != null && hosts.selfMachine != null;

/// "This computer" on the user's other devices: the synced machine that is
/// this device ([name]) is folded into This computer here unless
/// [showSeparately] (kept on this device, never synced).
class SelfMachineCard extends StatelessWidget {
  const SelfMachineCard({
    required this.name,
    required this.showSeparately,
    required this.onChanged,
    super.key,
  });

  static const title = 'This computer on your other devices';

  final String name;
  final bool showSeparately;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SettingsHeading(title),
        SettingsSwitchCard(
          key: const ValueKey('settings-self-machine'),
          switchKey: const ValueKey('settings-self-machine-switch'),
          icon: Icons.computer_rounded,
          title: 'Show it separately here too',
          subtitle:
              'Also shown as $name on your other devices. Here it opens as '
              'This computer; turn this on to also list $name and reach '
              'this computer over SSH. Kept on this device, never synced.',
          value: showSeparately,
          onChanged: onChanged,
        ),
      ],
    );
  }
}

/// A heading over a group of settings (plain case, unlike the uppercase
/// section labels elsewhere).
class SettingsHeading extends StatelessWidget {
  const SettingsHeading(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 2),
      child: Text(
        text,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

/// Muted explanatory text under a heading.
class SettingsNote extends StatelessWidget {
  const SettingsNote(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text,
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}

/// One machine in Settings › Agents: its agent hooks screen and its
/// notification level.
class _AgentMachineCard extends StatelessWidget {
  const _AgentMachineCard({required this.host, required this.onNotifyLevel});

  final SavedHost host;
  final ValueChanged<AgentNotifyLevel> onNotifyLevel;

  @override
  Widget build(BuildContext context) {
    final hasCompanion = CompanionSetupScope.maybeOf(context) != null;
    return SettingsCard(
      child: Column(
        children: [
          ListTile(
            key: ValueKey('settings-agent-hooks-${host.id}'),
            leading: const Icon(Icons.webhook_rounded),
            title: Text(
              host.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              host.agentAttentionEnabled
                  ? 'Agent monitoring on'
                  : 'Agent monitoring off (machine settings)',
            ),
            trailing: hasCompanion
                ? const Icon(Icons.chevron_right_rounded)
                : null,
            onTap: hasCompanion
                ? () => unawaited(showCompanionSetup(context, host))
                : null,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 12, 6),
            child: Row(
              children: [
                const Icon(Icons.notifications_none_rounded, size: 20),
                const SizedBox(width: 16),
                const Text('Notify'),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButton<AgentNotifyLevel>(
                    key: ValueKey('settings-notify-${host.id}'),
                    value: host.agentNotifyLevel,
                    isExpanded: true,
                    underline: const SizedBox.shrink(),
                    items: [
                      for (final level in AgentNotifyLevel.values)
                        DropdownMenuItem(
                          value: level,
                          child: Text(
                            level.label,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (level) {
                      if (level != null) onNotifyLevel(level);
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// "Lock again": how long Conductore may stay in the background before it
/// asks for the fingerprint, face or PIN again.
class _RelockDelayTile extends StatelessWidget {
  const _RelockDelayTile({required this.controller});

  final AppLockController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 12, 4),
        child: Row(
          children: [
            const Icon(Icons.timer_outlined, size: 22),
            const SizedBox(width: 16),
            const Expanded(child: Text('Lock again in the background')),
            DropdownButton<RelockDelay>(
              key: const ValueKey('settings-relock-delay'),
              value: controller.relockDelay,
              underline: const SizedBox.shrink(),
              items: [
                for (final delay in RelockDelay.values)
                  DropdownMenuItem(value: delay, child: Text(delay.label)),
              ],
              onChanged: (delay) {
                if (delay != null) unawaited(controller.setRelockDelay(delay));
              },
            ),
          ],
        ),
      ),
    );
  }
}
