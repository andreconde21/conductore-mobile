import 'package:conduit/features/sessions/domain/connect_preferences.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

void main() {
  group('ConnectTarget', () {
    test('shell target leaves the host untouched', () {
      final host = buildHost('h');
      const target = ConnectTarget.shell();

      expect(target.apply(host), same(host));
      expect(target.startupCommand, isNull);
      expect(target.key, 'shell');
    });

    test('tmux target derives the host id and reuses tmux-on-connect', () {
      final host = buildHost('h').copyWith(tmuxStartDirectory: '~/work');
      const target = ConnectTarget.tmux('build');

      final applied = target.apply(host);
      expect(applied.id, 'h#tmux:build');
      expect(applied.name, 'Host h: build');
      expect(applied.startTmuxOnConnect, isTrue);
      expect(applied.tmuxSessionName, 'build');
      expect(applied.tmuxStartDirectory, '~/work');
      expect(applied.password, host.password);
      expect(target.startupCommand, isNull);
      expect(baseHostId(applied.id), 'h');
    });

    test('herdr target focuses the workspace then attaches', () {
      const target = ConnectTarget.herdr(
        workspaceId: 'wX',
        label: 'Conductore-Mobile',
      );
      final applied = target.apply(
        buildHost('h').copyWith(startTmuxOnConnect: true),
      );

      expect(applied.id, 'h#herdr:wX');
      expect(applied.name, 'Host h: Conductore-Mobile');
      expect(applied.startTmuxOnConnect, isFalse);
      expect(
        target.startupCommand,
        'herdr workspace focus wX >/dev/null 2>&1; herdr',
      );
    });

    test('herdr tab target focuses the tab', () {
      const target = ConnectTarget.herdr(workspaceId: 'w4', tabId: 'w4:t4');
      expect(target.key, 'herdr:w4:w4:t4');
      expect(
        target.startupCommand,
        'herdr tab focus w4:t4 >/dev/null 2>&1; herdr',
      );
    });

    test('bare herdr target just launches herdr', () {
      const target = ConnectTarget.herdr(workspaceId: '');
      expect(target.key, 'herdr');
      expect(target.title, 'Herdr');
      expect(target.startupCommand, 'herdr');
    });

    test('quotes unusual ids in the attach command', () {
      const target = ConnectTarget.herdr(workspaceId: "it's");
      expect(
        target.startupCommand,
        "herdr workspace focus 'it'\\''s' >/dev/null 2>&1; herdr",
      );
    });

    test('round-trips through JSON', () {
      const targets = [
        ConnectTarget.shell(),
        ConnectTarget.tmux('main'),
        ConnectTarget.herdr(workspaceId: 'w1', label: 'L', tabId: 'w1:t2'),
        ConnectTarget.herdr(workspaceId: ''),
      ];
      for (final target in targets) {
        expect(ConnectTarget.fromJson(target.toJson()), target);
      }
      expect(ConnectTarget.fromJson({'kind': 'tmux', 'name': ''}), isNull);
      expect(ConnectTarget.fromJson({'kind': 'nope'}), isNull);
      expect(ConnectTarget.fromJson('junk'), isNull);
    });

    test('rebuilds the target from a session host id', () {
      expect(ConnectTarget.fromSessionHostId('h'), isNull);
      expect(
        ConnectTarget.fromSessionHostId('h#tmux:dev'),
        const ConnectTarget.tmux('dev'),
      );
      expect(
        ConnectTarget.fromSessionHostId('h#herdr:wX'),
        const ConnectTarget.herdr(workspaceId: 'wX'),
      );
      expect(
        ConnectTarget.fromSessionHostId('h#herdr:wX:wX:t1'),
        const ConnectTarget.herdr(workspaceId: 'wX', tabId: 'wX:t1'),
      );
      expect(
        ConnectTarget.fromSessionHostId('h#herdr'),
        const ConnectTarget.herdr(workspaceId: ''),
      );
      expect(
        ConnectTarget.fromSessionHostId('h#shell'),
        const ConnectTarget.shell(),
      );
      expect(ConnectTarget.fromSessionHostId('h#zellij:x'), isNull);
    });

    test('a named Herdr session is part of the key and the commands', () {
      const target = ConnectTarget.herdr(
        workspaceId: 'w2',
        label: 'work ‧ api',
        session: 'work',
      );
      expect(target.key, 'herdr@work:w2');
      expect(
        target.startupCommand,
        'herdr --session work workspace focus w2 >/dev/null 2>&1; '
        'herdr --session work',
      );
      expect(
        ConnectTarget.fromSessionHostId('h#herdr@work:w2'),
        const ConnectTarget.herdr(workspaceId: 'w2', session: 'work'),
      );
      expect(
        ConnectTarget.fromSessionHostId('h#herdr@work:w2:w2:t3'),
        const ConnectTarget.herdr(
          workspaceId: 'w2',
          tabId: 'w2:t3',
          session: 'work',
        ),
      );
      expect(
        ConnectTarget.fromSessionHostId('h#herdr@work'),
        const ConnectTarget.herdr(workspaceId: '', session: 'work'),
      );
      expect(ConnectTarget.fromSessionHostId('h#herdr@:w2'), isNull);
      expect(ConnectTarget.fromJson(target.toJson()), target);
    });

    test('a pane target focuses the agent pane, the tab only if that '
        'fails', () {
      const target = ConnectTarget.herdr(
        workspaceId: 'w1',
        tabId: 'w1:t2',
        paneId: 'w1:p5',
      );
      expect(target.key, 'herdr:w1:w1:t2');
      // `agent focus` switches workspace and tab itself (Herdr 0.9.1):
      // one herdr call before the attach, not two.
      expect(
        target.startupCommand,
        'herdr agent focus w1:p5 >/dev/null 2>&1 || '
        'herdr tab focus w1:t2 >/dev/null 2>&1; herdr',
      );
      expect(ConnectTarget.withoutHerdrFocus(target.startupCommand!), 'herdr');
    });

    test('a deep link to a pane falls back to its workspace', () {
      const target = ConnectTarget.herdr(workspaceId: 'w1', paneId: 'w1:p5');
      expect(
        target.startupCommand,
        'herdr agent focus w1:p5 >/dev/null 2>&1 || '
        'herdr workspace focus w1 >/dev/null 2>&1; herdr',
      );
    });
  });

  group('ConnectPreferences', () {
    test('records choices most recent first without duplicates', () {
      var preferences = const ConnectPreferences();
      preferences = preferences.withChoice(
        const ConnectTarget.tmux('a'),
        remember: false,
      );
      preferences = preferences.withChoice(
        const ConnectTarget.herdr(workspaceId: 'w1', label: 'One'),
        remember: true,
      );
      preferences = preferences.withChoice(
        const ConnectTarget.tmux('a'),
        remember: true,
      );

      expect(preferences.rememberChoice, isTrue);
      expect(preferences.lastTarget, const ConnectTarget.tmux('a'));
      expect(preferences.recents.map((target) => target.key), [
        'tmux:a',
        'herdr:w1',
      ]);
    });

    test('does not keep a plain shell as a recent', () {
      final preferences = const ConnectPreferences().withChoice(
        const ConnectTarget.shell(),
        remember: true,
      );
      expect(preferences.lastTarget, const ConnectTarget.shell());
      expect(preferences.recents, isEmpty);
    });

    test('caps recents and survives JSON', () {
      var preferences = const ConnectPreferences();
      for (var index = 0; index < 12; index++) {
        preferences = preferences.withChoice(
          ConnectTarget.tmux('s$index'),
          remember: false,
        );
      }
      expect(preferences.recents, hasLength(ConnectPreferences.maxRecents));
      expect(preferences.recents.first, const ConnectTarget.tmux('s11'));

      final restored = ConnectPreferences.fromJson(preferences.toJson());
      expect(restored.rememberChoice, isFalse);
      expect(restored.lastTarget, const ConnectTarget.tmux('s11'));
      expect(restored.recents, preferences.recents);
      expect(ConnectPreferences.fromJson(null).recents, isEmpty);
    });

    test('the last agent started is kept per machine (CON-071)', () {
      final preferences = const ConnectPreferences(
        lastAgent: 'codex',
      ).withChoice(const ConnectTarget.tmux('a'), remember: false);
      expect(preferences.lastAgent, 'codex');
      expect(
        ConnectPreferences.fromJson(preferences.toJson()).lastAgent,
        'codex',
      );
      expect(preferences.copyWith(lastAgent: '').lastAgent, '');
      expect(const ConnectPreferences().toJson(), isNot(contains('lastAgent')));
      expect(ConnectPreferences.fromJson(const {}).lastAgent, isNull);
    });
  });
}
