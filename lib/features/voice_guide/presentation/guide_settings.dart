import 'dart:async';

import 'package:conduit/core/presentation/theme_sheet.dart';
import 'package:conduit/core/theme/theme_controller.dart';
import 'package:conduit/features/hosts/presentation/hosts_controller.dart';
import 'package:conduit/features/voice/domain/speech_languages.dart';
import 'package:conduit/features/voice_guide/domain/guide_preferences.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Settings › Chat & Voice › Voice guide.
class GuideSettingsControls extends StatelessWidget {
  const GuideSettingsControls({required this.theme, this.hosts, super.key});

  final ThemeController theme;

  /// Saved machines, for the brain machine; null hides that choice.
  final HostsController? hosts;

  GuidePreferences get _prefs => theme.voice.guide;

  Future<void> _set(GuidePreferences guide) =>
      theme.setVoice(theme.voice.copyWith(guide: guide));

  static const _gap = SizedBox(height: 12);

  @override
  Widget build(BuildContext context) {
    final prefs = _prefs;
    final hosts = this.hosts;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSwitchCard(
          switchKey: const ValueKey('guide-enabled'),
          icon: Icons.headset_mic_outlined,
          title: 'Voice guide',
          subtitle:
              'Talk to all your agents hands-free: "what\'s waiting", "open '
              'api", "approve", "tell web to run the tests". Start it with '
              'the headset-mic button at the top of home, a long press on Talk in '
              'Chat View, or (Android) the Voice guide quick-settings tile.',
          value: prefs.enabled,
          onChanged: (value) => _set(prefs.copyWith(enabled: value)),
        ),
        if (prefs.enabled) ...[
          _gap,
          if (hosts != null)
            SettingsCard(
              child: ListTile(
                key: const ValueKey('guide-brain'),
                leading: const Icon(Icons.psychology_outlined),
                title: const Text('Brain machine'),
                subtitle: Text(_brainLabel(hosts)),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => unawaited(_pickBrain(context, hosts)),
              ),
            ),
          if (hosts != null) _gap,
          SettingsSegmentCard<GuideConfirm>(
            key: const ValueKey('guide-confirm'),
            icon: Icons.verified_user_outlined,
            title: 'Say yes before acting',
            description: switch (prefs.confirm) {
              GuideConfirm.always =>
                'The guide asks "Say yes" before it approves, denies, sends '
                    'a prompt, trusts an agent or switches account.',
              GuideConfirm.skipLowRisk =>
                'Requests labelled low risk are approved without asking. '
                    'High-risk ones are always confirmed and never '
                    'approved in a batch.',
            },
            values: GuideConfirm.values,
            label: (value) => value.label,
            selected: prefs.confirm,
            onChanged: (value) => _set(prefs.copyWith(confirm: value)),
          ),
          _gap,
          SettingsCard(
            child: ListTile(
              key: const ValueKey('guide-language'),
              leading: const Icon(Icons.translate_rounded),
              title: const Text('Guide language'),
              subtitle: Text(
                prefs.language.isEmpty
                    ? 'Same as dictation'
                    : describeSpeechLanguage(prefs.language),
              ),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => unawaited(_pickLanguage(context)),
            ),
          ),
          // The headset routes and the tile are Android's (GuideWakeBridge).
          if (defaultTargetPlatform == TargetPlatform.android) ...[
            _gap,
            SettingsSwitchCard(
              switchKey: const ValueKey('guide-headset'),
              icon: Icons.headphones_outlined,
              title: 'Wake with headset button',
              subtitle:
                  'Long-press the headset\'s play button, or its assistant '
                  'button (Android asks once which app to use), to start the '
                  'guide. The play button works while no music app has '
                  'played since.',
              value: prefs.headsetWake,
              onChanged: (value) => _set(prefs.copyWith(headsetWake: value)),
            ),
          ],
        ],
      ],
    );
  }

  String _brainLabel(HostsController hosts) {
    final id = _prefs.brainHostId;
    if (id.isEmpty) {
      return 'Automatic: the first connected machine with the Conductore '
          'companion. It runs Claude (Haiku) for what the phone cannot '
          'match itself.';
    }
    return hosts.findById(id)?.name ?? 'A removed machine (automatic)';
  }

  Future<void> _pickBrain(BuildContext context, HostsController hosts) async {
    final machines = [
      for (final host in hosts.machines)
        if (!host.isLocal) host,
    ];
    final picked = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Brain machine'),
        children: [
          RadioGroup<String>(
            groupValue: _prefs.brainHostId,
            onChanged: (value) => Navigator.of(context).pop(value),
            child: Column(
              children: [
                const RadioListTile<String>(
                  value: '',
                  title: Text('Automatic'),
                ),
                for (final host in machines)
                  RadioListTile<String>(value: host.id, title: Text(host.name)),
              ],
            ),
          ),
        ],
      ),
    );
    if (picked != null) await _set(_prefs.copyWith(brainHostId: picked));
  }

  Future<void> _pickLanguage(BuildContext context) async {
    final picked = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Guide language'),
        children: [
          RadioGroup<String>(
            groupValue: _prefs.language,
            onChanged: (value) => Navigator.of(context).pop(value),
            child: Column(
              children: [
                const RadioListTile<String>(
                  value: '',
                  title: Text('Same as dictation'),
                ),
                for (final language in speechLanguages)
                  if (!language.isDeviceDefault)
                    RadioListTile<String>(
                      value: language.tag,
                      title: Text(language.label),
                    ),
              ],
            ),
          ),
        ],
      ),
    );
    if (picked != null) await _set(_prefs.copyWith(language: picked));
  }
}
