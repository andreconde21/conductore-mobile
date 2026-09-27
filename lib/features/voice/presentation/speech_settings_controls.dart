import 'dart:async';

import 'package:conduit/core/platform_features.dart';
import 'package:conduit/core/theme/theme_controller.dart';
import 'package:conduit/features/voice/data/platform_text_to_speech.dart';
import 'package:conduit/features/voice/domain/speech_languages.dart';
import 'package:conduit/features/voice/domain/text_to_speech.dart';
import 'package:conduit/features/voice/domain/voice_preferences.dart';
import 'package:conduit/features/voice/presentation/voice_services.dart';
import 'package:flutter/material.dart';

/// Settings → Speech: dictation (language, continuous listening and its
/// limits) and Chat View's "Read replies aloud" (default, language, voice,
/// speed, pitch).
class SpeechSettingsControls extends StatefulWidget {
  const SpeechSettingsControls({
    required this.controller,
    this.textToSpeech,
    super.key,
  });

  final ThemeController controller;

  /// Lists voices and plays the sample; defaults to the on-device engine
  /// on Android. Without one the read-aloud settings are hidden.
  final TextToSpeech? textToSpeech;

  @override
  State<SpeechSettingsControls> createState() => _SpeechSettingsControlsState();
}

class _SpeechSettingsControlsState extends State<SpeechSettingsControls> {
  TextToSpeech? _tts;

  ThemeController get _settings => widget.controller;

  @override
  void initState() {
    super.initState();
    _tts =
        widget.textToSpeech ??
        VoiceServicesScope.maybeOf(context)?.tts ??
        (PlatformFeatures.textToSpeech ? PlatformTextToSpeech() : null);
  }

  @override
  void dispose() {
    final tts = _tts;
    if (tts != null) unawaited(tts.stop().catchError((Object _) {}));
    super.dispose();
  }

  void _update(VoicePreferences Function(VoicePreferences voice) change) {
    unawaited(_settings.setVoice(change(_settings.voice)));
  }

  String get _ttsLanguage =>
      _settings.voice.effectiveTtsLanguage(_settings.speechLanguage);

  Future<void> _playSample() async {
    final tts = _tts;
    if (tts == null) return;
    final voice = _settings.voice;
    await tts.setRate(voice.ttsRate);
    await tts.setPitch(voice.ttsPitch);
    await tts.speak(
      _sampleFor(_ttsLanguage),
      id: 'settings-sample',
      language: _ttsLanguage,
      voice: voice.ttsVoice,
    );
  }

  static String _sampleFor(String tag) {
    final language = tag.split('-').first.toLowerCase();
    return switch (language) {
      'pt' => 'É assim que as respostas do Claude vão soar.',
      'es' => 'Así sonarán las respuestas de Claude.',
      'fr' => 'Voici comment les réponses de Claude seront lues.',
      'de' => 'So klingen die Antworten von Claude.',
      'it' => 'Ecco come suoneranno le risposte di Claude.',
      'nl' => 'Zo klinken de antwoorden van Claude.',
      _ => "This is how Claude's replies will sound.",
    };
  }

