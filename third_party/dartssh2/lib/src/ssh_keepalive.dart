import 'dart:async';

/// A wrapper around [Timer] that calls [ping] every [interval], and can be
/// started or stopped idempotently.
///
/// A tick is skipped while the previous ping still waits for its reply, so
/// pings never pile up on a half-dead link, and a failed ping is not an
/// unhandled error. [interval] can change while running; null pauses it.
class SSHKeepAlive {
  Timer? _timer;

  Duration? _interval;

  final Future Function() ping;

  bool _started = false;

  bool _inFlight = false;

  SSHKeepAlive({
    required this.ping,
    Duration? interval = const Duration(seconds: 10),
  }) : _interval = interval;

  /// How often [ping] is called; null sends no keep-alive.
  Duration? get interval => _interval;

  set interval(Duration? value) {
    if (value == _interval) return;
    _interval = value;
    _timer?.cancel();
    _timer = null;
    if (_started) _schedule();
  }

  void start() {
    _started = true;
    _schedule();
  }

  void _schedule() {
    final interval = _interval;
    if (interval == null) return;
    _timer ??= Timer.periodic(interval, (timer) => _tick());
  }

  Future<void> _tick() async {
    if (_inFlight) return;
    _inFlight = true;
    try {
      await ping();
    } catch (_) {
      // The connection is gone or closed itself; its done future says so.
    } finally {
      _inFlight = false;
    }
  }

  void stop() {
    _started = false;
    _timer?.cancel();
    _timer = null;
  }
}
