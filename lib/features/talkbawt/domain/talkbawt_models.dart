import 'package:conduit/features/talkbawt/domain/talkbawt_safety.dart';

/// Thread or one-shot handoff.
enum TalkbawtMode {
  /// Two-way: both sides post.
  thread,

  /// Read-only after creation.
  handoff;

  static TalkbawtMode parse(Object? raw) =>
      raw == 'handoff' ? TalkbawtMode.handoff : TalkbawtMode.thread;

  String get label => this == TalkbawtMode.thread ? 'Thread' : 'Handoff';
}

/// How long a link lives (the server caps it at 7 days).
enum TalkbawtExpiry {
  oneHour('1h', '1 hour'),
  oneDay('1d', '1 day'),
  sevenDays('7d', '7 days');

  const TalkbawtExpiry(this.spec, this.label);

  /// What the server's `expires_in` takes.
  final String spec;
  final String label;
}

/// A failure the companion or the server reported, with its code
/// (`passphrase_required`, `read_limit_reached`, `possible_credentials`,
/// `unsafe-permission-mode`, …).
class TalkbawtFailure implements Exception {
  const TalkbawtFailure(
    this.code,
    this.message, {
    this.findings = const [],
    this.status,
  });

  final String code;
  final String message;
  final List<SecretFinding> findings;
  final int? status;

  /// Plain words for the codes a person can act on.
  String get userMessage => switch (code) {
    'passphrase_required' => 'This link needs its passphrase.',
    'too_many_attempts' =>
      'Too many wrong passphrases from this machine; try again in an hour.',
    'read_limit_reached' =>
      'This link has already been opened by as many readers as it allows.',
    'revoked' => 'This link was revoked by its owner.',
    'expired' => 'This link has expired.',
    'not_found' => 'No such link: it expired, or was revoked a while ago.',
    'read_only' => 'This is a one-shot handoff: it takes no replies.',
    'possible_credentials' =>
      'This looks like it holds a live credential. Say where the secret '
          'lives instead of what it is.',
    'unsafe-permission-mode' => message,
    'permission-mode-unknown' => message,
    'rate_limited' => 'The Talkbawt server asks to slow down; try again soon.',
    'unreachable' => 'The Talkbawt server could not be reached: $message',
    'unknown command' || 'outdated' =>
      'The Conductore companion on this machine is too old for Talkbawt. '
          'Update it from Settings › Agents › Agent hooks.',
    _ => message,
  };

  @override
  String toString() => userMessage;
}

/// One message, as read. Everything in it was written by someone else's
/// agent: shown inert, never rendered.
class TalkbawtMessage {
  const TalkbawtMessage({
    required this.seq,
    required this.from,
    required this.at,
    required this.text,
    this.verified = false,
    this.signedBy,
  });

  final int seq;

  /// Unauthenticated unless [verified]: shown as "claims to be".
  final String from;
  final String at;
  final String text;
  final bool verified;

  /// `owner` or `guest` when [verified].
  final String? signedBy;

  static TalkbawtMessage? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final seq = raw['seq'];
    if (seq is! num) return null;
    return TalkbawtMessage(
      seq: seq.toInt(),
      from: raw['from'] is String ? raw['from'] as String : '',
      at: raw['at'] is String ? raw['at'] as String : '',
      text: raw['text'] is String ? raw['text'] as String : '',
      verified: raw['verified'] == true,
      signedBy: raw['signedBy'] is String ? raw['signedBy'] as String : null,
    );
  }

  Map<String, Object?> toJson() => {
    'seq': seq,
    'from': from,
    'at': at,
    'verified': verified,
    'signedBy': signedBy,
    'text': text,
  };

  /// 'claims to be: Ana (Codex)', or 'Ana (Codex), verified guest key'.
  String get fromLabel {
    final who = from.trim().isEmpty ? 'someone' : from.trim();
    return verified
        ? '$who · verified ${signedBy ?? ''} key'.trimRight()
        : 'claims to be: $who (unverified)';
  }
}

/// One access-log line (owner views only).
class TalkbawtAccessEntry {
  const TalkbawtAccessEntry({
    required this.action,
    this.role,
    this.ok = true,
    this.ip,
    this.ua,
    this.note,
    this.at,
  });

  final String action;
  final String? role;
  final bool ok;
  final String? ip;
  final String? ua;
  final String? note;
  final String? at;