  Future<void> _pickVoice() async {
    final tts = _tts;
    if (tts == null) return;
    final voices = await tts.voices(language: _ttsLanguage);
    if (!mounted) return;
    final picked = await showDialog<String>(
      context: context,
      builder: (context) => _VoiceDialog(
        voices: voices,
        current: _settings.voice.ttsVoice,
        onPreview: (id) async {
          final voice = _settings.voice;
          await tts.setRate(voice.ttsRate);
          await tts.setPitch(voice.ttsPitch);
          await tts.speak(
            _sampleFor(_ttsLanguage),
            id: 'settings-sample',
            language: _ttsLanguage,
            voice: id,
          );
        },
      ),
    );
    unawaited(tts.stop().catchError((Object _) {}));
    if (picked != null) {
      _update((voice) => voice.copyWith(ttsVoice: picked));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _settings,
      builder: (context, _) {
        final theme = Theme.of(context);
        final colorScheme = theme.colorScheme;
        final voice = _settings.voice;
        final muted = theme.textTheme.bodySmall?.copyWith(
          color: colorScheme.onSurfaceVariant,
        );
        Widget card(List<Widget> children) => Material(
          color: colorScheme.surface,
          shape: RoundedRectangleBorder(
            side: BorderSide(color: colorScheme.outlineVariant),
            borderRadius: BorderRadius.circular(14),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(mainAxisSize: MainAxisSize.min, children: children),
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            card([
              ListTile(
                leading: const Icon(Icons.mic_none_rounded),
                title: const Text('Language'),
                subtitle: Text(
                  'Dictation in Chat mode uses on-device recognition.',
                  style: muted,
                ),
                trailing: _Value(
                  describeSpeechLanguage(_settings.speechLanguage),
                ),
                onTap: () => showSpeechLanguageDialog(
                  context: context,
                  current: _settings.speechLanguage,
                  onChanged: _settings.setSpeechLanguage,
                ),
              ),
              SwitchListTile(
                key: const ValueKey('speech-continuous'),
                secondary: const Icon(Icons.all_inclusive_rounded),
                title: const Text('Keep listening until I tap stop'),
                subtitle: Text(
                  'Dictation carries on across pauses instead of stopping '
                  'after the first one.',
                  style: muted,
                ),
                value: voice.continuousDictation,
                onChanged: (value) =>
                    _update((v) => v.copyWith(continuousDictation: value)),
              ),
              if (voice.continuousDictation) ...[
                _SliderTile(
                  key: const ValueKey('speech-silence'),
                  icon: Icons.hourglass_bottom_rounded,
                  title: 'Pause after silence',
                  value: voice.dictationSilenceSeconds.toDouble(),
                  min: VoicePreferences.minSilenceSeconds.toDouble(),
                  max: 30,
                  divisions: 27,
                  label: '${voice.dictationSilenceSeconds} s',
                  onChanged: (value) => _update(
                    (v) => v.copyWith(dictationSilenceSeconds: value.round()),
                  ),
                ),
                _SliderTile(
                  key: const ValueKey('speech-max-session'),
                  icon: Icons.timer_outlined,
                  title: 'Longest session',
                  value: voice.dictationMaxMinutes.toDouble(),
                  min: VoicePreferences.minMaxMinutes.toDouble(),
                  max: 15,
                  divisions: 14,
                  label: '${voice.dictationMaxMinutes} min',
                  onChanged: (value) => _update(
                    (v) => v.copyWith(dictationMaxMinutes: value.round()),
                  ),
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.notifications_off_outlined),
                  title: const Text('Silence beeps between phrases'),
                  subtitle: Text(
                    'Experimental. Mutes media, notification and system '
                    'sounds while dictating so restarts are quiet. Restored '
                    'when you stop, or on the next start if the app was '
                    'closed while muted.',
                    style: muted,
                  ),
                  value: voice.muteRestartBeeps,
                  onChanged: (value) =>
                      _update((v) => v.copyWith(muteRestartBeeps: value)),
                ),
              ],
            ]),
            if (_tts != null) ...[
              const SizedBox(height: 10),
              card([
                SwitchListTile(
                  key: const ValueKey('speech-read-aloud-default'),
                  secondary: const Icon(Icons.record_voice_over_outlined),
                  title: const Text('Read replies aloud by default'),
                  subtitle: Text(
                    "Chat View speaks Claude's final answer of each turn, "
                    'approvals and questions, never tool output. The speaker '
                    'in its header turns it off per session.',
                    style: muted,
                  ),
                  value: voice.readAloudByDefault,
                  onChanged: (value) =>
                      _update((v) => v.copyWith(readAloudByDefault: value)),
                ),
                Padding(
                  key: const ValueKey('speech-read-aloud-length'),
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'How much to read',
                        style: theme.textTheme.titleSmall,
                      ),
                      const SizedBox(height: 4),
                      Text(switch (voice.readAloudLength) {
                        ReadAloudLength.brief =>
                          'The first two or three sentences, then "More on '
                              'screen". In Talk, say "more" for the rest.',
                        ReadAloudLength.full =>
                          'The whole answer. Code blocks and tables become a '
                              'short cue.',
                        ReadAloudLength.summary =>
                          'A short summary written by Claude on the machine '
                              '(companion 0.7.0 or later), else the brief '
                              'version.',
                      }, style: muted),
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child: SegmentedButton<ReadAloudLength>(
                          segments: [
                            for (final length in ReadAloudLength.values)
                              ButtonSegment(
                                value: length,
                                label: Text(length.label),
                              ),
                          ],
                          selected: {voice.readAloudLength},
                          onSelectionChanged: (selection) => _update(
                            (v) =>
                                v.copyWith(readAloudLength: selection.single),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                ListTile(
                  key: const ValueKey('speech-tts-language'),
                  leading: const Icon(Icons.translate_rounded),
                  title: const Text('Reading language'),
                  trailing: _Value(
                    voice.ttsLanguage.isEmpty
                        ? 'Same as dictation'
                        : describeSpeechLanguage(voice.ttsLanguage),
                  ),
                  onTap: () => showSpeechLanguageDialog(
                    context: context,
                    current: voice.ttsLanguage,
                    title: 'Reading language',
                    defaultLabel: 'Same as dictation',
                    onChanged: (tag) => _update(
                      // A voice belongs to one language.
                      (v) => v.copyWith(ttsLanguage: tag, ttsVoice: ''),
                    ),
                  ),
                ),
                ListTile(
                  key: const ValueKey('speech-tts-voice'),
                  leading: const Icon(Icons.graphic_eq_rounded),
                  title: const Text('Voice'),
                  subtitle: Text('Offline voices only.', style: muted),
                  trailing: _Value(
                    voice.ttsVoice.isEmpty ? 'Automatic' : voice.ttsVoice,
                  ),
                  onTap: _pickVoice,
                ),
                _SliderTile(
                  key: const ValueKey('speech-talk-send'),
                  icon: Icons.send_rounded,
                  title: 'Talk: send after a pause of',
                  value: voice.talkSendSilenceSeconds.toDouble(),
                  min: VoicePreferences.minTalkSendSeconds.toDouble(),
                  max: VoicePreferences.maxTalkSendSeconds.toDouble(),
                  divisions: 9,
                  label: '${voice.talkSendSilenceSeconds} s',
                  onChanged: (value) => _update(
                    (v) => v.copyWith(talkSendSilenceSeconds: value.round()),
                  ),
                ),
                _SliderTile(
                  key: const ValueKey('speech-rate'),
                  icon: Icons.speed_rounded,
                  title: 'Speed',
                  value: voice.ttsRate,
                  min: VoicePreferences.minRate,
                  max: VoicePreferences.maxRate,
                  divisions: 15,
                  label: '${voice.ttsRate.toStringAsFixed(1)}×',
                  onChanged: (value) =>
                      _update((v) => v.copyWith(ttsRate: value)),
                ),
                _SliderTile(
                  key: const ValueKey('speech-pitch'),
                  icon: Icons.tune_rounded,
                  title: 'Pitch',
                  value: voice.ttsPitch,
                  min: VoicePreferences.minPitch,
                  max: VoicePreferences.maxPitch,
                  divisions: 15,
                  label: voice.ttsPitch.toStringAsFixed(1),
                  onChanged: (value) =>
                      _update((v) => v.copyWith(ttsPitch: value)),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      key: const ValueKey('speech-test'),
                      onPressed: _playSample,
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: const Text('Test voice'),
                    ),
                  ),
                ),
              ]),
            ],
          ],
        );
      },
    );
  }
}

