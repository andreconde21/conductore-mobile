import 'package:conduit/core/theme/theme_controller.dart';
import 'package:conduit/core/theme/theme_preferences_repository.dart';
import 'package:conduit/features/voice/domain/voice_preferences.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

void main() {
  test('voice settings persist through the preferences repository', () async {
    final repository = ThemePreferencesRepository(InMemorySecureStorage());
    final controller = ThemeController(repository);
    await controller.load();
    expect(controller.voice, VoicePreferences.defaults);
    expect(controller.voice.continuousDictation, isTrue);
    expect(controller.voice.dictationSilenceSeconds, 8);
    expect(controller.voice.dictationMaxMinutes, 5);
    expect(controller.voice.muteRestartBeeps, isFalse, reason: 'opt-in');

    await controller.setVoice(
      controller.voice
          .copyWith(
            readAloudByDefault: true,
            ttsLanguage: 'pt-PT',
            ttsVoice: 'pt-pt-x-sfs-local',
            ttsRate: 1.4,
            ttsPitch: 0.9,
            continuousDictation: false,
            dictationSilenceSeconds: 12,
            dictationMaxMinutes: 10,
            muteRestartBeeps: true,
            talkSendSilenceSeconds: 4,
          )
          .withSessionReadAloud('s1', false),
    );

    final reloaded = ThemeController(repository);
    await reloaded.load();
    final voice = reloaded.voice;
    expect(voice.readAloudByDefault, isTrue);
    expect(voice.ttsLanguage, 'pt-PT');
    expect(voice.ttsVoice, 'pt-pt-x-sfs-local');
    expect(voice.ttsRate, 1.4);
    expect(voice.ttsPitch, 0.9);
    expect(voice.continuousDictation, isFalse);
    expect(voice.dictationSilence, const Duration(seconds: 12));
    expect(voice.dictationMaxSession, const Duration(minutes: 10));
    expect(voice.muteRestartBeeps, isTrue);
    expect(voice.talkSendSilenceSeconds, 4);
    expect(voice.readAloudFor('s1'), isFalse);
    expect(voice.readAloudFor('other'), isTrue);
  });

  test('values are clamped and malformed JSON falls back to defaults', () {
    final clamped = VoicePreferences.defaults.copyWith(
      ttsRate: 9,
      ttsPitch: 0,
      dictationSilenceSeconds: 1,
      dictationMaxMinutes: 999,
    );
    expect(clamped.ttsRate, VoicePreferences.maxRate);
    expect(clamped.ttsPitch, VoicePreferences.minPitch);
    expect(clamped.dictationSilenceSeconds, VoicePreferences.minSilenceSeconds);
    expect(clamped.dictationMaxMinutes, VoicePreferences.maxMaxMinutes);

    expect(VoicePreferences.decode('not json'), VoicePreferences.defaults);
    expect(
      VoicePreferences.decode('{"ttsRate":"fast","readAloudByDefault":true}'),
      VoicePreferences.defaults.copyWith(readAloudByDefault: true),
    );
  });

  test('the speaker toggle is remembered per session, oldest dropped', () {
    var prefs = VoicePreferences.defaults;
    for (var i = 0; i < VoicePreferences.maxRememberedSessions + 5; i++) {
      prefs = prefs.withSessionReadAloud('s$i', true);
    }
    expect(
      prefs.readAloudSessions.length,
      VoicePreferences.maxRememberedSessions,
    );
    expect(prefs.readAloudFor('s0'), isFalse);
    expect(prefs.readAloudFor('s44'), isTrue);
  });

  test('backup JSON leaves out the per-session toggles', () {
    final local = VoicePreferences.defaults.withSessionReadAloud('mine', true);
    final backup = local.copyWith(ttsRate: 1.5).toJson(includeSessions: false);
    expect(backup.containsKey('readAloudSessions'), isFalse);
    final restored = VoicePreferences.fromJson(backup, fallback: local);
    expect(restored.ttsRate, 1.5);
    expect(restored.readAloudFor('mine'), isTrue);
  });

  test('speech language defaults to the dictation language', () {
    expect(VoicePreferences.defaults.effectiveTtsLanguage('pt-PT'), 'pt-PT');
    expect(
      VoicePreferences.defaults
          .copyWith(ttsLanguage: 'en-GB')
          .effectiveTtsLanguage('pt-PT'),
      'en-GB',
    );
  });

  test('read-aloud length and tool activity round-trip, unknown values '
      'fall back', () {
    expect(VoicePreferences.defaults.readAloudLength, ReadAloudLength.brief);
    expect(VoicePreferences.defaults.toolActivity, ToolActivity.collapsed);
    final custom = VoicePreferences.defaults.copyWith(
      readAloudLength: ReadAloudLength.summary,
      toolActivity: ToolActivity.hidden,
    );
    final back = VoicePreferences.decode(custom.encode());
    expect(back.readAloudLength, ReadAloudLength.summary);
    expect(back.toolActivity, ToolActivity.hidden);
    final odd = VoicePreferences.decode(
      '{"readAloudLength":"everything","toolActivity":3}',
    );
    expect(odd.readAloudLength, ReadAloudLength.brief);
    expect(odd.toolActivity, ToolActivity.collapsed);
  });

  test('Review opens on demand by default; the choice round-trips', () {
    expect(VoicePreferences.defaults.reviewOpens, ReviewOpens.onDemand);
    final auto = VoicePreferences.defaults.copyWith(
      reviewOpens: ReviewOpens.afterEachTurn,
    );
    expect(
      VoicePreferences.decode(auto.encode()).reviewOpens,
      ReviewOpens.afterEachTurn,
    );
    expect(
      VoicePreferences.decode('{"reviewOpens":"sometimes"}').reviewOpens,
      ReviewOpens.onDemand,
    );
  });
}
