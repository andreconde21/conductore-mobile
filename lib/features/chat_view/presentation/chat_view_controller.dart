// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:conduit/core/app_failure.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/chat_view/data/conductore_chat_client.dart';
import 'package:conduit/features/chat_view/domain/chat_items.dart';
import 'package:conduit/features/chat_view/domain/chat_outgoing.dart';
import 'package:conduit/features/chat_view/domain/chat_transcript.dart';
import 'package:conduit/features/voice/domain/speech_summary.dart';
import 'package:flutter/foundation.dart';

/// Answers a pending permission request (the agent attention decide flow).
typedef ChatDecide =
    Future<void> Function(
      PendingPermissionRequest request,
      PermissionVerdict verdict,
    );

/// What the header says the agent is doing.
enum ChatActivity { thinking, working, needsApproval, waiting, idle, ended }

extension ChatActivityLabel on ChatActivity {
  String get label => switch (this) {
    ChatActivity.thinking => 'Thinking…',
    ChatActivity.working => 'Working…',
    ChatActivity.needsApproval => 'Needs approval',
    ChatActivity.waiting => 'Waiting for you',
    ChatActivity.idle => 'Idle',
    ChatActivity.ended => 'Ended',
  };
}

/// Live chat view of one Claude Code session on one host.
///
/// Polls `conductore-hostd transcript --since <offset>` every
/// [pollInterval] while visible (each reply also carries the agent's state
/// and pending permission requests), and polls early when [agentChanges]
/// fires (the attention controller's companion long-poll saw this session
/// change). The first load reads only the transcript's tail; [loadOlder]
/// pages backwards on demand. Prompts are typed into the live session with
/// `send`, so the TUI and the chat always show the same conversation.
///
/// A prompt sent from here shows at once as an [outgoing] bubble (sending,
/// sent, failed) and is replaced by the transcript's own entry when a poll
/// brings it. Sends go out one at a time, in order.
class ChatViewController extends ChangeNotifier {
  ChatViewController({
    required AgentCommandRunner runner,
    required this.sessionId,
    this.fallbackName,
    ChatDecide? decide,
    Listenable? agentChanges,
    bool ownsRunner = false,
    Duration pollInterval = const Duration(milliseconds: 1500),
    Duration? workingPollInterval,
    int tailBytes = ConductoreChatClient.defaultTailBytes,
    this.lateAfter = const Duration(minutes: 2),
    DateTime Function()? clock,
  }) : _runner = runner,
       _clock = clock ?? DateTime.now,
       _client = ConductoreChatClient(runner),
       _decide = decide,
       _agentChanges = agentChanges,
       _ownsRunner = ownsRunner,
       _pollInterval = pollInterval,
       _workingPollInterval =
           workingPollInterval ??
           Duration(microseconds: pollInterval.inMicroseconds * 2 ~/ 3),
       _tailBytes = tailBytes {
    _agentChanges?.addListener(_onAgentChanged);
  }

  final String sessionId;

  /// How long a sent prompt may stay out of the transcript before its
  /// bubble says so.
  final Duration lateAfter;
  final DateTime Function() _clock;

  /// Name to show before the first reply arrives.
  final String? fallbackName;

  final AgentCommandRunner _runner;
  final ConductoreChatClient _client;
  final ChatDecide? _decide;
  final Listenable? _agentChanges;
  final bool _ownsRunner;
  final Duration _pollInterval;

  /// Faster cadence while the agent works, so the live activity label
  /// keeps up (1 s by default).
  final Duration _workingPollInterval;
  Duration? _timerInterval;
  final int _tailBytes;

  /// Upper bound on follow-up reads in one poll while catching up with a
  /// transcript that grew by more than one read.
  static const _maxCatchUpReads = 8;

  final List<TranscriptEntry> _entries = [];
  List<ChatItem> _items = const [];
  int? _offset;
  int _start = 0;
  bool _olderExhausted = false;
  bool _loading = true;
  bool _loadingOlder = false;
  bool _sending = false;
  String? _error;
  String? _unsupported;
  ChatUnsupportedKind? _unsupportedKind;
  ChatAgentStatus? _agent;
  final Set<String> _deciding = {};

