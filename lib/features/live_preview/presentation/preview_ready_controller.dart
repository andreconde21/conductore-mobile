import 'dart:async';

import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/companion_setup/data/companion_commands.dart';
import 'package:conduit/features/live_preview/domain/dev_server_detection.dart';
import 'package:conduit/features/live_preview/domain/listening_ports.dart';
import 'package:flutter/foundation.dart';

/// How [PreviewReadyController] learns about new listening ports.
enum PreviewPortSource {
  /// Not decided yet: the first poll asks the companion.
  unknown,

  /// `conductore-hostd ports --since <seq>` (0.5.0 and newer).
  companion,

  /// `ss -ltnH` diffed on the phone: no companion, or an older one.
  ss,
}

/// Watches one session's machine for a dev server that just started, and
/// offers it as a "Preview ready" chip.
///
/// Two signals feed [offer]:
/// * New listening TCP ports, polled only while the session is in the
///   foreground ([setForeground]): first after [interval], then backing
///   off to [maxInterval] while nothing new appears, and not at all while
///   an offer is shown (CON-089). The companion's
///   `ports` command is asked first; when it is missing or too old the
///   phone diffs `ss` output itself. The first poll is the baseline, so
///   servers that were already running are not announced.
/// * Dev server URLs printed on the terminal screen
///   ([scanScreen], e.g. Vite's `Local: http://localhost:5173/`).
///
/// A dismissed or opened port is not offered again for this session.
class PreviewReadyController extends ChangeNotifier {
  PreviewReadyController({
    required this._runnerFactory,
    this.interval = defaultInterval,
    this.maxInterval = defaultMaxInterval,
    this.startDelay = defaultStartDelay,
    this.screenDebounce = defaultScreenDebounce,
    this._canPoll,
  });

  static const defaultInterval = Duration(seconds: 5);
  static const defaultMaxInterval = Duration(seconds: 30);
  static const defaultStartDelay = Duration(seconds: 2);
  static const defaultScreenDebounce = Duration(milliseconds: 500);
  static const _commandTimeout = Duration(seconds: 8);

  final AgentCommandRunner Function() _runnerFactory;
  final bool Function()? _canPoll;
  final Duration interval;

  /// The longest gap between two polls once they keep finding nothing.
  final Duration maxInterval;

  /// The gap before the next poll; doubles up to [maxInterval].
  Duration _nextInterval = Duration.zero;

  /// Wait before the first poll after coming to the foreground, so
  /// flicking through tabs opens no connections.
  final Duration startDelay;

  /// Longest delay between a screen change and the [scanScreen] after it.
  final Duration screenDebounce;

  Listenable? _screen;
  List<String> Function()? _screenRows;
  Timer? _screenTimer;

  AgentCommandRunner? _runner;
  Timer? _timer;
  bool _foreground = false;
  bool _polling = false;
  bool _disposed = false;

  PreviewPortSource _source = PreviewPortSource.unknown;
  int? _companionSeq;
  List<ListeningPort>? _ssBaseline;

  final Set<int> _handled = {};
  final Set<int> _onScreen = {};
  DevServerOffer? _offer;

  /// The dev server to offer, or null.
  DevServerOffer? get offer => _offer;

  PreviewPortSource get source => _source;
  bool get isForeground => _foreground;

  /// Ports dismissed or opened in this session.
  Set<int> get handledPorts => Set.unmodifiable(_handled);

  /// Starts polling (after [startDelay], then every [interval]) and screen
  /// scanning while true. While false nothing runs and the extra SSH
  /// connection is closed: the phone asks nothing while the session is
  /// hidden.
  void setForeground(bool foreground) {
    if (_disposed || foreground == _foreground) return;
    _foreground = foreground;
    _timer?.cancel();
    _timer = null;
    _screenTimer?.cancel();
    _screenTimer = null;
    if (foreground) {
      _nextInterval = interval;
      _schedulePoll(startDelay);
      _scheduleScreenScan();
    } else {
      _closeRunner();
    }
  }

  /// Follows a terminal screen: [rows] are read at most once per
  /// [screenDebounce] while [screen] keeps changing, in the foreground.
  void attachScreen(Listenable screen, List<String> Function() rows) {
    _screen?.removeListener(_scheduleScreenScan);
    _screen = screen;
    _screenRows = rows;
    screen.addListener(_scheduleScreenScan);
    _scheduleScreenScan();
  }

  void _scheduleScreenScan() {
    if (!_foreground || _disposed || _screenRows == null) return;
    // A throttle, not a debounce: a build log that never pauses would
    // otherwise never be read.
    if (_screenTimer?.isActive ?? false) return;
    _screenTimer = Timer(screenDebounce, () {
      final rows = _screenRows;
      if (rows != null && _foreground && !_disposed) scanScreen(rows());
    });
  }

