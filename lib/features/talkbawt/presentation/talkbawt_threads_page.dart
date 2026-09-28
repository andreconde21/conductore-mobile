import 'dart:async';

import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/features/talkbawt/domain/talkbawt_models.dart';
import 'package:conduit/features/talkbawt/presentation/open_link_page.dart';
import 'package:conduit/features/talkbawt/presentation/paired_mode_page.dart';
import 'package:conduit/features/talkbawt/presentation/talkbawt_controller.dart';
import 'package:conduit/features/talkbawt/presentation/talkbawt_settings_page.dart';
import 'package:conduit/features/talkbawt/presentation/talkbawt_widgets.dart';
import 'package:flutter/material.dart';

/// Settings › Agents › Talkbawt: the links this phone owns (state,
/// readers, new replies), opening a link, paired mode and the settings.
class TalkbawtHubPage extends StatelessWidget {
  const TalkbawtHubPage({
    required this.controller,
    required this.machines,
    super.key,
  });

  final TalkbawtController controller;
  final TalkbawtMachines machines;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Talkbawt'),
        actions: [
          IconButton(
            key: const ValueKey('talkbawt-settings'),
            tooltip: 'Server and relay',
            icon: const Icon(Icons.tune_rounded),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => TalkbawtSettingsPage(controller: controller),
              ),
            ),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final threads = controller.threads;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                'Handoffs and threads between agents, through '
                '${Uri.parse(controller.settings.server).host}. Hand off from '
                "an agent's Chat menu or dashboard card.",
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    key: const ValueKey('talkbawt-open-link'),
                    onPressed: () => unawaited(
                      showOpenTalkbawtLink(
                        context,
                        controller: controller,
                        machines: machines,
                      ),
                    ),
                    icon: const Icon(Icons.link_rounded),
                    label: const Text('Open a link…'),
                  ),
                  OutlinedButton.icon(
                    key: const ValueKey('talkbawt-paired'),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => PairedModePage(
                          controller: controller,
                          machines: machines,
                        ),
                      ),
                    ),
                    icon: const Icon(Icons.sync_alt_rounded),
                    label: const Text('Paired machines'),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text('Your links', style: Theme.of(context).textTheme.titleSmall),
              if (threads.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text('None yet.'),
                ),
              for (final t in threads)
                _ThreadTile(controller: controller, thread: t),
            ],
          );
        },
      ),
    );
  }
}

class _ThreadTile extends StatelessWidget {
  const _ThreadTile({required this.controller, required this.thread});

  final TalkbawtController controller;
  final TalkbawtOwnedThread thread;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final t = thread;
    final readers = t.maxReads == null
        ? '${t.readers} ${t.readers == 1 ? 'reader' : 'readers'}'
        : '${t.readers} of ${t.maxReads} readers';
    return ListTile(
      key: ValueKey('talkbawt-thread-${t.id}'),
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        t.mode == TalkbawtMode.thread
            ? Icons.forum_outlined
            : Icons.outbox_outlined,
        color: t.live ? null : palette.mutedForeground,
      ),
      title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [
          if (!t.live) t.state else readers,
          if (t.paired) 'paired',
          ?t.lastReply,
        ].join(' · '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: t.unread > 0
          ? Badge(
              key: ValueKey('talkbawt-unread-${t.id}'),
              label: Text('${t.unread}'),
            )
          : null,
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) =>
              TalkbawtThreadPage(controller: controller, threadId: t.id),
        ),
      ),
    );
  }
}

/// One owned link: its messages as an inert preview, readers and the
/// access log, reply, copy the share link or passphrase, revoke. Reply
/// notifications open this page and nothing else.
class TalkbawtThreadPage extends StatefulWidget {
  const TalkbawtThreadPage({
    required this.controller,
    required this.threadId,
    this.copy = copyToClipboard,
    super.key,
  });

  final TalkbawtController controller;
  final String threadId;
  final TalkbawtCopy copy;

  @override
  State<TalkbawtThreadPage> createState() => _TalkbawtThreadPageState();
}

class _TalkbawtThreadPageState extends State<TalkbawtThreadPage> {
  TalkbawtRead? _read;
  String? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  TalkbawtOwnedThread? get _thread => widget.controller.thread(widget.threadId);

