// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:conduit/core/app_failure.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/hosts/presentation/hosts_controller.dart';
import 'package:conduit/features/sync/data/sync_crypto.dart';
import 'package:conduit/features/sync/data/sync_setup.dart';
import 'package:conduit/features/sync/data/sync_state_store.dart';
import 'package:conduit/features/sync/domain/canonical_json.dart';
import 'package:conduit/features/sync/domain/local_sync_store.dart';
import 'package:conduit/features/sync/domain/sync_category.dart';
import 'package:conduit/features/sync/domain/sync_config.dart';
import 'package:conduit/features/sync/domain/sync_hub.dart';
import 'package:conduit/features/sync/domain/sync_merge.dart';
import 'package:conduit/features/sync/domain/sync_record.dart';
import 'package:conduit/features/sync/domain/sync_setup_code.dart';
import 'package:conduit/features/terminal/domain/host_key_verifier.dart';
import 'package:flutter/widgets.dart';

enum SyncStatus { off, idle, syncing, error }

typedef SyncHubFactory = SyncHub Function(SavedHost hub, String deviceId);

/// Timers behind a seam so tests can run the schedule by hand.
class SyncTimers {
  const SyncTimers();

  Timer delay(Duration duration, void Function() callback) =>
      Timer(duration, callback);

  Timer every(Duration duration, void Function() callback) =>
      Timer.periodic(duration, (_) => callback());
}

/// A row of the device list: a device the hub's meta knows, a
/// `conductore-device` key without one (paired but never synced), or both.
@immutable
class SyncDeviceView {
  const SyncDeviceView({
    required this.name,
    this.id,
    this.platform = '',
    this.lastSeen,
    this.publicKey,
    this.isThisDevice = false,
  });

  final String name;
  final String? id;
  final String platform;
  final DateTime? lastSeen;
  final String? publicKey;
  final bool isThisDevice;

  bool get pairedOnly => id == null;
}

/// What "Add a device" shows: the code (QR or paste) and the six words
/// typed on the new device.
@immutable
class SyncPairingOffer {
  const SyncPairingOffer({
    required this.setupCode,
    required this.words,
    required this.deviceName,
    required this.publicKey,
  });

  final String setupCode;
  final List<String> words;
  final String deviceName;
  final String publicKey;
}

/// Device sync through one saved machine (the hub).
///
/// A sync reads the hub's meta, downloads and decrypts the bundle when it
/// changed, merges it with this device's data ([mergeSync]), applies what
/// changed here and pushes the result when the hub lacks something. It
/// runs [pushDelay] after a local change, on start and resume, every
/// [pollInterval] while the app is open, and on "Sync now". One sync runs
/// at a time; a request during one runs once more after it.
class SyncController extends ChangeNotifier with WidgetsBindingObserver {
  SyncController({
    required SyncStateStore state,
    required LocalSyncStore local,
    required SyncHubFactory hubFactory,
    required HostsController hosts,
    required HostKeyVerifier hostKeys,
    SyncCrypto crypto = const SyncCrypto(),
    SyncSetupCodec? setupCodec,
    List<Listenable> changeSources = const [],
    SyncTimers timers = const SyncTimers(),
    DateTime Function()? now,
    this.platform = '',
    this.defaultDeviceName = 'This device',
    this.pushDelay = const Duration(seconds: 5),
    this.pollInterval = const Duration(minutes: 3),
    this.observeLifecycle = true,
  }) : _state = state,
       _local = local,
       _hubFactory = hubFactory,
       _hosts = hosts,
       _hostKeys = hostKeys,
       _crypto = crypto,
       _setupCodec = setupCodec ?? SyncSetupCodec(crypto: crypto),
       _changeSources = changeSources,
       _timers = timers,
       _now = now ?? DateTime.now;

  final SyncStateStore _state;
  final LocalSyncStore _local;
  final SyncHubFactory _hubFactory;
  final HostsController _hosts;
  final HostKeyVerifier _hostKeys;
  final SyncCrypto _crypto;
  final SyncSetupCodec _setupCodec;
  final List<Listenable> _changeSources;
  final SyncTimers _timers;
  final DateTime Function() _now;

  /// Shown in the hub's device list (android, ios, linux…).
  final String platform;
  final String defaultDeviceName;
  final Duration pushDelay;
  final Duration pollInterval;
  final bool observeLifecycle;

  static const _maxActivity = 60;

  SyncConfig? _config;
  SyncKey? _key;
  SyncStatus _status = SyncStatus.off;
  String? _error;
  List<SyncActivityEntry> _activity = const [];
  List<SyncDeviceView> _devices = const [];
  SyncHubMeta? _lastMeta;
  SyncHub? _hub;
  String? _hubFingerprint;
  bool _started = false;
  bool _applying = false;
  bool _foreground = true;
  bool _disposed = false;
  Timer? _debounce;
  Timer? _poll;
  Future<void>? _running;
  bool _again = false;
  bool _forcePush = false;

