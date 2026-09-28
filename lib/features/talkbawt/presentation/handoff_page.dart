import 'dart:async';

import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/chat_view/data/platform_text_share.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/talkbawt/domain/talkbawt_models.dart';
import 'package:conduit/features/talkbawt/domain/talkbawt_safety.dart';
import 'package:conduit/features/talkbawt/presentation/talkbawt_controller.dart';
import 'package:conduit/features/talkbawt/presentation/talkbawt_settings_page.dart';
import 'package:conduit/features/talkbawt/presentation/talkbawt_widgets.dart';
import 'package:flutter/material.dart';

/// Shares text with other apps; false where there is no share sheet.
typedef TalkbawtShare = Future<bool> Function(String text, {String? subject});

/// "Hand off" from an agent (Chat view menu, dashboard card): draft,
/// review, options, post, share. Asks which server first on first use.
Future<void> showHandoffFlow(
  BuildContext context, {
  required TalkbawtController controller,
  required SavedHost host,
  required AgentInfo agent,
}) async {
  if (!await ensureTalkbawtServerChosen(context, controller)) return;
  if (!context.mounted) return;
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) =>
          HandoffPage(controller: controller, host: host, agent: agent),
    ),
  );
}

enum _Step { source, drafting, review, posting, shared }

/// Where the draft comes from.
enum HandoffDraftSource {
  /// The agent writes it to a file (best: it has the context).
  agent,

  /// Claude over its transcript, with tools off (the agent is busy).
  summary,

  /// The user types it.
  manual,
}

class HandoffPage extends StatefulWidget {
  const HandoffPage({
    required this.controller,
    required this.host,
    required this.agent,
    this.share = PlatformTextShare.share,
    this.copy = copyToClipboard,
    this.pollInterval = const Duration(seconds: 3),
    super.key,
  });

  final TalkbawtController controller;
  final SavedHost host;
  final AgentInfo agent;
  final TalkbawtShare share;
  final TalkbawtCopy copy;
  final Duration pollInterval;

  @override
  State<HandoffPage> createState() => _HandoffPageState();
}

class _HandoffPageState extends State<HandoffPage> {
  _Step _step = _Step.source;
  String? _status;
  String? _error;
  final _draft = TextEditingController();
  late final _title = TextEditingController(
    text: 'Handoff from ${widget.agent.name}',
  );
  late final _from = TextEditingController(
    text: widget.controller.settings.from.isNotEmpty
        ? widget.controller.settings.from
        : '${widget.agent.name} via Conductore',
  );
  TalkbawtMode _mode = TalkbawtMode.thread;
  TalkbawtExpiry _expiry = TalkbawtExpiry.oneDay;
  bool _usePassphrase = false;
  late String _passphrase = widget.controller.newPassphrase();
  int? _maxReads;
  List<SecretFinding> _findings = const [];
  List<SecretFinding> _serverFindings = const [];
  TalkbawtCreated? _created;
  int _attempt = 0;

  @override
  void initState() {
    super.initState();
    _draft.addListener(_rescan);
  }

  @override
  void dispose() {
    _attempt += 1;
    _draft.dispose();
    _title.dispose();
    _from.dispose();
    super.dispose();
  }

  void _rescan() {
    final findings = scanForSecrets(_draft.text);
    if (findings.length != _findings.length ||
        !findings.every(_findings.contains)) {
      setState(() => _findings = findings);
    }
  }

  /// Waiting for a prompt (the companion's waiting_input), not working
  /// and not stopped at a permission prompt.
  bool get _agentIdle =>
      (widget.agent.state == AgentAttentionState.needsInput ||
          widget.agent.state == AgentAttentionState.idle) &&
      widget.agent.pendingRequests.isEmpty;

  Future<void> _start(HandoffDraftSource source) async {
    final attempt = ++_attempt;
    setState(() {
      _error = null;
      _step = source == HandoffDraftSource.manual
          ? _Step.review
          : _Step.drafting;
    });
    switch (source) {
      case HandoffDraftSource.manual:
        return;
      case HandoffDraftSource.summary:
        await _summary(attempt);
      case HandoffDraftSource.agent:
        await _askAgent(attempt);
    }
  }