  void _schedulePoll(Duration delay) {
    _timer?.cancel();
    _timer = Timer(delay, () => unawaited(_pollAndReschedule()));
  }

  Future<void> _pollAndReschedule() async {
    _timer = null;
    if (!_foreground || _disposed || _offer != null) return;
    await poll();
    if (!_foreground || _disposed || _timer != null) return;
    // A port was found: no more polls until it is handled.
    if (_offer != null) return;
    _schedulePoll(_nextInterval);
    final doubled = _nextInterval * 2;
    _nextInterval = doubled > maxInterval ? maxInterval : doubled;
  }

  /// Whether a port poll is scheduled (tests).
  @visibleForTesting
  bool get pollScheduled => _timer?.isActive ?? false;

  void _closeRunner() {
    final runner = _runner;
    _runner = null;
    if (runner != null) unawaited(runner.close());
  }

  /// One detection round. Public for tests; the timer calls it.
  Future<void> poll() async {
    if (_disposed || _polling || !(_canPoll?.call() ?? true)) return;
    _polling = true;
    try {
      if (_source != PreviewPortSource.ss) {
        final handled = await _pollCompanion();
        if (handled || _disposed) return;
        _source = PreviewPortSource.ss;
      }
      await _pollSs();
    } on Object {
      // Unreachable for now (the session is reconnecting), or the runner
      // failed in a way that says nothing about ports: try next time.
    } finally {
      _polling = false;
    }
  }

  /// Returns false when the companion cannot answer `ports`.
  Future<bool> _pollCompanion() async {
    final result = await _run(
      CompanionCommands.hostdCommand(
        companionPortsArguments(since: _companionSeq),
      ),
    );
    final reply = result.exitCode == 0
        ? parseCompanionPorts(result.stdout)
        : null;
    if (reply == null) return false;
    _source = PreviewPortSource.companion;
    final baseline = _companionSeq == null;
    _companionSeq = reply.seq;
    if (!baseline) {
      for (final offer in reply.offers) {
        _consider(offer);
      }
    }
    return true;
  }

  Future<void> _pollSs() async {
    final result = await _run(listeningPortsCommand);
    if (result.exitCode != 0) return;
    final current = parseListeningPorts(
      result.stdout,
    ).where(isDevServerCandidate).toList();
    final previous = _ssBaseline;
    _ssBaseline = current;
    if (previous == null) return;
    for (final port in newListeningPorts(previous, current)) {
      _consider(
        DevServerOffer(
          port: port.port,
          source: DevServerOfferSource.listening,
          label: port.process,
        ),
      );
    }
  }

  Future<AgentCommandResult> _run(String command) =>
      (_runner ??= _runnerFactory()).run(command, timeout: _commandTimeout);

  /// Looks for dev server URLs in the visible terminal [rows]. Each port is
  /// offered when it first appears on screen, and again only after it left
  /// the screen and came back (a restarted server).
  void scanScreen(List<String> rows) {
    if (_disposed) return;
    final found = detectDevServerUrls(rows);
    final ports = {for (final offer in found) offer.port};
    _onScreen.removeWhere((port) => !ports.contains(port));
    for (final offer in found) {
      if (_onScreen.add(offer.port)) {
        _consider(offer);
      }
    }
  }

  void _consider(DevServerOffer offer) {
    if (_handled.contains(offer.port)) return;
    final current = _offer;
    final next = current != null && current.port == offer.port
        ? current.mergedWith(offer)
        : offer;
    if (next == current) return;
    _offer = next;
    notifyListeners();
  }

  /// The user closed the chip: this port is not offered again.
  void dismiss() => _handle();

  /// The user opened the offer in Live preview.
  void markOpened() => _handle();

  /// Hides the offer when [port] is already what Live preview shows.
  void markPreviewing(int port) {
    _handled.add(port);
    if (_offer?.port == port) {
      _offer = null;
      notifyListeners();
      _resumePolling();
    }
  }

  void _handle() {
    final offer = _offer;
    if (offer == null) return;
    _handled.add(offer.port);
    _offer = null;
    notifyListeners();
    _resumePolling();
  }

  /// Polling stopped while an offer was shown; it goes on, slowly.
  void _resumePolling() {
    if (_foreground && !_disposed && _timer == null) {
      _schedulePoll(_nextInterval);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _screenTimer?.cancel();
    _screen?.removeListener(_scheduleScreenScan);
    _screen = null;
    _closeRunner();
    super.dispose();
  }
}
