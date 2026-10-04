import 'dart:convert';

import 'package:conduit/features/voice_guide/domain/guide_preferences.dart';

/// How much of Claude's final answer is read aloud.
enum ReadAloudLength {
  /// The first two or three sentences, then "More on screen."
  brief('Brief'),

  /// The whole answer.
  full('Full'),

  /// A short summary written by the machine's coding agent (the
  /// companion's `summarize`), falling back to [brief].
  summary('Agent summary');

  const ReadAloudLength(this.label);

  final String label;
}

/// How Chat View shows tool calls and shell commands.
enum ToolActivity {
  /// Every tool call as its own card.
  all('Show all'),

  /// Consecutive tool calls fold into one row that expands on tap.
  collapsed('Collapsed'),

  /// No tool rows (approvals, questions and errors always show).
  hidden('Hidden');

  const ToolActivity(this.label);

  final String label;
}

/// When Review mode (the changed files of an agent turn) opens from Chat
/// View.
enum ReviewOpens {
  /// Only from the Review buttons (Chat View, the dashboard, the inbox) or
  /// the voice guide.
  onDemand('On demand'),

  /// As soon as a turn ends while its Chat View is on screen.
  afterEachTurn('After each turn');

  const ReviewOpens(this.label);

  final String label;
}

/// Read-aloud and continuous-dictation settings (Settings → Speech), and
/// how Chat View shows tool activity.
///
/// Stored as one JSON value next to the other app preferences, so adding a
/// field never needs a new storage key. Unknown or malformed fields fall
/// back to their defaults.
class VoicePreferences {
  const VoicePreferences({
    this.readAloudByDefault = false,
    this.ttsLanguage = '',
    this.ttsVoice = '',
    this.ttsRate = 1.0,
    this.ttsPitch = 1.0,
    this.continuousDictation = true,
    this.dictationSilenceSeconds = defaultSilenceSeconds,
    this.dictationMaxMinutes = defaultMaxMinutes,
    this.muteRestartBeeps = false,
    this.readAloudSessions = const {},
    this.talkSendSilenceSeconds = defaultTalkSendSeconds,
    this.readAloudLength = ReadAloudLength.brief,
    this.toolActivity = ToolActivity.collapsed,
    this.reviewOpens = ReviewOpens.onDemand,
    this.guide = GuidePreferences.defaults,
  });

  static const defaults = VoicePreferences();

  static const defaultSilenceSeconds = 8;
  static const defaultMaxMinutes = 5;
  static const minSilenceSeconds = 3;
  static const maxSilenceSeconds = 60;
  static const minMaxMinutes = 1;
  static const maxMaxMinutes = 30;
  static const defaultTalkSendSeconds = 2;
  static const minTalkSendSeconds = 1;
  static const maxTalkSendSeconds = 10;
  static const minRate = 0.5;
  static const maxRate = 2.0;
  static const minPitch = 0.5;
  static const maxPitch = 2.0;

  /// How many per-session speaker toggles are remembered (oldest dropped).
  static const maxRememberedSessions = 40;

  /// Whether Chat View opens with "Read replies aloud" on for a session
  /// whose speaker toggle was never touched.
  final bool readAloudByDefault;

  /// BCP-47 tag replies are spoken in; empty follows the dictation
  /// language (and that, when empty, the device locale).
  final String ttsLanguage;

  /// Engine voice name; empty picks the best offline voice for the
  /// language.
  final String ttsVoice;

  /// Speech rate, 1.0 is the engine's normal speed.
  final double ttsRate;

  /// Voice pitch, 1.0 is the engine's normal pitch.
  final double ttsPitch;

  /// Keep dictating across pauses until the user taps stop (the
  /// recognizer is restarted after each phrase).
  final bool continuousDictation;

  /// Continuous dictation pauses itself after this much silence.
  final int dictationSilenceSeconds;

  /// Hard cap on one continuous dictation session.
  final int dictationMaxMinutes;

