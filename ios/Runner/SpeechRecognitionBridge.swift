import AVFoundation
import Flutter
import Speech
import UIKit

/// Bridges SFSpeechRecognizer (fed by AVAudioEngine) to Dart, with the
/// same contract as the Android SpeechRecognitionBridge.kt.
///
/// Method channel (`conduit/speech`):
///  - `isAvailable` -> Bool, whether the device recognizes any language.
///  - `hasPermission` -> Bool, speech recognition AND microphone granted.
///  - `requestPermission` -> Bool, asks for both (speech first).
///  - `openSettings` -> Bool, opens this app's page in Settings.
///  - `start` {language?, continuous?, restart?, muteBeeps?,
///    completeSilenceMillis?, ...} -> nil, begins a phrase.
///  - `stop` -> nil, ends audio capture; the final result follows.
///  - `cancel` -> nil, drops the session without a result.
///
/// Event channel (`conduit/speech_events`) emits the Android maps:
/// status ready/listening/ended, level 0..1, partial, result, and error
/// with Android's SpeechRecognizer.ERROR_* codes (see [errorCode]).
///
/// Recognition runs on the device when the recognizer supports it for the
/// language (requiresOnDeviceRecognition); if the on-device model fails
/// before hearing anything, the phrase is retried once with Apple's server
/// recognizer, like Android's retry without the on-device engine.
///
/// SFSpeechRecognizer never ends a phrase on its own, so silence is timed
/// here: after speech, a pause of completeSilenceMillis (continuous) or
/// 1.5 s ends the phrase; with no speech at all the phrase ends with
/// ERROR_SPEECH_TIMEOUT after 8 s. A continuous session keeps the audio
/// engine running between phrases (a restart only starts a new task);
/// there are no earcons on iOS, so muteBeeps is ignored.
final class SpeechRecognitionBridge: NSObject, FlutterStreamHandler {
  static let methodChannel = "conduit/speech"
  static let eventChannel = "conduit/speech_events"

  private let audio: VoiceAudioSession
  private var events: FlutterEventSink?
  private var engine: AVAudioEngine?
  private var recognizer: SFSpeechRecognizer?
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  /// Bumped for each phrase so late callbacks of an old task are ignored.
  private var phrase = 0
  private var continuous = false
  private var completeSilence: TimeInterval = 1.5
  private var onDevice = false
  private var retriedWithoutOnDevice = false
  private var heardSpeech = false
  private var stopping = false
  private var lastPartial = ""
  private var timer: DispatchWorkItem?
  /// Whether this bridge holds the audio session for recording.
  private var holdsAudio = false

  /// The request the audio tap feeds, read on the audio thread.
  private let tapLock = NSLock()
  private var tapRequest: SFSpeechAudioBufferRecognitionRequest?
  private var lastLevelAt: TimeInterval = 0

  init(audio: VoiceAudioSession) {
    self.audio = audio
    super.init()
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(onInterruption(_:)),
      name: AVAudioSession.interruptionNotification,
      object: nil
    )
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "isAvailable":
      result(!SFSpeechRecognizer.supportedLocales().isEmpty)
    case "hasPermission":
      result(hasPermission())
    case "requestPermission":
      requestPermission(result)
    case "openSettings":
      guard let url = URL(string: UIApplication.openSettingsURLString) else {
        result(false)
        return
      }
      UIApplication.shared.open(url, options: [:]) { opened in result(opened) }
    case "start":
      let millis = (args["completeSilenceMillis"] as? NSNumber)?.doubleValue
      start(
        language: args["language"] as? String,
        continuous: args["continuous"] as? Bool ?? false,
        restart: args["restart"] as? Bool ?? false,
        completeSilence: millis.map { $0 / 1000 }
      )
      result(nil)
    case "stop":
      stop()
      result(nil)
    case "cancel":
      cancel()
      result(nil)
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

  // MARK: Permissions

