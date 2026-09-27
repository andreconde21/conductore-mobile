// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';

import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/home_widget/domain/agent_status_snapshot.dart';
import 'package:conduit/features/home_widget/domain/agent_status_widget_channel.dart';
import 'package:conduit/features/usage/domain/usage_report.dart';
import 'package:conduit/features/usage/presentation/usage_controller.dart';
import 'package:flutter/foundation.dart';

/// Keeps the native widget and tile in sync with the agent dashboard.
///
/// Pushes one snapshot on [start] and then at most one per [debounce]
/// window after the source changes (the dashboard notifies on every poll of
/// every host, so bursts are common). Pushes never overlap: a change that
/// arrives while a push is in flight schedules exactly one more. A snapshot
/// that differs from the last one pushed only by its time is skipped until
/// [unchangedRefresh] has passed (the widget shows the time to the minute).
class AgentStatusWidgetPusher {
  AgentStatusWidgetPusher({
    required Listenable source,
    required AgentStatusSnapshot Function() snapshot,
    required AgentStatusWidgetChannel channel,
    this.debounce = const Duration(milliseconds: 500),
  }) : _source = source,
       _snapshot = snapshot,
       _channel = channel;

  /// Wires the pusher to the live [AgentAttentionController].
  /// With [usage], the widget also shows Claude's limit rings.
  factory AgentStatusWidgetPusher.forController(
    AgentAttentionController controller, {
    required AgentStatusWidgetChannel channel,
    UsageController? usage,
    Duration debounce = const Duration(milliseconds: 500),
  }) {
    return AgentStatusWidgetPusher(
      source: usage == null
          ? controller
          : Listenable.merge([controller, usage]),
      snapshot: () => snapshotOf(controller, usage: usage),
      channel: channel,
      debounce: debounce,
    );
  }

  final Listenable _source;
  final AgentStatusSnapshot Function() _snapshot;
  final AgentStatusWidgetChannel _channel;
  final Duration debounce;

  /// How long a snapshot with nothing new but its time is held back.
  static const unchangedRefresh = Duration(minutes: 1);

  Timer? _timer;
  String? _lastContent;
  DateTime? _lastPushedAt;
  bool _pushing = false;
  bool _pushAgain = false;
  bool _started = false;
  bool _disposed = false;

  /// Builds the snapshot the widget shows for [controller]'s current state.
  static AgentStatusSnapshot snapshotOf(
    AgentAttentionController controller, {
    UsageController? usage,
    DateTime? now,
  }) {
    final hosts = controller.monitoredHosts;
    final at = now ?? DateTime.now();
    return AgentStatusSnapshot.build(
      hosts: [
        for (final host in hosts)
          (
            hostName: host.name,
            agents: controller.statusFor(host.id)?.agents ?? const [],
          ),
      ],
      monitoring: hosts.isNotEmpty,
      now: at,
      limits: usage == null
          ? const []
          : widgetLimits(usage.summary.claudeLimits, at),
    );
  }

  /// The 5-hour and weekly windows as the widget's rings.
  static List<AgentStatusLimit> widgetLimits(
    List<UsageLimit> limits,
    DateTime now,
  ) => [
    for (final limit in limits)
      if (limit.isFiveHour || limit.isWeekly)
        AgentStatusLimit(
          label: limit.label,
          usedPct: limit.effectivePct(now).round(),
          resetsAt: limit.resetsAt,
        ),
  ];

  /// Pushes the current state immediately and starts listening for changes.
  void start() {
    if (_started || _disposed) {
      return;
    }
    _started = true;
    _source.addListener(_onChanged);
    unawaited(_push());
  }

  void _onChanged() {
    if (_disposed || _timer != null) {
      return;
    }
    _timer = Timer(debounce, () {
      _timer = null;
      unawaited(_push());
    });
  }

  Future<void> _push() async {
    if (_disposed) {
      return;
    }
    if (_pushing) {
      _pushAgain = true;
      return;
    }
    _pushing = true;
    try {
      do {
        _pushAgain = false;
        try {
          final snapshot = _snapshot();
          final content = jsonEncode(snapshot.toJson()..remove('updatedAt'));
          final last = _lastPushedAt;
          if (content == _lastContent &&
              last != null &&
              snapshot.updatedAt.difference(last) < unchangedRefresh) {
            continue;
          }
          await _channel.push(snapshot);
          _lastContent = content;
          _lastPushedAt = snapshot.updatedAt;
        } catch (_) {
          // The widget is best-effort; never let it break the dashboard.
        }
      } while (_pushAgain && !_disposed);
    } finally {
      _pushing = false;
    }
  }

  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    if (_started) {
      _source.removeListener(_onChanged);
    }
  }
}
