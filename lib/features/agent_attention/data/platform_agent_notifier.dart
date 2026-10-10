import 'package:conduit/features/agent_attention/domain/agent_attention_notifier.dart';
import 'package:conduit/features/agent_attention/domain/agent_notifications.dart';
import 'package:conduit/features/agent_attention/domain/agent_permission_actions.dart';
import 'package:conduit/features/agent_attention/domain/agent_urgent_notifications.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android implementation of agent notifications over a platform channel,
/// following the app's native-notification precedent (the background
/// keepalive service). Notification permission rides the existing
/// POST_NOTIFICATIONS request flow in `main.dart`.
///
/// On platforms without a native handler (currently iOS: the app posts no
/// local notifications there) every call is a no-op; the dashboard itself
/// works everywhere.
class PlatformAgentAttentionNotifier implements AgentAttentionNotifier {
  const PlatformAgentAttentionNotifier();

  static const channel = MethodChannel('conduit/agent_notifications');

  @override
  Future<void> show({
    required String id,
    required String title,
    required String body,
    AgentOpenTarget? open,
  }) {
    return _invoke('show', {
      'id': id,
      'title': title,
      'body': body,
      ...?open?.toArguments(),
    });
  }

  @override
  Future<void> showAgents({
    required String hostId,
    required List<AgentNotification> notifications,
  }) {
    return _invoke('showAgents', {
      'hostId': hostId,
      'notifications': [
        for (final notification in notifications) notification.toArguments(),
      ],
    });
  }

  @override
  Future<void> showAgent(AgentNotification notification) =>
      _invoke('showAgent', notification.toArguments());

  @override
  Future<void> cancelAgent({required String key}) =>
      _invoke('cancelAgent', {'key': key});

  @override
  Future<void> showStatus(AgentOngoingStatus? status) =>
      _invoke('showStatus', {'status': status?.toArguments()});

  /// Routes native-to-Dart calls on [channel] to the permission action and
  /// open-agent listeners; the channel has one handler slot for both.
  static void _installHandler() {
    if (_handlerInstalled || defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    _handlerInstalled = true;
    channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'permissionActionAvailable':
          // Tells the native side whether the tap is being completed; if
          // not (app locked), it asks the user to open the app.
          return PlatformAgentPermissionActions.instance._listener?.call() ??
              false;
        case 'openAgentAvailable':
          PlatformAgentOpenRequests.instance._listener?.call();
          return null;
        case 'launcherAction':
          return PlatformLauncherActions.instance.handle(call.arguments);
        case 'launcherAnswersAvailable':
          PlatformLauncherActions.instance._queuedListener?.call();
          return null;
      }
      return null;
    });
  }

  static bool _handlerInstalled = false;

  /// Tells the native side the app lock as background actions must see it
  /// (`AppLockController.actionState`): notification buttons and the
  /// launcher refuse while [locked], or from [relockAt] on. The native
  /// side treats "never told" as locked.
  static Future<void> setAppLockState({
    required bool locked,
    DateTime? relockAt,
  }) async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    try {
      await channel.invokeMethod<void>('appLockState', {
        'locked': locked,
        'relockAtMillis': relockAt?.millisecondsSinceEpoch,
      });
    } on MissingPluginException {
      // No native handler (tests).
    } on PlatformException {
      // Best effort: the native side stays at its last (or locked) state.
    }
  }

  @override
  Future<void> cancel({required String id}) => _invoke('cancel', {'id': id});

  Future<void> _invoke(String method, Map<String, Object?> arguments) async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    try {
      await channel.invokeMethod<void>(method, arguments);
    } on MissingPluginException {
      // No native handler registered (e.g. tests); notifications are
      // best-effort.
    } on PlatformException {
      // Notification permission may be denied; never let that break polling.
    }
  }
}

/// Receives Allow / Deny / Always, answer and Reply taps from the Android
/// notification actions over the same channel. The native side queues each tap in
/// SharedPreferences (so a tap that started the app is delivered after
/// Dart is ready) and calls `permissionActionAvailable` while the engine
/// is alive.
class PlatformAgentPermissionActions implements AgentPermissionActionSource {
  PlatformAgentPermissionActions._();

  static final instance = PlatformAgentPermissionActions._();

  bool Function()? _listener;

  @override
  void setListener(bool Function()? listener) {
    _listener = listener;
    PlatformAgentAttentionNotifier._installHandler();
  }

