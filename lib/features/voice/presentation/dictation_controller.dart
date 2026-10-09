import 'dart:async';

import 'package:conduit/core/telemetry/telemetry.dart';
import 'package:conduit/core/telemetry/telemetry_events.dart';
import 'package:conduit/features/voice/domain/speech_event.dart';
import 'package:conduit/features/voice/domain/speech_recognizer.dart';
import 'package:conduit/features/voice/domain/voice_commands.dart';
import 'package:conduit/features/voice/domain/voice_preferences.dart';
import 'package:flutter/foundation.dart';

enum DictationStatus {
  /// Not listening; tapping the mic starts a session.
  idle,

  /// The system microphone permission dialog is showing.
  requestingPermission,

  /// `start` was issued; waiting for the recognizer to be ready.
  starting,

  /// Capturing audio; partial transcripts are flowing.
  listening,

  /// Audio capture ended (tap or end of speech); waiting for the final
  /// transcript.
  finishing,
}

/// How one dictation session behaves.
class DictationOptions {
  const DictationOptions({
    this.continuous = false,
    this.silenceTimeout = const Duration(seconds: 8),
    this.maxSession = const Duration(minutes: 5),
    this.muteRestartBeeps = false,
    this.waitForSpeech = false,
    this.commands,
    this.commandPause = const Duration(milliseconds: 800),
    this.commandSettle = const Duration(seconds: 1),
  });

  /// One phrase: the session ends when the recognizer hears a pause.
  static const singlePhrase = DictationOptions();

  factory DictationOptions.fromPreferences(VoicePreferences voice) =>
      DictationOptions(
        continuous: voice.continuousDictation,
        silenceTimeout: voice.dictationSilence,
        maxSession: voice.dictationMaxSession,
        muteRestartBeeps: voice.muteRestartBeeps,
        commands: voice.commandWords,
      );

  /// Keep listening across pauses until the user taps stop: the
  /// recognizer is restarted after every phrase and the phrases are joined.
  final bool continuous;

  /// A continuous session pauses itself after this long without speech.
  final Duration silenceTimeout;

  /// A continuous session never runs longer than this.
  final Duration maxSession;

  final bool muteRestartBeeps;

  /// Count [silenceTimeout] only once something was said (the Talk loop
  /// waits for the user to start; it only ends on a pause after speech).
  final bool waitForSpeech;

  /// Spoken commands that end the session ("… send"); null listens for
  /// none. Only a sink with [DictationSink.onCommand] receives them.
  final VoiceCommandWords? commands;

  /// A command counts only after this long without new words before it,
  /// so "when to send" mid-sentence never sends.
  final Duration commandPause;

  /// And only once nothing follows it for this long.
  final Duration commandSettle;
}

/// Why a continuous session stopped on its own.
enum DictationPause { silence, maxSession }

/// Callbacks a dictation session delivers text through. The owner of the
/// text field (composer sheet or inline bar) supplies them when it starts a
/// session, so whichever field the user tapped receives the transcript.
///
/// [onPartial] and [onFinish] always carry the whole session's text so
/// far (every phrase of a continuous session, joined), never a delta.
class DictationSink {
  const DictationSink({
    required this.onBegin,
    required this.onPartial,
    required this.onFinish,
    required this.onCancel,
    this.onTakenOver,
    this.onCommand,
    this.onDiscard,
    this.target,
  });

  final VoidCallback onBegin;
  final ValueChanged<String> onPartial;
  final ValueChanged<String> onFinish;
  final VoidCallback onCancel;

  /// Another controller took the recognizer mid-session, with the text
  /// heard so far. Null delivers it through [onFinish], which suits a
  /// text field; a sink that acts on a finished phrase (Talk sends it)
  /// must not treat a cut-off phrase as one.
  final ValueChanged<String>? onTakenOver;

  /// A trailing spoken command ended the session; [message] is the
  /// session's text without the command words. Null: commands are plain
  /// words.
  final void Function(VoiceCommand command, String message)? onCommand;

  /// The owner threw the session away ([DictationController.discard]);
  /// no text follows.
  final VoidCallback? onDiscard;

  /// What the sink writes into (its text field), so a composer can
  /// discard only its own session.
  final Object? target;
}

/// Joins dictated phrases: one space between them, none before
/// punctuation that belongs to the previous phrase.
String joinDictation(String before, String phrase) {
  final a = before.trimRight();
  final b = phrase.trim();
  if (a.isEmpty) return b;
  if (b.isEmpty) return a;
  if (RegExp(r'^[.,!?;:)\]]').hasMatch(b)) return '$a$b';
  return '$a $b';
}

