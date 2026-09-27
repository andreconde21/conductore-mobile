import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/core/theme/theme_controller.dart';
import 'package:conduit/features/agent_attention/data/herdr_attention_provider.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/app_lock/presentation/app_lock_controller.dart';
import 'package:conduit/features/backup/data/app_backup_service.dart';
import 'package:conduit/features/hosts/presentation/hosts_controller.dart';
import 'package:conduit/features/local_shell/presentation/local_shell_controller.dart';
import 'package:conduit/features/terminal/presentation/host_key_prompt_coordinator.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:conduit/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/test_doubles.dart';

void main() {
  testWidgets('a setting that changes no colours does not rebuild the app '
      'themes', (tester) async {
    final verifier = NoopVerifier();
    final themeController = ThemeController(InMemoryThemePreferences());
    await themeController.load();
    final hostsController = HostsController(EmptyHostsRepository());
    await tester.pumpWidget(
      ConduitApp(
        lockController: AppLockController(AlwaysAuthenticates()),
        themeController: themeController,
        hostsController: hostsController,
        terminalRepository: NoNetworkTerminalRepository(),
        workspaceController: TerminalWorkspaceController(
          NoNetworkTerminalRepository(),
        ),
        localShellController: LocalShellController(),
        hostKeyVerifier: verifier,
        promptCoordinator: HostKeyPromptCoordinator(),
        sftpRepository: NoNetworkSftpRepository(),
        sftpBookmarksRepository: InMemorySftpBookmarks(),
        agentAttention: AgentAttentionController(
          workspace: TerminalWorkspaceController(NoNetworkTerminalRepository()),
          runnerFactory: (_) => throw StateError('no agent polling in tests'),
          provider: const HerdrAttentionProvider(),
        ),
        backupService: AppBackupService(
          hostsController: hostsController,
          themeController: themeController,
          hostKeyVerifier: verifier,
        ),
        fileExport: RecordingFileExport(),
      ),
    );
    await tester.pump();
    MaterialApp app() => tester.widget<MaterialApp>(find.byType(MaterialApp));
    final light = app().theme;
    final dark = app().darkTheme;

    await themeController.setRestoreSessionsOnLaunch(
      !themeController.restoreSessionsOnLaunch,
    );
    await tester.pump();
    expect(identical(app().theme, light), isTrue);
    expect(identical(app().darkTheme, dark), isTrue);

    final other = AppPalette.values.firstWhere(
      (palette) => palette != themeController.palette,
    );
    await themeController.setPalette(other);
    await tester.pump();
    expect(identical(app().theme, light), isFalse);
    expect(app().darkTheme!.colorScheme, isNot(dark!.colorScheme));
  });
}
