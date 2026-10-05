import 'dart:async';
import 'dart:convert';

import 'package:conduit/core/app_failure.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/terminal/data/fido_hardware_key_ctap_device.dart';
import 'package:conduit/features/terminal/data/openssh_security_key_signer.dart';
import 'package:conduit/features/terminal/data/ssh_keepalive_policy.dart';
import 'package:conduit/features/terminal/data/tcp_ssh_socket.dart';
import 'package:conduit/features/terminal/domain/host_key_verifier.dart';
import 'package:conduit/features/terminal/domain/security_key_interaction.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart' show Uint8List, visibleForTesting;
import 'package:pinenacl/ed25519.dart' as ed25519;

typedef SshKeyPairParser =
    List<SSHKeyPair> Function(String pemText, String? passphrase);

class SshClientFactory {
  SshClientFactory(
    this._hostKeyVerifier, {
    OpenSshSecurityKeySigner? securityKeySigner,
    SshKeyPairParser? keyPairParser,
  }) : _securityKeySigner =
           securityKeySigner ??
           OpenSshSecurityKeySigner(
             openDevice: FidoHardwareKeyCtapDevice.open,
             closeDevice: FidoHardwareKeyCtapDevice.close,
             onStatus: SecurityKeyInteraction.instance.announce,
             onPinRequest: SecurityKeyInteraction.instance.requestPin,
             onKeySelect: SecurityKeyInteraction.instance.requestKeySelection,
           ),
       _keyPairParser = keyPairParser ?? parseKeyPairs;

  /// [SSHKeyPair.fromPem], remembered per key and passphrase for the
  /// app's run: decrypting a passphrase-protected key runs bcrypt, about
  /// 1.5 s of the UI isolate, and every connection to a machine (each
  /// terminal, the side connection, SFTP) would pay it again. The key and
  /// its passphrase are in memory anyway, in the saved machine.
  static List<SSHKeyPair> parseKeyPairs(String pemText, String? passphrase) {
    final key = _parsedKeyId(pemText, passphrase);
    final known = _parsedKeys.remove(key);
    final keyPairs = known ?? SSHKeyPair.fromPem(pemText, passphrase);
    _parsedKeys[key] = keyPairs;
    if (_parsedKeys.length > _parsedKeysKept) {
      _parsedKeys.remove(_parsedKeys.keys.first);
    }
    return keyPairs;
  }

  /// Drops every decrypted key no machine in [hosts] uses any more, so a
  /// deleted machine's key, or the old key or passphrase of an edited one,
  /// does not stay decrypted in memory for the rest of the run.
  static void retainKeysOf(Iterable<SavedHost> hosts) {
    if (_parsedKeys.isEmpty) return;
    final inUse = <String>{
      for (final host in hosts) ...[
        if (host.privateKey.isNotEmpty)
          _parsedKeyId(
            host.privateKey,
            host.passphrase.isEmpty ? null : host.passphrase,
          ),
        for (final entry in host.hardwareKeys)
          _parsedKeyId(
            entry.privateKey,
            entry.passphrase.isEmpty ? null : entry.passphrase,
          ),
      ],
    };
    _parsedKeys.removeWhere((key, _) => !inUse.contains(key));
  }

  @visibleForTesting
  static bool isParsed(String pemText, String? passphrase) =>
      _parsedKeys.containsKey(_parsedKeyId(pemText, passphrase));

  static String _parsedKeyId(String pemText, String? passphrase) =>
      '${passphrase ?? ''}\u0000$pemText';

  static final _parsedKeys = <String, List<SSHKeyPair>>{};
  static const _parsedKeysKept = 16;

  final HostKeyVerifier _hostKeyVerifier;
  final OpenSshSecurityKeySigner _securityKeySigner;
  final SshKeyPairParser _keyPairParser;
  SSHKeyPair? _externalAuthIdentity;

  /// Opens a connection to [host]; its keep-alive follows
  /// [SshKeepalivePolicy.instance] for a [role] connection.
  Future<SSHClient> connect(
    SavedHost host, {
    SshConnectionRole role = SshConnectionRole.side,
  }) async {
    SSHSocket? socket;
    try {
      socket = await TcpSshSocket.connect(
        host.host.trim(),
        host.port,
        timeout: Duration(seconds: host.connectionTimeoutSeconds),
      );
      final identities = _identitiesFor(host);
      final keepalive = SshKeepalivePolicy.instance;
      final client = SSHClient(
        socket,
        username: host.username.trim(),
        identities: identities,
        agentHandler: _agentHandlerFor(host, identities),
        onPasswordRequest: _passwordRequestFor(host),
        onUserInfoRequest: _userInfoRequestFor(host),
        onVerifyHostKey: (type, fingerprint) {
          return _hostKeyVerifier.verify(
            host: host.host.trim(),
            port: host.port,
            type: type,
            fingerprint: _formatFingerprint(fingerprint),
          );
        },
        keepAliveInterval: keepalive.intervalFor(role),
      );
      keepalive.register(client, role);
      return client;
    } catch (_) {
      unawaited(socket?.close() ?? Future<void>.value());
      rethrow;
    }
  }

  /// How long [host] gets from the TCP connection to its first channel:
  /// the SSH handshake, the sign-in and opening a shell, exec or SFTP. A
  /// hardware-key sign-in waits for a touch or a PIN, an external one
  /// (Tailscale SSH's check) for a browser login, so those get longer.
  static Duration setupTimeoutFor(SavedHost host) {
    final configured = Duration(seconds: host.connectionTimeoutSeconds);
    return switch (host.authMethod) {
      SshAuthMethod.hardwareKey || SshAuthMethod.external =>
        configured > interactiveSetupTimeout
            ? configured
            : interactiveSetupTimeout,
      _ => configured,
    };
  }

