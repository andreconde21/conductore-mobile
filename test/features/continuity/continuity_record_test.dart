import 'package:conduit/features/continuity/domain/continuity_preferences.dart';
import 'package:conduit/features/continuity/domain/continuity_record.dart';
import 'package:conduit/features/continuity/domain/continuity_state.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:flutter_test/flutter_test.dart';

import 'continuity_test_support.dart';

void main() {
  final at = DateTime(2026, 9, 28, 9, 30);

  test('a device record survives encode and decode', () {
    final context = ContinuityContext(
      place: chatPlace(),
      at: at,
      anchor: 'a12#0',
      layout: 'Morning check',
    );
    final device = DeviceContinuity(
      deviceId: 'desk',
      deviceName: 'Omarchy',
      platform: 'linux',
      desktop: true,
      activeAt: at.add(const Duration(minutes: 3)),
      context: context,
      recent: [
        ContinuityContext(
          place: terminalPlace(),
          at: at.subtract(const Duration(minutes: 20)),
        ),
      ],
      drafts: {'agent-1': ContinuityDraft(text: 'fix the tests', at: at)},
    );

    final back = DeviceContinuity.fromJson('desk', device.toJson())!;

    expect(back.deviceName, 'Omarchy');
    expect(back.platform, 'linux');
    expect(back.desktop, isTrue);
    expect(back.activeAt, device.activeAt);
    expect(back.context, context);
    expect(back.context!.place.target!.key, 'herdr:w1:t2');
    expect(back.context!.place.paneId, 'p3');
    expect(back.recent.single.place.target, const ConnectTarget.tmux('work'));
    // Recent places carry no scroll position.
    expect(back.recent.single.anchor, isNull);
    expect(
      back.drafts['agent-1'],
      ContinuityDraft(text: 'fix the tests', at: at),
    );
  });

  test('a record from a newer format or without a chat agent is skipped', () {
    expect(DeviceContinuity.fromJson('x', {'v': 99}), isNull);
    expect(DeviceContinuity.fromJson('x', 'nonsense'), isNull);
    final noAgent = {
      'v': 1,
      'context': {'machine': 'vtm', 'view': 'chat', 'at': 1},
    };
    expect(DeviceContinuity.fromJson('x', noAgent)!.context, isNull);
  });

  test('a place names the session, then the workspace, then the machine', () {
    expect(chatPlace().summary, 'VTM · Chat view');
    expect(
      terminalPlace(
        target: const ConnectTarget.herdr(workspaceId: 'w', label: 'Tomar'),
      ).summary,
      'Tomar · Terminal',
    );
    expect(
      const ContinuityPlace(machineId: 'vtm', machineName: 'Dev').summary,
      'Dev · Terminal',
    );
  });

  test('the same place ignores names, not the target or the view', () {
    final place = terminalPlace();
    expect(
      place.samePlace(
        const ContinuityPlace(
          machineId: 'vtm',
          machineName: 'Renamed',
          target: ConnectTarget.tmux('work'),
        ),
      ),
      isTrue,
    );
    expect(place.samePlace(terminalPlace(machine: 'other')), isFalse);
    expect(
      place.samePlace(terminalPlace(target: const ConnectTarget.tmux('x'))),
      isFalse,
    );
    expect(chatPlace().samePlace(chatPlace(agent: 'agent-2')), isFalse);
  });

  test('the kept state survives encode and decode', () {
    final state = ContinuityState(
      preferences: const ContinuityPreferences(drafts: false),
      activeAt: at,
      context: ContinuityContext(place: chatPlace(), at: at),
      drafts: {'agent-1': ContinuityDraft(text: 'x', at: at)},
      remote: deviceRecord(id: 'desk', activeAt: at),
      dismissed: const ['desk@1'],
      handledDrafts: const ['desk@2'],
    );

    final back = ContinuityState.fromJson(state.toJson());

    expect(back.preferences.drafts, isFalse);
    expect(back.preferences.sessions, isTrue);
    expect(back.activeAt, at);
    expect(back.context!.place, chatPlace());
    expect(back.drafts.keys, ['agent-1']);
    expect(back.remote.keys, ['continuity:desk']);
    expect(back.dismissed, ['desk@1']);
    expect(back.handledDrafts, ['desk@2']);
  });
}
