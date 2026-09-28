import 'dart:convert';

import 'package:conduit/core/theme/theme_controller.dart';
import 'package:conduit/features/continuity/domain/continuity_sync_port.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/hosts/domain/saved_hosts_repository.dart';
import 'package:conduit/features/hosts/presentation/hosts_controller.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:conduit/features/sessions/domain/session_snapshot.dart';
import 'package:conduit/features/snippets/domain/terminal_snippet.dart';
import 'package:conduit/features/sync/data/app_settings_codec.dart';
import 'package:conduit/features/sync/domain/local_data_changes.dart';
import 'package:conduit/features/sync/domain/local_sync_store.dart';
import 'package:conduit/features/sync/domain/sync_category.dart';
import 'package:conduit/features/terminal/domain/host_key_verifier.dart';
import 'package:conduit/features/terminal/presentation/recent_directories_controller.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// A JSON object kept whole under one storage key (connect preferences,
/// recent directories), read and written as a map.
abstract interface class JsonMapStore {
  Future<Map<String, Object?>> readAll();
  Future<void> writeAll(Map<String, Object?> values);
}

class SecureJsonMapStore implements JsonMapStore {
  const SecureJsonMapStore(this._storage, this._key);

  final FlutterSecureStorage _storage;
  final String _key;

  @override
  Future<Map<String, Object?>> readAll() async {
    final raw = await _storage.read(key: _key);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return Map<String, Object?>.from(decoded);
    } catch (_) {
      // Unreadable preferences are rebuilt from the synced copy.
    }
    return {};
  }

  @override
  Future<void> writeAll(Map<String, Object?> values) =>
      _storage.write(key: _key, value: jsonEncode(values));
}

/// Maps the app's controllers and stores to sync records and back.
///
/// Record layout (see [SyncKeys]):
/// * `host:<id>`: a saved machine without secrets, hardware keys, its
///   last-connected time or, for the hub, its login. Hidden snippet text
///   is blanked.
/// * `secret:host:<id>`: password, private key, passphrase and hidden
///   snippet text of one machine (credentials category).
/// * `knownHost:<host>:<port>`: a trusted host key.
/// * `hosts:sortMode`, `hosts:manualOrder`: the machine list order.
/// * `snippet:<id>` and `secret:snippet:<id>`: global snippets.
/// * `setting:<name>`: one [AppSettingsCodec] entry.
/// * `connect:<hostId>`, `recentDirs:<hostId>`: connect-picker memory.
/// * `sessions`: the session-restore list.
/// * `continuity:<device id>`: where each device is and its drafts (see
///   [ContinuitySyncPort]); this device writes only its own.
class AppLocalSyncStore implements LocalSyncStore {
  AppLocalSyncStore({
    required this.hosts,
    required this.theme,
    required this.hostKeys,
    required this.connectPreferences,
    required this.recentDirectoriesStore,
    required this.sessions,
    this.recentDirectories,
    this.ready,
    this.changes,
    this.continuity,
  });

  final HostsController hosts;
  final ThemeController theme;
  final HostKeyVerifier hostKeys;
  final JsonMapStore connectPreferences;

  /// Read side of recent directories (all hosts at once).
  final JsonMapStore recentDirectoriesStore;

  /// Write side of recent directories, so the in-memory cache follows.
  final RecentDirectoriesController? recentDirectories;
  final SessionSnapshotRepository sessions;

  /// Completes once the app's settings are loaded.
  final Future<void>? ready;

  /// Told after every [apply] that wrote something, so live pages reload
  /// what they cached (imports and sync pulls).
  final LocalDataChanges? changes;

  /// Where each device is; null leaves continuity out.
  final ContinuitySyncPort? continuity;

  static const _hostSecretFields = ['password', 'privateKey', 'passphrase'];
  static const _hubLoginFields = ['authMethod', 'externalAuthOfferKey'];
  static const _followSetting = 'omarchySyncHostId';

