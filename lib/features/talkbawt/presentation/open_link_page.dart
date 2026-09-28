import 'dart:async';

import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/sync/presentation/widgets/setup_code_scanner.dart';
import 'package:conduit/features/talkbawt/domain/talkbawt_link.dart';
import 'package:conduit/features/talkbawt/domain/talkbawt_models.dart';
import 'package:conduit/features/talkbawt/domain/talkbawt_safety.dart';
import 'package:conduit/features/talkbawt/presentation/talkbawt_controller.dart';
import 'package:conduit/features/talkbawt/presentation/talkbawt_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// The machines that can read links (their companion does the reading),
/// and the live agents on one of them.
class TalkbawtMachines {
  const TalkbawtMachines({required this.hosts, required this.agentsOn});

  final List<SavedHost> Function() hosts;
  final List<AgentInfo> Function(String hostId) agentsOn;
}

/// "Open a Talkbawt link": paste, share or scan it, pick the machine that
/// reads it (the reader that could later reply), check its read budget for
/// free, then preview it as inert text. From there it can be sent to an
/// agent on that machine, after a confirmation screen with the exact
/// prompt.
Future<void> showOpenTalkbawtLink(
  BuildContext context, {
  required TalkbawtController controller,
  required TalkbawtMachines machines,
  String? initialText,
}) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => OpenTalkbawtLinkPage(
      controller: controller,
      machines: machines,
      initialText: initialText,
    ),
  ),
);

enum _Phase { input, checking, confirmRead, reading, preview }

class OpenTalkbawtLinkPage extends StatefulWidget {
  const OpenTalkbawtLinkPage({
    required this.controller,
    required this.machines,
    this.initialText,
    this.copy = copyToClipboard,
    this.scan,
    super.key,
  });

  final TalkbawtController controller;
  final TalkbawtMachines machines;
  final String? initialText;
  final TalkbawtCopy copy;

  /// Scans a QR code; defaults to the camera on phones.
  final Future<String?> Function(BuildContext context)? scan;

  @override
  State<OpenTalkbawtLinkPage> createState() => _OpenTalkbawtLinkPageState();
}

class _OpenTalkbawtLinkPageState extends State<OpenTalkbawtLinkPage> {
  late final _field = TextEditingController(text: widget.initialText ?? '');
  final _passphrase = TextEditingController();
  _Phase _phase = _Phase.input;
  SavedHost? _host;
  TalkbawtLink? _link;
  TalkbawtMeta? _meta;
  TalkbawtRead? _read;
  String? _error;
  bool _needsPassphrase = false;

  @override
  void initState() {
    super.initState();
    final hosts = widget.machines.hosts();
    if (hosts.length == 1) _host = hosts.single;
  }

  @override
  void dispose() {
    _field.dispose();
    _passphrase.dispose();
    super.dispose();
  }

