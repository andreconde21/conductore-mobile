import 'dart:async';

import 'package:conduit/features/terminal/domain/host_key_verifier.dart';

enum HostKeyPromptKind { firstTrust, mismatch }

enum HostKeyDecision { trust, reject }

class HostKeyPromptRequest {
  const HostKeyPromptRequest({
    required this.host,
    required this.port,
    required this.type,
    required this.fingerprint,
    required this.kind,
    this.existing,
    this.sha256Fingerprint,
  });

  final String host;
  final int port;
  final String type;

  /// `MD5:…`; shown second, for servers that print MD5.
  final String fingerprint;

  /// `SHA256:…`, what `ssh` and `ssh-keygen -lf` print; null when the key
  /// exchange could not be read.
  final String? sha256Fingerprint;
  final HostKeyPromptKind kind;
  final HostKeyRecord? existing;
}

abstract interface class HostKeyPrompt {
  Future<HostKeyDecision> request(HostKeyPromptRequest request);
}

/// Runs [connect] as a connection the user opened and is looking at (a
/// terminal, the file browser): only there may a changed host key be
/// shown for a decision. Everything else (polling, previews, sync, usage,
/// companion commands) fails on a changed key without asking, so a
/// prompt never pops up while the user is doing something else.
Future<T> withInteractiveHostKeyCheck<T>(Future<T> Function() connect) =>
    runZoned(connect, zoneValues: {_interactiveKey: true});

/// Whether the current host-key check runs for [withInteractiveHostKeyCheck].
bool get isInteractiveHostKeyCheck => Zone.current[_interactiveKey] == true;

final _interactiveKey = Object();
