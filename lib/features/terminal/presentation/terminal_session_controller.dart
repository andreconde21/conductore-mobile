import 'dart:async';
import 'dart:convert';

import 'package:conduit/core/app_failure.dart';
import 'package:conduit/core/connection_problem.dart';
import 'package:conduit/core/telemetry/telemetry.dart';
import 'package:conduit/core/telemetry/telemetry_events.dart';
import 'package:conduit/core/theme/terminal_appearance.dart';
import 'package:conduit/features/agent_attention/data/remote_tool_command.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:conduit/features/sessions/presentation/terminal_preview.dart';
import 'package:conduit/features/terminal/domain/herdr_keymap.dart';
import 'package:conduit/features/terminal/domain/mosh_server_cleanup.dart';
import 'package:conduit/features/terminal/domain/network_connectivity.dart';
import 'package:conduit/features/terminal/domain/osc52_clipboard.dart';
import 'package:conduit/features/terminal/domain/predictive_echo.dart';
import 'package:conduit/features/terminal/domain/predictive_terminal_session.dart';
import 'package:conduit/features/terminal/domain/recent_directories.dart';
import 'package:conduit/features/terminal/domain/roaming_terminal_session.dart';
import 'package:conduit/features/terminal/domain/security_key_interaction.dart';
import 'package:conduit/features/terminal/domain/ssh_terminal_repository.dart';
import 'package:conduit/features/terminal/domain/ssh_terminal_session.dart';
import 'package:conduit/features/terminal/domain/terminal_string_sequence_filter.dart';
import 'package:conduit/features/terminal/presentation/desktop_keyboard.dart';
import 'package:conduit/features/terminal/presentation/session_input_hold.dart';
import 'package:conduit/features/terminal/presentation/terminal_keyboard_controller.dart';
import 'package:conduit_vt/conduit_vt.dart';
import 'package:flutter/foundation.dart';

enum TerminalConnectionStatus {
  idle,
  connecting,
  connected,
  disconnected,
  failed,
}

class TerminalSessionController extends ChangeNotifier {
  TerminalSessionController({
    required this.host,
    required this.repository,
    this.connectivity,
    this.startupCommand,
    bool predictiveEchoEnabled = false,
    TerminalEnterSequence enterSequence = TerminalEnterSequence.cr,
  }) : keyboard = TerminalKeyboardController(terminalInputHandlerForPlatform()),
       terminal = Terminal(
         maxLines: 10000,
         platform: terminalTargetPlatform(),
       ) {
    _predictiveEchoEnabled = predictiveEchoEnabled;
    _enterSequence = enterSequence;
    _configureTerminal();
  }

  final SavedHost host;
  final SshTerminalRepository repository;
  final NetworkConnectivity? connectivity;

  /// Command typed into the shell right after connecting (e.g. a Herdr
  /// attach picked in the connect picker). Takes precedence over the host's
  /// tmux-on-connect settings.
  final String? startupCommand;
  final TerminalKeyboardController keyboard;
  final Terminal terminal;
  final _outputFilter = TerminalStringSequenceFilter();

  /// stderr's own: a sequence split across chunks must not mix streams.
  final _stderrFilter = TerminalStringSequenceFilter();
  final _predictiveEcho = PredictiveEcho();
  final _terminalPaintNotifier = ChangeNotifier();
  final Stopwatch _inputClock = Stopwatch()..start();

  TerminalConnectionStatus _status = TerminalConnectionStatus.idle;
  SshTerminalSession? _session;
  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;
  StreamSubscription<void>? _doneSubscription;
  StreamSubscription<void>? _connectivitySubscription;
  StreamSubscription<int>? _echoAckSubscription;
  int _pixelWidth = 0;
  int _pixelHeight = 0;
  Timer? _resizeTimer;
  Timer? _redrawTimer;
  bool _resizePending = false;
  int _pendingColumns = 0;
  int _pendingRows = 0;
  int _sentColumns = 0;
  int _sentRows = 0;
  bool _disconnecting = false;
  bool _disposed = false;
  bool _predictiveEchoEnabled = false;
  TerminalEnterSequence _enterSequence = TerminalEnterSequence.cr;
  int _connectionGeneration = 0;
  int? _lastIosEnterOutputMs;
  final _terminalTitle = ValueNotifier<String>('');
  final _remoteClipboardWrites = StreamController<String>.broadcast();
  final _workingDirectoryReports = StreamController<String>.broadcast();
  String? _workingDirectory;
  late final _inputHold = SessionInputHold(deliver: _deliverInput);

  /// Set while remote output is being written: what the terminal sends
  /// then is its answer to a query, not input.
  bool _answeringRemote = false;
  final _sharedView = ValueNotifier<SharedViewSnapshot?>(null);
  final _focusElsewhere = ValueNotifier<String?>(null);

  static const _iosDuplicateEnterWindow = Duration(milliseconds: 80);
  static const _gracefulMoshCloseTimeout = Duration(milliseconds: 1500);
  static const _tmuxDetachExitDelay = Duration(milliseconds: 150);
  static const _connectSnippetAfterTmuxDelay = Duration(milliseconds: 250);

  TerminalConnectionStatus get status => _status;

  /// How the shell of a local session ("This computer") ended, while the
  /// session is disconnected because it did; null otherwise.
  int? get exitCode =>
      _status == TerminalConnectionStatus.disconnected ? _exitCode : null;
  int? _exitCode;

