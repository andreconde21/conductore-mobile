import 'package:conduit/features/continuity/domain/continuity_record.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:flutter/foundation.dart';

/// "Continue from Omarchy: VTM · Chat view": another device's place, offered
/// here.
@immutable
class ContinuityOffer {
  const ContinuityOffer(this.device, this.context);

  final DeviceContinuity device;
  final ContinuityContext context;

  /// Dismissing hides this very context; the device's next place is
  /// offered again.
  String get key => '${device.deviceId}@${context.at.millisecondsSinceEpoch}';

  @override
  bool operator ==(Object other) =>
      other is ContinuityOffer && other.key == key && other.context == context;

  @override
  int get hashCode => Object.hash(key, context);
}

/// The place to offer on this device, or null.
///
/// Another device's place is offered when that device was in use more
/// recently than this one ([lastActiveHere]: this device's last use before
/// it woke), within [window] of [now], somewhere else than [here] (where
/// this device is, or was last), not dismissed, and it can be opened here
/// ([canOpen]: its machine is saved on this device). The most recently
/// active device wins.
ContinuityOffer? pickContinuityOffer({
  required Iterable<DeviceContinuity> others,
  required DateTime now,
  DateTime? lastActiveHere,
  ContinuityPlace? here,
  Set<String> dismissed = const {},
  bool Function(ContinuityPlace place)? canOpen,
  Duration window = const Duration(hours: 2),
}) {
  ContinuityOffer? best;
  DateTime? bestAt;
  for (final device in others) {
    final context = device.context;
    final activeAt = device.activeAt;
    if (context == null || activeAt == null) continue;
    // A clock a little ahead elsewhere still counts as "just now".
    if (now.difference(activeAt) > window) continue;
    if (lastActiveHere != null && !activeAt.isAfter(lastActiveHere)) continue;
    if (here != null && here.samePlace(context.place)) continue;
    final offer = ContinuityOffer(device, context);
    if (dismissed.contains(offer.key)) continue;
    if (canOpen != null && !canOpen(context.place)) continue;
    if (bestAt == null || activeAt.isAfter(bestAt)) {
      best = offer;
      bestAt = activeAt;
    }
  }
  return best;
}

/// What a Chat View composer does with the drafts of one Claude session.
sealed class DraftResolution {
  const DraftResolution();
}

/// Nothing new elsewhere.
class DraftKeep extends DraftResolution {
  const DraftKeep();
}

/// Another device's draft that this device has not seen, with where it
/// comes from. [key] marks it seen once acted on.
sealed class RemoteDraftResolution extends DraftResolution {
  const RemoteDraftResolution(this.device, this.draft);

  final DeviceContinuity device;
  final ContinuityDraft draft;

  String get key => draftKey(device.deviceId, draft);
}

/// The composer is empty: the other device's draft goes in, with a "from
/// Desktop" hint.
class DraftFill extends RemoteDraftResolution {
  const DraftFill(super.device, super.draft);
}

/// Both have a different draft: the user picks (theirs, both, or mine);
/// the local one is never replaced silently.
class DraftChoice extends RemoteDraftResolution {
  const DraftChoice(super.device, super.draft);
}

/// The other device sent or cleared the draft after this one was last
/// edited: the user may clear it here too.
class DraftClearedElsewhere extends RemoteDraftResolution {
  const DraftClearedElsewhere(super.device, super.draft);
}

/// Identity of [draft] of [deviceId], to remember it was handled.
String draftKey(String deviceId, ContinuityDraft draft) =>
    '$deviceId@${draft.at.millisecondsSinceEpoch}';

/// Last writer wins, never silently: the newest draft of another device,
/// edited after this device's own ([local], when this device last edited
/// the draft), and not [handled] yet, is offered according to what the
/// composer holds now ([localText]).
DraftResolution resolveDraft({
  required ContinuityDraft? local,
  required String localText,
  required Iterable<(DeviceContinuity, ContinuityDraft)> remote,
  Set<String> handled = const {},
}) {
  (DeviceContinuity, ContinuityDraft)? newest;
  for (final entry in remote) {
    final (device, draft) = entry;
    if (local != null && !draft.at.isAfter(local.at)) continue;
    if (handled.contains(draftKey(device.deviceId, draft))) continue;
    if (newest == null || draft.at.isAfter(newest.$2.at)) newest = entry;
  }
  if (newest == null) return const DraftKeep();
  final (device, draft) = newest;
  final mine = localText.trim();
  if (draft.text.trim() == mine) return const DraftKeep();
  if (draft.isEmpty) {
    return mine.isEmpty
        ? const DraftKeep()
        : DraftClearedElsewhere(device, draft);
  }
  return mine.isEmpty ? DraftFill(device, draft) : DraftChoice(device, draft);
}

/// The id other devices know the machine of [hostId] (a machine or a
/// session on it) by. "This computer" is the saved machine that is this
/// desktop ([selfMachineId]), or null when it has none: another device
/// could not reach it.
String? sharedMachineId(String hostId, {String? selfMachineId}) {
  final base = baseHostId(hostId);
  if (base == thisComputerHostId) return selfMachineId;
  return base;
}

/// The machine to open another device's [machineId] on here: "This
/// computer" when it is the saved machine that is this desktop
/// ([selfMachineId]), else the saved machine ([findById]).
SavedHost? localMachineFor(
  String? machineId, {
  required SavedHost? Function(String id) findById,
  String? selfMachineId,
  SavedHost? thisComputer,
}) {
  if (machineId == null || machineId == thisComputerHostId) return null;
  if (thisComputer != null && machineId == selfMachineId) return thisComputer;
  return findById(machineId);
}