  Future<void> _whenLoaded() async {
    await ready;
    await hosts.firstLoad;
    if (hosts.errorMessage != null && hosts.hosts.isEmpty) {
      throw LocalSyncUnavailable(
        'Saved machines could not be read: ${hosts.errorMessage}',
      );
    }
  }

  @override
  Future<Map<String, Object?>> snapshot(LocalSyncOptions options) async {
    await _whenLoaded();
    final on = options.categories;
    final out = <String, Object?>{};

    for (final host in hosts.hosts) {
      if (host.isLocal) continue;
      if (on.contains(SyncCategory.machines)) {
        out[SyncKeys.host(host.id)] = _hostRecord(host, options);
      }
      if (on.contains(SyncCategory.credentials) &&
          host.id != options.hubHostId) {
        out[SyncKeys.hostSecret(host.id)] = _hostSecretRecord(host, options);
      }
    }
    if (on.contains(SyncCategory.machines)) {
      out[SyncKeys.hostSortMode] = hosts.sortMode.name;
      out[SyncKeys.hostManualOrder] = hosts.manualOrder;
      for (final record in await hostKeys.loadTrustedKeys()) {
        if (record.host.isEmpty || record.fingerprint.isEmpty) continue;
        out[SyncKeys.knownHost(record.host, record.port)] = {
          'host': record.host,
          'port': record.port,
          'type': record.type,
          'fingerprint': record.fingerprint,
        };
      }
    }

    final snippets = theme.terminalSnippets;
    for (var i = 0; i < snippets.length; i++) {
      final snippet = snippets[i];
      if (on.contains(SyncCategory.snippets)) {
        out[SyncKeys.snippet(snippet.id)] = {
          'position': i,
          ..._snippetWithoutSecret(snippet).toJson(),
        };
      }
      if (on.contains(SyncCategory.credentials) &&
          snippet.hidden &&
          snippet.text.isNotEmpty) {
        out[SyncKeys.snippetSecret(snippet.id)] = {'text': snippet.text};
      }
    }

    if (on.contains(SyncCategory.appearance)) {
      final settings = AppSettingsCodec.encode(theme);
      // A desktop following "This computer" follows, for the other
      // devices, the saved machine that is this desktop.
      final self = hosts.selfMachine?.id;
      if (theme.omarchySyncHostId == thisComputerHostId && self != null) {
        settings[_followSetting] = self;
      }
      settings.forEach((name, value) {
        out[SyncKeys.setting(name)] = value;
      });
    }

    if (on.contains(SyncCategory.connections)) {
      // With machines syncing, the memory of a machine no longer saved
      // (deleted, or its id changed) stays here instead of following that
      // id to every device.
      final saved = on.contains(SyncCategory.machines)
          ? {for (final host in hosts.hosts) host.id}
          : null;
      bool known(String hostId) =>
          saved == null || saved.contains(baseHostId(hostId));
      (await connectPreferences.readAll()).forEach((hostId, value) {
        if (value != null && known(hostId)) {
          out[SyncKeys.connect(hostId)] = value;
        }
      });
      (await recentDirectoriesStore.readAll()).forEach((hostId, value) {
        if (value is List && value.isNotEmpty && known(hostId)) {
          out[SyncKeys.recentDirs(hostId)] = value;
        }
      });
    }

    if (on.contains(SyncCategory.sessions)) {
      final snapshot = await sessions.load();
      if (!snapshot.isEmpty) out[SyncKeys.sessionsKey] = snapshot.toJson();
    }

    final continuity = this.continuity;
    final deviceId = options.deviceId;
    if (on.contains(SyncCategory.continuity) &&
        continuity != null &&
        deviceId != null) {
      final record = await continuity.ownRecord(deviceId);
      if (record != null) out[SyncKeys.continuity(deviceId)] = record;
    }
    return out;
  }

