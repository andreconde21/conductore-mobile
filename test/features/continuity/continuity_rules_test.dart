import 'package:conduit/features/continuity/domain/continuity_record.dart';
import 'package:conduit/features/continuity/domain/continuity_rules.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:flutter_test/flutter_test.dart';

import 'continuity_test_support.dart';

void main() {
  final now = DateTime(2026, 9, 28, 12);

  DeviceContinuity device(
    String id, {
    required Duration ago,
    ContinuityPlace? place,
  }) => DeviceContinuity(
    deviceId: id,
    deviceName: id,
    activeAt: now.subtract(ago),
    context: ContinuityContext(
      place: place ?? chatPlace(),
      at: now.subtract(ago),
    ),
  );

  group('the offer', () {
    test('names a device used since this one, somewhere else', () {
      final desk = device('desk', ago: const Duration(minutes: 5));
      final offer = pickContinuityOffer(
        others: [desk],
        now: now,
        lastActiveHere: now.subtract(const Duration(hours: 1)),
        here: terminalPlace(),
      );
      expect(offer?.device.deviceId, 'desk');
      expect(offer?.context.place, chatPlace());
    });

    test('waits for a device used after this one', () {
      expect(
        pickContinuityOffer(
          others: [device('desk', ago: const Duration(minutes: 30))],
          now: now,
          lastActiveHere: now.subtract(const Duration(minutes: 10)),
        ),
        isNull,
      );
    });

    test('forgets use older than the window', () {
      final old = device('desk', ago: const Duration(hours: 3));
      expect(pickContinuityOffer(others: [old], now: now), isNull);
      expect(
        pickContinuityOffer(
          others: [old],
          now: now,
          window: const Duration(hours: 4),
        ),
        isNotNull,
      );
    });

    test('is not made for the place this device is at', () {
      expect(
        pickContinuityOffer(
          others: [device('desk', ago: const Duration(minutes: 1))],
          now: now,
          // Same session and view; only the name differs.
          here: chatPlace(agentName: 'renamed'),
        ),
        isNull,
      );
      expect(
        pickContinuityOffer(
          others: [device('desk', ago: const Duration(minutes: 1))],
          now: now,
          here: chatPlace(agent: 'another-session'),
        ),
        isNotNull,
      );
    });

    test('stays away once dismissed, until the device moves on', () {
      final desk = device('desk', ago: const Duration(minutes: 1));
      final offer = pickContinuityOffer(others: [desk], now: now)!;
      expect(
        pickContinuityOffer(others: [desk], now: now, dismissed: {offer.key}),
        isNull,
      );
      final moved = device('desk', ago: Duration.zero, place: terminalPlace());
      expect(
        pickContinuityOffer(others: [moved], now: now, dismissed: {offer.key}),
        isNotNull,
      );
    });

    test('skips places this device cannot open', () {
      expect(
        pickContinuityOffer(
          others: [device('desk', ago: const Duration(minutes: 1))],
          now: now,
          canOpen: (_) => false,
        ),
        isNull,
      );
    });

    test('prefers the most recently used device', () {
      final offer = pickContinuityOffer(
        others: [
          device('tablet', ago: const Duration(minutes: 20)),
          device('desk', ago: const Duration(minutes: 2)),
        ],
        now: now,
      );
      expect(offer?.device.deviceId, 'desk');
    });
  });

  group('drafts', () {
    final desk = device('desk', ago: const Duration(minutes: 1));
    ContinuityDraft draft(String text, int minutesAgo) => ContinuityDraft(
      text: text,
      at: now.subtract(Duration(minutes: minutesAgo)),
    );

    test('fill an empty composer', () {
      final resolution = resolveDraft(
        local: null,
        localText: '',
        remote: [(desk, draft('ship it', 1))],
      );
      expect(resolution, isA<DraftFill>());
      expect((resolution as DraftFill).draft.text, 'ship it');
    });

    test('never replace a different local draft: both are offered', () {
      final resolution = resolveDraft(
        local: draft('mine', 5),
        localText: 'mine',
        remote: [(desk, draft('theirs', 1))],
      );
      expect(resolution, isA<DraftChoice>());
    });

    test('keep a local draft edited after theirs', () {
      expect(
        resolveDraft(
          local: draft('mine', 1),
          localText: 'mine',
          remote: [(desk, draft('theirs', 5))],
        ),
        isA<DraftKeep>(),
      );
    });

    test('keep the same text, and drafts already handled', () {
      expect(
        resolveDraft(
          local: draft('same', 5),
          localText: 'same',
          remote: [(desk, draft('same', 1))],
        ),
        isA<DraftKeep>(),
      );
      final theirs = draft('theirs', 1);
      expect(
        resolveDraft(
          local: null,
          localText: '',
          remote: [(desk, theirs)],
          handled: {draftKey('desk', theirs)},
        ),
        isA<DraftKeep>(),
      );
    });

    test('offer to clear a draft sent on the other device', () {
      expect(
        resolveDraft(
          local: draft('mine', 5),
          localText: 'mine',
          remote: [(desk, draft('', 1))],
        ),
        isA<DraftClearedElsewhere>(),
      );
      expect(
        resolveDraft(
          local: null,
          localText: '',
          remote: [(desk, draft('', 1))],
        ),
        isA<DraftKeep>(),
      );
    });
  });

  group('This computer', () {
    test('goes out as the saved machine that is this desktop', () {
      expect(
        sharedMachineId('this-computer', selfMachineId: 'omarchy'),
        'omarchy',
      );
      expect(
        sharedMachineId('this-computer#herdr:w1', selfMachineId: 'omarchy'),
        'omarchy',
      );
      expect(sharedMachineId('this-computer'), isNull);
      expect(sharedMachineId('vtm#tmux:work', selfMachineId: 'omarchy'), 'vtm');
    });

    test('comes back as This computer on that desktop only', () {
      final local = SavedHost.thisComputer();
      final omarchy = savedMachine('omarchy');
      final vtm = savedMachine('vtm');
      SavedHost? find(String id) => {'omarchy': omarchy, 'vtm': vtm}[id];

      expect(
        localMachineFor(
          'omarchy',
          findById: find,
          selfMachineId: 'omarchy',
          thisComputer: local,
        ),
        local,
      );
      expect(
        localMachineFor(
          'vtm',
          findById: find,
          selfMachineId: 'omarchy',
          thisComputer: local,
        ),
        vtm,
      );
      // On the phone the desktop is a saved machine like any other.
      expect(localMachineFor('omarchy', findById: find), omarchy);
      // Another desktop's own computer, never this one.
      expect(
        localMachineFor(
          'this-computer',
          findById: find,
          selfMachineId: 'omarchy',
          thisComputer: local,
        ),
        isNull,
      );
      expect(localMachineFor(null, findById: find), isNull);
    });
  });
}
