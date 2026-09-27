import 'package:flutter/foundation.dart';

/// What the running platform can do, so the UI hides controls that would
/// silently do nothing (or throw MissingPluginException) instead of offering
/// them.
///
/// The first group is backed by Conductore's own platform channels
/// (Android's MainActivity and friends; for voice also iOS's AppDelegate):
/// elsewhere there is no native side for them. The second group follows
/// the plugins' platform support (docs/desktop.md has the audit).
///
/// Every getter reads [defaultTargetPlatform], so widget tests (which run as
/// Android by default) keep exercising the Android UI, and a test can flip
/// `debugDefaultTargetPlatformOverride` to check the iOS or desktop layout.
abstract final class PlatformFeatures {
  static bool get _android => defaultTargetPlatform == TargetPlatform.android;
  static bool get _ios => defaultTargetPlatform == TargetPlatform.iOS;
  static bool get _mobile => _android || _ios;

  /// Linux, Windows or macOS: a mouse and a physical keyboard are assumed.
  static bool get isDesktop => switch (defaultTargetPlatform) {
    TargetPlatform.linux ||
    TargetPlatform.windows ||
    TargetPlatform.macOS => true,
    _ => false,
  };

  /// On-device dictation (`conduit/speech`): Android's SpeechRecognizer,
  /// iOS's SFSpeechRecognizer. Talk needs this and [textToSpeech].
  static bool get dictation => _mobile;

  /// On-device text-to-speech for Chat View replies (`conduit/tts`):
  /// Android's TextToSpeech, iOS's AVSpeechSynthesizer.
  static bool get textToSpeech => _mobile;

  /// Muting the recognizer's start/stop beeps between phrases: only
  /// Android's recognizer beeps.
  static bool get muteRestartBeeps => _android;

  /// Receiving text and files from the system share sheet
  /// (`conduit/share_target`).
  static bool get shareTarget => _android;

  /// Agent notifications with Allow / Deny actions
  /// (`conduit/agent_notifications`).
  static bool get agentNotifications => _android;

  /// Home screen widget and Quick Settings tile
  /// (`conduit/agent_status_widget`).
  static bool get homeWidget => _android;

  /// Pasting an image from the clipboard into a prompt
  /// (`conduit/clipboard_image`).
  static bool get clipboardImage => _android;

  /// Foreground service that keeps sessions alive in the background
  /// (`conduit/background_keepalive`).
  static bool get backgroundKeepalive => _android;

  /// The proot Linux environment of the local shell section (bundled
  /// arm64 Android binaries).
  static bool get prootLocalShell => _android;

  /// "This computer": the desktop's own login shell (flutter_pty), local
  /// tmux sessions and Herdr workspaces, files and companion, as a machine
  /// that is always there and never synced. Phones reach machines over
  /// SSH only.
  static bool get thisComputer => isDesktop;

  /// FIDO hardware security keys for `sk-` SSH keys: NFC (flutter_nfc_kit,
  /// Android and iOS) and USB (`conduit/fido_usb`, Android). No desktop
  /// transport yet, so desktops use regular OpenSSH keys.
  static bool get hardwareSecurityKeys => _mobile;

  /// Embedded web views (webview_flutter): Android, iOS and macOS
  /// (WKWebView). Linux and Windows have no official implementation, so the
  /// live preview and the HTML viewer open the system browser there.
  static bool get embeddedWebView =>
      _mobile || defaultTargetPlatform == TargetPlatform.macOS;

  /// Biometric / device-credential app lock (local_auth): no Linux
  /// implementation, so the lock is unavailable there.
  static bool get appLock => defaultTargetPlatform != TargetPlatform.linux;

  /// Taking a photo for a prompt (image_picker camera source). The desktop
  /// image_picker implementations only pick files.
  static bool get camera => _mobile;

  /// Whether the on-screen pill toolbar and key rows show by default. A
  /// desktop has a physical keyboard; the rows stay one toggle away.
  static bool get touchKeyRowsByDefault => !isDesktop;
}