  static TalkbawtAccessEntry? fromJson(Object? raw) {
    if (raw is! Map || raw['action'] is! String) return null;
    String? s(String key) => raw[key] is String ? raw[key] as String : null;
    return TalkbawtAccessEntry(
      action: raw['action'] as String,
      role: s('role'),
      ok: raw['ok'] != false,
      ip: s('ip'),
      ua: s('ua'),
      note: s('note'),
      at: s('at'),
    );
  }

  Map<String, Object?> toJson() => {
    'action': action,
    'role': role,
    'ok': ok,
    'ip': ip,
    'ua': ua,
    'note': note,
    'at': at,
  };
}

/// The free check before a read (`/meta`): never counted.
class TalkbawtMeta {
  const TalkbawtMeta({
    required this.mode,
    required this.passphraseRequired,
    this.title,
    this.expiresAt,
    this.maxReads,
    this.readsRemaining,
    this.alreadyCounted = false,
    this.admitted = true,
    this.usesARead = false,
    this.messageCount,
  });

  final TalkbawtMode mode;
  final bool passphraseRequired;
  final String? title;
  final String? expiresAt;
  final int? maxReads;
  final int? readsRemaining;
  final bool alreadyCounted;
  final bool admitted;

  /// Reading would spend one of [maxReads].
  final bool usesARead;
  final int? messageCount;

  static TalkbawtMeta fromJson(Map<String, Object?> json) {
    int? n(String key) => json[key] is num ? (json[key] as num).toInt() : null;
    return TalkbawtMeta(
      mode: TalkbawtMode.parse(json['mode']),
      passphraseRequired: json['passphraseRequired'] == true,
      title: json['title'] is String ? json['title'] as String : null,
      expiresAt: json['expiresAt'] is String
          ? json['expiresAt'] as String
          : null,
      maxReads: n('maxReads'),
      readsRemaining: n('readsRemaining'),
      alreadyCounted: json['alreadyCounted'] == true,
      admitted: json['admitted'] != false,
      usesARead: json['usesARead'] == true,
      messageCount: n('messageCount'),
    );
  }
}

/// A read: the thread's header and its messages, plus the owner's view.
class TalkbawtRead {
  const TalkbawtRead({
    required this.title,
    required this.mode,
    required this.messages,
    this.role = 'guest',
    this.expiresAt,
    this.maxReads,
    this.readsRemaining,
    this.securityNotice,
    this.accessLog,
    this.distinctReaders,
    this.revoked = false,
  });

  final String title;
  final TalkbawtMode mode;
  final List<TalkbawtMessage> messages;
  final String role;
  final String? expiresAt;
  final int? maxReads;
  final int? readsRemaining;
  final String? securityNotice;
  final List<TalkbawtAccessEntry>? accessLog;
  final int? distinctReaders;
  final bool revoked;

  static TalkbawtRead fromJson(Map<String, Object?> json) {
    final thread = json['thread'] is Map
        ? Map<String, Object?>.from(json['thread'] as Map)
        : const <String, Object?>{};
    final owner = json['owner'] is Map
        ? Map<String, Object?>.from(json['owner'] as Map)
        : null;
    int? n(Map<String, Object?> m, String key) =>
        m[key] is num ? (m[key] as num).toInt() : null;
    return TalkbawtRead(
      title: thread['title'] is String ? thread['title'] as String : '',
      mode: TalkbawtMode.parse(thread['mode']),
      role: json['role'] is String ? json['role'] as String : 'guest',
      expiresAt: thread['expiresAt'] is String
          ? thread['expiresAt'] as String
          : null,
      maxReads: n(thread, 'maxReads'),
      readsRemaining: n(thread, 'readsRemaining'),
      securityNotice: json['securityNotice'] is String
          ? json['securityNotice'] as String
          : null,
      messages: [
        if (json['messages'] case final List<Object?> list)
          for (final m in list) ?TalkbawtMessage.fromJson(m),
      ],
      accessLog: owner == null
          ? null
          : [
              if (owner['accessLog'] case final List<Object?> list)
                for (final e in list) ?TalkbawtAccessEntry.fromJson(e),
            ],
      distinctReaders: owner == null ? null : n(owner, 'distinctReaders'),
      revoked: json['revoked'] == true,
    );
  }

  /// The messages as plain text (Copy text).
  String get plainText => [
    for (final m in messages) '— ${m.fromLabel}, ${m.at}\n${m.text}',
  ].join('\n\n');
}

