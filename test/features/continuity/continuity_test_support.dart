import 'package:conduit/features/continuity/domain/continuity_record.dart';
import 'package:conduit/features/continuity/domain/continuity_state.dart';
import 'package:conduit/features/continuity/presentation/continuity_controller.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:flutter/foundation.dart';

/// Sync as continuity sees it, with the pushes and pulls counted.
class FakeContinuityLink extends ChangeNotifier implements ContinuitySyncLink {
  FakeContinuityLink({
    this.deviceId = 'phone-id',
    this.deviceName = 'Phone',
    bool sharing = true,
  }) : _sharing = sharing;

  @override
  String? deviceId;

  @override
  String deviceName;

  bool _sharing;

  @override
  bool get sharing => _sharing;

  set sharing(bool value) {
    _sharing = value;
    notifyListeners();
  }

  @override
  DateTime? lastSyncAt;

  int pushes = 0;
  int pulls = 0;

  @override
  void push() => pushes += 1;

  @override
  void pull() => pulls += 1;
}

SavedHost savedMachine(String id, {String name = ''}) => SavedHost(
  id: id,
  name: name.isEmpty ? 'Machine $id' : name,
  host: '$id.example.com',
  port: 22,
  username: 'andre',
  authMethod: SshAuthMethod.password,
);

/// A controller over [link] (a phone by default) whose clock is [clock].
ContinuityController continuityController({
  required FakeContinuityLink link,
  required DateTime Function() clock,
  InMemoryContinuityStore? store,
  List<SavedHost> machines = const [],
  String? selfMachineId,
  SavedHost? thisComputer,
  bool desktop = false,
  Duration publishInterval = const Duration(seconds: 10),
}) {
  final byId = {for (final machine in machines) machine.id: machine};
  return ContinuityController(
    store: store ?? InMemoryContinuityStore(),
    sync: link,
    machineFor: (id) {
      if (id == null || id == thisComputerHostId) return null;
      if (thisComputer != null && id == selfMachineId) return thisComputer;
      return byId[id];
    },
    selfMachineId: () => selfMachineId,
    desktop: desktop,
    now: clock,
    publishInterval: publishInterval,
    observeLifecycle: false,
  );
}

ContinuityPlace chatPlace({
  String machine = 'vtm',
  String agent = 'agent-1',
  String agentName = 'VTM',
}) => ContinuityPlace(
  machineId: machine,
  machineName: 'Dev central',
  view: ContinuityView.chat,
  agentId: agent,
  agentName: agentName,
  target: const ConnectTarget.herdr(workspaceId: 'w1', tabId: 't2'),
  paneId: 'p3',
);

ContinuityPlace terminalPlace({
  String machine = 'vtm',
  ConnectTarget target = const ConnectTarget.tmux('work'),
}) => ContinuityPlace(machineId: machine, machineName: 'Dev', target: target);

/// Another device's record as sync delivers it.
Map<String, Object?> deviceRecord({
  required String id,
  String name = 'Omarchy',
  bool desktop = true,
  required DateTime activeAt,
  ContinuityContext? context,
  Map<String, ContinuityDraft> drafts = const {},
}) => {
  'continuity:$id': DeviceContinuity(
    deviceId: id,
    deviceName: name,
    desktop: desktop,
    activeAt: activeAt,
    context: context,
    drafts: drafts,
  ).toJson(),
};