  Map<String, Object?> _hostRecord(SavedHost host, LocalSyncOptions options) {
    final json = host
        .copyWith(
          snippets: [for (final s in host.snippets) _snippetWithoutSecret(s)],
        )
        .toJson();
    for (final field in [
      ..._hostSecretFields,
      'hardwareKeys',
      'lastConnectedAt',
      'isLocal',
      if (host.id == options.hubHostId) ..._hubLoginFields,
    ]) {
      json.remove(field);
    }
    return json;
  }

  Map<String, Object?> _hostSecretRecord(
    SavedHost host,
    LocalSyncOptions options,
  ) {
    final hardware = host.authMethod == SshAuthMethod.hardwareKey;
    return {
      'password': host.password,
      // For hardware-key hosts these fields hold the first stub.
      if (!hardware || options.includeHardwareKeys) ...{
        'privateKey': host.privateKey,
        'passphrase': host.passphrase,
      },
      if (options.includeHardwareKeys && hardware)
        'hardwareKeys': [
          for (final key in host.effectiveHardwareKeys) key.toJson(),
        ],
      'snippetTexts': {
        for (final snippet in host.snippets)
          if (snippet.hidden && snippet.text.isNotEmpty)
            snippet.id: snippet.text,
      },
    };
  }

  static TerminalSnippet _snippetWithoutSecret(TerminalSnippet snippet) =>
      snippet.hidden ? snippet.copyWith(text: '') : snippet;

  @override
  Future<void> apply(
    Map<String, Object?> values,
    Set<String> changedKeys,
    LocalSyncOptions options, {
    bool replace = true,
  }) async {
    await _whenLoaded();
    try {
      await _apply(values, changedKeys, options, replace: replace);
    } finally {
      // Continuity has its own listeners: another device moving must not
      // make every page reload its saved data.
      final announced = {
        for (final key in changedKeys)
          if (SyncCategory.ofKey(key) != SyncCategory.continuity) key,
      };
      if (announced.isNotEmpty) changes?.announce(announced);
    }
  }

  Future<void> _apply(
    Map<String, Object?> values,
    Set<String> changedKeys,
    LocalSyncOptions options, {
    required bool replace,
  }) async {
    final on = options.categories;
    bool changed(bool Function(String key) test) => changedKeys.any(test);

    if ((on.contains(SyncCategory.machines) ||
            on.contains(SyncCategory.credentials)) &&
        changed(
          (key) =>
              key.startsWith('${SyncKeys.hostPrefix}:') ||
              key.startsWith('${SyncKeys.hostListPrefix}:') ||
              key.startsWith('${SyncKeys.secretPrefix}:host:'),
        )) {
      await _applyHosts(values, changedKeys, options, replace: replace);
    }
    if (on.contains(SyncCategory.machines) &&
        changed((key) => key.startsWith('${SyncKeys.knownHostPrefix}:'))) {
      await _applyKnownHosts(values, changedKeys, replace: replace);
    }
    if ((on.contains(SyncCategory.snippets) ||
            on.contains(SyncCategory.credentials)) &&
        changed(
          (key) =>
              key.startsWith('${SyncKeys.snippetPrefix}:') ||
              key.startsWith('${SyncKeys.secretPrefix}:snippet:'),
        )) {
      await _applySnippets(values, changedKeys, options, replace: replace);
    }
    if (on.contains(SyncCategory.appearance)) {
      final settings = <String, Object?>{
        for (final name in AppSettingsCodec.keys)
          if (changedKeys.contains(SyncKeys.setting(name)) &&
              values.containsKey(SyncKeys.setting(name)))
            name: values[SyncKeys.setting(name)],
      };
      // The saved machine that is this desktop is not listed here: its
      // theme is read as "This computer".
      final self = hosts.hiddenSelfMachine?.id;
      final followSelf = self != null && settings[_followSetting] == self;
      if (followSelf) settings.remove(_followSetting);
      if (settings.isNotEmpty) await AppSettingsCodec.apply(theme, settings);
      if (followSelf) await theme.setOmarchySyncHost(thisComputerHostId);
    }
    if (on.contains(SyncCategory.connections)) {
      await _applyConnections(values, changedKeys);
    }
    final continuity = this.continuity;
    final deviceId = options.deviceId;
    if (on.contains(SyncCategory.continuity) &&
        continuity != null &&
        deviceId != null &&
        changed((key) => key.startsWith('${SyncKeys.continuityPrefix}:'))) {
      // Every device's record comes along, so continuity sees them all.
      await continuity.receive({
        for (final MapEntry(:key, :value) in values.entries)
          if (SyncKeys.isForeign(key, deviceId) && value != null) key: value,
      }, deviceId: deviceId);
    }
    if (on.contains(SyncCategory.sessions) &&
        changedKeys.contains(SyncKeys.sessionsKey)) {
      final raw = values[SyncKeys.sessionsKey];
      if (raw == null) {
        if (replace) await sessions.clear();
      } else {
        await sessions.save(SessionSnapshot.fromJson(raw));
      }
    }
  }

