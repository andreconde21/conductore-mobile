import 'package:conduit/features/voice/domain/text_to_speech.dart';
import 'package:flutter/services.dart';

/// Android implementation over the `conduit/tts` method channel and the
/// `conduit/tts_events` event channel (see TextToSpeechBridge.kt).
///
/// Without a native handler (iOS, tests) it reports itself unavailable and
/// every call is a harmless no-op.
class PlatformTextToSpeech implements TextToSpeech {
  PlatformTextToSpeech({MethodChannel? methods, EventChannel? events})
    : _methods = methods ?? const MethodChannel('conduit/tts'),
      _eventChannel = events ?? const EventChannel('conduit/tts_events');

  final MethodChannel _methods;
  final EventChannel _eventChannel;
  Stream<TtsEvent>? _events;

  @override
  Future<bool> isAvailable() async {
    try {
      return await _methods.invokeMethod<bool>('isAvailable') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<List<TtsVoice>> voices({String language = ''}) async {
    try {
      final raw = await _methods.invokeMethod<List<Object?>>('voices', {
        'language': language.isEmpty ? null : language,
      });
      return [
        for (final entry in raw ?? const <Object?>[]) ?TtsVoice.fromMap(entry),
      ];
    } on MissingPluginException {
      return const [];
    }
  }

  @override
  Future<void> speak(
    String text, {
    required String id,
    String language = '',
    String voice = '',
  }) => _call('speak', {
    'text': text,
    'id': id,
    'language': language.isEmpty ? null : language,
    'voice': voice.isEmpty ? null : voice,
  });

  @override
  Future<void> stop() => _call('stop');

  @override
  Future<void> setRate(double rate) => _call('setRate', {'rate': rate});

  @override
  Future<void> setPitch(double pitch) => _call('setPitch', {'pitch': pitch});

  @override
  Future<bool> isInteractive() async {
    try {
      return await _methods.invokeMethod<bool>('isInteractive') ?? true;
    } on MissingPluginException {
      return true;
    }
  }

  @override
  Stream<TtsEvent> get events {
    return _events ??= _shared.putIfAbsent(
      _eventChannel,
      () => _eventChannel
          .receiveBroadcastStream()
          .map(TtsEvent.fromMap)
          .where((event) => event != null)
          .cast<TtsEvent>(),
    );
  }

  /// One stream per event channel for every instance: a platform event
  /// channel has a single Dart handler, so a second
  /// `receiveBroadcastStream` would take the events from the first
  /// listener, and cancelling either would silence both (a chat's own
  /// voice and the voice guide share the platform side).
  static final Map<EventChannel, Stream<TtsEvent>> _shared = {};

  Future<void> _call(String method, [Object? arguments]) async {
    try {
      await _methods.invokeMethod<void>(method, arguments);
    } on MissingPluginException {
      // No native side: nothing to speak or stop.
    }
  }
}
