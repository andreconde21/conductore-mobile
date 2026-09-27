import 'package:conduit/features/voice/domain/speech_event.dart';
import 'package:conduit/features/voice/domain/speech_recognizer.dart';
import 'package:flutter/services.dart';

/// Android implementation over the `conduit/speech` method channel and the
/// `conduit/speech_events` event channel (see SpeechRecognitionBridge.kt).
///
/// Without a native handler (iOS, tests) the recognizer reports itself as
/// unavailable and every call is a harmless no-op.
class PlatformSpeechRecognizer implements SpeechRecognizer {
  PlatformSpeechRecognizer({MethodChannel? methods, EventChannel? events})
    : _methods = methods ?? const MethodChannel('conduit/speech'),
      _eventChannel = events ?? const EventChannel('conduit/speech_events');

  final MethodChannel _methods;
  final EventChannel _eventChannel;
  Stream<SpeechEvent>? _events;

  @override
  Future<bool> isAvailable() => _bool('isAvailable');

  @override
  Future<bool> hasPermission() => _bool('hasPermission');

  @override
  Future<bool> requestPermission() => _bool('requestPermission');

  @override
  Future<void> start({
    String? language,
    SpeechListenOptions options = const SpeechListenOptions(),
  }) => _call('start', {
    'language': language == null || language.isEmpty ? null : language,
    ...options.toMap(),
  });

  @override
  Future<bool> openSettings() => _bool('openSettings');

  @override
  Future<void> stop() => _call('stop');

  @override
  Future<void> cancel() => _call('cancel');

  @override
  Stream<SpeechEvent> get events {
    return _events ??= _shared.putIfAbsent(
      _eventChannel,
      () => _eventChannel
          .receiveBroadcastStream()
          .map(SpeechEvent.fromMap)
          .where((event) => event != null)
          .cast<SpeechEvent>(),
    );
  }

  /// One stream per event channel for every instance: a platform event
  /// channel has a single Dart handler, so a second
  /// `receiveBroadcastStream` would take the events from the first
  /// listener, and cancelling either would silence both (a chat's own
  /// voice and the voice guide share the platform side).
  static final Map<EventChannel, Stream<SpeechEvent>> _shared = {};

  Future<bool> _bool(String method) async {
    try {
      return await _methods.invokeMethod<bool>(method) ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<void> _call(String method, [Object? arguments]) async {
    try {
      await _methods.invokeMethod<void>(method, arguments);
    } on MissingPluginException {
      // No native side: nothing to start or stop.
    }
  }
}