  /// Whether this session's shell runs on the desktop itself ("This
  /// computer"), so it ends with an exit code and restarts instead of
  /// reconnecting.
  bool get runsOnThisComputer => host.isThisComputer;
  String get title => _customTitle ?? host.name;

  /// Name the user gave this session (long-press › Rename on the home
  /// grid), or null to show the machine and target name.
  String? get customTitle => _customTitle;
  String? _customTitle;

  /// Renames the session for this app run; blank restores the default.
  void rename(String? value) {
    final trimmed = value?.trim() ?? '';
    final next = trimmed.isEmpty ? null : trimmed;
    if (next == _customTitle) return;
    _customTitle = next;
    notifyListeners();
  }

  /// The window title the remote application last set (OSC 0/2), empty
  /// until one arrives. Herdr and tmux both keep it current.
  String get terminalTitle => _terminalTitle.value;

  /// Notifies each change of [terminalTitle]. Kept apart from this
  /// controller's own notifications: a TUI that animates its title (a
  /// spinner) would otherwise rebuild everything listening to the session.
  ValueListenable<String> get terminalTitleListenable => _terminalTitle;

  /// Text the remote asked to put on the clipboard with OSC 52 (vim, tmux
  /// `set-clipboard on`, Claude Code's copy). Already decoded, capped at
  /// [osc52MaxBytes]; read requests are never answered. Whether it reaches
  /// the phone clipboard is the listener's decision (a user setting).
  Stream<String> get remoteClipboardWrites => _remoteClipboardWrites.stream;

  /// The shell's working directory as last reported with OSC 7 (bash with
  /// vte.sh, zsh on most distros, fish), null until one arrives.
  String? get workingDirectory => _workingDirectory;

  /// Each change of [workingDirectory].
  Stream<String> get workingDirectoryReports => _workingDirectoryReports.stream;
  bool get isConnected => _status == TerminalConnectionStatus.connected;

  /// Whether typed input is being held (see [holdInput]), and why the last
  /// held input was dropped; null when input flows.
  ValueListenable<InputHoldState?> get inputHold => _inputHold.state;

  /// Holds everything sent into this session (keys, pastes, composed
  /// prompts) until [ready] completes: true sends it in order, false or
  /// [timeout] drops it and says so on [inputHold]. Herdr sessions use it
  /// while their server's shared focus is moved back to them.
  void holdInput(
    Future<bool> ready, {
    String label = '',
    Duration timeout = SessionInputHold.defaultTimeout,
  }) => _inputHold.hold(ready, label: label, timeout: timeout);

  /// Holds input on a [decision] instead (see [SessionInputHold.decide]):
  /// the input waits, goes out, is dropped, or waits for the user
  /// ([releaseHeldInput], [discardHeldInput], [takeHeldText]).
  void decideInput(
    Future<InputHoldDecision> decision, {
    String label = '',
    String Function()? blockedLabel,
  }) => _inputHold.decide(decision, label: label, blockedLabel: blockedLabel);

  /// Sends the held input after all (the user chose to).
  void releaseHeldInput() => _inputHold.release();

  /// Drops the held input (the user chose to).
  void discardHeldInput() => _inputHold.discard();

  /// The printable text held so far, for the composer; the rest is
  /// dropped and input flows again.
  String takeHeldText() => _inputHold.takeText();

  /// Asked before typed input goes out while nothing holds it: a decision
  /// to hold it for, or null to send it now. Set by whoever knows where
  /// the input would land (Herdr's shared focus).
  Future<InputHoldDecision>? Function(TerminalSessionController session)?
  inputCheck;

  /// Rewrites [startupCommand] at each connect (a Herdr attach without its
  /// focus, when this device may not move Herdr's focus).
  String Function(String command)? startupCommandFilter;

  /// Delivers what the app writes into this session (composer, snippets,
  /// quick actions, menu answers, image paths) to its own place without
  /// the terminal, when set and able; see [sendAppText].
  AppInputRouter? appInputRouter;

  /// Types [text] the app wrote (not the user's keys) into this session,
  /// and presses Enter after it with [submit]: through [appInputRouter]
  /// when it can deliver it (Herdr, by pane id), else through the terminal
  /// like typed input, Enter as its own write shortly after.
  /// With [paste] the terminal path pastes it (bracketed when the program
  /// asked for that) instead of typing it.
  Future<void> sendAppText(
    String text, {
    bool submit = false,
    bool paste = false,
  }) async {
    final router = appInputRouter;
    if (router != null && await router.sendText(this, text, submit: submit)) {
      return;
    }
    if (_disposed) return;
    claimInput();
    if (text.isNotEmpty) paste ? this.paste(text) : sendText(text);
    if (submit) {
      await Future<void>.delayed(composedEnterDelay);
      if (!_disposed) sendKey(TerminalKey.enter);
    }
  }

  /// Presses [keys] for the app (a menu answer), like [sendAppText].
  Future<void> sendAppKeys(List<TerminalKey> keys) async {
    final router = appInputRouter;
    if (router != null && await router.sendKeys(this, keys)) {
      return;
    }
    if (_disposed) return;
    claimInput();
    for (final key in keys) {
      sendKey(key);
    }
  }

  /// Called before the app itself types into this session (the composer,
  /// a snippet, a quick action, an image path) so its Herdr focus can be
  /// checked first; set by whoever keeps that focus.
  void Function(TerminalSessionController session)? inputClaimer;

  /// Makes sure what the app types next lands in this session's own place
  /// (see [inputClaimer]). Cheap and safe to call before any write.
  void claimInput() => inputClaimer?.call(this);

