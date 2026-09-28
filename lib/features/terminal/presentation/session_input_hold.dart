import 'dart:async';

import 'package:flutter/foundation.dart';

/// Why a session is holding back what is typed into it, for the hint the
/// terminal shows.
@immutable
sealed class InputHoldState {
  const InputHoldState(this.label);

  /// What the session is being pointed at (a Herdr workspace name); empty
  /// when there is nothing better to say.
  final String label;
}

/// Input waits while the session's multiplexer is switched back to it.
class InputHoldSwitching extends InputHoldState {
  const InputHoldSwitching(super.label);
}

/// The switch was not confirmed: [dropped] characters were thrown away
/// rather than typed into whatever the multiplexer shows instead.
class InputHoldFailed extends InputHoldState {
  const InputHoldFailed(super.label, {required this.dropped});

  final int dropped;
}

/// Holds a session's outgoing input while something makes sure it will
/// land in the right place, then delivers it in order, or drops it and
/// says so.
///
/// Herdr keeps one focus per server, shared by every client attached to
/// it, so a session attached to workspace A types into workspace B when
/// another client (another app tab, the laptop) focused B last. The app
/// focuses A again before the session takes input; this is the queue that
/// covers the round trip.
class SessionInputHold {
  SessionInputHold({required this.deliver});

  /// Sends one piece of input for real.
  final void Function(String data) deliver;

  /// The longest input waits for a confirmation before it is dropped.
  static const defaultTimeout = Duration(seconds: 6);

  /// How long the "not sent" hint stays up.
  static const failureNoticeDuration = Duration(seconds: 5);

  final _state = ValueNotifier<InputHoldState?>(null);
  final List<String> _queued = [];
  int _generation = 0;
  Timer? _timeout;
  Timer? _noticeTimer;
  bool _disposed = false;

  ValueListenable<InputHoldState?> get state => _state;

  /// Whether input is being held right now.
  bool get holding => _state.value is InputHoldSwitching;

  /// Everything held so far, oldest first.
  @visibleForTesting
  List<String> get queued => List.unmodifiable(_queued);

  /// Holds input until [ready] completes: true delivers what was held,
  /// false (or [timeout] first) drops it with a visible notice. A newer
  /// hold replaces this one; the queue carries over.
  void hold(
    Future<bool> ready, {
    String label = '',
    Duration timeout = defaultTimeout,
  }) {
    if (_disposed) return;
    final generation = ++_generation;
    _noticeTimer?.cancel();
    _timeout?.cancel();
    _state.value = InputHoldSwitching(label);
    _timeout = Timer(timeout, () => _settle(generation, ok: false));
    unawaited(
      ready.then(
        (ok) => _settle(generation, ok: ok),
        onError: (Object _) => _settle(generation, ok: false),
      ),
    );
  }

  /// Takes [data] when input is held; false when it should go out now.
  bool offer(String data) {
    if (!holding) return false;
    _queued.add(data);
    return true;
  }

  /// Drops the queue without a notice (the connection went away).
  void reset() {
    _generation += 1;
    _timeout?.cancel();
    _queued.clear();
    if (!_disposed) _state.value = null;
  }

  void _settle(int generation, {required bool ok}) {
    if (_disposed || generation != _generation) return;
    _generation += 1;
    _timeout?.cancel();
    final label = _state.value?.label ?? '';
    final queued = List.of(_queued);
    _queued.clear();
    if (ok) {
      _state.value = null;
      for (final data in queued) {
        deliver(data);
      }
      return;
    }
    final dropped = queued.fold<int>(0, (sum, data) => sum + data.length);
    if (dropped == 0) {
      _state.value = null;
      return;
    }
    _state.value = InputHoldFailed(label, dropped: dropped);
    _noticeTimer = Timer(failureNoticeDuration, () {
      if (!_disposed && _state.value is InputHoldFailed) _state.value = null;
    });
  }

  void dispose() {
    _disposed = true;
    _timeout?.cancel();
    _noticeTimer?.cancel();
    _queued.clear();
    _state.dispose();
  }
}
