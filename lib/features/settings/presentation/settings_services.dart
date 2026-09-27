import 'package:conduit/core/theme/theme_controller.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/agents_digest/presentation/digest_controller.dart';
import 'package:conduit/features/app_lock/presentation/app_lock_controller.dart';
import 'package:conduit/features/backup/data/app_backup_service.dart';
import 'package:conduit/features/hosts/presentation/hosts_controller.dart';
import 'package:conduit/features/terminal/domain/host_key_verifier.dart';
import 'package:flutter/widgets.dart';

/// What the Settings page edits and opens. [theme] (ThemeController and
/// its ThemePreferencesRepository) stays the source of truth for every
/// app preference; the rest are optional so a page that lacks one (the
/// terminal in a test) still opens Settings with those items hidden.
@immutable
class SettingsServices {
  const SettingsServices({
    required this.theme,
    this.backupService,
    this.hostsController,
    this.hostKeyVerifier,
    this.agentAttention,
    this.digest,
    this.appLock,
    this.onLockNow,
    this.hasSync = false,
    this.hasSessionViews = false,
  });

  final ThemeController theme;
  final AppBackupService? backupService;

  /// Machines, for the per-machine agent hooks and notification levels.
  final HostsController? hostsController;

  /// Trusted host keys (Security).
  final HostKeyVerifier? hostKeyVerifier;

  /// Agents' usage (Agents).
  final AgentAttentionController? agentAttention;

  /// The agents dashboard's settings (Agents › Dashboard).
  final DigestController? digest;

  /// The app lock, for when it locks again; null where there is none.
  final AppLockController? appLock;

  /// Locks the app now (closing sessions first); null hides "Lock now".
  final Future<void> Function()? onLockNow;

  /// Whether a SyncScope is above the page (device sync is available).
  final bool hasSync;

  /// Whether a SessionViewScope is above the page.
  final bool hasSessionViews;

  SettingsServices copyWith({
    bool? hasSync,
    bool? hasSessionViews,
    Future<void> Function()? onLockNow,
  }) => SettingsServices(
    theme: theme,
    backupService: backupService,
    hostsController: hostsController,
    hostKeyVerifier: hostKeyVerifier,
    agentAttention: agentAttention,
    digest: digest,
    appLock: appLock,
    onLockNow: onLockNow ?? this.onLockNow,
    hasSync: hasSync ?? this.hasSync,
    hasSessionViews: hasSessionViews ?? this.hasSessionViews,
  );
}

/// Makes [SettingsServices] reachable from every route (the terminal's ⋮
/// menu opens Settings without holding each service itself).
class SettingsScope extends InheritedWidget {
  const SettingsScope({
    required this.services,
    required super.child,
    super.key,
  });

  final SettingsServices services;

  static SettingsServices? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<SettingsScope>()?.services;

  @override
  bool updateShouldNotify(SettingsScope oldWidget) =>
      services != oldWidget.services;
}