class _Value extends StatelessWidget {
  const _Value(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 150),
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        const Icon(Icons.chevron_right_rounded),
      ],
    );
  }
}

class _SliderTile extends StatelessWidget {
  const _SliderTile({
    required this.icon,
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.label,
    required this.onChanged,
    super.key,
  });

  final IconData icon;
  final String title;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String label;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 16),
              Expanded(child: Text(title, style: theme.textTheme.bodyLarge)),
              Text(
                label,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          Slider(
            min: min,
            max: max,
            divisions: divisions,
            value: value.clamp(min, max),
            label: label,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

class _VoiceDialog extends StatefulWidget {
  const _VoiceDialog({
    required this.voices,
    required this.current,
    required this.onPreview,
  });

  final List<TtsVoice> voices;
  final String current;
  final Future<void> Function(String id) onPreview;

  @override
  State<_VoiceDialog> createState() => _VoiceDialogState();
}

class _VoiceDialogState extends State<_VoiceDialog> {
  late String _selection = widget.current;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Voice'),
      content: SizedBox(
        width: double.maxFinite,
        child: widget.voices.isEmpty
            ? const Text(
                'No offline voice is installed for this language. Install '
                'one in Android Settings → Text-to-speech output.',
              )
            : ListView(
                shrinkWrap: true,
                children: [
                  RadioGroup<String>(
                    groupValue: _selection,
                    onChanged: (value) {
                      if (value == null) return;
                      setState(() => _selection = value);
                      if (value.isNotEmpty) unawaited(widget.onPreview(value));
                    },
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const RadioListTile<String>(
                          value: '',
                          title: Text('Automatic'),
                          subtitle: Text('The best offline voice'),
                          dense: true,
                        ),
                        for (final voice in widget.voices)
                          RadioListTile<String>(
                            value: voice.id,
                            title: Text(voice.id),
                            subtitle: Text(voice.locale),
                            dense: true,
                          ),
                      ],
                    ),
                  ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_selection),
          child: const Text('Use'),
        ),
      ],
    );
  }
}

