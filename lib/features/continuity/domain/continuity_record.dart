import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:flutter/foundation.dart';

/// Which face of a session a device showed.
enum ContinuityView {
  terminal('Terminal'),
  chat('Chat view');

  const ContinuityView(this.label);

  final String label;

  static ContinuityView parse(Object? raw) =>
      values.where((view) => view.name == raw).firstOrNull ??
      ContinuityView.terminal;
}

/// Where a device is: a machine, what the session there is attached to,
/// and the view it shows.
///
/// [machineId] is the id every device knows the machine by: a saved
/// machine's id. A desktop's "This computer" is published as the saved
/// machine that is that desktop (see `sharedMachineId`), or as null when
/// there is none: then only that desktop can open it.
@immutable
class ContinuityPlace {
  const ContinuityPlace({
    required this.machineId,
    this.machineName = '',
    this.target,
    this.view = ContinuityView.terminal,
    this.agentId,
    this.agentName = '',
    this.paneId = '',
    this.title = '',
  });

  final String? machineId;
  final String machineName;

  /// What the session is attached to (tmux session, Herdr workspace and
  /// tab, directory); null for a plain shell.
  final ConnectTarget? target;
  final ContinuityView view;

  /// The Claude session (the companion's agent id) the place shows; the
  /// same on every device, so Chat View opens the same conversation.
  final String? agentId;
  final String agentName;

  /// The Herdr pane of [agentId], to land on it in the terminal.
  final String paneId;

  /// The session's title as the device showed it.
  final String title;

  /// Whether [other] is the same place: machine, target, view and agent.
  /// Names and titles do not count.
  bool samePlace(ContinuityPlace other) =>
      other.machineId == machineId &&
      (other.target?.key ?? 'shell') == (target?.key ?? 'shell') &&
      other.view == view &&
      (view == ContinuityView.terminal || other.agentId == agentId);

  /// What the banner names: the Claude session in Chat View, else the
  /// workspace or tmux session, else the machine.
  String get label {
    if (view == ContinuityView.chat && agentName.trim().isNotEmpty) {
      return agentName.trim();
    }
    final targetTitle = switch (target) {
      null => '',
      final target when target.kind == ConnectTargetKind.shell => '',
      final target => target.title,
    };
    if (targetTitle.isNotEmpty) return targetTitle;
    if (machineName.isNotEmpty) return machineName;
    return title.isNotEmpty ? title : 'a session';
  }

  /// "VTM · Chat view".
  String get summary => '$label · ${view.label}';

  Map<String, Object?> toJson() => {
    'machine': machineId,
    if (machineName.isNotEmpty) 'machineName': machineName,
    'target': ?target?.toJson(),
    'view': view.name,
    'agent': ?agentId,
    if (agentName.isNotEmpty) 'agentName': agentName,
    if (paneId.isNotEmpty) 'pane': paneId,
    if (title.isNotEmpty) 'title': title,
  };

