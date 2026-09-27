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
      registerShare(messenger: registrar.messenger())
    }
  }

  /// Chat View's message "Share": the system activity sheet for text.
  private func registerShare(messenger: FlutterBinaryMessenger) {
    FlutterMethodChannel(name: "conduit/share_text", binaryMessenger: messenger)
      .setMethodCallHandler { call, result in
        guard call.method == "share",
          let args = call.arguments as? [String: Any],
          let text = args["text"] as? String
        else {
          result(FlutterMethodNotImplemented)
          return
        }
        let root = UIApplication.shared.connectedScenes
          .compactMap { scene -> UIViewController? in
            // keyWindow on a scene needs iOS 15; the app supports iOS 13.
            (scene as? UIWindowScene)?.windows.first(where: { $0.isKeyWindow })?.rootViewController
          }
          .first
        guard var top = root else {
          result(FlutterError(code: "no_window", message: "Nothing to share from", details: nil))
          return
        }
        while let presented = top.presentedViewController { top = presented }
        let sheet = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        if let subject = args["subject"] as? String {
          sheet.setValue(subject, forKey: "subject")
        }
        // iPad: a popover needs an anchor.
        if let popover = sheet.popoverPresentationController {
          popover.sourceView = top.view
          popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
          popover.permittedArrowDirections = []
        }
        top.present(sheet, animated: true)
        result(nil)
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
