import 'package:conduit/core/platform_features.dart';
import 'package:conduit/features/desktop_shell/presentation/project_layout_controller.dart';
import 'package:conduit/features/settings/presentation/settings_sections.dart';
import 'package:conduit/features/settings/presentation/settings_services.dart';
import 'package:conduit/features/voice/presentation/speech_settings_controls.dart';
import 'package:flutter/material.dart';

/// The Settings page's sections, in list order.
enum SettingsSection {
  appearance(
    'Appearance',
    'Theme, Omarchy themes, terminal font and size',
    Icons.palette_outlined,
  ),
  terminal(
    'Terminal',
    'Agent sessions, Herdr focus, snippets, quick actions',
    Icons.terminal_rounded,
  ),
  input(
    'Input',
    'Customize keys, key rows, gestures',
    Icons.keyboard_alt_outlined,
  ),
  chatVoice(
    'Chat & Voice',
    'Dictation, voice commands, voice guide, read aloud',
    Icons.forum_outlined,
  ),
  agents(
    'Agents',
    'Agent hooks per machine, notifications, usage',
    Icons.smart_toy_outlined,
  ),
  syncBackup(
    'Sync & Backup',
    'Device sync, export and import backups',
    Icons.sync_rounded,
  ),
  security('Security', 'App lock, trusted host keys', Icons.shield_outlined),
  privacy(
    'Privacy',
    'Crash reports, anonymous usage stats',
    Icons.privacy_tip_outlined,
  ),
  about(
    'About',
    'Version, credits, licences, recent errors',
    Icons.info_outline_rounded,
  );

  const SettingsSection(this.title, this.subtitle, this.icon);

  final String title;
  final String subtitle;
  final IconData icon;
}

/// Where a section keeps the settings most people never change (CON-108).
const settingsAdvanced = 'Advanced';

/// The Chat & Voice row that opens the voice guide's page.
const voiceGuideTitle = 'Voice guide';

/// Settings › Input: the editor of the toolbar in use (the pill's buttons
/// by default, else the key rows).
const customizeKeysTitle = 'Customize keys';

/// One setting as Settings search finds it: the [title] shown on its
/// section page, and extra words people may type for it.
class SettingsEntry {
  const SettingsEntry(
    this.section,
    this.title, {
    this.keywords = const [],
    this.availableWhen,
    this.under,
  });

  final SettingsSection section;

  /// The exact text of the setting on its section page.
  final String title;
  final List<String> keywords;

  /// Null on the section page itself; else what holds it there:
  /// [settingsAdvanced], or the title of the row whose page it is on.
  final String? under;

  bool get isTopLevel => under == null;

  /// Where search says it is: "Terminal" or "Terminal › Advanced".
  String get place => [section.title, ?under].join(' › ');

  /// Null when always shown; else whether this build and setup show it.
  final bool Function(SettingsServices services)? availableWhen;

  bool isAvailable(SettingsServices services) =>
      availableWhen?.call(services) ?? true;

  /// Whether every word of [query] appears in the title, the keywords or
  /// the section's name.
  bool matches(String query) {
    final haystack = [
      title,
      section.title,
      ...keywords,
    ].join(' ').toLowerCase();
    return query
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .every(haystack.contains);
  }
}

bool _omarchy(SettingsServices s) => s.theme.omarchySync != null;
bool _notDesktop(SettingsServices _) => !PlatformFeatures.isDesktop;
const _herdrFocusKeywords = [
  'herdr',
  'focus',
  'workspace',
  'laptop',
  'shared',
  'this device',
];

/// The wakelock setting (CON-089).
const keepScreenOnTitle = 'Keep screen on while a terminal is open';

/// The SSH keep-alive setting (CON-089).
const sshKeepaliveTitle = 'SSH keepalive';

/// The "Sync with sheprd" setting (CON-077).
const sheprdSyncTitle = 'Sync with sheprd';

/// The Herdr focus setting's title on this build.
String get herdrMayMoveFocusTitle => PlatformFeatures.isDesktop
    ? 'This device may move Herdr focus'
    : 'Phone may move Herdr focus';
bool _speech(SettingsServices _) =>
    PlatformFeatures.dictation || PlatformFeatures.textToSpeech;