/// Drives one [SpeechRecognizer] session at a time and exposes its state to
/// the mic button. Errors surface on [message]; a denied microphone
/// permission is remembered on [permissionDenied] so the button can explain
/// itself instead of silently doing nothing.
///
/// In continuous mode (see [DictationOptions.continuous]) Android's
/// recognizer still ends after each pause; the controller restarts it
/// until the user taps stop, [DictationOptions.silenceTimeout] passes
/// without speech (then [pause] says so), or [DictationOptions.maxSession]
/// is reached.
class DictationController extends ChangeNotifier {
  DictationController(
    this._recognizer, {
    required this.language,
    this.options,
    this.tick = const Duration(milliseconds: 250),
  });

  final SpeechRecognizer _recognizer;

  /// Resolves the BCP-47 tag to listen in; empty means the device locale.
  final String Function() language;

  /// Session behaviour when [start] is not given options; null means
  /// [DictationOptions.singlePhrase].
  final DictationOptions Function()? options;

  /// How often a continuous session checks its silence and length limits.
  final Duration tick;

  /// Restarts in a row that may fail as "busy"/"client" before giving up.
  static const _maxRestartRetries = 3;

  /// How long a stop waits for the recognizer's final result.
  static const _finishTimeout = Duration(seconds: 3);

  /// The controller that last started a session. Every controller shares
  /// the one platform recognizer and its event stream, so a chat's own
  /// dictation and the terminal's under it must never listen at once.
  static DictationController? _current;

  DictationStatus _status = DictationStatus.idle;
  bool _available = true;
  bool _permissionDenied = false;
  String? _message;
  DictationSink? _sink;
  StreamSubscription<SpeechEvent>? _subscription;
  bool _disposed = false;

  DictationOptions _options = DictationOptions.singlePhrase;
  String _committed = '';
  String _lastPartial = '';
  bool _stopping = false;
  bool _restarting = false;
  int _restartFailures = 0;
  Duration _silence = Duration.zero;
  Duration _elapsed = Duration.zero;
  Timer? _ticker;
  Timer? _finishTimer;
  DictationPause? _pause;
  double _level = 0;

  /// After a discard or a command the platform may still deliver the
  /// old session's last words; they are dropped until a new session is
  /// ready.
  bool _staleUntilReady = false;

  VoiceCommandWords? _commands;
  String _heard = '';
  List<String> _pausedWords = const [];
  Timer? _pauseTimer;
  Timer? _commandTimer;

  DictationStatus get status => _status;
  bool get isActive => _status != DictationStatus.idle;
  bool get isAvailable => _available;
  bool get permissionDenied => _permissionDenied;

  /// Whether the running (or last) session is continuous.
  bool get continuous => _options.continuous;

  /// Set when a continuous session stopped itself; cleared by the next
  /// start. The mic shows "Paused, tap to continue".
  DictationPause? get pause => _pause;

  /// Input loudness 0..1 while listening (the mic's pulse).
  double get level => _level;

  /// The last error or notice to show near the mic; cleared on the next
  /// start.
  String? get message => _message;

  /// Whether the given sink owns the running session.
  bool owns(DictationSink sink) => identical(_sink, sink);

  /// Probes the platform; without a recognizer the mic is shown muted and
  /// explains itself. Cheap, so the mic re-checks before explaining (the
  /// user may have just installed one).
  Future<void> checkAvailability() async {
    final available = await _recognizer.isAvailable();
    if (_disposed || available == _available) {
      return;
    }
    _available = available;
    notifyListeners();
  }

  /// Opens the system screen where a speech service is chosen; false when
  /// there is none.
  Future<bool> openSpeechSettings() => _recognizer.openSettings();

  /// Starts a session feeding [sink], or stops the running one when [sink]
  /// owns it. A tap on the mic always maps to this.
  Future<void> toggle(DictationSink sink, {DictationOptions? options}) {
    if (_status == DictationStatus.idle) {
      return start(sink, options: options);
    }
    if (owns(sink)) {
      return stop();
    }
    return Future<void>.value();
  }

