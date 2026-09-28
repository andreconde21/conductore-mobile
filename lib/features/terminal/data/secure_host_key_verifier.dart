import 'dart:convert';

import 'package:conduit/features/terminal/data/host_key_capture.dart';
import 'package:conduit/features/terminal/domain/host_key_prompt.dart';
import 'package:conduit/features/terminal/domain/host_key_verifier.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SecureHostKeyVerifier implements HostKeyVerifier {
  SecureHostKeyVerifier(this._storage, this._prompt);

  static const _trustedKeysKey = 'conduit.trusted_host_keys.v1';
  static const _sha256AsciiHexFingerprintPrefix = 'MD5:53:48:41:32:35:36:3a';

  final FlutterSecureStorage _storage;
  final HostKeyPrompt _prompt;

  /// Checks the key [fingerprint] (`MD5:…`, from the SSH library) of
  /// [host]:[port] against the pinned one.
  ///
  /// A first key is offered for trust. A changed key fails without a
  /// prompt unless the connection runs in [withInteractiveHostKeyCheck]
  /// (a terminal or file browser the user opened); there the prompt warns
  /// and asks twice before the new key replaces the old one.
  ///
  /// The SHA256 fingerprint comes from the key exchange
  /// ([HostKeyFingerprints]); it is shown first and pinned alongside the
  /// MD5 one, which stays the stored format.
  @override
  Future<bool> verify({
    required String host,
    required int port,
    required String type,
    required String fingerprint,
  }) async {
    final sha256 = HostKeyFingerprints.sha256For(fingerprint);
    final records = await loadTrustedKeys();
    final key = '$host:$port';
    final existingIndex = records.indexWhere((record) => record.key == key);
    final existing = existingIndex == -1 ? null : records[existingIndex];

    if (existing != null && _matches(existing, type, fingerprint, sha256)) {
      if (existing.sha256Fingerprint == null && sha256 != null) {
        records[existingIndex] = HostKeyRecord(
          host: existing.host,
          port: existing.port,
          type: existing.type,
          fingerprint: existing.fingerprint,
          sha256Fingerprint: sha256,
          trustedAt: existing.trustedAt,
        );
        await _save(records);
      }
      return true;
    }

    if (existing != null && !isInteractiveHostKeyCheck) {
      // Background work never offers to trust a changed key.
      return false;
    }

    final decision = await _prompt.request(
      HostKeyPromptRequest(
        host: host,
        port: port,
        type: type,
        fingerprint: fingerprint,
        sha256Fingerprint: sha256,
        kind: existing == null
            ? HostKeyPromptKind.firstTrust
            : HostKeyPromptKind.mismatch,
        existing: existing,
      ),
    );

    if (decision == HostKeyDecision.reject) {
      return false;
    }

    final record = HostKeyRecord(
      host: host,
      port: port,
      type: type,
      fingerprint: fingerprint,
      sha256Fingerprint: sha256,
      trustedAt: DateTime.now(),
    );
    if (existing == null) {
      records.add(record);
    } else {
      records[existingIndex] = record;
    }
    await _save(records);
    return true;
  }

  /// The same key: type and MD5, and SHA256 too when both sides have it.
  static bool _matches(
    HostKeyRecord record,
    String type,
    String fingerprint,
    String? sha256,
  ) {
    if (record.type != type || record.fingerprint != fingerprint) return false;
    final pinned = record.sha256Fingerprint;
    return pinned == null || sha256 == null || pinned == sha256;
  }

  @override
  Future<List<HostKeyRecord>> loadTrustedKeys() async {
    final raw = await _readRaw();
    if (raw == null || raw.isEmpty) {
      return [];
    }
    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      return [];
    }
    final records = decoded
        .whereType<Map<String, Object?>>()
        .map(HostKeyRecord.fromJson)
        .where(
          (record) => record.host.isNotEmpty && record.fingerprint.isNotEmpty,
        )
        .toList();
    final originalCount = records.length;
    records.removeWhere(_isAsciiHexSha256Fingerprint);
    if (records.length != originalCount) {
      await _save(records);
    }
    return records;
  }

  @override
  Future<void> saveTrustedKeys(List<HostKeyRecord> records) {
    final byKey = <String, HostKeyRecord>{};
    for (final record in records) {
      if (record.host.isNotEmpty && record.fingerprint.isNotEmpty) {
        byKey[record.key] = record;
      }
    }
    return _save(byKey.values.toList(growable: false));
  }

  @override
  Future<void> removeTrustedKey(String host, int port) async {
    final key = '$host:$port';
    final records = await loadTrustedKeys();
    records.removeWhere((record) => record.key == key);
    await _save(records);
  }

  /// The stored list, one read shared by callers that ask at the same time
  /// (the home page and its boards all ask at launch). Each caller parses
  /// its own copy.
  Future<String?> _readRaw() =>
      _reading ??= _storage.read(key: _trustedKeysKey).whenComplete(() {
        _reading = null;
      });
  Future<String?>? _reading;

  Future<void> _save(List<HostKeyRecord> records) {
    // A read started before this write must not answer later callers.
    _reading = null;
    return _storage.write(
      key: _trustedKeysKey,
      value: jsonEncode(records.map((record) => record.toJson()).toList()),
    );
  }

  bool _isAsciiHexSha256Fingerprint(HostKeyRecord record) {
    return record.fingerprint.toLowerCase().startsWith(
      _sha256AsciiHexFingerprintPrefix.toLowerCase(),
    );
  }
}
