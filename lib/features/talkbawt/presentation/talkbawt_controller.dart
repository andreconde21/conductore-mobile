import 'dart:async';
import 'dart:math';

import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/sync/data/app_local_sync_store.dart';
import 'package:conduit/features/talkbawt/domain/paired_session.dart';
import 'package:conduit/features/talkbawt/domain/talkbawt_host_client.dart';
import 'package:conduit/features/talkbawt/domain/talkbawt_link.dart';
import 'package:conduit/features/talkbawt/domain/talkbawt_models.dart';
import 'package:conduit/features/talkbawt/domain/talkbawt_safety.dart';
import 'package:conduit/features/talkbawt/domain/talkbawt_settings.dart';
import 'package:flutter/foundation.dart';

/// A companion client for one machine, and how to let go of it.
typedef TalkbawtClientLease = ({
  TalkbawtHostClient client,
  Future<void> Function() release,
});

/// Something for the user to see about a thread they own: a reply, a new
/// reader, or the link going away. Tapping it opens the preview only.
class TalkbawtNotice {
  const TalkbawtNotice({
    required this.threadId,
    required this.title,
    required this.body,
  });

  final String threadId;
  final String title;
  final String body;
}

/// Where a relayed message goes when the relay setting is Talkbawt.
class TalkbawtRelayTarget {
  const TalkbawtRelayTarget({required this.host, required this.agent});

  final SavedHost host;
  final AgentInfo agent;
}

/// Talkbawt on the phone (CON-050): the settings, the threads this phone
/// owns (secure storage, synced only end-to-end encrypted), handoffs from
/// agents, links opened on a machine, watching owned threads for replies,
/// and paired-machines mode. Every network step runs on a machine's
/// companion, which is the only Talkbawt client; the phone reviews and
/// confirms.
class TalkbawtController extends ChangeNotifier {
  TalkbawtController({
    required this._store,
    required this._clients,
    required this._findHost,
    this._notify,
    DateTime Function()? now,
    this.watchWait = 45,
    this.retryDelay = const Duration(seconds: 30),
    this.pairedInterval = const Duration(seconds: 5),
    Random? random,
  }) : _now = now ?? DateTime.now,
       _random = random ?? Random.secure();

  final JsonMapStore _store;
  final TalkbawtClientLease Function(SavedHost host) _clients;
  final SavedHost? Function(String hostId) _findHost;
  final Future<void> Function(TalkbawtNotice notice)? _notify;
  final DateTime Function() _now;
  final Random _random;

  /// Seconds one `talkbawt watch` is held on the server.
  final int watchWait;
  final Duration retryDelay;
  final Duration pairedInterval;

  static const storageKey = 'conductore.talkbawt.v1';

  TalkbawtSettings _settings = const TalkbawtSettings();
  List<TalkbawtOwnedThread> _threads = const [];
  Map<String, String> _creatorKeys = const {};
  bool _loaded = false;
  bool _disposed = false;
  Future<void>? _loading;

  TalkbawtSettings get settings => _settings;
  bool get loaded => _loaded;

  /// Bumped on every write to the store (not on every change on screen):
  /// what device sync listens to.
  final ValueNotifier<int> saves = ValueNotifier(0);

  /// Newest first.
  List<TalkbawtOwnedThread> get threads => _threads;
  int get unread => _threads.fold(0, (sum, t) => sum + t.unread);

  /// This install's creator key for [server], if the server issued one.
  String? creatorKeyFor(String server) => _creatorKeys[server];

  TalkbawtOwnedThread? thread(String id) =>
      _threads.where((t) => t.id == id).firstOrNull;

  /// Whether the first-use question (which server) is still to be asked.
  bool get needsFirstUseChoice => !_settings.firstUseAsked;

  Future<void> load() => _loading ??= _read();

  /// Reads the store again (a sync pull or backup import replaced it).
  Future<void> reload() async {
    _loading = null;
    await load();
  }