  /// Only the machines under [changedKeys] change; the others stay as they
  /// are now, edits made since the sync's snapshot included.
  Future<void> _applyHosts(
    Map<String, Object?> values,
    Set<String> changedKeys,
    LocalSyncOptions options, {
    required bool replace,
  }) async {
    final on = options.categories;
    final machines = on.contains(SyncCategory.machines);
    final credentials = on.contains(SyncCategory.credentials);
    final current = hosts.hosts;
    final result = <SavedHost>[];
    final placed = <String>{};

    SavedHost build(SavedHost? existing, String id) {
      final json = <String, Object?>{...?existing?.toJson()};
      final record = machines ? values[SyncKeys.host(id)] : null;
      if (record is Map) {
        final incoming = Map<String, Object?>.from(record);
        if (id == options.hubHostId) {
          for (final field in _hubLoginFields) {
            incoming.remove(field);
          }
        }
        json.addAll(incoming);
        // Hidden snippet text never travels in the machine record.
        json['snippets'] = _withLocalHiddenText(
          json['snippets'],
          existing?.snippets ?? const [],
        );
      }
      final secret = credentials && id != options.hubHostId
          ? values[SyncKeys.hostSecret(id)]
          : null;
      if (secret is Map) {
        for (final field in _hostSecretFields) {
          final value = secret[field];
          if (value is String) json[field] = value;
        }
        final hardwareKeys = secret['hardwareKeys'];
        if (hardwareKeys is List) json['hardwareKeys'] = hardwareKeys;
        final texts = secret['snippetTexts'];
        if (texts is Map) {
          json['snippets'] = [
            for (final raw in (json['snippets'] as List?) ?? const [])
              if (raw is Map)
                {
                  ...Map<String, Object?>.from(raw),
                  if (raw['hidden'] == true && texts[raw['id']] is String)
                    'text': texts[raw['id']],
                },
          ];
        }
      }
      json['id'] = id;
      json['isLocal'] = false;
      json['lastConnectedAt'] = existing?.lastConnectedAt?.toIso8601String();
      return SavedHost.fromJson(json);
    }

    for (final host in current) {
      if (host.isLocal) {
        result.add(host);
        continue;
      }
      final key = SyncKeys.host(host.id);
      if (machines &&
          replace &&
          changedKeys.contains(key) &&
          !values.containsKey(key)) {
        continue; // Deleted on another device.
      }
      final changed =
          changedKeys.contains(key) ||
          changedKeys.contains(SyncKeys.hostSecret(host.id));
      result.add(changed ? build(host, host.id) : host);
      placed.add(host.id);
    }
    if (machines) {
      for (final key in values.keys) {
        if (!key.startsWith('${SyncKeys.hostPrefix}:') ||
            !changedKeys.contains(key)) {
          continue;
        }
        final id = SyncKeys.idOf(key, SyncKeys.hostPrefix);
        if (id.isEmpty || placed.contains(id)) continue;
        final host = build(null, id);
        if (host.name.trim().isEmpty || host.host.trim().isEmpty) continue;
        result.add(host);
        placed.add(id);
      }
    }

    HostListSortMode? sortMode;
    List<String>? manualOrder;
    if (machines && changedKeys.contains(SyncKeys.hostSortMode)) {
      final rawMode = values[SyncKeys.hostSortMode];
      sortMode = HostListSortMode.values
          .where((mode) => mode.name == rawMode)
          .firstOrNull;
    }
    if (machines && changedKeys.contains(SyncKeys.hostManualOrder)) {
      final rawOrder = values[SyncKeys.hostManualOrder];
      if (rawOrder is List) {
        manualOrder = rawOrder.whereType<String>().toList();
        if (!replace) {
          manualOrder = [
            ...manualOrder,
            ...hosts.manualOrder.where((id) => !manualOrder!.contains(id)),
          ];
        }
      }
    }
    await hosts.replaceAll(
      result,
      sortMode: sortMode,
      manualOrder: manualOrder,
    );
  }

