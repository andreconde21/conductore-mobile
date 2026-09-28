// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:conduit/features/continuity/domain/continuity_preferences.dart';
import 'package:conduit/features/continuity/domain/continuity_record.dart';
import 'package:conduit/features/continuity/domain/continuity_rules.dart';
import 'package:conduit/features/continuity/domain/continuity_state.dart';
import 'package:conduit/features/continuity/domain/continuity_sync_port.dart';
import 'package:conduit/features/continuity/domain/continuity_throttle.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/sync/domain/sync_category.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// What continuity needs from device sync: who this device is, whether
/// "Continue where you left off" is on, and a way to push and pull.
abstract interface class ContinuitySyncLink implements Listenable {
  /// This device's sync id; null while sync is off.
  String? get deviceId;
  String get deviceName;

  /// Whether the continuity category syncs.
  bool get sharing;

  /// When this device last synced.
  DateTime? get lastSyncAt;

  /// Sends this device's record now.
  void push();

  /// Reads what the other devices sent.
  void pull();
}

/// Continuity between devices (CON-008): where this device is, what the
/// others are doing, and the offers to pick up there.
///
/// This device's record ([ownRecord]) holds its place (machine, target,
/// view, Claude session), the Chat View scroll anchor, its recent places,
/// its unsent Chat View drafts and when it was last in use. It goes out
/// through device sync, end-to-end encrypted, at most every
/// [publishInterval] while it changes and at once when the app leaves the
/// screen. The other devices' records come back through [receive].
///
/// When this device wakes (opened, resumed, or used again after
/// [idleGap]), [offer] names another device that was in use since, within
/// [window], somewhere else.
class ContinuityController extends ChangeNotifier
    with WidgetsBindingObserver
    implements ContinuitySyncPort {
  ContinuityController({
    required ContinuityStore store,
    required ContinuitySyncLink sync,
    required SavedHost? Function(String? machineId) machineFor,
    String? Function()? selfMachineId,
    this.platform = '',
    this.desktop = false,
    DateTime Function()? now,
    this.window = const Duration(hours: 2),
    this.idleGap = const Duration(minutes: 5),
    this.activityStep = const Duration(minutes: 2),
    this.draftLifetime = const Duration(days: 7),
    Duration publishInterval = const Duration(seconds: 10),
    this.observeLifecycle = true,
  }) : _store = store,
       _sync = sync,
       _machineFor = machineFor,
       _selfMachineId = selfMachineId ?? _none,
       _now = now ?? DateTime.now {
    _throttle = ContinuityThrottle(
      onFire: _publish,
      interval: publishInterval,
      now: _now,
    );
  }

  static String? _none() => null;

  final ContinuityStore _store;
  final ContinuitySyncLink _sync;
  final SavedHost? Function(String? machineId) _machineFor;
  final String? Function() _selfMachineId;
  final DateTime Function() _now;

  /// Shown to the other devices (android, linux…).
  final String platform;

  /// A desktop build: it wakes on input after [idleGap] and on focus.
  final bool desktop;

  /// How recent another device's use must be to be offered.
  final Duration window;

  /// Input after this long without any wakes a desktop.
  final Duration idleGap;

  /// How often continued use refreshes this device's "in use" time.
  final Duration activityStep;

  /// How long another device's draft is offered.
  final Duration draftLifetime;
  final bool observeLifecycle;

  /// A cleared draft is remembered this long, so older copies elsewhere
  /// are not offered as new.
  static const clearedDraftLifetime = Duration(days: 2);

  late final ContinuityThrottle _throttle;
  ContinuityState _state = const ContinuityState();
  final Completer<void> _loaded = Completer<void>();
  bool _started = false;
  bool _disposed = false;
  Timer? _saveTimer;

  /// Where this device is now (null: home, or nothing reported).
  ContinuityPlace? _here;

  /// This device's last use before it woke: offers must be newer.
  DateTime? _baseline;
  DateTime? _lastInput;
  AppLifecycleState? _lifecycle;

  /// A context opened from an offer, until its Chat View takes the
  /// anchor.
  ContinuityContext? _arrival;

  /// Set while turning continuity off: the record goes out empty once.
  bool _retracted = false;
  bool _wasSharing = false;

  /// Places reported by the desktop shell: the route tracker leaves the
  /// home route alone then.
  bool desktopShell = false;

  Future<void> get loaded => _loaded.future;

  /// Whether continuity runs: sync on and the category shared.
  bool get active =>
      _loaded.isCompleted && _sync.deviceId != null && _sync.sharing;

  ContinuityPreferences get preferences => _state.preferences;

  /// Where this device is (or was last), as the other devices see it.
  ContinuityContext? get context => _state.context;

  List<ContinuityContext> get recent => _state.recent;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    try {
      _state = await _store.load();
    } finally {
      if (!_loaded.isCompleted) _loaded.complete();
    }
    _wasSharing = _sync.sharing;
    _sync.addListener(_onSyncChanged);
    if (observeLifecycle) {
      WidgetsBinding.instance.addObserver(this);
      HardwareKeyboard.instance.addHandler(_onKey);
    }
    _wake(pull: false);
  }

  void _onSyncChanged() {
    final sharing = _sync.sharing;
    if (sharing && !_wasSharing) _retracted = false;
    _wasSharing = sharing;
    _notify();
  }

  // Other devices.

  List<DeviceContinuity>? _devices;
  Map<String, Object?>? _devicesFrom;

  /// The other devices' records, most recently used first.
  List<DeviceContinuity> get devices {
    final remote = _state.remote;
    if (identical(remote, _devicesFrom) && _devices != null) return _devices!;
    final own = _sync.deviceId;
    final devices = <DeviceContinuity>[
      for (final MapEntry(:key, :value) in remote.entries)
        if (key.startsWith('${SyncKeys.continuityPrefix}:'))
          if (DeviceContinuity.fromJson(
                SyncKeys.idOf(key, SyncKeys.continuityPrefix),
                value,
              )
              case final device? when device.deviceId != own)
            device,
    ];
    final epoch = DateTime.fromMillisecondsSinceEpoch(0);
    devices.sort(
      (a, b) => (b.activeAt ?? epoch).compareTo(a.activeAt ?? epoch),
    );
    _devicesFrom = remote;
    return _devices = devices;
  }

  /// The other devices with a place to continue from (the "Continue
  /// on…" list): those used within [draftLifetime].
  List<DeviceContinuity> get continuable {
    if (!active || !preferences.sessions) return const [];
    final now = _now();
    return [
      for (final device in devices)
        if (device.context != null &&
            device.activeAt != null &&
            now.difference(device.activeAt!) <= draftLifetime)
          device,
    ];
  }

  /// The machine [place] opens on here, or null when it is not saved on
  /// this device.
  SavedHost? machineFor(ContinuityPlace place) => _machineFor(place.machineId);

  // The offer.

  /// Another device's place to offer on this device now, or null.
  ContinuityOffer? get offer {
    if (!active || !preferences.sessions) return null;
    return pickContinuityOffer(
      others: devices,
      now: _now(),
      lastActiveHere: _baseline,
      here: _here ?? _state.context?.place,
      dismissed: _state.dismissed.toSet(),
      canOpen: (place) => machineFor(place) != null,
      window: window,
    );
  }

  /// Hides [offer] for good; the device's next place is offered again.
  void dismiss(ContinuityOffer offer) {
    if (_state.dismissed.contains(offer.key)) return;
    _update(
      _copy(
        dismissed: _bounded([
          ..._state.dismissed,
          offer.key,
        ], ContinuityState.maxDismissed),
      ),
    );
  }

  /// [offer] was taken: it is not offered again, and its Chat View
  /// scrolls to where the other device was.
  void accept(ContinuityOffer offer) {
    dismiss(offer);
    expectArrival(offer.context);
  }

  /// [context] is being opened here: its Chat View takes the anchor.
  void expectArrival(ContinuityContext context) {
    _arrival = context;
  }

  /// The Chat View anchor to scroll to, once, when [agentId]'s chat opens
  /// from another device's place.
  String? takeArrivalAnchor(String agentId) {
    final arrival = _arrival;
    if (arrival == null || arrival.place.agentId != agentId) return null;
    _arrival = null;
    return preferences.scroll ? arrival.anchor : null;
  }

  // This device's place.

  /// This device shows [place] now. Its machine is this device's id for
  /// it (a session's saved machine, or "This computer"); the other
  /// devices get the id they know it by ([sharedMachineId]).
  void reportPlace(ContinuityPlace place, {String layout = ''}) {
    final shared = _shared(place);
    _here = shared;
    final current = _state.context;
    final now = _now();
    if (current != null && current.place.samePlace(shared)) {
      if (current.place == shared && current.layout == layout) return;
      _update(
        _copy(
          context: ContinuityContext(
            place: shared,
            at: current.at,
            anchor: current.anchor,
            layout: layout,
          ),
        ),
        publish: true,
      );
      return;
    }
    _update(
      _copy(
        activeAt: now,
        context: ContinuityContext(place: shared, at: now, layout: layout),
        recent: [
          ?current,
          for (final old in _state.recent)
            if (!old.place.samePlace(shared) &&
                (current == null || !old.place.samePlace(current.place)))
              old,
        ].take(DeviceContinuity.maxRecent).toList(),
      ),
      publish: true,
    );
  }

  /// This device left its place (home, settings): the place stays what
  /// the others continue from.
  void reportAway() {
    if (_here == null) return;
    _here = null;
    _notify();
  }

  /// The desktop's layout changed name (a saved layout, a preset).
  void reportLayout(String layout) {
    final current = _state.context;
    if (current == null || current.layout == layout) return;
    _update(_copy(context: current.copyWith(layout: layout)), publish: true);
  }

  ContinuityPlace _shared(ContinuityPlace place) {
    final machine = place.machineId;
    if (machine == null) return place;
    final shared = sharedMachineId(machine, selfMachineId: _selfMachineId());
    return ContinuityPlace(
      machineId: shared,
      machineName: place.machineName,
      target: place.target,
      view: place.view,
      agentId: place.agentId,
      agentName: place.agentName,
      paneId: place.paneId,
      title: place.title,
    );
  }

  /// Chat View of [agentId] shows the thread with [itemId] as the newest
  /// item on screen (null: at the bottom).
  void noteAnchor(String agentId, String? itemId) {
    final current = _state.context;
    if (current == null ||
        current.place.view != ContinuityView.chat ||
        current.place.agentId != agentId ||
        current.anchor == itemId) {
      return;
    }
    _update(
      _copy(
        context: itemId == null
            ? current.copyWith(clearAnchor: true)
            : current.copyWith(anchor: itemId),
      ),
      publish: preferences.scroll,
    );
  }

  // Drafts.

  /// This device's own unsent draft for [agentId]'s Chat View.
  String draftFor(String agentId) =>
      preferences.drafts ? _state.drafts[agentId]?.text ?? '' : '';

  /// What [agentId]'s composer should do with the other devices' drafts,
  /// given what it holds now ([localText]).
  DraftResolution resolveDraftFor(String agentId, String localText) {
    if (!active || !preferences.drafts) return const DraftKeep();
    final oldest = _now().subtract(draftLifetime);
    return resolveDraft(
      local: _state.drafts[agentId],
      localText: localText,
      remote: [
        for (final device in devices)
          if (device.drafts[agentId] case final draft?
              when draft.at.isAfter(oldest))
            (device, draft),
      ],
      handled: _state.handledDrafts.toSet(),
    );
  }

  /// The composer of [agentId]'s Chat View holds [text] now.
  void noteDraft(String agentId, String text) {
    if (!preferences.drafts) return;
    final limited = text.length > DeviceContinuity.maxDraftLength
        ? text.substring(0, DeviceContinuity.maxDraftLength)
        : text;
    final existing = _state.drafts[agentId];
    if (existing?.text == limited) return;
    if (existing == null && limited.trim().isEmpty) return;
    _update(
      _copy(
        drafts: _prunedDrafts({
          ..._state.drafts,
          agentId: ContinuityDraft(text: limited, at: _now()),
        }),
      ),
      publish: true,
      save: false,
    );
    _saveSoon();
  }

  /// Another device's draft was taken or turned down here.
  void settleDraft(RemoteDraftResolution resolution) {
    if (_state.handledDrafts.contains(resolution.key)) return;
    _update(
      _copy(
        handledDrafts: _bounded([
          ..._state.handledDrafts,
          resolution.key,
        ], ContinuityState.maxHandled),
      ),
    );
  }

  Map<String, ContinuityDraft> _prunedDrafts(
    Map<String, ContinuityDraft> drafts,
  ) {
    final now = _now();
    final kept =
        drafts.entries
            .where(
              (entry) =>
                  !entry.value.isEmpty ||
                  now.difference(entry.value.at) <= clearedDraftLifetime,
            )
            .toList()
          ..sort((a, b) => b.value.at.compareTo(a.value.at));
    return {
      for (final entry in kept.take(DeviceContinuity.maxDrafts))
        entry.key: entry.value,
    };
  }

  // Preferences.

  Future<void> setPreferences(ContinuityPreferences preferences) async {
    if (preferences == _state.preferences) return;
    final dropDrafts = !preferences.drafts && _state.preferences.drafts;
    _update(
      _copy(
        preferences: preferences,
        // Turned off: the drafts kept for sharing go too.
        drafts: dropDrafts ? const {} : null,
      ),
      publish: true,
    );
    // Shared at once: what was turned off leaves the other devices now.
    _throttle.flush();
  }

  /// Continuity is being turned off: the next record carries no place
  /// and no drafts, so the other devices drop them.
  void retract() {
    _retracted = true;
    _throttle.poke();
    _throttle.flush();
  }

  // Activity and lifecycle.

  /// The user did something (a tap, a key).
  void noteActivity() {
    if (!_loaded.isCompleted) return;
    final now = _now();
    final last = _lastInput;
    _lastInput = now;
    if (desktop && last != null && now.difference(last) >= idleGap) {
      _wake();
      return;
    }
    final activeAt = _state.activeAt;
    if (activeAt == null || now.difference(activeAt) >= activityStep) {
      _update(_copy(activeAt: now), publish: true, save: false);
    }
  }

  bool _onKey(KeyEvent event) {
    if (event is KeyDownEvent) noteActivity();
    return false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final previous = _lifecycle;
    _lifecycle = state;
    switch (state) {
      case AppLifecycleState.resumed:
        // Back from the background, sync pulls by itself; a desktop
        // coming back into focus asks.
        final fromBackground =
            previous == AppLifecycleState.paused ||
            previous == AppLifecycleState.hidden;
        if (previous != null) _wake(pull: !fromBackground);
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        _leave();
      case AppLifecycleState.inactive:
        // A desktop window losing focus: the user may be moving to
        // another device.
        if (desktop) _leave();
      case AppLifecycleState.detached:
        break;
    }
  }

  void _wake({bool pull = true}) {
    if (!_loaded.isCompleted) return;
    final now = _now();
    _baseline = _state.activeAt;
    _lastInput = now;
    _update(_copy(activeAt: now), publish: true, save: false);
    if (pull && active) {
      final last = _sync.lastSyncAt;
      if (last == null || now.difference(last) > const Duration(seconds: 20)) {
        _sync.pull();
      }
    }
  }

  void _leave() {
    if (!_loaded.isCompleted) return;
    _update(_copy(activeAt: _now()), publish: true, save: false);
    _throttle.flush();
  }

  // Sync.

  @override
  Future<Object?> ownRecord(String deviceId) async {
    await loaded;
    final prefs = preferences;
    final retracted = _retracted;
    final context = _state.context;
    return DeviceContinuity(
      deviceId: deviceId,
      deviceName: _sync.deviceName,
      platform: platform,
      desktop: desktop,
      activeAt: _state.activeAt,
      context: retracted || !prefs.sessions || context == null
          ? null
          : prefs.scroll
          ? context
          : context.copyWith(clearAnchor: true),
      recent: retracted || !prefs.sessions ? const [] : _state.recent,
      drafts: retracted || !prefs.drafts
          ? const {}
          : _prunedDrafts(_state.drafts),
    ).toJson();
  }

  @override
  Future<void> receive(
    Map<String, Object?> records, {
    required String deviceId,
  }) async {
    await loaded;
    final remote = {
      for (final MapEntry(:key, :value) in records.entries)
        if (SyncKeys.isForeign(key, deviceId) && value != null) key: value,
    };
    _update(_copy(remote: remote));
  }

  void _publish() {
    _saveNow();
    if (active) _sync.push();
  }

  // State.

  ContinuityState _copy({
    ContinuityPreferences? preferences,
    DateTime? activeAt,
    ContinuityContext? context,
    List<ContinuityContext>? recent,
    Map<String, ContinuityDraft>? drafts,
    Map<String, Object?>? remote,
    List<String>? dismissed,
    List<String>? handledDrafts,
  }) => ContinuityState(
    preferences: preferences ?? _state.preferences,
    activeAt: activeAt ?? _state.activeAt,
    context: context ?? _state.context,
    recent: recent ?? _state.recent,
    drafts: drafts ?? _state.drafts,
    remote: remote ?? _state.remote,
    dismissed: dismissed ?? _state.dismissed,
    handledDrafts: handledDrafts ?? _state.handledDrafts,
  );

  void _update(ContinuityState next, {bool publish = false, bool save = true}) {
    _state = next;
    if (publish) _throttle.poke();
    if (save) _saveSoon();
    _notify();
  }

  static List<String> _bounded(List<String> items, int max) =>
      items.length <= max ? items : items.sublist(items.length - max);

  void _saveSoon() {
    _saveTimer ??= Timer(const Duration(seconds: 2), _saveNow);
  }

  void _saveNow() {
    _saveTimer?.cancel();
    _saveTimer = null;
    if (_loaded.isCompleted) unawaited(_store.save(_state));
  }

  /// Sends what waits and saves now (tests, and the app leaving).
  void flush() {
    _throttle.flush();
    _saveNow();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _throttle.dispose();
    _saveTimer?.cancel();
    if (_started) {
      _sync.removeListener(_onSyncChanged);
      if (observeLifecycle) {
        WidgetsBinding.instance.removeObserver(this);
        HardwareKeyboard.instance.removeHandler(_onKey);
      }
    }
    super.dispose();
  }
}
