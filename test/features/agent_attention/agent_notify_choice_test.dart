import 'package:conduit/features/agent_attention/domain/agent_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

/// "Notify me" (CON-108) is read from the detailed preferences people
/// saved before it existed, without changing what they get.
void main() {
  const defaults = AgentNotificationPreferences();

  group('saved preferences map onto the closest choice', () {
    for (final (name, preferences, choice)
        in <(String, AgentNotificationPreferences, AgentNotifyChoice?)>[
          (
            'the default (ongoing + urgent)',
            defaults,
            AgentNotifyChoice.urgentOnly,
          ),
          (
            'urgent only, no ongoing notification',
            defaults.copyWith(mode: AgentNotificationMode.urgentOnly),
            AgentNotifyChoice.urgentOnly,
          ),
          (
            'ongoing + urgent, also alert when finished',
            defaults.copyWith(finishedAlerts: true),
            AgentNotifyChoice.urgentAndFinished,
          ),
          (
            'urgent only, also alert when finished',
            defaults.copyWith(
              mode: AgentNotificationMode.urgentOnly,
              finishedAlerts: true,
            ),
            AgentNotifyChoice.urgentAndFinished,
          ),
          (
            'everything',
            defaults.copyWith(mode: AgentNotificationMode.everything),
            AgentNotifyChoice.everything,
          ),
          (
            'everything, stuck off (it never alerts there)',
            defaults.copyWith(
              mode: AgentNotificationMode.everything,
              stuck: false,
            ),
            AgentNotifyChoice.everything,
          ),
          (
            'everything, finished alerts set (unused there)',
            defaults.copyWith(
              mode: AgentNotificationMode.everything,
              finishedAlerts: true,
            ),
            AgentNotifyChoice.everything,
          ),
          (
            'urgent, finished set (unused there)',
            defaults.copyWith(finished: false),
            AgentNotifyChoice.urgentOnly,
          ),
          (
            'summary only, quiet updates off and a mute are details',
            defaults
                .copyWith(summaryOnly: true, quietUpdates: false)
                .withMuted('h', 'a', muted: true),
            AgentNotifyChoice.urgentOnly,
          ),
          ('approvals off', defaults.copyWith(approvals: false), null),
          ('questions off', defaults.copyWith(questions: false), null),
          ('errors off', defaults.copyWith(errors: false), null),
          ('stuck off', defaults.copyWith(stuck: false), null),
          (
            'everything without finished turns',
            defaults.copyWith(
              mode: AgentNotificationMode.everything,
              finished: false,
            ),
            null,
          ),
        ]) {
      test('$name: ${choice?.label ?? 'Custom'}', () {
        expect(preferences.choice, choice);
        // Reading the choice never changes what notifies.
        expect(
          AgentNotificationPreferences.fromJson(preferences.toJson()),
          preferences,
        );
      });
    }
  });

  test('each choice is what it says, and reads back as itself', () {
    for (final start in [
      defaults,
      defaults.copyWith(mode: AgentNotificationMode.urgentOnly),
      defaults.copyWith(
        mode: AgentNotificationMode.everything,
        finished: false,
      ),
      defaults.copyWith(approvals: false, stuck: false, errors: false),
    ]) {
      for (final choice in AgentNotifyChoice.values) {
        final next = start.withChoice(choice);
        expect(next.choice, choice, reason: '$start → ${choice.name}');
        expect(next.notifies(AgentNeed.approval), isTrue);
        expect(next.notifies(AgentNeed.question), isTrue);
        expect(next.notifies(AgentNeed.error), isTrue);
        expect(
          next.notifies(AgentNeed.finished),
          choice != AgentNotifyChoice.urgentOnly,
        );
        expect(
          next.notifies(AgentNeed.stuck),
          choice != AgentNotifyChoice.everything,
        );
      }
    }
  });

  test('the urgent choices keep whether the ongoing notification shows', () {
    final quiet = defaults.copyWith(mode: AgentNotificationMode.urgentOnly);
    expect(
      quiet.withChoice(AgentNotifyChoice.urgentAndFinished).mode,
      AgentNotificationMode.urgentOnly,
    );
    expect(
      defaults.withChoice(AgentNotifyChoice.urgentAndFinished).mode,
      AgentNotificationMode.ongoingAndUrgent,
    );
    // From Everything they start with the default, the ongoing one.
    expect(
      defaults
          .copyWith(mode: AgentNotificationMode.everything)
          .withChoice(AgentNotifyChoice.urgentOnly)
          .mode,
      AgentNotificationMode.ongoingAndUrgent,
    );
  });

  test('a choice keeps muting, summary only and quiet updates', () {
    final mine = defaults
        .copyWith(summaryOnly: true, quietUpdates: false)
        .withMuted('h', 'a', muted: true);
    final next = mine.withChoice(AgentNotifyChoice.everything);
    expect(next.summaryOnly, isTrue);
    expect(next.quietUpdates, isFalse);
    expect(next.isMuted('h', 'a'), isTrue);
  });
}
