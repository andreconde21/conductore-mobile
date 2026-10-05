import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/features/usage/data/usage_preferences.dart';
import 'package:conduit/features/usage/domain/usage_report.dart';
import 'package:conduit/features/usage/presentation/usage_controller.dart';
import 'package:conduit/features/usage/presentation/usage_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'usage_fakes.dart';

void main() {
  final now = DateTime.utc(2026, 9, 25, 12);
  final resets = DateTime.utc(2026, 9, 25, 15);

  late FakeUsageRunner runner;
  late FakeUsageSource source;
  late MemoryUsagePreferencesStore store;

  setUp(() {
    runner = FakeUsageRunner(
      () => FakeUsageRunner.ok(
        usageReplyJson(
          limits: [
            {
              'label': '5h',
              'usedPct': 83,
              'resetsAt': resets.millisecondsSinceEpoch,
            },
            {
              'label': '7d',
              'usedPct': 20,
              'resetsAt': resets
                  .add(const Duration(days: 3))
                  .millisecondsSinceEpoch,
            },
          ],
          rows: [
            usageRow('2026-09-25', output: 1200000, costUsd: 4.2),
            usageRow('2026-09-24', project: 'web'),
          ],
        ),
      ),
    );
    source = FakeUsageSource([usageHost('box', name: 'Box')], {'box': runner});
    store = MemoryUsagePreferencesStore();
  });

  UsageController controller(WidgetTester tester) {
    final c = UsageController(
      source: source,
      preferences: store,
      clock: () => now,
      observeLifecycle: false,
    );
    addTearDown(c.dispose);
    return c;
  }

  Widget app(Widget child) => MaterialApp(
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );

  /// Opens a folded section of the Usage tab or the explorer.
  Future<void> unfold(WidgetTester tester, String id) async {
    await tester.tap(find.byKey(ValueKey('usage-fold-$id')));
    await tester.pump();
  }

  test('ring colours: accent, then warning from 80 %, danger from 95 %', () {
    const palette = AppPalette.defaultPalette;
    expect(usageColor(79, palette), palette.accent);
    expect(usageColor(80, palette), palette.warning);
    expect(usageColor(95, palette), palette.danger);
  });

  testWidgets('the home bar shows the rings, today and polls while shown', (
    tester,
  ) async {
    final usage = controller(tester);
    await tester.pumpWidget(app(UsageHomeBar(controller: usage, now: now)));
    await tester.pump();
    expect(runner.commands, hasLength(1));
    expect(find.byKey(const ValueKey('usage-home-bar')), findsOneWidget);
    expect(find.text('83'), findsOneWidget);
    expect(find.text('20'), findsOneWidget);
    expect(find.text(r'1.2M tokens · $4.20 today'), findsOneWidget);
    // CON-080: no labels or explanations on the card, no age while fresh.
    expect(find.text('Today'), findsNothing);
    expect(find.text('API-price estimate'), findsNothing);
    expect(find.byKey(const ValueKey('usage-updated')), findsNothing);
    final ring = tester.widget<UsageRing>(
      find.byKey(const ValueKey('usage-ring-5h')),
    );
    expect(ring.percent, 83);

    // Collapsed: one line, remembered.
    await tester.tap(find.byKey(const ValueKey('usage-bar-toggle')));
    await tester.pump();
    expect(store.value.barCollapsed, isTrue);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('usage-collapsed-text')))
          .data,
      r'5h 83% · wk 20% · $4.20 today',
    );

    // Gone: polling stops.
    await tester.pumpWidget(app(const SizedBox()));
    expect(usage.isVisible, isFalse);
  });

  testWidgets('the home bar hides while no machine reports usage', (
    tester,
  ) async {
    source.hosts = [];
    final usage = controller(tester);
    await tester.pumpWidget(app(UsageHomeBar(controller: usage, now: now)));
    expect(find.byKey(const ValueKey('usage-home-bar')), findsNothing);
    expect(runner.commands, isEmpty);
  });

  testWidgets('the compact summary fits a sidebar footer', (tester) async {
    final usage = controller(tester);
    await tester.pumpWidget(
      app(
        SizedBox(
          width: 220,
          child: UsageSummaryView(
            controller: usage,
            layout: UsageSummaryLayout.compact,
            now: now,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.textContaining(r'83% · $4.20 today'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the breakdown groups by project, machine and model', (
    tester,
  ) async {
    final usage = controller(tester);
    await tester.pumpWidget(app(UsageBreakdown(controller: usage, now: now)));
    await tester.pump();
    expect(find.byKey(const ValueKey('usage-breakdown')), findsOneWidget);
    expect(find.text('Claude · 5-hour'), findsOneWidget);
    expect(find.text('Claude · Weekly'), findsOneWidget);
    expect(find.textContaining('83% · resets in 3h'), findsOneWidget);
    // The groups fold to their top row (CON-080).
    expect(find.text('api'), findsNothing);
    expect(
      find.byKey(const ValueKey('usage-fold-groups-summary')),
      findsOneWidget,
    );
    await unfold(tester, 'groups');
    expect(find.text('api'), findsOneWidget);
    expect(find.text('web'), findsOneWidget);
    expect(find.byKey(const ValueKey('usage-day-2026-09-25')), findsOneWidget);
    expect(find.byKey(const ValueKey('usage-day-2026-09-19')), findsOneWidget);

    await tester.tap(find.text('Model'));
    await tester.pump();
    expect(find.text('claude-opus-5'), findsOneWidget);
    await tester.tap(find.text('Machine'));
    await tester.pump();
    expect(find.text('Box'), findsOneWidget);
    expect(find.textContaining('API-equivalent cost'), findsOneWidget);
  });

  testWidgets('the breakdown offers the update for an old companion', (
    tester,
  ) async {
    runner.reply = () => FakeUsageRunner.ok({'error': 'unknown command usage'});
    final usage = controller(tester);
    String? updated;
    await tester.pumpWidget(
      app(
        UsageBreakdown(
          controller: usage,
          now: now,
          onUpdateCompanion: (hostId) => updated = hostId,
        ),
      ),
    );
    await tester.pump();
    expect(find.textContaining('needs 0.6.0'), findsOneWidget);
    await tester.tap(find.text('Update agent hooks'));
    expect(updated, 'box');
  });

  testWidgets('Codex limits show when a machine has Codex', (tester) async {
    runner.reply = () => FakeUsageRunner.ok(
      usageReplyJson(
        codex: {
          'present': true,
          'limits': [
            {'label': '5h', 'usedPct': 12},
          ],
          'rows': <Object?>[],
        },
      ),
    );
    final usage = controller(tester);
    await tester.pumpWidget(app(UsageBreakdown(controller: usage, now: now)));
    await tester.pump();
    // Folded to one line (CON-080), Codex's window in it.
    expect(find.text('Codex · 5-hour'), findsNothing);
    expect(find.text('Codex 12%'), findsOneWidget);
    await unfold(tester, 'agents');
    expect(find.text('Codex · 5-hour'), findsOneWidget);
    expect(usage.summary.codexPresent, isTrue);
    expect(
      usage.summary.codexLimits.single,
      const UsageLimit(label: '5h', usedPct: 12),
    );
  });

  testWidgets('Codex shows its active login and plan, nothing to switch', (
    tester,
  ) async {
    runner.reply = () => FakeUsageRunner.ok(
      usageReplyJson(
        codex: {
          'present': true,
          'limits': [
            {'label': '5h', 'usedPct': 40},
          ],
          'rows': <Object?>[],
          // What the companion's Codex adapter sends (CON-068): the
          // email masked, no slot, no token.
          'accounts': [
            {
              'label': 'd***@e***.com',
              'active': true,
              'plan': 'plus',
              'mode': 'chatgpt',
            },
          ],
        },
      ),
    );
    final usage = controller(tester);
    await tester.pumpWidget(app(UsageBreakdown(controller: usage, now: now)));
    await tester.pump();
    await unfold(tester, 'agents');
    expect(find.text('Codex account: d***@e***.com · Plus'), findsOneWidget);
    expect(find.text('Codex · 5-hour'), findsOneWidget);
    // Not one of Claude's cswap accounts.
    expect(find.byKey(const ValueKey('usage-accounts-chip')), findsNothing);
  });

  testWidgets('OpenCode: its model and reported cost, counted in the totals', (
    tester,
  ) async {
    // The `opencode` section as the companion's adapter builds it.
    runner.reply = () => FakeUsageRunner.ok(
      usageReplyJson(
        opencode: {
          'present': true,
          'limits': <Object?>[],
          'costSource': 'reported',
          'active': {'provider': 'opencode', 'model': 'mimo-v2.6-flash-free'},
          'today': {
            'input': 4000,
            'output': 1000,
            'cacheWrite': 0,
            'cacheRead': 0,
            'tokens': 5000,
            'messages': 3,
            'costUsd': 0.25,
          },
          'range': {
            'input': 4000,
            'output': 1000,
            'cacheWrite': 0,
            'cacheRead': 0,
            'tokens': 5000,
            'messages': 3,
            'costUsd': 0.25,
          },
          'rows': [
            {
              'date': '2026-09-25',
              'project': 'api',
              'model': 'opencode/mimo-v2.6-flash-free',
              'provider': 'opencode',
              'input': 4000,
              'output': 1000,
              'cacheWrite': 0,
              'cacheRead': 0,
              'messages': 3,
              'costUsd': 0.25,
            },
          ],
        },
      ),
    );
    final usage = controller(tester);
    await tester.pumpWidget(app(UsageBreakdown(controller: usage, now: now)));
    await tester.pump();
    expect(find.text('OpenCode'), findsOneWidget);
    await unfold(tester, 'agents');
    expect(
      find.text(
        'OpenCode: opencode/mimo-v2.6-flash-free · cost as reported by OpenCode',
      ),
      findsOneWidget,
    );
    final report = usage.summary.machines.single.report!;
    expect(report.opencode.present, isTrue);
    expect(report.opencode.agent, UsageAgent.opencode);
    expect(report.opencode.limits, isEmpty);
    expect(report.agents.map((s) => s.agent), contains(UsageAgent.opencode));
    expect(
      usage.summary.rows.where((r) => r.agent == UsageAgent.opencode),
      hasLength(1),
    );
    expect(usage.summary.todayFor(UsageAgent.opencode).costUsd, 0.25);
    expect(usage.summary.todayFor(UsageAgent.opencode).tokens, 5000);
  });

  group('cswap accounts', () {
    Map<String, Object?> reply({bool cswap = true}) => usageReplyJson(
      limits: [
        {
          'label': '5h',
          'usedPct': 83,
          'resetsAt': resets.millisecondsSinceEpoch,
        },
      ],
      accounts: [
        usageAccount(
          1,
          'work',
          active: true,
          fiveHour: 83,
          weekly: 20,
          fiveHourResets: resets,
          weeklyResets: resets.add(const Duration(days: 3)),
        ),
        usageAccount(
          2,
          'home',
          fiveHour: 12,
          weekly: 40,
          stale: true,
          usageAt: now.subtract(const Duration(hours: 11)),
        ),
        usageAccount(3, 'o***@e***.com', disabled: true, weekly: 99),
      ],
      cswap: cswap,
    );

    setUp(() {
      runner.reply = () => runner.commands.last.contains('cswap-switch')
          ? FakeUsageRunner.ok({
              'ok': true,
              'switched': true,
              'from': {'slot': 1, 'label': 'work'},
              'to': {'slot': 2, 'label': 'home'},
            })
          : FakeUsageRunner.ok(reply());
    });

    testWidgets('the breakdown lists every account with its rings', (
      tester,
    ) async {
      final usage = controller(tester);
      await tester.pumpWidget(app(UsageBreakdown(controller: usage, now: now)));
      await tester.pump();
      expect(find.byKey(const ValueKey('usage-accounts')), findsOneWidget);
      expect(find.text('Accounts'), findsOneWidget);
      // One line until tapped (CON-080).
      expect(find.byKey(const ValueKey('usage-account-home')), findsNothing);
      expect(find.text('3 accounts · best: home 40%'), findsOneWidget);
      await unfold(tester, 'accounts');
      for (final label in ['work', 'home', 'o***@e***.com']) {
        expect(find.byKey(ValueKey('usage-account-$label')), findsOneWidget);
      }
      expect(
        find.byKey(const ValueKey('usage-account-active-work')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('usage-account-active-home')),
        findsNothing,
      );
      // Two rings per account.
      final homeRings = find.descendant(
        of: find.byKey(const ValueKey('usage-account-home')),
        matching: find.byType(UsageRing),
      );
      expect(homeRings, findsNWidgets(2));
      expect(tester.widget<UsageRing>(homeRings.first).percent, 12);
      expect(tester.widget<UsageRing>(homeRings.last).percent, 40);
      expect(
        find.textContaining('resets 5h in 3h 0m · week in 3d 3h'),
        findsOneWidget,
      );
      // Every account's age (CON-067), not only stale ones.
      expect(find.textContaining('updated 11h ago'), findsOneWidget);
      // Disabled: greyed, no switch.
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('usage-account-o***@e***.com')),
          matching: find.byType(Opacity),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('disabled'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('usage-account-switch-o***@e***.com')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('usage-account-switch-work')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('usage-account-switch-home')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('usage-switch-best')), findsOneWidget);
    });

    testWidgets('switching asks first, then runs cswap-switch and refreshes', (
      tester,
    ) async {
      final usage = controller(tester);
      await tester.pumpWidget(app(UsageBreakdown(controller: usage, now: now)));
      await tester.pump();
      await unfold(tester, 'accounts');
      final before = runner.commands.length;

      await tester.tap(find.byKey(const ValueKey('usage-account-switch-home')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('usage-switch-confirm')),
        findsOneWidget,
      );
      expect(find.text('Switch to home?'), findsOneWidget);
      expect(find.textContaining('new Claude sessions on Box'), findsOneWidget);
      // Cancel: nothing runs.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(runner.commands, hasLength(before));

      await tester.tap(find.byKey(const ValueKey('usage-account-switch-home')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('usage-switch-confirm-box')));
      await tester.pumpAndSettle();
      expect(runner.commands[before], contains('cswap-switch 2'));
      // The machine is asked for usage again.
      expect(runner.commands.last, contains('usage --days'));
      expect(find.text('New Claude sessions now use home'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('usage-switch-best')));
      await tester.pumpAndSettle();
      expect(find.text('Switch to best account?'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('usage-switch-confirm-box')));
      await tester.pumpAndSettle();
      expect(
        runner.commands.where((c) => c.contains('cswap-switch --best')),
        hasLength(1),
      );
    });

    testWidgets('no switching when the companion does not report cswap', (
      tester,
    ) async {
      runner.reply = () => FakeUsageRunner.ok(reply(cswap: false));
      final usage = controller(tester);
      await tester.pumpWidget(app(UsageBreakdown(controller: usage, now: now)));
      await tester.pump();
      expect(find.byKey(const ValueKey('usage-accounts')), findsOneWidget);
      expect(find.text('Switch'), findsNothing);
      expect(find.byKey(const ValueKey('usage-switch-best')), findsNothing);
    });

    testWidgets('the home bar keeps the rings and adds N accounts', (
      tester,
    ) async {
      final usage = controller(tester);
      await tester.pumpWidget(app(UsageHomeBar(controller: usage, now: now)));
      await tester.pump();
      expect(
        tester
            .widget<UsageRing>(find.byKey(const ValueKey('usage-ring-5h')))
            .percent,
        83,
      );
      final chip = find.byKey(const ValueKey('usage-accounts-chip'));
      expect(chip, findsOneWidget);
      // Every account counts, the active and the disabled one too; "best"
      // measures the fuller window (home: 40 % weekly) against the active
      // one's 83 %.
      expect(find.text('3 accounts · best: home 40%'), findsOneWidget);
      await tester.tap(chip);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('usage-accounts')), findsOneWidget);
    });

    // CON-057: André's three accounts, the live one not in cswap.
    testWidgets('an unmanaged live login counts and lists, never switches', (
      tester,
    ) async {
      runner.reply = () => FakeUsageRunner.ok(
        usageReplyJson(
          limits: [
            {'label': '5h', 'usedPct': 38},
            {'label': '7d', 'usedPct': 96},
          ],
          accounts: [
            usageAccount(1, 'outsmartis', weekly: 100),
            usageAccount(2, 'webmaster', weekly: 100),
            usageUnmanagedAccount('a***@o***.com'),
          ],
        ),
      );
      final usage = controller(tester);
      await tester.pumpWidget(app(UsageHomeBar(controller: usage, now: now)));
      await tester.pump();
      expect(find.text('3 accounts'), findsOneWidget);
      await tester.pumpWidget(app(UsageBreakdown(controller: usage, now: now)));
      await tester.pump();
      await unfold(tester, 'accounts');
      for (final label in ['a***@o***.com', 'outsmartis', 'webmaster']) {
        expect(find.byKey(ValueKey('usage-account-$label')), findsOneWidget);
      }
      expect(
        find.byKey(const ValueKey('usage-account-active-a***@o***.com')),
        findsOneWidget,
      );
      // An older companion cannot tell whether cswap is right that this
      // login is none of its accounts (CON-067): only "Current login".
      expect(find.textContaining('Current login'), findsOneWidget);
      expect(find.textContaining('not in cswap'), findsNothing);
      expect(
        find.byKey(const ValueKey('usage-account-switch-a***@o***.com')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('usage-account-switch-outsmartis')),
        findsOneWidget,
      );
    });

    // CON-067: accounts cswap lost the login of, windows that ended, and
    // the unmanaged login only "not in cswap" when confirmed.
    testWidgets('needs re-login is labelled and greyed; ended windows say '
        'reset; ages show', (tester) async {
      runner.reply = () => FakeUsageRunner.ok(
        usageReplyJson(
          limits: [
            {
              'label': '7d',
              'usedPct': 52,
              'resetsAt': resets
                  .add(const Duration(days: 2))
                  .millisecondsSinceEpoch,
              'at': now
                  .subtract(const Duration(hours: 3))
                  .millisecondsSinceEpoch,
            },
          ],
          accounts: [
            usageAccount(
              1,
              'outsmartis',
              weekly: 100,
              weeklyResets: resets.add(const Duration(hours: 10)),
              status: 'relogin_required',
              stale: true,
              usageAt: now.subtract(const Duration(hours: 20)),
            ),
            usageAccount(
              3,
              'carol',
              weekly: 100,
              // Ended an hour ago, measured before.
              weeklyResets: now.subtract(const Duration(hours: 1)),
              usageAt: now.subtract(const Duration(hours: 2)),
            ),
            usageUnmanagedAccount(
              'g***@t***.pt',
              inCswap: false,
              limits: {
                '7d': {
                  'usedPct': 52,
                  'resetsAt': resets
                      .add(const Duration(days: 2))
                      .millisecondsSinceEpoch,
                  'expired': false,
                },
              },
              usageAt: now.subtract(const Duration(minutes: 8)),
            ),
          ],
        ),
      );
      final usage = controller(tester);
      await tester.pumpWidget(app(UsageBreakdown(controller: usage, now: now)));
      await tester.pump();
      // Folded: the count of logins lost (CON-080).
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('usage-fold-accounts-summary')),
            )
            .data,
        // Carol's week ended: the most headroom.
        '3 accounts · best: carol 0% · 1 needs re-login',
      );
      await unfold(tester, 'accounts');
      expect(find.textContaining('Needs re-login'), findsOneWidget);
      expect(
        tester
            .widget<Opacity>(
              find.byKey(const ValueKey('usage-account-greyed-outsmartis')),
            )
            .opacity,
        lessThan(1),
      );
      expect(
        find.byKey(const ValueKey('usage-account-greyed-carol')),
        findsNothing,
      );
      expect(find.textContaining('updated 20h ago'), findsOneWidget);
      // Carol's week ended: 0 %, "reset", never the old 100 %.
      final carolRings = find.descendant(
        of: find.byKey(const ValueKey('usage-account-carol')),
        matching: find.byType(UsageRing),
      );
      expect(tester.widget<UsageRing>(carolRings.last).percent, 0);
      expect(find.textContaining('week reset'), findsOneWidget);
      // Confirmed by the sessions' limits.
      expect(find.textContaining('Current login'), findsOneWidget);
      expect(find.textContaining('not in cswap'), findsOneWidget);
      expect(find.textContaining('updated 8m ago'), findsOneWidget);
      // The machine's limit bar says how old its figure is.
      expect(
        find.textContaining('52% · resets in 2d 3h · updated 3h ago'),
        findsOneWidget,
      );
    });

    testWidgets('the home bar hints at an account with more headroom', (
      tester,
    ) async {
      runner.reply = () => FakeUsageRunner.ok(
        usageReplyJson(
          accounts: [
            usageAccount(1, 'work', active: true, fiveHour: 90, weekly: 20),
            usageAccount(2, 'home', fiveHour: 12, weekly: 4),
          ],
        ),
      );
      final usage = controller(tester);
      await tester.pumpWidget(app(UsageHomeBar(controller: usage, now: now)));
      await tester.pump();
      expect(find.text('2 accounts · best: home 12%'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('usage-bar-toggle')));
      await tester.pump();
      // Collapsed: the count only.
      expect(find.text('2 acc'), findsOneWidget);
    });

    testWidgets('the compact summary shows the count; it opens the '
        'accounts', (tester) async {
      final usage = controller(tester);
      var tapped = 0;
      await tester.pumpWidget(
        app(
          SizedBox(
            width: 220,
            child: UsageSummaryView(
              controller: usage,
              layout: UsageSummaryLayout.compact,
              now: now,
              onTap: () => tapped++,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('3 acc'), findsOneWidget);
      expect(tester.takeException(), isNull);
      // The count opens the accounts in place; the rest opens the explorer.
      await tester.tap(find.byKey(const ValueKey('usage-accounts-chip')));
      await tester.pumpAndSettle();
      expect(tapped, 0);
      expect(find.byKey(const ValueKey('usage-details')), findsOneWidget);
      expect(find.byKey(const ValueKey('usage-account-home')), findsOneWidget);
    });

    testWidgets('an old companion without accounts changes nothing', (
      tester,
    ) async {
      runner.reply = () => FakeUsageRunner.ok(usageReplyJson());
      final usage = controller(tester);
      await tester.pumpWidget(
        app(
          Column(
            children: [
              UsageHomeBar(controller: usage, now: now),
              UsageBreakdown(controller: usage, now: now),
            ],
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('usage-accounts')), findsNothing);
      expect(find.byKey(const ValueKey('usage-accounts-chip')), findsNothing);
    });

    // CON-080: the home card is at most three lines on a 360 dp phone,
    // and everything it leaves out is one tap away.
    group('compact home card', () {
      Map<String, Object?> busy() => usageReplyJson(
        limits: [
          {
            'label': '5h',
            'usedPct': 91,
            'resetsAt': resets.millisecondsSinceEpoch,
            'at': now
                .subtract(const Duration(minutes: 40))
                .millisecondsSinceEpoch,
          },
          {'label': '7d', 'usedPct': 64},
        ],
        accounts: [
          usageAccount(1, 'work-account', active: true, fiveHour: 91),
          usageAccount(2, 'home-account', fiveHour: 5, weekly: 10),
          usageAccount(
            3,
            'outsmartis-long-account-name',
            weekly: 100,
            status: 'relogin_required',
            stale: true,
          ),
          usageUnmanagedAccount('g***@t***.pt', inCswap: false),
        ],
        rows: [usageRow('2026-09-25', output: 123456789, costUsd: 1234.5)],
      );

      Future<void> phone(WidgetTester tester, Widget child) async {
        tester.view.physicalSize = const Size(360, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: Column(children: [child])),
          ),
        );
        await tester.pump();
      }

      testWidgets('at most three lines at 360 dp, no overflow', (tester) async {
        runner.reply = () => FakeUsageRunner.ok(busy());
        final usage = controller(tester);
        await phone(tester, UsageHomeBar(controller: usage, now: now));
        expect(tester.takeException(), isNull);
        final lines = find.descendant(
          of: find.byKey(const ValueKey('usage-home-lines')),
          matching: find.byType(Text),
        );
        expect(lines, findsNWidgets(3));
        for (final text in tester.widgetList<Text>(lines)) {
          expect(text.maxLines, 1);
        }
        expect(
          find.text('4 accounts · best: home-account 10% · 1 needs re-login'),
          findsOneWidget,
        );
        // 40 minutes old: stale, so it says so.
        expect(
          tester.widget<Text>(find.byKey(const ValueKey('usage-updated'))).data,
          'Updated 40m ago',
        );
        // Three lines' height beside the rings, no more.
        expect(
          tester.getSize(find.byKey(const ValueKey('usage-home-bar'))).height,
          lessThanOrEqualTo(80),
        );
        expect(find.textContaining('Needs re-login'), findsNothing);
        expect(find.textContaining('cswap'), findsNothing);
      });

      testWidgets('the details are one tap away', (tester) async {
        runner.reply = () => FakeUsageRunner.ok(busy());
        final usage = controller(tester);
        await phone(tester, UsageHomeBar(controller: usage, now: now));
        await tester.tap(find.byKey(const ValueKey('usage-accounts-chip')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('usage-details')), findsOneWidget);
        expect(tester.takeException(), isNull);
        // Everything CON-067 shows: limits with resets and ages, each
        // account's state, Switch, and what the cost means.
        expect(
          find.textContaining('91% · resets in 3h 0m · updated 40m ago'),
          findsOneWidget,
        );
        expect(find.text('Limits updated 40m ago.'), findsOneWidget);
        expect(find.textContaining('API-equivalent cost'), findsOneWidget);
        expect(find.textContaining('Needs re-login'), findsOneWidget);
        expect(find.textContaining('not in cswap'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('usage-account-switch-home-account')),
          findsOneWidget,
        );
        // And the explorer from there.
        await tester.tap(find.byKey(const ValueKey('usage-details-explore')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('usage-explorer-page')),
          findsOneWidget,
        );
        await tester.pumpWidget(const SizedBox());
      });

      testWidgets('fresh figures carry no age; one account no accounts line', (
        tester,
      ) async {
        runner.reply = () => FakeUsageRunner.ok(
          usageReplyJson(
            limits: [
              {
                'label': '5h',
                'usedPct': 20,
                'at': now
                    .subtract(const Duration(minutes: 15))
                    .millisecondsSinceEpoch,
              },
            ],
            accounts: [usageAccount(1, 'work', active: true, fiveHour: 20)],
          ),
        );
        final usage = controller(tester);
        await phone(tester, UsageHomeBar(controller: usage, now: now));
        expect(find.byKey(const ValueKey('usage-updated')), findsNothing);
        expect(find.byKey(const ValueKey('usage-accounts-chip')), findsNothing);
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('usage-home-lines')),
            matching: find.byType(Text),
          ),
          findsOneWidget,
        );
      });
    });
  });
}
