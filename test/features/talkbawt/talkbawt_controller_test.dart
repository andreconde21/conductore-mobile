import 'package:conduit/features/talkbawt/domain/paired_session.dart';
import 'package:conduit/features/talkbawt/domain/talkbawt_host_client.dart';
import 'package:conduit/features/talkbawt/domain/talkbawt_link.dart';
import 'package:conduit/features/talkbawt/domain/talkbawt_models.dart';
import 'package:conduit/features/talkbawt/domain/talkbawt_settings.dart';
import 'package:conduit/features/talkbawt/presentation/talkbawt_controller.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'talkbawt_fakes.dart';

void main() {
  test(
    'create: server and creator key first, then the owned link is kept',
    () async {
      final devbox = FakeTalkbawtClient('devbox');
      final t = tbController({'devbox': devbox});
      final created = await t.controller.createThread(
        tbHost('devbox'),
        const TalkbawtCreateRequest(
          title: 'Handoff',
          text: 'state',
          passphrase: 'amber-canal-otter-quiet-47',
          maxReads: 2,
        ),
      );
      expect(devbox.calls, ['configure', 'create']);
      expect(devbox.configured.single, (defaultTalkbawtServer, null));
      final key = t.controller.creatorKeyFor(defaultTalkbawtServer);
      expect(key, 'k_${'a' * 48}', reason: 'the key the server issued is kept');
      final owned = t.controller.thread(created.id)!;
      expect(owned.ownerUrl, ownerUrl);
      expect(owned.passphrase, 'amber-canal-otter-quiet-47');
      expect(owned.hostId, 'devbox');
      // Stored, secrets included (secure storage), with the creator key.
      expect(t.store.data['creatorKeys'], {defaultTalkbawtServer: key});
      expect(
        (t.store.data['threads']! as List).single,
        containsPair('ownerUrl', ownerUrl),
      );
      // The next create hands the machine this install's key.
      await t.controller.createThread(
        tbHost('devbox'),
        const TalkbawtCreateRequest(title: 'Two', text: 'x'),
      );
      expect(devbox.configured.last, (defaultTalkbawtServer, key));
    },
  );

  test('settings: https server only, first use, relay', () async {
    final t = tbController({'devbox': FakeTalkbawtClient('devbox')});
    await t.controller.load();
    expect(t.controller.needsFirstUseChoice, isTrue);
    expect(
      () => t.controller.setServer('http://talkbawt.example.com'),
      throwsA(isA<TalkbawtAddressError>()),
    );
    await t.controller.setServer('https://tb.example.com/');
    expect(t.controller.settings.server, 'https://tb.example.com');
    expect(t.controller.needsFirstUseChoice, isFalse);
    await t.controller.setRelayMode(TalkbawtRelayMode.talkbawt);
    await t.controller.reload();
    expect(t.controller.settings.relay, TalkbawtRelayMode.talkbawt);
    expect(t.controller.settings.server, 'https://tb.example.com');
  });

  test(
    'deliver refuses agents in an auto-approve mode, and unknown ones unless confirmed',
    () async {
      final devbox = FakeTalkbawtClient('devbox');
      final t = tbController({'devbox': devbox});
      final read = devbox.read0;
      for (final mode in ['bypassPermissions', 'acceptEdits', 'auto']) {
        await expectLater(
          t.controller.deliver(
            tbHost('devbox'),
            tbAgent('a', mode: mode),
            read,
          ),
          throwsA(
            isA<TalkbawtFailure>().having(
              (f) => f.code,
              'code',
              'unsafe-permission-mode',
            ),
          ),
        );
      }
      await expectLater(
        t.controller.deliver(tbHost('devbox'), tbAgent('a', mode: null), read),
        throwsA(
          isA<TalkbawtFailure>().having(
            (f) => f.code,
            'code',
            'permission-mode-unknown',
          ),
        ),
      );
      expect(devbox.delivered, isEmpty, reason: 'nothing reached the machine');
      await t.controller.deliver(
        tbHost('devbox'),
        tbAgent('a', mode: null),
        read,
        confirmedUnknownMode: true,
      );
      expect(devbox.delivered.single.allowUnknownMode, isTrue);
      await t.controller.deliver(tbHost('devbox'), tbAgent('b'), read);
      expect(devbox.delivered.last.sessionId, 'b');
      expect(devbox.delivered.last.allowUnknownMode, isFalse);
    },
  );

  test(
    'watch: replies notify, a new reader notifies on a limited link, state follows',
    () async {
      final devbox = FakeTalkbawtClient('devbox');
      final t = tbController({'devbox': devbox});
      final created = await t.controller.createThread(
        tbHost('devbox'),
        const TalkbawtCreateRequest(title: 'Migration', text: 'x', maxReads: 2),
      );
      devbox.watchAnswer = [
        TalkbawtThreadChange(
          id: created.id,
          state: 'live',
          readers: 1,
          readersChanged: true,
          replies: [tbMessage(2, 'Which snapshot?\nmore lines')],
        ),
      ];
      await t.controller.watchOnce(tbHost('devbox'));
      final owned = t.controller.thread(created.id)!;
      expect(owned.unread, 1);
      expect(owned.readers, 1);
      expect(
        owned.lastReply,
        'claims to be: Ana (Codex) (unverified): Which snapshot?',
      );
      expect(t.notices.map((n) => n.title), [
        "Reply on 'Migration'",
        "Your link 'Migration' was opened",
      ]);
      expect(
        t.notices.first.body,
        'claims to be: Ana (Codex) (unverified): Which snapshot?',
      );
      expect(t.notices.every((n) => n.threadId == created.id), isTrue);
      await t.controller.markSeen(created.id);
      expect(t.controller.thread(created.id)!.unread, 0);
      devbox.watchAnswer = [
        TalkbawtThreadChange(id: created.id, state: 'expired', readers: 1),
      ];
      await t.controller.watchOnce(tbHost('devbox'));
      expect(t.controller.thread(created.id)!.state, 'expired');
      expect(t.notices.last.title, "'Migration' is expired");
    },
  );

  test(
    'revoke keeps the access log and drops the links and passphrase',
    () async {
      final devbox = FakeTalkbawtClient('devbox');
      final t = tbController({'devbox': devbox});
      final created = await t.controller.createThread(
        tbHost('devbox'),
        const TalkbawtCreateRequest(
          title: 'T',
          text: 'x',
          passphrase: 'pppppppp',
        ),
      );
      final log = await t.controller.revoke(t.controller.thread(created.id)!);
      expect(log.single.ua, 'Mozilla');
      final owned = t.controller.thread(created.id)!;
      expect(owned.state, 'revoked');
      expect(owned.accessLog.single.action, 'read');
      expect(owned.ownerUrl, isNull);
      expect(owned.shareUrl, isNull);
      expect(owned.passphrase, isNull);
    },
  );

  test(
    'the Talkbawt relay: a one-reader handoff, read on the target, delivered, revoked',
    () async {
      final a = FakeTalkbawtClient('a');
      final b = FakeTalkbawtClient('b');
      final t = tbController({'a': a, 'b': b});
      await t.controller.relayViaTalkbawt(
        from: tbHost('a'),
        fromLabel: 'api on a',
        to: TalkbawtRelayTarget(host: tbHost('b'), agent: tbAgent('web')),
        text: 'Look at the failing test',
      );
      expect(a.lastCreate!.mode, TalkbawtMode.handoff);
      expect(a.lastCreate!.maxReads, 1);
      expect(a.lastCreate!.expiry, TalkbawtExpiry.oneHour);
      expect(a.lastCreate!.passphrase, isNotNull);
      expect(b.calls, [
        'read',
        'deliver',
      ], reason: 'the target machine is the reader');
      expect(a.calls.last, 'revoke');
      await expectLater(
        t.controller.relayViaTalkbawt(
          from: tbHost('a'),
          fromLabel: 'api on a',
          to: TalkbawtRelayTarget(
            host: tbHost('b'),
            agent: tbAgent('web', mode: 'bypassPermissions'),
          ),
          text: 'x',
        ),
        throwsA(isA<TalkbawtFailure>()),
      );
    },
  );

  group('paired machines', () {
    test('refuses agents that are not in default or plan mode', () async {
      final t = tbController({
        'a': FakeTalkbawtClient('a'),
        'b': FakeTalkbawtClient('b'),
      });
      for (final mode in ['bypassPermissions', 'auto', null]) {
        await expectLater(
          t.controller.startPaired(
            hostA: tbHost('a'),
            agentA: tbAgent('x'),
            hostB: tbHost('b'),
            agentB: tbAgent('y', mode: mode),
            opening: 'hi',
          ),
          throwsA(
            isA<TalkbawtFailure>().having(
              (f) => f.code,
              'code',
              'unsafe-permission-mode',
            ),
          ),
          reason: '$mode',
        );
      }
      expect(t.controller.paired, isNull);
    });

    test('relays both ways without a tap, then stops by itself', () {
      fakeAsync((async) {
        final a = FakeTalkbawtClient('a');
        final b = FakeTalkbawtClient('b');
        // The thread as both sides see it: A's opening, then what each posts.
        final messages = <TalkbawtMessage>[
          tbMessage(1, 'Which port?', from: 'x on a'),
        ];
        var nextSeq = 2;
        List<TalkbawtMessage> since(int s) => [
          for (final m in messages)
            if (m.seq > s) m,
        ];
        a.readSince = since;
        b.readSince = since;
        for (final c in [a, b]) {
          c.nextSeq = 0;
        }
        final posted = <String>[];
        Future<int> post(String text, String from) async {
          final seq = nextSeq++;
          messages.add(tbMessage(seq, text, from: from));
          posted.add(from);
          return seq;
        }

        final t = tbController(
          {
            'a': _PostingClient(a, post, 'x on a'),
            'b': _PostingClient(b, post, 'y on b'),
          },
          now: () => DateTime.utc(2026, 9, 28, 10).add(async.elapsed),
          pairedInterval: const Duration(seconds: 5),
        );
        var bReply = const TalkbawtAgentReply(ready: false);
        b.reply = (_) => bReply;
        a.reply = (_) => const TalkbawtAgentReply(ready: false);
        PairedSession? session;
        t.controller
            .startPaired(
              hostA: tbHost('a'),
              agentA: tbAgent('x'),
              hostB: tbHost('b'),
              agentB: tbAgent('y', mode: 'plan'),
              opening: 'Which port?',
              duration: const Duration(minutes: 15),
            )
            .then((s) => session = s);
        async.flushMicrotasks();
        expect(session, isNotNull);
        expect(a.lastCreate!.passphrase, isNotNull);
        expect(a.lastCreate!.maxReads, 2);
        expect(a.lastCreate!.signing, isTrue);
        expect(a.lastExpiresSpec, '15m');
        // The opening reaches B, framed as its paired agent's message.
        expect(b.delivered.single.read.messages.single.text, 'Which port?');
        expect(b.delivered.single.pairedWith, 'x on a');
        expect(a.delivered, isEmpty, reason: 'A never gets its own message');
        // B answers; the next tick posts it and hands it to A.
        bReply = const TalkbawtAgentReply(ready: true, text: '8443');
        async.elapse(const Duration(seconds: 5));
        expect(posted, ['y on b']);
        expect(a.delivered.single.read.messages.single.text, '8443');
        expect(a.delivered.single.pairedWith, 'y on b');
        expect(
          b.delivered,
          hasLength(1),
          reason: 'B never gets its own reply back',
        );
        expect(session!.relayed, 1);
        expect(session!.active, isTrue);
        // Time is up: it stops and revokes the thread.
        async.elapse(const Duration(minutes: 15));
        expect(session!.active, isFalse);
        expect(session!.stopped, PairedStopReason.expired);
        expect(a.calls, contains('revoke'));
        final ticks = a.calls.where((c) => c == 'reply').length;
        async.elapse(const Duration(minutes: 1));
        expect(
          a.calls.where((c) => c == 'reply').length,
          ticks,
          reason: 'no more relaying',
        );
        t.controller.dispose();
      });
    });
  });
}

