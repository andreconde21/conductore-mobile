import 'dart:async';

import 'package:conduit/core/app_failure.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/live_preview/domain/listening_ports.dart';
import 'package:conduit/features/live_preview/domain/live_preview_port_store.dart';
import 'package:conduit/features/live_preview/domain/port_forward.dart';
import 'package:conduit/features/live_preview/domain/preview_viewport.dart';
import 'package:flutter/foundation.dart';

enum LivePreviewPhase { idle, connecting, ready, failed, closed }

/// The default when a host has no remembered port: what Vite, Next, Rails
/// and most dev servers pick.
const livePreviewDefaultPort = 3000;

/// State for one Live preview tab: the forward, its lifecycle, and the
/// URL the WebView shows.
class LivePreviewController extends ChangeNotifier {
  LivePreviewController(
    this._forwarder, {
    required this.hostId,
    LivePreviewPortStore? portStore,
    this._commandRunner,
  }) : _portStore = portStore ?? InMemoryLivePreviewPortStore();

  final PortForwarder _forwarder;
  final LivePreviewPortStore _portStore;
  final AgentCommandRunner? _commandRunner;
  final String hostId;

  static const _portsTimeout = Duration(seconds: 10);

  LivePreviewPhase _phase = LivePreviewPhase.idle;
  LocalPortForward? _forward;
  StreamSubscription<String>? _errorSubscription;
  int? _remotePort;
  String _path = '/';
  PreviewViewport _viewport = PreviewViewport.phone;
  String? _error;
  String? _connectionError;
  bool _disposed = false;
  int _generation = 0;
  Listenable? _session;
  VoidCallback? _sessionListener;

  LivePreviewPhase get phase => _phase;
  int? get remotePort => _remotePort;
  int? get localPort => _forward?.localPort;
  bool get isReady => _phase == LivePreviewPhase.ready && _forward != null;

  /// The emulated device width, remembered per port.
  PreviewViewport get viewport => _viewport;

  /// Switches the emulated device and remembers it for the current port.
  void setViewport(PreviewViewport value) {
    if (value == _viewport) return;
    _viewport = value;
    notifyListeners();
    final port = _remotePort;
    if (port != null) {
      unawaited(_portStore.writeViewport(hostId, port, value));
    }
  }

  /// Path (and query) shown in the address bar; always starts with `/`.
  String get path => _path;

  /// Why the forward could not be opened, when [phase] is failed.
  String? get error => _error;

  /// The latest tunnelled-connection failure; cleared on reload.
  String? get connectionError => _connectionError;

  /// The URL for the WebView, or null until the forward is ready.
  Uri? get url {
    final forward = _forward;
    if (!isReady || forward == null) {
      return null;
    }
    return Uri.parse('http://127.0.0.1:${forward.localPort}$_path');
  }

  /// The remembered port for this host, else [livePreviewDefaultPort].
  Future<int> suggestedPort() async =>
      await _portStore.read(hostId) ?? livePreviewDefaultPort;

  /// Ports something on the host is listening on, or an empty list when
  /// `ss` is unavailable or no command runner was given.
  Future<List<ListeningPort>> detectPorts() async {
    final runner = _commandRunner;
    if (runner == null) {
      return const [];
    }
    try {
      final result = await runner.run(
        listeningPortsCommand,
        timeout: _portsTimeout,
      );
      if (result.exitCode != 0) {
        return const [];
      }
      return parseListeningPorts(result.stdout);
    } on AppFailure {
      return const [];
    }
  }

  /// Opens (or replaces) the forward to [remotePort].
  Future<void> start(int remotePort) async {
    if (remotePort < 1 || remotePort > 65535) {
      _fail('Port must be between 1 and 65535.');
      return;
    }
    final generation = ++_generation;
    await _closeForward();
    _remotePort = remotePort;
    _phase = LivePreviewPhase.connecting;
    _error = null;
    _connectionError = null;
    notifyListeners();
    unawaited(_portStore.write(hostId, remotePort));
    try {
      final viewport =
          await _portStore.readViewport(hostId, remotePort) ??
          PreviewViewport.phone;
      if (!_disposed && generation == _generation) {
        _viewport = viewport;
      }
      final forward = await _forwarder.open(remotePort);
      if (_disposed || generation != _generation) {
        await forward.close();
        return;
      }
      _forward = forward;
      _errorSubscription = forward.connectionErrors.listen((message) {
        _connectionError = message;
        notifyListeners();
      });
      _phase = LivePreviewPhase.ready;
      notifyListeners();
    } catch (error) {
      if (_disposed || generation != _generation) {
        return;
      }
      _fail(error is AppFailure ? error.userMessage : error.toString());
    }
  }

  /// Re-opens the current forward after a failure or a disconnect.
  Future<void> restart() async {
    final port = _remotePort;
    if (port != null) {
      await start(port);
    }
  }

  /// Closes the forward; the tab stays open showing why.
  Future<void> stop({String? reason}) async {
    _generation++;
    await _closeForward();
    if (_disposed) {
      return;
    }
    _phase = LivePreviewPhase.closed;
    _error = reason;
    notifyListeners();
  }

  /// Updates the address bar path; WebView navigation reports land here
  /// so the field follows in-page links.
  void setPath(String path) {
    // A WebView callback can land after the tab closed.
    if (_disposed) return;
    final normalized = normalizePath(path);
    if (normalized == _path) {
      return;
    }
    _path = normalized;
    notifyListeners();
  }

  void clearConnectionError() {
    if (_connectionError == null) {
      return;
    }
    _connectionError = null;
    notifyListeners();
  }

  /// Ties the forward to a terminal session: when [isConnected] turns
  /// false the forward closes, as the process it pointed at is gone or the
  /// user chose to disconnect.
  void attachSession(Listenable session, bool Function() isConnected) {
    _detachSession();
    _session = session;
    _sessionListener = () {
      if (!isConnected() &&
          (_phase == LivePreviewPhase.ready ||
              _phase == LivePreviewPhase.connecting)) {
        unawaited(stop(reason: 'The session disconnected.'));
      }
    };
    session.addListener(_sessionListener!);
  }

  void _detachSession() {
    final listener = _sessionListener;
    if (listener != null) {
      _session?.removeListener(listener);
    }
    _session = null;
    _sessionListener = null;
  }

  /// Turns whatever the user typed (`about`, `/about?x=1`, a full URL to
  /// the preview host) into a path starting with `/`.
  static String normalizePath(String input) {
    var value = input.trim();
    if (value.isEmpty) {
      return '/';
    }
    final parsed = Uri.tryParse(value);
    if (parsed != null && parsed.hasScheme && parsed.hasAuthority) {
      value = parsed.hasQuery ? '${parsed.path}?${parsed.query}' : parsed.path;
      if (value.isEmpty) {
        value = '/';
      }
    }
    if (!value.startsWith('/')) {
      value = '/$value';
    }
    return value;
  }

  void _fail(String message) {
    _phase = LivePreviewPhase.failed;
    _error = message;
    notifyListeners();
  }

  Future<void> _closeForward() async {
    // Not awaited: cancelling takes effect at once, and the returned future
    // can be a root-zone value that never resolves under a fake clock.
    unawaited(_errorSubscription?.cancel());
    _errorSubscription = null;
    final forward = _forward;
    _forward = null;
    if (forward != null) {
      try {
        await forward.close();
      } catch (_) {
        // Already gone.
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _detachSession();
    unawaited(_closeForward().then((_) => _forwarder.close()));
    unawaited(_commandRunner?.close());
    super.dispose();
  }
}