  String? get _pass =>
      _passphrase.text.trim().isEmpty ? null : _passphrase.text.trim();

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text case final text?) {
      _field.text = text;
      setState(() {});
    }
  }

  Future<void> _scanQr() async {
    final scan = widget.scan ?? _scanWithCamera;
    final value = await scan(context);
    if (value != null && mounted) {
      _field.text = value;
      setState(() {});
    }
  }

  /// Checks the link and its server, then the read budget (free).
  Future<void> _check() async {
    TalkbawtLink? link;
    try {
      link =
          TalkbawtLink.find(_field.text) ?? TalkbawtLink.tryParse(_field.text);
    } on TalkbawtAddressError catch (error) {
      setState(() => _error = error.message);
      return;
    }
    if (link == null) {
      setState(
        () => _error =
            'Not a Talkbawt link. It looks like https://server/t/g_ and 32 '
            'characters.',
      );
      return;
    }
    final host = _host;
    if (host == null) {
      setState(() => _error = 'Pick the machine that reads it.');
      return;
    }
    final configured = widget.controller.settings.server;
    if (link.origin != configured) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          key: const ValueKey('talkbawt-other-server'),
          title: const Text('Another server'),
          content: Text(
            'This link is on ${link!.host}, not your configured server '
            '(${Uri.parse(configured).host}). Open it?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: const ValueKey('talkbawt-other-server-open'),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Open'),
            ),
          ],
        ),
      );
      if (!(ok ?? false) || !mounted) return;
    }
    setState(() {
      _link = link;
      _error = null;
      _phase = _Phase.checking;
    });
    try {
      final meta = await widget.controller.meta(host, link, passphrase: _pass);
      if (!mounted) return;
      if (meta.passphraseRequired && _pass == null) {
        setState(() {
          _meta = meta;
          _needsPassphrase = true;
          _phase = _Phase.input;
          _error =
              'This link is passphrase-protected. Enter the passphrase '
              'you were sent separately.';
        });
        return;
      }
      if (!meta.admitted) {
        setState(() {
          _meta = meta;
          _phase = _Phase.input;
          _error = const TalkbawtFailure('read_limit_reached', '').userMessage;
        });
        return;
      }
      setState(() {
        _meta = meta;
        _phase = meta.usesARead ? _Phase.confirmRead : _Phase.reading;
      });
      if (!meta.usesARead) await _doRead();
    } on TalkbawtFailure catch (error) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.input;
        _needsPassphrase =
            _needsPassphrase || error.code == 'passphrase_required';
        _error = error.userMessage;
      });
    }
  }

  Future<void> _doRead() async {
    setState(() => _phase = _Phase.reading);
    try {
      final read = await widget.controller.read(
        _host!,
        _link!,
        passphrase: _pass,
      );
      if (!mounted) return;
      setState(() {
        _read = read;
        _phase = _Phase.preview;
      });
    } on TalkbawtFailure catch (error) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.input;
        _needsPassphrase =
            _needsPassphrase || error.code == 'passphrase_required';
        _error = error.userMessage;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Open a Talkbawt link')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: switch (_phase) {
            _Phase.input => _inputView(),
            _Phase.checking || _Phase.reading => [
              const Center(child: CircularProgressIndicator()),
              const SizedBox(height: 12),
              Text(
                _phase == _Phase.checking
                    ? 'Checking the link through ${_host?.name} (not counted '
                          'as a read)…'
                    : 'Reading through ${_host?.name}…',
                textAlign: TextAlign.center,
              ),
            ],
            _Phase.confirmRead => _confirmReadView(),
            _Phase.preview => _previewView(),
          },
        ),
      ),
    );
  }

  List<Widget> _inputView() {
    final hosts = widget.machines.hosts();
    return [
      TextField(
        key: const ValueKey('talkbawt-link-field'),
        controller: _field,
        keyboardType: TextInputType.url,
        autocorrect: false,
        minLines: 1,
        maxLines: 3,
        decoration: const InputDecoration(
          labelText: 'Link',
          hintText: 'https://talkbawt.outsmartis.dev/t/g_…',
        ),
      ),
      Row(
        children: [
          TextButton.icon(
            key: const ValueKey('talkbawt-paste'),
            onPressed: () => unawaited(_pasteFromClipboard()),
            icon: const Icon(Icons.content_paste_rounded),
            label: const Text('Paste'),
          ),
          if (widget.scan != null || setupCodeScanningAvailable)
            TextButton.icon(
              key: const ValueKey('talkbawt-scan'),
              onPressed: () => unawaited(_scanQr()),
              icon: const Icon(Icons.qr_code_scanner_rounded),
              label: const Text('Scan QR'),
            ),
        ],
      ),
      if (_needsPassphrase)
        TextField(
          key: const ValueKey('talkbawt-passphrase-field'),
          controller: _passphrase,
          obscureText: true,
          autocorrect: false,
          decoration: const InputDecoration(labelText: 'Passphrase'),
        ),
      const SizedBox(height: 16),
      Text('Read it on', style: Theme.of(context).textTheme.titleSmall),
      Text(
        'Pick the machine whose agent may get it: that machine becomes the '
        'reader, and the one that can reply.',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      if (hosts.isEmpty)
        const Padding(
          padding: EdgeInsets.only(top: 8),
          child: Text(
            'No machine with the Conductore companion is being monitored. '
            'Set up agent hooks on one first.',
          ),
        ),
      RadioGroup<String>(
        groupValue: _host?.id,
        onChanged: (id) =>
            setState(() => _host = hosts.where((h) => h.id == id).firstOrNull),
        child: Column(
          children: [
            for (final host in hosts)
              RadioListTile<String>(
                key: ValueKey('talkbawt-host-${host.id}'),
                contentPadding: EdgeInsets.zero,
                value: host.id,
                title: Text(host.name),
              ),
          ],
        ),
      ),
      if (_error case final error?)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            error,
            key: const ValueKey('talkbawt-open-error'),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      const SizedBox(height: 12),
      FilledButton(
        key: const ValueKey('talkbawt-open'),
        onPressed: () => unawaited(_check()),
        child: const Text('Open'),
      ),
    ];
  }

  List<Widget> _confirmReadView() {
    final meta = _meta!;
    return [
      Text(
        meta.title ?? 'A Talkbawt ${meta.mode.label.toLowerCase()}',
        style: Theme.of(context).textTheme.titleMedium,
      ),
      const SizedBox(height: 8),
      Text(
        'Reading uses one of the ${meta.readsRemaining} reads left '
        '(${meta.maxReads} in all). ${_host!.name} becomes the reader: an '
        'agent there can then get it through Conductore. A browser, or '
        'another machine, would count as another reader.',
        key: const ValueKey('talkbawt-uses-read'),
      ),
      const SizedBox(height: 16),
      FilledButton(
        key: const ValueKey('talkbawt-read-anyway'),
        onPressed: () => unawaited(_doRead()),
        child: const Text('Read it'),
      ),
      TextButton(
        onPressed: () => setState(() => _phase = _Phase.input),
        child: const Text('Not now'),
      ),
    ];
  }

  List<Widget> _previewView() {
    final read = _read!;
    final agents = widget.machines.agentsOn(_host!.id);
    return [
      TalkbawtPreview(read: read),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        children: [
          FilledButton.icon(
            key: const ValueKey('talkbawt-send-to-agent'),
            onPressed: agents.isEmpty
                ? null
                : () => unawaited(
                    sendTalkbawtToAgent(
                      context,
                      controller: widget.controller,
                      host: _host!,
                      agents: agents,
                      read: read,
                    ),
                  ),
            icon: const Icon(Icons.smart_toy_outlined),
            label: const Text('Send to agent…'),
          ),
          if (read.mode == TalkbawtMode.thread)
            OutlinedButton.icon(
              key: const ValueKey('talkbawt-reply'),
              onPressed: () => unawaited(
                replyToTalkbawt(
                  context,
                  onSend: (text) => widget.controller.reply(
                    host: _host,
                    link: _link,
                    passphrase: _pass,
                    text: text,
                    from: widget.controller.settings.from.isEmpty
                        ? null
                        : widget.controller.settings.from,
                  ),
                ),
              ),
              icon: const Icon(Icons.reply_rounded),
              label: const Text('Reply…'),
            ),
          OutlinedButton.icon(
            key: const ValueKey('talkbawt-copy-text'),
            onPressed: () => unawaited(widget.copy(read.plainText)),
            icon: const Icon(Icons.copy_rounded),
            label: const Text('Copy text'),
          ),
        ],
      ),
      if (agents.isEmpty)
        Text(
          'No live agent on ${_host!.name} to send it to.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
    ];
  }
}

