import 'dart:async';

import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/talkbawt/domain/paired_session.dart';
import 'package:conduit/features/talkbawt/domain/talkbawt_safety.dart';
import 'package:conduit/features/talkbawt/presentation/open_link_page.dart';
import 'package:conduit/features/talkbawt/presentation/talkbawt_controller.dart';
import 'package:flutter/material.dart';

typedef _Pick = ({SavedHost host, AgentInfo agent});

/// Paired machines: two of your own agents talk over a passphrase-protected
/// thread for a set time, relayed by the phone without a tap per message.
/// Both must be in default or plan mode; it stops by itself.
class PairedModePage extends StatefulWidget {
  const PairedModePage({
    required this.controller,
    required this.machines,
    super.key,
  });

  final TalkbawtController controller;
  final TalkbawtMachines machines;

  @override
  State<PairedModePage> createState() => _PairedModePageState();
}

class _PairedModePageState extends State<PairedModePage> {
  _Pick? _a;
  _Pick? _b;
  int _minutes = 30;
  final _opening = TextEditingController();
  String? _error;
  bool _starting = false;

  @override
  void dispose() {
    _opening.dispose();
    super.dispose();
  }

  List<_Pick> get _candidates => [
    for (final host in widget.machines.hosts())
      for (final agent in widget.machines.agentsOn(host.id))
        (host: host, agent: agent),
  ];

  String _key(_Pick p) => '${p.host.id}/${p.agent.id}';

  Future<void> _start() async {
    final a = _a;
    final b = _b;
    if (a == null || b == null || _key(a) == _key(b)) {
      setState(() => _error = 'Pick two different agents.');
      return;
    }
    if (_opening.text.trim().isEmpty) {
      setState(() => _error = 'Write the first message from A to B.');
      return;
    }
    final findings = scanForSecrets(_opening.text);
    if (findings.isNotEmpty) {
      setState(
        () => _error =
            'The first message looks like it holds '
            '${findings.map((f) => f.label).join(', ')}.',
      );
      return;
    }
    setState(() {
      _error = null;
      _starting = true;
    });
    try {
      await widget.controller.startPaired(
        hostA: a.host,
        agentA: a.agent,
        hostB: b.host,
        agentB: b.agent,
        opening: _opening.text.trim(),
        duration: Duration(minutes: _minutes),
      );
    } on Object catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Widget _picker(String label, _Pick? value, ValueChanged<_Pick?> onChanged) {
    final candidates = _candidates;
    return DropdownButtonFormField<String>(
      key: ValueKey('paired-pick-$label'),
      initialValue: value == null ? null : _key(value),
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: [
        for (final p in candidates)
          DropdownMenuItem(
            value: _key(p),
            enabled:
                agentModeSafety(p.agent.permissionMode) == AgentModeSafety.safe,
            child: Text(
              '${p.agent.name} on ${p.host.name}'
              '${switch (agentModeSafety(p.agent.permissionMode)) {
                AgentModeSafety.safe => '',
                AgentModeSafety.unsafe => ' (auto mode: not allowed)',
                AgentModeSafety.unknown => ' (mode unknown: not allowed)',
              }}',
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: (key) =>
          onChanged(candidates.where((p) => _key(p) == key).firstOrNull),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Paired machines')),
      body: ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) {
          final session = widget.controller.paired;
          if (session != null && session.active) {
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [PairedModeBanner(controller: widget.controller)],
            );
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text(
                'Two of your agents talk through a passphrase-protected '
                'Talkbawt thread for a set time. The phone passes each reply '
                'on without asking you each time, framed as the other '
                "agent's output, never as your instruction. Both agents must "
                'be in default or plan mode, so they still ask before acting. '
                'It stops by itself, and runs only while this app is open.',
              ),
              if (session?.stopped case final reason?)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'Last session: ${reason.label}, '
                    '${session!.relayed} message(s) relayed.',
                    key: const ValueKey('paired-last'),
                  ),
                ),
              const SizedBox(height: 12),
              _picker(
                'A (holds the thread)',
                _a,
                (p) => setState(() => _a = p),
              ),
              _picker('B', _b, (p) => setState(() => _b = p)),
              const SizedBox(height: 12),
              SegmentedButton<int>(
                key: const ValueKey('paired-duration'),
                segments: const [
                  ButtonSegment(value: 15, label: Text('15 min')),
                  ButtonSegment(value: 30, label: Text('30 min')),
                  ButtonSegment(value: 60, label: Text('1 hour')),
                ],
                selected: {_minutes},
                onSelectionChanged: (s) => setState(() => _minutes = s.first),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('paired-opening'),
                controller: _opening,
                minLines: 2,
                maxLines: 6,
                decoration: const InputDecoration(
                  labelText: 'First message, from A to B',
                ),
              ),
              if (_error case final error?)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    error,
                    key: const ValueKey('paired-error'),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              FilledButton(
                key: const ValueKey('paired-start'),
                onPressed: _starting ? null : () => unawaited(_start()),
                child: Text('Pair for $_minutes minutes'),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// While a paired session runs: who talks to whom, time left, messages
/// relayed, and Stop. Shown on the paired page and above every screen.
class PairedModeBanner extends StatefulWidget {
  const PairedModeBanner({
    required this.controller,
    this.compact = false,
    super.key,
  });

  final TalkbawtController controller;

  /// One line, for the overlay above every screen.
  final bool compact;

  @override
  State<PairedModeBanner> createState() => _PairedModeBannerState();
}

class _PairedModeBannerState extends State<PairedModeBanner> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && (widget.controller.paired?.active ?? false)) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final PairedSession? s = widget.controller.paired;
        if (s == null || !s.active) return const SizedBox.shrink();
        final palette = AppPalette.of(context);
        final left = s.remaining(DateTime.now());
        final clock =
            '${left.inMinutes}:${(left.inSeconds % 60).toString().padLeft(2, '0')}';
        final stop = TextButton(
          key: const ValueKey('paired-stop'),
          onPressed: () => unawaited(widget.controller.stopPaired()),
          child: const Text('Stop'),
        );
        final body = widget.compact
            ? Row(
                children: [
                  const Icon(Icons.sync_alt_rounded, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Paired: ${s.a.label} ⇄ ${s.b.label} · $clock left',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  stop,
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Paired and relaying',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  Text('${s.a.label} ⇄ ${s.b.label}'),
                  Text(
                    '$clock left · ${s.relayed} relayed',
                    key: const ValueKey('paired-remaining'),
                  ),
                  if (s.lastError case final error?)
                    Text(error, style: TextStyle(color: palette.danger)),
                  Align(alignment: Alignment.centerRight, child: stop),
                ],
              );
        return Material(
          key: const ValueKey('paired-active-banner'),
          color: palette.attention.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: 12,
              vertical: widget.compact ? 2 : 12,
            ),
            child: body,
          ),
        );
      },
    );
  }
}