  private var microphoneGranted: Bool {
    if #available(iOS 17.0, *) {
      return AVAudioApplication.shared.recordPermission == .granted
    }
    return AVAudioSession.sharedInstance().recordPermission == .granted
  }

  private func hasPermission() -> Bool {
    SFSpeechRecognizer.authorizationStatus() == .authorized && microphoneGranted
  }

  private func requestPermission(_ result: @escaping FlutterResult) {
    SFSpeechRecognizer.requestAuthorization { status in
      DispatchQueue.main.async {
        guard status == .authorized else {
          result(false)
          return
        }
        let done: (Bool) -> Void = { granted in
          DispatchQueue.main.async { result(granted) }
        }
        if #available(iOS 17.0, *) {
          AVAudioApplication.requestRecordPermission(completionHandler: done)
        } else {
          AVAudioSession.sharedInstance().requestRecordPermission(done)
        }
      }
    }
  }

  // MARK: Session

  private func start(
    language: String?, continuous: Bool, restart: Bool, completeSilence: TimeInterval?
  ) {
    guard hasPermission() else {
      emitError(Self.errorInsufficientPermissions)
      return
    }
    if restart && continuous, let engine = engine, engine.isRunning,
      recognizer != nil
    {
      // Next phrase of a continuous session: the engine keeps running.
      startTask()
      emit(["type": "status", "value": "ready"])
      return
    }
    cancel()
    guard let recognizer = Self.recognizer(for: language) else {
      emitError(Self.errorLanguageNotSupported)
      return
    }
    guard recognizer.isAvailable else {
      // Offline, and this language has no on-device model.
      emitError(recognizer.supportsOnDeviceRecognition ? Self.errorUnavailable : Self.errorNetwork)
      return
    }
    self.recognizer = recognizer
    self.continuous = continuous
    self.completeSilence = continuous ? (completeSilence ?? 2) : 1.5
    stopping = false
    retriedWithoutOnDevice = false
    onDevice = recognizer.supportsOnDeviceRecognition
    do {
      try audio.setRecording(true)
      holdsAudio = true
      try startEngine()
    } catch {
      teardown()
      emitError(Self.errorAudio)
      return
    }
    startTask()
    emit(["type": "status", "value": "ready"])
  }

  private func startEngine() throws {
    let engine = AVAudioEngine()
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else {
      throw NSError(domain: "conduit.speech", code: 1)
    }
    input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
      self?.receive(buffer)
    }
    engine.prepare()
    try engine.start()
    self.engine = engine
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(onConfigurationChange(_:)),
      name: .AVAudioEngineConfigurationChange,
      object: engine
    )
  }

  private func startTask() {
    guard let recognizer = recognizer else { return }
    phrase += 1
    let current = phrase
    task?.cancel()
    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    request.taskHint = .dictation
    request.requiresOnDeviceRecognition = onDevice
    if #available(iOS 16.0, *) { request.addsPunctuation = true }
    self.request = request
    heardSpeech = false
    lastPartial = ""
    setTapRequest(request)
    task = recognizer.recognitionTask(with: request) { [weak self] result, error in
      // Delivered on the recognizer's queue, the main queue by default.
      self?.onRecognition(current, result: result, error: error)
    }
    arm(Self.noSpeechTimeout) { [weak self] in self?.noSpeech() }
  }

  /// Audio thread: feeds the recognizer and reports loudness 10x a second.
  private func receive(_ buffer: AVAudioPCMBuffer) {
    tapLock.lock()
    let request = tapRequest
    tapLock.unlock()
    guard let request = request else { return }
    request.append(buffer)
    let now = ProcessInfo.processInfo.systemUptime
    guard now - lastLevelAt >= 0.1, let samples = buffer.floatChannelData?[0] else { return }
    lastLevelAt = now
    let count = Int(buffer.frameLength)
    guard count > 0 else { return }
    var sum: Float = 0
    for index in 0..<count { sum += samples[index] * samples[index] }
    let decibels = 20 * log10(max(sqrt(sum / Float(count)), 1e-7))
    // About -50 dB (a quiet room) to -10 dB (close, loud speech).
    let level = Double(min(max((decibels + 50) / 40, 0), 1))
    DispatchQueue.main.async { [weak self] in
      guard let self = self, self.task != nil else { return }
      self.emit(["type": "level", "value": level])
    }
  }

  private func setTapRequest(_ request: SFSpeechAudioBufferRecognitionRequest?) {
    tapLock.lock()
    tapRequest = request
    tapLock.unlock()
  }

  private func onRecognition(_ current: Int, result: SFSpeechRecognitionResult?, error: Error?) {
    guard current == phrase else { return }
    if let result = result {
      let text = result.bestTranscription.formattedString
      if result.isFinal {
        finishPhrase(text)
        return
      }
      guard text != lastPartial else { return }
      if !heardSpeech {
        heardSpeech = true
        emit(["type": "status", "value": "listening"])
      }
      lastPartial = text
      emit(["type": "partial", "text": text])
      arm(completeSilence) { [weak self] in self?.endOfSpeech() }
      return
    }
    guard let error = error else { return }
    let code = Self.errorCode(error)
    if !lastPartial.isEmpty && (stopping || code == Self.errorNoMatch) {
      // Ended after speech: keep what was heard.
      finishPhrase(lastPartial)
      return
    }
    if onDevice && !retriedWithoutOnDevice && !heardSpeech && !stopping
      && code != Self.errorNoMatch && code != Self.errorClient
    {
      // The on-device model may lack this language: once more, via Apple.
      retriedWithoutOnDevice = true
      onDevice = false
      startTask()
      return
    }
    endPhrase()
    emitError(code)
  }

  /// A pause after speech: stop feeding audio; the final result follows.
  private func endOfSpeech() {
    guard task != nil else { return }
    emit(["type": "status", "value": "ended"])
    setTapRequest(nil)
    request?.endAudio()
    let current = phrase
    arm(Self.finalResultTimeout) { [weak self] in
      guard let self = self, self.phrase == current else { return }
      self.finishPhrase(self.lastPartial)
    }
  }

  private func noSpeech() {
    guard task != nil, !heardSpeech else { return }
    endPhrase()
    emitError(Self.errorSpeechTimeout)
  }

  private func finishPhrase(_ text: String) {
    endPhrase()
    emit(["type": "result", "text": text])
  }

  /// Retires the phrase's task. The engine stays up between the phrases
  /// of a continuous session unless it is stopping (or lost its input).
  private func endPhrase() {
    phrase += 1
    timer?.cancel()
    timer = nil
    setTapRequest(nil)
    task?.cancel()
    task = nil
    request = nil
    if !continuous || stopping || !(engine?.isRunning ?? false) { teardown() }
  }

  private func stop() {
    guard task != nil else {
      teardown()
      return
    }
    stopping = true
    engine?.stop()
    endOfSpeech()
  }

  private func cancel() {
    phrase += 1
    task?.cancel()
    teardown()
  }

  private func teardown() {
    timer?.cancel()
    timer = nil
    setTapRequest(nil)
    task = nil
    request = nil
    removeEngine()
    if holdsAudio {
      holdsAudio = false
      try? audio.setRecording(false)
    }
  }

  private func removeEngine() {
    guard let engine = engine else { return }
    NotificationCenter.default.removeObserver(
      self, name: .AVAudioEngineConfigurationChange, object: engine)
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    self.engine = nil
  }

  /// A call took the microphone: end the phrase with what was heard.
  @objc private func onInterruption(_ notification: Notification) {
    let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
    guard raw == AVAudioSession.InterruptionType.began.rawValue else { return }
    DispatchQueue.main.async { [weak self] in self?.endForLostAudio() }
  }

  /// The input changed (AirPods connected, a headset unplugged) and the
  /// engine stopped. Before any speech the phrase quietly starts over on
  /// the new input; after speech it ends with what was heard.
  @objc private func onConfigurationChange(_ notification: Notification) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self, self.engine != nil else { return }
      guard self.task != nil, !self.heardSpeech, !self.stopping else {
        self.endForLostAudio()
        return
      }
      self.removeEngine()
      do {
        try self.startEngine()
      } catch {
        self.endPhrase()
        self.emitError(Self.errorAudio)
        return
      }
      self.startTask()
    }
  }

  private func endForLostAudio() {
    guard engine != nil else { return }
    stopping = true
    if task != nil {
      engine?.stop()
      endOfSpeech()
    } else {
      teardown()
    }
  }

  private func arm(_ seconds: TimeInterval, _ action: @escaping () -> Void) {
    timer?.cancel()
    let item = DispatchWorkItem(block: action)
    timer = item
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
  }

  // MARK: Helpers

  /// The recognizer for a BCP-47 tag (the device language when empty),
  /// falling back to another region of the same language.
  private static func recognizer(for language: String?) -> SFSpeechRecognizer? {
    guard let tag = language, !tag.isEmpty else { return SFSpeechRecognizer() }
    if let exact = SFSpeechRecognizer(locale: Locale(identifier: tag)) { return exact }
    let wanted = base(tag)
    let match = SFSpeechRecognizer.supportedLocales()
      .filter { base($0.identifier) == wanted }
      .sorted { $0.identifier < $1.identifier }
      .first
    return match.flatMap { SFSpeechRecognizer(locale: $0) }
  }

  private static func base(_ tag: String) -> String {
    String(tag.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "").lowercased()
  }

  private func emit(_ event: [String: Any]) {
    events?(event)
  }

  private func emitError(_ code: Int) {
    emit(["type": "error", "code": code, "message": Self.describe(code)])
  }

  // Android SpeechRecognizer.ERROR_* codes, which the Dart side reads.
  private static let errorNetwork = 2
  private static let errorAudio = 3
  private static let errorServer = 4
  private static let errorClient = 5
  private static let errorSpeechTimeout = 6
  private static let errorNoMatch = 7
  private static let errorInsufficientPermissions = 9
  private static let errorLanguageNotSupported = 12
  private static let errorUnavailable = 1000

  private static let noSpeechTimeout: TimeInterval = 8
  private static let finalResultTimeout: TimeInterval = 2

  /// Speech framework errors (kAFAssistantErrorDomain codes are not
  /// public API; these are the documented-in-practice ones).
  private static func errorCode(_ error: Error) -> Int {
    let error = error as NSError
    if error.domain == NSURLErrorDomain { return errorNetwork }
    if error.domain == "kAFAssistantErrorDomain" {
      switch error.code {
      case 203, 1110: return errorNoMatch  // nothing recognized / no speech
      case 216, 300, 301: return errorClient  // the task was cancelled
      case 1700: return errorUnavailable  // Siri and Dictation turned off
      default: return errorServer
      }
    }
    return errorServer
  }

  private static func describe(_ code: Int) -> String {
    switch code {
    case errorNetwork: return "Speech recognition needs a network connection."
    case errorAudio: return "Audio recording failed."
    case errorServer: return "The speech service failed."
    case errorClient: return "Speech recognition was interrupted."
    case errorSpeechTimeout: return "No speech was heard."
    case errorNoMatch: return "Nothing was recognized."
    case errorInsufficientPermissions:
      return "Microphone or speech recognition permission denied."
    case errorLanguageNotSupported: return "This language is not available for speech recognition."
    case errorUnavailable: return "Speech recognition is not available. Turn on Dictation in Settings."
    default: return "Speech recognition failed (\(code))."
    }
  }
}