  Future<void> _summary(int attempt) async {
    setState(() => _status = 'Summarising the transcript (tools off)…');
    try {
      final text = await widget.controller.summaryDraft(
        widget.host,
        widget.agent.id,
      );
      if (!mounted || attempt != _attempt) return;
      _draft.text = text;
      setState(() => _step = _Step.review);
    } on Object catch (error) {
      if (!mounted || attempt != _attempt) return;
      setState(() {
        _error = 'Could not summarise: $error';
        _step = _Step.source;
      });
    }
  }

  Future<void> _askAgent(int attempt) async {
    setState(() => _status = 'Asking ${widget.agent.name} to write it…');
    String id;
    try {
      id = await widget.controller.requestAgentDraft(
        widget.host,
        widget.agent.id,
      );
    } on TalkbawtFailure catch (error) {
      if (!mounted || attempt != _attempt) return;
      if (error.code == 'busy') {
        // Busy: the brain summary instead (André's decision 6).
        return _summary(attempt);
      }
      setState(() {
        _error = error.userMessage;
        _step = _Step.source;
      });
      return;
    }
    if (!mounted || attempt != _attempt) return;
    setState(
      () => _status =
          '${widget.agent.name} is writing the handoff to a file on '
          '${widget.host.name}. It posts nothing itself.',
    );
    while (mounted && attempt == _attempt) {
      await Future<void>.delayed(widget.pollInterval);
      if (!mounted || attempt != _attempt) return;
      try {
        final status = await widget.controller.draftStatus(widget.host, id);
        if (!mounted || attempt != _attempt) return;
        if (status.ready) {
          _draft.text = status.text ?? '';
          setState(() => _step = _Step.review);
          return;
        }
        if (status.expired) {
          setState(() {
            _error = 'The agent did not write a draft. Try the summary.';
            _step = _Step.source;
          });
          return;
        }
      } on Object catch (error) {
        if (!mounted || attempt != _attempt) return;
        setState(() {
          _error = '$error';
          _step = _Step.source;
        });
        return;
      }
    }
  }

  Future<void> _post({bool override = false}) async {
    final text = _draft.text;
    if (text.trim().isEmpty) {
      setState(() => _error = 'The handoff is empty.');
      return;
    }
    setState(() {
      _error = null;
      _step = _Step.posting;
    });
    try {
      final created = await widget.controller.createThread(
        widget.host,
        TalkbawtCreateRequest(
          title: _title.text.trim().isEmpty ? 'Handoff' : _title.text.trim(),
          text: text,
          mode: _mode,
          from: _from.text.trim().isEmpty ? 'Conductore' : _from.text.trim(),
          expiry: _expiry,
          passphrase: _usePassphrase ? _passphrase : null,
          maxReads: _maxReads,
          overrideSecretScan: override,
        ),
      );
      if (!mounted) return;
      setState(() {
        _created = created;
        _step = _Step.shared;
      });
    } on TalkbawtFailure catch (error) {
      if (!mounted) return;
      setState(() {
        _serverFindings = error.findings;
        _error = error.userMessage;
        _step = _Step.review;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _step = _Step.review;
      });
    }
  }

