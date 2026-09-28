import 'package:conduit/features/continuity/domain/continuity_record.dart';
import 'package:conduit/features/continuity/presentation/continuity_controller.dart';
import 'package:conduit/features/continuity/presentation/continuity_opener.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:flutter_test/flutter_test.dart';

import 'continuity_test_support.dart';

/// Records what the page was asked to open.
class _Opened {
  final calls = <String>[];
  bool chatWorks = true;

  ContinuityOpenActions get actions => ContinuityOpenActions(
    openTerminal: (host, place) async {
      calls.add('terminal ${host.id} ${place.target?.key ?? 'shell'}');
      return true;
    },
    openChat: (host, place) async {
      calls.add('chat ${host.id} ${place.agentId}');
      return chatWorks;
    },
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final at = DateTime(2026, 9, 28, 12);

  ContinuityController controller({
    String? selfMachineId,
    SavedHost? thisComputer,
  }) => continuityController(
    link: FakeContinuityLink(),
    clock: () => at,
    machines: [savedMachine('vtm'), savedMachine('omarchy')],
    selfMachineId: selfMachineId,
    thisComputer: thisComputer,
  );

  test('Chat View opens on the same session, at the same message', () async {
    final continuity = controller();
    await continuity.start();
    final opened = _Opened();
    final context = ContinuityContext(
      place: chatPlace(),
      at: at,
      anchor: 'a12#0',
    );

    final result = await openContinuityContext(
      continuity,
      context,
      opened.actions,
    );

    expect(result, ContinuityOpenResult.opened);
    expect(opened.calls, ['chat vtm agent-1']);
    expect(continuity.takeArrivalAnchor('agent-1'), 'a12#0');
    continuity.dispose();
  });

  test('the terminal opens on the same target', () async {
    final continuity = controller();
    await continuity.start();
    final opened = _Opened();

    await openContinuityContext(
      continuity,
      ContinuityContext(place: terminalPlace(), at: at),
      opened.actions,
    );

    expect(opened.calls, ['terminal vtm tmux:work']);
    continuity.dispose();
  });

  test('an ended Claude session falls back to its terminal', () async {
    final continuity = controller();
    await continuity.start();
    final opened = _Opened()..chatWorks = false;
    final context = ContinuityContext(place: chatPlace(), at: at);

    final result = await openContinuityContext(
      continuity,
      context,
      opened.actions,
    );

    expect(result, ContinuityOpenResult.openedTerminal);
    expect(opened.calls, ['chat vtm agent-1', 'terminal vtm herdr:w1:t2']);
    expect(continuityOpenMessage(result, context), contains('not running'));
    continuity.dispose();
  });

  test('the phone\'s place on this desktop opens on This computer', () async {
    final local = SavedHost.thisComputer();
    final continuity = controller(
      selfMachineId: 'omarchy',
      thisComputer: local,
    );
    await continuity.start();
    final opened = _Opened();

    await openContinuityContext(
      continuity,
      ContinuityContext(
        place: terminalPlace(machine: 'omarchy'),
        at: at,
      ),
      opened.actions,
    );

    expect(opened.calls, ['terminal ${local.id} tmux:work']);
    continuity.dispose();
  });

  test('a machine not saved here says so', () async {
    final continuity = controller();
    await continuity.start();
    final opened = _Opened();
    final context = ContinuityContext(
      place: terminalPlace(machine: 'elsewhere'),
      at: at,
    );

    final result = await openContinuityContext(
      continuity,
      context,
      opened.actions,
    );

    expect(result, ContinuityOpenResult.noMachine);
    expect(opened.calls, isEmpty);
    expect(continuityOpenMessage(result, context), contains('not saved'));
    continuity.dispose();
  });
}