/// Posts land in the shared thread [post] keeps.
class _PostingClient extends FakeTalkbawtClient {
  _PostingClient(this.inner, this._post, this.label) : super(inner.name);

  final FakeTalkbawtClient inner;
  final Future<int> Function(String text, String from) _post;
  final String label;

  @override
  Future<int> post({
    required String text,
    String? link,
    String? id,
    String? passphrase,
    String? from,
    String? signingKey,
  }) {
    inner.calls.add('post');
    return _post(text, label);
  }

  @override
  Future<void> configure({required String server, String? creatorKey}) =>
      inner.configure(server: server, creatorKey: creatorKey);

  @override
  Future<TalkbawtCreated> create(
    TalkbawtCreateRequest request, {
    String? expiresSpec,
  }) => inner.create(request, expiresSpec: expiresSpec);

  @override
  Future<TalkbawtRead> read({
    String? link,
    String? id,
    String? passphrase,
    int since = 0,
  }) => inner.read(link: link, id: id, passphrase: passphrase, since: since);

  @override
  Future<void> deliver({
    required String sessionId,
    required TalkbawtRead read,
    bool allowUnknownMode = false,
    String? pairedWith,
    String? until,
  }) => inner.deliver(
    sessionId: sessionId,
    read: read,
    allowUnknownMode: allowUnknownMode,
    pairedWith: pairedWith,
    until: until,
  );

  @override
  Future<TalkbawtAgentReply> agentReply(
    String sessionId, {
    required int after,
  }) => inner.agentReply(sessionId, after: after);

  @override
  Future<List<TalkbawtAccessEntry>> revoke({required String id}) =>
      inner.revoke(id: id);
}
