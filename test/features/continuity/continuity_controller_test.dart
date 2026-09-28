import 'package:conduit/features/continuity/domain/continuity_preferences.dart';
import 'package:conduit/features/continuity/domain/continuity_record.dart';
import 'package:conduit/features/continuity/domain/continuity_rules.dart';
import 'package:conduit/features/continuity/domain/continuity_state.dart';
import 'package:conduit/features/continuity/presentation/continuity_controller.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'continuity_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final start = DateTime(2026, 9, 28, 12);

  /// Runs [body] with a started controller whose clock follows fake time.
  void withController(
    void Function(
      FakeAsync async,
      ContinuityController controller,
      FakeContinuityLink link,
    )
    body, {
    InMemoryContinuityStore? store,
    List<SavedHost> machines = const [],
    String? selfMachineId,
    SavedHost? thisComputer,
    bool desktop = false,
    String deviceId = 'phone-id',
  }) {
    fakeAsync((async) {
      final link = FakeContinuityLink(deviceId: deviceId);
      final controller = continuityController(
        link: link,
        clock: () => start.add(async.elapsed),
        store: store,
        machines: machines.isEmpty ? [savedMachine('vtm')] : machines,
        selfMachineId: selfMachineId,
        thisComputer: thisComputer,
        desktop: desktop,
      );
      controller.start();
      async.flushMicrotasks();
      body(async, controller, link);
      controller.dispose();
    });
  }

  Future<DeviceContinuity> own(ContinuityController controller) async =>
      DeviceContinuity.fromJson(
        'phone-id',
        await controller.ownRecord('phone-id'),
      )!;

  DeviceContinuity ownNow(FakeAsync async, ContinuityController controller) {
    DeviceContinuity? record;
    own(controller).then((value) => record = value);
    async.flushMicrotasks();
    return record!;
  }

  test('a place goes out as the record, with the one before in recent', () {
    withController((async, controller, link) {
      controller.reportPlace(terminalPlace());
      async.elapse(const Duration(minutes: 1));
      controller.reportPlace(chatPlace());

      final record = ownNow(async, controller);
      expect(record.deviceName, 'Phone');
      expect(record.context!.place, chatPlace());
      expect(record.recent.single.place, terminalPlace());
      expect(record.activeAt, start.add(const Duration(minutes: 1)));
    });
  });

  test('changes go out at most every 10 s, and at once on leaving', () {
    withController((async, controller, link) {
      async.elapse(const Duration(seconds: 30));
      link.pushes = 0;
      for (var i = 0; i < 30; i++) {
        controller.noteDraft('agent-1', 'typing $i');
        async.elapse(const Duration(seconds: 1));
      }
      expect(link.pushes, inInclusiveRange(2, 4));

      link.pushes = 0;
      controller.noteDraft('agent-1', 'last words');
      controller.didChangeAppLifecycleState(AppLifecycleState.paused);
      expect(link.pushes, 1);
      expect(ownNow(async, controller).drafts['agent-1']!.text, 'last words');
    });
  });

  test('another device used since is offered, until dismissed', () {
    withController((async, controller, link) {
      expect(controller.offer, isNull);
      async.elapse(const Duration(minutes: 10));
      final context = ContinuityContext(place: chatPlace(), at: start);
      controller.receive(
        deviceRecord(
          id: 'desk',
          activeAt: start.add(const Duration(minutes: 9)),
          context: context,
        ),
        deviceId: 'phone-id',
      );
      async.flushMicrotasks();

      final offer = controller.offer!;
      expect(offer.device.name, 'Omarchy');
      expect(offer.context, context);

      controller.dismiss(offer);
      expect(controller.offer, isNull);
    });
  });

  test('no offer for use older than this device, or with sharing off', () {
    withController(
      (async, controller, link) {
        controller.receive(
          deviceRecord(
            id: 'desk',
            activeAt: start.subtract(const Duration(minutes: 1)),
            context: ContinuityContext(place: chatPlace(), at: start),
          ),
          deviceId: 'phone-id',
        );
        async.flushMicrotasks();
        // The phone was last used 30 s before start: the desktop's use is
        // older.
        expect(controller.offer, isNull);

        controller.receive(
          deviceRecord(
            id: 'desk',
            activeAt: start.add(const Duration(seconds: 5)),
            context: ContinuityContext(place: chatPlace(), at: start),
          ),
          deviceId: 'phone-id',
        );
        async.flushMicrotasks();
        expect(controller.offer, isNotNull);
        link.sharing = false;
        expect(controller.offer, isNull);
      },
      store: InMemoryContinuityStore(
        ContinuityState(activeAt: start.subtract(const Duration(seconds: 30))),
      ),
    );
  });

  test('a place on This computer goes out as the saved machine of this '
      'desktop', () {
    withController(
      (async, controller, link) {
        controller.reportPlace(
          const ContinuityPlace(
            machineId: 'this-computer',
            target: ConnectTarget.herdr(workspaceId: 'w1'),
          ),
        );
        expect(ownNow(async, controller).context!.place.machineId, 'omarchy');
        expect(
          controller.machineFor(controller.context!.place)?.id,
          thisComputerHostId,
        );
      },
      desktop: true,
      selfMachineId: 'omarchy',
      thisComputer: SavedHost.thisComputer(),
      machines: [savedMachine('omarchy')],
    );
  });

  test('a desktop wakes on input after a pause and asks for the others', () {
    withController((async, controller, link) {
      link.lastSyncAt = start;
      controller.noteActivity();
      async.elapse(const Duration(minutes: 30));
      link.lastSyncAt = start;
      controller.noteActivity();
      expect(link.pulls, 1);
    }, desktop: true);
  });

  test('the preferences decide what the record carries', () {
    withController((async, controller, link) {
      controller.reportPlace(chatPlace());
      controller.noteAnchor('agent-1', 'a7#0');
      controller.noteDraft('agent-1', 'secret plan');
      var record = ownNow(async, controller);
      expect(record.context!.anchor, 'a7#0');
      expect(record.drafts, contains('agent-1'));

      controller.setPreferences(
        const ContinuityPreferences(drafts: false, scroll: false),
      );
      async.flushMicrotasks();
      record = ownNow(async, controller);
      expect(record.context, isNotNull);
      expect(record.context!.anchor, isNull);
      expect(record.drafts, isEmpty);
      // Off also drops the kept drafts.
      expect(controller.draftFor('agent-1'), '');

      controller.setPreferences(const ContinuityPreferences(sessions: false));
      async.flushMicrotasks();
      record = ownNow(async, controller);
      expect(record.context, isNull);
      expect(record.recent, isEmpty);
    });
  });

  test('turning continuity off sends an empty record', () {
    withController((async, controller, link) {
      controller.reportPlace(chatPlace());
      controller.noteDraft('agent-1', 'draft');
      link.pushes = 0;
      controller.retract();
      expect(link.pushes, 1);
      final record = ownNow(async, controller);
      expect(record.context, isNull);
      expect(record.drafts, isEmpty);
    });
  });

  test('another device\'s draft fills an empty composer, else is offered', () {
    withController((async, controller, link) {
      async.elapse(const Duration(minutes: 1));
      controller.receive(
        deviceRecord(
          id: 'desk',
          activeAt: start,
          drafts: {
            'agent-1': ContinuityDraft(
              text: 'from the desk',
              at: start.add(const Duration(seconds: 30)),
            ),
          },
        ),
        deviceId: 'phone-id',
      );
      async.flushMicrotasks();

      final fill = controller.resolveDraftFor('agent-1', '');
      expect(fill, isA<DraftFill>());

      // A local draft is never replaced silently.
      final choice = controller.resolveDraftFor('agent-1', 'mine');
      expect(choice, isA<DraftChoice>());
      controller.settleDraft(choice as DraftChoice);
      expect(controller.resolveDraftFor('agent-1', 'mine'), isA<DraftKeep>());
    });
  });

  test('an arrival hands its anchor to that chat once', () {
    withController((async, controller, link) {
      controller.expectArrival(
        ContinuityContext(place: chatPlace(), at: start, anchor: 'a3#0'),
      );
      expect(controller.takeArrivalAnchor('other-agent'), isNull);
      expect(controller.takeArrivalAnchor('agent-1'), 'a3#0');
      expect(controller.takeArrivalAnchor('agent-1'), isNull);
    });
  });

  test('the state is kept between runs', () {
    final store = InMemoryContinuityStore();
    withController((async, controller, link) {
      controller.reportPlace(chatPlace());
      controller.noteDraft('agent-1', 'kept');
      controller.flush();
      async.flushMicrotasks();
    }, store: store);
    expect(store.stored.context?.place, chatPlace());
    expect(store.stored.drafts['agent-1']?.text, 'kept');
    withController((async, controller, link) {
      expect(controller.draftFor('agent-1'), 'kept');
    }, store: store);
  });
}
