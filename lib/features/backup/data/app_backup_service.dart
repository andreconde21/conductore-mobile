// ignore_for_file: prefer_initializing_formals

import 'dart:convert';
import 'dart:math';

import 'package:conduit/core/theme/theme_controller.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/hosts/domain/saved_hosts_repository.dart';
import 'package:conduit/features/hosts/presentation/hosts_controller.dart';
import 'package:conduit/features/sessions/domain/session_snapshot.dart';
import 'package:conduit/features/snippets/domain/terminal_snippet.dart';
import 'package:conduit/features/sync/data/app_local_sync_store.dart';
import 'package:conduit/features/sync/data/app_settings_codec.dart';
import 'package:conduit/features/sync/data/sync_crypto.dart';
import 'package:conduit/features/sync/domain/local_data_changes.dart';
import 'package:conduit/features/sync/domain/local_sync_store.dart';
import 'package:conduit/features/sync/domain/sync_category.dart';
import 'package:conduit/features/sync/domain/sync_record.dart';
import 'package:conduit/features/terminal/domain/host_key_verifier.dart';
import 'package:crypto/crypto.dart';
import 'package:pinenacl/x25519.dart';

/// File backups, in the same encrypted bundle format as device sync (see
/// [SyncCrypto]): a backup file and a sync hub's bundle open the same way
/// with their passphrase. Older `conduit.backup` v1 files still import.
class AppBackupService {
  /// Without [localStore], backups cover machines, keys, snippets and
  /// settings but not connect preferences or the session list (tests).
  AppBackupService({
    required HostsController hostsController,
    required ThemeController themeController,
    required HostKeyVerifier hostKeyVerifier,
    LocalSyncStore? localStore,
    LocalDataChanges? changes,
    String? Function()? syncHubHostId,
    SyncCrypto crypto = const SyncCrypto(),
    AppBackupCrypto legacyCrypto = const AppBackupCrypto(),
    DateTime Function()? now,
  }) : _hostsController = hostsController,
       _themeController = themeController,
       _hostKeyVerifier = hostKeyVerifier,
       _localStore =
           localStore ??
           AppLocalSyncStore(
             hosts: hostsController,
             theme: themeController,
             hostKeys: hostKeyVerifier,
             connectPreferences: _NoJsonMapStore(),
             recentDirectoriesStore: _NoJsonMapStore(),
             sessions: InMemorySessionSnapshotRepository(),
             changes: changes,
           ),
       _changes = changes,
       _syncHubHostId = syncHubHostId ?? _noHub,
       _crypto = crypto,
       _legacyCrypto = legacyCrypto,
       _now = now ?? DateTime.now;

  static const fileExtension = 'conductore-backup.json';

  static String? _noHub() => null;

  final HostsController _hostsController;
  final ThemeController _themeController;
  final HostKeyVerifier _hostKeyVerifier;
  final LocalSyncStore _localStore;

  /// Announced after a legacy import (bundle imports go through the local
  /// store, which announces its own writes).
  final LocalDataChanges? _changes;

  /// The saved machine device sync goes through, when sync is on. Its
  /// login is this device's own (a device key the hub can revoke), so
  /// backups neither carry it nor overwrite it, as sync does.
  final String? Function() _syncHubHostId;
  final SyncCrypto _crypto;
  final AppBackupCrypto _legacyCrypto;
  final DateTime Function() _now;

  /// Everything but credentials unless [includeSecrets]; always encrypted
  /// with [password]. Hardware-key stubs come along with credentials.
  Future<Uint8List> exportBackup({
    required bool includeSecrets,
    required String password,
  }) async {
    final validation = AppBackupPasswordPolicy.validate(password);
    if (validation != null) {
      throw AppBackupException(validation);
    }
    final options = LocalSyncOptions(
      categories: {
        ...SyncCategory.values.where(
          (category) =>
              (includeSecrets || category != SyncCategory.credentials) &&
              !SyncCategory.notBackedUp.contains(category),
        ),
      },
      hubHostId: _syncHubHostId(),
      includeHardwareKeys: includeSecrets,
    );
    final values = await _localStore.snapshot(options);
    final now = _now().toUtc();
    final clock = SyncClock(
      time: now.millisecondsSinceEpoch,
      counter: 0,
      device: 'backup',
    );
    final document = SyncDocument(
      records: {
        for (final entry in values.entries)
          entry.key: SyncRecord(
            key: entry.key,
            value: entry.value,
            clock: clock,
          ),
      },
      deviceId: 'backup',
      createdAt: now,
    );
    final key = await _crypto.newKey(password);
    return _crypto.seal(
      key,
      Uint8List.fromList(utf8.encode(jsonEncode(document.toJson()))),
    );
  }

