/// One side of a paired-machines session: an agent on one of the user's
/// machines.
class PairedEndpoint {
  const PairedEndpoint({
    required this.hostId,
    required this.sessionId,
    required this.label,
  });

  final String hostId;
  final String sessionId;

  /// "api on devbox".
  final String label;
}

/// Why a paired session ended.
enum PairedStopReason {
  user('Stopped'),
  expired('Time is up'),
  failed('Stopped after an error'),
  unsafe('Stopped: an agent switched to an auto-approve mode');

  const PairedStopReason(this.label);

  final String label;
}

/// A time-boxed conversation between two of the user's own agents over a
/// passphrase-protected Talkbawt thread, relayed by the phone without a
/// tap per message (André, 2026-09-27). A owns the thread; B reads it as a
/// guest with the passphrase and the guest signing key.
class PairedSession {
  PairedSession({
    required this.a,
    required this.b,
    required this.threadId,
    required this.shareUrl,
    required this.passphrase,
    required this.startedAt,
    required this.endsAt,
    this.guestKey,
  });

  final PairedEndpoint a;
  final PairedEndpoint b;

  /// The thread's id on A's companion.
  final String threadId;
  final String shareUrl;
  final String passphrase;
  final String? guestKey;
  final DateTime startedAt;
  final DateTime endsAt;

  /// Messages relayed so far, both ways.
  int relayed = 0;

  /// The last message seq each side has been given.
  int aSeen = 1;
  int bSeen = 0;

  /// Seqs each side posted (never delivered back to itself).
  final Set<int> aPosted = {1};
  final Set<int> bPosted = {};

  /// When a message was last delivered to a side, which now owes a reply
  /// (epoch ms), or null.
  int? aAwaitingSince;
  int? bAwaitingSince;

  PairedStopReason? stopped;
  String? lastError;

  bool get active => stopped == null;

  Duration remaining(DateTime now) {
    final left = endsAt.difference(now);
    return left.isNegative ? Duration.zero : left;
  }
}