  Future<void> start(DictationSink sink, {DictationOptions? options}) async {
    if (_status != DictationStatus.idle) {
      return;
    }
    final other = _current;
    _current = this;
    if (other != null && !identical(other, this) && other.isActive) {
      // Keeps what the other session heard, in its own field.
      await other._cancel(takenOver: true);
      // Taken back while waiting (Talk re-listening, another mic tap).
      if (_disposed ||
          _status != DictationStatus.idle ||
          !identical(_current, this)) {
        return;
      }
    }
    Telemetry.instance.track(
      TelemetryEvent.voiceUsed(TelemetryVoice.dictation),
    );
    _message = null;
    _pause = null;
    _sink = sink;
    _options = options ?? this.options?.call() ?? DictationOptions.singlePhrase;
    _committed = '';
    _lastPartial = '';
    _stopping = false;
    _restarting = false;
    _restartFailures = 0;
    _silence = Duration.zero;
    _elapsed = Duration.zero;
    _level = 0;
    _commands = sink.onCommand == null ? null : _options.commands;
    _heard = '';
    // The start of a session counts as a pause: "send" alone sends what
    // was typed.
    _pausedWords = const [];
    if (!await _recognizer.hasPermission()) {
      _setStatus(DictationStatus.requestingPermission);
      final granted = await _recognizer.requestPermission();
      // Discarded while the dialog showed.
      if (_disposed || !identical(_sink, sink)) {
        return;
      }
      if (!granted) {
        _permissionDenied = true;
        _message = 'Microphone access is needed to dictate.';
        _sink = null;
        _setStatus(DictationStatus.idle);
        return;
      }
    }
    _permissionDenied = false;
    _subscription ??= _recognizer.events.listen(_handleEvent);
    sink.onBegin();
    _setStatus(DictationStatus.starting);
    if (_options.continuous) {
      _ticker?.cancel();
      _ticker = Timer.periodic(tick, (_) => _onTick());
    }
    try {
      await _recognizer.start(language: language(), options: _listenOptions());
    } catch (error) {
      _fail('Could not start speech recognition.');
    }
  }

  SpeechListenOptions _listenOptions({bool restart = false}) {
    if (!_options.continuous) {
      return const SpeechListenOptions();
    }
    return SpeechListenOptions(
      continuous: true,
      restart: restart,
      muteRestartBeeps: _options.muteRestartBeeps,
      // Ask for long pauses; recognizers that honour these restart less.
      completeSilenceMillis: 4000,
      possiblyCompleteSilenceMillis: 3000,
      minimumLengthMillis: 10000,
    );
  }

  /// Ends audio capture; the final transcript still arrives.
  Future<void> stop() async {
    if (_status != DictationStatus.starting &&
        _status != DictationStatus.listening) {
      return;
    }
    _setStatus(DictationStatus.finishing);
    if (_options.continuous) {
      _stopping = true;
      _ticker?.cancel();
      // Between phrases no result is coming: do not wait for one.
      _finishTimer?.cancel();
      _finishTimer = Timer(
        _restarting ? Duration.zero : _finishTimeout,
        _complete,
      );
    } else {
      // A recognizer that never sends its result must not leave the mic
      // "finishing" for good: keep what was heard.
      _finishTimer?.cancel();
      _finishTimer = Timer(_finishTimeout, _complete);
    }
    try {
      await _recognizer.stop();
    } catch (error) {
      _fail('Could not stop speech recognition.');
    }
  }

  /// Drops the session, keeping whatever partial text was already inserted.
  Future<void> cancel() => _cancel(takenOver: false);

  /// Throws the session away: its sink gets no more text, not even a late
  /// final result (the composer was sent or cleared, CON-097). With
  /// [target], only a session writing into it.
  Future<void> discard({Object? target}) async {
    if (_status == DictationStatus.idle) {
      return;
    }
    final sink = _sink;
    if (target != null && !identical(sink?.target, target)) {
      return;
    }
    _endSession();
    _staleUntilReady = true;
    _setStatus(DictationStatus.idle);
    sink?.onDiscard?.call();
    try {
      await _recognizer.cancel();
    } catch (_) {
      // Nothing left to release.
    }
  }

  Future<void> _cancel({required bool takenOver}) async {
    if (_status == DictationStatus.idle) {
      return;
    }
    final sink = _sink;
    final text = _sessionText;
    _endSession();
    _setStatus(DictationStatus.idle);
    final takenOverSink = takenOver ? sink?.onTakenOver : null;
    if (takenOverSink != null) {
      takenOverSink(text);
    } else {
      sink?.onFinish(text);
    }
    try {
      await _recognizer.cancel();
    } catch (_) {
      // Nothing left to release.
    }
  }

  String get _sessionText => joinDictation(_committed, _lastPartial);

