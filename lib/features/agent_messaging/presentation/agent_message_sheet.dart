import 'dart:async';

import 'package:conduit/core/presentation/adaptive_modal.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/presentation/widgets/agent_inbox_widgets.dart';
import 'package:conduit/features/agent_messaging/data/agent_messenger.dart';
import 'package:conduit/features/agent_messaging/domain/agent_message.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/live/domain/live_host_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Where a message comes from: the machine, and the agent whose output it
/// is when it relays one (null for the user's own words).
class AgentMessageSource {
  const AgentMessageSource({this.host, this.agentId, this.agentLabel});

  final SavedHost? host;

  /// The sender's own id, left out of the targets.
  final String? agentId;

  /// "reviewer on VTM": set when the text is another agent's output,
  /// which then arrives framed as context.
  final String? agentLabel;
}

/// "Message agents": pick one or more agents, see the exact text each will
/// get, and send, or ask one and wait for its answer (which can be relayed
/// on). Nothing is sent before the explicit Send.
Future<void> showAgentMessageSheet(
  BuildContext context, {
  required AgentMessenger messenger,
  required String text,
  AgentMessageSource source = const AgentMessageSource(),
}) async {
  final targets = messenger.targets(
    excludeHostId: source.host?.id,
    excludeAgentId: source.agentId,
  );
  if (targets.isEmpty) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(
        content: Text(
          'No other agent on a monitored machine whose companion takes '
          'messages.',
        ),
      ),
    );
    return;
  }
  await showAdaptiveModal<void>(
    context: context,
    kind: AdaptiveModalKind.dialog,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (context) => AgentMessageSheet(
      messenger: messenger,
      targets: targets,
      text: text,
      source: source,
    ),
  );
}

enum _Phase { compose, sending, done }

/// The sheet behind [showAgentMessageSheet].
class AgentMessageSheet extends StatefulWidget {
  const AgentMessageSheet({
    required this.messenger,
    required this.targets,
    required this.text,
    this.source = const AgentMessageSource(),
    super.key,
  });

  final AgentMessenger messenger;
  final List<AgentMessageTarget> targets;
  final String text;
  final AgentMessageSource source;

  @override
  State<AgentMessageSheet> createState() => _AgentMessageSheetState();
}

class _AgentMessageSheetState extends State<AgentMessageSheet> {
  final Set<AgentMessageTarget> _chosen = {};
  bool _wait = false;
  Duration _timeout = const Duration(minutes: 2);
  _Phase _phase = _Phase.compose;
  List<AgentSendResult> _results = const [];

  static const _timeouts = [
    Duration(minutes: 1),
    Duration(minutes: 2),
    Duration(minutes: 5),
    Duration(minutes: 10),
  ];

  String? get _contextFrom => widget.source.agentLabel;

  String get _exactText =>
      AgentMessenger.textFor(widget.text, contextFrom: _contextFrom);

  /// "Ask and wait" is for one agent at a time.
  bool get _canWait => _chosen.length == 1;

  String _label(AgentMessageTarget t) {
    final kind = AgentKindStyle.of(t.agent.kind).label;
    return '${t.agent.name} · $kind · ${t.host.name}';
  }

  Future<void> _send() async {
    setState(() => _phase = _Phase.sending);
    final results = await widget.messenger.send(
      to: _chosen.toList(),
      text: widget.text,
      from: widget.source.host,
      contextFrom: _contextFrom,
      wait: _wait && _canWait,
      timeout: _timeout,
    );
    if (!mounted) return;
    setState(() {
      _results = results;
      _phase = _Phase.done;
    });
  }

  AgentMessageTarget? _targetOf(AgentSendResult result) =>
      _chosen.where((t) => t.target == result.target).firstOrNull;

