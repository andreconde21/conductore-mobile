import 'dart:async';
import 'dart:math' as math;

import 'package:conduit/features/agent_attention/domain/agent_kinds.dart';
import 'package:conduit/features/chat_view/domain/chat_working.dart';
import 'package:flutter/material.dart';

/// The "`<agent>` is working" row at the bottom of the thread: a typing
/// bubble with three pulsing dots, the live activity label and a timer
/// that ticks every second. With reduced motion the dots stand still.
class ChatWorkingIndicator extends StatefulWidget {
  const ChatWorkingIndicator({
    required this.working,
    required this.since,
    this.now = DateTime.now,
    this.agentName,
    super.key,
  });

  final ChatWorking working;

  /// The agent's name for people; null when its kind is not known.
  final String? agentName;

  /// When the turn started (the prompt, else when the row first showed).
  final DateTime since;

  final DateTime Function() now;

  @override
  State<ChatWorkingIndicator> createState() => _ChatWorkingIndicatorState();
}

class _ChatWorkingIndicatorState extends State<ChatWorkingIndicator> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final elapsed = ChatWorking.elapsed(
      widget.now().toUtc().difference(widget.since.toUtc()),
    );
    return Semantics(
      liveRegion: true,
      label:
          '${agentSubject(widget.agentName)} is working: '
          '${widget.working.label}',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.only(top: 6, bottom: 4, right: 8),
        child: Row(
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHigh,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(14),
                  topRight: Radius.circular(14),
                  bottomRight: Radius.circular(14),
                  bottomLeft: Radius.circular(4),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                child: TypingDots(color: colorScheme.primary),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: widget.working.label),
                    TextSpan(
                      text: ' · $elapsed',
                      style: TextStyle(color: colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
                key: const ValueKey('chat-working-label'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Three dots that pulse in turn; static when animations are disabled.
class TypingDots extends StatefulWidget {
  const TypingDots({required this.color, super.key});

  final Color color;

  @override
  State<TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      unawaited(_controller.repeat());
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => Row(
        key: ValueKey(still ? 'typing-dots-static' : 'typing-dots'),
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < 3; i++) ...[
            if (i > 0) const SizedBox(width: 4),
            _dot(still ? 0.75 : _pulse(i)),
          ],
        ],
      ),
    );
  }

  /// Each dot peaks a third of a cycle after the previous one.
  double _pulse(int index) {
    final phase = (_controller.value - index / 3) * 2 * math.pi;
    return 0.35 + 0.65 * (0.5 + 0.5 * math.sin(phase));
  }

  Widget _dot(double strength) => Transform.scale(
    scale: 0.8 + 0.3 * strength,
    child: Container(
      width: 7,
      height: 7,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: widget.color.withValues(alpha: strength),
      ),
    ),
  );
}

/// Gently pulses [child]'s opacity while [active] (the header's state
/// while Claude works); still when animations are disabled.
class PulseWhile extends StatefulWidget {
  const PulseWhile({required this.active, required this.child, super.key});

  final bool active;
  final Widget child;

  @override
  State<PulseWhile> createState() => _PulseWhileState();
}

class _PulseWhileState extends State<PulseWhile>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  bool get _run =>
      widget.active && !(MediaQuery.maybeDisableAnimationsOf(context) ?? false);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(PulseWhile oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    if (_run) {
      if (!_controller.isAnimating) {
        unawaited(_controller.repeat(reverse: true));
      }
    } else {
      _controller
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(
        begin: 1,
        end: 0.45,
      ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut)),
      child: widget.child,
    );
  }
}