  void _handleEvent(SpeechEvent event) {
    if (_disposed || _status == DictationStatus.idle) {
      return;
    }
    if (_staleUntilReady) {
      if (event is SpeechReady || event is SpeechListening) {
        _staleUntilReady = false;
      } else if (event is SpeechPartial || event is SpeechResult) {
        return;
      }
    }
    if (_options.continuous) {
      _handleContinuous(event);
      return;
    }
    switch (event) {
      case SpeechReady() || SpeechListening():
        if (_status == DictationStatus.starting) {
          _setStatus(DictationStatus.listening);
        }
      case SpeechEnded():
        if (_status != DictationStatus.finishing) {
          _setStatus(DictationStatus.finishing);
        }
      case SpeechLevel(:final value):
        _setLevel(value);
      case SpeechPartial(:final text):
        _lastPartial = text;
        _sink?.onPartial(text);
        _heardText(text);
      case SpeechResult(:final text):
        final sink = _sink;
        final result = text.isEmpty ? _lastPartial : text;
        final command = _finalCommand(result);
        if (command != null) {
          _runCommand(command);
          return;
        }
        _endSession();
        _setStatus(DictationStatus.idle);
        sink?.onFinish(result);
      case final SpeechError error:
        if (error.isQuiet && _lastPartial.isNotEmpty) {
          // A pause after speaking: keep the partial as the result.
          final sink = _sink;
          final result = _lastPartial;
          _endSession();
          _setStatus(DictationStatus.idle);
          sink?.onFinish(result);
        } else {
          _permissionDenied = error.code == SpeechError.insufficientPermissions;
          _fail(error.isQuiet ? null : error.message);
        }
    }
  }

  void _handleContinuous(SpeechEvent event) {
    switch (event) {
      case SpeechReady():
        _restarting = false;
        _restartFailures = 0;
        if (_status == DictationStatus.starting) {
          _setStatus(DictationStatus.listening);
        }
      case SpeechListening():
        _restarting = false;
        _silence = Duration.zero;
        if (_status == DictationStatus.starting) {
          _setStatus(DictationStatus.listening);
        }
      case SpeechEnded():
        // The phrase ended; its result follows and the session goes on.
        _setLevel(0);
      case SpeechLevel(:final value):
        _setLevel(value);
      case SpeechPartial(:final text):
        if (text != _lastPartial) {
          _silence = Duration.zero;
        }
        _lastPartial = text;
        _sink?.onPartial(_sessionText);
        _heardText(_sessionText);
      case SpeechResult(:final text):
        _committed = joinDictation(
          _committed,
          text.isEmpty ? _lastPartial : text,
        );
        _lastPartial = '';
        _nextPhrase();
      case final SpeechError error:
        _committed = joinDictation(_committed, _lastPartial);
        _lastPartial = '';
        if (error.isQuiet) {
          _nextPhrase();
        } else if (_restarting &&
            (error.code == SpeechError.busy ||
                error.code == SpeechError.client) &&
            _restartFailures < _maxRestartRetries) {
          // The kept recognizer refused the restart; try again shortly
          // with a fresh one.
          _restartFailures += 1;
          _finishTimer?.cancel();
          _finishTimer = Timer(
            Duration(milliseconds: 250 * _restartFailures),
            () => _restart(fresh: true),
          );
        } else if (_stopping || _committed.isNotEmpty) {
          // Keep what was said; say why it ended.
          _permissionDenied = error.code == SpeechError.insufficientPermissions;
          _message ??= _stopping ? null : error.message;
          _complete();
        } else {
          _permissionDenied = error.code == SpeechError.insufficientPermissions;
          _fail(error.message);
        }
    }
  }

  /// A phrase finished: show it, then listen for the next one unless the
  /// session is ending.
  void _nextPhrase() {
    if (_stopping) {
      _complete();
      return;
    }
    _sink?.onPartial(_committed);
    // The recognizer ended the phrase on a pause.
    _heardText(_committed, pause: true);
    _restart();
  }

  /// Watches the session's text for a trailing command: it counts when
  /// the words before it were followed by a pause ([_pausedWords]) and
  /// nothing follows it for [DictationOptions.commandSettle].
  void _heardText(String text, {bool pause = false}) {
    final commands = _commands;
    if (commands == null || (text == _heard && !pause)) {
      return;
    }
    _heard = text;
    _commandTimer?.cancel();
    _commandTimer = null;
    _pauseTimer?.cancel();
    _pauseTimer = null;
    final match = _pausedCommand(text);
    if (match != null) {
      _commandTimer = Timer(_options.commandSettle, () => _runCommand(match));
    }
    if (pause) {
      _pausedWords = normalizeSpeechWords(text);
    } else {
      _pauseTimer = Timer(
        _options.commandPause,
        () => _pausedWords = normalizeSpeechWords(_heard),
      );
    }
  }

