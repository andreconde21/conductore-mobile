// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:conduit/core/app_failure.dart';
import 'package:conduit/core/telemetry/telemetry.dart';
import 'package:conduit/core/telemetry/telemetry_events.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/voice/domain/speech_text.dart';
import 'package:conduit/features/voice/presentation/dictation_controller.dart';
import 'package:conduit/features/voice/presentation/read_aloud_controller.dart';
import 'package:conduit/features/voice_guide/domain/approval_actions.dart';
import 'package:conduit/features/voice_guide/domain/guide_brain.dart';
import 'package:conduit/features/voice_guide/domain/guide_intent.dart';
import 'package:conduit/features/voice_guide/domain/guide_phrases.dart';
import 'package:conduit/features/voice_guide/domain/guide_ports.dart';
import 'package:conduit/features/voice_guide/domain/guide_preferences.dart';
import 'package:conduit/features/voice_guide/domain/guide_resolver.dart';
import 'package:conduit/features/voice_guide/domain/guide_strings.dart';
import 'package:conduit/features/voice_guide/domain/guide_world.dart';
import 'package:flutter/foundation.dart';

/// Where the guide is.
enum GuidePhase {
  /// Not running.
  off,

  /// The mic is open for a command (or a yes or no).
  listening,

  /// The brain machine is working out what was meant.
  thinking,

  /// Saying something; listening follows.
  speaking,

  /// The mic failed (a call, another app); trying again shortly.
  paused,
}

/// A question waiting for "yes": the action pinned to exactly what was
/// named in the question (a request id, an agent id), so a yes never
/// acts on something else. Checked against the app again on "yes".
class _Confirm {
  const _Confirm(this.intent, {this.safe = const []});

  final GuideIntent intent;

  /// Approve all safe: the requests the question counted.
  final List<({String hostId, String requestId})> safe;
}

/// The voice guide: "Talk to the fleet", hands-free.
///
/// One command at a time: listen (one phrase) → match it on the phone
/// ([GuidePhrases]) or ask the brain machine ([GuideBrain], one action
/// back) → check it against the app as it is now ([GuideResolver] over a
/// fresh [GuideWorld]) → ask for a spoken "yes" when it approves, denies,
/// sends, trusts or switches account → do it → say what happened → listen
/// for the next command. Silence, "stop" or [stop] end it.
///
/// Built to survive a fleet that changes while it talks: every step reads
/// the app again, a confirmed action is re-checked before it runs (the
/// agent may have ended, the request may be answered), a vanished target
/// is said out loud, and nothing is retried in a loop: two unclear answers
/// cancel a question, the mic is retried twice, a session has at most
/// [maxTurns] commands. Speech pauses and resumes around calls like read
/// aloud (it is a [ReadAloudController]).
class GuideController extends ChangeNotifier {
  GuideController({
    required DictationController dictation,
    required ReadAloudController speaker,
    required this.world,
    required this.approvals,
    required this.navigator,
    required this.messenger,
    required this.preferences,
    required this.speechLanguage,
    this.brain,
    this.usage,
    this.accounts,
    this.locked,
    this.afterSpeechPause = const Duration(milliseconds: 400),
    this.retryDelay = const Duration(milliseconds: 1500),
    this.thinkingNotice = const Duration(milliseconds: 2500),
    this.maxTurns = 20,
  }) : _dictation = dictation,
       _speaker = speaker {
    _sink = DictationSink(
      onBegin: () {},
      onPartial: _onPartial,
      onFinish: _onHeard,
      onCancel: _onMicFailed,
    );
    _speaker.addListener(_onSpeakerChanged);
  }

  final DictationController _dictation;
  final ReadAloudController _speaker;

  /// The app now (read again at every step).
  final GuideWorld Function() world;
  final ApprovalActions approvals;
  final GuideNavigator navigator;
  final GuideMessenger messenger;
  final GuidePreferences Function() preferences;

  /// The dictation language (the guide's own, when set, wins).
  final String Function() speechLanguage;

  /// Null: only the phone's own phrases work.
  final GuideBrain? brain;
  final GuideUsageText? usage;

  /// Claude account switching; null (or not available) says so.
  final GuideAccounts? accounts;

  /// True while the app is locked: the guide does nothing then.
  final bool Function()? locked;

  final Duration afterSpeechPause;
  final Duration retryDelay;

  /// Says "One moment" when the brain takes longer than this.
  final Duration thinkingNotice;
  final int maxTurns;