bool _tts(SettingsServices _) => PlatformFeatures.textToSpeech;
bool _guide(SettingsServices _) =>
    PlatformFeatures.dictation && PlatformFeatures.textToSpeech;
bool _beeps(SettingsServices _) => PlatformFeatures.muteRestartBeeps;
bool _homeWidget(SettingsServices _) => PlatformFeatures.homeWidget;
bool _backup(SettingsServices s) => s.backupService != null;
bool _machines(SettingsServices s) => s.hostsController != null;
bool _usage(SettingsServices s) => s.agentAttention != null;
bool _digest(SettingsServices s) => s.digest != null;
bool _projects(SettingsServices _) => ProjectLayoutController.instance != null;
bool _talkbawt(SettingsServices s) =>
    s.talkbawt != null && s.agentAttention != null;
bool _agentNotifications(SettingsServices s) =>
    s.hostsController != null &&
    s.agentAttention != null &&
    PlatformFeatures.agentNotifications;
bool _trustedKeys(SettingsServices s) => s.hostKeyVerifier != null;
bool _lock(SettingsServices s) => s.onLockNow != null;
bool _sessionViews(SettingsServices s) => s.hasSessionViews;
bool _sync(SettingsServices s) => s.hasSync;
bool _desktop(SettingsServices _) => PlatformFeatures.isDesktop;
bool _selfMachine(SettingsServices s) =>
    s.hostsController != null && showsSelfMachineSetting(s.hostsController!);
bool _windowsShell(SettingsServices s) =>
    s.hostsController != null && showsWindowsShellSetting(s.hostsController!);

