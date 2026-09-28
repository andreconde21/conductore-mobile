import 'package:conduit/features/talkbawt/domain/talkbawt_models.dart';

/// A handoff draft being written by the agent itself.
class TalkbawtDraftStatus {
  const TalkbawtDraftStatus({
    required this.ready,
    this.text,
    this.expired = false,
  });

  final bool ready;
  final String? text;
  final bool expired;
}

/// The agent's reply for paired mode, once its turn ended.
class TalkbawtAgentReply {
  const TalkbawtAgentReply({required this.ready, this.text, this.state});

  final bool ready;
  final String? text;
  final String? state;
}

/// One machine's companion as a Talkbawt client (`conductore-hostd
/// talkbawt …`, host/README.md). Links, passphrases and keys always go on
/// stdin. Failures are [TalkbawtFailure]s.
abstract interface class TalkbawtHostClient {
  /// Sets the server (and this install's creator key for it) on the
  /// companion before a create.
  Future<void> configure({required String server, String? creatorKey});

  Future<TalkbawtCreated> create(
    TalkbawtCreateRequest request, {
    String? expiresSpec,
  });

  Future<TalkbawtMeta> meta({String? link, String? id, String? passphrase});

  Future<TalkbawtRead> read({
    String? link,
    String? id,
    String? passphrase,
    int since = 0,
  });

  /// Resolves the new message's seq.
  Future<int> post({
    required String text,
    String? link,
    String? id,
    String? passphrase,
    String? from,
    String? signingKey,
  });

  /// Held up to [wait] seconds; the owned threads on this machine that
  /// changed.
  Future<List<TalkbawtThreadChange>> watch({int wait = 45, List<String>? ids});

  /// The access log saved right before the revoke.
  Future<List<TalkbawtAccessEntry>> revoke({required String id});

  /// Writes [read] to a fenced file on the machine and types the fixed
  /// prompt into [sessionId]. [pairedWith] frames it for paired mode.
  Future<void> deliver({
    required String sessionId,
    required TalkbawtRead read,
    bool allowUnknownMode = false,
    String? pairedWith,
    String? until,
  });

  /// Asks the agent to write a draft; resolves its id. Throws a
  /// [TalkbawtFailure] with code `busy` while the agent works.
  Future<String> startAgentDraft(String sessionId);

  Future<TalkbawtDraftStatus> draftStatus(String draftId);

  /// The fallback draft: Claude over the transcript, no tools.
  Future<String> summaryDraft(String sessionId);

  Future<TalkbawtAgentReply> agentReply(String sessionId, {required int after});
}
