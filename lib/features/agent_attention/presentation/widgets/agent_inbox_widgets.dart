import 'dart:math' as math;

import 'package:conduit/core/theme/app_theme.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/domain/agent_inbox.dart';
import 'package:conduit/features/agent_attention/presentation/widgets/approval_widgets.dart';
import 'package:flutter/material.dart';

/// Which agent CLI a row belongs to, from the provider's free-form kind.
class AgentKindStyle {
  const AgentKindStyle._(this.label, this.monogram, this.color);

  factory AgentKindStyle.of(String kind) {
    final normalized = kind.toLowerCase();
    for (final (match, style) in _known) {
      if (normalized.contains(match)) {
        return style;
      }
    }
    return _generic;
  }

  final String label;
  final String monogram;
  final Color color;

  static const _claude = AgentKindStyle._(
    'Claude Code',
    'CC',
    Color(0xFFD97757),
  );
  static const _generic = AgentKindStyle._('Agent', '', Color(0xFF7A869A));
  static const _known = [
    ('claude', _claude),
    ('codex', AgentKindStyle._('Codex', 'CX', Color(0xFF10A37F))),
    ('opencode', AgentKindStyle._('OpenCode', 'OC', Color(0xFF5C6BC0))),
    ('gemini', AgentKindStyle._('Gemini CLI', 'GM', Color(0xFF4285F4))),
    ('aider', AgentKindStyle._('Aider', 'AI', Color(0xFF8E6CC9))),
    ('cursor', AgentKindStyle._('Cursor', 'CU', Color(0xFF6D7B8D))),
    ('amp', AgentKindStyle._('Amp', 'AM', Color(0xFFE0548B))),
    ('goose', AgentKindStyle._('Goose', 'GO', Color(0xFF6A9A3C))),
  ];
}

/// Round badge naming the agent CLI (monogram in its colour).
class AgentKindBadge extends StatelessWidget {
  const AgentKindBadge({required this.kind, this.size = 36, super.key});

  final String kind;
  final double size;

  @override
  Widget build(BuildContext context) {
    final style = AgentKindStyle.of(kind);
    return Tooltip(
      message: kind.isEmpty ? style.label : '${style.label} ($kind)',
      excludeFromSemantics: true,
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: style.color.withValues(alpha: 0.16),
          shape: BoxShape.circle,
          border: Border.all(color: style.color.withValues(alpha: 0.55)),
        ),
        child: style.monogram.isEmpty
            ? Icon(
                Icons.smart_toy_outlined,
                size: size * 0.5,
                color: style.color,
              )
            : Text(
                style.monogram,
                style: TextStyle(
                  color: style.color,
                  fontWeight: FontWeight.w800,
                  fontSize: size * 0.34,
                  letterSpacing: 0.2,
                ),
              ),
      ),
    );
  }
}

/// A small ring showing how full an agent's context window is. Turns amber
/// past 70 % and red past 90 %.
class ContextRing extends StatelessWidget {
  const ContextRing({
    required this.percent,
    this.size = 22,
    this.showLabel = false,
    super.key,
  });

  /// 0 to 100.
  final double percent;
  final double size;

  /// Draws the rounded percentage inside the ring (for larger rings).
  final bool showLabel;