  Future<void> _load() async {
    await widget.controller.load();
    final t = _thread;
    if (t == null || !t.live) {
      if (mounted) setState(() {});
      return;
    }
    setState(() => _loading = true);
    try {
      final read = await widget.controller.readOwned(t);
      await widget.controller.markSeen(t.id);
      if (mounted) setState(() => _read = read);
    } on Object catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _revoke(TalkbawtOwnedThread t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Revoke this link?'),
        content: const Text(
          'Nobody can read or reply through it any more, and its messages '
          'are deleted. Who opened it is saved here first.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('talkbawt-revoke-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Revoke'),
          ),
        ],
      ),
    );
    if (!(ok ?? false)) return;
    try {
      await widget.controller.revoke(t);
      if (mounted) setState(() => _read = null);
    } on Object catch (error) {
      if (mounted) setState(() => _error = 'Not revoked: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final t = _thread;
        final messenger = ScaffoldMessenger.maybeOf(context);
        return Scaffold(
          appBar: AppBar(title: Text(t?.title ?? 'Talkbawt link')),
          body: t == null
              ? const Center(
                  child: Text('This link is no longer on this phone.'),
                )
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Text(
                      [
                        t.mode.label,
                        t.state,
                        if (t.maxReads != null)
                          '${t.readers} of ${t.maxReads} readers'
                        else
                          '${t.readers} readers',
                        if (t.expiresAt != null)
                          'expires ${talkbawtShortTime(t.expiresAt!)}',
                      ].join(' · '),
                      key: const ValueKey('talkbawt-thread-state'),
                    ),
                    if (_error case final error?)
                      Text(
                        error,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    const SizedBox(height: 12),
                    if (t.live)
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          if (t.shareUrl case final share?)
                            OutlinedButton.icon(
                              key: const ValueKey('talkbawt-copy-share'),
                              onPressed: () async {
                                await widget.copy(share);
                                messenger?.showSnackBar(
                                  const SnackBar(content: Text('Link copied')),
                                );
                              },
                              icon: const Icon(Icons.link_rounded),
                              label: const Text('Copy link'),
                            ),
                          if (t.passphrase case final pass?)
                            OutlinedButton.icon(
                              key: const ValueKey('talkbawt-copy-passphrase'),
                              onPressed: () async {
                                await widget.copy(pass);
                                messenger?.showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      'Passphrase copied. Send it over a '
                                      'different channel.',
                                    ),
                                  ),
                                );
                              },
                              icon: const Icon(Icons.key_rounded),
                              label: const Text('Copy passphrase'),
                            ),
                          if (t.mode == TalkbawtMode.thread)
                            OutlinedButton.icon(
                              key: const ValueKey('talkbawt-thread-reply'),
                              onPressed: () => unawaited(
                                replyToTalkbawt(
                                  context,
                                  onSend: (text) async {
                                    final seq = await widget.controller.reply(
                                      owned: t,
                                      text: text,
                                    );
                                    unawaited(_load());
                                    return seq;
                                  },
                                ),
                              ),
                              icon: const Icon(Icons.reply_rounded),
                              label: const Text('Reply…'),
                            ),
                          OutlinedButton.icon(
                            key: const ValueKey('talkbawt-revoke'),
                            onPressed: () => unawaited(_revoke(t)),
                            icon: const Icon(Icons.link_off_rounded),
                            label: const Text('Revoke'),
                          ),
                        ],
                      ),
                    const SizedBox(height: 16),
                    if (_loading) const LinearProgressIndicator(),
                    if (_read case final read?) ...[
                      TalkbawtPreview(read: read),
                      const SizedBox(height: 16),
                      Text(
                        'Who opened it',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      AccessLogList(entries: read.accessLog ?? const []),
                    ] else if (!t.live) ...[
                      Text(
                        'Access log saved when it was revoked',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      AccessLogList(entries: t.accessLog),
                      TextButton(
                        key: const ValueKey('talkbawt-forget'),
                        onPressed: () async {
                          final navigator = Navigator.of(context);
                          await widget.controller.forget(t.id);
                          navigator.pop();
                        },
                        child: const Text('Forget it'),
                      ),
                    ],
                  ],
                ),
        );
      },
    );
  }
}
