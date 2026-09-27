/// Everything the app can count, as closed sets: an event name and props
/// whose values come from these enums (or the app's own version), never
/// from user data.
library;

import 'package:conduit/core/connection_problem.dart';

/// Top-level screens, sent as `app://conductore/<name>` page views.
enum TelemetryScreen { home, terminal, chat, settings, files }

/// How a session reached its machine.
enum TelemetryTransport { ssh, mosh, local }

/// What the session runs on top of the shell.
enum TelemetryMultiplexer { herdr, tmux, none }

/// Why a connection failed, coarsely.
enum TelemetryFailure { unreachable, auth, hostkey, other }

/// Which voice feature was used.
enum TelemetryVoice { dictation, talk }

/// One usage event: its Plausible [name], the screen it belongs to and its
/// props. Built only through the named constructors.
class TelemetryEvent {
  const TelemetryEvent._(this.name, this.screen, [this.props = const {}]);

  /// Once per cold start.
  const TelemetryEvent.appOpen() : this._('app_open', TelemetryScreen.home);

  /// A top-level screen was shown.
  TelemetryEvent.screenView(TelemetryScreen screen)
    : this._('pageview', screen);

  /// A connection attempt finished.
  TelemetryEvent.sessionConnect({
    required TelemetryTransport transport,
    required TelemetryMultiplexer multiplexer,
    TelemetryFailure? failure,
  }) : this._('session_connect', TelemetryScreen.terminal, {
         'transport': transport.name,
         'multiplexer': multiplexer.name,
         'result': failure == null ? 'success' : 'fail',
         'failure': ?failure?.name,
       });

  /// Chat View opened for a session.
  const TelemetryEvent.chatModeOpened()
    : this._('chat_mode_opened', TelemetryScreen.chat);

  /// The agents dashboard was opened (no content, no counts).
  const TelemetryEvent.digestOpened()
    : this._('digest_opened', TelemetryScreen.home);

  /// The usage explorer was opened (no range, filter or numbers).
  const TelemetryEvent.usageExplorerOpened()
    : this._('usage_explorer_opened', TelemetryScreen.home);

  TelemetryEvent.voiceUsed(TelemetryVoice kind)
    : this._('voice_used', TelemetryScreen.chat, {'kind': kind.name});

  /// A machine answered with a companion; [version] is kept only when it
  /// looks like a release number.
  TelemetryEvent.companionDetected(String? version)
    : this._('companion_detected', TelemetryScreen.home, {
        'companion_version': companionVersionProp(version),
      });

  final String name;
  final TelemetryScreen screen;
  final Map<String, String> props;

  /// `1.4.0`, `0.3.1-beta.2`; anything else is "other".
  static String companionVersionProp(String? version) {
    final value = version?.trim() ?? '';
    return RegExp(
          r'^\d{1,3}\.\d{1,3}\.\d{1,4}(?:[-+][0-9A-Za-z.]{1,20})?$',
        ).hasMatch(value)
        ? value
        : 'other';
  }

  @override
  String toString() => 'TelemetryEvent($name, ${screen.name}, $props)';
}

/// The coarse class of a failed connection, from the error and its
/// causes. Only the class is sent, never the text it was read from.
TelemetryFailure classifyConnectFailure(Object error) =>
    switch (classifyConnectionError(error)) {
      ConnectionProblemKind.unreachable => TelemetryFailure.unreachable,
      ConnectionProblemKind.authentication => TelemetryFailure.auth,
      ConnectionProblemKind.hostKey => TelemetryFailure.hostkey,
      ConnectionProblemKind.commandFailed => TelemetryFailure.other,
    };
