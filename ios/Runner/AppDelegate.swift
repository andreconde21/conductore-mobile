import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var speech: SpeechRecognitionBridge?
  private var textToSpeech: TextToSpeechBridge?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ConductoreVoice") {
      registerVoice(messenger: registrar.messenger())
    }
  }

  /// Dictation and read-aloud: the same channels as Android's MainActivity.
  private func registerVoice(messenger: FlutterBinaryMessenger) {
    let speech = SpeechRecognitionBridge(audio: VoiceAudioSession.shared)
    FlutterMethodChannel(name: SpeechRecognitionBridge.methodChannel, binaryMessenger: messenger)
      .setMethodCallHandler(speech.handle)
    FlutterEventChannel(name: SpeechRecognitionBridge.eventChannel, binaryMessenger: messenger)
      .setStreamHandler(speech)
    self.speech = speech

    let textToSpeech = TextToSpeechBridge(audio: VoiceAudioSession.shared)
    FlutterMethodChannel(name: TextToSpeechBridge.methodChannel, binaryMessenger: messenger)
      .setMethodCallHandler(textToSpeech.handle)
    FlutterEventChannel(name: TextToSpeechBridge.eventChannel, binaryMessenger: messenger)
      .setStreamHandler(textToSpeech)
    self.textToSpeech = textToSpeech
  }
}
