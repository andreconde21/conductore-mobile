// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:conduit/core/telemetry/telemetry.dart';
import 'package:conduit/core/telemetry/telemetry_events.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/chat_view/domain/chat_items.dart';
import 'package:conduit/features/voice/domain/voice_answers.dart';
import 'package:conduit/features/voice/presentation/dictation_controller.dart';
import 'package:conduit/features/voice/presentation/read_aloud_controller.dart';
import 'package:flutter/foundation.dart';

/// Where the Talk loop is.
enum TalkPhase {
  /// Not talking.
  off,

  /// The mic is open; what the user says shows live.
  listening,

  /// The user paused: the prompt goes out when the countdown ends unless
  /// they cancel.
  confirming,

  /// The prompt, verdict or option is on its way.
  sending,

  /// Claude is working; the loop stays quiet.
  waiting,

  /// Reading the answer or an announcement; listening follows.
  speaking,
}

/// What the next thing the user says answers.
sealed class TalkTarget {
  const TalkTarget();
}

/// A new prompt for Claude.
class TalkPrompt extends TalkTarget {
  const TalkPrompt();
}

/// A permission request: "allow", "deny" or "always".
class TalkApproval extends TalkTarget {
  const TalkApproval(this.request);

  final PendingPermissionRequest request;
}

/// An AskUserQuestion prompt: an option number or name.
class TalkQuestion extends TalkTarget {
  const TalkQuestion(this.question);

  final ChatQuestion question;

  List<String> get labels => [
    for (final option
        in question.questions.firstOrNull?.options ??
            const <ChatQuestionOption>[])
      option.label,
  ];
}

/// Hands-free conversation with Claude in Chat View: listen (continuous
/// dictation) → after a pause, a short visible countdown, then send →
/// stay quiet while Claude works → read the turn's final answer (or
/// announce an approval or question) → listen again, until [stop].
///
/// Approvals are answered by saying allow, deny or always, questions by
/// an option's number or name (see [VoiceAnswers]). All audio stays on
/// the device where the platform allows: recognition and speech are the
/// phone's own engines (iOS falls back to Apple's recognizer for a
/// language without an on-device model).
///
/// The page feeds [update] after every poll, after [ReadAloudController]
/// has seen the same state (so the answer is already queued).
class TalkController extends ChangeNotifier {
  TalkController({
    required DictationController dictation,
    required ReadAloudController readAloud,
    required this.send,
    required this.decide,
    required this.answer,
    required this.options,
    this.cancelWindow = const Duration(seconds: 2),
    this.turnStartTimeout = const Duration(seconds: 20),
    this.afterSpeechPause = const Duration(milliseconds: 400),
  }) : _dictation = dictation,
       _readAloud = readAloud {
    _sink = DictationSink(
      onBegin: () {},
      onPartial: _onPartial,
      onFinish: _onHeard,
      onCancel: _onDictationFailed,
      onTakenOver: _onTakenOver,
    );
    _readAloud.addListener(_onReadAloudChanged);
  }

  final DictationController _dictation;
  final ReadAloudController _readAloud;

  /// Types a prompt into the session.
  final Future<void> Function(String text) send;

  /// Answers a permission request.
  final Future<void> Function(
    PendingPermissionRequest request,
    PermissionVerdict verdict,
  )
  decide;

  /// Picks option N (1-based) of the open question.
  final Future<void> Function(int number) answer;

  /// Listening options (continuous; its silence is the send pause).
  final DictationOptions Function() options;

  /// How long the user can cancel before a prompt is sent.
  final Duration cancelWindow;

  /// How long to wait for Claude to start after sending before listening
  /// again anyway.
  final Duration turnStartTimeout;

  /// A breath after speaking so the mic does not hear the last word.
  final Duration afterSpeechPause;

  late final DictationSink _sink;
  TalkPhase _phase = TalkPhase.off;
  TalkTarget _target = const TalkPrompt();
  String _transcript = '';
  String? _message;
  Duration _countdown = Duration.zero;
  Timer? _timer;
  bool _disposed = false;

  // Latest thread state from [update].
  List<ChatItem> _items = const [];
  List<PendingPermissionRequest> _pending = const [];
  String? _state;

  // The turn being waited for.
  int _itemsAtSend = 0;
  bool _sawWork = false;

  /// What to do once the reader goes quiet.
  VoidCallback? _afterSpeech;

  /// Saying "That session ended" before the loop stops.
  bool _ending = false;

  /// Spoken when the session the loop talks to ends.
  static const sessionEnded = 'That session ended.';