  /// [setupTimeoutFor] a sign-in that waits on the user.
  static const interactiveSetupTimeout = Duration(minutes: 5);

  /// Awaits [firstChannel] (which waits on the handshake and sign-in of
  /// [client] too) within [setupTimeoutFor] [host]. A server that accepts
  /// the connection but never speaks SSH would otherwise hang it forever;
  /// on timeout [client] is closed and a [TimeoutException] thrown.
  static Future<T> withinSetupTimeout<T>(
    SavedHost host,
    SSHClient client,
    Future<T> firstChannel,
  ) {
    final timeout = setupTimeoutFor(host);
    return firstChannel.timeout(
      timeout,
      onTimeout: () {
        client.close();
        throw TimeoutException(
          'The SSH server did not finish the handshake and sign-in in time.',
          timeout,
        );
      },
    );
  }

  List<SSHKeyPair>? _identitiesFor(SavedHost host) {
    if (host.authMethod == SshAuthMethod.external &&
        host.externalAuthOfferKey) {
      return [_externalAuthIdentity ??= _generateExternalAuthIdentity()];
    }
    if (host.authMethod == SshAuthMethod.hardwareKey) {
      return _hardwareKeyIdentitiesFor(host);
    }
    if (host.authMethod != SshAuthMethod.privateKey) {
      return null;
    }
    try {
      final keyPairs = _keyPairParser(
        host.privateKey,
        host.passphrase.isEmpty ? null : host.passphrase,
      );
      if (keyPairs.any((keyPair) => keyPair is OpenSSHSecurityKeyPair)) {
        throw const AppFailure(
          'This is a hardware-key stub. Choose Hardware key instead.',
        );
      }
      return _securityKeySigner.attach(keyPairs);
    } catch (error) {
      if (error is AppFailure) {
        rethrow;
      }
      throw AppFailure('Private key could not be loaded.', error);
    }
  }

  List<SSHKeyPair> _hardwareKeyIdentitiesFor(SavedHost host) {
    final entries = host.effectiveHardwareKeys;
    if (entries.isEmpty) {
      throw const AppFailure('Add at least one hardware key to this host.');
    }
    final keyPairs = <SSHKeyPair>[];
    final labels = <String>[];
    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      final label = entry.label.trim().isEmpty
          ? 'hardware key ${i + 1}'
          : entry.label.trim();
      final List<SSHKeyPair> parsed;
      try {
        parsed = _keyPairParser(
          entry.privateKey,
          entry.passphrase.isEmpty ? null : entry.passphrase,
        );
      } catch (error) {
        throw AppFailure('Hardware key "$label" could not be loaded.', error);
      }
      final securityKeyPairs = parsed
          .whereType<OpenSSHSecurityKeyPair>()
          .toList(growable: false);
      if (securityKeyPairs.isEmpty) {
        throw AppFailure(
          'Hardware key "$label" requires an OpenSSH security-key stub '
          '(id_ed25519_sk or id_ecdsa_sk), not a normal private key.',
        );
      }
      for (final keyPair in securityKeyPairs) {
        keyPairs.add(keyPair);
        labels.add(label);
      }
    }
    return _securityKeySigner.attach(keyPairs, labels: labels);
  }

  @visibleForTesting
  List<SSHKeyPair>? identitiesForTesting(SavedHost host) =>
      _identitiesFor(host);

  SSHAgentHandler? _agentHandlerFor(
    SavedHost host,
    List<SSHKeyPair>? identities,
  ) {
    if (host.authMethod == SshAuthMethod.external ||
        !host.forwardAgent ||
        identities == null ||
        identities.isEmpty) {
      return null;
    }
    return SSHKeyPairAgent(identities);
  }

  @visibleForTesting
  SSHAgentHandler? agentHandlerForTesting(SavedHost host) =>
      _agentHandlerFor(host, _identitiesFor(host));

  @visibleForTesting
  String formatFingerprintForTesting(Uint8List bytes) =>
      _formatFingerprint(bytes);

  @visibleForTesting
  String Function()? passwordRequestForTesting(SavedHost host) =>
      _passwordRequestFor(host);

  @visibleForTesting
  SSHUserInfoRequestHandler? userInfoRequestForTesting(SavedHost host) =>
      _userInfoRequestFor(host);

  String Function()? _passwordRequestFor(SavedHost host) {
    return host.authMethod == SshAuthMethod.password
        ? () => host.password
        : null;
  }

  SSHUserInfoRequestHandler? _userInfoRequestFor(SavedHost host) {
    if (host.authMethod != SshAuthMethod.password) {
      return null;
    }
    return (request) {
      var answered = false;
      return [
        for (final prompt in request.prompts)
          if (!prompt.echo && !answered)
            (() {
              answered = true;
              return host.password;
            })()
          else
            '',
      ];
    };
  }

  SSHKeyPair _generateExternalAuthIdentity() {
    final signingKey = ed25519.SigningKey.generate();
    return OpenSSHEd25519KeyPair(
      Uint8List.fromList(signingKey.verifyKey.asTypedList),
      Uint8List.fromList(signingKey.asTypedList),
      'conduit-external-auth',
    );
  }

  String _formatFingerprint(Uint8List bytes) {
    final text = utf8.decode(bytes, allowMalformed: true);
    if (text.startsWith('SHA256:')) {
      return text;
    }
    final parts = bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0'));
    return 'MD5:${parts.join(':')}';
  }
}