  /// Posting past a finding takes a second confirmation naming it.
  Future<void> _overrideAndPost() async {
    final findings = _findings.isNotEmpty ? _findings : _serverFindings;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Post it anyway?'),
        content: Text(
          'It still looks like it holds '
          '${findings.map((f) => f.label).join(', ')}. Anyone with the link '
          'can read it. Post only if you are sure it is not a live secret.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('handoff-override-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Post anyway'),
          ),
        ],
      ),
    );
    if (ok ?? false) await _post(override: true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Hand off ${widget.agent.name}')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_error case final error?)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  error,
                  key: const ValueKey('handoff-error'),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ...switch (_step) {
              _Step.source => _sourceStep(),
              _Step.drafting || _Step.posting => [
                const Center(child: CircularProgressIndicator()),
                const SizedBox(height: 12),
                Text(
                  _step == _Step.posting
                      ? 'Posting through ${widget.host.name}…'
                      : _status ?? '',
                  textAlign: TextAlign.center,
                ),
                if (_step == _Step.drafting)
                  TextButton(
                    key: const ValueKey('handoff-use-summary'),
                    onPressed: () =>
                        unawaited(_start(HandoffDraftSource.summary)),
                    child: const Text('Use a summary instead'),
                  ),
              ],
              _Step.review => _reviewStep(),
              _Step.shared => _sharedStep(),
            },
          ],
        ),
      ),
    );
  }

  List<Widget> _sourceStep() => [
    const Text(
      'Who writes the handoff? You review and edit it before anything is '
      'posted.',
    ),
    const SizedBox(height: 12),
    Card(
      child: ListTile(
        key: const ValueKey('handoff-source-agent'),
        leading: const Icon(Icons.smart_toy_outlined),
        title: Text('Ask ${widget.agent.name}'),
        subtitle: Text(
          _agentIdle
              ? 'It has the context. It writes to a file; it posts nothing.'
              : 'It is busy: a summary of its transcript is used instead.',
        ),
        onTap: () => unawaited(_start(HandoffDraftSource.agent)),
      ),
    ),
    Card(
      child: ListTile(
        key: const ValueKey('handoff-source-summary'),
        leading: const Icon(Icons.summarize_outlined),
        title: const Text('Summarise its transcript'),
        subtitle: const Text('Claude on the machine, with tools off.'),
        onTap: () => unawaited(_start(HandoffDraftSource.summary)),
      ),
    ),
    Card(
      child: ListTile(
        key: const ValueKey('handoff-source-manual'),
        leading: const Icon(Icons.edit_outlined),
        title: const Text('Write it myself'),
        onTap: () => unawaited(_start(HandoffDraftSource.manual)),
      ),
    ),
  ];

  List<Widget> _reviewStep() {
    final findings = _findings.isNotEmpty ? _findings : _serverFindings;
    return [
      TextField(
        key: const ValueKey('handoff-title'),
        controller: _title,
        decoration: const InputDecoration(labelText: 'Title'),
      ),
      const SizedBox(height: 10),
      TextField(
        key: const ValueKey('handoff-draft'),
        controller: _draft,
        minLines: 8,
        maxLines: 20,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
        decoration: const InputDecoration(
          labelText: 'Handoff',
          helperText: 'Say where secrets live, never what they are.',
          border: OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 8),
      SecretFindingsPanel(
        findings: findings,
        onRemove: () {
          _draft.text = removeSecretLines(_draft.text, findings);
          setState(() => _serverFindings = const []);
        },
      ),
      const SizedBox(height: 12),
      SegmentedButton<TalkbawtMode>(
        key: const ValueKey('handoff-mode'),
        segments: const [
          ButtonSegment(
            value: TalkbawtMode.thread,
            label: Text('Thread'),
            tooltip: 'Two-way: they can reply',
          ),
          ButtonSegment(
            value: TalkbawtMode.handoff,
            label: Text('Handoff'),
            tooltip: 'One-shot, read-only',
          ),
        ],
        selected: {_mode},
        onSelectionChanged: (s) => setState(() => _mode = s.first),
      ),
      const SizedBox(height: 10),
      SegmentedButton<TalkbawtExpiry>(
        key: const ValueKey('handoff-expiry'),
        segments: [
          for (final e in TalkbawtExpiry.values)
            ButtonSegment(value: e, label: Text(e.label)),
        ],
        selected: {_expiry},
        onSelectionChanged: (s) => setState(() => _expiry = s.first),
      ),
      SwitchListTile(
        key: const ValueKey('handoff-passphrase'),
        contentPadding: EdgeInsets.zero,
        title: const Text('Passphrase'),
        subtitle: Text(
          _usePassphrase
              ? '$_passphrase · send it over a different channel than the link'
              : 'A second factor, sent separately',
        ),
        value: _usePassphrase,
        onChanged: (v) => setState(() => _usePassphrase = v),
        secondary: _usePassphrase
            ? IconButton(
                tooltip: 'New passphrase',
                onPressed: () => setState(
                  () => _passphrase = widget.controller.newPassphrase(),
                ),
                icon: const Icon(Icons.refresh_rounded),
              )
            : null,
      ),
      DropdownButtonFormField<int?>(
        key: const ValueKey('handoff-max-reads'),
        initialValue: _maxReads,
        decoration: const InputDecoration(
          labelText: 'Readers',
          helperText: 'A browser and an agent count as two readers.',
        ),
        items: const [
          DropdownMenuItem(child: Text('No limit')),
          DropdownMenuItem(value: 1, child: Text('1 reader')),
          DropdownMenuItem(value: 2, child: Text('2 readers')),
        ],
        onChanged: (v) => setState(() => _maxReads = v),
      ),
      const SizedBox(height: 10),
      TextField(
        key: const ValueKey('handoff-from'),
        controller: _from,
        decoration: const InputDecoration(
          labelText: 'From',
          helperText: 'Shown to them as unverified.',
        ),
      ),
      const SizedBox(height: 16),
      FilledButton.icon(
        key: const ValueKey('handoff-post'),
        onPressed: findings.isEmpty ? () => unawaited(_post()) : null,
        icon: const Icon(Icons.send_rounded),
        label: Text('Post through ${widget.host.name}'),
      ),
      if (findings.isNotEmpty)
        TextButton(
          key: const ValueKey('handoff-override'),
          onPressed: () => unawaited(_overrideAndPost()),
          child: const Text('It is not a secret: post anyway…'),
        ),
    ];
  }

  List<Widget> _sharedStep() {
    final created = _created!;
    final messenger = ScaffoldMessenger.of(context);
    return [
      Text(
        created.mode == TalkbawtMode.thread
            ? 'Posted. Replies show up here and as notifications.'
            : 'Posted. It is read-only.',
      ),
      const SizedBox(height: 12),
      SelectableText(
        created.shareUrl,
        key: const ValueKey('handoff-share-url'),
        style: const TextStyle(fontFamily: 'monospace'),
      ),
      const SizedBox(height: 12),
      FilledButton.icon(
        key: const ValueKey('handoff-share'),
        // The share sheet carries the share link and nothing else: never
        // the passphrase, never the owner link.
        onPressed: () async {
          final shared = await widget.share(created.shareUrl);
          if (!shared) {
            await widget.copy(created.shareUrl);
            messenger.showSnackBar(
              const SnackBar(content: Text('Link copied')),
            );
          }
        },
        icon: const Icon(Icons.share_rounded),
        label: const Text('Share link'),
      ),
      OutlinedButton.icon(
        key: const ValueKey('handoff-copy-link'),
        onPressed: () async {
          await widget.copy(created.shareUrl);
          messenger.showSnackBar(const SnackBar(content: Text('Link copied')));
        },
        icon: const Icon(Icons.link_rounded),
        label: const Text('Copy link'),
      ),
      if (_usePassphrase) ...[
        const SizedBox(height: 12),
        OutlinedButton.icon(
          key: const ValueKey('handoff-copy-passphrase'),
          onPressed: () async {
            await widget.copy(_passphrase);
            messenger.showSnackBar(
              const SnackBar(
                content: Text(
                  'Passphrase copied. Send it over a different channel.',
                ),
              ),
            );
          },
          icon: const Icon(Icons.key_rounded),
          label: const Text('Copy passphrase'),
        ),
        const Text('Send the passphrase over a different channel.'),
      ],
      const SizedBox(height: 12),
      Text(
        'The owner link stays on this phone and ${widget.host.name}: it '
        'revokes the link and shows who opened it. Manage it under '
        'Settings › Agents › Talkbawt.',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    ];
  }
}

/// On first use, asks which server to use (André's decision 3); false
/// when dismissed.
Future<bool> ensureTalkbawtServerChosen(
  BuildContext context,
  TalkbawtController controller,
) async {
  await controller.load();
  if (!controller.needsFirstUseChoice) return true;
  if (!context.mounted) return false;
  final chosen = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      key: const ValueKey('talkbawt-first-use'),
      title: const Text('Which Talkbawt server?'),
      content: Text(
        'Handoffs go through a Talkbawt server: the link lives there until '
        'it expires. The default is ${controller.settings.server}. You can '
        'also run one on your own machine (conductore-hostd talkbawt serve) '
        'or use your team\'s.',
      ),
      actions: [
        TextButton(
          key: const ValueKey('talkbawt-first-use-other'),
          onPressed: () async {
            final saved = await Navigator.of(context).push<bool>(
              MaterialPageRoute(
                builder: (_) => TalkbawtSettingsPage(controller: controller),
              ),
            );
            if (context.mounted) {
              Navigator.of(
                context,
              ).pop(saved ?? !controller.needsFirstUseChoice);
            }
          },
          child: const Text('Another server…'),
        ),
        FilledButton(
          key: const ValueKey('talkbawt-first-use-default'),
          onPressed: () async {
            await controller.markFirstUseAsked();
            if (context.mounted) Navigator.of(context).pop(true);
          },
          child: const Text('Use the default'),
        ),
      ],
    ),
  );
  return (chosen ?? false) && !controller.needsFirstUseChoice;
}