/// Picks an agent on [host], shows the exact prompt, and on confirmation
/// has the machine write the content to a fenced file and type the fixed
/// prompt. Agents that act without asking are listed but cannot be picked;
/// one that has not reported its mode needs the user's word for it.
Future<void> sendTalkbawtToAgent(
  BuildContext context, {
  required TalkbawtController controller,
  required SavedHost host,
  required List<AgentInfo> agents,
  required TalkbawtRead read,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final picked = await Navigator.of(context).push<(AgentInfo, bool)>(
    MaterialPageRoute(
      builder: (_) => _SendToAgentPage(host: host, agents: agents, read: read),
    ),
  );
  if (picked == null) return;
  final (agent, confirmedUnknown) = picked;
  try {
    await controller.deliver(
      host,
      agent,
      read,
      confirmedUnknownMode: confirmedUnknown,
    );
    messenger?.showSnackBar(
      SnackBar(content: Text('Sent to ${agent.name} as untrusted data')),
    );
  } on Object catch (error) {
    messenger?.showSnackBar(
      SnackBar(content: Text('Not sent to ${agent.name}: $error')),
    );
  }
}

class _SendToAgentPage extends StatefulWidget {
  const _SendToAgentPage({
    required this.host,
    required this.agents,
    required this.read,
  });

  final SavedHost host;
  final List<AgentInfo> agents;
  final TalkbawtRead read;

  @override
  State<_SendToAgentPage> createState() => _SendToAgentPageState();
}

class _SendToAgentPageState extends State<_SendToAgentPage> {
  AgentInfo? _agent;
  bool _unknownConfirmed = false;

  @override
  Widget build(BuildContext context) {
    final agent = _agent;
    final safety = agent == null ? null : agentModeSafety(agent.permissionMode);
    final canSend =
        agent != null &&
        (safety == AgentModeSafety.safe ||
            (safety == AgentModeSafety.unknown && _unknownConfirmed));
    return Scaffold(
      appBar: AppBar(title: const Text('Send to agent')),
      body: SafeArea(
        child: ListView(
          key: const ValueKey('talkbawt-confirm-send'),
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'On ${widget.host.name}',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            RadioGroup<String>(
              groupValue: agent?.id,
              onChanged: (id) => setState(() {
                _agent = widget.agents.where((a) => a.id == id).firstOrNull;
                _unknownConfirmed = false;
              }),
              child: Column(
                children: [for (final a in widget.agents) _agentTile(a)],
              ),
            ),
            if (safety == AgentModeSafety.unknown)
              CheckboxListTile(
                key: const ValueKey('talkbawt-confirm-unknown-mode'),
                contentPadding: EdgeInsets.zero,
                value: _unknownConfirmed,
                onChanged: (v) =>
                    setState(() => _unknownConfirmed = v ?? false),
                title: Text(
                  '${agent!.name} has not reported its permission mode. I '
                  'checked: it is not in an auto-approve or bypass mode.',
                ),
              ),
            const SizedBox(height: 12),
            Text('What happens', style: Theme.of(context).textTheme.titleSmall),
            Text(
              'The ${widget.read.messages.length} message(s) you saw are '
              'written to a new file on ${widget.host.name}, fenced as '
              'untrusted, and only this prompt is typed into the agent:',
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                border: Border.all(color: Theme.of(context).dividerColor),
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                talkbawtInboxPrompt(
                  '~/.conductore/talkbawt/inbox/<new file>.md',
                  handoff: widget.read.mode == TalkbawtMode.handoff,
                ),
                key: const ValueKey('talkbawt-exact-prompt'),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'The agent never gets the link, the passphrase or a key.',
            ),
            const SizedBox(height: 16),
            FilledButton(
              key: const ValueKey('talkbawt-confirm-send-button'),
              onPressed: canSend
                  ? () => Navigator.of(context).pop((agent, _unknownConfirmed))
                  : null,
              child: Text(
                agent == null ? 'Pick an agent' : 'Send to ${agent.name}',
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _agentTile(AgentInfo a) {
    final safety = agentModeSafety(a.permissionMode);
    final unsafe = safety == AgentModeSafety.unsafe;
    return RadioListTile<String>(
      key: ValueKey('talkbawt-agent-${a.id}'),
      contentPadding: EdgeInsets.zero,
      value: a.id,
      enabled: !unsafe,
      title: Text(a.name),
      subtitle: Text(switch (safety) {
        AgentModeSafety.unsafe =>
          'Refused: runs in ${permissionModeLabel(a.permissionMode!)} mode, '
              'where it acts without asking',
        AgentModeSafety.unknown => '${a.state.label} · mode not reported',
        AgentModeSafety.safe =>
          '${a.state.label} · ${permissionModeLabel(a.permissionMode!)} mode',
      }),
    );
  }
}

/// Asks for a reply's text, scans it, and posts it through [onSend].
Future<void> replyToTalkbawt(
  BuildContext context, {
  required Future<int> Function(String text) onSend,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final text = await showDialog<String>(
    context: context,
    builder: (context) => const _ReplyDialog(),
  );
  if (text == null || text.trim().isEmpty) return;
  try {
    await onSend(text);
    messenger?.showSnackBar(const SnackBar(content: Text('Reply posted')));
  } on Object catch (error) {
    messenger?.showSnackBar(SnackBar(content: Text('Not posted: $error')));
  }
}

class _ReplyDialog extends StatefulWidget {
  const _ReplyDialog();

  @override
  State<_ReplyDialog> createState() => _ReplyDialogState();
}

class _ReplyDialogState extends State<_ReplyDialog> {
  final _text = TextEditingController();
  List<SecretFinding> _findings = const [];

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Reply'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const ValueKey('talkbawt-reply-field'),
            controller: _text,
            minLines: 3,
            maxLines: 8,
            onChanged: (v) => setState(() => _findings = scanForSecrets(v)),
          ),
          const SizedBox(height: 8),
          SecretFindingsPanel(
            findings: _findings,
            onRemove: () {
              _text.text = removeSecretLines(_text.text, _findings);
              setState(() => _findings = scanForSecrets(_text.text));
            },
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('talkbawt-reply-send'),
          onPressed: _findings.isEmpty
              ? () => Navigator.of(context).pop(_text.text)
              : null,
          child: const Text('Post'),
        ),
      ],
    );
  }
}

Future<String?> _scanWithCamera(BuildContext context) => Navigator.of(
  context,
).push<String>(MaterialPageRoute(builder: (_) => const _LinkScannerPage()));

class _LinkScannerPage extends StatefulWidget {
  const _LinkScannerPage();

  @override
  State<_LinkScannerPage> createState() => _LinkScannerPageState();
}

class _LinkScannerPageState extends State<_LinkScannerPage> {
  final _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
  );
  bool _done = false;
  String? _hint;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value == null) continue;
      TalkbawtLink? link;
      try {
        link = TalkbawtLink.find(value);
      } on TalkbawtAddressError {
        link = null;
      }
      if (link != null) {
        _done = true;
        Navigator.of(context).pop(link.url);
        return;
      }
      setState(() => _hint = 'That QR code is not a Talkbawt link.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan a Talkbawt link')),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(controller: _controller, onDetect: _onDetect),
          if (_hint case final hint?)
            Align(
              alignment: Alignment.bottomCenter,
              child: Container(
                margin: const EdgeInsets.all(16),
                padding: const EdgeInsets.all(12),
                color: Colors.black54,
                child: Text(hint, style: const TextStyle(color: Colors.white)),
              ),
            ),
        ],
      ),
    );
  }
}