  /// Imports a backup file or a sync hub bundle. Items in the file replace
  /// the matching ones here; nothing else is removed.
  Future<AppBackupImportResult> importBackup(
    Uint8List bytes, {
    String? password,
  }) async {
    if (SyncCrypto.isBundle(bytes)) {
      return _importBundle(bytes, password);
    }
    return _importLegacy(bytes, password);
  }

  Future<AppBackupImportResult> _importBundle(
    Uint8List bytes,
    String? password,
  ) async {
    if (password == null || password.isEmpty) {
      throw const AppBackupException('Enter the backup password.');
    }
    final SyncDocument document;
    try {
      final plaintext = await _crypto.open(bytes, passphrase: password);
      document = SyncDocument.fromJson(jsonDecode(utf8.decode(plaintext)));
    } on SyncCryptoException catch (error) {
      throw AppBackupException(
        error.error == SyncCryptoError.wrongKey
            ? 'The password is wrong or the backup changed.'
            : error.message,
      );
    } on SyncFormatException catch (error) {
      throw AppBackupException(error.message);
    } on FormatException {
      throw const AppBackupException('This backup is damaged.');
    }
    final values = <String, Object?>{
      for (final record in document.records.values)
        if (!record.deleted) record.key: record.value,
    };
    await _localStore.apply(
      values,
      values.keys.toSet(),
      LocalSyncOptions(
        categories: {
          ...SyncCategory.values.where(
            (category) => !SyncCategory.notBackedUp.contains(category),
          ),
        },
        hubHostId: _syncHubHostId(),
        includeHardwareKeys: true,
      ),
      replace: false,
    );
    return AppBackupImportResult(
      hostsImported: values.keys
          .where((key) => key.startsWith('${SyncKeys.hostPrefix}:'))
          .length,
      trustedKeysImported: values.keys
          .where((key) => key.startsWith('${SyncKeys.knownHostPrefix}:'))
          .length,
    );
  }

  Future<AppBackupImportResult> _importLegacy(
    Uint8List bytes,
    String? password,
  ) async {
    final document = _decodeDocument(bytes);
    final payload = _extractPayload(document, password: password);
    final hub = _hostsController.hosts
        .where((host) => host.id == _syncHubHostId())
        .firstOrNull;
    final hosts = [
      for (final host in _parseHosts(payload['hosts']))
        hub != null && host.id == hub.id
            ? host.copyWith(
                authMethod: hub.authMethod,
                password: hub.password,
                privateKey: hub.privateKey,
                passphrase: hub.passphrase,
                hardwareKeys: hub.hardwareKeys,
                externalAuthOfferKey: hub.externalAuthOfferKey,
              )
            : host,
    ];
    final sortMode = _parseSortMode(payload['hostSortMode']);
    final manualOrder = _parseStringList(payload['hostManualOrder']);
    final trustedKeys = _parseTrustedKeys(payload['trustedHostKeys']);

    await _hostsController.mergeImported(
      hosts: hosts,
      sortMode: sortMode,
      manualOrder: manualOrder,
    );
    await _hostKeyVerifier.saveTrustedKeys([
      ...await _hostKeyVerifier.loadTrustedKeys(),
      ...trustedKeys,
    ]);
    await _restoreTheme(payload['theme']);
    _changes?.announce();

    return AppBackupImportResult(
      hostsImported: hosts.length,
      trustedKeysImported: trustedKeys.length,
    );
  }

  Future<void> _restoreTheme(Object? raw) async {
    if (raw is! Map<Object?, Object?>) {
      return;
    }
    final json = Map<String, Object?>.from(raw);
    // v1 wrote null when not following a machine and restored nothing.
    final followed = json['omarchySyncHostId'];
    if (followed is! String || followed.isEmpty) {
      json.remove('omarchySyncHostId');
    }
    await AppSettingsCodec.apply(_themeController, json);
    await _themeController.setTerminalSnippets(
      _parseSnippets(json['terminalSnippets']),
    );
  }