  /// Mutes the recognizer's start/stop earcons while it restarts between
  /// phrases (best effort; see SpeechRecognitionBridge.kt). Opt-in and off
  /// by default: it mutes whole system streams.
  final bool muteRestartBeeps;

  /// The Chat View speaker toggle per session id, most recent last.
  final Map<String, bool> readAloudSessions;

  /// Talk mode sends what was said after this long a pause.
  final int talkSendSilenceSeconds;

  /// How much of each final answer is read aloud.
  final ReadAloudLength readAloudLength;

  /// How Chat View shows tool calls.
  final ToolActivity toolActivity;

  /// Whether Review opens by itself when a turn ends in Chat View.
  final ReviewOpens reviewOpens;

  /// The voice guide (Settings › Chat & Voice › Voice guide).
  final GuidePreferences guide;

  Duration get dictationSilence => Duration(seconds: dictationSilenceSeconds);
  Duration get dictationMaxSession => Duration(minutes: dictationMaxMinutes);

  /// Whether Chat View should read [sessionId] aloud.
  bool readAloudFor(String sessionId) =>
      readAloudSessions[sessionId] ?? readAloudByDefault;

  /// Remembers the speaker toggle for [sessionId], keeping only the most
  /// recent [maxRememberedSessions].
  VoicePreferences withSessionReadAloud(String sessionId, bool enabled) {
    final sessions = Map<String, bool>.of(readAloudSessions)
      ..remove(sessionId)
      ..[sessionId] = enabled;
    while (sessions.length > maxRememberedSessions) {
      sessions.remove(sessions.keys.first);
    }
    return copyWith(readAloudSessions: sessions);
  }

  /// The language to speak in, given the dictation language.
  String effectiveTtsLanguage(String dictationLanguage) =>
      ttsLanguage.isNotEmpty ? ttsLanguage : dictationLanguage;

  VoicePreferences copyWith({
    bool? readAloudByDefault,
    String? ttsLanguage,
    String? ttsVoice,
    double? ttsRate,
    double? ttsPitch,
    bool? continuousDictation,
    int? dictationSilenceSeconds,
    int? dictationMaxMinutes,
    bool? muteRestartBeeps,
    Map<String, bool>? readAloudSessions,
    int? talkSendSilenceSeconds,
    ReadAloudLength? readAloudLength,
    ToolActivity? toolActivity,
    ReviewOpens? reviewOpens,
    GuidePreferences? guide,
  }) {
    return VoicePreferences(
      readAloudByDefault: readAloudByDefault ?? this.readAloudByDefault,
      ttsLanguage: ttsLanguage ?? this.ttsLanguage,
      ttsVoice: ttsVoice ?? this.ttsVoice,
      ttsRate: (ttsRate ?? this.ttsRate).clamp(minRate, maxRate).toDouble(),
      ttsPitch: (ttsPitch ?? this.ttsPitch)
          .clamp(minPitch, maxPitch)
          .toDouble(),
      continuousDictation: continuousDictation ?? this.continuousDictation,
      dictationSilenceSeconds:
          (dictationSilenceSeconds ?? this.dictationSilenceSeconds).clamp(
            minSilenceSeconds,
            maxSilenceSeconds,
          ),
      dictationMaxMinutes: (dictationMaxMinutes ?? this.dictationMaxMinutes)
          .clamp(minMaxMinutes, maxMaxMinutes),
      muteRestartBeeps: muteRestartBeeps ?? this.muteRestartBeeps,
      readAloudSessions: readAloudSessions ?? this.readAloudSessions,
      talkSendSilenceSeconds:
          (talkSendSilenceSeconds ?? this.talkSendSilenceSeconds).clamp(
            minTalkSendSeconds,
            maxTalkSendSeconds,
          ),
      readAloudLength: readAloudLength ?? this.readAloudLength,
      toolActivity: toolActivity ?? this.toolActivity,
      reviewOpens: reviewOpens ?? this.reviewOpens,
      guide: guide ?? this.guide,
    );
  }

