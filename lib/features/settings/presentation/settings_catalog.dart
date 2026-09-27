import 'package:conduit/core/platform_features.dart';
import 'package:conduit/features/settings/presentation/settings_sections.dart';
import 'package:conduit/features/settings/presentation/settings_services.dart';
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
    'Enter key, mouse taps, clipboard, menus, sessions, snippets',
    Icons.terminal_rounded,
  ),
  input(
    'Input',
    'Toolbar and pill buttons, key rows, gestures',
    Icons.keyboard_alt_outlined,
  ),
  chatVoice(
    'Chat & Voice',
    'Composer, dictation, read replies aloud, Talk',
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

/// One setting as Settings search finds it: the [title] shown on its
/// section page, and extra words people may type for it.
class SettingsEntry {
  const SettingsEntry(
    this.section,
    this.title, {
    this.keywords = const [],
    this.availableWhen,
  });

  final SettingsSection section;

  /// The exact text of the setting on its section page.
  final String title;
  final List<String> keywords;

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
bool _speech(SettingsServices _) =>
    PlatformFeatures.dictation || PlatformFeatures.textToSpeech;
bool _tts(SettingsServices _) => PlatformFeatures.textToSpeech;
bool _guide(SettingsServices _) =>
    PlatformFeatures.dictation && PlatformFeatures.textToSpeech;
bool _homeWidget(SettingsServices _) => PlatformFeatures.homeWidget;
bool _backup(SettingsServices s) => s.backupService != null;
bool _machines(SettingsServices s) => s.hostsController != null;
bool _usage(SettingsServices s) => s.agentAttention != null;
bool _trustedKeys(SettingsServices s) => s.hostKeyVerifier != null;
bool _lock(SettingsServices s) => s.onLockNow != null;
bool _sessionViews(SettingsServices s) => s.hasSessionViews;
bool _sync(SettingsServices s) => s.hasSync;
bool _desktop(SettingsServices _) => PlatformFeatures.isDesktop;
bool _selfMachine(SettingsServices s) =>
    s.hostsController != null && showsSelfMachineSetting(s.hostsController!);
bool _windowsShell(SettingsServices s) =>
    s.hostsController != null && showsWindowsShellSetting(s.hostsController!);

/// Every setting the page offers, section by section. A test walks this
/// list and checks each title on its section page, so nothing that used to
/// live in the Appearance sheet gets lost.
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
    'Enter sends',
    keywords: ['enter', 'return', 'crlf', 'newline', 'sequence'],
  ),
  SettingsEntry(
    SettingsSection.terminal,
    'Send mouse taps',
    keywords: ['mouse', 'click', 'tap'],
  ),
  SettingsEntry(
    SettingsSection.terminal,
    'Remote clipboard',
    keywords: ['osc 52', 'copy', 'clipboard'],
  ),
  SettingsEntry(
    SettingsSection.terminal,
    'Menu buttons',
    keywords: ['prompts', 'y/n', 'numbered menus'],
  ),
  SettingsEntry(
    SettingsSection.terminal,
    'Paste images as uploaded files',
    keywords: ['image', 'paste', 'screenshot'],
  ),
  SettingsEntry(
    SettingsSection.terminal,
    'Restore sessions on launch',
    keywords: ['restore', 'reopen', 'startup'],
  ),
  SettingsEntry(
    SettingsSection.terminal,
    'Open Claude sessions in',
    keywords: ['default view', 'chat view', 'claude'],
    availableWhen: _sessionViews,
  ),
  SettingsEntry(
    SettingsSection.terminal,
    'Multiplexer tabs on phone',
    keywords: ['herdr tabs', 'tmux windows', 'strip', 'compact', 'tablet'],
  ),
  SettingsEntry(
    SettingsSection.terminal,
    'Global snippets',
    keywords: ['snippet', 'snip', 'macro', 'command'],
  ),
  // Input
  SettingsEntry(
    SettingsSection.input,
    'Toolbar style',
    keywords: ['pill', 'keyboard bar', 'toolbar'],
  ),
  SettingsEntry(
    SettingsSection.input,
    'Pill buttons',
    keywords: ['pill', 'configure', 'customize', 'buttons'],
  ),
  SettingsEntry(
    SettingsSection.input,
    'Key rows',
    keywords: ['keys', 'shortcuts', 'ctrl', 'esc', 'tab', 'keyboard'],
  ),
  SettingsEntry(
    SettingsSection.input,
    'Keyboard shortcuts',
    keywords: ['hotkeys', 'desktop', 'keys', 'ctrl'],
    availableWhen: _desktop,
  ),
  SettingsEntry(
    SettingsSection.input,
    'Swipe switches window',
    keywords: ['gesture', 'swipe'],
  ),
  SettingsEntry(
    SettingsSection.input,
    'Pinch to zoom',
    keywords: ['gesture', 'zoom'],
  ),
  SettingsEntry(
    SettingsSection.input,
    'Drag scrolls the remote app (mouse wheel)',
    keywords: ['gesture', 'scroll', 'drag', 'terminal'],
  ),
  // Chat & Voice
  SettingsEntry(
    SettingsSection.chatVoice,
    'Press Enter after inserting',
    keywords: ['composer', 'prompt', 'chat mode', 'enter', 'submit', 'send'],
  ),
  SettingsEntry(
    SettingsSection.chatVoice,
    'Tool activity',
    keywords: ['tools', 'tool calls', 'commands', 'collapse', 'hide'],
  ),
  SettingsEntry(
    SettingsSection.chatVoice,
    'Where to find voice',
    keywords: ['mic', 'microphone', 'dictate', 'talk', 'speech', 'voice'],
    availableWhen: _speech,
  ),
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
    'Silence beeps between phrases',
    keywords: ['beep', 'mute', 'experimental'],
    availableWhen: _speech,
  ),
  SettingsEntry(
    SettingsSection.chatVoice,
    'Read replies aloud by default',
    keywords: ['tts', 'text to speech', 'speak', 'read aloud'],
    availableWhen: _tts,
  ),
  SettingsEntry(
    SettingsSection.chatVoice,
    'How much to read',
    keywords: ['brief', 'full', 'summary', 'read aloud', 'length'],
    availableWhen: _tts,
  ),
  SettingsEntry(
    SettingsSection.chatVoice,
    'Talk: send after a pause of',
    keywords: ['talk', 'voice mode', 'hands-free'],
    availableWhen: _tts,
  ),
  SettingsEntry(
    SettingsSection.chatVoice,
    'Voice guide',
    keywords: ['guide', 'hands-free', 'driving', 'talk to the fleet', 'voice'],
    availableWhen: _guide,
  ),
  SettingsEntry(
    SettingsSection.chatVoice,
    'Brain machine',
    keywords: ['guide', 'claude', 'haiku'],
    availableWhen: _guide,
  ),
  SettingsEntry(
    SettingsSection.chatVoice,
    'Say yes before acting',
    keywords: ['guide', 'confirm', 'approve', 'low risk'],
    availableWhen: _guide,
  ),
  SettingsEntry(
    SettingsSection.chatVoice,
    'Guide language',
    keywords: ['guide', 'portuguese', 'english'],
    availableWhen: _guide,
  ),
  SettingsEntry(
    SettingsSection.chatVoice,
    'Wake with headset button',
    keywords: ['guide', 'headset', 'bluetooth', 'media button', 'driving'],
    availableWhen: _guide,
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
    'Notifications',
    keywords: ['notify', 'alerts', 'approvals'],
    availableWhen: _machines,
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
