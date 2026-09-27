import 'package:conduit/core/telemetry/telemetry_scrubber.dart';
import 'package:conduit/core/telemetry/telemetry_terms.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/snippets/domain/terminal_snippet.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final scrubber = TelemetryScrubber();

  /// [input] scrubbed, checked to contain none of [secrets].
  String clean(String input, List<String> secrets, [TelemetryScrubber? s]) {
    final out = (s ?? scrubber).scrub(input);
    for (final secret in secrets) {
      expect(
        out.toLowerCase(),
        isNot(contains(secret.toLowerCase())),
        reason: '"$secret" leaked from "$input" as "$out"',
      );
    }
    return out;
  }

  group('addresses', () {
    test('IPv4, with and without a port', () {
      expect(
        clean(
          'SocketException: Connection refused, address = 10.0.0.2, '
          'port = 45678',
          ['10.0.0.2', '45678'],
        ),
        'SocketException: Connection refused, address = <ip>, port = <port>',
      );
      expect(
        clean('connect 192.168.1.20:2222 failed', ['192.168', '2222']),
        'connect <ip> failed',
      );
    });

    test('IPv6: full, compressed, loopback, link-local with zone', () {
      clean('to 2001:db8:85a3::8a2e:370:7334 failed', ['2001:db8', '7334']);
      clean('[fe80::1ff:fe23:4567:890a%wlan0]:22', ['fe80', '890a', 'wlan0']);
      clean('bind ::1 refused', ['::1']);
    });

    test('hostnames and domain names', () {
      clean('Could not connect to build-box.tail574592.ts.net:22.', [
        'build-box',
        'tail574592',
        'ts.net',
      ]);
      clean('Failed host lookup: myserver.local', ['myserver']);
    });

    test('URLs, including credentials and paths', () {
      final out = clean(
        'GET https://admin:hunter2@git.example.com/org/repo?token=abc failed',
        ['admin', 'hunter2', 'example.com', 'org/repo', 'token=abc'],
      );
      expect(out, contains('<url>'));
      clean('opened file:///home/andre/notes.txt', ['andre', 'notes.txt']);
    });
  });

  group('users', () {
    test('user@host in any form', () {
      clean('ssh andre@devbox', ['andre', 'devbox']);
      clean('root@10.1.2.3 denied', ['root', '10.1.2.3']);
      clean('mail me: jane.doe+ci@example.org', ['jane', 'example.org']);
    });

    test('keeps Dart private names with an @ library suffix', () {
      expect(
        scrubber.scrub("Field '_session@17123' has not been initialized"),
        contains('_session@17123'),
      );
    });
  });

  group('paths', () {
    test('home directories and other absolute paths', () {
      clean(
        'PathNotFoundException: Cannot open file, path = '
        "'/home/andre/projects/secret-plan.md'",
        ['andre', 'secret-plan', 'projects'],
      );
      clean('No such file: /Users/jane/Desktop/keys', ['jane', 'desktop']);
      clean('cd ~/work/client-x', ['client-x', 'work']);
      clean(r'C:\Users\Bob\Documents\todo.txt missing', ['bob', 'todo']);
      clean(r'\\nas\share\private missing', ['nas', 'private']);
      clean('/root/.ssh/id_ed25519', ['.ssh', 'id_ed25519']);
    });

    test('file names', () {
      clean('Could not open "q3 budget.xlsx"', ['budget']);
      clean('upload of report.pdf failed', ['report.pdf']);
    });

    test('keeps package: and dart: code locations', () {
      final out = scrubber.scrub(
        'at package:conduit/features/terminal/presentation/'
        'terminal_page.dart:120 and dart:async/zone.dart',
      );
      expect(
        out,
        contains(
          'package:conduit/features/terminal/presentation/'
          'terminal_page.dart',
        ),
      );
      expect(out, contains('dart:async/zone.dart'));
    });
  });

  group('review L10', () {
    test('single-quoted names and one-word hosts', () {
      expect(
        clean("Failed host lookup: 'buildserver'", ['buildserver']),
        "Failed host lookup: '<text>'",
      );
      clean('Failed host lookup: buildserver (OS Error)', ['buildserver']);
      clean('SocketException: host = Buildserver, port = 22', ['buildserver']);
      clean("no workspace 'Acme Payroll' in session", ['acme', 'payroll']);
    });

    test('relative and branch paths', () {
      clean('checkout of feature/acme-merger failed', ['acme-merger']);
      clean('cannot open src/acme/secret_plan.dart', ['acme', 'secret_plan']);
    });

    test('keeps Dart identifiers, types and apostrophes', () {
      const message =
          "type 'String' is not a subtype of type 'List<int>?' in 'dispose()'; "
          "can't retry, don't know";
      expect(scrubber.scrub(message), message);
      expect(scrubber.scrub('Host is down'), 'Host is down');
    });
  });

  group('secrets', () {
    test('PEM keys, OpenSSH public keys, hex and base64 tokens', () {
      clean(
        '-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA\n'
        '-----END OPENSSH PRIVATE KEY-----',
        ['b3BlbnNzaC1rZXktdjEAAAAA', 'OPENSSH PRIVATE'],
      );
      clean('offered ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMq5 user', [
        'AAAAC3NzaC1lZDI1NTE5',
      ]);
      clean('fingerprint SHA256:nThbg6kXUpJWGl7E1IGOCspRomTxdCARLviKw6E5SY8', [
        'nThbg6kXUpJWGl7E1IGOCspRomTxdCARLviKw6E5SY8',
      ]);
      clean('session deadbeefcafebabe0123456789abcdef expired', [
        'deadbeefcafebabe',
      ]);
      clean('MD5 43:51:43:a1:b5:fc:8b:b7:0a:3a:a9:b1:0f:66:73:a8', ['43:51']);
      clean('Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.abc123XYZ', [
        'eyJhbGciOiJIUzI1NiJ9',
      ]);
    });

    test('keeps long plain identifiers', () {
      const message =
          'setState() called after dispose(): _TerminalWorkspaceControllerState';
      expect(scrubber.scrub(message), message);
    });
  });

  group('saved machines', () {
    const host = SavedHost(
      id: 'h1',
      name: 'Kitchen Pi',
      host: 'pi-kitchen',
      port: 2202,
      username: 'grandma',
      authMethod: SshAuthMethod.password,
      password: 'correcthorse',
      tags: ['family'],
      tmuxSessionName: 'blog-drafts',
      tmuxStartDirectory: 'srv',
      snippets: [
        TerminalSnippet(id: 's', label: 'Deploy blog', text: 'make ship'),
      ],
    );
    final withHosts = TelemetryScrubber(
      sensitiveTerms: () => savedHostTerms([host]),
    );

    test('labels, hosts, users, passwords, tags, tmux names, snippets', () {
      clean(
        'Could not connect to pi-kitchen (Kitchen Pi) as GRANDMA: '
        'correcthorse rejected; tag family; tmux blog-drafts in srv; '
        'Deploy blog ran make ship',
        [
          'pi-kitchen',
          'kitchen pi',
          'grandma',
          'correcthorse',
          'family',
          'blog-drafts',
          'deploy blog',
          'make ship',
        ],
        withHosts,
      );
    });

    test('matches whole words only', () {
      final s = TelemetryScrubber(sensitiveTerms: () => ['dev']);
      expect(s.scrub('the device is dev'), 'the device is <redacted>');
    });

    test('reads the terms at every scrub', () {
      final terms = <String>[];
      final s = TelemetryScrubber(sensitiveTerms: () => terms);
      expect(s.scrub('hello zorro'), 'hello zorro');
      terms.add('zorro');
      expect(s.scrub('hello zorro'), 'hello <redacted>');
    });
  });

  group('limits', () {
    test('caps lines and length', () {
      final many = List.generate(30, (i) => 'line $i').join('\n');
      final out = scrubber.scrub(many);
      expect(out.split('\n'), hasLength(TelemetryScrubber.maxLines));
      expect(out, endsWith('…'));
      expect(
        scrubber.scrub('x ' * 1000).length,
        lessThanOrEqualTo(TelemetryScrubber.maxLength + 1),
      );
    });

    test('leaves ordinary Flutter errors readable', () {
      const overflow = 'A RenderFlex overflowed by 12.5 pixels on the right.';
      expect(scrubber.scrub(overflow), overflow);
      const cast = "type 'Null' is not a subtype of type 'String' in type cast";
      expect(scrubber.scrub(cast), cast);
      expect(scrubber.scrub('Bad state: No element'), 'Bad state: No element');
    });
  });
}