  /// When the app first reported a change since [_stampEdits] last ran.
  DateTime? _changedSince;
  final Completer<void> _loaded = Completer<void>();

  SyncConfig? get config => _config;
  bool get enabled => _config != null && _key != null;
  SyncStatus get status => _status;
  String? get error => _error;
  List<SyncActivityEntry> get activity => _activity;
  List<SyncDeviceView> get devices => _devices;
  bool get syncing => _running != null;

  /// Saved machines that can be the hub (not local shells).
  List<SavedHost> get machines =>
      _hosts.hosts.where((host) => !host.isLocal).toList(growable: false);

  /// The hub's saved machine on this device.
  SavedHost? get hubHost {
    final id = _config?.hubHostId;
    return id == null ? null : _findHost(id);
  }

  /// A listenable for the pages: this controller and the machine list.
  late final Listenable changes = Listenable.merge([this, _hosts]);

  /// Completes once the saved setup has been read.
  Future<void> get loaded => _loaded.future;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    _config = await _state.loadConfig();
    _key = await _state.loadKey();
    if (_config != null && _key == null) {
      // A config without its key is useless; start over cleanly.
      _config = null;
      await _state.saveConfig(null);
    }
    _activity = await _state.loadActivity();
    _status = enabled ? SyncStatus.idle : SyncStatus.off;
    for (final source in _changeSources) {
      source.addListener(_onLocalChange);
    }
    if (observeLifecycle) WidgetsBinding.instance.addObserver(this);
    if (!_loaded.isCompleted) _loaded.complete();
    _notify();
    if (enabled) {
      _startPolling();
      unawaited(syncNow());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        onResume();
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        onPause();
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  /// Back in front: pull what other devices did meanwhile.
  void onResume() {
    if (_foreground) return;
    _foreground = true;
    if (!enabled) return;
    _startPolling();
    unawaited(syncNow());
  }

  /// Leaving: push a pending change now rather than in five seconds.
  void onPause() {
    if (!_foreground) return;
    _foreground = false;
    _poll?.cancel();
    _poll = null;
    if (_debounce != null) {
      _debounce!.cancel();
      _debounce = null;
      unawaited(_syncIfChanged().whenComplete(_closeHub));
    } else if (_running == null) {
      unawaited(_closeHub());
    }
  }

  void _startPolling() {
    _poll?.cancel();
    _poll = _foreground && enabled
        ? _timers.every(pollInterval, () => unawaited(syncNow()))
        : null;
  }

  void _onLocalChange() {
    if (!enabled || _applying) return;
    _changedSince ??= _now();
    _debounce?.cancel();
    _debounce = _timers.delay(pushDelay, () {
      _debounce = null;
      unawaited(_syncIfChanged());
    });
  }

  Future<void> _syncIfChanged() async {
    if (!enabled) return;
    if (await _stampEdits() || _running != null) {
      await syncNow();
    }
  }

  /// Whether this device has unsynced edits. When it has and none were
  /// stamped yet, they are stamped with the first change notification
  /// since the last check, not the (later, maybe offline) sync's time. A
  /// notification that changed nothing (a connect time) stamps nothing,
  /// so it cannot backdate a later edit.
  Future<bool> _stampEdits() async {
    final since = _changedSince;
    _changedSince = null;
    final changed = await _localChanged();
    final config = _config;
    if (changed &&
        since != null &&
        config != null &&
        config.dirtySince == null) {
      // Saved in the background; a lost write only makes the stamp later.
      _config = config.copyWith(dirtySince: since);
      unawaited(_state.saveConfig(_config));
    }
    return changed;
  }

  /// Whether this device's data differs from what it last synced, without
  /// touching the network.
  Future<bool> _localChanged() async {
    final config = _config;
    if (config == null) return false;
    try {
      final local = await _local.snapshot(_options(config));
      final base = await _state.loadBase();
      for (final entry in local.entries) {
        final category = SyncCategory.ofKey(entry.key);
        if (category == null || !config.categories.contains(category)) continue;
        if (base[entry.key]?.localHash != valueHash(entry.value)) return true;
      }
      for (final entry in base.entries) {
        final category = SyncCategory.ofKey(entry.key);
        if (category == null || !config.categories.contains(category)) continue;
        if (entry.value.localHash != null && !local.containsKey(entry.key)) {
          return true;
        }
      }
      return false;
    } catch (_) {
      return true;
    }
  }

  /// Runs a sync now (or joins the one running, which then runs again).
  Future<void> syncNow() {
    final running = _running;
    if (running != null) {
      _again = true;
      return running;
    }
    final future = _loop();
    _running = future;
    _notify();
    return future;
  }

  Future<void> _loop() async {
    try {
      do {
        _again = false;
        await _runSync();
      } while (_again && enabled && !_disposed);
    } finally {
      _running = null;
      _notify();
    }
  }

  LocalSyncOptions _options(SyncConfig config) => LocalSyncOptions(
    categories: config.categories,
    hubHostId: config.hubHostId,
  );

  SavedHost? _findHost(String id) =>
      _hosts.hosts.where((host) => host.id == id).firstOrNull;

  SyncHub _hubFor(SavedHost host, String deviceId) {
    final fingerprint = canonicalJson(host.toJson()..remove('lastConnectedAt'));
    final current = _hub;
    if (current != null && _hubFingerprint == fingerprint) return current;
    if (current != null) unawaited(current.close());
    _hubFingerprint = fingerprint;
    return _hub = _hubFactory(host, deviceId);
  }

  Future<void> _closeHub() async {
    final hub = _hub;
    _hub = null;
    _hubFingerprint = null;
    if (hub != null) {
      try {
        await hub.close();
      } catch (_) {
        // Already gone.
      }
    }
  }

  Future<void> _runSync() async {
    final key = _key;
    if (_config == null || key == null) return;
    _status = SyncStatus.syncing;
    _notify();
    try {
      await _hosts.firstLoad;
      var config = _config!;
      final hubHost = _findHost(config.hubHostId);
      if (hubHost == null) {
        throw const AppFailure(
          'The sync hub machine is no longer saved on this device. '
          'Turn sync off and set it up again.',
        );
      }
      final hub = _hubFor(hubHost, config.deviceId);
      for (var attempt = 0; attempt < 3; attempt++) {
        final outcome = await _attempt(hub, config, key);
        if (_config == null) return; // Removed from another device.
        config = _config!;
        if (outcome == null || outcome == SyncPushOutcome.ok) break;
        if (attempt == 2) {
          throw const AppFailure(
            'Other devices kept updating the hub; trying again soon.',
          );
        }
      }
      _config = _config!.copyWith(lastSyncAt: _now());
      // A stamp taken while this pass ran, for edits it pushed, must not
      // backdate the next edit.
      if (_config!.dirtySince != null && !await _localChanged()) {
        _config = _config!.copyWith(clearDirtySince: true);
      }
      await _state.saveConfig(_config);
      _status = SyncStatus.idle;
      _error = null;
    } catch (error) {
      if (_config == null) return;
      _status = SyncStatus.error;
      _error = _describe(error);
      if (_activity.isEmpty ||
          _activity.first.kind != SyncActivityKind.error ||
          _activity.first.message != _error) {
        await _log(SyncActivityKind.error, _error!);
      }
    } finally {
      _notify();
    }
  }

  /// One pull-merge-apply-push round. Returns null when nothing had to be
  /// pushed, else the push outcome (conflict and busy mean: go again).
  Future<SyncPushOutcome?> _attempt(
    SyncHub hub,
    SyncConfig config,
    SyncKey key,
  ) async {
    final options = _options(config);
    // Edits not stamped yet (their push still waits for the debounce) are
    // stamped with their first notification; only real edits use it.
    final pendingSince = _changedSince;
    _changedSince = null;
    final base = await _state.loadBase();
    var local = await _local.snapshot(options);
    final meta = await hub.readMeta(config.vaultId);
    _lastMeta = meta;
    if (meta != null && meta.revoked.contains(config.deviceId)) {
      await _stopLocally(
        'This device was removed from sync on another device. '
        'Its data stays here.',
      );
      return null;
    }

    Map<String, SyncRecord>? remote;
    if (meta == null) {
      if (config.lastRevision > 0) {
        await _log(
          SyncActivityKind.info,
          'The hub had no sync data any more; stored this device\'s copy.',
        );
      }
    } else if (meta.version == config.lastRevision &&
        !config.unpushed &&
        base.isNotEmpty) {
      // Unchanged since this device's last sync: the base is the hub.
      remote = {
        for (final entry in base.values) entry.record.key: entry.record,
      };
    } else {
      remote = await _download(hub, config, key);
    }

    if (remote != null &&
        config.categories.contains(SyncCategory.machines) &&
        !config.initialized.contains(SyncCategory.machines)) {
      if (await _adoptMachines(remote, config)) {
        config = _config!;
        local = await _local.snapshot(_options(config));
      }
    }

    var dirtySince = config.dirtySince ?? pendingSince;
    SyncMergeResult merge() => mergeSync(
      base: base,
      local: local,
      enabled: config.categories,
      initialized: config.initialized,
      remote: remote,
      deviceId: config.deviceId,
      now: _now().millisecondsSinceEpoch,
      counter: config.counter,
      editTime: dirtySince?.millisecondsSinceEpoch,
    );
    var result = merge();
    // Edits made while the hub was read (a machine saved during a poll)
    // are merged too, so applying the hub's changes never puts back the
    // older snapshot.
    for (var round = 0; round < 3 && result.toApply.isNotEmpty; round++) {
      final current = await _local.snapshot(_options(config));
      if (valueHash(current) == valueHash(local)) break;
      local = current;
      dirtySince = _config?.dirtySince ?? dirtySince;
      result = merge();
    }

    bool enabledKey(String key) {
      final category = SyncCategory.ofKey(key);
      return category != null && config.categories.contains(category);
    }

    var after = local;
    if (result.toApply.isNotEmpty) {
      final values = <String, Object?>{
        for (final record in result.merged.values)
          if (!record.deleted && enabledKey(record.key))
            record.key: record.value,
      };
      _applying = true;
      try {
        await _local.apply(
          values,
          result.toApply.keys.toSet(),
          _options(config),
        );
      } finally {
        _applying = false;
      }
      after = await _local.snapshot(_options(config));
    }
    // Applied keys are hashed as the app stored them; the others as they
    // were merged, so an edit made since (its push still pending) is not
    // taken as synced. Keys of a category turned off keep the hash and
    // clock they were last synced with (see [SyncBaseEntry.pausedClock]).
    SyncBaseEntry baseEntry(SyncRecord record) {
      if (enabledKey(record.key)) {
        return SyncBaseEntry(
          record: record,
          localHash: valueHash(
            result.toApply.containsKey(record.key)
                ? after[record.key]
                : local[record.key],
          ),
        );
      }
      final previous = base[record.key];
      final localHash = previous?.localHash;
      return SyncBaseEntry(
        record: record,
        localHash: localHash,
        pausedClock: localHash == null
            ? null
            : previous!.pausedClock ?? previous.record.clock,
      );
    }

    await _state.saveBase({
      for (final record in result.merged.values) record.key: baseEntry(record),
    });
    await _logMerge(result);

    final registered = meta?.devices.any(
      (device) =>
          device.id == config.deviceId &&
          device.name == config.deviceName &&
          device.publicKey == config.devicePublicKey,
    );
    final push =
        result.pushNeeded ||
        registered != true ||
        config.pendingRevocations.isNotEmpty ||
        _forcePush;
    // Settings changed during the sync (a switch, a device name, a new
    // local edit) are in the latest config; keep them.
    final latest = _config ?? config;
    config = latest.copyWith(
      counter: result.counter,
      initialized: {...latest.initialized, ...config.categories},
      lastRevision: meta?.version ?? 0,
      unpushed: push,
      clearDirtySince: latest.dirtySince == dirtySince,
    );
    _config = config;
    await _state.saveConfig(config);
    if (!push) return null;

    final now = _now();
    final revoked = {...?meta?.revoked, ...config.pendingRevocations};
    final newMeta = SyncHubMeta(
      version: (meta?.version ?? 0) + 1,
      updatedAt: now,
      updatedBy: config.deviceId,
      devices: [
        for (final device in meta?.devices ?? const <SyncDeviceInfo>[])
          if (device.id != config.deviceId && !revoked.contains(device.id))
            device,
        SyncDeviceInfo(
          id: config.deviceId,
          name: config.deviceName,
          platform: platform,
          lastSeen: now,
          publicKey: config.devicePublicKey,
        ),
      ],
      revoked: revoked.toList(),
    );
    final document = SyncDocument(
      records: result.merged,
      revision: newMeta.version,
      vaultId: config.vaultId,
      deviceId: config.deviceId,
      createdAt: now,
    );
    final bundle = await _crypto.seal(
      key,
      Uint8List.fromList(utf8.encode(jsonEncode(document.toJson()))),
      vaultId: config.vaultId,
    );
    final outcome = await hub.push(
      config.vaultId,
      bundle: bundle,
      meta: newMeta,
      expectedVersion: meta?.version ?? 0,
    );
    if (outcome == SyncPushOutcome.ok) {
      _forcePush = false;
      _lastMeta = newMeta;
      final latest = _config ?? config;
      _config = latest.copyWith(
        lastRevision: newMeta.version,
        unpushed: false,
        pendingRevocations: [
          for (final id in latest.pendingRevocations)
            if (!revoked.contains(id)) id,
        ],
      );
      await _state.saveConfig(_config);
    }
    return outcome;
  }

  Future<Map<String, SyncRecord>> _download(
    SyncHub hub,
    SyncConfig config,
    SyncKey key,
  ) async {
    final bytes = await hub.readBundle(config.vaultId);
    final Uint8List plaintext;
    try {
      plaintext = await _crypto.open(bytes, key: key);
    } on SyncCryptoException catch (error) {
      if (error.error == SyncCryptoError.wrongKey) {
        throw const AppFailure(
          'The sync data on the hub is locked with a different passphrase. '
          'Turn sync off and set it up again with the current passphrase.',
        );
      }
      rethrow;
    }
    return SyncDocument.fromJson(jsonDecode(utf8.decode(plaintext))).records;
  }

  /// At this device's first machine sync, a saved machine that is the same
  /// host, port and user as one on the hub takes the hub's id, so the two
  /// merge instead of showing twice.
  Future<bool> _adoptMachines(
    Map<String, SyncRecord> remote,
    SyncConfig config,
  ) async {
    String endpoint(Object? host, Object? port, Object? user) =>
        '${host.toString().trim().toLowerCase()}:$port:${user.toString().trim()}';
    final localIds = _hosts.hosts.map((host) => host.id).toSet();
    final remoteByEndpoint = <String, List<String>>{};
    for (final record in remote.values) {
      if (record.deleted || !record.key.startsWith('${SyncKeys.hostPrefix}:')) {
        continue;
      }
      final value = record.value;
      if (value is! Map) continue;
      final id = SyncKeys.idOf(record.key, SyncKeys.hostPrefix);
      if (localIds.contains(id)) continue;
      remoteByEndpoint
          .putIfAbsent(
            endpoint(value['host'], value['port'], value['username']),
            () => [],
          )
          .add(id);
    }
    final renamed = <String, String>{};
    final taken = <String>{};
    for (final host in _hosts.hosts) {
      if (host.isLocal || remote.containsKey(SyncKeys.host(host.id))) continue;
      final matches =
          remoteByEndpoint[endpoint(host.host, host.port, host.username)];
      if (matches == null || matches.length != 1) continue;
      if (!taken.add(matches.single)) continue;
      renamed[host.id] = matches.single;
    }
    if (renamed.isEmpty) return false;
    await _hosts.replaceAll(
      [
        for (final host in _hosts.hosts)
          renamed.containsKey(host.id)
              ? host.copyWith(id: renamed[host.id])
              : host,
      ],
      manualOrder: [for (final id in _hosts.manualOrder) renamed[id] ?? id],
    );
    final hubId = renamed[config.hubHostId];
    if (hubId != null) {
      _config = config.copyWith(hubHostId: hubId);
      await _state.saveConfig(_config);
    }
    return true;
  }

  Future<void> _logMerge(SyncMergeResult result) async {
    final firstSync = result.conflicts
        .where((c) => c.kind == SyncConflictKind.firstSync)
        .toList();
    if (firstSync.isNotEmpty) {
      await _log(
        SyncActivityKind.info,
        'First sync: ${firstSync.length} item(s) here were replaced by the '
        "hub's version (${_describeKeys(firstSync.map((c) => c.key))}).",
      );
    }
    for (final conflict in result.conflicts) {
      if (conflict.kind != SyncConflictKind.concurrentEdit) continue;
      await _log(
        SyncActivityKind.conflict,
        conflict.keptLocal
            ? 'Kept this device\'s edit of ${describeSyncKey(conflict.key)}; '
                  'another device changed it too.'
            : '${describeSyncKey(conflict.key)} was changed on another device '
                  'after your edit here; the newer one won.',
        key: conflict.key,
        lostValue: conflict.keptLocal ? null : conflict.lostValue,
        canRestore: !conflict.keptLocal,
      );
    }
    final applied = result.toApply.length;
    final edited = result.localEdits.length;
    if (applied > 0 || edited > 0) {
      await _log(
        SyncActivityKind.synced,
        [
          if (applied > 0) 'Received $applied change(s)',
          if (edited > 0) 'Sent $edited change(s)',
        ].join(', '),
      );
    }
  }

  static String _describeKeys(Iterable<String> keys) {
    final names = keys.map(describeSyncKey).toSet().toList();
    if (names.length <= 3) return names.join(', ');
    return '${names.take(3).join(', ')} and ${names.length - 3} more';
  }

  Future<void> _log(
    SyncActivityKind kind,
    String message, {
    String? key,
    Object? lostValue,
    bool canRestore = false,
  }) async {
    _activity = [
      SyncActivityEntry(
        at: _now(),
        kind: kind,
        message: message,
        key: key,
        lostValue: lostValue,
        canRestore: canRestore,
      ),
      ..._activity,
    ].take(_maxActivity).toList();
    await _state.saveActivity(_activity);
    _notify();
  }

  String _describe(Object error) {
    if (error is AppFailure) return error.userMessage;
    if (error is SyncCryptoException) return error.message;
    if (error is SyncFormatException) return error.message;
    if (error is LocalSyncUnavailable) return error.message;
    return 'Sync failed: $error';
  }

  // Setting up.

  /// Starts syncing through [hub]. When the hub already holds sync data,
  /// [passphrase] must open it and this device joins; otherwise a new
  /// vault is created with it.
  Future<void> setUp({
    required SavedHost hub,
    required String passphrase,
    String? deviceName,
    Set<SyncCategory> categories = SyncCategory.defaults,
  }) async {
    if (enabled) throw StateError('Sync is already on.');
    final deviceId = randomSyncId();
    final client = _hubFactory(hub, deviceId);
    try {
      final vaults = await client.listVaults();
      String? vaultId;
      SyncKey? key;
      if (vaults.isEmpty) {
        vaultId = randomSyncId();
        key = await _crypto.newKey(passphrase);
      } else {
        final ordered = <(DateTime, String)>[];
        for (final vault in vaults) {
          final meta = await client.readMeta(vault);
          ordered.add((
            meta?.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0),
            vault,
          ));
        }
        ordered.sort((a, b) => b.$1.compareTo(a.$1));
        for (final (_, vault) in ordered) {
          final bytes = await client.readBundle(vault);
          final header = SyncCrypto.readHeader(bytes);
          final candidate = await _crypto.deriveKey(
            passphrase,
            header.salt,
            header.params,
          );
          try {
            await _crypto.open(bytes, key: candidate);
          } on SyncCryptoException catch (error) {
            if (error.error == SyncCryptoError.wrongKey) continue;
            rethrow;
          }
          vaultId = vault;
          key = candidate;
          break;
        }
        if (vaultId == null || key == null) {
          throw SyncSetupException(
            'That passphrase does not open the sync data on ${hub.name}.',
          );
        }
      }
      await _enable(
        SyncConfig(
          vaultId: vaultId,
          hubHostId: hub.id,
          deviceId: deviceId,
          deviceName: _cleanName(deviceName),
          categories: categories,
        ),
        key,
      );
    } finally {
      await client.close();
    }
    await _log(SyncActivityKind.info, 'Sync turned on with ${hub.name}.');
    await syncNow();
  }