  @override
  Future<List<AgentPermissionAction>> consumeActions() async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return const [];
    }
    try {
      final raw = await PlatformAgentAttentionNotifier.channel
          .invokeMethod<List<Object?>>('consumePermissionActions');
      return parseActions(raw);
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      return const [];
    }
  }

  @visibleForTesting
  static List<AgentPermissionAction> parseActions(List<Object?>? raw) {
    if (raw == null) {
      return const [];
    }
    return [
      for (final item in raw)
        if (item is Map)
          if (item['hostId'] is String && item['requestId'] is String)
            AgentPermissionAction(
              notificationId: item['notificationId'] as String? ?? '',
              hostId: item['hostId'] as String,
              agentId: item['agentId'] as String? ?? '',
              requestId: item['requestId'] as String,
              verdict: item['verdict'] as String? ?? '',
              text: item['text'] as String? ?? '',
              question: item['question'] as String? ?? '',
            ),
    ];
  }
}

/// Answers from the launcher's details sheet (CON-082), over the same
/// channel: the native provider calls `launcherAction` with the action and
/// waits for `{ok, error}`; null means nobody can take it now (no
/// listener: the app is locked or not on its home page), and the native
/// side then holds it (contract 3): `consumeLauncherAnswers` takes the
/// held ones, `launcherAnswersAvailable` says one was held.
class PlatformLauncherActions implements LauncherActionSource {
  PlatformLauncherActions._();

  static final instance = PlatformLauncherActions._();

  Future<String?> Function(AgentPermissionAction action)? _listener;
  void Function()? _queuedListener;

  @override
  void setListener(
    Future<String?> Function(AgentPermissionAction action)? listener,
  ) {
    _listener = listener;
    PlatformAgentAttentionNotifier._installHandler();
  }

  @override
  void setQueuedListener(void Function()? listener) {
    _queuedListener = listener;
    PlatformAgentAttentionNotifier._installHandler();
  }

  @override
  Future<List<QueuedLauncherAnswer>> consumeQueued() async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return const [];
    }
    try {
      final raw = await PlatformAgentAttentionNotifier.channel
          .invokeMethod<List<Object?>>('consumeLauncherAnswers');
      return parseQueued(raw);
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      return const [];
    }
  }

  @visibleForTesting
  static List<QueuedLauncherAnswer> parseQueued(List<Object?>? raw) => [
    for (final item in raw ?? const <Object?>[])
      ?QueuedLauncherAnswer.fromMap(item),
  ];

  /// The channel call: [arguments] as the native side sends them.
  @visibleForTesting
  Future<Map<String, Object?>?> handle(Object? arguments) async {
    final listener = _listener;
    if (listener == null) {
      return null;
    }
    final action = parseAction(arguments);
    if (action == null) {
      return {'ok': false, 'error': 'Unknown action'};
    }
    final error = await listener(action);
    return {'ok': error == null, 'error': error};
  }

  @visibleForTesting
  static AgentPermissionAction? parseAction(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    String? text(String key) => raw[key] is String ? raw[key] as String : null;
    final hostId = text('hostId');
    final agentId = text('agentId');
    final requestId = text('requestId');
    final verdict = text('verdict');
    if (hostId == null ||
        hostId.isEmpty ||
        agentId == null ||
        agentId.isEmpty ||
        requestId == null ||
        verdict == null) {
      return null;
    }
    return AgentPermissionAction(
      notificationId: '',
      hostId: hostId,
      agentId: agentId,
      requestId: requestId,
      verdict: verdict,
      text: text('text') ?? '',
    );
  }
}

/// Notification body taps that should open an agent, from the Android
/// side of the same channel. The native side keeps the last tap (a cold
/// start included) until [consume] takes it.
class PlatformAgentOpenRequests implements AgentOpenRequestSource {
  PlatformAgentOpenRequests._();

  static final instance = PlatformAgentOpenRequests._();

  void Function()? _listener;

  @override
  void setListener(void Function()? listener) {
    _listener = listener;
    PlatformAgentAttentionNotifier._installHandler();
  }

  @override
  Future<AgentOpenTarget?> consume() async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return null;
    }
    try {
      final raw = await PlatformAgentAttentionNotifier.channel
          .invokeMethod<Object?>('consumeOpenAgent');
      return AgentOpenTarget.fromMap(raw);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}