  late final DictationSink _sink;
  GuidePhase _phase = GuidePhase.off;
  String _heard = '';
  String? _said;
  _Confirm? _confirm;
  int _confirmMisses = 0;
  int _micFailures = 0;
  int _turns = 0;

  /// Bumped by [start] and [stop], so answers to an older step are
  /// dropped.
  int _generation = 0;
  Completer<void>? _brainCancel;
  VoidCallback? _afterSpeech;
  Timer? _timer;
  String? _more;
  bool _disposed = false;

  GuidePhase get phase => _phase;
  bool get active => _phase != GuidePhase.off;

  /// What was heard (live while listening).
  String get heard => _heard;

  /// The last thing the guide said.
  String? get said => _said;

  /// A yes or no is expected.
  bool get confirming => _confirm != null;

  GuideStrings get strings {
    final own = preferences().language;
    return GuideStrings.of(own.isNotEmpty ? own : speechLanguage());
  }

  /// Starts the guide (the Guide button, the tile, the headset button).
  /// While it listens this stops it; while it speaks or thinks it stops
  /// that and listens (barge in), keeping an open question.
  void start() {
    if (_disposed) return;
    if (!preferences().enabled) {
      _announce(strings.disabled);
      return;
    }
    if (locked?.call() ?? false) {
      _announce(strings.locked);
      return;
    }
    switch (_phase) {
      case GuidePhase.listening:
        stop();
        return;
      case GuidePhase.thinking || GuidePhase.speaking || GuidePhase.paused:
        _generation++;
        _cancelBrain();
        _timer?.cancel();
        _afterSpeech = null;
        _speaker.stop();
        _listen();
        return;
      case GuidePhase.off:
        Telemetry.instance.track(TelemetryEvent.voiceUsed(TelemetryVoice.talk));
        _generation++;
        _turns = 0;
        _micFailures = 0;
        _confirm = null;
        _more = null;
        _speaker.stop();
        _listen();
    }
  }

  /// Ends the guide at once: no more listening or speaking.
  void stop() {
    if (_phase == GuidePhase.off && _confirm == null) return;
    _generation++;
    _phase = GuidePhase.off;
    _confirm = null;
    _timer?.cancel();
    _afterSpeech = null;
    _cancelBrain();
    if (_dictation.owns(_sink)) {
      unawaited(_dictation.cancel());
    }
    _speaker.stop();
    _heard = '';
    if (!_disposed) notifyListeners();
  }

  /// Says [text] outside a session (the guide is off or locked).
  void _announce(String text) {
    if (_phase != GuidePhase.off) return;
    _said = text;
    _speaker.say(text);
    notifyListeners();
  }

  void _cancelBrain() {
    final cancel = _brainCancel;
    _brainCancel = null;
    if (cancel != null && !cancel.isCompleted) cancel.complete();
  }

  void _listen() {
    if (_disposed) return;
    if (++_turns > maxTurns) {
      _end(strings.off);
      return;
    }
    _timer?.cancel();
    _phase = GuidePhase.listening;
    _heard = '';
    notifyListeners();
    final generation = _generation;
    final started = _dictation.start(
      _sink,
      options: DictationOptions.singlePhrase,
    );
    unawaited(
      started.then((_) {
        // No microphone permission (or no recognizer): the session never
        // began and no callback will come.
        if (generation == _generation &&
            _phase == GuidePhase.listening &&
            !_dictation.owns(_sink) &&
            _heard.isEmpty) {
          _onMicFailed();
        }
      }),
    );
  }

  void _onPartial(String text) {
    if (_phase != GuidePhase.listening) return;
    _heard = text;
    notifyListeners();
  }

  void _onMicFailed() {
    if (_phase != GuidePhase.listening) return;
    if (_dictation.message == null && !_dictation.permissionDenied) {
      // Silence or nothing recognized: an ordinary end, not a failure.
      _onHeard('');
      return;
    }
    if (_dictation.permissionDenied || !_dictation.isAvailable) {
      _end(_dictation.message ?? strings.micBusy);
      return;
    }
    _micFailures += 1;
    if (_micFailures > 2) {
      _end(strings.micBusy);
      return;
    }
    // A call or another app has the mic: try again in a moment.
    _phase = GuidePhase.paused;
    notifyListeners();
    final generation = _generation;
    _timer?.cancel();
    _timer = Timer(retryDelay * _micFailures, () {
      if (generation != _generation || _phase != GuidePhase.paused) return;
      _turns -= 1;
      _listen();
    });
  }