  /// Hub vault ids on [hub] (to tell "create" from "join" in the UI).
  Future<bool> hubHasSyncData(SavedHost hub) async {
    final client = _hubFactory(hub, randomSyncId());
    try {
      return (await client.listVaults()).isNotEmpty;
    } finally {
      await client.close();
    }
  }

  /// Joins with a setup code from "Add a device" and its six words: saves
  /// the hub machine with the one-time key and its expected host key,
  /// replaces that key with one generated here, then pulls everything.
  Future<void> join({
    required String setupCode,
    required String words,
    String? deviceName,
  }) async {
    if (enabled) throw StateError('Sync is already on.');
    final offer = SyncSetupOffer.decode(setupCode);
    if (offer == null) {
      throw const SyncSetupException('This is not a Conductore setup code.');
    }
    final secret = await _setupCodec.open(offer, words);
    await _hosts.firstLoad;
    final oneTime = DeviceSshKey.fromSeed(secret.deviceKeySeed);
    final name = _cleanName(deviceName ?? secret.deviceName);

    bool sameEndpoint(SavedHost host) =>
        !host.isLocal &&
        host.host.trim().toLowerCase() == offer.host.trim().toLowerCase() &&
        host.port == offer.port &&
        host.username.trim() == offer.username.trim();
    final byId = _findHost(offer.hubHostId);
    final byEndpoint = _hosts.hosts.where(sameEndpoint).firstOrNull;
    final existing = byId ?? byEndpoint;
    var hubHost =
        (existing ??
                SavedHost(
                  id: offer.hubHostId,
                  name: offer.hubName,
                  host: offer.host,
                  port: offer.port,
                  username: offer.username,
                  authMethod: SshAuthMethod.privateKey,
                ))
            .copyWith(
              id: offer.hubHostId,
              host: offer.host,
              port: offer.port,
              username: offer.username,
              authMethod: SshAuthMethod.privateKey,
              privateKey: oneTime.privateKeyPem,
              passphrase: '',
            );
    if (byEndpoint != null && byEndpoint.id != offer.hubHostId) {
      await _hosts.remove(byEndpoint);
    }
    await _hosts.upsert(hubHost);
    final trusted = await _hostKeys.loadTrustedKeys();
    await _hostKeys.saveTrustedKeys([
      for (final record in trusted)
        if (!(record.host == offer.host && record.port == offer.port)) record,
      HostKeyRecord(
        host: offer.host,
        port: offer.port,
        type: offer.hostKeyType,
        fingerprint: offer.hostKeyFingerprint,
        trustedAt: _now(),
      ),
    ]);

    var config = SyncConfig(
      vaultId: offer.vaultId,
      hubHostId: offer.hubHostId,
      deviceId: secret.deviceId,
      deviceName: name,
      devicePublicKey: oneTime.publicKey,
    );
    try {
      final fresh = DeviceSshKey.generate();
      hubHost = await _replaceDeviceKey(hubHost, config, oneTime, fresh);
      config = config.copyWith(devicePublicKey: fresh.publicKey);
    } catch (error) {
      await _log(
        SyncActivityKind.info,
        'Kept the key from the setup code; replacing it failed '
        '(${_describe(error)}).',
      );
    }
    await _enable(config, secret.syncKey);
    await _log(SyncActivityKind.info, 'Joined sync through ${offer.hubName}.');
    await syncNow();
  }