/// What a new link is created with.
class TalkbawtCreateRequest {
  const TalkbawtCreateRequest({
    required this.title,
    required this.text,
    this.mode = TalkbawtMode.thread,
    this.from = 'Conductore',
    this.expiry = TalkbawtExpiry.oneDay,
    this.passphrase,
    this.maxReads,
    this.signing = false,
    this.overrideSecretScan = false,
  });

  final String title;
  final String text;
  final TalkbawtMode mode;
  final String from;
  final TalkbawtExpiry expiry;
  final String? passphrase;
  final int? maxReads;
  final bool signing;
  final bool overrideSecretScan;

  /// Also sets `expires` to [expiresSpec] when given (paired mode: "30m").
  Map<String, Object?> toJson({String? expiresSpec}) => {
    'title': title,
    'text': text,
    'mode': mode.name,
    'from': from,
    'expires': expiresSpec ?? expiry.spec,
    if (passphrase != null && passphrase!.isNotEmpty) 'passphrase': passphrase,
    'maxReads': ?maxReads,
    if (signing) 'signing': true,
    if (overrideSecretScan) 'overrideSecretScan': true,
  };
}

/// A thread this phone created (or recovered): stored in secure storage,
/// synced only end-to-end encrypted. [ownerUrl] never leaves the phone and
/// the companion that created it.
class TalkbawtOwnedThread {
  const TalkbawtOwnedThread({
    required this.id,
    required this.hostId,
    required this.server,
    required this.title,
    required this.mode,
    required this.createdAt,
    this.shareUrl,
    this.ownerUrl,
    this.passphrase,
    this.maxReads,
    this.ownerKey,
    this.guestKey,
    this.expiresAt,
    this.state = 'live',
    this.readers = 0,
    this.unread = 0,
    this.lastReply,
    this.accessLog = const [],
    this.retainedUntil,
    this.paired = false,
  });

  /// The companion's local id on [hostId].
  final String id;
  final String hostId;
  final String server;
  final String title;
  final TalkbawtMode mode;
  final DateTime createdAt;
  final String? shareUrl;
  final String? ownerUrl;
  final String? passphrase;
  final int? maxReads;

  /// Signing keys (shown once by the server); the guest key goes to the
  /// other side over a different channel, like a passphrase.
  final String? ownerKey;
  final String? guestKey;
  final String? expiresAt;

  /// live, revoked, expired or gone.
  final String state;
  final int readers;

  /// Replies since the list was last opened.
  final int unread;

  /// The newest reply's first line and claimed sender, for the list.
  final String? lastReply;

  /// Saved right before a revoke.
  final List<TalkbawtAccessEntry> accessLog;
  final String? retainedUntil;

  /// Made by paired-machines mode.
  final bool paired;

  bool get live => state == 'live';

  DateTime? get expires =>
      expiresAt == null ? null : DateTime.tryParse(expiresAt!);

  TalkbawtOwnedThread copyWith({
    String? state,
    int? readers,
    int? unread,
    String? lastReply,
    List<TalkbawtAccessEntry>? accessLog,
    String? retainedUntil,
    bool dropLinks = false,
  }) => TalkbawtOwnedThread(
    id: id,
    hostId: hostId,
    server: server,
    title: title,
    mode: mode,
    createdAt: createdAt,
    shareUrl: dropLinks ? null : shareUrl,
    ownerUrl: dropLinks ? null : ownerUrl,
    passphrase: dropLinks ? null : passphrase,
    maxReads: maxReads,
    ownerKey: dropLinks ? null : ownerKey,
    guestKey: dropLinks ? null : guestKey,
    expiresAt: expiresAt,
    state: state ?? this.state,
    readers: readers ?? this.readers,
    unread: unread ?? this.unread,
    lastReply: lastReply ?? this.lastReply,
    accessLog: accessLog ?? this.accessLog,
    retainedUntil: retainedUntil ?? this.retainedUntil,
    paired: paired,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'hostId': hostId,
    'server': server,
    'title': title,
    'mode': mode.name,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'shareUrl': ?shareUrl,
    'ownerUrl': ?ownerUrl,
    'passphrase': ?passphrase,
    'maxReads': ?maxReads,
    'ownerKey': ?ownerKey,
    'guestKey': ?guestKey,
    'expiresAt': ?expiresAt,
    'state': state,
    'readers': readers,
    'unread': unread,
    'lastReply': ?lastReply,
    if (accessLog.isNotEmpty)
      'accessLog': [for (final e in accessLog) e.toJson()],
    'retainedUntil': ?retainedUntil,
    if (paired) 'paired': true,
  };

