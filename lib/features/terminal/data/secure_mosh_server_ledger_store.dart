import 'dart:convert';

import 'package:conduit/features/terminal/domain/mosh_server_ledger.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Keeps the mosh-server ledger in secure storage, next to the open-session
/// list: it must outlive the app run that started the servers.
class SecureMoshServerLedgerStore implements MoshServerLedgerStore {
  const SecureMoshServerLedgerStore(this._storage);

  static const storageKey = 'conductore.mosh_servers.v1';

  final FlutterSecureStorage _storage;

  @override
  Future<List<MoshServerLedgerEntry>> load() async {
    final raw = await _storage.read(key: storageKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final json = jsonDecode(raw);
      return [
        if (json is List)
          for (final item in json) ?MoshServerLedgerEntry.fromJson(item),
      ];
    } catch (_) {
      return [];
    }
  }

  @override
  Future<void> save(List<MoshServerLedgerEntry> entries) => entries.isEmpty
      ? _storage.delete(key: storageKey)
      : _storage.write(
          key: storageKey,
          value: jsonEncode([for (final entry in entries) entry.toJson()]),
        );
}
