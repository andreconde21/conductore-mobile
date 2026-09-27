import AVFoundation
import Flutter
import UIKit

/// Bridges AVSpeechSynthesizer to Dart (Chat View "Read replies aloud"),
/// with the same contract as the Android TextToSpeechBridge.kt. Every
/// system voice runs on the device; nothing leaves the phone.
///
/// Method channel (`conduit/tts`):
///  - `isAvailable` -> Bool, whether any voice is installed.
///  - `voices` {language?} -> [{id, name, locale, quality}] for the
///    language (all when null). `id` is the voice identifier.
///  - `speak` {text, id, language?, voice?} -> nil. Queues behind whatever
///    is playing (AVSpeechSynthesizer queues natively); only `stop` cuts.
///  - `stop` -> nil, stops at once and flushes the queue.
///  - `setRate` {rate}, `setPitch` {pitch} -> nil, Android's 1.0 = normal.
///  - `isInteractive` -> Bool, whether the app is in the foreground.
///
/// Event channel (`conduit/tts_events`) emits maps:
///  - {type: "start" | "done" | "stopped", id}
///  - {type: "error", id, message}
///  - {type: "paused", id, offset} when a call, Siri or unplugged
///    headphones cut the audio: the utterance stopped near UTF-16 character
///    `offset` (from willSpeakRangeOfSpeechString); {type: "resumed"} when
///    the call ended with shouldResume or the headphones came back, and
///    {type: "interrupted"} when an interruption ended without it.
///
/// iOS cannot tell the lock screen from another app in front, so
/// `isInteractive` is false whenever the app is not active. Speech goes on
/// in the background (UIBackgroundModes audio) only while utterances keep
/// coming; the app is suspended a few seconds after the last one.
final class TextToSpeechBridge: NSObject, FlutterStreamHandler,
  AVSpeechSynthesizerDelegate
{
  static let methodChannel = "conduit/tts"
  static let eventChannel = "conduit/tts_events"

  private let synthesizer = AVSpeechSynthesizer()
  private let audio: VoiceAudioSession
  private var events: FlutterEventSink?
  private var rate: Float = 1
  private var pitch: Float = 1
  /// Dart ids of the utterances queued or playing.
  private var ids: [ObjectIdentifier: String] = [:]
  private var current: AVSpeechUtterance?
  private var currentId = ""
  private var spokenUpTo = 0
  private var paused = false
  private var pausedByRoute = false

  init(audio: VoiceAudioSession) {
    self.audio = audio
    super.init()
    synthesizer.delegate = self
    let center = NotificationCenter.default
    center.addObserver(
      self,
      selector: #selector(onInterruption(_:)),
      name: AVAudioSession.interruptionNotification,
      object: nil
    )
    center.addObserver(
      self,
      selector: #selector(onRouteChange(_:)),
      name: AVAudioSession.routeChangeNotification,
      object: nil
    )
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "isAvailable":
      result(!AVSpeechSynthesisVoice.speechVoices().isEmpty)
    case "voices":
      result(voices(language: args["language"] as? String))
    case "speak":
      speak(
        args["text"] as? String ?? "",
        id: args["id"] as? String ?? "",
        language: args["language"] as? String,
        voice: args["voice"] as? String
      )
      result(nil)
    case "stop":
      stop()
      result(nil)
    case "setRate":
      rate = Float((args["rate"] as? NSNumber)?.doubleValue ?? 1)
      result(nil)
    case "setPitch":
      pitch = Float((args["pitch"] as? NSNumber)?.doubleValue ?? 1)
      result(nil)
    case "isInteractive":
      result(UIApplication.shared.applicationState == .active)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  func onListen(withArguments arguments: Any?, eventSink sink: @escaping FlutterEventSink)
    -> FlutterError?
  {
    events = sink
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    events = nil
    return nil
  }

  private func speak(_ text: String, id: String, language: String?, voice: String?) {
    do {
      try audio.setSpeaking(true)
    } catch {
      // A call is still holding the audio: report it like Android's
      // failed speak, the Dart side moves on.
      emit(["type": "error", "id": id, "message": "Could not speak (audio busy)."])
      return
    }
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = pickVoice(language: language, identifier: voice)
    utterance.rate = TextToSpeechBridge.iosRate(rate)
    utterance.pitchMultiplier = min(max(pitch, 0.5), 2)
    utterance.volume = 1
    ids[ObjectIdentifier(utterance)] = id
    paused = false
    pausedByRoute = false
    synthesizer.speak(utterance)
  }

  private func stop() {
    paused = false
    pausedByRoute = false
    // Only the playing utterance reports didCancel (as "stopped").
    ids = current.map { [ObjectIdentifier($0): currentId] } ?? [:]
    synthesizer.stopSpeaking(at: .immediate)
    releaseIfIdle()
  }

  /// Android's rate is a multiplier (Dart sends 0.5-2.0, 1 = normal);
  /// AVSpeechUtterance's rate runs 0-1 with 0.5 as normal and 1 very fast
  /// (about 3x), so the fast half is compressed.
  private static func iosRate(_ rate: Float) -> Float {
    let normal = AVSpeechUtteranceDefaultSpeechRate
    let value: Float
    if rate <= 1 {
      value = normal * max(rate, 0.25)
    } else {
      value = normal + (AVSpeechUtteranceMaximumSpeechRate - normal) * (rate - 1) * 0.5
    }
    return min(max(value, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
  }

  // MARK: Voices

  private func usable() -> [AVSpeechSynthesisVoice] {
    AVSpeechSynthesisVoice.speechVoices().filter { voice in
      if #available(iOS 17.0, *) {
        return !voice.voiceTraits.contains(.isNoveltyVoice)
      }
      return true
    }
  }

  private func voices(language: String?) -> [[String: Any]] {
    let wanted = language.flatMap { $0.isEmpty ? nil : $0 }
    return usable()
      .filter { wanted == nil || Self.sameLanguage($0.language, wanted!) }
      .sorted {
        if $0.language != $1.language { return $0.language < $1.language }
        if $0.quality != $1.quality { return $0.quality.rawValue > $1.quality.rawValue }
        return $0.name < $1.name
      }
      .map { voice -> [String: Any] in
        [
          "id": voice.identifier,
          "name": voice.name,
          "locale": voice.language,
          "quality": voice.quality.rawValue,
        ]
      }
  }

  private func pickVoice(language: String?, identifier: String?) -> AVSpeechSynthesisVoice? {
    if let identifier = identifier, !identifier.isEmpty,
      let chosen = AVSpeechSynthesisVoice(identifier: identifier)
    {
      return chosen
    }
    let tag = language.flatMap { $0.isEmpty ? nil : $0 }
      ?? AVSpeechSynthesisVoice.currentLanguageCode()
    let region = Self.parts(tag).region
    let best = usable()
      .filter { Self.sameLanguage($0.language, tag) }
      .max { a, b in
        let aRegion = Self.parts(a.language).region == region
        let bRegion = Self.parts(b.language).region == region
        if aRegion != bRegion { return !aRegion }
        return a.quality.rawValue < b.quality.rawValue
      }
    return best ?? AVSpeechSynthesisVoice(language: tag)
  }

  private static func parts(_ tag: String) -> (language: String, region: String) {
    let pieces = tag.split(whereSeparator: { $0 == "-" || $0 == "_" }).map {
      String($0).lowercased()
    }
    return (pieces.first ?? "", pieces.count > 1 ? pieces[pieces.count - 1] : "")
  }

  private static func sameLanguage(_ a: String, _ b: String) -> Bool {
    parts(a).language == parts(b).language
  }

  // MARK: Synthesizer delegate (main thread)

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
    let id = ids[ObjectIdentifier(utterance)] ?? ""
    current = utterance
    currentId = id
    spokenUpTo = 0
    emit(["type": "start", "id": id])
  }

  func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer,
    willSpeakRangeOfSpeechString characterRange: NSRange,
    utterance: AVSpeechUtterance
  ) {
    if utterance === current { spokenUpTo = characterRange.location }
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    emit(["type": "done", "id": finished(utterance)])
    releaseIfIdle()
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    emit(["type": "stopped", "id": finished(utterance)])
    releaseIfIdle()
  }

  private func finished(_ utterance: AVSpeechUtterance) -> String {
    let id = ids.removeValue(forKey: ObjectIdentifier(utterance)) ?? ""
    if utterance === current { current = nil }
    return id
  }

  /// Nothing queued or playing: let other audio come back. A pause
  /// releases too, so a long call never leaves music ducked.
  private func releaseIfIdle() {
    if ids.isEmpty || paused { try? audio.setSpeaking(false) }
  }

  // MARK: Audio interruptions

  /// Cuts the playing utterance; Dart replays it from the sentence it cut.
  private func pause() {
    guard current != nil, !paused else { return }
    paused = true
    emit(["type": "paused", "id": currentId, "offset": spokenUpTo])
    ids = current.map { [ObjectIdentifier($0): currentId] } ?? [:]
    synthesizer.stopSpeaking(at: .immediate)
  }

  private func resume() {
    guard paused else { return }
    paused = false
    pausedByRoute = false
    emit(["type": "resumed"])
  }

  @objc private func onInterruption(_ notification: Notification) {
    guard let info = notification.userInfo,
      let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
      let type = AVAudioSession.InterruptionType(rawValue: raw)
    else { return }
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      switch type {
      case .began:
        // A call, Siri, an alarm, or another app's non-mixing audio.
        self.pause()
      case .ended:
        guard self.paused, !self.pausedByRoute else { return }
        let options = (info[AVAudioSessionInterruptionOptionKey] as? UInt)
          .map { AVAudioSession.InterruptionOptions(rawValue: $0) } ?? []
        if options.contains(.shouldResume) {
          self.resume()
        } else {
          self.paused = false
          self.emit(["type": "interrupted"])
        }
      @unknown default:
        break
      }
    }
  }

  @objc private func onRouteChange(_ notification: Notification) {
    guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
      let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
    else { return }
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      switch reason {
      case .oldDeviceUnavailable:
        // Headphones unplugged or AirPods taken out: never go on out loud.
        guard self.current != nil, !self.paused else { return }
        self.pausedByRoute = true
        self.pause()
      case .newDeviceAvailable:
        if self.pausedByRoute { self.resume() }
      default:
        break
      }
    }
  }

  private func emit(_ event: [String: Any]) {
    events?(event)
  }
}
