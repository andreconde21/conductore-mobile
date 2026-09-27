import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/terminal/domain/security_key_interaction.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

String _screen(TerminalSessionController c) =>
    c.terminal.buffer.lines.toList().map((l) => l.toString()).join('\n');

void main() {
  test('a security-key prompt shows only in sessions signing in with a '
      'hardware key', () async {
    final keyRepo = PendingTerminalRepository();
    final passwordRepo = PendingTerminalRepository();
    final key = TerminalSessionController(
      host: buildHost(
        'k',
      ).copyWith(authMethod: SshAuthMethod.hardwareKey, password: ''),
      repository: keyRepo,
    );
    final password = TerminalSessionController(
      host: buildHost('p'),
      repository: passwordRepo,
    );
    addTearDown(key.dispose);
    addTearDown(password.dispose);

    // Both are connecting when the key asks for a touch.
    final connecting = [key.connect(), password.connect()];
    await pumpEventQueue();
    SecurityKeyInteraction.instance.announce('Touch your security key');
    await pumpEventQueue();
    expect(_screen(key), contains('Touch your security key'));
    expect(_screen(password), isNot(contains('Touch your security key')));

    keyRepo.complete(FakeTerminalSession());
    passwordRepo.complete(FakeTerminalSession());
    await Future.wait(connecting);
  });
}
