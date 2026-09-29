import 'dart:async';

import 'package:conduit/core/app_failure.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/hosts/domain/saved_hosts_repository.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:conduit/features/this_computer/domain/local_shell_launch.dart';
import 'package:conduit/features/this_computer/domain/this_computer_settings.dart';
import 'package:flutter/foundation.dart';

/// [hosts] without the session hosts that were saved as machines: a
/// copy of another saved machine with that machine's id and name plus a
/// session's (`<id>#herdr:w1`, `<name>: <workspace>`) and the same
/// address, port and user. Earlier builds saved one when a Herdr workspace
/// was opened from an agent (CON-056). Anything else stays, even a close
/// copy the user made.
List<SavedHost> withoutSessionCopies(List<SavedHost> hosts) {
  bool isSessionCopy(SavedHost host) => hosts.any(
    (machine) =>
        machine.id != host.id &&
        host.id.startsWith('${machine.id}${ConnectTarget.idSeparator}') &&
        host.name.startsWith('${machine.name}: ') &&
        host.host == machine.host &&
        host.port == machine.port &&
        host.username == machine.username,
  );
  if (!hosts.any(isSessionCopy)) return hosts;
  return [
    for (final host in hosts)
      if (!isSessionCopy(host)) host,
  ];
}

class HostsController extends ChangeNotifier {
  /// With [thisComputerStore] (desktops), "This computer" is a machine
  /// too: listed first by [machines] and [sortedMachines], found by
  /// [findById], and its settings go to that store instead of the saved
  /// list, so they are never backed up or synced.
  ///
  /// A saved machine that is this device ([selfMachine], usually one
  /// synced from a phone) is folded into "This computer" on that device:
  /// see [hiddenSelfMachine].
  HostsController(this._repository, {ThisComputerStore? thisComputerStore})
    : _thisComputerStore = thisComputerStore,
      _thisComputer = thisComputerStore == null
          ? null
          : ThisComputerSettings(host: SavedHost.thisComputer());

  final SavedHostsRepository _repository;
  final ThisComputerStore? _thisComputerStore;
  ThisComputerSettings? _thisComputer;

  List<SavedHost> _hosts = const [];
  String? _selfMachineId;
  List<SavedHost>? _sortedHostsCache;
  HostListSortMode _sortMode = HostListSortMode.lastConnected;
  List<String> _manualOrder = const [];
  bool _isLoading = true;
  String? _errorMessage;
  final Completer<void> _firstLoad = Completer<void>();

  /// Completes once the first [load] has finished (successfully or not),
  /// for work that must see the saved hosts right after app start.
  Future<void> get firstLoad => _firstLoad.future;

  /// The saved machines (what backups and sync carry), all of them: a
  /// hidden [hiddenSelfMachine] included.
  List<SavedHost> get hosts => _hosts;

  /// The saved machines in the machine list's order, as lists show them:
  /// without [hiddenSelfMachine].
  List<SavedHost> get sortedHosts =>
      _sortedHostsCache ??= _computeSortedHosts();

  /// "This computer" on a desktop, else null. While [hiddenSelfMachine]
  /// is folded into it, it carries that machine's name ("This computer ·
  /// omarchy") and its preferences where it has none of its own.
  SavedHost? get thisComputer {
    final settings = _thisComputer;
    if (settings == null) return null;
    final self = hiddenSelfMachine;
    return self == null ? settings.host : settings.hostFoldedWith(self);
  }

  /// The saved machine that is this device (found by the desktop's
  /// `SelfMachineWatcher`), or null. Always null on phones.
  SavedHost? get selfMachine {
    final id = _selfMachineId;
    if (id == null || _thisComputer == null) return null;
    return _hosts.where((host) => host.id == id).firstOrNull;
  }

  /// [selfMachine] unless the user shows it separately: left out of every
  /// machine list on this device, and anything that targets it opens "This
  /// computer" instead ([findById]). It stays in [hosts], so backups and
  /// sync carry it unchanged to the other devices.
  SavedHost? get hiddenSelfMachine =>
      _thisComputer?.showSelfSeparately ?? true ? null : selfMachine;

  /// Whether a synced machine that is this device stays listed as a
  /// machine of its own (SSH to itself). Kept on this device only.
  bool get showSelfSeparately => _thisComputer?.showSelfSeparately ?? false;

