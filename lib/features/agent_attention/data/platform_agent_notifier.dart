import 'package:conduit/features/agent_attention/domain/agent_attention_notifier.dart';
import 'package:conduit/features/agent_attention/domain/agent_notifications.dart';
import 'package:conduit/features/agent_attention/domain/agent_permission_actions.dart';
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
      }
      return null;
    });
  }

  static bool _handlerInstalled = false;

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

/// Receives Allow / Deny / Always taps from the Android notification
/// actions over the same channel. The native side queues each tap in
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
            ),
    ];
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