  /// Shown when another mic takes the recognizer while Talk listens.
  static const takenOver = 'Talk stopped: another microphone is in use.';

  TalkPhase get phase => _phase;
  bool get active => _phase != TalkPhase.off;
  TalkTarget get target => _target;

  /// What the user said so far (live while listening, then the prompt
  /// being confirmed).
  String get transcript => _transcript;

  /// Time left before the prompt is sent (while confirming).
  Duration get countdown => _countdown;

  /// A short note for the panel ("Say allow, deny, or always.").
  String? get message => _message;

  /// Starts the loop by listening.
  void start() {
    if (active || _disposed) return;
    Telemetry.instance.track(TelemetryEvent.voiceUsed(TelemetryVoice.talk));
    _readAloud
      ..stop()
      ..conversation = true;
    _listen();
  }

  /// Ends the loop. Returns what was said but not sent (the page puts it
  /// back in the composer), or null.
  String? stop() {
    if (!active) return null;
    final unsent =
        (_phase == TalkPhase.listening || _phase == TalkPhase.confirming) &&
            _target is TalkPrompt &&
            _transcript.trim().isNotEmpty
        ? _transcript.trim()
        : null;
    _phase = TalkPhase.off;
    _ending = false;
    _timer?.cancel();
    _afterSpeech = null;
    _transcript = '';
    _message = null;
    if (_dictation.isActive) {
      unawaited(_dictation.cancel());
    }
    _readAloud
      ..stop()
      ..conversation = false;
    notifyListeners();
    return unsent;
  }

  /// The thread after a poll. See the class docs.
  void update(
    List<ChatItem> items,
    List<PendingPermissionRequest> pending,
    String? state,
  ) {
    _items = items;
    _pending = pending;
    _state = state;
    if (state == 'ended' && active) {
      _sessionEnded();
      return;
    }
    if (_phase != TalkPhase.waiting) return;
    if (state == 'working' ||
        state == 'needs_permission' ||
        items.length > _itemsAtSend) {
      _sawWork = true;
    }
    if (pending.isNotEmpty) {
      _afterReading(_listen);
      return;
    }
    if (!_sawWork) return;
    if (state == 'waiting_input') {
      _afterReading(_listen);
    }
  }

  /// The agent's session ended: after what is being read, say so once and
  /// stop, rather than listening to a dead session.
  void _sessionEnded() {
    if (_ending) return;
    _ending = true;
    _timer?.cancel();
    _phase = TalkPhase.speaking;
    _message = sessionEnded;
    notifyListeners();
    if (_dictation.isActive) {
      unawaited(_dictation.cancel());
    }
    _readAloud.say(sessionEnded);
    _afterReading(stop);
  }

  void _listen() {
    if (_disposed) return;
    if (_state == 'ended') {
      _sessionEnded();
      return;
    }
    _timer?.cancel();
    _target = _currentTarget();
    _transcript = '';
    _message = switch (_target) {
      TalkApproval() => 'Say allow, deny, or always.',
      TalkQuestion() => 'Say the number or the name.',
      TalkPrompt() => null,
    };
    _phase = TalkPhase.listening;
    notifyListeners();
    if (_dictation.isActive) {
      // Another field is dictating; take over.
      unawaited(_dictation.cancel());
    }
    final started = _dictation.start(
      _sink,
      options: () {
        final base = options();
        return DictationOptions(
          continuous: true,
          silenceTimeout: base.silenceTimeout,
          maxSession: base.maxSession,
          muteRestartBeeps: base.muteRestartBeeps,
          waitForSpeech: true,
        );
      }(),
    );
    unawaited(
      started.then((_) {
        // No microphone permission (or no recognizer): the session never
        // began and no callback will come.
        if (_phase == TalkPhase.listening && !_dictation.owns(_sink)) {
          _onDictationFailed(force: true);
        }
      }),
    );
  }

  TalkTarget _currentTarget() {
    if (_pending.isNotEmpty) return TalkApproval(_pending.first);
    final last = _items.lastOrNull;
    if (last is ChatQuestion &&
        !last.answered &&
        _state == 'waiting_input' &&
        last.questions.isNotEmpty) {
      return TalkQuestion(last);
    }
    return const TalkPrompt();
  }

  void _onPartial(String text) {
    if (_phase != TalkPhase.listening) return;
    _transcript = text;
    notifyListeners();
  }

