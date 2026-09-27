import 'dart:async';

import 'package:conduit/core/app_failure.dart';
import 'package:conduit/core/theme/omarchy_theme_sync.dart';
import 'package:conduit/core/theme/theme_controller.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:flutter/widgets.dart';

enum OmarchySyncState {
  /// Not following a machine, or not synced yet.
  idle,
  syncing,
  synced,

  /// The machine signs in with a security key: syncing needs a tap.
  needsTap,
  failed,
}

/// Follows the Omarchy theme (and font) of one saved machine.
///
/// Reads it with [omarchyThemeProbeCommand] over a fresh non-interactive
/// SSH exec connection (the agent command runner, never the terminal PTY),
/// on app start and whenever the app resumes, at most once per
/// [minInterval]. The last result is cached by [ThemeController], so the
/// app opens in the synced theme and a sync never blocks the UI. Machines
/// that sign in with a security key only sync on an explicit tap.
class OmarchyThemeSyncController extends ChangeNotifier
    with WidgetsBindingObserver {
  OmarchyThemeSyncController({
    required this._theme,
    required this._hosts,
    required this._runnerFactory,
    this._findHost,
    this._clock = DateTime.now,
    this.minInterval = const Duration(seconds: 60),
    this.timeout = const Duration(seconds: 12),
  });

  final ThemeController _theme;
  final Future<List<SavedHost>> Function() _hosts;
  final AgentCommandRunner Function(SavedHost host) _runnerFactory;

  /// Finds the followed machine by id; defaults to a lookup in [_hosts].
  /// On a desktop it also finds the synced machine that is this device,
  /// which is folded into "This computer" and not listed.
  final Future<SavedHost?> Function(String id)? _findHost;
  final DateTime Function() _clock;
  final Duration minInterval;
  final Duration timeout;

  OmarchySyncState _state = OmarchySyncState.idle;
  String _message = '';
  Future<void>? _inFlight;
  String? _inFlightHostId;
  DateTime? _lastAttempt;
  bool _started = false;
  bool _disposed = false;

  OmarchySyncState get state => _state;

  /// A one-line status for the settings (error text, or what was synced).
  String get message => _message;

  ThemeController get theme => _theme;

  /// Saved machines the theme can follow (the local shell is not one).
  Future<List<SavedHost>> machines() async =>
      (await _hosts()).where((host) => !host.isLocal).toList();

  /// Syncs now and on every resume. Call once, after the theme loaded.
  void start() {
    if (_started) {
      return;
    }
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    unawaited(refresh());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(refresh());
    }
  }

  /// Follows [hostId] (null stops following) and syncs right away. Picking
  /// the machine is an explicit tap, so security-key machines sync too.
  Future<void> follow(String? hostId) async {
    await _theme.setOmarchySyncHost(hostId);
    _lastAttempt = null;
    _set(OmarchySyncState.idle, '');
    if (hostId != null) {
      await refresh(explicit: true);
    }
  }

  /// Reads the followed machine's theme. Automatic calls are throttled to
  /// [minInterval] and skip security-key machines; [explicit] (a tap on
  /// "Sync now") always runs. Concurrent calls for the same machine share
  /// one run.
  Future<void> refresh({bool explicit = false}) {
    final hostId = _theme.omarchySyncHostId;
    if (hostId == null) {
      return Future.value();
    }
    final running = _inFlight;
    if (running != null) {
      if (_inFlightHostId == hostId) return running;
      // Another machine is still being read (its result is dropped):
      // read this one after it.
      return running.then((_) => refresh(explicit: explicit));
    }
    final last = _lastAttempt;
    if (!explicit && last != null && _clock().difference(last) < minInterval) {
      return Future.value();
    }
    final future = _sync(hostId, explicit: explicit).whenComplete(() {
      _inFlight = null;
      _inFlightHostId = null;
    });
    _inFlight = future;
    _inFlightHostId = hostId;
    return future;
  }

  Future<void> _sync(String hostId, {required bool explicit}) async {
    _lastAttempt = _clock();
    final findHost = _findHost;
    final host = findHost != null
        ? await findHost(hostId)
        : (await _hosts()).where((h) => h.id == hostId).firstOrNull;
    if (host == null) {
      _set(OmarchySyncState.failed, 'That machine is no longer saved.');
      return;
    }
    if (!explicit && host.authMethod == SshAuthMethod.hardwareKey) {
      _set(
        OmarchySyncState.needsTap,
        '${host.name} signs in with a security key. Tap Sync now.',
      );
      return;
    }
    _set(OmarchySyncState.syncing, 'Reading the theme on ${host.name}...');
    final runner = _runnerFactory(host);
    try {
      final result = await runner.run(
        omarchyThemeProbeCommand,
        timeout: timeout,
      );
      final probe = parseOmarchyProbe(result.stdout);
      if (probe == null) {
        _set(OmarchySyncState.failed, '${host.name} sent an incomplete reply.');
        return;
      }
      if (!probe.hasOmarchy) {
        _set(
          OmarchySyncState.failed,
          'No Omarchy theme found on ${host.name}.',
        );
        return;
      }
      final palette = paletteForOmarchyProbe(probe);
      if (palette == null) {
        _set(
          OmarchySyncState.failed,
          'Could not read the colours of "${probe.themeName}".',
        );
        return;
      }
      if (_theme.omarchySyncHostId != hostId) {
        return;
      }
      final synced = OmarchySyncedTheme(
        hostId: hostId,
        palette: palette,
        syncedAt: _clock(),
        fontFamily: probe.fontFamily,
      );
      await _theme.applyOmarchySync(synced);
      final font = probe.fontFamily.isEmpty
          ? ''
          : synced.font == null
          ? ' (font ${probe.fontFamily} is not bundled)'
          : ', ${probe.fontFamily}';
      _set(OmarchySyncState.synced, '${palette.label}$font');
    } on AppFailure catch (failure) {
      _set(OmarchySyncState.failed, failure.message);
    } catch (error) {
      _set(OmarchySyncState.failed, 'Sync failed: $error');
    } finally {
      unawaited(runner.close());
    }
  }

  void _set(OmarchySyncState state, String message) {
    if (_disposed || (_state == state && _message == message)) {
      return;
    }
    _state = state;
    _message = message;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    if (_started) {
      WidgetsBinding.instance.removeObserver(this);
    }
    super.dispose();
  }
}