  void _onHeard(String text) {
    if (_phase != GuidePhase.listening) return;
    final spoken = text.trim();
    _heard = spoken;
    if (spoken.isEmpty) {
      if (_confirm != null) {
        _unclearAnswer();
      } else {
        // Silence ends the guide.
        stop();
      }
      return;
    }
    _micFailures = 0;
    final pending = _confirm;
    if (pending != null) {
      switch (GuidePhrases.yesNo(spoken)) {
        case true:
          _confirm = null;
          unawaited(_run(pending.intent, confirmed: pending));
        case false:
          _confirm = null;
          _say(strings.cancelled);
        case null:
          // A new command instead of an answer drops the question.
          final intent = GuidePhrases.match(spoken);
          if (intent != null && intent is! GuideMore) {
            _confirm = null;
            unawaited(_run(intent));
          } else {
            _unclearAnswer();
          }
      }
      return;
    }
    final intent = GuidePhrases.match(spoken);
    if (intent != null && !(brain != null && _namesNothing(intent))) {
      unawaited(_run(intent));
    } else {
      unawaited(_think(spoken));
    }
  }

  /// Whether [intent] names something the app does not know at all ("open
  /// the thing from yesterday"): the brain may understand it better.
  bool _namesNothing(GuideIntent intent) {
    final target = switch (intent) {
      GuideOpen(:final target) => target,
      GuideSend(:final target) => target,
      GuideRead(:final target) => target,
      GuideDecide(:final target) => target,
      GuideShowChat(:final target) => target,
      GuideShowTerminal(:final target) => target,
      GuideTrust(:final target) => target,
      _ => null,
    };
    if (target is! GuideByName) return false;
    return switch (GuideResolver.resolve(target, world())) {
      ResolvedNothing(:final ended) => ended == null,
      _ => false,
    };
  }

  /// Twice unclear (or silent) and the question is cancelled.
  void _unclearAnswer() {
    _confirmMisses += 1;
    if (_confirmMisses >= 2) {
      _confirm = null;
      _say(strings.cancelled);
    } else {
      _say(strings.sayYesOrNo);
    }
  }

  Future<void> _think(String spoken) async {
    final strings = this.strings;
    final brain = this.brain;
    if (brain == null) {
      _say(strings.noBrain);
      return;
    }
    final generation = _generation;
    _phase = GuidePhase.thinking;
    notifyListeners();
    final context = GuideContext.of(
      world(),
      language: strings.code,
      riskOf: approvals.riskOf,
    );
    final cancel = Completer<void>();
    _brainCancel = cancel;
    final notice = Timer(thinkingNotice, () {
      if (generation == _generation && _phase == GuidePhase.thinking) {
        _speaker.say(strings.oneMoment);
      }
    });
    GuideBrainReply reply;
    try {
      reply = await brain.ask(spoken, context.json, cancel: cancel.future);
    } catch (error) {
      reply = GuideBrainFailed(GuideBrainFailed.unreachable, message: '$error');
    }
    notice.cancel();
    if (identical(_brainCancel, cancel)) _brainCancel = null;
    if (generation != _generation || _phase != GuidePhase.thinking) return;
    switch (reply) {
      case final GuideBrainAction answer:
        final fallback = answer.rejected != null && answer.speak.isNotEmpty
            ? answer.speak
            : strings.didNotCatch;
        await _run(context.intentFor(answer, fallback: fallback));
      case GuideBrainFailed(:final reason):
        _say(
          reason == GuideBrainFailed.noBrain
              ? strings.noBrain
              : strings.brainFailed(reason),
        );
    }
  }

  /// Carries out [intent] against the app as it is now. With [confirmed]
  /// the user said yes to exactly this.
  Future<void> _run(GuideIntent intent, {_Confirm? confirmed}) async {
    if (_disposed) return;
    final generation = _generation;
    _phase = GuidePhase.thinking;
    _confirmMisses = 0;
    notifyListeners();
    final s = strings;
    final now = world();
    String? reply;
    try {
      reply = await _perform(intent, now, s, confirmed: confirmed);
    } on AppFailure catch (failure) {
      reply = _failureText(failure.userMessage, s);
    } on UnsupportedError {
      reply = s.failed('not available');
    } catch (error) {
      reply = s.failed('$error');
    }
    if (generation != _generation || _disposed) return;
    if (reply == null) return;
    _say(reply);
  }

