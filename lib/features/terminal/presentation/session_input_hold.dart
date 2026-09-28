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

/// The multiplexer shows another place ([label]: another screen moved its
/// shared focus there), and this device may not move it back on its own:
/// input waits for the user to decide (see [SessionInputHold.release],
/// [SessionInputHold.discard] and [SessionInputHold.takeText]).
class InputHoldBlocked extends InputHoldState {
  const InputHoldBlocked(super.label, {required this.queued});

  /// Characters waiting.
  final int queued;
}

/// What becomes of held input.
enum InputHoldDecision {
  /// It can go out now.
  send,

  /// It must not: drop it and say so.
  drop,

  /// Keep it until the user decides.
  block,
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
  bool get holding =>
      _state.value is InputHoldSwitching || _state.value is InputHoldBlocked;

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
  }) => decide(
    ready.then((ok) => ok ? InputHoldDecision.send : InputHoldDecision.drop),
    label: label,
    timeout: timeout,
  );

  /// Holds input until [decision] completes. [blockedLabel] names what
  /// the multiplexer shows instead, for [InputHoldDecision.block]; it is
  /// read when the decision arrives. [timeout] drops the input.
  void decide(
    Future<InputHoldDecision> decision, {
    String label = '',
    String Function()? blockedLabel,
    Duration timeout = defaultTimeout,
  }) {
    if (_disposed) return;
    final generation = ++_generation;
    _noticeTimer?.cancel();
    _timeout?.cancel();
    _state.value = InputHoldSwitching(label);
    _timeout = Timer(
      timeout,
      () => _settle(generation, InputHoldDecision.drop),
    );
    unawaited(
      decision.then(
        (value) => _settle(generation, value, blockedLabel?.call() ?? ''),
        onError: (Object _) => _settle(generation, InputHoldDecision.drop),
      ),
    );
  }

  /// Takes [data] when input is held; false when it should go out now.
  bool offer(String data) {
    if (!holding) return false;
    _queued.add(data);
    final state = _state.value;
    if (state is InputHoldBlocked) {
      _state.value = InputHoldBlocked(state.label, queued: _queuedLength);
    }
    return true;
  }

  int get _queuedLength =>
      _queued.fold<int>(0, (sum, data) => sum + data.length);

  /// Sends what is held (the user chose to), and lets input flow again.
  void release() => _finish(send: true);

  /// Drops what is held without a notice (the user chose to).
  void discard() => _finish(send: false);

  /// Hands over the printable text held so far (for the composer) and
  /// drops the rest; input flows again.
  String takeText() {
    final text = _queued
        .join()
        .replaceAll(RegExp(r'\x1b\[[0-9;?]*[ -/]*[@-~]'), '')
        .replaceAll(RegExp(r'[\x00-\x08\x0b-\x1f\x7f]'), '');
    _finish(send: false);
    return text;
  }

  void _finish({required bool send}) {
    if (_disposed) return;
    _generation += 1;
    _timeout?.cancel();
    _noticeTimer?.cancel();
    final queued = List.of(_queued);
    _queued.clear();
    _state.value = null;
    if (send) {
      for (final data in queued) {
        deliver(data);
      }
    }
  }

  /// Drops the queue without a notice (the connection went away).
  void reset() {
    _generation += 1;
    _timeout?.cancel();
    _queued.clear();
    if (!_disposed) _state.value = null;
  }

  void _settle(
    int generation,
    InputHoldDecision decision, [
    String blockedLabel = '',
  ]) {
    if (_disposed || generation != _generation) return;
    _timeout?.cancel();
    if (decision == InputHoldDecision.block) {
      // Waits for the user's choice (or a newer hold); no timeout.
      _generation += 1;
      _state.value = InputHoldBlocked(blockedLabel, queued: _queuedLength);
      return;
    }
    final ok = decision == InputHoldDecision.send;
    _generation += 1;
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
    // Nothing typed yet: nothing lost, and nothing to say.
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
