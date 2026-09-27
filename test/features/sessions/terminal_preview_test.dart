import 'package:conduit/features/sessions/presentation/terminal_preview.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:conduit_vt/conduit_vt.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

void main() {
  group('TerminalPreview', () {
    test('captures the last rows of the viewport, trimmed and cut', () {
      final terminal = Terminal(maxLines: 100)..resize(40, 6);
      terminal.write('one\r\ntwo\r\nthree is a rather long line\r\n');

      final preview = TerminalPreview.capture(terminal, rows: 2, columns: 8);

      expect(preview.lines, ['two', 'three is']);
      expect(preview.isEmpty, isFalse);
    });

    test('is empty for a blank terminal', () {
      final terminal = Terminal(maxLines: 100)..resize(20, 4);
      expect(TerminalPreview.capture(terminal), TerminalPreview.empty);
    });

    test('follows scrollback so only the visible screen is captured', () {
      final terminal = Terminal(maxLines: 100)..resize(10, 3);
      for (var index = 0; index < 10; index++) {
        terminal.write('line $index\r\n');
      }
      final preview = TerminalPreview.capture(terminal, rows: 10);
      // 3 rows visible; the last write leaves a blank cursor row that is
      // trimmed.
      expect(preview.lines, ['line 8', 'line 9']);
    });
  });

  group('TerminalSessionController rename', () {
    test('overrides the title until cleared', () {
      final controller = TerminalSessionController(
        host: buildHost('h'),
        repository: ImmediateTerminalRepository(TrackableTerminalSession()),
      );
      addTearDown(controller.dispose);
      var notified = 0;
      controller.addListener(() => notified += 1);

      controller.rename('  Deploys  ');
      expect(controller.title, 'Deploys');
      expect(controller.customTitle, 'Deploys');
      controller.rename('');
      expect(controller.title, controller.host.name);
      expect(controller.customTitle, isNull);
      expect(notified, 2);
    });
  });

  group('TerminalSessionController startup', () {
    test('types the startup command after connecting', () async {
      final session = TrackableTerminalSession();
      final controller = TerminalSessionController(
        host: buildHost('h'),
        repository: ImmediateTerminalRepository(session),
        startupCommand: 'herdr workspace focus wX >/dev/null 2>&1; herdr',
      );
      addTearDown(controller.dispose);

      await controller.connect();
      await pumpEventQueue();

      expect(session.sent.map(String.fromCharCodes), [
        'herdr workspace focus wX >/dev/null 2>&1; herdr\r',
      ]);
    });

    test('startup command wins over tmux-on-connect', () async {
      final session = TrackableTerminalSession();
      final controller = TerminalSessionController(
        host: buildHost('h').copyWith(startTmuxOnConnect: true),
        repository: ImmediateTerminalRepository(session),
        startupCommand: 'herdr',
      );
      addTearDown(controller.dispose);

      await controller.connect();
      await pumpEventQueue();

      expect(session.sent.map(String.fromCharCodes), ['herdr\r']);
    });

    test('tracks the terminal title set by the remote side', () {
      final controller = TerminalSessionController(
        host: buildHost('h'),
        repository: ImmediateTerminalRepository(TrackableTerminalSession()),
      );
      addTearDown(controller.dispose);
      var notified = 0;
      var sessionNotified = 0;
      controller.terminalTitleListenable.addListener(() => notified += 1);
      controller.addListener(() => sessionNotified += 1);

      controller.terminal.write('\x1b]0;dev: Infrastructure\x07');
      expect(controller.terminalTitle, 'dev: Infrastructure');
      expect(notified, 1);

      controller.terminal.write('\x1b]0;dev: Infrastructure\x07');
      expect(notified, 1);

      // A title spinner must not rebuild everything that watches the
      // session (the terminal page, the workspace, agent attention).
      for (final frame in ['⠋', '⠙', '⠹']) {
        controller.terminal.write('\x1b]2;$frame Claude Code\x07');
      }
      expect(notified, 4);
      expect(sessionNotified, 0);
    });
  });
}