  /// Installs [fresh] through the one-time key, proves it works by
  /// removing the one-time key with it, then saves it on the hub machine.
  Future<SavedHost> _replaceDeviceKey(
    SavedHost hubHost,
    SyncConfig config,
    DeviceSshKey oneTime,
    DeviceSshKey fresh,
  ) async {
    final withOneTime = _hubFactory(hubHost, config.deviceId);
    try {
      await withOneTime.addDeviceKey(fresh.publicKey, config.deviceName);
    } finally {
      await withOneTime.close();
    }
    final updated = hubHost.copyWith(privateKey: fresh.privateKeyPem);
    final withFresh = _hubFactory(updated, config.deviceId);
    try {
      await withFresh.removeDeviceKey(oneTime.publicKey);
    } catch (_) {
      // The new key did not work: take it back out, keep the old one.
      final cleanup = _hubFactory(hubHost, config.deviceId);
      try {
        await cleanup.removeDeviceKey(fresh.publicKey);
      } finally {
        await cleanup.close();
      }
      rethrow;
    } finally {
      await withFresh.close();
    }
    await _hosts.upsert(updated);
    return updated;
  }

  Future<void> _enable(SyncConfig config, SyncKey key) async {
    await _state.saveBase(const {});
    await _state.saveKey(key);
    await _state.saveConfig(config);
    _key = key;
    _config = config;
    _status = SyncStatus.idle;
    _error = null;
    _startPolling();
    _notify();
  }

