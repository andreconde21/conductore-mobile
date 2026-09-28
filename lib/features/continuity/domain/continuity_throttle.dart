import 'dart:async';

/// Runs [onFire] at most once per [interval] while changes keep coming,
/// and at the latest [interval] after the first change since the last
/// run; [flush] runs it at once (the app is leaving the screen).
///
/// The first change after a quiet spell waits [settle] rather than the
/// whole interval, so a burst (typing, scrolling) goes out as one.
class ContinuityThrottle {
  ContinuityThrottle({
    required this.onFire,
    this.interval = const Duration(seconds: 10),
    this.settle = const Duration(seconds: 2),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final void Function() onFire;
  final Duration interval;
  final Duration settle;
  final DateTime Function() _now;

  Timer? _timer;
  DateTime? _lastFire;
  bool _dirty = false;

  /// Whether a change waits to go out.
  bool get pending => _dirty;

  /// Something changed.
  void poke() {
    _dirty = true;
    if (_timer != null) return;
    final last = _lastFire;
    var wait = settle;
    if (last != null) {
      final gap = interval - _now().difference(last);
      if (gap > wait) wait = gap;
    }
    _timer = Timer(wait, _fire);
  }

  /// Runs now when a change waits.
  void flush() {
    _timer?.cancel();
    _timer = null;
    if (_dirty) _fire();
  }

  void _fire() {
    _timer = null;
    if (!_dirty) return;
    _dirty = false;
    _lastFire = _now();
    onFire();
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}