  Map<String, Object?> _decodeDocument(Uint8List bytes) {
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is Map<Object?, Object?>) {
        return Map<String, Object?>.from(decoded);
      }
      throw const FormatException('Backup root is not an object.');
    } catch (error) {
      throw const AppBackupException(
        'This does not look like a Conductore backup.',
      );
    }
  }

  Map<String, Object?> _extractPayload(
    Map<String, Object?> document, {
    String? password,
  }) {
    if (document['format'] != 'conduit.backup' || document['version'] != 1) {
      throw const AppBackupException('This backup format is not supported.');
    }

    if (document['encrypted'] == true) {
      final secret = password ?? '';
      if (secret.isEmpty) {
        throw const AppBackupException('Enter the backup password.');
      }
      try {
        final plaintext = _legacyCrypto.decrypt(document, secret);
        final decoded = jsonDecode(utf8.decode(plaintext));
        if (decoded is Map<Object?, Object?>) {
          return Map<String, Object?>.from(decoded);
        }
      } catch (_) {
        throw const AppBackupException(
          'The password is wrong or the backup changed.',
        );
      }
      throw const AppBackupException(
        'The encrypted backup payload is invalid.',
      );
    }

    final payload = document['payload'];
    if (payload is Map<Object?, Object?>) {
      return Map<String, Object?>.from(payload);
    }
    throw const AppBackupException('The backup payload is missing.');
  }

  List<SavedHost> _parseHosts(Object? raw) {
    if (raw is! List) {
      return const [];
    }
    return raw
        .whereType<Map<Object?, Object?>>()
        .map((json) => SavedHost.fromJson(Map<String, Object?>.from(json)))
        .where(_isImportableHost)
        .toList(growable: false);
  }

  bool _isImportableHost(SavedHost host) {
    return host.id.isNotEmpty &&
        host.name.trim().isNotEmpty &&
        host.host.trim().isNotEmpty &&
        host.port > 0 &&
        host.port <= 65535 &&
        host.connectionTimeoutSeconds >= 3 &&
        host.connectionTimeoutSeconds <= 120;
  }

  List<HostKeyRecord> _parseTrustedKeys(Object? raw) {
    if (raw is! List) {
      return const [];
    }
    return raw
        .whereType<Map<Object?, Object?>>()
        .map((json) => HostKeyRecord.fromJson(Map<String, Object?>.from(json)))
        .where(
          (record) => record.host.isNotEmpty && record.fingerprint.isNotEmpty,
        )
        .toList(growable: false);
  }

  HostListSortMode _parseSortMode(Object? raw) {
    return HostListSortMode.values.firstWhere(
      (mode) => mode.name == raw,
      orElse: () => HostListSortMode.lastConnected,
    );
  }

  List<String> _parseStringList(Object? raw) {
    if (raw is! List) {
      return const [];
    }
    return raw.whereType<String>().toList(growable: false);
  }
}

List<TerminalSnippet> _parseSnippets(Object? raw) {
  if (raw is! List) {
    return const [];
  }
  return raw
      .map(TerminalSnippet.fromJson)
      .whereType<TerminalSnippet>()
      .toList(growable: false);
}

/// Version 1 backups (PBKDF2 + XSalsa20-Poly1305). New backups use
/// [SyncCrypto]; this stays so older files still import, and [encrypt]
/// stays for tests of that path.
class AppBackupCrypto {
  const AppBackupCrypto();

  static const iterations = 210000;
  static const _keyLength = 32;
  static const _saltLength = 32;
  static const _nonceLength = 24;

  Map<String, Object?> encrypt(Uint8List plaintext, String password) {
    final salt = _randomBytes(_saltLength);
    final nonce = _randomBytes(_nonceLength);
    final key = _pbkdf2HmacSha256(
      utf8.encode(password),
      salt,
      iterations,
      _keyLength,
    );
    final encrypted = SecretBox(key).encrypt(plaintext, nonce: nonce);
    return {
      'format': 'conduit.backup',
      'version': 1,
      'encrypted': true,
      'kdf': {
        'name': 'pbkdf2-hmac-sha256',
        'salt': base64Encode(salt),
        'iterations': iterations,
        'keyLength': _keyLength,
      },
      'cipher': {
        'name': 'secretbox-xsalsa20-poly1305',
        'nonce': base64Encode(encrypted.nonce.asTypedList),
        'ciphertext': base64Encode(encrypted.cipherText.asTypedList),
      },
    };
  }