  String _cleanName(String? name) {
    final trimmed = name?.trim() ?? '';
    return trimmed.isEmpty ? defaultDeviceName : trimmed;
  }

  // Devices.

  /// Installs a one-time key for a new device on the hub and seals the
  /// setup code for it.
  Future<SyncPairingOffer> addDevice(String deviceName) async {
    final config = _config;
    final key = _key;
    if (config == null || key == null) throw StateError('Sync is off.');
    final hubHost = _findHost(config.hubHostId);
    if (hubHost == null) {
      throw const AppFailure('The sync hub machine is not saved here.');
    }
    final hub = _hubFor(hubHost, config.deviceId);
    var hostKey = await _hubHostKey(hubHost);
    if (hostKey == null) {
      // Connecting once records (or asks to trust) the host key.
      await hub.readMeta(config.vaultId);
      hostKey = await _hubHostKey(hubHost);
    }
    if (hostKey == null) {
      throw const AppFailure(
        "The hub's host key is not trusted on this device yet.",
      );
    }
    final name = _cleanName(deviceName);
    final deviceKey = DeviceSshKey.generate();
    await hub.addDeviceKey(deviceKey.publicKey, name);
    final words = SetupWords.generate();
    final offer = await _setupCodec.seal(
      hubName: hubHost.name,
      host: hubHost.host.trim(),
      port: hubHost.port,
      username: hubHost.username.trim(),
      hostKeyType: hostKey.type,
      hostKeyFingerprint: hostKey.fingerprint,
      hubHostId: config.hubHostId,
      vaultId: config.vaultId,
      secret: SyncSetupSecret(
        deviceId: randomSyncId(),
        deviceName: name,
        deviceKeySeed: deviceKey.seed,
        syncKey: key,
      ),
      words: words,
    );
    await _log(
      SyncActivityKind.info,
      'Added a one-time key for "$name" to ${hubHost.name}.',
    );
    return SyncPairingOffer(
      setupCode: offer.encode(),
      words: words,
      deviceName: name,
      publicKey: deviceKey.publicKey,
    );
  }

