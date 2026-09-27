import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:conduit/core/app_failure.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/sync/domain/sync_hub.dart';
import 'package:conduit/features/sync/domain/sync_hub_commands.dart';
import 'package:conduit/features/sync/presentation/sync_controller.dart';
import 'package:dartssh2/dartssh2.dart';

/// The files and authorized_keys of one hub machine, shared by the
/// [FakeSyncHub] connections of every test device.
class FakeHubServer {
  final bundles = <String, Uint8List>{};
  final metas = <String, SyncHubMeta>{};
  final authorizedKeys = <String>[];
  int metaReads = 0;
  int bundleReads = 0;
  int pushes = 0;

  /// Runs inside the next push, before its compare-and-swap (to let
  /// another device win the race).
  Future<void> Function()? beforeNextCommit;

  /// Runs inside the next bundle download (to change a device's data
  /// while its sync is running).
  Future<void> Function()? duringNextBundleRead;

  SyncHubFactory get factory =>
      (host, deviceId) => FakeSyncHub(this, host);
}

class FakeSyncHub implements SyncHub {
  FakeSyncHub(this.server, this.host);

  final FakeHubServer server;
  final SavedHost host;
  bool closed = false;

  /// Key logins need their public key in authorized_keys, like sshd.
  void _authenticate() {
    if (closed) throw StateError('closed');
    if (host.authMethod != SshAuthMethod.privateKey) return;
    final pair = SSHKeyPair.fromPem(host.privateKey).single;
    final data = base64Encode(pair.toPublicKey().encode());
    if (!server.authorizedKeys.any((line) => line.contains(data))) {
      throw const AppFailure('Permission denied (publickey).');
    }
  }

  @override
  Future<SyncHubMeta?> readMeta(String vaultId) async {
    _authenticate();
    server.metaReads++;
    return server.metas[vaultId];
  }

  @override
  Future<List<String>> listVaults() async {
    _authenticate();
    return server.metas.keys.toList();
  }

  @override
  Future<Uint8List> readBundle(String vaultId) async {
    _authenticate();
    server.bundleReads++;
    final hook = server.duringNextBundleRead;
    if (hook != null) {
      server.duringNextBundleRead = null;
      await hook();
    }
    final bundle = server.bundles[vaultId];
    if (bundle == null) throw const AppFailure('No such file');
    return bundle;
  }

  @override
  Future<SyncPushOutcome> push(
    String vaultId, {
    required Uint8List bundle,
    required SyncHubMeta meta,
    required int expectedVersion,
  }) async {
    _authenticate();
    final hook = server.beforeNextCommit;
    if (hook != null) {
      server.beforeNextCommit = null;
      await hook();
    }
    final current = server.metas[vaultId]?.version ?? 0;
    if (current != expectedVersion) return SyncPushOutcome.conflict;
    server.bundles[vaultId] = bundle;
    server.metas[vaultId] = meta;
    server.pushes++;
    return SyncPushOutcome.ok;
  }

  @override
  Future<void> deleteVault(String vaultId) async {
    _authenticate();
    server.bundles.remove(vaultId);
    server.metas.remove(vaultId);
  }

  @override
  Future<List<AuthorizedDeviceKey>> deviceKeys() async {
    _authenticate();
    return SyncHubCommands.parseAuthorizedKeys(
      server.authorizedKeys.join('\n'),
    );
  }

  @override
  Future<void> addDeviceKey(String publicKey, String name) async {
    _authenticate();
    final (_, data) = SyncHubCommands.splitPublicKey(publicKey);
    if (server.authorizedKeys.any((line) => line.contains(data))) return;
    server.authorizedKeys.add(
      SyncHubCommands.authorizedKeyLine(publicKey, name),
    );
  }

  @override
  Future<void> removeDeviceKey(String publicKey) async {
    _authenticate();
    final (_, data) = SyncHubCommands.splitPublicKey(publicKey);
    server.authorizedKeys.removeWhere((line) => line.contains(data));
  }

  @override
  Future<void> close() async => closed = true;
}

/// Timers fired by hand.
class FakeSyncTimers extends SyncTimers {
  final pending = <FakeTimer>[];

  @override
  Timer delay(Duration duration, void Function() callback) =>
      _add(duration, callback, periodic: false);

  @override
  Timer every(Duration duration, void Function() callback) =>
      _add(duration, callback, periodic: true);

  FakeTimer _add(
    Duration duration,
    void Function() callback, {
    required bool periodic,
  }) {
    final timer = FakeTimer(duration, callback, periodic: periodic);
    pending.add(timer);
    return timer;
  }

  Iterable<FakeTimer> get active => pending.where((t) => t.isActive);

  /// Fires the active one-shot timers of [duration].
  void fireDelays(Duration duration) {
    for (final timer
        in active
            .where((t) => !t.periodic && t.duration == duration)
            .toList()) {
      timer.fire();
    }
  }
}

class FakeTimer implements Timer {
  FakeTimer(this.duration, this.callback, {required this.periodic});

  final Duration duration;
  final void Function() callback;
  final bool periodic;
  bool _active = true;
  int _ticks = 0;

  void fire() {
    if (!_active) return;
    _ticks++;
    if (!periodic) _active = false;
    callback();
  }

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  @override
  int get tick => _ticks;
}

abstract final class SyncHubMetaCopy {
  static SyncHubMeta withRevoked(SyncHubMeta meta, List<String> revoked) =>
      SyncHubMeta(
        version: meta.version + 1,
        updatedAt: meta.updatedAt,
        updatedBy: meta.updatedBy,
        devices: meta.devices,
        revoked: revoked,
      );

  static SyncHubMeta bump(SyncHubMeta meta) => withRevoked(meta, meta.revoked);
}
