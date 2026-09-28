import 'dart:math';

import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/sync/data/app_local_sync_store.dart';
import 'package:conduit/features/talkbawt/domain/talkbawt_host_client.dart';
import 'package:conduit/features/talkbawt/domain/talkbawt_models.dart';
import 'package:conduit/features/talkbawt/presentation/talkbawt_controller.dart';

SavedHost tbHost(String id) => SavedHost(
  id: id,
  name: id,
  host: '$id.example',
  port: 22,
  username: 'me',
  authMethod: SshAuthMethod.password,
);

AgentInfo tbAgent(
  String id, {
  String? mode = 'default',
  AgentAttentionState state = AgentAttentionState.needsInput,
}) => AgentInfo(id: id, name: id, state: state, permissionMode: mode);

class MemoryJsonMapStore implements JsonMapStore {
  Map<String, Object?> data = {};

  @override
  Future<Map<String, Object?>> readAll() async => data;

  @override
  Future<void> writeAll(Map<String, Object?> values) async => data = values;
}

const shareUrl =
    'https://talkbawt.outsmartis.dev/t/g_0123456789abcdef0123456789abcdef';
const ownerUrl =
    'https://talkbawt.outsmartis.dev/t/o_fedcba9876543210fedcba9876543210';

TalkbawtMessage tbMessage(
  int seq,
  String text, {
  String from = 'Ana (Codex)',
}) => TalkbawtMessage(
  seq: seq,
  from: from,
  at: '2026-09-28T10:00:00Z',
  text: text,
);

/// A companion that records every call and answers from its fields.
class FakeTalkbawtClient implements TalkbawtHostClient {
  FakeTalkbawtClient(this.name);

  final String name;
  final calls = <String>[];
  final configured = <(String, String?)>[];
  TalkbawtCreateRequest? lastCreate;
  String? lastExpiresSpec;
  final delivered =
      <
        ({
          String sessionId,
          TalkbawtRead read,
          bool allowUnknownMode,
          String? pairedWith,
        })
      >[];
  final posts =
      <
        ({
          String? link,
          String? id,
          String text,
          String? passphrase,
          String? signingKey,
        })
      >[];
  int nextSeq = 2;

  String? issueCreatorKey = 'k_${'a' * 48}';
  TalkbawtMeta meta0 = const TalkbawtMeta(
    mode: TalkbawtMode.thread,
    passphraseRequired: false,
  );
  TalkbawtRead read0 = TalkbawtRead(
    title: 'Migration handoff',
    mode: TalkbawtMode.thread,
    messages: [tbMessage(1, '## State\nAll green.')],
  );
  List<TalkbawtMessage> Function(int since)? readSince;
  List<TalkbawtThreadChange> watchAnswer = const [];
  List<TalkbawtAccessEntry> revokeLog = const [
    TalkbawtAccessEntry(action: 'read', role: 'guest', ua: 'Mozilla'),
  ];
  Object? draftError;
  String draftId = 'aaaaaaaaaaaa';
  List<TalkbawtDraftStatus> draftStatuses = [
    const TalkbawtDraftStatus(ready: true, text: '## Goal\nShip it.'),
  ];
  String summaryText = '## Goal\nSummarised.';
  TalkbawtAgentReply Function(String sessionId)? reply;
  Object? deliverError;

  @override
  Future<void> configure({required String server, String? creatorKey}) async {
    calls.add('configure');
    configured.add((server, creatorKey));
  }

  @override
  Future<TalkbawtCreated> create(
    TalkbawtCreateRequest request, {
    String? expiresSpec,
  }) async {
    calls.add('create');
    lastCreate = request;
    lastExpiresSpec = expiresSpec;
    final key = issueCreatorKey;
    issueCreatorKey = null;
    return TalkbawtCreated(
      id: name.padRight(12, '0').substring(0, 12),
      server: 'https://talkbawt.outsmartis.dev',
      title: request.title,
      mode: request.mode,
      shareUrl: shareUrl,
      ownerUrl: ownerUrl,
      maxReads: request.maxReads,
      passphraseRequired: request.passphrase != null,
      ownerKey: request.signing ? 'sk_o_${'1' * 48}' : null,
      guestKey: request.signing ? 'sk_g_${'2' * 48}' : null,
      creatorKey: key,
    );
  }

  @override
  Future<TalkbawtMeta> meta({
    String? link,
    String? id,
    String? passphrase,
  }) async {
    calls.add('meta');
    return meta0;
  }

  @override
  Future<TalkbawtRead> read({
    String? link,
    String? id,
    String? passphrase,
    int since = 0,
  }) async {
    calls.add('read');
    final since0 = readSince;
    if (since0 == null) return read0;
    return TalkbawtRead(
      title: read0.title,
      mode: read0.mode,
      messages: since0(since),
    );
  }

  @override
  Future<int> post({
    required String text,
    String? link,
    String? id,
    String? passphrase,
    String? from,
    String? signingKey,
  }) async {
    calls.add('post');
    posts.add((
      link: link,
      id: id,
      text: text,
      passphrase: passphrase,
      signingKey: signingKey,
    ));
    return nextSeq++;
  }

  @override
  Future<List<TalkbawtThreadChange>> watch({
    int wait = 45,
    List<String>? ids,
  }) async {
    calls.add('watch');
    return watchAnswer;
  }

  @override
  Future<List<TalkbawtAccessEntry>> revoke({required String id}) async {
    calls.add('revoke');
    return revokeLog;
  }

  @override
  Future<void> deliver({
    required String sessionId,
    required TalkbawtRead read,
    bool allowUnknownMode = false,
    String? pairedWith,
    String? until,
  }) async {
    calls.add('deliver');
    if (deliverError case final error?) throw error;
    delivered.add((
      sessionId: sessionId,
      read: read,
      allowUnknownMode: allowUnknownMode,
      pairedWith: pairedWith,
    ));
  }

  @override
  Future<String> startAgentDraft(String sessionId) async {
    calls.add('draft');
    if (draftError case final error?) throw error;
    return draftId;
  }

  @override
  Future<TalkbawtDraftStatus> draftStatus(String draftId) async {
    calls.add('draft-status');
    return draftStatuses.length > 1
        ? draftStatuses.removeAt(0)
        : draftStatuses.first;
  }

  @override
  Future<String> summaryDraft(String sessionId) async {
    calls.add('summary');
    return summaryText;
  }

  @override
  Future<TalkbawtAgentReply> agentReply(
    String sessionId, {
    required int after,
  }) async {
    calls.add('reply');
    return reply?.call(sessionId) ?? const TalkbawtAgentReply(ready: false);
  }
}

/// A controller over [clients] (one fake per machine id) and a memory
/// store.
({
  TalkbawtController controller,
  MemoryJsonMapStore store,
  List<TalkbawtNotice> notices,
})
tbController(
  Map<String, FakeTalkbawtClient> clients, {
  DateTime Function()? now,
  Duration pairedInterval = const Duration(hours: 1),
}) {
  final store = MemoryJsonMapStore();
  final notices = <TalkbawtNotice>[];
  final hosts = {for (final id in clients.keys) id: tbHost(id)};
  final controller = TalkbawtController(
    store: store,
    clients: (host) => (client: clients[host.id]!, release: () async {}),
    findHost: (id) => hosts[id],
    notify: (n) async => notices.add(n),
    now: now,
    pairedInterval: pairedInterval,
    random: Random(7),
  );
  return (controller: controller, store: store, notices: notices);
}