Future<void> showSpeechLanguageDialog({
  required BuildContext context,
  required String current,
  required ValueChanged<String> onChanged,
  String title = 'Speech language',
  String? defaultLabel,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => _SpeechLanguageDialog(
      current: current,
      onChanged: onChanged,
      title: title,
      defaultLabel: defaultLabel,
    ),
  );
}

class _SpeechLanguageDialog extends StatefulWidget {
  const _SpeechLanguageDialog({
    required this.current,
    required this.onChanged,
    required this.title,
    this.defaultLabel,
  });

  final String current;
  final ValueChanged<String> onChanged;
  final String title;

  /// Label for the empty tag (else "Device default").
  final String? defaultLabel;

  @override
  State<_SpeechLanguageDialog> createState() => _SpeechLanguageDialogState();
}

class _SpeechLanguageDialogState extends State<_SpeechLanguageDialog> {
  static const _custom = '__custom__';

  late String _selection;
  late final TextEditingController _customController;
  String? _customError;

  bool get _isListed =>
      speechLanguages.any((language) => language.tag == widget.current);

  @override
  void initState() {
    super.initState();
    _selection = _isListed ? widget.current : _custom;
    _customController = TextEditingController(
      text: _isListed ? '' : widget.current,
    );
  }

  @override
  void dispose() {
    _customController.dispose();
    super.dispose();
  }

  void _apply() {
    if (_selection == _custom) {
      final normalized = normalizeSpeechLanguageTag(_customController.text);
      if (normalized == null) {
        setState(() => _customError = 'Use a tag such as pt-PT or en-US.');
        return;
      }
      widget.onChanged(normalized);
    } else {
      widget.onChanged(_selection);
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: double.maxFinite,
        child: ListView(
          shrinkWrap: true,
          children: [
            RadioGroup<String>(
              groupValue: _selection,
              onChanged: (value) {
                if (value != null) {
                  setState(() => _selection = value);
                }
              },
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final language in speechLanguages)
                    RadioListTile<String>(
                      value: language.tag,
                      title: Text(
                        language.isDeviceDefault
                            ? widget.defaultLabel ?? language.label
                            : language.label,
                      ),
                      subtitle: language.isDeviceDefault
                          ? null
                          : Text(language.tag),
                      dense: true,
                    ),
                  const RadioListTile<String>(
                    value: _custom,
                    title: Text('Other'),
                    dense: true,
                  ),
                ],
              ),
            ),
            if (_selection == _custom)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                child: TextField(
                  controller: _customController,
                  autofocus: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: 'Language tag',
                    hintText: 'pt-PT',
                    errorText: _customError,
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: (_) {
                    if (_customError != null) {
                      setState(() => _customError = null);
                    }
                  },
                  onSubmitted: (_) => _apply(),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _apply, child: const Text('Use')),
      ],
    );
  }
}