  /// While set, this session's screen mirrors another session's Herdr
  /// workspace (they share a Herdr server, whose focus is on the other),
  /// and previews show this snapshot of its own instead.
  ValueListenable<SharedViewSnapshot?> get sharedView => _sharedView;

  set sharedViewSnapshot(SharedViewSnapshot? snapshot) {
    if (!_disposed) _sharedView.value = snapshot;
  }

  /// What Herdr shows instead of this session's own workspace (the focused
  /// workspace's name) while another screen has its shared focus and this
  /// device may not move it; null while it shows this session's own.
  ValueListenable<String?> get focusElsewhere => _focusElsewhere;

  set focusElsewhereLabel(String? label) {
    if (!_disposed) _focusElsewhere.value = label;
  }

  bool get predictiveEchoEnabled => _predictiveEchoEnabled;
  TerminalEnterSequence get enterSequence => _enterSequence;
  Listenable get terminalPaintListenable => _terminalPaintNotifier;

  /// Whether the remote application has enabled mouse tracking (DECSET
  /// 1000/1002/1003), meaning forwarded taps would actually be delivered
  /// as mouse clicks rather than ignored.
  bool get remoteMouseTrackingActive => terminal.mouseMode != MouseMode.none;

  List<TerminalCellOverlay> get overlays {
    if (!_predictiveEchoEnabled) {
      return const <TerminalCellOverlay>[];
    }

    return [
      for (final prediction in _predictiveEcho.overlay)
        TerminalCellOverlay(
          row: prediction.row,
          column: prediction.column,
          text: prediction.character,
          opacity: prediction.erase ? 1 : 0.62,
          erase: prediction.erase,
        ),
    ];
  }

  set predictiveEchoEnabled(bool enabled) {
    if (_predictiveEchoEnabled == enabled) {
      return;
    }
    _predictiveEchoEnabled = enabled;
    if (!enabled) {
      _predictiveEcho.reset();
    }
    _notifyTerminalPaint();
    notifyListeners();
  }

  set enterSequence(TerminalEnterSequence sequence) {
    if (_enterSequence == sequence) {
      return;
    }
    _enterSequence = sequence;
    notifyListeners();
  }

  bool get shouldConnect =>
      !_disconnecting &&
      (_status == TerminalConnectionStatus.idle ||
          _status == TerminalConnectionStatus.disconnected ||
          _status == TerminalConnectionStatus.failed);

  Future<void> connect() async {
    if (_status == TerminalConnectionStatus.connecting ||
        _status == TerminalConnectionStatus.connected ||
        _disconnecting ||
        _disposed) {
      return;
    }

    // A session that ended on its own (shell exit, stream error) is
    // already closed; this only catches one that somehow was not.
    _teardownSession();
    final generation = ++_connectionGeneration;
    _exitCode = null;
    _outputFilter.reset();
    _stderrFilter.reset();
    _predictiveEcho.reset();
    _status = TerminalConnectionStatus.connecting;
    terminal.write(
      host.isThisComputer
          ? 'Starting the shell on this computer...\r\n'
          : host.isLocal
          ? 'Starting ${host.name}...\r\n'
          : 'Connecting to ${host.endpoint}...\r\n',
    );
    notifyListeners();

    StreamSubscription<String>? securityKeySubscription;
    try {
      // The key's prompts ("touch your key") are app-wide; only a session
      // signing in with a hardware key can be the one they are about.
      if (host.authMethod == SshAuthMethod.hardwareKey) {
        securityKeySubscription = SecurityKeyInteraction.instance.messages
            .listen((message) => terminal.write('$message\r\n'));
      }
      final session = await repository.connect(
        host,
        columns: terminal.viewWidth,
        rows: terminal.viewHeight,
      );
      if (_disposed || generation != _connectionGeneration || _disconnecting) {
        unawaited(session.close());
        return;
      }
      _session = session;

      terminal.buffer.clear();
      terminal.buffer.setCursor(0, 0);
      if (kDebugMode) {
        debugPrint(
          '[term ${host.name}] connect size -> '
          '${terminal.viewWidth}x${terminal.viewHeight}',
        );
      }
      session.resize(
        terminal.viewWidth,
        terminal.viewHeight,
        _pixelWidth,
        _pixelHeight,
      );
      _sentColumns = terminal.viewWidth;
      _sentRows = terminal.viewHeight;

      _stdoutSubscription = session.stdout
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(
            (chunk) => _writeTerminalOutput(_outputFilter.process(chunk)),
            onError: _handleStreamError,
          );
      _stderrSubscription = session.stderr
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(
            (chunk) => _writeTerminalOutput(_stderrFilter.process(chunk)),
            onError: _handleStreamError,
          );
      _doneSubscription = session.done
          .asStream()
          .asyncMap((_) async {
            if (session is ExitStatusTerminalSession) {
              return (session as ExitStatusTerminalSession).exitCode
                  .then<int?>((code) => code)
                  .catchError((_) => null);
            }
            return null;
          })
          .listen((code) {
            if (_status == TerminalConnectionStatus.connected &&
                _session == session) {
              _status = TerminalConnectionStatus.disconnected;
              _exitCode = code;
              terminal.write(switch ((host.isLocal, code)) {
                (_, final int code) => '\r\n[Shell exited (code $code)]\r\n',
                (true, null) => '\r\nShell exited.\r\n',
                (false, null) => '\r\nConnection closed.\r\n',
              });
              _teardownSession(drainOutput: true);
              notifyListeners();
            }
          }, onError: _handleStreamError);

      if (session is RoamingTerminalSession) {
        _connectivitySubscription = connectivity?.onNetworkChanged.listen(
          (_) => _rehome(),
        );
      }
      if (session is PredictiveTerminalSession) {
        final predictiveSession = session as PredictiveTerminalSession;
        _predictiveEcho.updateSrtt(predictiveSession.smoothedRtt);
        _echoAckSubscription = predictiveSession.echoAcks.listen((int ackNum) {
          _predictiveEcho
            ..updateSrtt(predictiveSession.smoothedRtt)
            ..recordEchoAck(ackNum);
          _notifyTerminalPaint();
        }, onError: _handleStreamError);
      }

      _status = TerminalConnectionStatus.connected;
      notifyListeners();
      _reportConnect();
      _runStartupCommandIfConfigured(session);
      _runConnectSnippetIfConfigured(session);
    } catch (error) {
      if (_disposed || generation != _connectionGeneration) {
        return;
      }
      _reportConnect(error);
      _failConnect(error);
    } finally {
      await securityKeySubscription?.cancel();
    }
  }

