import 'dart:convert';

import 'package:conduit/features/agent_attention/data/conductore_host_attention_provider.dart';
import 'package:conduit/features/agent_attention/data/remote_tool_command.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/talkbawt/domain/talkbawt_host_client.dart';
import 'package:conduit/features/talkbawt/domain/talkbawt_models.dart';
import 'package:conduit/features/talkbawt/domain/talkbawt_safety.dart';

/// [TalkbawtHostClient] over the companion's CLI on an exec channel. Every
/// secret (links, passphrases, keys, texts) goes on stdin as one JSON
/// object: never in the command line, which other users of the machine
/// can see.
class ConductoreTalkbawtClient implements TalkbawtHostClient {
  const ConductoreTalkbawtClient(this._runner);

  final AgentCommandRunner _runner;

  static const _timeout = Duration(seconds: 30);

  /// `conductore-hostd talkbawt <args>` through the PATH wrapper.
  static String command(String args) =>
      ConductoreHostAttentionProvider.remoteCommand('talkbawt $args');

  Future<Map<String, Object?>> _run(
    String args, {
    Object? stdin,
    Duration timeout = _timeout,
  }) async {
    final runner = _runner;
    final AgentCommandResult result;
    if (stdin != null) {
      if (runner is! StdinAgentCommandRunner) {
        throw const TalkbawtFailure(
          'unsupported',
          'This connection cannot pass data on stdin.',
        );
      }
      result = await runner.runWithStdin(
        command(args),
        stdin: stdin is String ? stdin : jsonEncode(stdin),
        timeout: timeout,
      );
    } else {
      result = await runner.run(command(args), timeout: timeout);
    }
    final stderr = result.stderr.trim();
    if (result.exitCode == 127 ||
        stderr.contains('command not found') ||
        stderr.contains('conductore-hostd: not found')) {
      throw const TalkbawtFailure(
        'not-installed',
        'The Conductore companion is not installed on this machine.',
      );
    }
    Map<String, Object?>? json;
    final lines = result.stdout.trim().split('\n');
    try {
      final decoded = jsonDecode(lines.last);
      if (decoded is Map) json = Map<String, Object?>.from(decoded);
    } catch (_) {}
    if (json == null) {
      throw TalkbawtFailure(
        'failed',
        stderr.isNotEmpty ? stderr : 'The companion gave no answer.',
      );
    }
    if (json['error'] is String) {
      final message = json['error'] as String;
      if (message.startsWith('unknown command')) {
        throw const TalkbawtFailure(
          'outdated',
          'The companion predates Talkbawt.',
        );
      }
      throw TalkbawtFailure(
        json['code'] is String ? json['code'] as String : 'failed',
        message,
        status: json['status'] is num ? (json['status'] as num).toInt() : null,
        findings: [
          if (json['findings'] case final List<Object?> list)
            for (final f in list) ?SecretFinding.fromJson(f),
        ],
      );
    }
    return json;
  }

  Map<String, Object?> _target(
    String? link,
    String? id,
    String? passphrase,
  ) => {
    'link': ?link,
    'id': ?id,
    if (passphrase != null && passphrase.isNotEmpty) 'passphrase': passphrase,
  };

  @override
  Future<void> configure({required String server, String? creatorKey}) async {
    final key = creatorKey != null && creatorKey.isNotEmpty;
    await _run(
      'config --server ${shellQuoteArgument(server)}'
      '${key ? ' --creator-key-from-stdin' : ''}',
      stdin: key ? creatorKey : null,
    );
  }

  @override
  Future<TalkbawtCreated> create(
    TalkbawtCreateRequest request, {
    String? expiresSpec,
  }) async => TalkbawtCreated.fromJson(
    await _run('create -', stdin: request.toJson(expiresSpec: expiresSpec)),
  );

  @override
  Future<TalkbawtMeta> meta({
    String? link,
    String? id,
    String? passphrase,
  }) async => TalkbawtMeta.fromJson(
    await _run('meta -', stdin: _target(link, id, passphrase)),
  );

  @override
  Future<TalkbawtRead> read({
    String? link,
    String? id,
    String? passphrase,
    int since = 0,
  }) async => TalkbawtRead.fromJson(
    await _run(
      'read -',
      stdin: {..._target(link, id, passphrase), if (since > 0) 'since': since},
    ),
  );

  @override
  Future<int> post({
    required String text,
    String? link,
    String? id,
    String? passphrase,
    String? from,
    String? signingKey,
  }) async {
    final json = await _run(
      'post -',
      stdin: {
        ..._target(link, id, passphrase),
        'text': text,
        'from': ?from,
        'signingKey': ?signingKey,
      },
    );
    return (json['seq'] as num?)?.toInt() ?? 0;
  }

  @override
  Future<List<TalkbawtThreadChange>> watch({
    int wait = 45,
    List<String>? ids,
  }) async {
    final json = await _run(
      'watch --wait $wait'
      '${ids == null || ids.isEmpty ? '' : ' --id ${shellQuoteArgument(ids.join(','))}'}',
      timeout: Duration(seconds: wait + 30),
    );
    return [
      if (json['threads'] case final List<Object?> list)
        for (final t in list) ?TalkbawtThreadChange.fromJson(t),
    ];
  }

  @override
  Future<List<TalkbawtAccessEntry>> revoke({required String id}) async {
    final json = await _run('revoke -', stdin: {'id': id});
    return [
      if (json['accessLog'] case final List<Object?> list)
        for (final e in list) ?TalkbawtAccessEntry.fromJson(e),
    ];
  }

  @override
  Future<void> deliver({
    required String sessionId,
    required TalkbawtRead read,
    bool allowUnknownMode = false,
    String? pairedWith,
    String? until,
  }) async {
    await _run(
      [
        'deliver ${shellQuoteArgument(sessionId)}',
        if (allowUnknownMode) '--allow-unknown-mode',
        if (pairedWith != null)
          '--paired-with ${shellQuoteArgument(pairedWith)}',
        if (until != null) '--until ${shellQuoteArgument(until)}',
      ].join(' '),
      stdin: {
        'title': read.title,
        'mode': read.mode.name,
        'messages': [for (final m in read.messages) m.toJson()],
      },
    );
  }

  @override
  Future<String> startAgentDraft(String sessionId) async {
    final json = await _run('draft ${shellQuoteArgument(sessionId)}');
    return json['id'] as String? ?? '';
  }

  @override
  Future<TalkbawtDraftStatus> draftStatus(String draftId) async {
    final json = await _run('draft-status ${shellQuoteArgument(draftId)}');
    return TalkbawtDraftStatus(
      ready: json['ready'] == true,
      text: json['text'] is String ? json['text'] as String : null,
      expired: json['expired'] == true,
    );
  }

  @override
  Future<String> summaryDraft(String sessionId) async {
    final json = await _run(
      'draft ${shellQuoteArgument(sessionId)} --summary --timeout-ms 60000',
      timeout: const Duration(seconds: 75),
    );
    return json['text'] as String? ?? '';
  }

  @override
  Future<TalkbawtAgentReply> agentReply(
    String sessionId, {
    required int after,
  }) async {
    final json = await _run(
      'reply ${shellQuoteArgument(sessionId)} --after $after',
    );
    return TalkbawtAgentReply(
      ready: json['ready'] == true,
      text: json['text'] is String ? json['text'] as String : null,
      state: json['state'] is String ? json['state'] as String : null,
    );
  }
}