  void _onHeard(String text) {
    if (_phase != TalkPhase.listening) return;
    final spoken = text.trim();
    _transcript = spoken;
    if (spoken.isEmpty) {
      if (_dictation.pause == DictationPause.maxSession) {
        stop();
      } else {
        _listen();
      }
      return;
    }
    switch (_target) {
      case TalkPrompt() when VoiceAnswers.isMore(spoken) && _readAloud.hasMore:
        // The rest of a brief reply, not a prompt for Claude.
        _phase = TalkPhase.speaking;
        _transcript = '';
        notifyListeners();
        _readAloud.more();
        _afterReading(_listen);
      case TalkPrompt():
        _confirm(spoken);
      case TalkApproval(:final request):
        final verdict = VoiceAnswers.verdict(spoken);
        if (verdict == null) {
          _askAgain('Say allow, deny, or always.');
        } else {
          unawaited(_deliver(() => decide(request, verdict)));
        }
      case final TalkQuestion question:
        final number = VoiceAnswers.option(spoken, question.labels);
        if (number == null) {
          _askAgain('Say the number or the name.');
        } else {
          unawaited(_deliver(() => answer(number)));
        }
    }
  }

  /// Another mic (the terminal's, the voice guide's) took the recognizer:
  /// what was heard is cut off, not a finished sentence, so nothing is
  /// sent and the loop stops rather than fight for the microphone.
  void _onTakenOver(String _) {
    if (_phase != TalkPhase.listening) return;
    stop();
    _message = takenOver;
    notifyListeners();
  }

  void _onDictationFailed({bool force = false}) {
    if (_phase != TalkPhase.listening) return;
    if (force && _transcript.isNotEmpty) return;
    final message = _dictation.message;
    stop();
    _message = message;
    notifyListeners();
  }

  /// Counts down [cancelWindow], then sends [text].
  void _confirm(String text) {
    _phase = TalkPhase.confirming;
    _countdown = cancelWindow;
    notifyListeners();
    const step = Duration(milliseconds: 100);
    _timer?.cancel();
    _timer = Timer.periodic(step, (timer) {
      if (_phase != TalkPhase.confirming) {
        timer.cancel();
        return;
      }
      _countdown -= step;
      if (_countdown <= Duration.zero) {
        timer.cancel();
        unawaited(_deliver(() => send(text)));
      } else {
        notifyListeners();
      }
    });
  }

  /// Skips the rest of the countdown.
  void sendNow() {
    if (_phase != TalkPhase.confirming) return;
    _timer?.cancel();
    final text = _transcript;
    unawaited(_deliver(() => send(text)));
  }

  void _askAgain(String hint) {
    _phase = TalkPhase.speaking;
    _message = hint;
    notifyListeners();
    _readAloud.say(hint);
    _afterReading(_listen);
  }

  Future<void> _deliver(Future<void> Function() action) async {
    _phase = TalkPhase.sending;
    _message = null;
    notifyListeners();
    _itemsAtSend = _items.length;
    _sawWork = false;
    try {
      await action();
    } catch (error) {
      if (_phase != TalkPhase.sending) return;
      final unsent = _transcript;
      stop();
      _message = 'Could not send: $error';
      _transcript = unsent;
      notifyListeners();
      return;
    }
    if (_phase != TalkPhase.sending) return;
    _phase = TalkPhase.waiting;
    notifyListeners();
    _timer?.cancel();
    _timer = Timer(turnStartTimeout, () {
      // Claude never visibly started: listen again rather than hang.
      if (_phase == TalkPhase.waiting && !_sawWork) _afterReading(_listen);
    });
  }

  /// Runs [next] once the reader has finished what it queued.
  void _afterReading(VoidCallback next) {
    _timer?.cancel();
    _phase = TalkPhase.speaking;
    notifyListeners();
    _afterSpeech = next;
    _onReadAloudChanged();
  }

  void _onReadAloudChanged() {
    final next = _afterSpeech;
    if (next == null || _phase != TalkPhase.speaking || _readAloud.busy) {
      return;
    }
    _afterSpeech = null;
    _timer?.cancel();
    _timer = Timer(afterSpeechPause, () {
      if (_phase != TalkPhase.speaking) return;
      if (_readAloud.busy) {
        // Something new started in the pause (the answer landed a poll
        // after the turn ended): opening the mic would cut it off.
        _afterSpeech = next;
        return;
      }
      next();
    });
  }

  @override
  void dispose() {
    stop();
    _disposed = true;
    _timer?.cancel();
    _readAloud.removeListener(_onReadAloudChanged);
    super.dispose();
  }
}