  /// Anonymous usage count of this attempt: transport, multiplexer and,
  /// on failure, only its coarse class.
  void _reportConnect([Object? error]) {
    final command = (startupCommand ?? '').toLowerCase();
    Telemetry.instance.track(
      TelemetryEvent.sessionConnect(
        transport: host.isLocal || host.isThisComputer
            ? TelemetryTransport.local
            : host.useMosh
            ? TelemetryTransport.mosh
            : TelemetryTransport.ssh,
        multiplexer: command.contains('herdr')
            ? TelemetryMultiplexer.herdr
            : command.contains('tmux') || host.startTmuxOnConnect
            ? TelemetryMultiplexer.tmux
            : TelemetryMultiplexer.none,
        failure: error == null ? null : classifyConnectFailure(error),
      ),
    );
  }

  Future<void> disconnect() async {
    if (_disconnecting ||
        _status == TerminalConnectionStatus.disconnected ||
        _status == TerminalConnectionStatus.idle) {
      return;
    }
    _disconnecting = true;
    _connectionGeneration += 1;

    _resizeTimer?.cancel();
    _resizeTimer = null;
    _resizePending = false;
    _redrawTimer?.cancel();
    _redrawTimer = null;
    await _stdoutSubscription?.cancel();
    await _stderrSubscription?.cancel();
    await _doneSubscription?.cancel();
    await _connectivitySubscription?.cancel();
    await _echoAckSubscription?.cancel();
    _stdoutSubscription = null;
    _stderrSubscription = null;
    _doneSubscription = null;
    _connectivitySubscription = null;
    _echoAckSubscription = null;
    _predictiveEcho.reset();

    final session = _session;
    _session = null;
    _inputHold.reset();
    try {
      final leavesServer = await _closeRemoteMoshSession(session);
      await session?.close();
      if (leavesServer && session is ReapableTerminalSession) {
        // Nothing ended the remote side (a Herdr detach leaves its shell
        // running): stop the server over a command channel, in the
        // background.
        unawaited((session as ReapableTerminalSession).reapServer());
      }
    } finally {
      keyboard.clearModifiers();
      _status = TerminalConnectionStatus.disconnected;
      if (!_disposed) {
        terminal.write('\r\nDisconnected.\r\n');
        notifyListeners();
      }
      _disconnecting = false;
    }
  }

  void sendKey(TerminalKey key) {
    terminal.keyInput(key, ctrl: keyboard.ctrl, alt: keyboard.alt);
    keyboard.clearModifiers();
  }

  void sendText(String text) {
    terminal.textInput(text);
    keyboard.clearModifiers();
  }

  void sendControl(TerminalKey key) {
    terminal.keyInput(key, ctrl: true);
    keyboard.clearModifiers();
  }

  /// Sends a multiplexer prefix (the host's tmux/Herdr prefix, usually).
  ///
  /// A plain Ctrl+letter or Ctrl+Space goes through [sendControl] so the
  /// terminal encodes it like any other control key; every other
  /// combination is written as its raw byte sequence.
  void sendPrefix(MultiplexerPrefixKey prefix) {
    final controlKey = prefix.controlKey;
    if (controlKey != null) {
      sendControl(controlKey);
      return;
    }
    sendText(prefix.sequence);
  }

  void paste(String text) {
    claimInput();
    terminal.paste(text);
    keyboard.clearModifiers();
  }

  /// Whether the remote application has switched bracketed paste on
  /// (DECSET 2004), so pasted text is delivered atomically instead of being
  /// interpreted as individual key presses.
  bool get bracketedPasteSupported => terminal.bracketedPasteMode;

  static const composedEnterDelay = Duration(milliseconds: 120);