  /// Completes once the saved machines were matched against this device
  /// (at most [timeout] after the first load), so a restore or deep link
  /// right after start resolves a machine that is this device to "This
  /// computer". Completes at once on phones.
  Future<void> selfMachineKnown({
    Duration timeout = const Duration(seconds: 4),
  }) async {
    await firstLoad;
    if (_thisComputer == null || _selfMachineKnown.isCompleted) return;
    await _selfMachineKnown.future.timeout(timeout, onTimeout: () {});
  }

  final Completer<void> _selfMachineKnown = Completer<void>();

  /// Records which saved machine is this device (null: none). Ignored
  /// without "This computer" (phones).
  void setSelfMachineId(String? id) {
    if (!_selfMachineKnown.isCompleted) _selfMachineKnown.complete();
    if (_thisComputer == null || id == _selfMachineId) return;
    _selfMachineId = id;
    _sortedHostsCache = null;
    notifyListeners();
  }

  Future<void> setShowSelfSeparately(bool value) async {
    final current = _thisComputer;
    if (current == null || current.showSelfSeparately == value) return;
    _sortedHostsCache = null;
    await _saveThisComputer(current.copyWith(showSelfSeparately: value));
  }

  /// Where "This computer" reads per-host preferences it has none of its
  /// own for, while [hiddenSelfMachine] is folded into it: [hostId] (the
  /// machine or a session on it, `this-computer#tmux:work`) on that saved
  /// machine instead. Null for other machines. Lookups only: nothing is
  /// written under the returned id.
  String? fallbackHostIdFor(String hostId) {
    final self = hiddenSelfMachine?.id;
    if (self == null) return null;
    if (hostId == thisComputerHostId) return self;
    if (hostId.startsWith('$thisComputerHostId#')) {
      return '$self${hostId.substring(thisComputerHostId.length)}';
    }
    return null;
  }

  /// The shell "This computer" opens on Windows.
  WindowsShellKind get windowsShell =>
      _thisComputer?.windowsShell ?? WindowsShellKind.powershell;

  /// Every machine a session can open on: "This computer" first, then the
  /// saved ones (without [hiddenSelfMachine]).
  List<SavedHost> get machines {
    final hidden = hiddenSelfMachine?.id;
    return [
      ?thisComputer,
      for (final host in _hosts)
        if (host.id != hidden) host,
    ];
  }

  /// [machines] in the machine list's order ("This computer" stays first).
  List<SavedHost> get sortedMachines => [?thisComputer, ...sortedHosts];

  /// The machine with [id] (a saved one or "This computer"), or null.
  /// The id of [hiddenSelfMachine] finds "This computer": a deep link,
  /// restored session or pin for it opens this device locally.
  SavedHost? findById(String id) {
    final local = thisComputer;
    if (local != null && (id == local.id || id == hiddenSelfMachine?.id)) {
      return local;
    }
    return _hosts.where((host) => host.id == id).firstOrNull;
  }

  Future<void> setWindowsShell(WindowsShellKind shell) async {
    final current = _thisComputer;
    if (current == null || current.windowsShell == shell) return;
    await _saveThisComputer(current.copyWith(windowsShell: shell));
  }

  Future<void> _saveThisComputer(ThisComputerSettings settings) async {
    _thisComputer = settings;
    notifyListeners();
    try {
      await _thisComputerStore?.save(settings);
    } catch (error) {
      _errorMessage = error.toString();
      notifyListeners();
    }
  }

  HostListSortMode get sortMode => _sortMode;
  List<String> get manualOrder => List.unmodifiable(_manualOrder);

  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;

