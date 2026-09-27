/// When the voice guide asks "Say yes" before acting.
enum GuideConfirm {
  /// Approvals, denials, prompts, trust and account switches.
  always('Always'),

  /// The same, except approving a request labelled low risk.
  skipLowRisk('Not for low-risk approvals');

  const GuideConfirm(this.label);

  final String label;
}

/// Settings › Chat & Voice › Voice guide. Stored inside the voice
/// preferences' JSON (key `guide`), so it travels with them in backups.
class GuidePreferences {
  const GuidePreferences({
    this.enabled = true,
    this.brainHostId = '',
    this.confirm = GuideConfirm.always,
    this.language = '',
    this.headsetWake = false,
  });

  static const defaults = GuidePreferences();

  /// The Guide button, tile and headset wake do something.
  final bool enabled;

  /// Saved host id of the machine that answers what the phone cannot
  /// match itself (`conductore-hostd guide`); empty picks the first
  /// connected machine whose companion has the command.
  final String brainHostId;

  final GuideConfirm confirm;

  /// BCP-47 tag the guide listens and speaks in; empty follows the
  /// dictation language.
  final String language;

  /// A long press on the headset's media button starts the guide.
  final bool headsetWake;

  GuidePreferences copyWith({
    bool? enabled,
    String? brainHostId,
    GuideConfirm? confirm,
    String? language,
    bool? headsetWake,
  }) => GuidePreferences(
    enabled: enabled ?? this.enabled,
    brainHostId: brainHostId ?? this.brainHostId,
    confirm: confirm ?? this.confirm,
    language: language ?? this.language,
    headsetWake: headsetWake ?? this.headsetWake,
  );

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'brainHostId': brainHostId,
    'confirm': confirm.name,
    'language': language,
    'headsetWake': headsetWake,
  };

  static GuidePreferences fromJson(Object? raw) {
    if (raw is! Map) return defaults;
    T pick<T>(String key, T current) {
      final value = raw[key];
      return value is T ? value : current;
    }

    final confirmName = raw['confirm'];
    return GuidePreferences(
      enabled: pick('enabled', defaults.enabled),
      brainHostId: pick('brainHostId', defaults.brainHostId).trim(),
      confirm:
          GuideConfirm.values
              .where((value) => value.name == confirmName)
              .firstOrNull ??
          defaults.confirm,
      language: pick('language', defaults.language).trim(),
      headsetWake: pick('headsetWake', defaults.headsetWake),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is GuidePreferences &&
      other.enabled == enabled &&
      other.brainHostId == brainHostId &&
      other.confirm == confirm &&
      other.language == language &&
      other.headsetWake == headsetWake;

  @override
  int get hashCode =>
      Object.hash(enabled, brainHostId, confirm, language, headsetWake);
}
