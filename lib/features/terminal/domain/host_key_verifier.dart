class HostKeyRecord {
  const HostKeyRecord({
    required this.host,
    required this.port,
    required this.type,
    required this.fingerprint,
    required this.trustedAt,
    this.sha256Fingerprint,
  });

  final String host;
  final int port;
  final String type;

  /// `MD5:aa:bb:…`, the format every stored record has.
  final String fingerprint;

  /// `SHA256:…` as OpenSSH prints it; null for records pinned before it
  /// was stored (they gain it on the next matching connection).
  final String? sha256Fingerprint;
  final DateTime trustedAt;

  String get key => '$host:$port';

  Map<String, Object?> toJson() {
    return {
      'host': host,
      'port': port,
      'type': type,
      'fingerprint': fingerprint,
      'sha256': ?sha256Fingerprint,
      'trustedAt': trustedAt.toIso8601String(),
    };
  }

  factory HostKeyRecord.fromJson(Map<String, Object?> json) {
    return HostKeyRecord(
      host: json['host'] as String? ?? '',
      port: json['port'] as int? ?? 22,
      type: json['type'] as String? ?? '',
      fingerprint: json['fingerprint'] as String? ?? '',
      sha256Fingerprint: switch (json['sha256']) {
        final String value when value.isNotEmpty => value,
        _ => null,
      },
      trustedAt:
          DateTime.tryParse(json['trustedAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

abstract interface class HostKeyVerifier {
  Future<bool> verify({
    required String host,
    required int port,
    required String type,
    required String fingerprint,
  });

  Future<List<HostKeyRecord>> loadTrustedKeys();

  Future<void> saveTrustedKeys(List<HostKeyRecord> records);

  Future<void> removeTrustedKey(String host, int port);
}