  static List<Object?> _withLocalHiddenText(
    Object? rawSnippets,
    List<TerminalSnippet> local,
  ) {
    final localText = {
      for (final snippet in local)
        if (snippet.hidden) snippet.id: snippet.text,
    };
    return [
      for (final raw in (rawSnippets as List?) ?? const [])
        if (raw is Map)
          {
            ...Map<String, Object?>.from(raw),
            if (raw['hidden'] == true &&
                (raw['text'] as String? ?? '').isEmpty &&
                localText[raw['id']] != null)
              'text': localText[raw['id']],
          },
    ];
  }

  Future<void> _applyKnownHosts(
    Map<String, Object?> values,
    Set<String> changedKeys, {
    required bool replace,
  }) async {
    final byKey = {
      for (final record in await hostKeys.loadTrustedKeys())
        SyncKeys.knownHost(record.host, record.port): record,
    };
    for (final key in changedKeys) {
      if (!key.startsWith('${SyncKeys.knownHostPrefix}:')) continue;
      final raw = values[key];
      if (raw is Map) {
        final record = HostKeyRecord.fromJson({
          ...Map<String, Object?>.from(raw),
          'trustedAt': (byKey[key]?.trustedAt ?? DateTime.now())
              .toIso8601String(),
        });
        if (record.host.isNotEmpty && record.fingerprint.isNotEmpty) {
          byKey[key] = record;
        }
      } else if (replace) {
        byKey.remove(key);
      }
    }
    await hostKeys.saveTrustedKeys(byKey.values.toList());
  }

  /// Only the snippets under [changedKeys] change; the others stay as they
  /// are now. The list is ordered by the synced positions, and snippets
  /// the values do not know (added here since) go last.
  Future<void> _applySnippets(
    Map<String, Object?> values,
    Set<String> changedKeys,
    LocalSyncOptions options, {
    required bool replace,
  }) async {
    final credentials = options.categories.contains(SyncCategory.credentials);
    final live = theme.terminalSnippets;
    final local = {for (final s in live) s.id: s};
    String hiddenText(String id) {
      final secret = credentials ? values[SyncKeys.snippetSecret(id)] : null;
      if (secret is Map && secret['text'] is String) {
        return secret['text'] as String;
      }
      return local[id]?.text ?? '';
    }

    if (!options.categories.contains(SyncCategory.snippets)) {
      // Credentials only: fill in hidden text of the snippets already here.
      await theme.setTerminalSnippets([
        for (final snippet in live)
          snippet.hidden
              ? snippet.copyWith(text: hiddenText(snippet.id))
              : snippet,
      ]);
      return;
    }
    final byId = {...local};
    for (final key in changedKeys) {
      final String id;
      if (key.startsWith('${SyncKeys.snippetPrefix}:')) {
        id = SyncKeys.idOf(key, SyncKeys.snippetPrefix);
      } else if (key.startsWith('${SyncKeys.secretPrefix}:snippet:')) {
        id = key.substring('${SyncKeys.secretPrefix}:snippet:'.length);
      } else {
        continue;
      }
      final raw = values[SyncKeys.snippet(id)];
      var snippet = raw is Map ? TerminalSnippet.fromJson(raw) : null;
      if (snippet == null) {
        if (replace && changedKeys.contains(SyncKeys.snippet(id))) {
          byId.remove(id);
        }
        continue;
      }
      if (snippet.hidden) {
        snippet = snippet.copyWith(text: hiddenText(snippet.id));
      }
      byId[id] = snippet;
    }
    num position(String id, int index) {
      final raw = values[SyncKeys.snippet(id)];
      final synced = raw is Map ? raw['position'] : null;
      return synced is num ? synced : (1 << 20) + index;
    }

    final ids = [
      ...live.map((s) => s.id).where(byId.containsKey),
      ...byId.keys.where((id) => !local.containsKey(id)),
    ];
    final ordered =
        [for (var i = 0; i < ids.length; i++) (position(ids[i], i), ids[i])]
          ..sort((a, b) {
            final byPosition = a.$1.compareTo(b.$1);
            return byPosition != 0 ? byPosition : a.$2.compareTo(b.$2);
          });
    await theme.setTerminalSnippets([for (final (_, id) in ordered) byId[id]!]);
  }