  Uint8List decrypt(Map<String, Object?> document, String password) {
    final kdf = _requiredMap(document['kdf']);
    final cipher = _requiredMap(document['cipher']);
    if (kdf['name'] != 'pbkdf2-hmac-sha256' ||
        cipher['name'] != 'secretbox-xsalsa20-poly1305') {
      throw const AppBackupException('This encrypted backup is not supported.');
    }
    final salt = base64Decode(kdf['salt'] as String? ?? '');
    final nonce = base64Decode(cipher['nonce'] as String? ?? '');
    final ciphertext = base64Decode(cipher['ciphertext'] as String? ?? '');
    final iterationCount = kdf['iterations'];
    final keyLength = kdf['keyLength'];
    if (iterationCount is! int ||
        keyLength is! int ||
        keyLength != _keyLength) {
      throw const AppBackupException('This encrypted backup is not supported.');
    }
    final key = _pbkdf2HmacSha256(
      utf8.encode(password),
      salt,
      iterationCount,
      keyLength,
    );
    return SecretBox(key).decrypt(
      EncryptedMessage(
        nonce: Uint8List.fromList(nonce),
        cipherText: Uint8List.fromList(ciphertext),
      ),
    );
  }

  static Map<String, Object?> _requiredMap(Object? raw) {
    if (raw is Map<Object?, Object?>) {
      return Map<String, Object?>.from(raw);
    }
    throw const AppBackupException('This encrypted backup is invalid.');
  }

  static Uint8List _randomBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(length, (_) => random.nextInt(256)),
    );
  }

  static Uint8List _pbkdf2HmacSha256(
    List<int> password,
    List<int> salt,
    int iterations,
    int keyLength,
  ) {
    if (iterations <= 0 || keyLength <= 0) {
      throw ArgumentError.value(iterations, 'iterations');
    }
    final hmac = Hmac(sha256, password);
    final blockCount = (keyLength / hmac.convert(<int>[]).bytes.length).ceil();
    final output = <int>[];
    for (var block = 1; block <= blockCount; block += 1) {
      final initial = hmac.convert([...salt, ..._uint32be(block)]).bytes;
      var u = initial;
      final result = List<int>.of(initial);
      for (var i = 1; i < iterations; i += 1) {
        u = hmac.convert(u).bytes;
        for (var j = 0; j < result.length; j += 1) {
          result[j] ^= u[j];
        }
      }
      output.addAll(result);
    }
    return Uint8List.fromList(output.take(keyLength).toList());
  }

  static List<int> _uint32be(int value) {
    return [
      (value >> 24) & 0xff,
      (value >> 16) & 0xff,
      (value >> 8) & 0xff,
      value & 0xff,
    ];
  }
}

class AppBackupPasswordPolicy {
  const AppBackupPasswordPolicy._();

  static String? validate(String password) {
    if (password.length < 12) {
      return 'Use at least 12 characters.';
    }
    if (password.trim() != password) {
      return 'Remove spaces from the start or end.';
    }
    var groups = 0;
    if (RegExp('[a-z]').hasMatch(password)) groups += 1;
    if (RegExp('[A-Z]').hasMatch(password)) groups += 1;
    if (RegExp('[0-9]').hasMatch(password)) groups += 1;
    if (RegExp(r'[^A-Za-z0-9]').hasMatch(password)) groups += 1;
    if (groups < 3) {
      return 'Use at least three of lowercase, uppercase, numbers, and symbols.';
    }
    return null;
  }
}

class AppBackupImportResult {
  const AppBackupImportResult({
    required this.hostsImported,
    required this.trustedKeysImported,
  });

  final int hostsImported;
  final int trustedKeysImported;
}

class AppBackupException implements Exception {
  const AppBackupException(this.message);

  final String message;

  @override
  String toString() => message;
}

class _NoJsonMapStore implements JsonMapStore {
  @override
  Future<Map<String, Object?>> readAll() async => {};

  @override
  Future<void> writeAll(Map<String, Object?> values) async {}
}