  Future<void> _read() async {
    final raw = await _store.readAll();
    _settings = TalkbawtSettings.fromJson(raw['settings']);
    _creatorKeys = {
      if (raw['creatorKeys'] case final Map<Object?, Object?> keys)
        for (final e in keys.entries)
          if (e.key is String && e.value is String)
            e.key! as String: e.value! as String,
    };
    _threads = [
      if (raw['threads'] case final List<Object?> list)
        for (final t in list) ?TalkbawtOwnedThread.fromJson(t),
    ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    _loaded = true;
    _changed();
  }

  Future<void> _save() async {
    await _store.writeAll({
      'settings': _settings.toJson(),
      'creatorKeys': _creatorKeys,
      'threads': [for (final t in _threads) t.toJson()],
    });
    if (!_disposed) saves.value += 1;
    _changed();
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  // --- shared links -------------------------------------------------------------

  String? _sharedLink;

  /// A link shared into the app, waiting for the unlocked app to open it.
  String? get pendingSharedLink => _sharedLink;

  void receiveSharedLink(String url) {
    _sharedLink = url;
    _changed();
  }

  /// Takes the waiting shared link (once).
  String? takeSharedLink() {
    final link = _sharedLink;
    _sharedLink = null;
    return link;
  }

  // --- settings ---------------------------------------------------------------

  /// Validates and keeps [raw] as the server (https only; http for
  /// localhost or the tailnet). Throws [TalkbawtAddressError].
  Future<void> setServer(String raw) async {
    await load();
    _settings = _settings.copyWith(
      server: talkbawtServerOrigin(raw),
      firstUseAsked: true,
    );
    await _save();
  }

  Future<void> markFirstUseAsked() async {
    await load();
    _settings = _settings.copyWith(firstUseAsked: true);
    await _save();
  }

  Future<void> setRelayMode(TalkbawtRelayMode mode) async {
    await load();
    _settings = _settings.copyWith(relay: mode);
    await _save();
  }

  Future<void> setFrom(String from) async {
    await load();
    _settings = _settings.copyWith(from: from.trim());
    await _save();
  }

  /// A fresh passphrase: four words and a number.
  String newPassphrase() => generateTalkbawtPassphrase(_random.nextInt);

  // --- companions -------------------------------------------------------------

  Future<T> _with<T>(
    SavedHost host,
    Future<T> Function(TalkbawtHostClient client) body,
  ) async {
    final lease = _clients(host);
    try {
      return await body(lease.client);
    } finally {
      await lease.release();
    }
  }

  SavedHost _host(String hostId) {
    final host = _findHost(hostId);
    if (host == null) {
      throw const TalkbawtFailure(
        'no-machine',
        'The machine that holds this link is no longer saved on this phone.',
      );
    }
    return host;
  }

  // --- hand off ---------------------------------------------------------------

  /// Asks the agent to write its own handoff; resolves the draft id.
  /// Throws a [TalkbawtFailure] `busy` while it works (use [summaryDraft]).
  Future<String> requestAgentDraft(SavedHost host, String sessionId) =>
      _with(host, (c) => c.startAgentDraft(sessionId));

  Future<TalkbawtDraftStatus> draftStatus(SavedHost host, String draftId) =>
      _with(host, (c) => c.draftStatus(draftId));

  Future<String> summaryDraft(SavedHost host, String sessionId) =>
      _with(host, (c) => c.summaryDraft(sessionId));

  /// Creates a link on [host] with this install's server and creator key,
  /// and keeps it (owner link, passphrase and keys) in secure storage.
  Future<TalkbawtCreated> createThread(
    SavedHost host,
    TalkbawtCreateRequest request, {
    String? expiresSpec,
    bool paired = false,
  }) async {
    await load();
    final server = _settings.server;
    final created = await _with(host, (c) async {
      await c.configure(server: server, creatorKey: _creatorKeys[server]);
      return c.create(request, expiresSpec: expiresSpec);
    });
    if (created.creatorKey case final key?
        when !_creatorKeys.containsKey(server)) {
      _creatorKeys = {..._creatorKeys, server: key};
    }
    _threads = [
      TalkbawtOwnedThread(
        id: created.id,
        hostId: host.id,
        server: server,
        title: created.title,
        mode: created.mode,
        createdAt: _now(),
        shareUrl: created.shareUrl,
        ownerUrl: created.ownerUrl,
        passphrase: request.passphrase,
        maxReads: created.maxReads,
        ownerKey: created.ownerKey,
        guestKey: created.guestKey,
        expiresAt: created.expiresAt,
        paired: paired,
      ),
      ..._threads,
    ];
    await _save();
    _restartWatch();
    return created;
  }

  // --- opening links ------------------------------------------------------------

  Future<TalkbawtMeta> meta(
    SavedHost host,
    TalkbawtLink link, {
    String? passphrase,
  }) => _with(host, (c) => c.meta(link: link.url, passphrase: passphrase));

  Future<TalkbawtRead> read(
    SavedHost host,
    TalkbawtLink link, {
    String? passphrase,
  }) => _with(host, (c) => c.read(link: link.url, passphrase: passphrase));

  /// Checks [agent]'s permission mode before anything reaches it: never an
  /// agent that acts without asking, and an unknown mode only when the user
  /// confirmed it.
  static void checkAgentMode(
    AgentInfo agent, {
    bool confirmedUnknownMode = false,
  }) {
    switch (agentModeSafety(agent.permissionMode)) {
      case AgentModeSafety.unsafe:
        throw TalkbawtFailure(
          'unsafe-permission-mode',
          '${agent.name} runs in '
              '${permissionModeLabel(agent.permissionMode!)} mode, where it '
              'acts without asking. Switch it to default or plan mode first.',
        );
      case AgentModeSafety.unknown when !confirmedUnknownMode:
        throw TalkbawtFailure(
          'permission-mode-unknown',
          '${agent.name} has not reported its permission mode. Confirm it '
              'is not in an auto-approve mode.',
        );
      case AgentModeSafety.unknown || AgentModeSafety.safe:
        return;
    }
  }

  /// Writes [content] to a fenced file on [host] and types the fixed
  /// "untrusted data, summarise and wait" prompt into [agent].
  Future<void> deliver(
    SavedHost host,
    AgentInfo agent,
    TalkbawtRead content, {
    bool confirmedUnknownMode = false,
  }) async {
    checkAgentMode(agent, confirmedUnknownMode: confirmedUnknownMode);
    await _with(
      host,
      (c) => c.deliver(
        sessionId: agent.id,
        read: content,
        allowUnknownMode:
            confirmedUnknownMode &&
            agentModeSafety(agent.permissionMode) == AgentModeSafety.unknown,
      ),
    );
  }

  /// Replies on a link opened on [host] (as its reader) or on an owned
  /// thread. Resolves the new message's seq.
  Future<int> reply({
    required String text,
    SavedHost? host,
    TalkbawtLink? link,
    String? passphrase,
    TalkbawtOwnedThread? owned,
    String? from,
  }) {
    if (owned != null) {
      return _with(
        _host(owned.hostId),
        (c) => c.post(id: owned.id, text: text, from: from),
      );
    }
    return _with(
      host!,
      (c) => c.post(
        link: link!.url,
        passphrase: passphrase,
        text: text,
        from: from,
      ),
    );
  }

  // --- owned threads --------------------------------------------------------------

  /// The owner's view: every message and the access log.
  Future<TalkbawtRead> readOwned(TalkbawtOwnedThread owned) =>
      _with(_host(owned.hostId), (c) => c.read(id: owned.id));

  Future<void> markSeen(String id) async {
    final t = thread(id);
    if (t == null || t.unread == 0) return;
    _replace(t.copyWith(unread: 0));
    await _save();
  }

  /// Revokes on the machine that created it (which saves the access log
  /// first), then keeps only that log here.
  Future<List<TalkbawtAccessEntry>> revoke(TalkbawtOwnedThread owned) async {
    final log = await _with(_host(owned.hostId), (c) => c.revoke(id: owned.id));
    final t = thread(owned.id) ?? owned;
    _replace(
      t.copyWith(state: 'revoked', accessLog: log, unread: 0, dropLinks: true),
    );
    await _save();
    return log;
  }

  Future<void> forget(String id) async {
    _threads = [
      for (final t in _threads)
        if (t.id != id) t,
    ];
    await _save();
  }

  void _replace(TalkbawtOwnedThread updated) {
    _threads = [
      for (final t in _threads)
        if (t.id == updated.id && t.hostId == updated.hostId) updated else t,
    ];
  }

  // --- watching -------------------------------------------------------------------

  bool _foreground = false;
  final Map<String, int> _watchLoops = {};
  int _watchGeneration = 0;

  /// Watches the owned threads while the app is in front: one held
  /// `talkbawt watch` per machine that created a live thread.
  void setForeground(bool foreground) {
    if (_foreground == foreground) return;
    _foreground = foreground;
    _restartWatch();
  }

  void _restartWatch() {
    _watchGeneration += 1;
    _watchLoops.clear();
    if (!_foreground || _disposed) return;
    final hosts = {
      for (final t in _threads)
        if (t.live && t.ownerUrl != null) t.hostId,
    };
    for (final hostId in hosts) {
      final generation = _watchGeneration;
      _watchLoops[hostId] = generation;
      unawaited(_watchLoop(hostId, generation));
    }
  }

  Future<void> _watchLoop(String hostId, int generation) async {
    while (!_disposed && _foreground && _watchGeneration == generation) {
      final host = _findHost(hostId);
      if (host == null) return;
      try {
        await watchOnce(host, wait: watchWait);
      } catch (_) {
        if (_disposed || _watchGeneration != generation) return;
        await Future<void>.delayed(retryDelay);
      }
      if (!_threads.any((t) => t.hostId == hostId && t.live)) return;
    }
  }

  /// One `talkbawt watch` on [host]; applies what changed and notifies.
  Future<void> watchOnce(SavedHost host, {int wait = 0}) async {
    final ids = [
      for (final t in _threads)
        if (t.hostId == host.id && t.live) t.id,
    ];
    if (ids.isEmpty) return;
    final changes = await _with(host, (c) => c.watch(wait: wait, ids: ids));
    await applyChanges(host.id, changes);
  }

  /// Updates the threads from a watch answer. Replies notify (tapping opens
  /// the preview, nothing else); a new reader notifies when the link has a
  /// read limit; a link that went away notifies once.
  Future<void> applyChanges(
    String hostId,
    List<TalkbawtThreadChange> changes,
  ) async {
    if (changes.isEmpty) return;
    final notices = <TalkbawtNotice>[];
    for (final change in changes) {
      final t = _threads
          .where((x) => x.id == change.id && x.hostId == hostId)
          .firstOrNull;
      if (t == null) continue;
      final replies = change.replies;
      final last = replies.isEmpty ? null : replies.last;
      _replace(
        t.copyWith(
          state: change.state,
          readers: change.readers,
          unread: t.unread + replies.length,
          lastReply: last == null
              ? null
              : '${last.fromLabel}: ${_firstLine(last.text)}',
        ),
      );
      for (final reply in replies) {
        notices.add(
          TalkbawtNotice(
            threadId: t.id,
            title: "Reply on '${t.title}'",
            body: '${reply.fromLabel}: ${_firstLine(reply.text)}',
          ),
        );
      }
      if (change.readersChanged && t.maxReads != null) {
        notices.add(
          TalkbawtNotice(
            threadId: t.id,
            title: "Your link '${t.title}' was opened",
            body:
                '${change.readers} of ${t.maxReads} readers so far. '
                'Not you? Revoke it.',
          ),
        );
      }
      if (change.state != 'live' && t.live) {
        notices.add(
          TalkbawtNotice(
            threadId: t.id,
            title: "'${t.title}' is ${change.state}",
            body: 'The link no longer works.',
          ),
        );
      }
    }
    await _save();
    final notify = _notify;
    if (notify != null) {
      for (final notice in notices) {
        await notify(notice);
      }
    }
  }

  static String _firstLine(String text) {
    final line = text.trim().split('\n').first.trim();
    return line.length > 140 ? '${line.substring(0, 139)}…' : line;
  }

  // --- relay (send to another machine's agent) ---------------------------------------

  /// The Talkbawt path of the relay setting: a one-reader, passphrase-
  /// protected handoff that expires in an hour, created on [from], read by
  /// the target's machine (the same reader that could reply), delivered to
  /// the target agent as fenced data, then revoked. The caller confirmed
  /// the exact text first.
  Future<void> relayViaTalkbawt({
    required SavedHost from,
    required String fromLabel,
    required TalkbawtRelayTarget to,
    required String text,
    bool confirmedUnknownMode = false,
  }) async {
    checkAgentMode(to.agent, confirmedUnknownMode: confirmedUnknownMode);
    final passphrase = newPassphrase();
    final created = await createThread(
      from,
      TalkbawtCreateRequest(
        title: 'From $fromLabel',
        text: text,
        mode: TalkbawtMode.handoff,
        from: fromLabel,
        expiry: TalkbawtExpiry.oneHour,
        passphrase: passphrase,
        maxReads: 1,
      ),
    );
    final link = TalkbawtLink.tryParse(created.shareUrl)!;
    try {
      final content = await read(to.host, link, passphrase: passphrase);
      await deliver(
        to.host,
        to.agent,
        content,
        confirmedUnknownMode: confirmedUnknownMode,
      );
    } finally {
      final owned = thread(created.id);
      if (owned != null) {
        try {
          await revoke(owned);
        } catch (_) {
          // It expires within the hour anyway.
        }
      }
    }
  }

  // --- paired machines ----------------------------------------------------------------

  PairedSession? _paired;
  Timer? _pairedTimer;
  bool _pairedBusy = false;

  /// The paired-machines session, running or just ended.
  PairedSession? get paired => _paired;

  /// Starts a time-boxed conversation between [a] and [b], two of the
  /// user's agents: a passphrase-protected thread (two readers, signed,
  /// expiring with the session) on A's machine, opened with [opening] as
  /// A's first message. Both agents must be in a mode that asks before
  /// acting; the phone relays each reply without a tap until [duration]
  /// is up or it is stopped.
  Future<PairedSession> startPaired({
    required SavedHost hostA,
    required AgentInfo agentA,
    required SavedHost hostB,
    required AgentInfo agentB,
    required String opening,
    Duration duration = const Duration(minutes: 30),
  }) async {
    if (_paired?.active ?? false) {
      throw const TalkbawtFailure(
        'already-paired',
        'A paired session is already running. Stop it first.',
      );
    }
    for (final agent in [agentA, agentB]) {
      if (agentModeSafety(agent.permissionMode) != AgentModeSafety.safe) {
        throw TalkbawtFailure(
          'unsafe-permission-mode',
          agentModeSafety(agent.permissionMode) == AgentModeSafety.unknown
              ? '${agent.name} has not reported its permission mode; paired '
                    'mode needs both agents in default or plan mode.'
              : '${agent.name} runs in '
                    '${permissionModeLabel(agent.permissionMode!)} mode. '
                    'Paired mode needs both agents in default or plan mode.',
        );
      }
    }
    final labelA = '${agentA.name} on ${hostA.name}';
    final labelB = '${agentB.name} on ${hostB.name}';
    final passphrase = newPassphrase();
    final minutes = duration.inMinutes.clamp(1, 7 * 24 * 60);
    final created = await createThread(
      hostA,
      TalkbawtCreateRequest(
        title: 'Paired: $labelA and $labelB',
        text: opening,
        from: labelA,
        passphrase: passphrase,
        maxReads: 2,
        signing: true,
      ),
      expiresSpec: '${minutes}m',
      paired: true,
    );
    final now = _now();
    final session = PairedSession(
      a: PairedEndpoint(hostId: hostA.id, sessionId: agentA.id, label: labelA),
      b: PairedEndpoint(hostId: hostB.id, sessionId: agentB.id, label: labelB),
      threadId: created.id,
      shareUrl: created.shareUrl,
      passphrase: passphrase,
      guestKey: created.guestKey,
      startedAt: now,
      endsAt: now.add(Duration(minutes: minutes)),
    );
    _paired = session;
    _changed();
    _pairedTimer = Timer.periodic(
      pairedInterval,
      (_) => unawaited(pairedTick()),
    );
    unawaited(pairedTick());
    return session;
  }

  /// Ends the paired session and revokes its thread.
  Future<void> stopPaired([
    PairedStopReason reason = PairedStopReason.user,
  ]) async {
    final session = _paired;
    _pairedTimer?.cancel();
    _pairedTimer = null;
    if (session == null || !session.active) return;
    session.stopped = reason;
    _changed();
    final owned = thread(session.threadId);
    if (owned != null && owned.live) {
      try {
        await revoke(owned);
      } catch (_) {
        // It expires with the session anyway.
      }
    }
  }

  String _clock(DateTime t) {
    final l = t.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(l.hour)}:${two(l.minute)}';
  }

  /// One relay step (every [pairedInterval]): stops at the deadline; hands
  /// each side what the other posted; posts each side's reply once its
  /// turn ended.
  Future<void> pairedTick() async {
    final s = _paired;
    if (s == null || !s.active) return;
    // The deadline wins over a relay step still in flight.
    if (!_now().isBefore(s.endsAt)) {
      await stopPaired(PairedStopReason.expired);
      return;
    }
    if (_pairedBusy) return;
    _pairedBusy = true;
    try {
      final hostA = _host(s.a.hostId);
      final hostB = _host(s.b.hostId);
      final link = TalkbawtLink.tryParse(s.shareUrl)!;
      final until = _clock(s.endsAt);

      // Replies owed: post them.
      if (s.aAwaitingSince case final since?) {
        final r = await _with(
          hostA,
          (c) => c.agentReply(s.a.sessionId, after: since),
        );
        if (r.ready && r.text != null) {
          final seq = await _with(
            hostA,
            (c) => c.post(id: s.threadId, text: r.text!, from: s.a.label),
          );
          s.aPosted.add(seq);
          s.aAwaitingSince = null;
          s.relayed += 1;
        }
      }
      if (s.bAwaitingSince case final since?) {
        final r = await _with(
          hostB,
          (c) => c.agentReply(s.b.sessionId, after: since),
        );
        if (r.ready && r.text != null) {
          final seq = await _with(
            hostB,
            (c) => c.post(
              link: link.url,
              passphrase: s.passphrase,
              text: r.text!,
              from: s.b.label,
              signingKey: s.guestKey,
            ),
          );
          s.bPosted.add(seq);
          s.bAwaitingSince = null;
          s.relayed += 1;
        }
      }

      // New messages: deliver them to the other side.
      if (s.bAwaitingSince == null) {
        final read = await _with(
          hostB,
          (c) =>
              c.read(link: link.url, passphrase: s.passphrase, since: s.bSeen),
        );
        final fresh = [
          for (final m in read.messages)
            if (m.seq > s.bSeen && !s.bPosted.contains(m.seq)) m,
        ];
        if (read.messages.isNotEmpty) {
          s.bSeen = read.messages.map((m) => m.seq).reduce(max);
        }
        if (fresh.isNotEmpty) {
          await _with(
            hostB,
            (c) => c.deliver(
              sessionId: s.b.sessionId,
              read: TalkbawtRead(
                title: read.title,
                mode: read.mode,
                messages: fresh,
              ),
              pairedWith: s.a.label,
              until: until,
            ),
          );
          s.bAwaitingSince = _now().millisecondsSinceEpoch;
        }
      }
      if (s.aAwaitingSince == null) {
        final read = await _with(
          hostA,
          (c) => c.read(id: s.threadId, since: s.aSeen),
        );
        final fresh = [
          for (final m in read.messages)
            if (m.seq > s.aSeen && !s.aPosted.contains(m.seq)) m,
        ];
        if (read.messages.isNotEmpty) {
          s.aSeen = max(s.aSeen, read.messages.map((m) => m.seq).reduce(max));
        }
        if (fresh.isNotEmpty) {
          await _with(
            hostA,
            (c) => c.deliver(
              sessionId: s.a.sessionId,
              read: TalkbawtRead(
                title: read.title,
                mode: read.mode,
                messages: fresh,
              ),
              pairedWith: s.b.label,
              until: until,
            ),
          );
          s.aAwaitingSince = _now().millisecondsSinceEpoch;
        }
      }
      s.lastError = null;
    } on TalkbawtFailure catch (error) {
      s.lastError = error.userMessage;
      if (error.code == 'unsafe-permission-mode') {
        await stopPaired(PairedStopReason.unsafe);
      } else if (error.code == 'revoked' ||
          error.code == 'expired' ||
          error.code == 'not_found' ||
          error.code == 'gone') {
        await stopPaired(PairedStopReason.failed);
      }
    } catch (error) {
      s.lastError = '$error';
    } finally {
      _pairedBusy = false;
      _changed();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _pairedTimer?.cancel();
    _watchGeneration += 1;
    saves.dispose();
    super.dispose();
  }
}
