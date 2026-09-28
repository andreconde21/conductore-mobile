import 'package:conduit/core/presentation/terminal_route.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_launcher.dart';
import 'package:conduit/features/continuity/domain/continuity_record.dart';
import 'package:conduit/features/continuity/presentation/continuity_controller.dart';
import 'package:conduit/features/hosts/presentation/hosts_controller.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:flutter/widgets.dart';

/// The place [session] shows in the terminal, with its machine as this
/// device knows it; null for a phone's local shell, which no other device
/// can open. [herdrWorkspace] is the Herdr workspace it is on now, when
/// the app knows (a gesture may have moved it since it opened).
ContinuityPlace? placeForSession(
  TerminalSessionController session, {
  AgentAttentionController? attention,
  HostsController? hosts,
  String? herdrWorkspace,
}) {
  final host = session.host;
  if (host.isLocal) return null;
  final machineId = baseHostId(host.id);
  var target = ConnectTarget.fromSessionHostId(host.id);
  if (target != null &&
      target.kind == ConnectTargetKind.herdr &&
      herdrWorkspace != null &&
      herdrWorkspace.isNotEmpty &&
      herdrWorkspace != target.name) {
    target = ConnectTarget.herdr(
      workspaceId: herdrWorkspace,
      session: target.session,
    );
  }
  final agent = attention == null ? null : chatAgentForSession(attention, host);
  return ContinuityPlace(
    machineId: machineId,
    machineName: hosts?.findById(machineId)?.name ?? '',
    target: target?.kind == ConnectTargetKind.shell ? null : target,
    agentId: agent?.id,
    agentName: agent?.name ?? '',
    paneId: agent?.pane ?? '',
    title: session.title,
  );
}

/// The place of Chat View on [agentId] of monitored machine [hostId] (a
/// session host id, as the chat route and tab name it).
ContinuityPlace placeForChat({
  required String hostId,
  required String agentId,
  AgentAttentionController? attention,
  HostsController? hosts,
}) {
  final machineId = baseHostId(hostId);
  AgentInfo? agent;
  for (final candidate
      in attention?.statusFor(hostId)?.agents ?? const <AgentInfo>[]) {
    if (candidate.id == agentId) agent = candidate;
  }
  final workspace = agent?.workspace ?? '';
  return ContinuityPlace(
    machineId: machineId,
    machineName: hosts?.findById(machineId)?.name ?? '',
    view: ContinuityView.chat,
    // Where its terminal is, for opening that when the chat cannot.
    target: workspace.isEmpty
        ? null
        : ConnectTarget.herdr(workspaceId: workspace, tabId: agent?.tab ?? ''),
    agentId: agentId,
    agentName: agent?.name ?? '',
    paneId: agent?.pane ?? '',
  );
}

/// The place of the desktop shell's focused view [viewId]: a session
/// (`session:<host id>`) or a Chat View tab (`chat:<host id>:<agent>`);
/// null for other tabs (files, diffs, previews).
ContinuityPlace? placeForShellView(
  String viewId, {
  required TerminalWorkspaceController workspace,
  AgentAttentionController? attention,
  HostsController? hosts,
  String? Function(TerminalSessionController session)? herdrWorkspaceOf,
}) {
  if (viewId.startsWith('session:')) {
    final hostId = viewId.substring('session:'.length);
    final session = workspace.sessions
        .where((session) => session.host.id == hostId)
        .firstOrNull;
    if (session == null) return null;
    return placeForSession(
      session,
      attention: attention,
      hosts: hosts,
      herdrWorkspace: herdrWorkspaceOf?.call(session),
    );
  }
  if (viewId.startsWith('chat:')) {
    final rest = viewId.substring('chat:'.length);
    final split = rest.lastIndexOf(':');
    if (split <= 0 || split == rest.length - 1) return null;
    return placeForChat(
      hostId: rest.substring(0, split),
      agentId: rest.substring(split + 1),
      attention: attention,
      hosts: hosts,
    );
  }
  return null;
}

/// Follows the phone's routes and reports where the app is: Chat View
/// (its route names the machine and agent), the terminal (the active
/// session), or away (home, settings). The desktop shell reports its
/// focused view itself ([ContinuityController.desktopShell]).
class ContinuityRouteTracker extends NavigatorObserver {
  ContinuityRouteTracker({
    required this.continuity,
    required this.workspace,
    this.attention,
    this.hosts,
    this.herdrWorkspaceOf,
  }) {
    workspace.addListener(_schedule);
    attention?.addListener(_schedule);
  }

  final ContinuityController continuity;
  final TerminalWorkspaceController workspace;
  final AgentAttentionController? attention;
  final HostsController? hosts;
  final String? Function(TerminalSessionController session)? herdrWorkspaceOf;

  /// Page routes from the bottom; dialogs and sheets do not move the
  /// user anywhere.
  final List<Route<Object?>> _pages = [];
  bool _scheduled = false;

  @override
  void didPush(Route<Object?> route, Route<Object?>? previousRoute) {
    if (route is PageRoute) _pages.add(route);
    _schedule();
  }

  @override
  void didPop(Route<Object?> route, Route<Object?>? previousRoute) {
    _pages.remove(route);
    _schedule();
  }

  @override
  void didRemove(Route<Object?> route, Route<Object?>? previousRoute) {
    _pages.remove(route);
    _schedule();
  }

  @override
  void didReplace({Route<Object?>? newRoute, Route<Object?>? oldRoute}) {
    final index = oldRoute == null ? -1 : _pages.indexOf(oldRoute);
    if (index >= 0) {
      if (newRoute is PageRoute) {
        _pages[index] = newRoute;
      } else {
        _pages.removeAt(index);
      }
    } else if (newRoute is PageRoute) {
      _pages.add(newRoute);
    }
    _schedule();
  }

  void _schedule() {
    if (_scheduled) return;
    _scheduled = true;
    // After the frame: the route's page (and the workspace) settled.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      check();
    });
  }

  /// Reports what the top page shows.
  @visibleForTesting
  void check() {
    final top = _pages.lastOrNull;
    if (top == null || _pages.length == 1) {
      // Home: the desktop shell tells its own places.
      if (!continuity.desktopShell) continuity.reportAway();
      return;
    }
    if (chatRouteTarget(top) case (:final hostId, :final agentId)) {
      continuity.reportPlace(
        placeForChat(
          hostId: hostId,
          agentId: agentId,
          attention: attention,
          hosts: hosts,
        ),
      );
      return;
    }
    if (isTerminalRoute(top)) {
      final session = workspace.activeSession;
      final place = session == null
          ? null
          : placeForSession(
              session,
              attention: attention,
              hosts: hosts,
              herdrWorkspace: herdrWorkspaceOf?.call(session),
            );
      if (place != null) {
        continuity.reportPlace(place);
        return;
      }
    }
    if (!continuity.desktopShell) continuity.reportAway();
  }

  void dispose() {
    workspace.removeListener(_schedule);
    attention?.removeListener(_schedule);
  }
}
