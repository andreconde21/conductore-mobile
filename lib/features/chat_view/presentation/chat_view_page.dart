import 'dart:async';

import 'package:conduit/core/app_failure.dart';
import 'package:conduit/core/platform_features.dart';
import 'package:conduit/core/telemetry/telemetry.dart';
import 'package:conduit/core/telemetry/telemetry_events.dart';
import 'package:conduit/core/theme/theme_controller.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/agent_attention/presentation/approval_sheets.dart';
import 'package:conduit/features/chat_view/data/conductore_chat_client.dart';
import 'package:conduit/features/chat_view/data/platform_text_share.dart';
import 'package:conduit/features/chat_view/domain/chat_items.dart';
import 'package:conduit/features/chat_view/domain/chat_outgoing.dart';
import 'package:conduit/features/chat_view/domain/chat_tool_activity.dart';
import 'package:conduit/features/chat_view/domain/chat_working.dart';
import 'package:conduit/features/chat_view/presentation/chat_forward.dart';
import 'package:conduit/features/chat_view/presentation/chat_thread_extras.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_controller.dart';
import 'package:conduit/features/chat_view/presentation/widgets/chat_composer.dart';
import 'package:conduit/features/chat_view/presentation/widgets/chat_injected_items.dart';
import 'package:conduit/features/chat_view/presentation/widgets/chat_thread_items.dart';
import 'package:conduit/features/chat_view/presentation/widgets/chat_working_indicator.dart';
import 'package:conduit/features/chat_view/presentation/widgets/talk_panel.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/review/presentation/review_launcher.dart';
import 'package:conduit/features/terminal/data/platform_prompt_image_source.dart';
import 'package:conduit/features/terminal/domain/clipboard_image_paste.dart';
import 'package:conduit/features/terminal/domain/prompt_image.dart';
import 'package:conduit/features/terminal/presentation/widgets/prompt_composer_sheet.dart';
import 'package:conduit/features/voice/data/platform_speech_recognizer.dart';
import 'package:conduit/features/voice/data/platform_text_to_speech.dart';
import 'package:conduit/features/voice/domain/speech_recognizer.dart';
import 'package:conduit/features/voice/domain/text_to_speech.dart';
import 'package:conduit/features/voice/domain/voice_preferences.dart';
import 'package:conduit/features/voice/presentation/dictation_controller.dart';
import 'package:conduit/features/voice/presentation/read_aloud_controller.dart';
import 'package:conduit/features/voice/presentation/talk_controller.dart';
import 'package:conduit/features/voice/presentation/voice_services.dart';
import 'package:conduit/features/voice/presentation/voice_settings_scope.dart';
import 'package:conduit/features/voice_guide/presentation/app_guide.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// A native chat over one live Claude Code session: the transcript as
/// bubbles and tool cards, permission prompts answered in the thread, and a
/// composer that types into the same session the terminal shows.
class ChatViewPage extends StatefulWidget {
  const ChatViewPage({
    required this.controller,
    required this.onOpenTerminal,
    this.hostName,
    this.dictation,
    this.speechRecognizer,
    this.ownsController = true,
    this.onSetUpCompanion,
    this.onEnableMonitoring,
    this.textToSpeech,
    this.accessory,
    this.initialDraft = '',
    this.imageAttacher,
    this.pasteImages = true,
    this.clipboardHasImage = PlatformPromptImageSource.clipboardHasImage,
    this.attention,
    this.hostId,
    this.forwardTargets,
    this.onForward,
    this.share = PlatformTextShare.share,
    super.key,
  });

  final ChatViewController controller;

  /// Leaves the chat for the full TUI of the same session.
  final VoidCallback onOpenTerminal;
  final String? hostName;

  /// The opener's dictation (the terminal's), so one recognizer serves
  /// both. Null: the page makes its own from [speechRecognizer], so the mic
  /// and Talk are there however the chat was opened.
  final DictationController? dictation;

  /// Backs the page's own dictation when [dictation] is null; defaults to
  /// the on-device recognizer where there is one (tests inject one).
  final SpeechRecognizer? speechRecognizer;

  /// Disposes [controller] with the page.
  final bool ownsController;

  /// Opens the Agent hooks screen from the "not installed / too old"
  /// state; null hides the button.
  final VoidCallback? onSetUpCompanion;

  /// Turns agent monitoring on for this machine (approval notifications,
  /// the Agents panel and live updates need it). Non-null only while it is
  /// off; the banner offering it hides once tapped.
  final Future<void> Function()? onEnableMonitoring;

  /// Speaks replies when "Read replies aloud" is on; defaults to the
  /// on-device engine on Android and iOS and to none elsewhere (tests
  /// inject one).
  final TextToSpeech? textToSpeech;

  /// A small widget pinned above the composer (the "Preview ready" chip).
  final Widget? accessory;

  /// What the composer starts with.
  final String initialDraft;

  /// Images for the prompt (the full composer's image button, and pasting
  /// an image in the inline field); null hides both.
  final PromptImageAttacher? imageAttacher;

  /// "Paste images as uploaded files": off keeps paste text-only.
  final bool pasteImages;

  /// Whether the clipboard holds an image (offers "Paste image").
  final Future<bool> Function() clipboardHasImage;

  /// The agent monitor and this chat's host: when the host's companion
  /// keeps approval rules, approval cards offer "Trust…" and "Always"
  /// saves a companion rule (see [answerPermissionRequest]).
  final AgentAttentionController? attention;
  final String? hostId;

  /// Where a message can be sent ("Send to another agent"), and how;
  /// default: the other live sessions [attention] knows, opened in their
  /// own chat with the message sent there.
  final List<ChatForwardTarget> Function()? forwardTargets;
  final ChatForward? onForward;