/// Every setting the page offers, section by section: about 40 on the
/// section pages, the rest under Advanced or on a row's own page
/// ([SettingsEntry.under]). A test walks this list and checks each title
/// where it says, so nothing gets lost.
const List<SettingsEntry> settingsCatalog = [
  // Appearance
  SettingsEntry(
    SettingsSection.appearance,
    'Follow Omarchy theme from machine',
    keywords: ['omarchy', 'sync theme', 'machine theme'],
    availableWhen: _omarchy,
  ),
  SettingsEntry(
    SettingsSection.appearance,
    'Themes',
    keywords: ['theme', 'palette', 'colours', 'colors', 'dark', 'light'],
  ),
  SettingsEntry(
    SettingsSection.appearance,
    'Terminal font',
    keywords: ['font', 'typeface', 'nerd'],
  ),
  SettingsEntry(
    SettingsSection.appearance,
    'Font size',
    keywords: ['text size', 'zoom', 'bigger', 'smaller'],
  ),
  SettingsEntry(
    SettingsSection.appearance,
    'Show local shell',
    keywords: ['home', 'local terminal'],
    under: settingsAdvanced,
  ),
  // Terminal
  SettingsEntry(
    SettingsSection.terminal,
    'This computer: shell',
    keywords: ['windows', 'powershell', 'cmd', 'command prompt', 'wsl'],
    availableWhen: _windowsShell,
  ),
  SettingsEntry(
    SettingsSection.terminal,
    'Phone may move Herdr focus',
    keywords: _herdrFocusKeywords,
    availableWhen: _notDesktop,
  ),
  SettingsEntry(
    SettingsSection.terminal,
    'This device may move Herdr focus',
    keywords: _herdrFocusKeywords,
    availableWhen: _desktop,
  ),
  SettingsEntry(
    SettingsSection.terminal,
    'Open agent sessions in',
    keywords: ['default view', 'chat view', 'claude'],
    availableWhen: _sessionViews,
  ),
  SettingsEntry(
    SettingsSection.terminal,
    'Global snippets',
    keywords: ['snippet', 'snip', 'macro', 'command'],
  ),
  SettingsEntry(
    SettingsSection.terminal,
    'Quick actions',
    keywords: ['commands', 'buttons', 'project', 'code-workspace', 'run'],
  ),
  SettingsEntry(
    SettingsSection.terminal,
    'Enter sends',
    keywords: ['enter', 'return', 'crlf', 'newline', 'sequence'],
    under: settingsAdvanced,
  ),
  SettingsEntry(
    SettingsSection.terminal,
    'Send mouse taps',
    keywords: ['mouse', 'click', 'tap'],
    under: settingsAdvanced,
  ),
  SettingsEntry(
    SettingsSection.terminal,
    'Remote clipboard',
    keywords: ['osc 52', 'copy', 'clipboard'],
    under: settingsAdvanced,
  ),
  SettingsEntry(
    SettingsSection.terminal,
    'Menu buttons',
    keywords: ['prompts', 'y/n', 'numbered menus'],
    under: settingsAdvanced,
  ),
  SettingsEntry(
    SettingsSection.terminal,
    'Paste images as uploaded files',
    keywords: ['image', 'paste', 'screenshot'],
    under: settingsAdvanced,
  ),
  SettingsEntry(
    SettingsSection.terminal,
    'Restore sessions on launch',
    keywords: ['restore', 'reopen', 'startup'],
    under: settingsAdvanced,
  ),
  SettingsEntry(
    SettingsSection.terminal,
    keepScreenOnTitle,
    keywords: ['wakelock', 'screen', 'sleep', 'battery', 'lock'],
    under: settingsAdvanced,
  ),
  SettingsEntry(
    SettingsSection.terminal,
    sshKeepaliveTitle,
    keywords: ['keepalive', 'keep-alive', 'battery', 'data', 'disconnect'],
    under: settingsAdvanced,
  ),
  SettingsEntry(
    SettingsSection.terminal,
    'Multiplexer tabs on phone',
    keywords: ['herdr tabs', 'tmux windows', 'strip', 'compact', 'tablet'],
    under: settingsAdvanced,
  ),
  // Input
  SettingsEntry(
    SettingsSection.input,
    customizeKeysTitle,
    keywords: [
      'pill buttons',
      'keys',
      'toolbar',
      'pill',
      'configure',
      'customize',
      'buttons',
    ],
  ),
  SettingsEntry(
    SettingsSection.input,
    'Keyboard shortcuts',
    keywords: ['hotkeys', 'desktop', 'keys', 'ctrl'],
    availableWhen: _desktop,
  ),
  SettingsEntry(
    SettingsSection.input,
    'Toolbar style',
    keywords: ['pill', 'keyboard bar', 'toolbar'],
    under: settingsAdvanced,
  ),
  SettingsEntry(
    SettingsSection.input,
    'Key rows',
    keywords: ['keys', 'shortcuts', 'ctrl', 'esc', 'tab', 'keyboard'],
    under: settingsAdvanced,
  ),
  SettingsEntry(
    SettingsSection.input,
    'Swipe switches window',
    keywords: ['gesture', 'swipe'],
    under: settingsAdvanced,
  ),
  SettingsEntry(
    SettingsSection.input,
    'Pinch to zoom',
    keywords: ['gesture', 'zoom'],
    under: settingsAdvanced,
  ),
  SettingsEntry(
    SettingsSection.input,
    'Drag scrolls the remote app (mouse wheel)',
    keywords: ['gesture', 'scroll', 'drag', 'terminal'],
    under: settingsAdvanced,
  ),
  // Chat & Voice
  SettingsEntry(
    SettingsSection.chatVoice,
    'Language',
    keywords: ['dictation', 'speech', 'microphone'],
    availableWhen: _speech,
  ),
  SettingsEntry(
    SettingsSection.chatVoice,
    'Keep listening until I tap stop',
    keywords: ['continuous dictation', 'dictation'],
    availableWhen: _speech,
  ),
  SettingsEntry(
    SettingsSection.chatVoice,
    voiceCommandsTitle,
    keywords: [
      'voice command',
      'send',
      'cancel',
      'dictation',
      'say send',
      'enviar',
      'cancelar',
    ],
    availableWhen: _speech,
  ),
  SettingsEntry(
    SettingsSection.chatVoice,
    voiceGuideTitle,
    keywords: ['guide', 'hands-free', 'driving', 'talk to the fleet', 'voice'],
    availableWhen: _guide,
  ),
  SettingsEntry(
    SettingsSection.chatVoice,
    'Send words',
    keywords: ['voice command', 'send', 'enviar', 'dictation'],
    availableWhen: _speech,
    under: voiceCommandsTitle,
  ),
  SettingsEntry(
    SettingsSection.chatVoice,
    'Cancel words',
    keywords: ['voice command', 'cancel', 'cancelar', 'discard', 'dictation'],
    availableWhen: _speech,
    under: voiceCommandsTitle,
  ),
  SettingsEntry(
    SettingsSection.chatVoice,
    'Brain machine',
    keywords: ['guide', 'claude', 'haiku'],
    availableWhen: _guide,
    under: voiceGuideTitle,
  ),
  SettingsEntry(
    SettingsSection.chatVoice,
    'Say yes before acting',
    keywords: ['guide', 'confirm', 'approve', 'low risk'],
    availableWhen: _guide,
    under: voiceGuideTitle,
  ),
  SettingsEntry(
    SettingsSection.chatVoice,
    'Guide language',
    keywords: ['guide', 'portuguese', 'english'],
    availableWhen: _guide,
    under: voiceGuideTitle,
  ),
  SettingsEntry(
    SettingsSection.chatVoice,
    'Wake with headset button',
    keywords: ['guide', 'headset', 'bluetooth', 'media button', 'driving'],
    availableWhen: _guide,
    under: voiceGuideTitle,
  ),
  SettingsEntry(
    SettingsSection.chatVoice,
    'Press Enter after inserting',
    keywords: ['composer', 'prompt', 'chat mode', 'enter', 'submit', 'send'],
    under: settingsAdvanced,
  ),
  SettingsEntry(
    SettingsSection.chatVoice,
    'Review changes',
    keywords: ['review', 'diff', 'after each turn', 'accept', 'reject'],
    under: settingsAdvanced,
  ),
  SettingsEntry(
    SettingsSection.chatVoice,
    'Silence beeps between phrases',
    keywords: ['beep', 'mute', 'experimental'],
    availableWhen: _beeps,
    under: settingsAdvanced,
  ),
  SettingsEntry(
    SettingsSection.chatVoice,
    'Read replies aloud by default',
    keywords: ['tts', 'text to speech', 'speak', 'read aloud'],
    availableWhen: _tts,
    under: settingsAdvanced,
  ),
  SettingsEntry(
    SettingsSection.chatVoice,
    'Reading language',
    keywords: [
      'read aloud',
      'tts',
      'voice',
      'speed',
      'pitch',
      'text to speech',
    ],
    availableWhen: _tts,
    under: settingsAdvanced,
  ),
  SettingsEntry(
    SettingsSection.chatVoice,
    'Talk: send after a pause of',
    keywords: ['talk', 'voice mode', 'hands-free'],
    availableWhen: _tts,
    under: settingsAdvanced,
  ),
  // Agents
  SettingsEntry(
    SettingsSection.agents,
    'Agent hooks',
    keywords: ['companion', 'hooks', 'hostd', 'install'],
    availableWhen: _machines,
  ),
  SettingsEntry(
    SettingsSection.agents,
    'Approval rules',
    keywords: ['trust', 'always', 'auto-approve', 'permissions', 'risk'],
    availableWhen: _machines,
  ),
  SettingsEntry(
    SettingsSection.agents,
    'Notifications',
    keywords: [
      'notify',
      'notify me',
      'alerts',
      'approvals',
      'urgent',
      'finished',
      'everything',
    ],
    availableWhen: _machines,
  ),
  SettingsEntry(
    SettingsSection.agents,
    'Talkbawt',
    keywords: ['handoff', 'hand off', 'link', 'share', 'thread', 'paired'],
    availableWhen: _talkbawt,
  ),
  SettingsEntry(
    SettingsSection.agents,
    'Dashboard',
    keywords: ['digest', 'summaries', 'stuck', 'catch up', 'while away'],
    availableWhen: _digest,
  ),
  SettingsEntry(
    SettingsSection.agents,
    sheprdSyncTitle,
    keywords: [
      'sheprd',
      'herdr',
      'sidebar',
      'projects',
      'unread',
      'kept',
      'dismissed',
      'mirror',
    ],
    availableWhen: _projects,
  ),
  SettingsEntry(
    SettingsSection.agents,
    'Usage',
    keywords: ['context', 'rate limit', 'tokens'],
    availableWhen: _usage,
  ),
  SettingsEntry(
    SettingsSection.agents,
    'Add quick-settings tile',
    keywords: ['tile', 'widget', 'quick settings'],
    availableWhen: _homeWidget,
  ),
  SettingsEntry(
    SettingsSection.agents,
    'Ongoing notification',
    keywords: [
      'ongoing + urgent',
      'notify',
      'notifications',
      'mode',
      'ongoing',
      'status',
      'urgent',
      'everything',
      'verbose',
      'quiet',
    ],
    availableWhen: _agentNotifications,
    under: settingsAdvanced,
  ),
  SettingsEntry(
    SettingsSection.agents,
    'Also alert when an agent finishes',
    keywords: ['notify', 'finished', 'done', 'turn ended', 'idle'],
    availableWhen: _agentNotifications,
    under: settingsAdvanced,
  ),
  SettingsEntry(
    SettingsSection.agents,
    'Stuck or looping',
    keywords: ['notify', 'stuck', 'loop', 'repeating', 'no progress'],
    availableWhen: _agentNotifications,
    under: settingsAdvanced,
  ),
  SettingsEntry(
    SettingsSection.agents,
    'Summary only',
    keywords: ['notify', 'buttons', 'allow', 'deny', 'actions'],
    availableWhen: _agentNotifications,
    under: settingsAdvanced,
  ),
  SettingsEntry(
    SettingsSection.agents,
    'Quiet updates',
    keywords: ['notify', 'silent', 'sound', 'vibrate', 'verbose'],
    availableWhen: _agentNotifications,
    under: settingsAdvanced,
  ),
  // Sync & Backup
  SettingsEntry(
    SettingsSection.syncBackup,
    SelfMachineCard.title,
    keywords: ['this computer', 'ssh to itself', 'duplicate', 'same machine'],
    availableWhen: _selfMachine,
  ),
  SettingsEntry(
    SettingsSection.syncBackup,
    'Device sync',
    keywords: ['sync', 'hub', 'devices', 'other phone'],
    availableWhen: _sync,
  ),
  SettingsEntry(
    SettingsSection.syncBackup,
    'What syncs',
    keywords: ['categories', 'sync'],
  ),
  SettingsEntry(
    SettingsSection.syncBackup,
    'Continue where you left off',
    keywords: ['continuity', 'handoff', 'drafts', 'other device', 'resume'],
    availableWhen: _sync,
  ),
  SettingsEntry(
    SettingsSection.syncBackup,
    'Export backup',
    keywords: ['backup', 'export', 'save', 'file'],
    availableWhen: _backup,
  ),
  SettingsEntry(
    SettingsSection.syncBackup,
    'Import backup',
    keywords: ['restore', 'import', 'backup', 'file'],
    availableWhen: _backup,
  ),
  // Security
  SettingsEntry(
    SettingsSection.security,
    'App lock',
    keywords: ['biometric', 'fingerprint', 'face', 'pin', 'lock'],
  ),
  SettingsEntry(
    SettingsSection.security,
    'Lock now',
    keywords: ['lock'],
    availableWhen: _lock,
  ),
  SettingsEntry(
    SettingsSection.security,
    'Trusted host keys',
    keywords: ['known hosts', 'fingerprint', 'ssh keys'],
    availableWhen: _trustedKeys,
  ),
  // Privacy
  SettingsEntry(
    SettingsSection.privacy,
    'Send crash reports',
    keywords: ['crash', 'errors', 'glitchtip', 'sentry', 'telemetry'],
  ),
  SettingsEntry(
    SettingsSection.privacy,
    'Send anonymous usage stats',
    keywords: ['analytics', 'plausible', 'statistics', 'telemetry'],
  ),
  // About
  SettingsEntry(
    SettingsSection.about,
    'Based on Conduit by gwitko (Apache-2.0)',
    keywords: ['credits', 'upstream', 'conduit'],
  ),
  SettingsEntry(
    SettingsSection.about,
    'Open-source licenses',
    keywords: ['licences', 'licenses', 'legal'],
  ),
  SettingsEntry(
    SettingsSection.about,
    'Conductore on GitHub',
    keywords: ['source', 'code', 'repository', 'links', 'version'],
  ),
  SettingsEntry(
    SettingsSection.about,
    'Recent errors',
    keywords: ['bug', 'log', 'crash', 'report'],
  ),
];