  String _failureText(String message, GuideStrings s) {
    final lower = message.toLowerCase();
    if (lower.contains('already answered') || lower.contains('timed out')) {
      return s.requestGone;
    }
    return s.failed(message);
  }

  /// Does [intent]; returns what to say (then listen), or null when it
  /// already arranged what comes next (a question, the end).
  Future<String?> _perform(
    GuideIntent intent,
    GuideWorld now,
    GuideStrings s, {
    _Confirm? confirmed,
  }) async {
    switch (intent) {
      case GuideStop():
        _end(s.ok);
        return null;
      case GuideMore():
        final rest = _more;
        if (rest != null) {
          _more = null;
          return rest;
        }
        return s.nothingMore;
      case GuideHelp():
        return s.help;
      case GuideWhatsWaiting():
        return s.waiting(now);
      case GuideHome():
        await navigator.home();
        return s.home;
      case GuideUsage():
        return usage?.call(s.code) ?? s.noUsage;
      case GuideSay(:final text):
        return text;
      case GuideSwitchAccount(:final account):
        return _switchAccount(account, s, confirmed: confirmed != null);
      case GuideOpen(:final target):
        return _open(target, now, s);
      case GuideShowChat(:final target):
        return _show(target, GuideView.chat, now, s);
      case GuideShowTerminal(:final target):
        return _show(target, GuideView.terminal, now, s);
      case GuideRead(:final target):
        return _read(target, now, s);
      case GuideDecide():
        return _decide(intent, now, s, confirmed: confirmed != null);
      case GuideApproveAllSafe():
        return _approveAllSafe(now, s, confirmed: confirmed);
      case GuideTrust(:final minutes, :final target):
        return _trust(minutes, target, now, s, confirmed: confirmed != null);
      case GuideSend(:final target, :final text):
        return _send(target, text, now, s, confirmed: confirmed != null);
    }
  }

  /// The agent [target] names (null: the one on screen), or what to say
  /// instead.
  (GuideAgent?, String?) _agent(
    GuideRef? target,
    GuideWorld now,
    GuideStrings s,
  ) {
    if (target == null) {
      final agent = now.onScreen;
      if (agent == null) return (null, s.noAgentOnScreen);
      if (agent.ended) return (null, s.ended(agent.label));
      return (agent, null);
    }
    return switch (GuideResolver.resolve(target, now, agentsOnly: true)) {
      ResolvedAgent(:final agent) => (agent, null),
      ResolvedRequest(:final pending) => (pending.agent, null),
      ResolvedAmbiguous(:final agents) => (null, s.ambiguous(agents)),
      ResolvedNothing(:final ended?) => (null, s.ended(ended.label)),
      ResolvedNothing(:final name) => (null, s.notFound(name)),
      ResolvedMachine(:final machine) => (null, s.notFound(machine.name)),
    };
  }

  Future<String> _open(GuideRef target, GuideWorld now, GuideStrings s) async {
    switch (GuideResolver.resolve(target, now)) {
      case ResolvedAgent(:final agent):
        final shown = await navigator.openAgent(agent);
        return shown == null
            ? s.notFound(agent.label)
            : s.opening(s.agentName(agent, now));
      case ResolvedRequest(:final pending):
        await navigator.openAgent(pending.agent);
        return s.opening(s.agentName(pending.agent, now));
      case ResolvedMachine(:final machine):
        final opened = await navigator.openMachine(machine);
        return opened ? s.opening(machine.name) : s.pickOnScreen;
      case ResolvedAmbiguous(:final agents):
        return s.ambiguous(agents);
      case ResolvedNothing(:final ended?):
        return s.ended(ended.label);
      case ResolvedNothing(:final name):
        return s.notFound(name);
    }
  }

  Future<String> _show(
    GuideRef? target,
    GuideView view,
    GuideWorld now,
    GuideStrings s,
  ) async {
    final (agent, problem) = _agent(target, now, s);
    if (agent == null) return problem!;
    final shown = await navigator.openAgent(agent, view: view);
    if (shown == null) return s.notFound(agent.label);
    if (view == GuideView.chat && shown != GuideView.chat) {
      return s.noChat(agent.label);
    }
    return view == GuideView.chat
        ? s.openingChat(agent.label)
        : s.openingTerminal(agent.label);
  }