  Future<void> _relay(AgentSendResult result) async {
    final from = _targetOf(result);
    final answer = result.answer;
    if (from == null || answer == null) return;
    Navigator.of(context).pop();
    await showAgentMessageSheet(
      context,
      messenger: widget.messenger,
      text: answer,
      source: AgentMessageSource(
        host: from.host,
        agentId: from.agent.id,
        agentLabel: '${from.agent.name} on ${from.host.name}',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _contextFrom == null ? 'Message agents' : 'Relay the answer',
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Flexible(
              child: SingleChildScrollView(
                child: switch (_phase) {
                  _Phase.compose => _compose(theme),
                  _Phase.sending => const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                  _Phase.done => _done(theme),
                },
              ),
            ),
            const SizedBox(height: 8),
            _buttons(),
          ],
        ),
      ),
    );
  }

  Widget _compose(ThemeData theme) {
    final crossing = _chosen.any(
      (t) => AgentMessenger.crossesMachines(widget.source.host, t),
    );
    final route = widget.messenger.relayRoute();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final target in widget.targets)
          CheckboxListTile(
            key: ValueKey('agent-message-target-${target.target}'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            value: _chosen.contains(target),
            onChanged: (on) => setState(() {
              if (on == true) {
                _chosen.add(target);
              } else {
                _chosen.remove(target);
              }
            }),
            secondary: AgentKindBadge(kind: target.agent.kind, size: 28),
            title: Text(
              _label(target),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              [
                target.agent.state.label,
                if (target.agent.state.needsAttention)
                  'waiting on a question: it will refuse',
                if (isHerdrOnlyAgent(target.agent)) 'via Herdr',
              ].join(' · '),
            ),
          ),
        const Divider(),
        SwitchListTile(
          key: const ValueKey('agent-message-wait'),
          contentPadding: EdgeInsets.zero,
          value: _wait && _canWait,
          onChanged: _canWait ? (on) => setState(() => _wait = on) : null,
          title: const Text('Ask and wait for the answer'),
          subtitle: Text(
            _canWait
                ? 'Up to ${_timeout.inMinutes} min. A timeout is never '
                      'resent: the message may have arrived.'
                : 'Pick one agent to wait for its answer.',
          ),
        ),
        if (_wait && _canWait)
          Wrap(
            spacing: 8,
            children: [
              for (final t in _timeouts)
                ChoiceChip(
                  label: Text('${t.inMinutes} min'),
                  selected: _timeout == t,
                  onSelected: (_) => setState(() => _timeout = t),
                ),
            ],
          ),
        const SizedBox(height: 12),
        Text(
          _contextFrom == null
              ? 'Each agent gets exactly this:'
              : 'Each agent gets exactly this, framed as context (not as '
                    'your instruction):',
          style: theme.textTheme.labelLarge,
        ),
        const SizedBox(height: 6),
        Container(
          key: const ValueKey('agent-message-preview'),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          constraints: const BoxConstraints(maxHeight: 220),
          child: SingleChildScrollView(
            child: SelectableText(
              _exactText,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
              ),
            ),
          ),
        ),
        if (crossing)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              route == AgentRelayRoute.phone
                  ? 'Another machine: the phone relays it through that '
                        "machine's companion. Nothing leaves your machines."
                  : 'Another machine: it goes through Talkbawt (your relay '
                        'setting).',
              key: const ValueKey('agent-message-route'),
              style: theme.textTheme.bodySmall,
            ),
          ),
      ],
    );
  }

  Widget _done(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final result in _results) ...[
          ListTile(
            key: ValueKey('agent-message-result-${result.target}'),
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              result.ok
                  ? Icons.check_circle_outline
                  : result.maybeDelivered
                  ? Icons.help_outline
                  : Icons.block,
            ),
            title: Text(
              _targetOf(result) == null
                  ? result.target
                  : _label(_targetOf(result)!),
            ),
            subtitle: Text(_describe(result)),
          ),
          if (result.answer case final answer?) ...[
            Container(
              key: ValueKey('agent-message-answer-${result.target}'),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              constraints: const BoxConstraints(maxHeight: 260),
              child: SingleChildScrollView(child: SelectableText(answer)),
            ),
            Wrap(
              alignment: WrapAlignment.end,
              children: [
                TextButton.icon(
                  onPressed: () =>
                      unawaited(Clipboard.setData(ClipboardData(text: answer))),
                  icon: const Icon(Icons.copy_rounded, size: 18),
                  label: const Text('Copy'),
                ),
                TextButton.icon(
                  key: ValueKey('agent-message-relay-${result.target}'),
                  onPressed: () => unawaited(_relay(result)),
                  icon: const Icon(Icons.forward_rounded, size: 18),
                  label: const Text('Relay the answer…'),
                ),
              ],
            ),
          ],
        ],
      ],
    );
  }

  static String _describe(AgentSendResult result) {
    if (result.ok) {
      if (result.answer != null) return 'Answered (${result.state ?? 'idle'})';
      return 'Sent';
    }
    if (result.blocked) {
      return 'Refused: it waits on a question or an approval. Answer that '
          'first.';
    }
    if (result.maybeDelivered) {
      return '${result.timedOut ? 'Timed out' : 'No answer'}: it may have '
          'arrived. Not sent again; check the agent before retrying.';
    }
    return result.error ?? 'Not sent';
  }

  Widget _buttons() {
    final close = TextButton(
      onPressed: () => Navigator.of(context).pop(),
      child: Text(_phase == _Phase.done ? 'Close' : 'Cancel'),
    );
    if (_phase != _Phase.compose) {
      return Align(alignment: AlignmentDirectional.centerEnd, child: close);
    }
    final count = _chosen.length;
    final label = count == 0
        ? 'Send'
        : _wait && _canWait
        ? 'Ask and wait'
        : count == 1
        ? 'Send'
        : 'Send to $count agents';
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        close,
        const SizedBox(width: 8),
        FilledButton(
          key: const ValueKey('agent-message-send'),
          onPressed: count == 0 ? null : () => unawaited(_send()),
          child: Text(label),
        ),
      ],
    );
  }
}