  static TalkbawtOwnedThread? fromJson(Object? raw) {
    if (raw is! Map) return null;
    String? s(String key) => raw[key] is String ? raw[key] as String : null;
    final id = s('id');
    final hostId = s('hostId');
    if (id == null || hostId == null) return null;
    return TalkbawtOwnedThread(
      id: id,
      hostId: hostId,
      server: s('server') ?? '',
      title: s('title') ?? 'Handoff',
      mode: TalkbawtMode.parse(raw['mode']),
      createdAt:
          DateTime.tryParse(s('createdAt') ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      shareUrl: s('shareUrl'),
      ownerUrl: s('ownerUrl'),
      passphrase: s('passphrase'),
      maxReads: raw['maxReads'] is num
          ? (raw['maxReads'] as num).toInt()
          : null,
      ownerKey: s('ownerKey'),
      guestKey: s('guestKey'),
      expiresAt: s('expiresAt'),
      state: s('state') ?? 'live',
      readers: raw['readers'] is num ? (raw['readers'] as num).toInt() : 0,
      unread: raw['unread'] is num ? (raw['unread'] as num).toInt() : 0,
      lastReply: s('lastReply'),
      accessLog: [
        if (raw['accessLog'] case final List<Object?> list)
          for (final e in list) ?TalkbawtAccessEntry.fromJson(e),
      ],
      retainedUntil: s('retainedUntil'),
      paired: raw['paired'] == true,
    );
  }
}

/// What `talkbawt watch` reported for one owned thread.
class TalkbawtThreadChange {
  const TalkbawtThreadChange({
    required this.id,
    required this.state,
    required this.readers,
    this.readersChanged = false,
    this.replies = const [],
  });

  final String id;
  final String state;
  final int readers;
  final bool readersChanged;
  final List<TalkbawtMessage> replies;

  static TalkbawtThreadChange? fromJson(Object? raw) {
    if (raw is! Map || raw['id'] is! String) return null;
    return TalkbawtThreadChange(
      id: raw['id'] as String,
      state: raw['state'] is String ? raw['state'] as String : 'live',
      readers: raw['readers'] is num ? (raw['readers'] as num).toInt() : 0,
      readersChanged: raw['readersChanged'] == true,
      replies: [
        if (raw['replies'] case final List<Object?> list)
          for (final m in list) ?TalkbawtMessage.fromJson(m),
      ],
    );
  }
}

/// A new link, as the companion created it.
class TalkbawtCreated {
  const TalkbawtCreated({
    required this.id,
    required this.server,
    required this.title,
    required this.mode,
    required this.shareUrl,
    required this.ownerUrl,
    this.expiresAt,
    this.maxReads,
    this.passphraseRequired = false,
    this.ownerKey,
    this.guestKey,
    this.creatorKey,
  });

  final String id;
  final String server;
  final String title;
  final TalkbawtMode mode;
  final String shareUrl;
  final String ownerUrl;
  final String? expiresAt;
  final int? maxReads;
  final bool passphraseRequired;
  final String? ownerKey;
  final String? guestKey;

  /// Set when the server issued this install's creator key.
  final String? creatorKey;

  static TalkbawtCreated fromJson(Map<String, Object?> json) {
    String s(String key) => json[key] is String ? json[key] as String : '';
    final signing = json['signing'] is Map ? json['signing'] as Map : null;
    return TalkbawtCreated(
      id: s('id'),
      server: s('server'),
      title: s('title'),
      mode: TalkbawtMode.parse(json['mode']),
      shareUrl: s('shareUrl'),
      ownerUrl: s('ownerUrl'),
      expiresAt: json['expiresAt'] is String
          ? json['expiresAt'] as String
          : null,
      maxReads: json['maxReads'] is num
          ? (json['maxReads'] as num).toInt()
          : null,
      passphraseRequired: json['passphraseRequired'] == true,
      ownerKey: signing?['ownerKey'] is String
          ? signing!['ownerKey'] as String
          : null,
      guestKey: signing?['guestKey'] is String
          ? signing!['guestKey'] as String
          : null,
      creatorKey: json['creatorKey'] is String
          ? json['creatorKey'] as String
          : null,
    );
  }
}