  final List<_Outgoing> _outgoing = [];
  int _outgoingCount = 0;
  Future<void> _sendQueue = Future.value();

  /// Confirmed bubbles kept (a thread frozen above the real entry still
  /// shows them).
  static const _keptConfirmed = 10;

  /// A transcript entry older than this before a send cannot be it (for
  /// when the send had nothing in the thread to anchor to).
  static const _clockSkew = Duration(minutes: 10);

  Timer? _timer;
  Future<void>? _inFlight;
  bool _pollAgain = false;
  bool _visible = false;
  bool _disposed = false;

  List<ChatItem> get items => _items;

  /// Prompts and answers sent from this view, oldest first: pending ones
  /// (sending, sent, failed) and the last few confirmed ones.
  List<ChatOutgoing> get outgoing {
    final now = _clock();
    return [
      for (final o in _outgoing)
        ChatOutgoing(
          id: o.id,
          text: o.shown,
          state: o.state,
          error: o.error,
          answer: o.questionId != null,
          confirmedId: o.confirmedId,
          late:
              o.confirmedId == null &&
              o.state == ChatSendState.sent &&
              now.difference(o.sentAt!) >= lateAfter,
        ),
    ];
  }

  /// Whether an answer to question [questionId] is on its way.
  bool isAnswering(String questionId) => _outgoing.any(
    (o) =>
        o.questionId == questionId &&
        o.confirmedId == null &&
        o.state != ChatSendState.failed,
  );
  ChatAgentStatus? get agent => _agent;
  bool get loading => _loading;
  bool get loadingOlder => _loadingOlder;
  bool get sending => _sending;

  /// Last poll failure (the view keeps showing what it has).
  String? get error => _error;

  /// Set when the companion is missing or too old; polling has stopped.
  String? get unsupported => _unsupported;

  /// Whether [unsupported] means missing or outdated.
  ChatUnsupportedKind? get unsupportedKind => _unsupportedKind;

  /// Whether older lines exist before the loaded window.
  bool get hasOlder => _start > 0 && !_olderExhausted;

  /// Older lines exist but cannot be shown here (they only fit the TUI).
  bool get olderOnlyInTerminal => _start > 0 && _olderExhausted;

  bool isDeciding(String requestId) => _deciding.contains(requestId);

  String get name => _agent?.name ?? fallbackName ?? 'Claude';

  List<PendingPermissionRequest> get pending => _agent?.pending ?? const [];

  /// When the session started: the first line when the whole transcript is
  /// loaded, else when the companion first saw it.
  DateTime? get startedAt {
    if (_start == 0) {
      for (final entry in _entries) {
        if (entry.timestamp != null) {
          return entry.timestamp;
        }
      }
    }
    return _agent?.startedAt;
  }

  ChatActivity? get activity {
    final agent = _agent;
    if (agent == null) {
      return null;
    }
    switch (agent.state) {
      case 'ended':
        return ChatActivity.ended;
      case 'needs_permission':
        return ChatActivity.needsApproval;
      case 'waiting_input':
        final last = _items.lastOrNull;
        if (last is ChatQuestion && !last.answered ||
            last is ChatPlan && last.status == ChatPlanStatus.pending) {
          return ChatActivity.waiting;
        }
        return ChatActivity.idle;
      case 'working':
        final last = _items.lastOrNull;
        if (last is ChatToolCall && last.running) {
          return ChatActivity.working;
        }
        if (last == null || last is ChatThinking || last is ChatUserMessage) {
          return ChatActivity.thinking;
        }
        return ChatActivity.working;
    }
    return ChatActivity.idle;
  }

  /// Whether typing into the session is currently allowed: the host
  /// refuses while a permission prompt waits and after the session ended.
  bool get canSend {
    final state = _agent?.state;
    return _unsupported == null &&
        state != 'ended' &&
        state != 'needs_permission';
  }

  /// Starts (or resumes) polling while the view is on screen, and pauses
  /// it when hidden (app backgrounded, route covered).
  void setVisible(bool visible) {
    if (_disposed || _visible == visible) {
      return;
    }
    _visible = visible;
    _timer?.cancel();
    _timer = null;
    _timerInterval = null;
    if (visible && _unsupported == null) {
      _retime();
      unawaited(refresh());
    }
  }