  TrailingVoiceCommand? _pausedCommand(String text) {
    final match = _commands?.trailing(text);
    if (match == null ||
        !listEquals(normalizeSpeechWords(match.message), _pausedWords)) {
      return null;
    }
    return match;
  }

  /// The command a session's last words give, once it ends: one already
  /// heard (the recognizer may tidy the words in its final result), or one
  /// that only the final result shows.
  TrailingVoiceCommand? _finalCommand(String text) {
    final commands = _commands;
    if (commands == null) return null;
    return _commandTimer != null
        ? commands.trailing(text)
        : _pausedCommand(text);
  }

  void _runCommand(TrailingVoiceCommand match) {
    if (_status == DictationStatus.idle) {
      return;
    }
    final sink = _sink;
    _endSession();
    _staleUntilReady = true;
    _setStatus(DictationStatus.idle);
    unawaited(_recognizer.cancel().catchError((Object _) {}));
    sink?.onCommand?.call(match.command, match.message);
  }

  void _restart({bool fresh = false}) {
    if (_disposed || _stopping || _status == DictationStatus.idle) {
      return;
    }
    _restarting = true;
    unawaited(
      _recognizer
          .start(
            language: language(),
            options: _listenOptions(restart: !fresh),
          )
          .catchError((Object _) => _complete()),
    );
  }

  void _onTick() {
    if (_status == DictationStatus.idle || _stopping) {
      return;
    }
    _elapsed += tick;
    if (!_options.waitForSpeech || _sessionText.isNotEmpty) {
      _silence += tick;
    }
    if (_elapsed >= _options.maxSession) {
      _autoStop(DictationPause.maxSession);
    } else if (_silence >= _options.silenceTimeout) {
      _autoStop(DictationPause.silence);
    }
  }

  void _autoStop(DictationPause reason) {
    _pause = reason;
    _message = switch (reason) {
      DictationPause.silence =>
        'Paused after ${_options.silenceTimeout.inSeconds} s of silence. '
            'Tap the mic to continue.',
      DictationPause.maxSession =>
        'Stopped after ${_options.maxSession.inMinutes} min. '
            'Tap the mic to continue.',
    };
    unawaited(stop());
  }

  /// Ends a continuous session with everything heard so far.
  void _complete() {
    if (_status == DictationStatus.idle) {
      return;
    }
    final text = _sessionText;
    final command = _finalCommand(text);
    if (command != null) {
      _runCommand(command);
      return;
    }
    final sink = _sink;
    _endSession();
    _setStatus(DictationStatus.idle);
    sink?.onFinish(text);
    // Continuous sessions keep the platform recognizer between phrases.
    unawaited(_recognizer.cancel().catchError((Object _) {}));
  }

  void _endSession() {
    _sink = null;
    _stopping = false;
    _restarting = false;
    _level = 0;
    _ticker?.cancel();
    _ticker = null;
    _finishTimer?.cancel();
    _finishTimer = null;
    _pauseTimer?.cancel();
    _pauseTimer = null;
    _commandTimer?.cancel();
    _commandTimer = null;
    _commands = null;
  }

  void _setLevel(double value) {
    if ((value - _level).abs() < 0.05) {
      return;
    }
    _level = value;
    if (!_disposed) notifyListeners();
  }

  void _fail(String? message) {
    final sink = _sink;
    final continuous = _options.continuous;
    _endSession();
    _message = message;
    _setStatus(DictationStatus.idle);
    sink?.onCancel();
    if (continuous) {
      unawaited(_recognizer.cancel().catchError((Object _) {}));
    }
  }

  void _setStatus(DictationStatus status) {
    if (_disposed) {
      return;
    }
    _status = status;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    if (identical(_current, this)) _current = null;
    _ticker?.cancel();
    _finishTimer?.cancel();
    _pauseTimer?.cancel();
    _commandTimer?.cancel();
    unawaited(_subscription?.cancel());
    if (_status != DictationStatus.idle) {
      unawaited(_recognizer.cancel().catchError((_) {}));
    }
    super.dispose();
  }
}
