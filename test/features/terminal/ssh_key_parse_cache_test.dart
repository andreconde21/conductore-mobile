import 'package:conduit/features/terminal/data/ssh_client_factory.dart';
import 'package:flutter_test/flutter_test.dart';

/// A throwaway test key (ed25519, one bcrypt round), passphrase
/// `test-passphrase`.
const _encryptedPem = '''
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABDs0IVLFa
2VYvT+tUhlvi+dAAAAAQAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIETkGPCEoAMIdJtA
Fcu5ZDP7GuUjjwM9VQM1vgeNz84eAAAAoDMut/Y/27OqoJ2skqrpf35OjA7GGFiGJb8gHG
fv6SYQQIISp4WGHDd8rWNZSxbEtTIb7wQ0b22o3ZgXPLukQOhwST+iB/X+ve4Cq1W4yJOg
9sT/z41qbVBKnzCqWLzyl/ts7TdhE/2GSOJMYSSwwOdq93+0qdojvttYawE2ViiAVvcgzz
wT7hCgswAIIfRqtXNNM2UF8IlaAW6Y+c4lq9k=
-----END OPENSSH PRIVATE KEY-----
''';

void main() {
  test('a passphrase-protected key is decrypted once per run', () {
    // CON-058: every connection (each terminal, the side connection)
    // decrypted it again, about 1.5 s of the UI isolate at the default
    // 16 bcrypt rounds.
    final first = SshClientFactory.parseKeyPairs(
      _encryptedPem,
      'test-passphrase',
    );
    final again = SshClientFactory.parseKeyPairs(
      _encryptedPem,
      'test-passphrase',
    );
    expect(first, hasLength(1));
    expect(identical(first, again), isTrue);
  });

  test('a wrong passphrase fails every time, and is not remembered', () {
    for (var i = 0; i < 2; i++) {
      expect(
        () => SshClientFactory.parseKeyPairs(_encryptedPem, 'wrong'),
        throwsA(anything),
      );
    }
    expect(
      SshClientFactory.parseKeyPairs(_encryptedPem, 'test-passphrase'),
      hasLength(1),
    );
  });
}