  /// Polls every second while the agent works, at the idle pace otherwise.
  void _retime() {
    if (!_visible || _unsupported != null || _disposed) {
      return;
    }
    final activity = this.activity;
    final interval =
        activity == ChatActivity.working || activity == ChatActivity.thinking
        ? _workingPollInterval
        : _pollInterval;
    if (_timer != null && _timerInterval == interval) {
      return;
    }
    _timer?.cancel();
    _timerInterval = interval;
    _timer = Timer.periodic(interval, (_) => unawaited(refresh()));
  }

  /// Reads whatever is new now. Concurrent calls share one read; a call
  /// arriving mid-read schedules exactly one more.
  Future<void> refresh() {
    final running = _inFlight;
    if (running != null) {
      _pollAgain = true;
      return running;
    }
    final future = _poll().whenComplete(() {
      _inFlight = null;
      if (_pollAgain && !_disposed) {
        _pollAgain = false;
        unawaited(refresh());
      }
    });
    _inFlight = future;
    return future;
  }

  Future<void> _poll() async {
    if (_disposed || _unsupported != null) {
      return;
    }
    try {
      var reads = 0;
      while (true) {
        final offset = _offset;
        final page = offset == null
            ? await _client.transcript(sessionId, tailBytes: _tailBytes)
            : await _client.transcript(sessionId, since: offset);
        if (_disposed) {
          return;
        }
        if (offset == null || page.reset) {
          _entries
            ..clear()
            ..addAll(page.entries);
          _start = page.start;
          _olderExhausted = false;
        } else {
          _entries.addAll(page.entries);
        }
        final grew = page.entries.isNotEmpty || offset == null || page.reset;
        _offset = page.offset;
        var changed = grew || _error != null || _loading;
        if (page.agent case final agent? when agent != _agent) {
          _agent = agent;
          changed = true;
        }
        if (grew) {
          _items = ChatItemBuilder.build(_entries);
          _confirmOutgoing();
        }
        _error = null;
        _loading = false;
        _retime();
        // A poll that brought nothing (most of them) rebuilds nothing.
        if (changed) notifyListeners();
        reads += 1;
        if (page.offset >= page.size ||
            page.offset == offset ||
            reads >= _maxCatchUpReads) {
          break;
        }
      }
    } on ChatUnsupported catch (error) {
      _unsupported = error.message;
      _unsupportedKind = error.kind;
      _loading = false;
      _timer?.cancel();
      _timer = null;
      if (!_disposed) notifyListeners();
    } catch (error) {
      _error = _describe(error);
      _loading = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// Loads the lines before the current window. No-op when there are none
  /// or a load is running.
  Future<void> loadOlder() async {
    if (!hasOlder || _loadingOlder || _disposed) {
      return;
    }
    _loadingOlder = true;
    notifyListeners();
    try {
      final page = await _client.transcript(
        sessionId,
        before: _start,
        maxBytes: _tailBytes,
      );
      if (_disposed) {
        return;
      }
      if (page.start >= _start && page.entries.isEmpty) {
        // Nothing parseable before (e.g. one huge line): stop offering it.
        _olderExhausted = true;
      } else {
        _entries.insertAll(0, page.entries);
        _start = page.start;
        _items = ChatItemBuilder.build(_entries);
      }
    } catch (error) {
      _error = _describe(error);
    } finally {
      _loadingOlder = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// Types [text] into the session and presses Enter, showing it at once
  /// as an [outgoing] bubble. Sends queue up and go out in order. Throws an
  /// [AppFailure] when it could not be sent; the bubble then shows the
  /// failure with the text kept for [retry] or [discard].
  ///
  /// With [enter] false the text is only typed (no bubble: nothing was
  /// submitted).
  Future<void> send(String text, {bool enter = true}) {
    if (!enter) {
      return _type(text, enter: false);
    }
    if (text.trim().isEmpty) {
      return Future.value();
    }
    return _queue(_Outgoing(_nextOutgoingId(), text, _snapshot()));
  }

  /// Sends a failed message again, as a new bubble at the bottom.
  Future<void> retry(String outgoingId) {
    final index = _outgoing.indexWhere(
      (o) => o.id == outgoingId && o.state == ChatSendState.failed,
    );
    if (index == -1) {
      return Future.value();
    }
    final old = _outgoing.removeAt(index);
    if (old.questionId != null) {
      return answerQuestion(old.number!, label: old.label);
    }
    return send(old.text);
  }

  /// Drops a failed message and returns its text (for editing), or null.
  String? discard(String outgoingId) {
    final index = _outgoing.indexWhere(
      (o) => o.id == outgoingId && o.state == ChatSendState.failed,
    );
    if (index == -1) {
      return null;
    }
    final old = _outgoing.removeAt(index);
    notifyListeners();
    return old.questionId != null ? null : old.text;
  }

  String _nextOutgoingId() => 'outgoing-${_outgoingCount++}';

  /// What the thread holds now, to tell a new entry from an old one.
  _Snapshot _snapshot() => _Snapshot(
    anchor: _items.lastOrNull?.id,
    known: {for (final item in _items) item.id},
    at: _clock(),
  );

  Future<void> _queue(_Outgoing outgoing) {
    _outgoing.add(outgoing);
    notifyListeners();
    final done = Completer<void>();
    // Keep the chain alive past a failure.
    _sendQueue = _sendQueue.then((_) async {
      if (outgoing.state == ChatSendState.failed) {
        // An earlier message failed: this one was not typed either.
        done.completeError(AppFailure(outgoing.error!));
        return;
      }
      try {
        await _client.send(sessionId, outgoing.text, enter: outgoing.enter);
        outgoing
          ..state = ChatSendState.sent
          ..sentAt = _clock();
        done.complete();
        if (!_disposed) {
          notifyListeners();
          unawaited(refresh());
        }
      } catch (error) {
        final failure = switch (error) {
          ChatUnsupported(:final message) => AppFailure(message),
          AppFailure() => error,
          _ => AppFailure(_describe(error)),
        };
        _fail(outgoing, failure.userMessage);
        done.completeError(failure);
      }
    });
    return done.future;
  }

  /// Marks [outgoing] failed, and every send queued behind it: typing
  /// those now would put them before it.
  void _fail(_Outgoing outgoing, String error) {
    outgoing
      ..state = ChatSendState.failed
      ..error = error;
    final index = _outgoing.indexOf(outgoing);
    for (final later in _outgoing.skip(index + 1)) {
      if (later.state == ChatSendState.sending) {
        later
          ..state = ChatSendState.failed
          ..error = 'Not sent: the message before it failed.';
      }
    }
    if (!_disposed) notifyListeners();
  }

  /// Pairs pending bubbles with the transcript entries that show them, in
  /// send order, each entry used once.
  void _confirmOutgoing() {
    if (_outgoing.isEmpty) {
      return;
    }
    final claimed = {for (final o in _outgoing) ?o.confirmedId};
    // Failed ones too: a send that timed out may have been typed after all.
    for (final o in _outgoing) {
      if (o.confirmedId != null) {
        continue;
      }
      final questionId = o.questionId;
      if (questionId != null) {
        final question = _items.where((item) => item.id == questionId);
        if (question.isEmpty ||
            question.first is ChatQuestion &&
                (question.first as ChatQuestion).answered) {
          o.confirmedId = questionId;
        }
        continue;
      }
      var from = 0;
      final anchor = o.before.anchor;
      if (anchor != null) {
        from = _items.indexWhere((item) => item.id == anchor) + 1;
      }
      for (var i = from; i < _items.length; i++) {
        final item = _items[i];
        if (claimed.contains(item.id) || o.before.known.contains(item.id)) {
          continue;
        }
        if (from == 0 && _tooOld(item, o.before.at)) {
          continue;
        }
        if (ChatOutgoingMatch.matches(o.text, item)) {
          o.confirmedId = item.id;
          claimed.add(item.id);
          break;
        }
      }
    }
    // Keep only the last few confirmed ones.
    var confirmed = _outgoing.where((o) => o.confirmedId != null).length;
    _outgoing.removeWhere(
      (o) => o.confirmedId != null && confirmed-- > _keptConfirmed,
    );
  }

  static bool _tooOld(ChatItem item, DateTime sentAt) {
    final at = switch (item) {
      ChatUserMessage(:final timestamp) => timestamp,
      ChatShellCommand(:final timestamp) => timestamp,
      _ => null,
    };
    return at != null && at.isBefore(sentAt.toUtc().subtract(_clockSkew));
  }

  /// Types [text] without a bubble (a partial prompt, a menu key).
  Future<void> _type(String text, {required bool enter}) async {
    _sending = true;
    notifyListeners();
    try {
      await _client.send(sessionId, text, enter: enter);
    } on ChatUnsupported catch (error) {
      throw AppFailure(error.message);
    } finally {
      _sending = false;
      if (!_disposed) notifyListeners();
    }
    unawaited(refresh());
  }

  /// A short spoken summary of [text] by Claude on this chat's machine,
  /// through the chat's own connection (see
  /// [ConductoreChatClient.summarize]).
  Future<SpeechSummaryResult> summarize(String text, {Future<void>? cancel}) {
    if (_disposed) {
      return Future.value(
        const SpeechSummaryFailed(SpeechSummaryFailed.unreachable),
      );
    }
    return _client.summarize(text, cancel: cancel);
  }

  /// Presses Escape in the session (interrupts the current turn).
  Future<void> interrupt() async {
    try {
      await _client.interrupt(sessionId);
    } on ChatUnsupported catch (error) {
      throw AppFailure(error.message);
    }
    unawaited(refresh());
  }

  /// Picks option [number] (1-based) of an open AskUserQuestion prompt by
  /// typing its number, as the terminal's menu accepts. When the thread
  /// shows the open question, the answer shows at once as an [outgoing]
  /// bubble ([label]: the option's text) until the question is answered.
  Future<void> answerQuestion(int number, {String? label}) {
    final question = _items.lastOrNull;
    if (question is! ChatQuestion || question.answered) {
      return _type('$number', enter: false);
    }
    return _queue(
      _Outgoing(
        _nextOutgoingId(),
        '$number',
        _snapshot(),
        enter: false,
        questionId: question.id,
        number: number,
        label: label,
      ),
    );
  }

  Future<void> decide(
    PendingPermissionRequest request,
    PermissionVerdict verdict,
  ) async {
    final decide = _decide;
    if (decide == null) {
      throw const AppFailure(
        'Permission requests cannot be answered from this view.',
      );
    }
    if (!_deciding.add(request.id)) {
      return;
    }
    notifyListeners();
    try {
      await decide(request, verdict);
      // Drop it locally at once; the next poll confirms.
      final agent = _agent;
      if (agent != null) {
        _agent = ChatAgentStatus(
          state: agent.pending.length > 1 ? agent.state : 'working',
          lastEvent: agent.lastEvent,
          lastToolName: agent.lastToolName,
          name: agent.name,
          lastMessage: agent.lastMessage,
          startedAt: agent.startedAt,
          updatedAt: agent.updatedAt,
          endedAt: agent.endedAt,
          pending: [
            for (final p in agent.pending)
              if (p.id != request.id) p,
          ],
        );
      }
    } finally {
      _deciding.remove(request.id);
      if (!_disposed) notifyListeners();
    }
    unawaited(refresh());
  }

  void _onAgentChanged() {
    if (_visible && !_disposed) {
      unawaited(refresh());
    }
  }

  static String _describe(Object error) =>
      error is AppFailure ? error.userMessage : error.toString();

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _agentChanges?.removeListener(_onAgentChanged);
    if (_ownsRunner) {
      unawaited(_runner.close());
    }
    super.dispose();
  }
}

/// The thread when a message was sent.
class _Snapshot {
  const _Snapshot({
    required this.anchor,
    required this.known,
    required this.at,
  });

  /// The last item then; the message's entry can only come after it.
  final String? anchor;
  final Set<String> known;
  final DateTime at;
}

class _Outgoing {
  _Outgoing(
    this.id,
    this.text,
    this.before, {
    this.enter = true,
    this.questionId,
    this.number,
    this.label,
  });

  final String id;
  final String text;
  final _Snapshot before;
  final bool enter;

  /// For an answer: the question, the option picked and its label.
  final String? questionId;
  final int? number;
  final String? label;

  ChatSendState state = ChatSendState.sending;
  DateTime? sentAt;
  String? error;
  String? confirmedId;

  String get shown => label == null ? text : '$number. $label';
}