  /// JSON for storage. [includeSessions] is false for backups: the
  /// per-session toggles are device-local noise.
  Map<String, Object?> toJson({bool includeSessions = true}) => {
    'readAloudByDefault': readAloudByDefault,
    'ttsLanguage': ttsLanguage,
    'ttsVoice': ttsVoice,
    'ttsRate': ttsRate,
    'ttsPitch': ttsPitch,
    'continuousDictation': continuousDictation,
    'dictationSilenceSeconds': dictationSilenceSeconds,
    'dictationMaxMinutes': dictationMaxMinutes,
    'muteRestartBeeps': muteRestartBeeps,
    'talkSendSilenceSeconds': talkSendSilenceSeconds,
    'readAloudLength': readAloudLength.name,
    'toolActivity': toolActivity.name,
    'reviewOpens': reviewOpens.name,
    'guide': guide.toJson(),
    if (includeSessions) 'readAloudSessions': readAloudSessions,
  };

  /// Parses [toJson]; [fallback] supplies fields the map lacks (a backup
  /// restore keeps this device's per-session toggles).
  static VoicePreferences fromJson(
    Object? raw, {
    VoicePreferences fallback = defaults,
  }) {
    if (raw is! Map) {
      return fallback;
    }
    T pick<T>(String key, T current) {
      final value = raw[key];
      return value is T ? value : current;
    }

    double number(String key, double current) {
      final value = raw[key];
      return value is num ? value.toDouble() : current;
    }

    int integer(String key, int current) {
      final value = raw[key];
      return value is num ? value.round() : current;
    }

    T named<T extends Enum>(String key, List<T> values, T current) {
      final value = raw[key];
      for (final candidate in values) {
        if (candidate.name == value) return candidate;
      }
      return current;
    }

    final rawSessions = raw['readAloudSessions'];
    return fallback.copyWith(
      readAloudByDefault: pick(
        'readAloudByDefault',
        fallback.readAloudByDefault,
      ),
      ttsLanguage: pick('ttsLanguage', fallback.ttsLanguage).trim(),
      ttsVoice: pick('ttsVoice', fallback.ttsVoice).trim(),
      ttsRate: number('ttsRate', fallback.ttsRate),
      ttsPitch: number('ttsPitch', fallback.ttsPitch),
      continuousDictation: pick(
        'continuousDictation',
        fallback.continuousDictation,
      ),
      dictationSilenceSeconds: integer(
        'dictationSilenceSeconds',
        fallback.dictationSilenceSeconds,
      ),
      dictationMaxMinutes: integer(
        'dictationMaxMinutes',
        fallback.dictationMaxMinutes,
      ),
      muteRestartBeeps: pick('muteRestartBeeps', fallback.muteRestartBeeps),
      talkSendSilenceSeconds: integer(
        'talkSendSilenceSeconds',
        fallback.talkSendSilenceSeconds,
      ),
      readAloudLength: named(
        'readAloudLength',
        ReadAloudLength.values,
        fallback.readAloudLength,
      ),
      toolActivity: named(
        'toolActivity',
        ToolActivity.values,
        fallback.toolActivity,
      ),
      reviewOpens: named(
        'reviewOpens',
        ReviewOpens.values,
        fallback.reviewOpens,
      ),
      guide: raw['guide'] is Map
          ? GuidePreferences.fromJson(raw['guide'])
          : fallback.guide,
      readAloudSessions: rawSessions is Map
          ? {
              for (final entry in rawSessions.entries)
                if (entry.key is String && entry.value is bool)
                  entry.key as String: entry.value as bool,
            }
          : null,
    );
  }

  String encode() => jsonEncode(toJson());

  static VoicePreferences decode(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return defaults;
    }
    try {
      return fromJson(jsonDecode(raw));
    } catch (_) {
      return defaults;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is VoicePreferences && other.encode() == encode();

  @override
  int get hashCode => encode().hashCode;
}
