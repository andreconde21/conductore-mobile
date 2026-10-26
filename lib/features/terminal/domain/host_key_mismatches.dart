import 'package:conduit/features/terminal/domain/host_key_verifier.dart';
import 'package:flutter/foundation.dart';

/// A changed host key that background work refused: what is pinned for
/// [host]:[port] and the key the machine presented instead.
@immutable
class HostKeyMismatch {
  const HostKeyMismatch({
    required this.host,
    required this.port,
    required this.type,
    required this.fingerprint,
    required this.pinned,
    this.sha256Fingerprint,
  });

  final String host;
  final int port;

  /// The presented key: its algorithm, `MD5:…` and `SHA256:…` (null when
  /// the key exchange could not be read).
  final String type;
  final String fingerprint;
  final String? sha256Fingerprint;

  /// The key trusted before, which the presented one failed to match.
  final HostKeyRecord pinned;

  String get endpoint => '$host:$port';

  /// The presented key's fingerprint as OpenSSH prints it, MD5 when the
  /// SHA256 one is unknown.
  String get shownFingerprint => sha256Fingerprint ?? fingerprint;

  /// The pinned key's fingerprint, the same way.
  String get pinnedFingerprint => pinned.sha256Fingerprint ?? pinned.fingerprint;

  /// The same presented key against the same pin.
  bool sameAs(HostKeyMismatch other) =>
      host == other.host &&
      port == other.port &&
      type == other.type &&
      fingerprint == other.fingerprint &&
      sha256Fingerprint == other.sha256Fingerprint &&
      pinned.type == other.pinned.type &&
      pinned.fingerprint == other.pinned.fingerprint &&
      pinned.sha256Fingerprint == other.pinned.sha256Fingerprint;
}

/// Changed host keys seen by connections that may not ask (status polls,
/// sync, previews), per `host:port`, in memory only.
///
/// The home page shows each as a notice on its machine. Replacing the pin
/// takes an explicit review ([acceptReviewed]) and only ever pins the key
/// recorded here, the one the user was shown: a later connection that
/// presents yet another key overwrites the record (and the notice) first.
class HostKeyMismatches extends ChangeNotifier {
  final Map<String, HostKeyMismatch> _byEndpoint = {};

  /// The refused key for [host]:[port] (host as saved, trimmed), if any.
  HostKeyMismatch? forEndpoint(String host, int port) =>
      _byEndpoint['${host.trim()}:$port'];

  Iterable<HostKeyMismatch> get all => _byEndpoint.values;

  /// Notes that [mismatch] was refused; a different key for the same
  /// endpoint replaces the earlier record.
  void record(HostKeyMismatch mismatch) {
    final previous = _byEndpoint[mismatch.endpoint];
    if (previous != null && previous.sameAs(mismatch)) return;
    _byEndpoint[mismatch.endpoint] = mismatch;
    notifyListeners();
  }

  /// Forgets the record for [host]:[port]: the key matches again, or the
  /// pin was replaced or removed.
  void clear(String host, int port) {
    if (_byEndpoint.remove('$host:$port') != null) notifyListeners();
  }

  /// Drops records whose pin is no longer the one stored in [records]
  /// (replaced or removed by a restore, sync or Settings).
  void retainPinned(List<HostKeyRecord> records) {
    final pins = {for (final record in records) record.key: record};
    final before = _byEndpoint.length;
    _byEndpoint.removeWhere((endpoint, mismatch) {
      final pin = pins[endpoint];
      return pin == null ||
          pin.type != mismatch.pinned.type ||
          pin.fingerprint != mismatch.pinned.fingerprint;
    });
    if (_byEndpoint.length != before) notifyListeners();
  }

  /// Pins the key of [reviewed], the record the user looked at and chose
  /// to trust, in [verifier]'s store in place of the old one.
  ///
  /// Returns false and changes nothing when the record moved on meanwhile
  /// (another key was presented since, or the pin changed elsewhere): the
  /// user then reviews what is current.
  Future<bool> acceptReviewed(
    HostKeyMismatch reviewed,
    HostKeyVerifier verifier, {
    DateTime? now,
  }) async {
    final current = _byEndpoint[reviewed.endpoint];
    if (current == null || !current.sameAs(reviewed)) return false;
    final records = await verifier.loadTrustedKeys();
    final index = records.indexWhere((r) => r.key == reviewed.endpoint);
    if (index == -1 ||
        records[index].type != reviewed.pinned.type ||
        records[index].fingerprint != reviewed.pinned.fingerprint) {
      // Settings, a restore or sync changed the pin since: not ours to
      // overwrite. The next connection records what is true now.
      clear(reviewed.host, reviewed.port);
      return false;
    }
    records[index] = HostKeyRecord(
      host: reviewed.host,
      port: reviewed.port,
      type: reviewed.type,
      fingerprint: reviewed.fingerprint,
      sha256Fingerprint: reviewed.sha256Fingerprint,
      trustedAt: now ?? DateTime.now(),
    );
    await verifier.saveTrustedKeys(records);
    clear(reviewed.host, reviewed.port);
    return true;
  }
}
