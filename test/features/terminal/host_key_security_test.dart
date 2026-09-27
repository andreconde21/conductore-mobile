import 'dart:convert';
import 'dart:typed_data';

import 'package:conduit/features/terminal/data/host_key_capture.dart';
import 'package:conduit/features/terminal/data/secure_host_key_verifier.dart';
import 'package:conduit/features/terminal/domain/host_key_prompt.dart';
import 'package:conduit/features/terminal/domain/host_key_verifier.dart';
import 'package:conduit/features/terminal/presentation/host_key_prompt_dialog.dart';
import 'package:conduit/features/this_computer/domain/self_machine.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

// `ssh-keygen -lf` of this key prints the SHA256 and MD5 below.
const _publicKey =
    'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN64D+Ktc+ucaeD19CYaP/xuyj7BwHoAZF0J'
    '+CWmo2jL test';
const _sha256 = 'SHA256:52DIyFBmzx+JLE8YsfsyGAWjwZ3/8rnOQd8M85ujSD8';
const _md5 = 'MD5:09:c8:bb:df:33:67:93:3e:57:e9:df:f0:1c:1d:ed:9e';

Uint8List get _blob => base64.decode(_publicKey.split(' ')[1]);

List<int> _u32(int value) => [
  (value >> 24) & 0xff,
  (value >> 16) & 0xff,
  (value >> 8) & 0xff,
  value & 0xff,
];

List<int> _string(List<int> bytes) => [..._u32(bytes.length), ...bytes];

/// One unencrypted SSH binary packet carrying [payload].
List<int> _packet(List<int> payload) {
  var padding = 8 - ((payload.length + 5) % 8);
  if (padding < 4) padding += 8;
  return [
    ..._u32(payload.length + padding + 1),
    padding,
    ...payload,
    ...List.filled(padding, 0),
  ];
}

/// What a server sends up to NEWKEYS in a curve25519 key exchange.
List<int> _serverHandshake() => [
  ...utf8.encode('SSH-2.0-OpenSSH_9.6\r\n'),
  ..._packet([20, ...List.filled(16, 7), ..._string(utf8.encode('x'))]),
  ..._packet([
    31,
    ..._string(_blob),
    ..._string(List.filled(32, 1)),
    ..._string(List.filled(83, 2)),
  ]),
  ..._packet([21]),
];

