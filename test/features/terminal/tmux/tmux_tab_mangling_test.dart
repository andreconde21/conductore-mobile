import 'package:conduit/features/sessions/domain/remote_session_listing.dart';
import 'package:conduit/features/terminal/domain/multiplexer_tabs.dart';
import 'package:conduit/features/terminal/domain/tmux_navigator.dart';
import 'package:flutter_test/flutter_test.dart';

// CON-071: tmux 3.3a and 3.4 print a format's tabs as `_` to a client they
// take for non-UTF-8 (LANG unset or C, common on an SSH exec channel). The
// lines below are what both printed in Docker for the app's own formats,
// without and with `-u`.
void main() {
  const sessionsTabbed = 'my_sess\t0\t2\t1791145544\n';
  const sessionsMangled = 'my_sess_0_2_1791145544\n';
  const windowsTabbed =
      'W\t@0\t0\t0\t0\t0\t1791145544\tw name\n'
      'W\t@1\t1\t1\t0\t0\t1791145544\ttwo\n';
  const windowsMangled =
      'W_@0_0_0_0_0_1791145544_w name\n'
      'W_@1_1_1_0_0_1791145544_two\n';
  const panesTabbed =
      'C\t/dev/pts/3\tmy_sess\t\$0\t@1\t%1\t1791145544\n'
      'P\t\$0\tmy_sess\t@0\t0\t0\t%0\t0\t1\t0\tsleep\t/\tw name\t830f03fe06e9\n'
      'P\t\$0\tmy_sess\t@1\t1\t1\t%1\t0\t1\t0\tsleep\t/\ttwo\t830f03fe06e9\n';
  const panesMangled =
      'C_/dev/pts/3_my_sess_\$0_@1_%1_1791145544\n'
      'P_\$0_my_sess_@0_0_0_%0_0_1_0_sleep_/_w name_830f03fe06e9\n'
      'P_\$0_my_sess_@1_1_1_%1_0_1_0_sleep_/_two_830f03fe06e9\n';

  test('every listing runs tmux -u', () {
    expect(RemoteSessionListing.tmuxListCommand, startsWith('tmux -u '));
    expect(TmuxWindowCommands.list('s'), contains('exec tmux -u list-windows'));
    expect(TmuxCommands.listing, contains('exec tmux -u list-clients'));
  });

  test('list-sessions: both forms give the same sessions', () {
    for (final raw in [sessionsTabbed, sessionsMangled]) {
      final sessions = RemoteSessionListing.parseTmuxSessions(raw);
      expect(sessions.single.name, 'my_sess', reason: raw);
      expect(sessions.single.attachedClients, 0);
      expect(sessions.single.windows, 2);
      expect(sessions.single.lastActivity, isNotNull);
    }
  });

  test('list-windows: both forms give the same tabs', () {
    for (final raw in [windowsTabbed, windowsMangled]) {
      final tabs = TmuxWindowCommands.parse(raw);
      expect(
        [for (final t in tabs) (t.id, t.index, t.active, t.label)],
        [('@0', 0, false, 'w name'), ('@1', 1, true, 'two')],
        reason: raw,
      );
    }
  });

  test('the navigator listing: clients and panes from both forms', () {
    for (final raw in [panesTabbed, panesMangled]) {
      final snapshot = TmuxNavigator.parse(raw);
      final client = snapshot.clients.single;
      expect(
        (client.name, client.sessionName, client.paneId),
        ('/dev/pts/3', 'my_sess', '%1'),
        reason: raw,
      );
      expect(
        [
          for (final p in snapshot.panes)
            (p.sessionName, p.windowId, p.windowActive, p.paneId, p.command),
        ],
        [
          ('my_sess', '@0', false, '%0', 'sleep'),
          ('my_sess', '@1', true, '%1', 'sleep'),
        ],
        reason: raw,
      );
    }
    // With tabs, the free text is exact.
    final tabbed = TmuxNavigator.parse(panesTabbed).panes.first;
    expect((tabbed.path, tabbed.windowName), ('/', 'w name'));
  });
}
