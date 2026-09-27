import 'package:flutter/services.dart';

/// The system share sheet for text (`conduit/share_text`): Android's
/// chooser, iOS's activity sheet.
abstract final class PlatformTextShare {
  static const channel = MethodChannel('conduit/share_text');

  /// Offers [text] to other apps. False when this platform has no share
  /// sheet (desktop, tests), so the caller can fall back to the clipboard.
  static Future<bool> share(String text, {String? subject}) async {
    try {
      await channel.invokeMethod<void>('share', {
        'text': text,
        'subject': ?subject,
      });
      return true;
    } on MissingPluginException {
      return false;
    }
  }
}
