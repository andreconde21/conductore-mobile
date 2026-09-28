import 'package:conduit/features/talkbawt/domain/talkbawt_link.dart';

/// How "send to another machine's agent" travels (André, 2026-09-27).
enum TalkbawtRelayMode {
  /// The phone reads from one machine and types into the other: nothing
  /// leaves your machines. The default.
  phone(
    'Phone relay',
    'The phone carries the message between your machines. Nothing leaves '
        'them, but both must be reachable from the phone.',
  ),

  /// Through a short-lived, passphrase-protected Talkbawt handoff.
  talkbawt(
    'Talkbawt',
    'The message goes through your Talkbawt server as a one-reader, '
        'passphrase-protected handoff that expires in an hour.',
  );

  const TalkbawtRelayMode(this.label, this.description);

  final String label;
  final String description;

  static TalkbawtRelayMode parse(Object? raw) =>
      raw == 'talkbawt' ? TalkbawtRelayMode.talkbawt : TalkbawtRelayMode.phone;
}

/// The Talkbawt settings (Settings › Agents › Talkbawt).
class TalkbawtSettings {
  const TalkbawtSettings({
    this.server = defaultTalkbawtServer,
    this.firstUseAsked = false,
    this.relay = TalkbawtRelayMode.phone,
    this.from = '',
  });

  /// The server's origin; always valid (see [talkbawtServerOrigin]).
  final String server;

  /// Whether the first-use question (which server) was answered.
  final bool firstUseAsked;
  final TalkbawtRelayMode relay;

  /// The default "from" label ("André via Conductore"); empty: the agent's
  /// name and "via Conductore".
  final String from;

  TalkbawtSettings copyWith({
    String? server,
    bool? firstUseAsked,
    TalkbawtRelayMode? relay,
    String? from,
  }) => TalkbawtSettings(
    server: server ?? this.server,
    firstUseAsked: firstUseAsked ?? this.firstUseAsked,
    relay: relay ?? this.relay,
    from: from ?? this.from,
  );

  Map<String, Object?> toJson() => {
    'server': server,
    'firstUseAsked': firstUseAsked,
    'relay': relay.name,
    'from': from,
  };

  static TalkbawtSettings fromJson(Object? raw) {
    if (raw is! Map) return const TalkbawtSettings();
    var server = defaultTalkbawtServer;
    if (raw['server'] case final String s) {
      try {
        server = talkbawtServerOrigin(s);
      } on TalkbawtAddressError {
        // A bad stored value falls back to the default.
      }
    }
    return TalkbawtSettings(
      server: server,
      firstUseAsked: raw['firstUseAsked'] == true,
      relay: TalkbawtRelayMode.parse(raw['relay']),
      from: raw['from'] is String ? raw['from'] as String : '',
    );
  }
}

/// A passphrase of four words and a number, for reading aloud or typing
/// on another device ("amber-canal-otter-quiet-47"). [random] picks
/// indices (a secure source in the app).
String generateTalkbawtPassphrase(int Function(int max) random) {
  final words = [
    for (var i = 0; i < 4; i++)
      _passphraseWords[random(_passphraseWords.length)],
  ];
  return '${words.join('-')}-${10 + random(90)}';
}

const _passphraseWords = [
  'amber', 'anchor', 'apple', 'arrow', 'aspen', 'badge', 'basil', 'beacon', //
  'birch', 'bison', 'blaze', 'bloom', 'brook', 'cabin', 'cactus', 'canal',
  'candle', 'canyon', 'cedar', 'chalk', 'cherry', 'cider', 'cliff', 'clover',
  'cobalt', 'comet', 'coral', 'cotton', 'crane', 'crystal', 'daisy', 'delta',
  'denim', 'desert', 'dune', 'eagle', 'ember', 'falcon', 'fern', 'fjord',
  'flint', 'forest', 'fossil', 'garnet', 'glacier', 'granite', 'harbor',
  'hazel', 'heron', 'honey', 'indigo', 'island', 'ivory', 'jasper', 'juniper',
  'kettle', 'lagoon', 'lantern', 'lemon', 'lilac', 'linen', 'lotus', 'maple',
  'marble', 'meadow', 'mint', 'monsoon', 'moss', 'nectar', 'nickel', 'oasis',
  'ocean', 'olive', 'onyx', 'orbit', 'orchid', 'otter', 'pebble', 'pepper',
  'pine', 'planet', 'plum', 'prairie', 'quartz', 'quiet', 'raven', 'reef',
  'river', 'saffron', 'sage', 'salt', 'sierra', 'silver', 'spruce', 'stone',
  'summit', 'thistle', 'thunder', 'tidal', 'topaz', 'tulip', 'tundra',
  'velvet', 'violet', 'walnut', 'willow', 'winter', 'yarrow', 'zephyr',
];