  /// A message's "Share": the system share sheet (tests inject one).
  final Future<bool> Function(String text) share;

  @override
  State<ChatViewPage> createState() => _ChatViewPageState();
}

class _ChatViewPageState extends State<ChatViewPage>
    with WidgetsBindingObserver, ChatThreadExtras {
  final _scroll = ScrollController();

  @override
  TextEditingController get composerText => _composerText;

  @override
  ScrollController get threadScroll => _scroll;

  bool _monitoringTurnedOn = false;

  Future<void> _enableMonitoring() async {
    setState(() => _monitoringTurnedOn = true);
    try {
      await widget.onEnableMonitoring?.call();
    } catch (error) {
      if (!mounted) return;
      setState(() => _monitoringTurnedOn = false);
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text('Could not turn on monitoring: $error')),
      );
    }
  }

  bool _showJump = false;
  Timer? _clock;
  final _headerTick = ValueNotifier<int>(0);
  ReadAloudController? _readAloud;

  /// Made and disposed here when the opener passed no dictation.
  DictationController? _ownDictation;

  DictationController? get _dictation => widget.dictation ?? _ownDictation;

  /// The hands-free Talk loop; null without dictation or speech.
  TalkController? _talk;
  String? _talkMessageShown;
  late final _composerText = TextEditingController(text: widget.initialDraft);

  /// When the working indicator appeared, for turns whose prompt has no
  /// timestamp.
  DateTime? _workingShownAt;

  ChatWorking? get _working => _chat.loading || _chat.unsupported != null
      ? null
      : ChatWorking.of(_chat.agent, _chat.items);

  ChatViewController get _chat => widget.controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scroll.addListener(_onScroll);
    Telemetry.instance
      ..screen(TelemetryScreen.chat)
      ..track(const TelemetryEvent.chatModeOpened());
    _chat.setVisible(true);
    _chat.addListener(_stickToBottom);
    _chat.addListener(_watchTurnEnd);
    if (widget.dictation == null) {
      final recognizer =
          widget.speechRecognizer ??
          VoiceServicesScope.maybeOf(context)?.recognizer ??
          (PlatformFeatures.dictation ? PlatformSpeechRecognizer() : null);
      if (recognizer != null) {
        _ownDictation = DictationController(
          recognizer,
          language: () => _settings?.speechLanguage ?? '',
        );
        unawaited(_ownDictation!.checkAvailability());
      }
    }
    final tts =
        widget.textToSpeech ??
        VoiceServicesScope.maybeOf(context)?.tts ??
        (PlatformFeatures.textToSpeech ? PlatformTextToSpeech() : null);
    if (tts != null) {
      _readAloud = ReadAloudController(
        tts: tts,
        preferences: () => _settings?.voice ?? VoicePreferences.defaults,
        dictationLanguage: () => _settings?.speechLanguage ?? '',
        // On this chat's machine, through the chat's own connection.
        summarize: (text, cancel) => _chat.summarize(text, cancel: cancel),
        onNotice: (note) {
          if (mounted) _tell(note, long: true);
        },
      )..addListener(_onSpeakerChanged);
      unawaited(_readAloud!.checkAvailability());
      _chat.addListener(_feedReadAloud);
      _dictation?.addListener(_syncDictation);
      final dictation = _dictation;
      if (dictation != null) {
        _talk = TalkController(
          dictation: dictation,
          readAloud: _readAloud!,
          send: (text) => _chat.send(text),
          decide: _chat.decide,
          answer: _chat.answerQuestion,
          options: () {
            final voice = _settings?.voice ?? VoicePreferences.defaults;
            return DictationOptions(
              continuous: true,
              silenceTimeout: Duration(seconds: voice.talkSendSilenceSeconds),
              maxSession: voice.dictationMaxSession,
              muteRestartBeeps: voice.muteRestartBeeps,
            );
          },
        )..addListener(_onTalkChanged);
      }
    }
    // The elapsed time in the header, and a sent prompt's "not in the
    // transcript yet" note. Only the header ticks; the thread rebuilds
    // only while a sent prompt waits for its transcript entry.
    _clock = Timer.periodic(const Duration(seconds: 15), (_) {
      if (!mounted) return;
      _headerTick.value += 1;
      if (_chat.outgoing.any(
        (o) => o.pending && o.state == ChatSendState.sent && !o.late,
      )) {
        setState(() {});
      }
    });
  }

  bool _readAloudPrimed = false;

  /// Whether a route covers this chat (or its desktop tab is hidden):
  /// tickers are off below it.
  bool _covered = false;

  /// Polls only while the chat can be seen: a route on top (the terminal,
  /// a sheet) or a hidden desktop tab pauses it, unless the chat is
  /// reading aloud or in Talk, which the user hears rather than sees.
  void _syncPolling() {
    if (!mounted) return;
    final resumed =
        _lifecycle == null || _lifecycle == AppLifecycleState.resumed;
    final listening =
        (_readAloud?.enabled ?? false) || (_talk?.active ?? false);
    if (!resumed) return;
    _chat.setVisible(!_covered || listening);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final covered = !TickerMode.valuesOf(context).enabled;
    if (covered != _covered) {
      _covered = covered;
      WidgetsBinding.instance.addPostFrameCallback((_) => _syncPolling());
    }
    final readAloud = _readAloud;
    // The chat on screen holds the speaker; a chat opened on top takes it
    // (this one then finishes its sentence and keeps quiet), and it comes
    // back when this route is on top again.
    if (readAloud != null && (ModalRoute.of(context)?.isCurrent ?? true)) {
      // After the frame: claiming notifies the other chat's listeners.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && (ModalRoute.of(context)?.isCurrent ?? true)) {
          readAloud.claim();
        }
      });
    }
    if (readAloud != null && !_readAloudPrimed) {
      _readAloudPrimed = true;
      final voice = _settings?.voice ?? VoicePreferences.defaults;
      readAloud.setEnabled(voice.readAloudFor(_chat.sessionId));
      _feedReadAloud();
    }
  }

  ThemeController? get _settings => VoiceSettingsScope.maybeOf(context);

  // --- Review -------------------------------------------------------------------

  /// The monitored machine this chat is on.
  SavedHost? get _reviewHost {
    final attention = widget.attention;
    final hostId = widget.hostId;
    if (attention == null || hostId == null) return null;
    return attention.monitoredHosts.where((h) => h.id == hostId).firstOrNull;
  }

  /// The monitor's record of this agent (Review needs its cwd and name).
  AgentInfo? get _reviewAgent => widget.attention
      ?.statusFor(widget.hostId ?? '')
      ?.agents
      .where((a) => a.id == _chat.sessionId)
      .firstOrNull;

  bool get _canReview {
    final host = _reviewHost;
    return host != null &&
        _reviewAgent != null &&
        reviewAvailable(widget.attention!, host);
  }

  bool _reviewOpen = false;

  Future<void> _openReview() async {
    final host = _reviewHost;
    final agent = _reviewAgent;
    if (host == null || agent == null || _reviewOpen) return;
    _reviewOpen = true;
    try {
      await openReview(
        context: context,
        attention: widget.attention!,
        host: host,
        agent: agent,
        // Through the chat, so the prompt shows as a bubble here too.
        send: (text) => _chat.send(text),
        dictation: _dictation,
      );
    } finally {
      _reviewOpen = false;
    }
  }

  String? _lastTurnState;

  /// "Review changes: after each turn": a turn that ends (Stop) while this
  /// chat is on screen opens Review, on machines that snapshot turns.
  void _watchTurnEnd() {
    final agent = _chat.agent;
    final state = agent?.state;
    final previous = _lastTurnState;
    _lastTurnState = state;
    if (previous != 'working' || state != 'waiting_input') return;
    if (agent?.lastEvent != 'Stop') return;
    final voice = _settings?.voice ?? VoicePreferences.defaults;
    if (voice.reviewOpens != ReviewOpens.afterEachTurn) return;
    final host = _reviewHost;
    if (host == null || !widget.attention!.supportsSnapshots(host.id)) return;
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return;
    unawaited(_openReview());
  }

  /// Hands every new poll to the reader; the first loaded thread only
  /// marks what is already there as read.
  void _feedReadAloud() {
    if (!_chat.loading && _chat.unsupported == null) {
      final state = _chat.agent?.state;
      _readAloud?.observe(_chat.items, _chat.pending, state);
      // After the reader, so the turn's answer is already queued.
      _talk?.update(_chat.items, _chat.pending, state);
    }
  }

  void _startTalk() {
    FocusManager.instance.primaryFocus?.unfocus();
    _readAloud?.claim();
    _talk?.start();
  }

  /// Long press on Talk: the voice guide, which talks to every agent.
  /// This chat's own Talk and reading stop so only the guide listens.
  void _startGuide() {
    final guide = GuideScope.maybeOf(context);
    if (guide == null) return;
    FocusManager.instance.primaryFocus?.unfocus();
    if (_talk?.active ?? false) _stopTalk();
    _readAloud?.stop();
    guide.start();
  }

  /// Another chat took the speaker: a Talk loop here would listen and
  /// answer for the wrong agent.
  void _onSpeakerChanged() {
    final readAloud = _readAloud;
    if (readAloud == null || readAloud.current) return;
    if (_talk?.active ?? false) _stopTalk();
  }

  /// Ends the Talk loop; anything said but not sent goes to the composer.
  void _stopTalk() {
    final unsent = _talk?.stop();
    if (unsent != null) {
      final current = _composerText.text.trimRight();
      _composerText.text = current.isEmpty ? unsent : '$current $unsent';
    }
  }

  void _onTalkChanged() {
    final talk = _talk;
    if (talk == null || !mounted) return;
    final message = talk.message;
    if (!talk.active && message != null && message != _talkMessageShown) {
      _talkMessageShown = message;
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(message)));
    }
    if (talk.active) _talkMessageShown = null;
    _syncDictation();
  }

  /// Dictating into the composer keeps the reader quiet (and skips what
  /// arrives meanwhile). Talk's own listening does not: it closes the mic
  /// when there is something to read (see TalkController.update).
  void _syncDictation() {
    _readAloud?.suppressed =
        (_dictation?.isActive ?? false) && !(_talk?.active ?? false);
  }

  void _toggleReadAloud() {
    final readAloud = _readAloud;
    if (readAloud == null) return;
    if (!readAloud.isAvailable) {
      _tell(
        defaultTargetPlatform == TargetPlatform.iOS
            ? 'Reading aloud needs a voice. Download one in Settings › '
                  'Accessibility › Spoken Content › Voices.'
            : 'Reading aloud needs a text-to-speech engine. Install or turn '
                  'one on in Android Settings › Accessibility › '
                  'Text-to-speech output.',
      );
      // It may have been installed since the chat opened.
      unawaited(readAloud.checkAvailability());
      return;
    }
    final enabled = !readAloud.enabled;
    readAloud.setEnabled(enabled);
    _tell(enabled ? 'Reading replies aloud' : 'Stopped reading aloud');
    final settings = _settings;
    if (settings != null) {
      unawaited(
        settings.setVoice(
          settings.voice.withSessionReadAloud(_chat.sessionId, enabled),
        ),
      );
    }
  }

  void _tell(String message, {bool long = false}) =>
      ScaffoldMessenger.maybeOf(context)
        ?..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(message),
            duration: Duration(seconds: long ? 5 : 2),
          ),
        );

  ToolActivity get _toolActivity =>
      _settings?.voice.toolActivity ?? VoicePreferences.defaults.toolActivity;

  ReadAloudLength get _readAloudLength =>
      _settings?.voice.readAloudLength ??
      VoicePreferences.defaults.readAloudLength;

  void _setVoice(VoicePreferences Function(VoicePreferences voice) change) {
    final settings = _settings;
    if (settings == null) return;
    unawaited(settings.setVoice(change(settings.voice)));
  }

  /// Tool groups the user opened (Tool activity: Collapsed).
  final Set<String> _openGroups = {};

  /// The user is acting (sending, answering): stop talking over them.
  void _quiet() => _readAloud?.stop();

  Future<void> _send(String text, {bool enter = true}) async {
    _quiet();
    try {
      await _chat.send(text, enter: enter);
    } on AppFailure {
      // A submitted prompt stays in the thread as a failed bubble with
      // Retry and Edit, so the composer need not keep it.
      if (!enter) rethrow;
    }
  }

  Future<void> _retry(ChatOutgoing outgoing) async {
    _quiet();
    try {
      await _chat.retry(outgoing.id);
    } on AppFailure {
      // Shown on the new bubble.
    }
  }

  /// Puts a failed prompt back in the composer.
  void _edit(ChatOutgoing outgoing) {
    final text = _chat.discard(outgoing.id);
    if (text == null) return;
    _composerText.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  /// The last lifecycle state seen, to tell leaving from coming back.
  AppLifecycleState? _lifecycle;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final previous = _lifecycle;
    _lifecycle = state;
    final readAloud = _readAloud;
    final talking = _talk?.active ?? false;
    if (state == AppLifecycleState.resumed ||
        readAloud == null ||
        !(readAloud.enabled || talking)) {
      if (state == AppLifecycleState.resumed) {
        _syncPolling();
      } else {
        _chat.setVisible(false);
      }
      return;
    }
    // Read-aloud is on. Keep polling and reading while only the screen
    // went off with this chat on top; leaving the chat (another app, the
    // home screen) silences it. No background service keeps it alive.
    if (state == AppLifecycleState.inactive) {
      return;
    }
    // Only going down (inactive → hidden) can mean the user left. Coming
    // back up from paused passes through hidden too, with the screen
    // already on (a notification woke it, the user unlocked): that is not
    // leaving.
    if (previous != AppLifecycleState.inactive) {
      return;
    }
    final onTop = ModalRoute.of(context)?.isCurrent ?? true;
    unawaited(
      readAloud.screenOn().then((screenOn) {
        if (!mounted) return;
        // Back on screen before the answer came.
        if (_lifecycle == AppLifecycleState.resumed ||
            _lifecycle == AppLifecycleState.inactive) {
          return;
        }
        final keep = onTop && !screenOn;
        _chat.setVisible(keep);
        if (!keep) {
          readAloud.stop();
          _stopTalk();
        }
      }),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _chat.removeListener(_feedReadAloud);
    _chat.removeListener(_stickToBottom);
    _chat.removeListener(_watchTurnEnd);
    _dictation?.removeListener(_syncDictation);
    _talk
      ?..removeListener(_onTalkChanged)
      ..dispose();
    _ownDictation?.dispose();
    _readAloud
      ?..removeListener(_onSpeakerChanged)
      ..dispose();
    _composerText.dispose();
    _clock?.cancel();
    _headerTick.dispose();
    _scroll.dispose();
    _chat.setVisible(false);
    if (widget.ownsController) {
      _chat.dispose();
    }
    super.dispose();
  }

  /// Within this distance of the newest message the thread follows new
  /// messages; further up it holds still.
  static const _stickDistance = 48.0;

  /// Set while the user reads further up: the thread shows nothing newer
  /// than [_ThreadFreeze.lastItemId], so arriving messages, approvals and
  /// the working row cannot move what is on screen. They are counted on
  /// the "New messages" pill and appear once the user is back at the
  /// bottom.
  _ThreadFreeze? _freeze;

  /// The last working state shown, kept for a frozen working row.
  ChatWorking? _lastWorking;

  void _onScroll() {
    // The list is reversed: offset 0 is the newest message.
    final offset = _scroll.offset;
    final away = offset > 240;
    if (away != _showJump) {
      setState(() => _showJump = away);
    }
    if (offset > _stickDistance && _freeze == null) {
      setState(() {
        _freeze = _ThreadFreeze(
          lastItemId: _chat.items.lastOrNull?.id,
          approvals: {for (final request in _chat.pending) request.id},
          working: _working != null,
        );
      });
    } else if (offset <= _stickDistance && _freeze != null) {
      setState(() => _freeze = null);
      _stickToBottom();
    }
    final position = _scroll.position;
    if (position.maxScrollExtent - position.pixels < 400) {
      unawaited(_chat.loadOlder());
    }
  }

  /// Follows new messages while at the bottom.
  void _stickToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _freeze != null || !_scroll.hasClients) return;
      if (_scroll.offset > 0 && _scroll.offset <= _stickDistance) {
        _scroll.jumpTo(0);
      }
    });
  }

  void _jumpToLatest() {
    unawaited(
      _scroll.animateTo(
        0,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      ),
    );
  }

  bool get _smartApprovals {
    final attention = widget.attention;
    final hostId = widget.hostId;
    return attention != null &&
        hostId != null &&
        attention.supportsSmartApprovals(hostId);
  }

  Future<void> _trust(PendingPermissionRequest request) async {
    _quiet();
    await trustPermissionRequest(
      context,
      controller: widget.attention!,
      hostId: widget.hostId!,
      request: request,
    );
    if (mounted) unawaited(_chat.refresh());
  }

  Future<void> _decide(
    PendingPermissionRequest request,
    PermissionVerdict verdict,
  ) async {
    _quiet();
    if (verdict == PermissionVerdict.always && _smartApprovals) {
      await answerPermissionRequest(
        context,
        controller: widget.attention!,
        hostId: widget.hostId!,
        request: request,
        verdict: verdict,
      );
      if (mounted) unawaited(_chat.refresh());
      return;
    }
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await _chat.decide(request, verdict);
    } catch (error) {
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
            'Could not ${verdict.label.toLowerCase()} ${request.toolName}: '
            '${error is AppFailure ? error.userMessage : error}',
          ),
        ),
      );
    }
  }

  Future<void> _pick(ChatQuestion question, int number) async {
    _quiet();
    final options = question.questions.firstOrNull?.options ?? const [];
    try {
      await _chat.answerQuestion(
        number,
        label: number <= options.length ? options[number - 1].label : null,
      );
    } on AppFailure {
      // The failed answer bubble offers Retry.
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(error is AppFailure ? error.userMessage : '$error'),
        ),
      );
    }
  }

  Future<void> _openComposer(String text, ValueChanged<String> setDraft) {
    var draft = text;
    return showPromptComposerSheet(
      context: context,
      initialText: text,
      onDraftChanged: (value) => draft = value,
      onSend: (value, {required submit}) async {
        await _send(value, enter: submit);
        draft = '';
      },
      submitEnter: true,
      onSubmitEnterChanged: (_) {},
      isConnected: () => _chat.canSend,
      // `send` pastes multiline text as one bracketed paste on the host.
      bracketedPasteSupported: () => true,
      dictation: _dictation,
      imageAttacher: widget.imageAttacher,
      pasteImages: widget.pasteImages,
    ).whenComplete(() => setDraft(draft));
  }

  /// The inline field's "Paste image": uploads the clipboard image and puts
  /// its path at the cursor, like the terminal's paste.
  Future<void> _pasteImage() async {
    final attacher = widget.imageAttacher;
    if (attacher == null) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final path = await ClipboardImagePaster.fromAttacher(attacher).paste(
        onUploading: () => messenger?.showSnackBar(
          const SnackBar(
            content: Text('Uploading image…'),
            duration: Duration(minutes: 1),
          ),
        ),
      );
      messenger?.hideCurrentSnackBar();
      if (!mounted) return;
      if (path == null) {
        messenger?.showSnackBar(
          const SnackBar(content: Text('There is no image on the clipboard.')),
        );
        return;
      }
      insertImagePath(path);
    } catch (error) {
      messenger
        ?..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              'Could not paste the image: '
              '${error is AppFailure ? error.userMessage : error}',
            ),
          ),
        );
    }
  }

  /// Puts [path] at the composer's cursor as its own word.
  void insertImagePath(String path) {
    final value = _composerText.value;
    final selection = value.selection;
    final start = selection.isValid ? selection.start : value.text.length;
    final end = selection.isValid ? selection.end : value.text.length;
    final inserted = insertPromptImagePath(value.text, start, end, path);
    _composerText.value = TextEditingValue(
      text: inserted.text,
      selection: TextSelection.collapsed(offset: inserted.cursor),
    );
  }

  static String _elapsed(DateTime? since) {
    if (since == null) return '';
    final d = DateTime.now().toUtc().difference(since.toUtc());
    if (d.isNegative || d.inMinutes < 1) return '<1m';
    if (d.inHours < 1) return '${d.inMinutes}m';
    if (d.inDays < 1) return '${d.inHours}h ${d.inMinutes % 60}m';
    return '${d.inDays}d ${d.inHours % 24}h';
  }

  @override
  Widget build(BuildContext context) => wrapShortcuts(_page(context));

  Widget _page(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      // Settings too: Tool activity and the read-aloud length show here.
      listenable: Listenable.merge([_chat, ?_settings, search]),
      builder: (context, _) {
        final activity = _chat.activity;
        final working = _working;
        if (working == null) {
          _workingShownAt = null;
        } else {
          _workingShownAt ??= DateTime.now();
        }
        return Scaffold(
          appBar: AppBar(
            titleSpacing: 0,
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_chat.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                PulseWhile(
                  key: const ValueKey('chat-header-pulse'),
                  active: working != null,
                  child: ValueListenableBuilder(
                    valueListenable: _headerTick,
                    builder: (context, _, _) {
                      final elapsed = _elapsed(_chat.startedAt);
                      return Text(
                        [
                          activity?.label ?? 'Connecting…',
                          if (elapsed.isNotEmpty) elapsed,
                          ?widget.hostName,
                        ].join(' · '),
                        key: const ValueKey('chat-header-status'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: switch (activity) {
                            ChatActivity.needsApproval ||
                            ChatActivity.waiting => theme.colorScheme.error,
                            ChatActivity.thinking ||
                            ChatActivity.working => theme.colorScheme.primary,
                            _ => theme.colorScheme.onSurfaceVariant,
                          },
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
            actions: [
              searchButton(),
              if (_talk case final talk?)
                ListenableBuilder(
                  listenable: talk,
                  builder: (context, _) => talk.active
                      ? IconButton.filled(
                          key: const ValueKey('chat-talk-toggle'),
                          tooltip: 'End Talk mode',
                          isSelected: true,
                          onPressed: _stopTalk,
                          icon: const Icon(Icons.record_voice_over_rounded),
                        )
                      : const SizedBox.shrink(),
                ),
              if (_readAloud case final readAloud?)
                _ReadAloudToggle(
                  controller: readAloud,
                  onPressed: _toggleReadAloud,
                ),
              if (_canReview)
                IconButton(
                  key: const ValueKey('chat-review'),
                  tooltip: 'Review changes',
                  onPressed: _openReview,
                  icon: const Icon(Icons.rate_review_outlined),
                ),
              _ChatMenu(
                readAloudLength: _readAloud == null ? null : _readAloudLength,
                toolActivity: _toolActivity,
                onReadAloudLength: (length) =>
                    _setVoice((v) => v.copyWith(readAloudLength: length)),
                onToolActivity: (mode) =>
                    _setVoice((v) => v.copyWith(toolActivity: mode)),
              ),
              // Narrow phones: the icon alone keeps room for the title.
              if (MediaQuery.sizeOf(context).width < 400)
                IconButton(
                  tooltip: 'Terminal',
                  onPressed: widget.onOpenTerminal,
                  icon: const Icon(Icons.terminal_rounded),
                )
              else
                TextButton.icon(
                  onPressed: widget.onOpenTerminal,
                  icon: const Icon(Icons.terminal_rounded),
                  label: const Text('Terminal'),
                ),
            ],
          ),
          body: SafeArea(
            top: false,
            child: Column(
              children: [
                ?findBar(),
                if (_chat.error case final error?)
                  MaterialBanner(
                    content: Text(error, maxLines: 3),
                    actions: [
                      TextButton(
                        onPressed: _chat.refresh,
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                if (widget.onEnableMonitoring != null && !_monitoringTurnedOn)
                  MaterialBanner(
                    key: const ValueKey('chat-enable-monitoring'),
                    leading: const Icon(Icons.monitor_heart_outlined),
                    content: const Text(
                      'Agent monitoring is off for this machine. Turn it on '
                      'for approval alerts and the Agents panel.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: _enableMonitoring,
                        child: const Text('Turn on'),
                      ),
                    ],
                  ),
                Expanded(
                  // Touching the thread ends the Talk loop.
                  child: Listener(
                    onPointerDown: (_) {
                      if (_talk?.active ?? false) _stopTalk();
                    },
                    child: _buildThread(context),
                  ),
                ),
                if (widget.accessory case final accessory?)
                  Align(
                    alignment: Alignment.centerRight,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                      child: accessory,
                    ),
                  ),
                if (_talk case final talk?)
                  ListenableBuilder(
                    listenable: talk,
                    builder: (context, _) => talk.active
                        ? TalkPanel(controller: talk, onStop: _stopTalk)
                        : _composer(activity),
                  )
                else
                  _composer(activity),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _composer(ChatActivity? activity) => ChatComposer(
    textController: _composerText,
    focusNode: composerFocus,
    onTalk: _talk == null ? null : _startTalk,
    onGuide: GuideScope.maybeOf(context) == null ? null : _startGuide,
    enabled: _chat.canSend,
    disabledHint: _chat.unsupported != null
        ? 'Chat unavailable'
        : _chat.agent?.state == 'ended'
        ? 'This session has ended'
        : 'Answer the approval above first',
    sending: _chat.sending,
    showInterrupt:
        activity == ChatActivity.working || activity == ChatActivity.thinking,
    onSend: _send,
    onInterrupt: _chat.interrupt,
    onExpand: _openComposer,
    dictation: _dictation,
    onPasteImage: widget.imageAttacher != null && widget.pasteImages
        ? () => unawaited(_pasteImage())
        : null,
    clipboardHasImage: widget.clipboardHasImage,
  );

  Widget _buildThread(BuildContext context) {
    final theme = Theme.of(context);
    if (_chat.unsupported case final reason?) {
      final setUp = widget.onSetUpCompanion;
      return _Centered(
        icon: Icons.extension_off_outlined,
        text: reason,
        action: setUp == null
            ? null
            : FilledButton.icon(
                key: const ValueKey('chat-set-up-companion'),
                onPressed: setUp,
                icon: const Icon(Icons.webhook_rounded),
                label: Text(
                  _chat.unsupportedKind == ChatUnsupportedKind.outdated
                      ? 'Update agent hooks'
                      : 'Install agent hooks',
                ),
              ),
      );
    }
    if (_chat.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final items = _chat.items;
    final allPending = _chat.pending;
    final waiting = _chat.agent?.state == 'waiting_input';
    final working = _working;
    if (working != null) _lastWorking = working;
    // While frozen, show only what was there when the user scrolled up.
    final freeze = _freeze;
    final allOutgoing = _chat.outgoing;
    final confirmedIds = {for (final o in allOutgoing) ?o.confirmedId};
    var shownCount = items.length;
    var pending = allPending;
    var held = 0;
    if (freeze != null) {
      final last = freeze.lastItemId == null
          ? -1
          : items.lastIndexWhere((item) => item.id == freeze.lastItemId);
      if (last != -1 || freeze.lastItemId == null) {
        shownCount = last + 1;
      }
      for (var i = shownCount; i < items.length; i++) {
        if (items[i] is! ChatThinking && !confirmedIds.contains(items[i].id)) {
          held += 1;
        }
      }
      pending = [
        for (final request in allPending)
          if (freeze.approvals.contains(request.id)) request,
      ];
      held += allPending.length - pending.length;
    }
    // What the user sent stays at the bottom until the transcript shows
    // it; while frozen above that entry, the bubble stands in for it.
    searchThread(items, shownCount, _toolActivity);
    final shownIds = {for (final item in items.take(shownCount)) item.id};
    final outgoing = [
      for (final o in allOutgoing)
        if (o.pending || !shownIds.contains(o.confirmedId)) o,
    ];
    final showWorkingRow = freeze == null
        ? working != null
        : freeze.working && (working ?? _lastWorking) != null;
    final shownWorking = working ?? _lastWorking;
    // Newest first: the list is reversed so it opens at the latest message
    // and stays there as messages arrive. Rows are built lazily, only near
    // the screen: a long transcript costs its visible rows per build, not
    // thousands.
    final rows = <_ThreadRow>[
      if (showWorkingRow && shownWorking != null)
        _ThreadRow(
          const ValueKey('chat-working-slot'),
          // Frozen and finished: keep the row's space so nothing moves.
          () => Visibility(
            key: const ValueKey('chat-working-slot'),
            visible: working != null,
            maintainSize: true,
            maintainAnimation: true,
            maintainState: true,
            child: ChatWorkingIndicator(
              key: const ValueKey('chat-working-indicator'),
              working: shownWorking,
              since: shownWorking.since ?? _workingShownAt ?? DateTime.now(),
            ),
          ),
        ),
      for (final request in pending.reversed)
        _ThreadRow(
          ValueKey('approval-${request.id}'),
          () => ChatApprovalCard(
            key: ValueKey('approval-${request.id}'),
            request: request,
            busy:
                _chat.isDeciding(request.id) ||
                (widget.attention?.isDeciding(request.id) ?? false),
            onDecide: (verdict) => _decide(request, verdict),
            onTrust: _smartApprovals ? () => _trust(request) : null,
          ),
        ),
      for (final o in outgoing.reversed)
        _ThreadRow(
          ValueKey(o.id),
          () => decorateOutgoing(
            o,
            ChatOutgoingBubble(
              item: o,
              onRetry: () => unawaited(_retry(o)),
              onEdit: o.answer ? null : () => _edit(o),
            ),
          ),
        ),
      for (final entry in ChatToolActivity.arrange(
        items.sublist(0, shownCount),
        _toolActivity,
      ).reversed)
        switch (entry) {
          ChatItemEntry(:final item) => _ThreadRow(
            ValueKey(('chat-row', item.id)),
            () => _row(
              item,
              isLast: identical(item, items.last),
              waiting: waiting,
            ),
            ids: [item.id],
          ),
          final ChatToolGroup group => _ThreadRow(
            ValueKey(group.id),
            () => ChatToolGroupRow(
              key: ValueKey(group.id),
              group: group,
              expanded: _openGroups.contains(group.id) || searchOpens(group),
              onToggle: () => setState(() {
                if (!_openGroups.remove(group.id)) _openGroups.add(group.id);
              }),
              children: [
                for (final item in group.items)
                  _row(item, isLast: false, waiting: waiting),
              ],
            ),
            ids: [for (final item in group.items) item.id],
          ),
        },
      if (_chat.hasOlder)
        _ThreadRow(
          const ValueKey('chat-load-older'),
          () => Padding(
            padding: const EdgeInsets.all(12),
            child: Center(
              child: _chat.loadingOlder
                  ? const CircularProgressIndicator()
                  : TextButton(
                      onPressed: _chat.loadOlder,
                      child: const Text('Load earlier messages'),
                    ),
            ),
          ),
        )
      else if (_chat.olderOnlyInTerminal)
        _ThreadRow(
          const ValueKey('chat-older-in-terminal'),
          () => Padding(
            padding: const EdgeInsets.all(12),
            child: Center(
              child: Text(
                'Earlier messages are in the terminal.',
                style: theme.textTheme.bodySmall,
              ),
            ),
          ),
        )
      else if (items.isEmpty && pending.isEmpty && outgoing.isEmpty)
        _ThreadRow(
          const ValueKey('chat-empty'),
          () => const _Centered(
            icon: Icons.forum_outlined,
            text: 'No messages yet. Send a prompt to start.',
          ),
        ),
    ];
    noteRows([for (final row in rows) row.ids]);
    final rowIndex = {for (var i = 0; i < rows.length; i++) rows[i].key: i};
    return Stack(
      children: [
        wrapThread(
          ListView.builder(
            key: const ValueKey('chat-thread'),
            controller: _scroll,
            reverse: true,
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            itemCount: rows.length,
            itemBuilder: (context, index) => rows[index].build(),
            // Rows keep their state (an open card, a selection) when new
            // ones arrive below them and move them up the list.
            findChildIndexCallback: (key) => rowIndex[key],
          ),
        ),
        if (held > 0)
          Positioned(
            bottom: 12,
            left: 0,
            right: 0,
            child: Center(
              child: FilledButton.tonalIcon(
                key: const ValueKey('chat-new-messages'),
                onPressed: _jumpToLatest,
                icon: const Icon(Icons.arrow_downward_rounded, size: 18),
                label: Text('New messages ($held)'),
              ),
            ),
          )
        else if (_showJump)
          Positioned(
            right: 12,
            bottom: 12,
            child: FloatingActionButton.small(
              heroTag: null,
              tooltip: 'Latest',
              backgroundColor: theme.colorScheme.secondaryContainer,
              onPressed: _jumpToLatest,
              child: const Icon(Icons.keyboard_double_arrow_down_rounded),
            ),
          ),
      ],
    );
  }

  Widget _row(ChatItem item, {required bool isLast, required bool waiting}) {
    final key = ValueKey(item.id);
    return decorateRow(item, switch (item) {
      ChatUserMessage() => ChatUserBubble(key: key, item: item),
      ChatAgentMessage() => ChatAgentMessageCard(key: key, item: item),
      ChatTaskNotice() => ChatTaskNoticeRow(key: key, item: item),
      ChatShellCommand() => ChatShellCommandCard(key: key, item: item),
      ChatAssistantText() => ChatAssistantBubble(key: key, item: item),
      ChatThinking() => ChatThinkingRow(key: key, item: item),
      ChatToolCall() => ChatToolCard(key: key, item: item),
      ChatTodoList() => ChatTodoCard(key: key, item: item),
      ChatPlan() => ChatPlanCard(key: key, item: item),
      ChatQuestion() => ChatQuestionCard(
        key: key,
        item: item,
        onPick:
            !item.answered && isLast && waiting && !_chat.isAnswering(item.id)
            ? (number) => _pick(item, number)
            : null,
      ),
      ChatNotice() => ChatNoticeRow(key: key, item: item),
    });
  }
}

/// One row of the thread, built only when the list needs it: [key] is
/// the built widget's key, [ids] the chat items it shows (for find).
class _ThreadRow {
  const _ThreadRow(this.key, this.build, {this.ids = const []});

  final Key key;
  final Widget Function() build;
  final List<String> ids;
}

class _Centered extends StatelessWidget {
  const _Centered({required this.icon, required this.text, this.action});

  final IconData icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(
              text,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    );
  }
}

/// The header's speaker: on/off for "Read replies aloud", filled while
/// on, a sound wave while speaking. Turning it off stops speech at once.
/// Without a text-to-speech engine it shows muted and explains on tap.
class _ReadAloudToggle extends StatelessWidget {
  const _ReadAloudToggle({required this.controller, required this.onPressed});

  final ReadAloudController controller;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final colors = Theme.of(context).colorScheme;
        if (!controller.isAvailable) {
          return IconButton(
            key: const ValueKey('chat-read-aloud'),
            tooltip: 'Read aloud unavailable',
            onPressed: onPressed,
            icon: Icon(
              Icons.volume_off_outlined,
              color: colors.onSurface.withValues(alpha: 0.38),
            ),
          );
        }
        final on = controller.enabled;
        if (controller.summarizing) {
          // Waiting for Claude's summary: a quiet ring, nothing spoken.
          return IconButton(
            key: const ValueKey('chat-read-aloud'),
            tooltip: 'Summarizing…',
            onPressed: onPressed,
            style: IconButton.styleFrom(
              backgroundColor: colors.primaryContainer,
              foregroundColor: colors.onPrimaryContainer,
            ),
            icon: const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                key: ValueKey('chat-summarizing'),
                strokeWidth: 2,
              ),
            ),
          );
        }
        return IconButton(
          key: const ValueKey('chat-read-aloud'),
          tooltip: on ? 'Stop reading replies aloud' : 'Read replies aloud',
          isSelected: on,
          onPressed: onPressed,
          style: on
              ? IconButton.styleFrom(
                  backgroundColor: colors.primaryContainer,
                  foregroundColor: colors.onPrimaryContainer,
                )
              : null,
          icon: const Icon(Icons.volume_off_outlined),
          selectedIcon: Icon(
            controller.speaking
                ? Icons.graphic_eq_rounded
                : Icons.volume_up_rounded,
          ),
        );
      },
    );
  }
}

/// The header menu: quick switches for the read-aloud length and Tool
/// activity (the same settings as Settings › Chat & Voice).
class _ChatMenu extends StatelessWidget {
  const _ChatMenu({
    required this.readAloudLength,
    required this.toolActivity,
    required this.onReadAloudLength,
    required this.onToolActivity,
  });

  /// Null hides the read-aloud choices (no speech on this device).
  final ReadAloudLength? readAloudLength;
  final ToolActivity toolActivity;
  final ValueChanged<ReadAloudLength> onReadAloudLength;
  final ValueChanged<ToolActivity> onToolActivity;

  @override
  Widget build(BuildContext context) {
    final length = readAloudLength;
    return PopupMenuButton<Object>(
      key: const ValueKey('chat-menu'),
      tooltip: 'Chat options',
      onSelected: (value) => switch (value) {
        final ReadAloudLength length => onReadAloudLength(length),
        final ToolActivity mode => onToolActivity(mode),
        _ => null,
      },
      itemBuilder: (context) => [
        if (length != null) ...[
          const PopupMenuItem<Object>(
            enabled: false,
            height: 32,
            child: Text('Read aloud'),
          ),
          for (final option in ReadAloudLength.values)
            CheckedPopupMenuItem<Object>(
              key: ValueKey('chat-menu-length-${option.name}'),
              value: option,
              checked: option == length,
              child: Text(option.label),
            ),
          const PopupMenuDivider(),
        ],
        const PopupMenuItem<Object>(
          enabled: false,
          height: 32,
          child: Text('Tool activity'),
        ),
        for (final option in ToolActivity.values)
          CheckedPopupMenuItem<Object>(
            key: ValueKey('chat-menu-tools-${option.name}'),
            value: option,
            checked: option == toolActivity,
            child: Text(option.label),
          ),
      ],
    );
  }
}

/// What the thread showed when the user scrolled away from the bottom.
class _ThreadFreeze {
  const _ThreadFreeze({
    required this.lastItemId,
    required this.approvals,
    required this.working,
  });

  final String? lastItemId;
  final Set<String> approvals;
  final bool working;
}