  /// Sends a composed, possibly multiline prompt into the terminal.
  ///
  /// The payload goes through the terminal's paste path: when the remote
  /// application advertises bracketed paste (DECSET 2004) the text — newlines,
  /// quotes, and all — is wrapped in paste markers and arrives as one literal
  /// block. Without bracketed paste the text falls back to the plain input
  /// path with newlines normalized to carriage returns, which is what each
  /// line's Enter key would have sent.
  ///
  /// Control characters other than tab and newline are stripped in both
  /// paths: a prompt copied from a terminal can carry ESC, ^C or ^D bytes
  /// that the remote application would act on as keystrokes, and inside a
  /// bracketed paste an embedded paste-end marker would let the rest of the
  /// text escape the paste guard.
  ///
  /// With [submit], Enter is delivered as a separate write shortly after the
  /// text. Some TUIs classify a single read that contains a long line ending
  /// in CR as a paste and insert the trailing CR literally instead of
  /// submitting; an isolated Enter keypress submits regardless.
  Future<void> sendComposed(String text, {required bool submit}) async {
    final sanitized = sanitizeComposedText(text);
    final router = appInputRouter;
    if (router != null &&
        await router.sendText(this, sanitized, submit: submit)) {
      return;
    }
    if (_disposed) return;
    claimInput();
    if (terminal.bracketedPasteMode) {
      terminal.paste(sanitized);
    } else {
      // Without bracketed paste, newlines are delivered as carriage returns
      // (what Enter sends). Trailing newlines are dropped so "insert only"
      // never submits the final line on its own.
      final normalized = sanitized
          .replaceAll(RegExp(r'\n+$'), '')
          .replaceAll('\n', '\r');
      terminal.textInput(normalized);
    }
    keyboard.clearModifiers();
    if (submit) {
      await Future<void>.delayed(composedEnterDelay);
      if (!_disposed) {
        terminal.keyInput(TerminalKey.enter);
      }
    }
  }

  /// Normalizes line endings to `\n` and strips every C0 control character
  /// except tab and newline (plus DEL), so composed text can only ever reach
  /// the remote application as printable input. Stripping ESC also removes
  /// any embedded bracketed-paste end marker.
  static String sanitizeComposedText(String text) {
    return text
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .replaceAll(_composedControlCharacters, '');
  }

