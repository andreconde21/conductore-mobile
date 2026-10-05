import 'dart:async';

import 'package:conduit/features/agent_attention/domain/launcher_prompt.dart';
import 'package:conduit/features/home_widget/domain/agent_status_snapshot.dart';
import 'package:conduit/features/home_widget/domain/agent_status_widget_channel.dart';

/// Records pushes and lets a test hand out launch targets.
class FakeAgentStatusWidgetChannel implements AgentStatusWidgetChannel {
  final List<AgentStatusSnapshot> pushed = [];
  AgentStatusLaunchTarget? pendingTarget;
  AddTileResult addTileResult = AddTileResult.added;
  void Function()? listener;

  /// When set, `push` waits on this completer (simulates a slow native side).
  Completer<void>? pushGate;
  int consumeCalls = 0;

  @override
  Future<void> push(AgentStatusSnapshot snapshot) async {
    pushed.add(snapshot);
    final gate = pushGate;
    if (gate != null) {
      await gate.future;
    }
  }

  final List<List<LauncherPrompt>> pushedPrompts = [];

  @override
  Future<void> pushLauncherPrompts(List<LauncherPrompt> prompts) async {
    pushedPrompts.add(prompts);
  }

  @override
  Future<AgentStatusLaunchTarget?> consumeLaunchTarget() async {
    consumeCalls += 1;
    final target = pendingTarget;
    pendingTarget = null;
    return target;
  }

  @override
  void setLaunchTargetListener(void Function()? listener) {
    this.listener = listener;
  }

  @override
  Future<AddTileResult> requestAddTile() async => addTileResult;

  /// Simulates a widget/tile intent arriving while the app runs.
  void deliver(AgentStatusLaunchTarget target) {
    pendingTarget = target;
    listener?.call();
  }
}