  Future<void> load() async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    // Asked for together: the list, its order and This computer are
    // independent reads, and the home page waits for all of them.
    final thisComputerStore = _thisComputerStore;
    final thisComputer = thisComputerStore?.load()?..ignore();
    final loadedHosts = _repository.loadHosts()..ignore();
    final sortMode = _repository.loadSortMode()..ignore();
    final manualOrder = _repository.loadManualOrder()..ignore();
    if (thisComputer != null) {
      try {
        _thisComputer = await thisComputer;
      } catch (_) {
        // Defaults stay: the machine itself always works.
      }
    }
    try {
      final loaded = (await loadedHosts)
          .where((host) => !host.isThisComputer)
          .toList(growable: false);
      final hosts = withoutSessionCopies(loaded);
      _sortMode = await sortMode;
      _manualOrder = await manualOrder;
      if (hosts.length != loaded.length) {
        // Cleans up after CON-056 (opening a Herdr workspace saved the
        // session's host as a machine).
        _manualOrder = [
          for (final id in _manualOrder)
            if (hosts.any((host) => host.id == id)) id,
        ];
        await _repository.saveHosts(hosts);
        await _repository.saveManualOrder(_manualOrder);
      }
      _setHosts(hosts);
    } on AppFailure catch (failure) {
      _errorMessage = failure.toString();
    } catch (error) {
      _errorMessage = error.toString();
    } finally {
      _isLoading = false;
      if (!_firstLoad.isCompleted) {
        _firstLoad.complete();
      }
      notifyListeners();
    }
  }

  Future<void> setSortMode(HostListSortMode mode) async {
    if (mode == _sortMode) return;

    final seedManualOrder =
        mode == HostListSortMode.manual && _manualOrder.isEmpty;
    if (seedManualOrder) {
      _manualOrder = _withHiddenSelf(
        sortedHosts.map((host) => host.id).toList(),
      );
    }

    _sortMode = mode;
    _sortedHostsCache = null;
    notifyListeners();

    try {
      await _repository.saveSortMode(mode);
      if (seedManualOrder) {
        await _repository.saveManualOrder(_manualOrder);
      }
    } on AppFailure catch (failure) {
      _errorMessage = failure.toString();
      notifyListeners();
    } catch (error) {
      _errorMessage = error.toString();
      notifyListeners();
    }
  }

  Future<void> reorderManual(int oldIndex, int newIndex) async {
    final ordered = [...sortedHosts];
    if (oldIndex < 0 || oldIndex >= ordered.length) return;
    newIndex = newIndex.clamp(0, ordered.length - 1);
    if (oldIndex == newIndex) return;

    final moved = ordered.removeAt(oldIndex);
    ordered.insert(newIndex, moved);
    _manualOrder = _withHiddenSelf(ordered.map((host) => host.id).toList());
    _sortMode = HostListSortMode.manual;
    _sortedHostsCache = null;
    notifyListeners();

    try {
      await _repository.saveManualOrder(_manualOrder);
    } on AppFailure catch (failure) {
      _errorMessage = failure.toString();
      notifyListeners();
    } catch (error) {
      _errorMessage = error.toString();
      notifyListeners();
    }
  }

  Future<void> upsert(SavedHost host) async {
    if (host.isThisComputer) {
      final current = _thisComputer;
      final shown = thisComputer;
      if (current == null || shown == null) return;
      await _saveThisComputer(current.withEdit(host, shown: shown));
      return;
    }
    final index = _hosts.indexWhere((currentHost) => currentHost.id == host.id);
    final updatedHosts = [..._hosts];

    if (index == -1) {
      updatedHosts.add(host);
    } else {
      updatedHosts[index] = host;
    }

    await _save(updatedHosts);
  }

  Future<void> mergeImported({
    required List<SavedHost> hosts,
    required HostListSortMode sortMode,
    required List<String> manualOrder,
  }) async {
    final mergedById = {for (final host in _hosts) host.id: host};
    for (final host in hosts) {
      if (host.id.isNotEmpty && !host.isThisComputer) {
        mergedById[host.id] = host;
      }
    }

    _errorMessage = null;
    notifyListeners();

    try {
      final mergedHosts = mergedById.values.toList(growable: false);
      final importedIds = hosts.map((host) => host.id).toSet();
      final currentManualOrder = _manualOrder.where(mergedById.containsKey);
      final mergedManualOrder = <String>[
        ...manualOrder.where(mergedById.containsKey),
        ...currentManualOrder.where((id) => !importedIds.contains(id)),
        ...mergedById.keys.where(
          (id) => !manualOrder.contains(id) && !_manualOrder.contains(id),
        ),
      ];
      await _repository.saveHosts(mergedHosts);
      await _repository.saveSortMode(sortMode);
      await _repository.saveManualOrder(mergedManualOrder);
      _sortMode = sortMode;
      _manualOrder = mergedManualOrder;
      _setHosts(mergedHosts);
    } on AppFailure catch (failure) {
      _errorMessage = failure.toString();
    } catch (error) {
      _errorMessage = error.toString();
    } finally {
      notifyListeners();
    }
  }

  /// Replaces the saved machines with [hosts] (device sync). Unlike
  /// [mergeImported], machines missing from [hosts] are removed. The sort
  /// mode and manual order change only when given.
  Future<void> replaceAll(
    List<SavedHost> hosts, {
    HostListSortMode? sortMode,
    List<String>? manualOrder,
  }) async {
    _errorMessage = null;
    hosts = withoutSessionCopies(
      hosts.where((host) => !host.isThisComputer).toList(),
    );
    try {
      await _repository.saveHosts(hosts);
      if (sortMode != null && sortMode != _sortMode) {
        await _repository.saveSortMode(sortMode);
        _sortMode = sortMode;
      }
      if (manualOrder != null) {
        await _repository.saveManualOrder(manualOrder);
        _manualOrder = List.of(manualOrder);
      }
      _setHosts(List.unmodifiable(hosts));
    } on AppFailure catch (failure) {
      _errorMessage = failure.toString();
    } catch (error) {
      _errorMessage = error.toString();
    } finally {
      notifyListeners();
    }
  }

  Future<void> remove(SavedHost host) async {
    if (host.isThisComputer) return;
    await _save(
      _hosts.where((currentHost) => currentHost.id != host.id).toList(),
    );
  }

  Future<void> markConnected(SavedHost host) async {
    if (host.isThisComputer) {
      final local = thisComputer;
      if (local == null) return;
      await upsert(local.copyWith(lastConnectedAt: DateTime.now()));
      return;
    }
    // A session's host (`<machine id>#herdr:w1`, as the agent monitors
    // and the dashboard hand them out) stamps its machine; it is never
    // saved as a machine of its own.
    final machineId = baseHostId(host.id);
    SavedHost? saved(String id) =>
        _hosts.where((currentHost) => currentHost.id == id).firstOrNull;
    final current =
        saved(host.id) ??
        saved(machineId) ??
        (machineId == host.id ? host : null);
    if (current == null) return;
    await upsert(current.copyWith(lastConnectedAt: DateTime.now()));
  }

  Future<void> _save(List<SavedHost> hosts) async {
    _errorMessage = null;
    notifyListeners();

    try {
      await _repository.saveHosts(hosts);
      _setHosts(hosts);
    } on AppFailure catch (failure) {
      _errorMessage = failure.toString();
    } catch (error) {
      _errorMessage = error.toString();
    } finally {
      notifyListeners();
    }
  }

  /// [visibleOrder] (a manual order of the listed machines) with the
  /// hidden [hiddenSelfMachine] kept where it was: the order syncs, and
  /// the other devices list that machine.
  List<String> _withHiddenSelf(List<String> visibleOrder) {
    final hidden = hiddenSelfMachine?.id;
    if (hidden == null || visibleOrder.contains(hidden)) return visibleOrder;
    final previous = _manualOrder.indexOf(hidden);
    final at = previous < 0 ? visibleOrder.length : previous;
    return [...visibleOrder]..insert(at.clamp(0, visibleOrder.length), hidden);
  }

  void _setHosts(List<SavedHost> hosts) {
    _hosts = hosts;
    _sortedHostsCache = null;
  }

  List<SavedHost> _computeSortedHosts() {
    final hidden = hiddenSelfMachine?.id;
    final hosts = hidden == null
        ? _hosts
        : [
            for (final host in _hosts)
              if (host.id != hidden) host,
          ];
    final sorted = [...hosts];
    switch (_sortMode) {
      case HostListSortMode.lastConnected:
        sorted.sort(_compareLastConnected);
      case HostListSortMode.name:
        sorted.sort(_compareName);
      case HostListSortMode.added:
        break;
      case HostListSortMode.manual:
        return _computeManualOrder(hosts);
    }
    return List.unmodifiable(sorted);
  }

  List<SavedHost> _computeManualOrder(List<SavedHost> hosts) {
    final byId = {for (final host in hosts) host.id: host};
    final ordered = <SavedHost>[];
    final seen = <String>{};
    for (final id in _manualOrder) {
      final host = byId[id];
      if (host != null && seen.add(id)) {
        ordered.add(host);
      }
    }
    for (final host in hosts) {
      if (seen.add(host.id)) {
        ordered.add(host);
      }
    }
    return List.unmodifiable(ordered);
  }

  int _compareLastConnected(SavedHost a, SavedHost b) {
    final aDate = a.lastConnectedAt;
    final bDate = b.lastConnectedAt;
    if (aDate == null && bDate == null) {
      return _compareName(a, b);
    }
    if (aDate == null) {
      return 1;
    }
    if (bDate == null) {
      return -1;
    }
    final byDate = bDate.compareTo(aDate);
    return byDate == 0 ? _compareName(a, b) : byDate;
  }

  int _compareName(SavedHost a, SavedHost b) {
    final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    if (byName != 0) return byName;
    final byHost = a.host.toLowerCase().compareTo(b.host.toLowerCase());
    if (byHost != 0) return byHost;
    return a.id.compareTo(b.id);
  }
}
