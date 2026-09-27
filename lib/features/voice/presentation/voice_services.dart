import 'package:conduit/core/platform_features.dart';
import 'package:conduit/features/voice/data/platform_speech_recognizer.dart';
import 'package:conduit/features/voice/data/platform_text_to_speech.dart';
import 'package:conduit/features/voice/domain/speech_recognizer.dart';
import 'package:conduit/features/voice/domain/text_to_speech.dart';
import 'package:flutter/widgets.dart';

/// The app's one speech recognizer and one text-to-speech engine.
///
/// The platform side has one event channel each, and a channel keeps a
/// single Dart handler: a second `receiveBroadcastStream` takes the events
/// away from the first listener, and any cancel clears them for both. So
/// every page (Chat View, the terminal, Settings) and the voice guide use
/// these instances; their controllers still listen one at a time (see
/// DictationController).
class VoiceServices {
  const VoiceServices({this.recognizer, this.tts});

  /// The platform's engines, or null where the platform has none.
  factory VoiceServices.platform() => VoiceServices(
    recognizer: PlatformFeatures.dictation ? PlatformSpeechRecognizer() : null,
    tts: PlatformFeatures.textToSpeech ? PlatformTextToSpeech() : null,
  );

  final SpeechRecognizer? recognizer;
  final TextToSpeech? tts;
}

/// Makes [VoiceServices] reachable from every route.
class VoiceServicesScope extends InheritedWidget {
  const VoiceServicesScope({
    required this.services,
    required super.child,
    super.key,
  });

  final VoiceServices services;

  /// Safe in initState: it does not register a dependency.
  static VoiceServices? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<VoiceServicesScope>()?.services;

  @override
  bool updateShouldNotify(VoiceServicesScope oldWidget) =>
      services != oldWidget.services;
}