  @override
  Future<void> renameHosts(Map<String, String> renamed) async {
    if (renamed.isEmpty) return;
    await _whenLoaded();
    // `a#tmux:work` (a session on machine a) moves with a.
    String? renamedId(String hostId) {
      final base = baseHostId(hostId);
      final to = renamed[base];
      return to == null ? null : '$to${hostId.substring(base.length)}';
    }

    final connect = await connectPreferences.readAll();
    if (connect.keys.any((id) => renamedId(id) != null)) {
      await connectPreferences.writeAll({
        for (final MapEntry(:key, :value) in connect.entries)
          renamedId(key) ?? key: value,
      });
    }
    final dirs = await recentDirectoriesStore.readAll();
    final controller = recentDirectories;
    var dirsChanged = false;
    for (final MapEntry(:key, :value) in dirs.entries.toList()) {
      final to = renamedId(key);
      if (to == null) continue;
      final list = value is List
          ? value.whereType<String>().toList()
          : <String>[];
      if (controller != null) {
        await controller.replace(to, list);
        await controller.replace(key, const []);
      } else {
        dirs
          ..remove(key)
          ..[to] = list;
        dirsChanged = true;
      }
    }
    if (dirsChanged) await recentDirectoriesStore.writeAll(dirs);
    final followed = theme.omarchySyncHostId;
    final followTo = followed == null ? null : renamed[followed];
    if (followTo != null) await theme.setOmarchySyncHost(followTo);
  }

  Future<void> _applyConnections(
    Map<String, Object?> values,
    Set<String> changedKeys,
  ) async {
    final connectKeys = changedKeys
        .where((key) => key.startsWith('${SyncKeys.connectPrefix}:'))
        .toList();
    if (connectKeys.isNotEmpty) {
      final all = await connectPreferences.readAll();
      for (final key in connectKeys) {
        final hostId = SyncKeys.idOf(key, SyncKeys.connectPrefix);
        final value = values[key];
        if (value == null) {
          all.remove(hostId);
        } else {
          all[hostId] = value;
        }
      }
      await connectPreferences.writeAll(all);
    }
    final dirKeys = changedKeys
        .where((key) => key.startsWith('${SyncKeys.recentDirsPrefix}:'))
        .toList();
    if (dirKeys.isEmpty) return;
    final all = await recentDirectoriesStore.readAll();
    for (final key in dirKeys) {
      final hostId = SyncKeys.idOf(key, SyncKeys.recentDirsPrefix);
      final raw = values[key];
      final list = raw is List ? raw.whereType<String>().toList() : <String>[];
      final controller = recentDirectories;
      if (controller != null) {
        await controller.replace(hostId, list);
      } else if (list.isEmpty) {
        all.remove(hostId);
      } else {
        all[hostId] = list;
      }
    }
    if (recentDirectories == null) await recentDirectoriesStore.writeAll(all);
  }
}
