import 'dart:async';
import 'dart:convert';

import 'package:conduit/core/app_failure.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/sftp/domain/sftp_repository.dart';
import 'package:conduit/features/sftp/domain/sftp_session.dart';
import 'package:conduit/features/sync/domain/sync_hub.dart';
import 'package:conduit/features/sync/domain/sync_hub_commands.dart';
import 'package:flutter/foundation.dart';

/// [SyncHub] over the app's own SSH stack: short commands through an
/// [AgentCommandRunner] (one kept-open exec connection) and file transfer
/// through [SftpRepository]. No port, daemon or companion on the host.
class SshSyncHub implements SyncHub {
  SshSyncHub({
    required this.host,
    required this.runner,
    required this.sftp,
    required this.deviceId,
  });

  final SavedHost host;
  final AgentCommandRunner runner;
  final SftpRepository sftp;

  /// Names this device's upload files, so two devices never write the
  /// same temporary file.
  final String deviceId;

  static const _timeout = Duration(seconds: 30);

  /// Bundles are small (settings, not files); anything bigger is refused
  /// rather than buffered.
  static const maxBundleBytes = 32 * 1024 * 1024;

  Future<AgentCommandResult> _run(String command, {bool check = true}) async {
    final result = await runner.run(
      SyncHubCommands.wrap(command),
      timeout: _timeout,
    );
    if (check && result.exitCode != null && result.exitCode != 0) {
      throw AppFailure(
        'The sync hub ${host.name} refused a command.',
        result.stderr.trim().isEmpty ? null : result.stderr.trim(),
      );
    }
    return result;
  }

  @override
  Future<SyncHubMeta?> readMeta(String vaultId) async {
    final result = await _run(SyncHubCommands.readMeta(vaultId));
    return SyncHubMeta.decode(result.stdout);
  }

  @override
  Future<List<String>> listVaults() async {
    final result = await _run(SyncHubCommands.listVaults());
    return [
      for (final line in const LineSplitter().convert(result.stdout))
        if (SyncHubCommands.isValidId(line.trim())) line.trim(),
    ];
  }

  /// An SFTP session on [runner]'s connection when it can carry one (no
  /// new handshake per sync, CON-089), else a connection of its own.
  Future<SftpSession> _files() async {
    if (runner case final SftpChannelRunner shared) {
      try {
        final session = await shared.openSftp();
        if (session != null) return session;
      } on Object {
        // The shared connection failed: a fresh one below.
      }
    }
    return sftp.connect(host);
  }

  @override
  Future<Uint8List> readBundle(String vaultId) async {
    final session = await _files();
    try {
      return await session.read(
        SyncHubCommands.bundlePath(vaultId),
        maxBytes: maxBundleBytes,
      );
    } finally {
      await session.close();
    }
  }

  @override
  Future<SyncPushOutcome> push(
    String vaultId, {
    required Uint8List bundle,
    required SyncHubMeta meta,
    required int expectedVersion,
  }) async {
    await _run(SyncHubCommands.prepare());
    final metaBytes = Uint8List.fromList(utf8.encode('${meta.encode()}\n'));
    final session = await _files();
    try {
      await session.write(
        SyncHubCommands.uploadPath(vaultId, deviceId, 'bundle'),
        Stream.value(bundle),
        bundle.length,
      );
      await session.write(
        SyncHubCommands.uploadPath(vaultId, deviceId, 'meta'),
        Stream.value(metaBytes),
        metaBytes.length,
      );
    } finally {
      await session.close();
    }
    final result = await _run(
      SyncHubCommands.commit(vaultId, deviceId, expectedVersion),
      check: false,
    );
    return switch (result.exitCode) {
      0 || null => SyncPushOutcome.ok,
      3 => SyncPushOutcome.conflict,
      75 => SyncPushOutcome.busy,
      _ => throw AppFailure(
        'The sync hub ${host.name} could not store the update.',
        result.stderr.trim().isEmpty ? null : result.stderr.trim(),
      ),
    };
  }

  @override
  Future<void> deleteVault(String vaultId) =>
      _run(SyncHubCommands.deleteVault(vaultId));

  @override
  Future<List<AuthorizedDeviceKey>> deviceKeys() async {
    final result = await _run(SyncHubCommands.listAuthorizedKeys());
    return SyncHubCommands.parseAuthorizedKeys(result.stdout);
  }

  @override
  Future<void> addDeviceKey(String publicKey, String name) =>
      _run(SyncHubCommands.addAuthorizedKey(publicKey, name));

  @override
  Future<void> removeDeviceKey(String publicKey) =>
      _run(SyncHubCommands.removeAuthorizedKey(publicKey));

  @override
  Future<void> close() => runner.close();
}