  static final _composedControlCharacters = RegExp(
    r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]',
  );

  bool get _hasStartupCommand =>
      startupCommand != null || host.startTmuxOnConnect;

  void _runStartupCommandIfConfigured(SshTerminalSession session) {
    final original = startupCommand;
    final explicit = original == null
        ? null
        : startupCommandFilter?.call(original) ?? original;
    final command = explicit != null
        ? '$explicit${_enterSequence.value}'
        : _buildTmuxCommand();
    if (command == null) {
      return;
    }
    unawaited(
      session.send(utf8.encode(command)).catchError(_handleStreamError),
    );
  }

  void _runConnectSnippetIfConfigured(SshTerminalSession session) {
    final snippetId = host.connectSnippetId;
    if (snippetId.isEmpty) {
      return;
    }
    final snippet = host.snippets
        .where((candidate) => candidate.id == snippetId)
        .firstOrNull;
    if (snippet == null) {
      return;
    }
    final text = snippet.submit
        ? '${snippet.text}${_enterSequence.value}'
        : snippet.text;
    if (text.isEmpty) {
      return;
    }
    final delay = _hasStartupCommand
        ? _connectSnippetAfterTmuxDelay
        : Duration.zero;
    unawaited(_sendConnectSnippet(session, text, delay));
  }

  Future<void> _sendConnectSnippet(
    SshTerminalSession session,
    String text,
    Duration delay,
  ) async {
    try {
      await Future<void>.delayed(delay);
      if (_session != session ||
          _status != TerminalConnectionStatus.connected ||
          _disposed ||
          _disconnecting) {
        return;
      }
      await session.send(utf8.encode(text));
    } catch (error, stackTrace) {
      _handleStreamError(error, stackTrace);
    }
  }

  /// Types what ends the remote side cleanly; true when it leaves the
  /// server running (a Herdr detach, or nothing typed) so it must be
  /// stopped another way.
  Future<bool> _closeRemoteMoshSession(SshTerminalSession? session) async {
    if (session == null || !host.useMosh) {
      return false;
    }
    final keystrokes = moshCloseKeystrokes();
    final leavesServer =
        keystrokes is MoshCloseHerdr || keystrokes is MoshCloseNothing;
    try {
      switch (keystrokes) {
        case MoshCloseTmux(:final detach):
          await session.send(detach);
          await Future<void>.delayed(_tmuxDetachExitDelay);
          await session.send(utf8.encode('exit\r'));
        case MoshCloseHerdr(:final detach):
          // No "exit" after it: if the detach did not land, it would be
          // typed into the focused pane (Claude Code reads it as a command).
          await session.send(detach);
        case MoshCloseShell():
          await session.send(const [0x04]);
        case MoshCloseNothing():
          return leavesServer;
      }
      await session.done.timeout(_gracefulMoshCloseTimeout);
    } catch (_) {
      // Fall back to the transport close below if the remote side ignores the
      // graceful exit sequence or the session is already gone.
    }
    return leavesServer;
  }

  /// What is typed into a Mosh session before its transport closes (Close,
  /// Reconnect, the pill's reconnect), so the remote side ends cleanly
  /// instead of leaving mosh-server behind.
  ///
  /// Only a plain shell gets Ctrl-D. A session attached to a multiplexer
  /// never does: the multiplexer's client is the foreground app, so Ctrl-D
  /// would reach its focused pane and could end Claude Code or a shell
  /// there. tmux gets its detach (prefix, d); Herdr gets the machine's own
  /// `detach` binding from its keymap (prefix+q by default) once that keymap
  /// has been read, and nothing at all before that.
  @visibleForTesting
  MoshCloseKeystrokes moshCloseKeystrokes() {
    final target = ConnectTarget.fromSessionHostId(host.id);
    if (host.startTmuxOnConnect || target?.kind == ConnectTargetKind.tmux) {
      return MoshCloseTmux(_tmuxDetachBytes());
    }
    if (target?.kind == ConnectTargetKind.herdr ||
        _startsHerdr(startupCommand)) {
      final bytes = herdrDetachBytes(
        baseHostId(host.id),
        hostPrefix: host.tmuxPrefixKey,
      );
      return bytes == null ? const MoshCloseNothing() : MoshCloseHerdr(bytes);
    }
    return const MoshCloseShell();
  }

  static final _herdrCommand = RegExp(r'(^|[;&|\s])herdr(\s|$)');

  static bool _startsHerdr(String? command) =>
      command != null && _herdrCommand.hasMatch(command);

  /// The bytes of the `detach` binding in [hostId]'s Herdr keymap, behind
  /// its prefix (the config's `keys.prefix`, else [hostPrefix]); null when
  /// the keymap has not been read from the machine or `detach` is unbound.
  static List<int>? herdrDetachBytes(
    String hostId, {
    required MultiplexerPrefixKey hostPrefix,
  }) {
    final cache = HerdrKeymapCache.instance;
    if (!cache.has(hostId)) {
      return null;
    }
    final keymap = cache.of(hostId);
    final binding = keymap.bindingFor('detach');
    if (binding == null) {
      return null;
    }
    // Encoded exactly as a key press on the terminal would be.
    final out = <int>[];
    final encoder = Terminal()
      ..onOutput = (data) => out.addAll(utf8.encode(data));
    void control(TerminalKey key) => encoder.keyInput(key, ctrl: true);
    HerdrKeySender.send(
      binding,
      prefix: keymap.prefix ?? hostPrefix,
      sendPrefix: (prefix) {
        final key = prefix.controlKey;
        if (key != null) {
          control(key);
        } else {
          encoder.textInput(prefix.sequence);
        }
      },
      sendText: encoder.textInput,
      sendKey: encoder.keyInput,
      sendControl: control,
    );
    return out.isEmpty ? null : out;
  }

  List<int> _tmuxDetachBytes() => [...host.tmuxPrefixKey.bytes, 0x64];

  @visibleForTesting
  String? buildTmuxCommandForTesting() => _buildTmuxCommand();

  String? _buildTmuxCommand() {
    if (!host.startTmuxOnConnect) {
      return null;
    }
    final sessionName = host.tmuxSessionName.trim().isEmpty
        ? defaultTmuxSessionName
        : host.tmuxSessionName.trim();
    final command = StringBuffer(
      'tmux new-session -A -s ${_shellQuote(sessionName)}',
    );
    final startDirectory = host.tmuxStartDirectory.trim();
    if (startDirectory.isNotEmpty) {
      command.write(' -c ${_shellQuote(startDirectory)}');
    }
    command.write(_enterSequence.value);
    return command.toString();
  }

  static final _unquotedPath = RegExp(r'^[A-Za-z0-9_~./:=+-]+$');

  static String _shellQuote(String value) =>
      _unquotedPath.hasMatch(value) ? value : shellQuoteArgument(value);

  void _configureTerminal() {
    terminal.inputHandler = keyboard;
    terminal.onResize = (columns, rows, pixelWidth, pixelHeight) {
      _pixelWidth = pixelWidth;
      _pixelHeight = pixelHeight;
      _pendingColumns = columns;
      _pendingRows = rows;
      // Leading edge: the first change reaches the remote app at once, so
      // a layout change (the chat bar replacing the toolbar, the keyboard
      // opening) redraws the TUI straight away. Changes within the next
      // [resizeCoalesce] (a keyboard animation, a pinch) are coalesced and
      // the final size follows when it ends.
      if (_resizeTimer?.isActive ?? false) {
        _resizePending = true;
        return;
      }
      _flushResize();
      _resizeTimer = Timer(resizeCoalesce, _resizeCooldownEnded);
    };
    terminal.onOutput = _sendTerminalOutput;
    terminal.onTitleChange = (title) {
      if (_disposed) {
        return;
      }
      _terminalTitle.value = title;
    };
    terminal.onPrivateOSC = _handlePrivateOsc;
  }

  void _handlePrivateOsc(String code, List<String> args) {
    if (_disposed) {
      return;
    }
    switch (code) {
      case '52':
        final text = decodeOsc52Payload(args);
        if (text != null) {
          _remoteClipboardWrites.add(text);
        }
      case '7':
        final directory = parseOsc7Directory(args);
        if (directory != null && directory != _workingDirectory) {
          _workingDirectory = directory;
          _workingDirectoryReports.add(directory);
        }
    }
  }

  void _sendTerminalOutput(String data) {
    final normalized = _normalizeEnterOutput(data);
    if (_shouldSuppressDuplicateIosEnter(normalized)) {
      return;
    }
    if (_answeringRemote) {
      // The terminal answering the remote program (device attributes,
      // cursor position, size): it goes back to that program (the Herdr
      // client itself), never to a pane, so it is never held.
      _deliverInput(normalized);
      return;
    }
    if (isMouseReport(normalized)) {
      // A tap or a scroll on the screen the user sees, which is whatever
      // the multiplexer shows: not typed input, so it is never held (nor
      // counted as waiting). Dropped while input is held: the screen is
      // about to change, or shows another place than the session's own.
      if (!_inputHold.holding) _deliverInput(normalized);
      return;
    }
    if (_inputHold.offer(normalized)) {
      return;
    }
    final decision = inputCheck?.call(this);
    if (decision != null) {
      decideInput(decision, blockedLabel: () => _focusElsewhere.value ?? '');
      _inputHold.offer(normalized);
      return;
    }
    _deliverInput(normalized);
  }

  static final _mouseReports = RegExp(
    r'^(?:\x1b\[<\d+;\d+;\d+[Mm]|\x1b\[\d+;\d+;\d+M|\x1b\[M[\s\S]{3})+$',
  );

  /// Whether [data] is only mouse reports (SGR, urxvt or legacy
  /// encodings): wheel notches of a drag, or the terminal's own clicks.
  @visibleForTesting
  static bool isMouseReport(String data) => _mouseReports.hasMatch(data);

  void _deliverInput(String normalized) {
    final session = _session;
    if (session == null) {
      return;
    }

    final bytes = utf8.encode(normalized);
    if (_predictiveEchoEnabled && session is PredictiveTerminalSession) {
      final predictiveSession = session as PredictiveTerminalSession;
      try {
        final inputNum = predictiveSession.sendWithInputState(bytes);
        _predictiveEcho
          ..updateSrtt(predictiveSession.smoothedRtt)
          ..recordInput(
            normalized,
            inputNum: inputNum,
            cursorRow: terminal.absoluteCursorRow,
            cursorColumn: terminal.cursorColumn,
            viewWidth: terminal.viewWidth,
            altScreen: terminal.isUsingAltBuffer,
          );
        _notifyTerminalPaint();
      } catch (error, stackTrace) {
        _handleStreamError(error, stackTrace);
      }
      return;
    }

    unawaited(session.send(bytes).catchError(_handleStreamError));
  }

  bool _shouldSuppressDuplicateIosEnter(String data) {
    if (defaultTargetPlatform != TargetPlatform.iOS || !_isEnterOutput(data)) {
      if (data.isNotEmpty && !_isEnterOutput(data)) {
        _lastIosEnterOutputMs = null;
      }
      return false;
    }

    final now = _inputClock.elapsedMilliseconds;
    final last = _lastIosEnterOutputMs;
    _lastIosEnterOutputMs = now;

    return last != null &&
        now - last <= _iosDuplicateEnterWindow.inMilliseconds;
  }

  bool _isEnterOutput(String data) {
    return data == '\r' || data == '\n' || data == '\r\n';
  }

  String _normalizeEnterOutput(String data) {
    return _isEnterOutput(data) ? _enterSequence.value : data;
  }

  void _writeTerminalOutput(String data) {
    _answeringRemote = true;
    try {
      terminal.write(data);
    } finally {
      _answeringRemote = false;
    }
    if (_predictiveEcho.hasPredictions) {
      _predictiveEcho.removeWhere(_isConfirmedPrediction);
      _notifyTerminalPaint();
    }
  }

  void _notifyTerminalPaint() {
    _terminalPaintNotifier.notifyListeners();
  }

  bool _isConfirmedPrediction(TerminalPrediction prediction) {
    if (prediction.erase) {
      return !_hasTerminalContentAt(prediction.row, prediction.column);
    }
    return _terminalCharacterAt(prediction.row, prediction.column) ==
            prediction.character ||
        _terminalCursorPassed(prediction.row, prediction.column);
  }

  bool _hasTerminalContentAt(int row, int column) {
    return _terminalCharacterAt(row, column) != null;
  }

  String? _terminalCharacterAt(int row, int column) {
    if (row < 0 || row >= terminal.buffer.lines.length) {
      return null;
    }
    final line = terminal.buffer.lines[row];
    if (column < 0 || column >= line.length) {
      return null;
    }
    final codePoint = line.getCodePoint(column);
    return codePoint == 0 ? null : String.fromCharCode(codePoint);
  }

  bool _terminalCursorPassed(int row, int column) {
    final cursorRow = terminal.absoluteCursorRow;
    if (row < cursorRow) {
      return true;
    }
    return row == cursorRow && column < terminal.cursorColumn;
  }

  void _rehome() {
    final session = _session;
    if (session is! RoamingTerminalSession ||
        _status != TerminalConnectionStatus.connected) {
      return;
    }
    final roaming = session as RoamingTerminalSession;
    unawaited(roaming.rehome().catchError(_handleStreamError));
  }

  /// Makes the remote application repaint its whole screen.
  ///
  /// Sending the size the server already has changes nothing: the kernel
  /// only raises SIGWINCH on an actual change, so a same-size window-change
  /// never reaches Herdr, tmux or a TUI. This sends one row fewer and then
  /// the real size, [redrawNudgeDelay] apart, which every full-screen app
  /// answers with a full repaint. Used whenever a session's screen comes
  /// back into view (the app resumes, the terminal page is reopened), so
  /// the phone shows the remote state instead of trusting a local buffer
  /// that may have missed or mis-applied updates while nobody looked.
  void forceResize() {
    final session = _session;
    if (session == null || _status != TerminalConnectionStatus.connected) {
      return;
    }
    final columns = terminal.viewWidth;
    final rows = terminal.viewHeight;
    if (rows < 2) {
      return;
    }
    _resizeTimer?.cancel();
    _resizeTimer = null;
    _resizePending = false;
    _redrawTimer?.cancel();
    session.resize(columns, rows - 1, _pixelWidth, _pixelHeight);
    _sentColumns = columns;
    _sentRows = rows - 1;
    _redrawTimer = Timer(redrawNudgeDelay, () {
      _redrawTimer = null;
      if (_session != session ||
          _status != TerminalConnectionStatus.connected ||
          _disposed) {
        return;
      }
      _pendingColumns = terminal.viewWidth;
      _pendingRows = terminal.viewHeight;
      _flushResize();
    });
  }

  /// Gap between the two halves of [forceResize], so they arrive as two
  /// window changes rather than one the remote coalesces away.
  static const redrawNudgeDelay = Duration(milliseconds: 60);

  /// How long resizes after one sent to the server are gathered into one
  /// (sent when the window closes). At most two sends per window.
  static const resizeCoalesce = Duration(milliseconds: 250);

  void _resizeCooldownEnded() {
    if (!_resizePending) {
      return;
    }
    _resizePending = false;
    _flushResize();
  }

  void _flushResize() {
    final session = _session;
    if (session == null) return;
    if (_pendingColumns == _sentColumns && _pendingRows == _sentRows) {
      return;
    }
    _sentColumns = _pendingColumns;
    _sentRows = _pendingRows;
    if (kDebugMode) {
      debugPrint(
        '[term ${host.name}] -> server ${_pendingColumns}x$_pendingRows',
      );
    }
    session.resize(_pendingColumns, _pendingRows, _pixelWidth, _pixelHeight);
  }

  void _handleStreamError(Object error, [StackTrace? stackTrace]) {
    if (_disposed || _status != TerminalConnectionStatus.connected) {
      return;
    }
    terminal.write('\r\n$error\r\n');
    _status = TerminalConnectionStatus.failed;
    _teardownSession();
    notifyListeners();
  }

  /// Drops the current session after it ended on its own: its listeners
  /// stop (so nothing it still emits reaches the next session's screen)
  /// and its transport closes (the SSH client and its keepalive, the
  /// Mosh UDP socket), which a later Reconnect would otherwise leak.
  ///
  /// With [drainOutput] (the shell exited) stdout and stderr keep writing
  /// until the next [connect] or [dispose]: the shell's last lines can
  /// arrive after its exit is reported.
  void _teardownSession({bool drainOutput = false}) {
    final session = _session;
    _session = null;
    _resizeTimer?.cancel();
    _resizeTimer = null;
    _resizePending = false;
    _redrawTimer?.cancel();
    _redrawTimer = null;
    if (!drainOutput) {
      unawaited(_stdoutSubscription?.cancel());
      unawaited(_stderrSubscription?.cancel());
      _stdoutSubscription = null;
      _stderrSubscription = null;
    }
    unawaited(_doneSubscription?.cancel());
    unawaited(_connectivitySubscription?.cancel());
    unawaited(_echoAckSubscription?.cancel());
    _doneSubscription = null;
    _connectivitySubscription = null;
    _echoAckSubscription = null;
    _predictiveEcho.reset();
    if (session != null) {
      unawaited(session.close().catchError((Object _) {}));
    }
  }

  /// Says why connecting failed: the shared headline and advice for an
  /// unreachable machine or a rejected sign-in, the technical reason
  /// dimmed below it.
  void _failConnect(Object error) {
    final problem = connectionProblemFor(
      error,
      machine: host.name,
      address: host.host,
      retryLabel: 'Reconnect',
    );
    if (problem == null) {
      _fail(
        error is AppFailure ? error.toString() : 'Connection failed: $error',
      );
      return;
    }
    final detail = problem.detail;
    _fail(
      [
        problem.title,
        problem.message,
        if (detail != null) '\x1b[2m${detail.replaceAll('\n', '\r\n')}\x1b[0m',
      ].join('\r\n'),
    );
  }

  void _fail(String message) {
    if (_disposed) {
      return;
    }
    _status = TerminalConnectionStatus.failed;
    terminal.write('\r\n$message\r\n');
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _connectionGeneration += 1;
    _resizeTimer?.cancel();
    _redrawTimer?.cancel();
    unawaited(_stdoutSubscription?.cancel());
    unawaited(_stderrSubscription?.cancel());
    unawaited(_doneSubscription?.cancel());
    unawaited(_connectivitySubscription?.cancel());
    unawaited(_echoAckSubscription?.cancel());
    final session = _session;
    _session = null;
    if (session != null) {
      unawaited(session.close());
    }
    keyboard.dispose();
    _inputHold.dispose();
    _sharedView.dispose();
    _focusElsewhere.dispose();
    _terminalPaintNotifier.dispose();
    _terminalTitle.dispose();
    unawaited(_remoteClipboardWrites.close());
    unawaited(_workingDirectoryReports.close());
    super.dispose();
  }
}