void main() {
  group('HostKeyCapture', () {
    test('reads the host key off the key exchange, in any chunking', () {
      final bytes = _serverHandshake();
      for (final size in [1, 3, 7, 64, bytes.length]) {
        final capture = HostKeyCapture();
        for (var i = 0; i < bytes.length; i += size) {
          capture.add(
            bytes.sublist(i, i + size > bytes.length ? bytes.length : i + size),
          );
        }
        expect(HostKeyFingerprints.sha256For(_md5), _sha256, reason: '$size');
      }
    });

    test('fingerprints match OpenSSH and the stored MD5 format', () {
      expect(sha256HostKeyFingerprint(_blob), _sha256);
      expect(md5HostKeyFingerprint(_blob), _md5);
      // This computer's own keys are compared in the stored format.
      expect(hostKeyFingerprint(_publicKey), _md5);
    });

    test('ignores a DH group exchange prime that shares message 31', () {
      expect(
        HostKeyCapture.hostKeyBlobOf(
          Uint8List.fromList([31, ..._string(List.filled(129, 0xff))]),
        ),
        isNull,
      );
    });
  });

  group('SecureHostKeyVerifier', () {
    Future<SecureHostKeyVerifier> pinned(
      HostKeyPrompt prompt, {
      String? sha256,
    }) async {
      final storage = InMemorySecureStorage();
      final verifier = SecureHostKeyVerifier(storage, prompt);
      await verifier.saveTrustedKeys([
        HostKeyRecord(
          host: 'a',
          port: 22,
          type: 'ssh-ed25519',
          fingerprint: 'MD5:aa',
          sha256Fingerprint: sha256,
          trustedAt: DateTime(2026),
        ),
      ]);
      return verifier;
    }

    test('a changed key fails background work without a prompt', () async {
      final prompt = StubPrompt(decision: HostKeyDecision.trust);
      final verifier = await pinned(prompt);

      final ok = await verifier.verify(
        host: 'a',
        port: 22,
        type: 'ssh-ed25519',
        fingerprint: 'MD5:bb',
      );

      expect(ok, isFalse);
      expect(prompt.calls, 0);
      expect((await verifier.loadTrustedKeys()).single.fingerprint, 'MD5:aa');
    });

    test('a first key is still offered from background work', () async {
      final prompt = StubPrompt(decision: HostKeyDecision.reject);
      final verifier = SecureHostKeyVerifier(InMemorySecureStorage(), prompt);
      await verifier.verify(
        host: 'new',
        port: 22,
        type: 'ssh-ed25519',
        fingerprint: 'MD5:cc',
      );
      expect(prompt.calls, 1);
    });

    test('pins SHA256 next to MD5, and upgrades old MD5-only pins', () async {
      HostKeyCapture().add(_serverHandshake());
      final prompt = CapturingPrompt(decision: HostKeyDecision.trust);
      final storage = InMemorySecureStorage();
      final verifier = SecureHostKeyVerifier(storage, prompt);
      await verifier.saveTrustedKeys([
        HostKeyRecord(
          host: 'a',
          port: 22,
          type: 'ssh-ed25519',
          fingerprint: _md5,
          trustedAt: DateTime(2026),
        ),
      ]);

      expect(
        await verifier.verify(
          host: 'a',
          port: 22,
          type: 'ssh-ed25519',
          fingerprint: _md5,
        ),
        isTrue,
      );
      expect(prompt.requests, isEmpty);
      final record = (await verifier.loadTrustedKeys()).single;
      expect(record.fingerprint, _md5);
      expect(record.sha256Fingerprint, _sha256);

      await verifier.verify(
        host: 'b',
        port: 22,
        type: 'ssh-ed25519',
        fingerprint: _md5,
      );
      expect(prompt.requests.single.sha256Fingerprint, _sha256);
    });

    test('a pinned SHA256 must match too', () async {
      HostKeyCapture().add(_serverHandshake());
      final prompt = StubPrompt(decision: HostKeyDecision.trust);
      final verifier = SecureHostKeyVerifier(InMemorySecureStorage(), prompt);
      await verifier.saveTrustedKeys([
        HostKeyRecord(
          host: 'a',
          port: 22,
          type: 'ssh-ed25519',
          fingerprint: _md5,
          sha256Fingerprint: 'SHA256:other',
          trustedAt: DateTime(2026),
        ),
      ]);

      final ok = await verifier.verify(
        host: 'a',
        port: 22,
        type: 'ssh-ed25519',
        fingerprint: _md5,
      );

      expect(ok, isFalse);
      expect(prompt.calls, 0);
    });
  });

  group('host key dialog', () {
    HostKeyPromptRequest mismatch() => HostKeyPromptRequest(
      host: 'a',
      port: 22,
      type: 'ssh-ed25519',
      fingerprint: _md5,
      sha256Fingerprint: _sha256,
      kind: HostKeyPromptKind.mismatch,
      existing: HostKeyRecord(
        host: 'a',
        port: 22,
        type: 'ssh-ed25519',
        fingerprint: 'MD5:aa',
        sha256Fingerprint: 'SHA256:old',
        trustedAt: DateTime(2026),
      ),
    );

    Future<Future<HostKeyDecision?>> open(
      WidgetTester tester,
      HostKeyPromptRequest request,
    ) async {
      late Future<HostKeyDecision?> result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => result = showHostKeyPromptDialog(
                context: context,
                request: request,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return result;
    }

    testWidgets('shows SHA256 first, MD5 second, old and new', (tester) async {
      await open(tester, mismatch());
      expect(find.text(_sha256), findsOneWidget);
      expect(find.text(_md5), findsOneWidget);
      expect(find.text('SHA256:old'), findsOneWidget);
      expect(find.text('MD5 fingerprint'), findsNWidgets(2));
      expect(find.text('Trust new key'), findsNothing);
    });

    testWidgets('replacing a changed key takes two explicit steps', (
      tester,
    ) async {
      final result = await open(tester, mismatch());

      await tester.tap(find.text('Review replacement…'));
      await tester.pumpAndSettle();
      expect(find.text('Replace the trusted key?'), findsOneWidget);

      // Disabled until the fingerprint check is ticked.
      await tester.tap(find.text('Replace key'));
      await tester.pumpAndSettle();
      expect(find.text('Replace the trusted key?'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('host-key-confirm-checked')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Replace key'));
      await tester.pumpAndSettle();
      expect(await result, HostKeyDecision.trust);
    });

    testWidgets('Reject and Keep old key reject', (tester) async {
      var result = await open(tester, mismatch());
      await tester.tap(find.text('Reject'));
      await tester.pumpAndSettle();
      expect(await result, HostKeyDecision.reject);

      result = await open(tester, mismatch());
      await tester.tap(find.text('Review replacement…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Keep old key'));
      await tester.pumpAndSettle();
      expect(await result, HostKeyDecision.reject);
    });
  });

  test('withInteractiveHostKeyCheck marks only its own zone', () async {
    expect(isInteractiveHostKeyCheck, isFalse);
    expect(
      await withInteractiveHostKeyCheck(() async => isInteractiveHostKeyCheck),
      isTrue,
    );
    expect(isInteractiveHostKeyCheck, isFalse);
  });
}