  Future<HostKeyRecord?> _hubHostKey(SavedHost hubHost) async {
    final records = await _hostKeys.loadTrustedKeys();
    return records
        .where(
          (record) =>
              record.host == hubHost.host.trim() && record.port == hubHost.port,
        )
        .firstOrNull;
  }

  /// Takes back the key of a pairing that was not used.
  Future<void> cancelPairing(SyncPairingOffer offer) async {
    final config = _config;
    if (config == null) return;
    final hubHost = _findHost(config.hubHostId);
    if (hubHost == null) return;
    await _hubFor(hubHost, config.deviceId).removeDeviceKey(offer.publicKey);
    await _log(
      SyncActivityKind.info,
      'Removed the unused key for "${offer.deviceName}".',
    );
  }

  /// Reads the device list: the hub's meta plus its `conductore-device`
  /// keys.
  Future<void> refreshDevices() async {
    final config = _config;
    if (config == null) return;
    final hubHost = _findHost(config.hubHostId);
    if (hubHost == null) return;
    final hub = _hubFor(hubHost, config.deviceId);
    final meta = await hub.readMeta(config.vaultId) ?? _lastMeta;
    final keys = await hub.deviceKeys();
    final revoked = {...?meta?.revoked, ...config.pendingRevocations};
    final views = <SyncDeviceView>[];
    final listedKeys = <String>{};
    for (final device in meta?.devices ?? const <SyncDeviceInfo>[]) {
      if (revoked.contains(device.id)) continue;
      final publicKey = device.publicKey;
      if (publicKey != null) listedKeys.add(publicKey);
      views.add(
        SyncDeviceView(
          id: device.id,
          name: device.name,
          platform: device.platform,
          lastSeen: device.lastSeen,
          publicKey: keys.any((k) => k.publicKey == publicKey)
              ? publicKey
              : null,
          isThisDevice: device.id == config.deviceId,
        ),
      );
    }
    for (final key in keys) {
      if (listedKeys.contains(key.publicKey)) continue;
      views.add(SyncDeviceView(name: key.name, publicKey: key.publicKey));
    }
    views.sort((a, b) {
      if (a.isThisDevice != b.isThisDevice) return a.isThisDevice ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    _devices = views;
    _notify();
  }

  /// Revokes [device]'s hub key and drops it from the device list. The
  /// device keeps what it already synced.
  Future<void> removeDevice(SyncDeviceView device) async {
    final config = _config;
    if (config == null) return;
    if (device.isThisDevice) {
      throw StateError('Use Turn off sync for this device.');
    }
    final hubHost = _findHost(config.hubHostId);
    if (hubHost == null) return;
    final publicKey = device.publicKey;
    if (publicKey != null) {
      await _hubFor(hubHost, config.deviceId).removeDeviceKey(publicKey);
    }
    final id = device.id;
    if (id != null) {
      _config = config.copyWith(
        pendingRevocations: {...config.pendingRevocations, id}.toList(),
      );
      await _state.saveConfig(_config);
      _forcePush = true;
      await syncNow();
    }
    await _log(SyncActivityKind.info, 'Removed "${device.name}" from sync.');
    await refreshDevices();
  }

  // Settings.

  Future<void> setCategory(SyncCategory category, bool on) async {
    final config = _config;
    if (config == null) return;
    final categories = {...config.categories};
    on ? categories.add(category) : categories.remove(category);
    _config = config.copyWith(categories: categories);
    await _state.saveConfig(_config);
    _notify();
    unawaited(syncNow());
  }

  Future<void> setDeviceName(String name) async {
    final config = _config;
    if (config == null) return;
    _config = config.copyWith(deviceName: _cleanName(name));
    await _state.saveConfig(_config);
    _notify();
    unawaited(syncNow());
  }

  /// Puts back this device's value that lost a conflict, as a new edit.
  Future<void> keepMine(SyncActivityEntry entry) async {
    final config = _config;
    final key = entry.key;
    if (config == null || key == null || !entry.canRestore) return;
    final options = _options(config);
    final values = await _local.snapshot(options);
    final lost = entry.lostValue;
    if (lost == null) {
      values.remove(key);
    } else {
      values[key] = lost;
    }
    await _local.apply(values, {key}, options);
    _activity = [
      for (final item in _activity)
        identical(item, entry) ? item.resolved() : item,
    ];
    await _state.saveActivity(_activity);
    await _log(
      SyncActivityKind.info,
      'Restored this device\'s version of ${describeSyncKey(key)}.',
    );
    await syncNow();
  }

  /// Stops syncing on this device. Local data stays; with
  /// [deleteHubData] the hub's bundle goes too (other devices then stop
  /// finding it).
  Future<void> turnOff({bool deleteHubData = false}) async {
    final config = _config;
    if (config == null) return;
    await _running;
    if (deleteHubData) {
      final hubHost = _findHost(config.hubHostId);
      if (hubHost != null) {
        await _hubFor(hubHost, config.deviceId).deleteVault(config.vaultId);
      }
    }
    await _stopLocally(null);
  }

  Future<void> _stopLocally(String? reason) async {
    _debounce?.cancel();
    _debounce = null;
    _poll?.cancel();
    _poll = null;
    await _closeHub();
    _config = null;
    _key = null;
    _devices = const [];
    _lastMeta = null;
    _status = SyncStatus.off;
    _error = null;
    await _state.saveConfig(null);
    await _state.saveKey(null);
    await _state.saveBase(const {});
    _activity = const [];
    await _state.saveActivity(const []);
    if (reason != null) await _log(SyncActivityKind.info, reason);
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    _poll?.cancel();
    for (final source in _changeSources) {
      source.removeListener(_onLocalChange);
    }
    if (observeLifecycle && _started) {
      WidgetsBinding.instance.removeObserver(this);
    }
    unawaited(_closeHub());
    super.dispose();
  }
}

/// 128 random bits as 32 lowercase hex characters (vault and device ids).
String randomSyncId() => SyncCrypto.randomBytes(
  16,
).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

/// A record key in words, for the activity list.
String describeSyncKey(String key) {
  final category = SyncCategory.ofKey(key);
  final rest = key.contains(':') ? key.substring(key.indexOf(':') + 1) : key;
  return switch (category) {
    SyncCategory.machines when key.startsWith('${SyncKeys.hostPrefix}:') =>
      'a saved machine',
    SyncCategory.machines when key.startsWith('${SyncKeys.knownHostPrefix}:') =>
      'the host key of $rest',
    SyncCategory.machines => 'the machine order',
    SyncCategory.credentials => 'a saved credential',
    SyncCategory.snippets => 'a snippet',
    SyncCategory.appearance => 'the setting "$rest"',
    SyncCategory.connections => 'connect preferences',
    SyncCategory.sessions => 'the session list',
    null => key,
  };
}