  static Color colorFor(double percent, ColorScheme scheme) {
    if (percent >= 90) {
      return scheme.error;
    }
    if (percent >= 70) {
      return const Color(0xFFE0A030);
    }
    return scheme.primary;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final clamped = percent.clamp(0, 100).toDouble();
    return Semantics(
      label: 'Context ${clamped.round()} percent used',
      child: SizedBox.square(
        dimension: size,
        child: CustomPaint(
          painter: _RingPainter(
            fraction: clamped / 100,
            color: colorFor(clamped, scheme),
            track: scheme.outlineVariant,
            stroke: math.max(2.5, size / 9),
          ),
          child: showLabel
              ? Center(
                  child: Text(
                    '${clamped.round()}%',
                    style: TextStyle(
                      fontSize: size * 0.24,
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurface,
                    ),
                  ),
                )
              : null,
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  const _RingPainter({
    required this.fraction,
    required this.color,
    required this.track,
    required this.stroke,
  });

  final double fraction;
  final Color color;
  final Color track;
  final double stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(stroke / 2);
    final base = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = track;
    canvas.drawArc(rect, 0, math.pi * 2, false, base);
    if (fraction <= 0) {
      return;
    }
    canvas.drawArc(
      rect,
      -math.pi / 2,
      math.pi * 2 * fraction,
      false,
      base
        ..color = color
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.fraction != fraction ||
      old.color != color ||
      old.track != track ||
      old.stroke != stroke;
}

/// Colour and short label for an agent's state chip.
({String label, Color color}) agentStateStyle(
  AgentInfo agent,
  ColorScheme scheme,
) {
  if (agent.pendingRequests.isNotEmpty) {
    return (label: 'Approval', color: scheme.error);
  }
  return switch (agent.state) {
    AgentAttentionState.working => (label: 'Working', color: scheme.primary),
    AgentAttentionState.needsInput => (
      label: 'Needs input',
      color: scheme.error,
    ),
    AgentAttentionState.blocked => (label: 'Blocked', color: scheme.error),
    AgentAttentionState.finished => (label: 'Done', color: scheme.tertiary),
    AgentAttentionState.idle => (label: 'Idle', color: scheme.onSurfaceVariant),
    AgentAttentionState.unknown => (
      label: 'Unknown',
      color: scheme.onSurfaceVariant,
    ),
  };
}

class AgentStateChip extends StatelessWidget {
  const AgentStateChip({required this.agent, super.key});

  final AgentInfo agent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = agentStateStyle(agent, theme.colorScheme);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: style.color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppTheme.radius),
      ),
      child: Text(
        style.label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: style.color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// "just now", "5m ago", "3h ago", "2d ago".
String relativeAgentTime(DateTime time, {DateTime? now}) {
  final delta = (now ?? DateTime.now()).toUtc().difference(time.toUtc());
  if (delta.inSeconds < 60) {
    return 'just now';
  }
  if (delta.inMinutes < 60) {
    return '${delta.inMinutes}m ago';
  }
  if (delta.inHours < 24) {
    return '${delta.inHours}h ago';
  }
  return '${delta.inDays}d ago';
}

/// Compact token count: 850, 85k, 1.2M.
String compactTokens(int tokens) {
  if (tokens >= 1000000) {
    final value = tokens / 1000000;
    return '${value.toStringAsFixed(value >= 10 ? 0 : 1)}M';
  }
  if (tokens >= 1000) {
    return '${(tokens / 1000).round()}k';
  }
  return '$tokens';
}

/// One inbox row: the live record of one agent session.
class AgentInboxRow extends StatelessWidget {
  const AgentInboxRow({
    required this.entry,
    required this.onOpen,
    this.showHost = true,
    this.onOpenChat,
    this.onReview,
    this.pending,
    super.key,
  });

  final AgentInboxEntry entry;
  final VoidCallback onOpen;

  /// False when the group header already names the host.
  final bool showHost;

  /// Renders a "Chat" button when set.
  final VoidCallback? onOpenChat;

  /// Renders a "Review" button (the last turn's changes) when set.
  final VoidCallback? onReview;

  /// The approval cards, shown under the row (pinned approvals).
  final Widget? pending;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final agent = entry.agent;
    final project = entry.project;
    final changed = agent.stateChangedAt;
    final contextPct = agent.usage?.contextUsedPct;
    final state = agentStateStyle(agent, scheme);
    final meta = [
      if (showHost) entry.hostName,
      if (agent.name != project) agent.name,
      if (changed != null) relativeAgentTime(changed),
    ].join(' · ');
    final message = agent.lastMessage?.trim();
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: scheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radius),
          side: BorderSide(
            color: agent.pendingRequests.isNotEmpty
                ? scheme.error.withValues(alpha: 0.5)
                : scheme.outlineVariant,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              button: true,
              label:
                  '${AgentKindStyle.of(agent.kind).label} $project on '
                  '${entry.hostName}, ${state.label}',
              child: InkWell(
                onTap: onOpen,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AgentKindBadge(kind: agent.kind),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    project,
                                    style: theme.textTheme.titleSmall?.copyWith(
                                      fontWeight: FontWeight.w700,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                AgentStateChip(agent: agent),
                              ],
                            ),
                            if (meta.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Text(
                                  meta,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            if (message != null && message.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(
                                  message,
                                  style: theme.textTheme.bodyMedium,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            if (onOpenChat != null || onReview != null)
                              Align(
                                alignment: AlignmentDirectional.centerEnd,
                                child: Wrap(
                                  children: [
                                    if (onReview case final review?)
                                      TextButton.icon(
                                        key: ValueKey(
                                          'agent-review-${entry.key}',
                                        ),
                                        style: TextButton.styleFrom(
                                          visualDensity: VisualDensity.compact,
                                        ),
                                        onPressed: review,
                                        icon: const Icon(
                                          Icons.rate_review_outlined,
                                          size: 18,
                                        ),
                                        label: const Text('Review'),
                                      ),
                                    if (onOpenChat case final openChat?)
                                      TextButton.icon(
                                        style: TextButton.styleFrom(
                                          visualDensity: VisualDensity.compact,
                                        ),
                                        onPressed: openChat,
                                        icon: const Icon(
                                          Icons.chat_bubble_outline_rounded,
                                          size: 18,
                                        ),
                                        label: const Text('Chat'),
                                      ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                      if (contextPct != null)
                        Padding(
                          padding: const EdgeInsets.only(left: 10, top: 2),
                          child: Tooltip(
                            message: 'Context ${contextPct.round()}% used',
                            child: ContextRing(percent: contextPct),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            ?pending,
          ],
        ),
      ),
    );
  }
}

/// One pending permission request: what the agent wants to run, its risk
/// label, the full tool input on demand, and the answers. With [onTrust]
/// (a companion that keeps rules), a "Trust" button saves a time-boxed
/// rule; high-risk requests get neither Trust nor Always.
class PendingRequestCard extends StatefulWidget {
  const PendingRequestCard({
    required this.request,
    required this.busy,
    required this.onDecide,
    this.onTrust,
    super.key,
  });

  final PendingPermissionRequest request;
  final bool busy;
  final ValueChanged<PermissionVerdict> onDecide;
  final VoidCallback? onTrust;

  @override
  State<PendingRequestCard> createState() => _PendingRequestCardState();
}

class _PendingRequestCardState extends State<PendingRequestCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final request = widget.request;
    final hasInput = request.toolInput.trim().isNotEmpty;
    final high = request.risk?.level == PermissionRiskLevel.high;
    final onTrust = request.trustable ? widget.onTrust : null;
    return Container(
      color: theme.colorScheme.errorContainer.withValues(alpha: 0.25),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.shield_outlined,
                size: 18,
                color: theme.colorScheme.error,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  request.toolName,
                  style: theme.textTheme.titleSmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (hasInput)
                TextButton.icon(
                  onPressed: () => setState(() => _expanded = !_expanded),
                  icon: Icon(
                    _expanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 18,
                  ),
                  label: Text(_expanded ? 'Hide input' : 'Tool input'),
                ),
            ],
          ),
          SelectableText(
            request.summary,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontFamily: 'monospace',
            ),
            maxLines: _expanded ? null : 3,
          ),
          if (request.risk case final risk?) ...[
            const SizedBox(height: 6),
            RiskLine(risk: risk),
          ],
          if (_expanded && hasInput) ...[
            const SizedBox(height: 8),
            Container(
              constraints: const BoxConstraints(maxHeight: 220),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(AppTheme.radius),
              ),
              padding: const EdgeInsets.all(10),
              child: SingleChildScrollView(
                child: SelectableText(
                  request.toolInput,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 8),
          ApprovalButtons(
            deny: ApprovalAction(
              PermissionVerdict.deny.label,
              widget.busy
                  ? null
                  : () => widget.onDecide(PermissionVerdict.deny),
            ),
            secondary: [
              if (onTrust != null)
                ApprovalAction(
                  'Trust…',
                  widget.busy ? null : onTrust,
                  key: ValueKey('trust-${request.id}'),
                ),
              // High risk always asks: no rule, from here or Claude Code.
              if (!(high && widget.onTrust != null))
                ApprovalAction(
                  PermissionVerdict.always.label,
                  widget.busy
                      ? null
                      : () => widget.onDecide(PermissionVerdict.always),
                ),
            ],
            allow: ApprovalAction(
              PermissionVerdict.allow.label,
              widget.busy
                  ? null
                  : () => widget.onDecide(PermissionVerdict.allow),
            ),
          ),
          if (widget.busy)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: LinearProgressIndicator(),
            ),
        ],
      ),
    );
  }
}