  static ContinuityPlace? fromJson(Object? json) {
    if (json is! Map) return null;
    final machine = json['machine'];
    final agent = json['agent'];
    final view = ContinuityView.parse(json['view']);
    if (view == ContinuityView.chat && agent is! String) return null;
    String text(String key) => json[key] is String ? json[key] as String : '';
    return ContinuityPlace(
      machineId: machine is String && machine.isNotEmpty ? machine : null,
      machineName: text('machineName'),
      target: ConnectTarget.fromJson(json['target']),
      view: view,
      agentId: agent is String && agent.isNotEmpty ? agent : null,
      agentName: text('agentName'),
      paneId: text('pane'),
      title: text('title'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ContinuityPlace &&
      samePlace(other) &&
      other.machineName == machineName &&
      other.agentName == agentName &&
      other.paneId == paneId &&
      other.title == title &&
      other.target?.label == target?.label;

  @override
  int get hashCode => Object.hash(
    machineId,
    target?.key,
    view,
    agentId,
    machineName,
    agentName,
    paneId,
    title,
  );
}

/// A place and when the device went there, with the Chat View scroll
/// position and the desktop layout while it was there.
@immutable
class ContinuityContext {
  const ContinuityContext({
    required this.place,
    required this.at,
    this.anchor,
    this.layout = '',
  });

  final ContinuityPlace place;
  final DateTime at;

  /// The newest Chat View item on screen while reading further up (the
  /// last one read); null at the bottom of the thread.
  final String? anchor;

  /// The desktop's named layout ("Morning check", "Two side by side").
  final String layout;

  ContinuityContext copyWith({
    DateTime? at,
    String? anchor,
    bool clearAnchor = false,
    String? layout,
  }) => ContinuityContext(
    place: place,
    at: at ?? this.at,
    anchor: clearAnchor ? null : anchor ?? this.anchor,
    layout: layout ?? this.layout,
  );

  Map<String, Object?> toJson({bool withAnchor = true}) => {
    ...place.toJson(),
    'at': at.millisecondsSinceEpoch,
    if (withAnchor && anchor != null) 'anchor': anchor,
    if (layout.isNotEmpty) 'layout': layout,
  };

  static ContinuityContext? fromJson(Object? json) {
    if (json is! Map) return null;
    final place = ContinuityPlace.fromJson(json);
    final at = json['at'];
    if (place == null || at is! int) return null;
    final anchor = json['anchor'];
    final layout = json['layout'];
    return ContinuityContext(
      place: place,
      at: DateTime.fromMillisecondsSinceEpoch(at),
      anchor: anchor is String && anchor.isNotEmpty ? anchor : null,
      layout: layout is String ? layout : '',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ContinuityContext &&
      other.place == place &&
      other.at == at &&
      other.anchor == anchor &&
      other.layout == layout;

  @override
  int get hashCode => Object.hash(place, at, anchor, layout);
}

/// An unsent Chat View prompt. Empty [text] records that the draft was
/// sent or cleared at [at], so an older copy elsewhere is not offered
/// again as new.
@immutable
class ContinuityDraft {
  const ContinuityDraft({required this.text, required this.at});

  final String text;
  final DateTime at;

  bool get isEmpty => text.trim().isEmpty;

  Map<String, Object?> toJson() => {
    'text': text,
    'at': at.millisecondsSinceEpoch,
  };

  static ContinuityDraft? fromJson(Object? json) {
    if (json is! Map) return null;
    final text = json['text'];
    final at = json['at'];
    if (text is! String || at is! int) return null;
    return ContinuityDraft(
      text: text,
      at: DateTime.fromMillisecondsSinceEpoch(at),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ContinuityDraft && other.text == text && other.at == at;

  @override
  int get hashCode => Object.hash(text, at);
}

/// One device's continuity record (`continuity:<device id>`): only that
/// device writes it, so devices never overwrite each other's.
@immutable
class DeviceContinuity {
  const DeviceContinuity({
    required this.deviceId,
    this.deviceName = '',
    this.platform = '',
    this.desktop = false,
    this.activeAt,
    this.context,
    this.recent = const [],
    this.drafts = const {},
  });

  static const version = 1;

  /// Recent places kept per device.
  static const maxRecent = 8;

  /// Drafts kept per device, newest first, and the longest one.
  static const maxDrafts = 12;
  static const maxDraftLength = 8000;

  final String deviceId;
  final String deviceName;
  final String platform;
  final bool desktop;

  /// When the device was last in use.
  final DateTime? activeAt;

  /// Where it is (or was last).
  final ContinuityContext? context;

  /// Places it was before [context], newest first.
  final List<ContinuityContext> recent;

  /// Unsent Chat View prompts by Claude session id.
  final Map<String, ContinuityDraft> drafts;

  String get name => deviceName.trim().isEmpty ? 'another device' : deviceName;

  Map<String, Object?> toJson() => {
    'v': version,
    if (deviceName.isNotEmpty) 'device': deviceName,
    if (platform.isNotEmpty) 'platform': platform,
    if (desktop) 'desktop': true,
    if (activeAt case final at?) 'activeAt': at.millisecondsSinceEpoch,
    if (context case final context?) 'context': context.toJson(),
    if (recent.isNotEmpty)
      'recent': [
        for (final context in recent) context.toJson(withAnchor: false),
      ],
    if (drafts.isNotEmpty)
      'drafts': {
        for (final MapEntry(:key, :value) in drafts.entries)
          key: value.toJson(),
      },
  };

  /// Reads [deviceId]'s record; null for one this build cannot read (a
  /// newer format).
  static DeviceContinuity? fromJson(String deviceId, Object? json) {
    if (json is! Map) return null;
    final v = json['v'];
    if (v is! int || v > version) return null;
    final name = json['device'];
    final platform = json['platform'];
    final activeAt = json['activeAt'];
    final rawDrafts = json['drafts'];
    return DeviceContinuity(
      deviceId: deviceId,
      deviceName: name is String ? name : '',
      platform: platform is String ? platform : '',
      desktop: json['desktop'] == true,
      activeAt: activeAt is int
          ? DateTime.fromMillisecondsSinceEpoch(activeAt)
          : null,
      context: ContinuityContext.fromJson(json['context']),
      recent: [
        for (final item in (json['recent'] as List?) ?? const [])
          ?ContinuityContext.fromJson(item),
      ],
      drafts: {
        if (rawDrafts is Map)
          for (final MapEntry(:key, :value) in rawDrafts.entries)
            if (key is String) key: ?ContinuityDraft.fromJson(value),
      },
    );
  }
}
