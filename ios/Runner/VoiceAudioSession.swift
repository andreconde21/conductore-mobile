import AVFoundation

/// The app's AVAudioSession, shared by dictation (SpeechRecognitionBridge)
/// and read-aloud (TextToSpeechBridge).
///
/// While the microphone records, the category is playAndRecord (speaker by
/// default, Bluetooth headsets allowed); while only speaking it is playback
/// with the spokenAudio mode, so a podcast or audiobook pauses and music
/// ducks under the voice. A notification sound never interrupts either.
///
/// The session is deactivated a moment after the last user lets go (no
/// un-duck / duck flicker between sentences or between Talk's listening
/// and speaking), with notifyOthersOnDeactivation so other audio comes back.
/// All calls happen on the main thread.
final class VoiceAudioSession {
  static let shared = VoiceAudioSession()

  private let session = AVAudioSession.sharedInstance()
  private var recording = false
  private var speaking = false
  private var release: DispatchWorkItem?

  private enum Setup { case record, speak }
  private var setup: Setup?

  func setRecording(_ value: Bool) throws {
    recording = value
    try apply()
  }

  func setSpeaking(_ value: Bool) throws {
    speaking = value
    try apply()
  }

  private func apply() throws {
    release?.cancel()
    release = nil
    guard recording || speaking else {
      scheduleRelease()
      return
    }
    let wanted: Setup = recording ? .record : .speak
    if setup != wanted {
      switch wanted {
      case .record:
        try session.setCategory(
          .playAndRecord,
          mode: .default,
          options: [.duckOthers, .defaultToSpeaker, .allowBluetooth]
        )
      case .speak:
        try session.setCategory(
          .playback,
          mode: .spokenAudio,
          options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers]
        )
      }
      setup = wanted
    }
    try session.setActive(true)
  }

  private func scheduleRelease() {
    let item = DispatchWorkItem { [weak self] in
      guard let self = self, !self.recording, !self.speaking else { return }
      self.release = nil
      // Fails harmlessly (busy) if audio is still draining; the next
      // release or the system deactivates it then.
      try? self.session.setActive(false, options: .notifyOthersOnDeactivation)
    }
    release = item
    DispatchQueue.main.asyncAfter(
      deadline: .now() + VoiceAudioSession.releaseDelay,
      execute: item
    )
  }

  private static let releaseDelay: TimeInterval = 0.7
}
