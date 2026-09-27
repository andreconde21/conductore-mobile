import 'package:flutter/widgets.dart';

/// Settings for a route that shows the terminal page, so Chat View opened
/// on top of it can tell and leave both on back (a desktop shell that
/// embeds the terminal has no such route).
const terminalRouteSettings = RouteSettings(name: '/terminal');

bool isTerminalRoute(Route<Object?> route) =>
    route.settings.name == terminalRouteSettings.name;

/// The route on top of [navigator], without popping anything.
Route<Object?>? topRouteOf(NavigatorState navigator) {
  Route<Object?>? top;
  navigator.popUntil((route) {
    top = route;
    return true;
  });
  return top;
}

/// Settings for a Chat View route, naming the machine (session host id)
/// and agent it shows, so the voice guide knows what is on screen.
RouteSettings chatRouteSettings({
  required String hostId,
  required String agentId,
}) =>
    RouteSettings(name: '/chat', arguments: (hostId: hostId, agentId: agentId));

/// The machine and agent a Chat View route shows, or null for any other
/// route.
({String hostId, String agentId})? chatRouteTarget(Route<Object?> route) {
  final arguments = route.settings.arguments;
  return route.settings.name == '/chat' &&
          arguments is ({String hostId, String agentId})
      ? arguments
      : null;
}
