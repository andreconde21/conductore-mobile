import 'package:conduit/features/agent_attention/data/conductore_host_attention_provider.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_page.dart';
import 'package:conduit/features/desktop_shell/domain/sidebar_tree.dart';
import 'package:conduit/features/desktop_shell/presentation/desktop_home.dart';
import 'package:conduit/features/session_navigation/domain/session_view_preferences.dart';
import 'package:conduit/features/session_navigation/presentation/session_view_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

import '../../support/test_doubles.dart';
import 'shell_harness.dart';

class _NoopWakelock extends WakelockPlusPlatformInterface {
  @override
  Future<void> toggle({required bool enable}) async {}

  @override
  Future<bool> get enabled async => false;
}

/// "Open Claude sessions in: Chat View" in the desktop shell: a sidebar
/// workspace that was not open connects, then its Claude session opens as
/// a Chat View tab, not a pushed route.
void main() {
  // The terminal toggles the wakelock; runAsync below would reach the
  // real (absent) platform channel.
  WakelockPlusPlatformInterface.instance = _NoopWakelock();

  AgentCommandResult ok(String stdout) =>
      AgentCommandResult(stdout: stdout, stderr: '', exitCode: 0);

  const status =
      '{"version":1,"seq":2,"agents":['
      '{"sessionId":"infra","name":"infra","cwd":"/w/infra",'
      '"state":"working","kind":"claude","pending":[],'
      '"herdr":{"workspaceId":"w1","tabId":"w1:t1","paneId":"w1:p1"}},'
      '{"sessionId":"calendar","name":"calendar","cwd":"/w/calendar",'
      '"state":"working","kind":"claude","pending":[],'
      '"herdr":{"workspaceId":"w2","tabId":"w2:t1","paneId":"w2:p1"}}]}';

  testWidgets('a sidebar workspace opens its Claude session as a Chat View '
      'tab', (tester) async {
    late AgentAttentionController attention;
    final h = await pumpShell(
      tester,
      before: (h) {
        attention = AgentAttentionController(
          workspace: h.workspace,
          runnerFactory: (_) => ScriptedAgentCommandRunner([ok(status)]),
          provider: const ConductoreHostAttentionProvider(),
          pollInterval: const Duration(days: 1),
        )..setAppForeground(false);
        h.attention = attention;
        h.sessionViews = SessionViewController(
          InMemorySessionViewPreferencesRepository(
            const SessionViewPreferences(defaultView: SessionView.chat),
          ),
        );
        addTearDown(h.sessionViews!.dispose);
      },
    );
    await h.sessionViews!.load();
    await attention.enableMonitoring(workstation);

    await tester.tap(
      find.byKey(
        ValueKey(
          'sidebar-row-machines-'
          '${SidebarKeys.herdrWorkspace('workstation', 'w2')}',
        ),
      ),
    );
    for (var i = 0; i < 3; i += 1) {
      await tester.runAsync(pumpEventQueue);
      await settleShell(tester);
    }

    final session = h.workspace.activeSession!;
    expect(session.host.id, startsWith('workstation#herdr:w2'));
    expect(
      find.byKey(ValueKey('shell-tab-chat:${session.host.id}:calendar')),
      findsOneWidget,
    );
    expect(find.byType(ChatViewPage), findsOneWidget);
    // A tab in the shell, not a route over it.
    expect(find.byType(DesktopHome), findsOneWidget);
    expect(
      tester.state<NavigatorState>(find.byType(Navigator).first).canPop(),
      isFalse,
    );

    await tester.pumpWidget(const SizedBox());
    attention.dispose();
    await tearDownShell(tester);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
}
