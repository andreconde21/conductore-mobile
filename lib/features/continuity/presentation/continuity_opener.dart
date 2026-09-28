import 'package:conduit/features/continuity/domain/continuity_record.dart';
import 'package:conduit/features/continuity/presentation/continuity_controller.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';

/// How the page that shows sessions opens a place: its terminal (the
/// target, or the agent's pane), or Chat View on its Claude session. Each
/// returns false when it could not.
class ContinuityOpenActions {
  const ContinuityOpenActions({
    required this.openTerminal,
    required this.openChat,
  });

  final Future<bool> Function(SavedHost host, ContinuityPlace place)
  openTerminal;
  final Future<bool> Function(SavedHost host, ContinuityPlace place) openChat;
}

enum ContinuityOpenResult {
  /// Opened as the other device showed it.
  opened,

  /// Chat View could not open (the Claude session ended, no companion):
  /// the terminal opened instead.
  openedTerminal,

  /// The machine is not saved on this device.
  noMachine,
  failed,
}

/// Opens another device's [context] here: the same machine (a desktop's
/// "This computer" and the phone's entry for that desktop are the same
/// one, see [ContinuityController.machineFor]), the same session, the same
/// view. Chat View then scrolls to the other device's anchor and offers
/// its draft.
Future<ContinuityOpenResult> openContinuityContext(
  ContinuityController continuity,
  ContinuityContext context,
  ContinuityOpenActions actions,
) async {
  final place = context.place;
  final host = continuity.machineFor(place);
  if (host == null) return ContinuityOpenResult.noMachine;
  continuity.expectArrival(context);
  if (place.view == ContinuityView.chat && place.agentId != null) {
    if (await actions.openChat(host, place)) return ContinuityOpenResult.opened;
    return await actions.openTerminal(host, place)
        ? ContinuityOpenResult.openedTerminal
        : ContinuityOpenResult.failed;
  }
  return await actions.openTerminal(host, place)
      ? ContinuityOpenResult.opened
      : ContinuityOpenResult.failed;
}

/// What to tell the user after [result] (null: nothing).
String? continuityOpenMessage(
  ContinuityOpenResult result,
  ContinuityContext context,
) => switch (result) {
  ContinuityOpenResult.opened => null,
  ContinuityOpenResult.openedTerminal =>
    'That Claude session is not running any more; opened its terminal.',
  ContinuityOpenResult.noMachine =>
    context.place.machineId == null
        ? 'That session is on the other device itself, which is not saved '
              'as a machine here.'
        : '${context.place.machineName.isEmpty ? 'That machine' : context.place.machineName} '
              'is not saved on this device.',
  ContinuityOpenResult.failed => 'Could not open ${context.place.summary}.',
};
