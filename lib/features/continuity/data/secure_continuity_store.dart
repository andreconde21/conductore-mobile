import 'dart:convert';

import 'package:conduit/features/continuity/domain/continuity_state.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// [ContinuityState] in the app's secure storage: drafts are unsent
/// prompts and may hold anything, like the synced data they come from.
class SecureContinuityStore implements ContinuityStore {
  const SecureContinuityStore(this._storage);

  static const _key = 'conductore.continuity.v1';

  final FlutterSecureStorage _storage;

  @override
  Future<ContinuityState> load() async {
    try {
      final raw = await _storage.read(key: _key);
      if (raw == null || raw.isEmpty) return const ContinuityState();
      return ContinuityState.fromJson(jsonDecode(raw));
    } catch (_) {
      // Unreadable: start over; the next sync brings the others back.
      return const ContinuityState();
    }
  }

  @override
  Future<void> save(ContinuityState state) async {
    try {
      await _storage.write(key: _key, value: jsonEncode(state.toJson()));
    } catch (_) {
      // Kept in memory for this run.
    }
  }
}