  String _read(GuideRef? target, GuideWorld now, GuideStrings s) {
    var (agent, problem) = _agent(target, now, s);
    if (agent == null && target == null) {
      // Nothing on screen: the one agent waiting on the user, if exactly
      // one is.
      final waiting = [
        for (final a in now.live)
          if (a.info.state.needsAttention) a,
      ];
      if (waiting.length == 1) agent = waiting.first;
    }
    if (agent == null) return problem!;
    final message = agent.info.lastMessage?.trim() ?? '';
    final speech = message.isEmpty ? '' : SpeechText.fromMarkdown(message);
    if (speech.isEmpty) return s.noReply(agent.label);
    final brief = SpeechText.brief(speech);
    _more = brief.rest;
    return s.replyFrom(agent.label, brief.spoken);
  }

  bool _mustConfirm(GuideIntent intent, ApprovalRisk? risk) {
    if (intent is GuideDecide && intent.allow) {
      if (risk == ApprovalRisk.high) return true;
      return !(preferences().confirm == GuideConfirm.skipLowRisk &&
          risk == ApprovalRisk.low);
    }
    return intent.risky;
  }

  /// Asks [question] and waits for yes or no; [intent] is what "yes" does.
  String? _ask(String question, _Confirm confirm) {
    _confirm = confirm;
    _confirmMisses = 0;
    _say(question);
    return null;
  }

  Future<String?> _decide(
    GuideDecide intent,
    GuideWorld now,
    GuideStrings s, {
    required bool confirmed,
  }) async {
    final target = intent.target;
    GuidePending? pending;
    switch (target) {
      case GuideRequestRef(:final hostId, :final requestId):
        pending = now.request(hostId, requestId);
        if (pending == null) return s.requestGone;
      case null:
        final onScreen = now.onScreen;
        if (onScreen != null &&
            onScreen.pending.isNotEmpty &&
            !onScreen.ended) {
          pending = GuidePending(onScreen, onScreen.pending.first);
        } else {
          final all = now.pending;
          if (all.isEmpty) return s.noRequests;
          if (all.length > 1) return s.severalRequests(all.length);
          pending = all.first;
        }
      default:
        final (agent, problem) = _agent(target, now, s);
        if (agent == null) return problem;
        if (agent.pending.isEmpty) return s.noRequests;
        pending = GuidePending(agent, agent.pending.first);
    }
    final risk = approvals.riskOf(pending.hostId, pending.request);
    if (!confirmed && _mustConfirm(intent, risk)) {
      return _ask(
        intent.allow ? s.confirmApprove(pending) : s.confirmDeny(pending),
        _Confirm(
          GuideDecide(
            allow: intent.allow,
            target: GuideRequestRef(pending.hostId, pending.request.id),
          ),
        ),
      );
    }
    await approvals.decide(
      pending.hostId,
      pending.request,
      intent.allow ? PermissionVerdict.allow : PermissionVerdict.deny,
    );
    return intent.allow ? s.approved : s.denied;
  }

  Future<String?> _approveAllSafe(
    GuideWorld now,
    GuideStrings s, {
    required _Confirm? confirmed,
  }) async {
    if (!approvals.supportsApproveAllSafe) return s.notAvailableApproveAll;
    bool safe(GuidePending p) =>
        approvals.canBatch(p.hostId) &&
        approvals.riskOf(p.hostId, p.request) == ApprovalRisk.low;
    if (confirmed == null) {
      final targets = [
        for (final p in now.pending)
          if (safe(p)) (hostId: p.hostId, requestId: p.request.id),
      ];
      if (targets.isEmpty) return s.noSafeRequests;
      return _ask(
        s.confirmApproveAll(targets.length),
        _Confirm(const GuideApproveAllSafe(), safe: targets),
      );
    }
    // Only what the question counted, still waiting and still low risk.
    final targets = <ApprovalTarget>[
      for (final t in confirmed.safe)
        if (now.request(t.hostId, t.requestId) case final p? when safe(p))
          (hostId: p.hostId, request: p.request),
    ];
    if (targets.isEmpty) return s.requestGone;
    final count = await approvals.approveAllSafe(targets);
    return s.approvedCount(count);
  }