/// Delivers app-written input to a session's own place without its
/// terminal (Herdr: by pane id, so it lands in the session's workspace
/// whatever the shared focus shows). Each call answers false when it
/// cannot, and the session falls back to its terminal.
abstract interface class AppInputRouter {
  Future<bool> sendText(
    TerminalSessionController session,
    String text, {
    required bool submit,
  });

  Future<bool> sendKeys(
    TerminalSessionController session,
    List<TerminalKey> keys,
  );
}

/// What [TerminalSessionController] types into a Mosh session before
/// closing it.
sealed class MoshCloseKeystrokes {
  const MoshCloseKeystrokes();
}

/// tmux: its detach, then `exit` for the shell it returns to.
class MoshCloseTmux extends MoshCloseKeystrokes {
  const MoshCloseTmux(this.detach);

  final List<int> detach;
}

/// Herdr: the machine's detach binding.
class MoshCloseHerdr extends MoshCloseKeystrokes {
  const MoshCloseHerdr(this.detach);

  final List<int> detach;
}

/// A plain shell: Ctrl-D.
class MoshCloseShell extends MoshCloseKeystrokes {
  const MoshCloseShell();
}

/// Nothing is typed; only the transport closes.
class MoshCloseNothing extends MoshCloseKeystrokes {
  const MoshCloseNothing();
}
