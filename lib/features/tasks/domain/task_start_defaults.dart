import 'dart:convert';

import 'package:conduit/features/tasks/domain/task_run.dart';
import 'package:flutter/foundation.dart';

/// What "Start" preselects (CON-037), remembered on this device: the place,
/// agent, worktree, attempts, cap, "mark done", and the last machine and
/// repository per task source.
@immutable
class TaskStartDefaults {
  const TaskStartDefaults({
    this.place = TaskPlace.herdr,
    this.agent,
    this.worktree = true,
    this.attempts = 1,
    this.cap = 3,
    this.markDone = false,
    this.machineBySource = const {},
    this.repoBySource = const {},
  });

  final TaskPlace place;

  /// The agent kind chosen last; null: the machine's first.
  final String? agent;
  final bool worktree;
  final int attempts;
  final int cap;
  final bool markDone;

  /// Source id → machine id (`''`: automatic).
  final Map<String, String> machineBySource;

  /// Source id → repository path on the machine.
  final Map<String, String> repoBySource;

  TaskStartDefaults copyWith({
    TaskPlace? place,
    String? agent,
    bool? worktree,
    int? attempts,
    int? cap,
    bool? markDone,
    Map<String, String>? machineBySource,
    Map<String, String>? repoBySource,
  }) => TaskStartDefaults(
    place: place ?? this.place,
    agent: agent ?? this.agent,
    worktree: worktree ?? this.worktree,
    attempts: attempts ?? this.attempts,
    cap: cap ?? this.cap,
    markDone: markDone ?? this.markDone,
    machineBySource: machineBySource ?? this.machineBySource,
    repoBySource: repoBySource ?? this.repoBySource,
  );

  String toJson() => jsonEncode({
    'place': place.wire,
    'agent': ?agent,
    'worktree': worktree,
    'attempts': attempts,
    'cap': cap,
    'markDone': markDone,
    'machineBySource': machineBySource,
    'repoBySource': repoBySource,
  });

  static TaskStartDefaults parse(String? raw) {
    Object? json;
    try {
      json = raw == null ? null : jsonDecode(raw);
    } catch (_) {}
    if (json is! Map) return const TaskStartDefaults();
    Map<String, String> strings(Object? m) => {
      if (m is Map)
        for (final e in m.entries)
          if (e.key is String && e.value is String)
            e.key as String: e.value as String,
    };
    int clamp(Object? v, int min, int max, int fallback) =>
        v is int && v >= min && v <= max ? v : fallback;
    return TaskStartDefaults(
      place: TaskPlace.parse(json['place']),
      agent: json['agent'] is String ? json['agent'] as String : null,
      worktree: json['worktree'] != false,
      attempts: clamp(json['attempts'], 1, 5, 1),
      cap: clamp(json['cap'], 1, 20, 3),
      markDone: json['markDone'] == true,
      machineBySource: strings(json['machineBySource']),
      repoBySource: strings(json['repoBySource']),
    );
  }
}