  Future<String?> _trust(
    int minutes,
    GuideRef? target,
    GuideWorld now,
    GuideStrings s, {
    required bool confirmed,
  }) async {
    if (!approvals.supportsTrust) return s.notAvailableTrust;
    // Trust answers a waiting request and lets its kind through for a
    // while (the companion derives the rule from it).
    GuidePending pending;
    if (target is GuideRequestRef) {
      final found = now.request(target.hostId, target.requestId);
      if (found == null) return s.requestGone;
      pending = found;
    } else {
      final (agent, problem) = _agent(target, now, s);
      if (agent == null) return problem;
      if (agent.pending.isEmpty) return s.nothingToTrust(agent.label);
      pending = GuidePending(agent, agent.pending.first);
    }
    if (!approvals.canTrust(pending.hostId)) return s.notAvailableTrust;
    if (approvals.riskOf(pending.hostId, pending.request) ==
        ApprovalRisk.high) {
      return s.trustHighRisk;
    }
    if (!confirmed) {
      return _ask(
        s.confirmTrust(pending, minutes),
        _Confirm(
          GuideTrust(
            minutes,
            GuideRequestRef(pending.hostId, pending.request.id),
          ),
        ),
      );
    }
    await approvals.trust(
      pending.hostId,
      pending.request,
      Duration(minutes: minutes),
    );
    return s.trusted(pending.agent.label, minutes);
  }

  Future<String?> _switchAccount(
    String name,
    GuideStrings s, {
    required bool confirmed,
  }) async {
    final accounts = this.accounts;
    if (accounts == null || !accounts.available) return s.notAvailableAccounts;
    final all = accounts.accounts;
    var best = 0;
    final matches = <GuideAccount>[];
    for (final account in all) {
      final score = GuideResolver.matchScore(name, account.label);
      if (score == 0 || score < best) continue;
      if (score > best) {
        best = score;
        matches.clear();
      }
      matches.add(account);
    }
    if (matches.isEmpty) {
      return s.accountNotFound(name, [for (final a in all) a.label]);
    }
    if (matches.length > 1) {
      return s.accountAmbiguous([for (final a in matches) a.label]);
    }
    final account = matches.single;
    if (account.targets.isEmpty) {
      return account.active
          ? s.accountAlreadyActive(account.label)
          : s.accountCannotSwitch(account.label);
    }
    final machines = [for (final t in account.targets) t.hostName];
    if (!confirmed) {
      // The exact label, so yes switches to this account and no other.
      return _ask(
        s.confirmAccount(account.label, machines),
        _Confirm(GuideSwitchAccount(account.label)),
      );
    }
    final results = await accounts.switchTo(account);
    final failed = [
      for (final r in results)
        if (!r.ok) r,
    ];
    if (failed.isEmpty) return s.accountSwitched(account.label, machines);
    return s.failed(
      failed.map((r) => '${r.hostName}: ${r.error ?? 'no reply'}').join('; '),
    );
  }

  Future<String?> _send(
    GuideRef target,
    String text,
    GuideWorld now,
    GuideStrings s, {
    required bool confirmed,
  }) async {
    final (agent, problem) = _agent(target, now, s);
    if (agent == null) return problem;
    if (!confirmed) {
      return _ask(
        s.confirmSend(agent.label, text),
        _Confirm(GuideSend(GuideAgentRef(agent.hostId, agent.id), text)),
      );
    }
    await messenger.send(agent, text);
    return s.sent;
  }

  /// Says [text], then listens.
  void _say(String text) {
    _phase = GuidePhase.speaking;
    _said = text;
    notifyListeners();
    _speaker.say(text);
    _afterReading(_listen);
  }

  /// Says [text], then turns off.
  void _end(String text) {
    _confirm = null;
    _phase = GuidePhase.speaking;
    _said = text;
    notifyListeners();
    _speaker.say(text);
    _afterReading(stop);
  }

  /// Runs [next] once the speaker has finished what it queued.
  void _afterReading(VoidCallback next) {
    _timer?.cancel();
    _afterSpeech = next;
    _onSpeakerChanged();
  }

  void _onSpeakerChanged() {
    final next = _afterSpeech;
    if (next == null || _phase != GuidePhase.speaking || _speaker.busy) {
      return;
    }
    _afterSpeech = null;
    _timer?.cancel();
    final generation = _generation;
    _timer = Timer(afterSpeechPause, () {
      if (generation != _generation || _phase != GuidePhase.speaking) return;
      if (_speaker.busy) {
        // Something new started in the pause: opening the mic would cut
        // it off.
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
    _speaker.removeListener(_onSpeakerChanged);
    super.dispose();
  }
}
