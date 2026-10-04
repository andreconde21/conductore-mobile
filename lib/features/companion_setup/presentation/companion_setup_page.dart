import 'dart:async';

import 'package:conduit/core/app_failure.dart';
import 'package:conduit/core/platform_features.dart';
import 'package:conduit/core/presentation/adaptive_page.dart';
import 'package:conduit/core/presentation/system_navigation_insets.dart';
import 'package:conduit/core/theme/app_theme.dart';
import 'package:conduit/features/companion_setup/domain/companion_status.dart';
import 'package:conduit/features/companion_setup/presentation/agent_setup_steps.dart';
import 'package:conduit/features/companion_setup/presentation/companion_install_sheet.dart';
import 'package:conduit/features/companion_setup/presentation/companion_setup_controller.dart';
import 'package:conduit/features/companion_setup/presentation/companion_status_chip.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Opens the Agent hooks screen for [host]. Uses the app-wide
/// [CompanionSetupScope] unless [controller] is given; does nothing when
/// neither exists (a build without companion support).
Future<void> showCompanionSetup(
  BuildContext context,
  SavedHost host, {
  CompanionSetupController? controller,
}) async {
  final resolved = controller ?? CompanionSetupScope.maybeOf(context);
  if (resolved == null) return;
  // A dialog over the shell on desktop, a full-screen page on phones.
  await pushAdaptivePage<void>(
    context,
    desktopMaxWidth: 760,
    builder: (_) => CompanionSetupPage(host: host, controller: resolved),
  );
}

/// Commands for installing the companion by hand from the git repository.
const companionManualInstallCommands = [
  'git clone https://github.com/andreconde21/conductore-mobile && cd conductore-mobile/host && '
      './install.sh',
  'conductore-hostd doctor',
];

/// What the Claude Code hooks documentation says about running sessions
/// (https://code.claude.com/docs/en/hooks, "Disable or remove hooks").
const companionHotReloadNote =
    'Claude Code\'s hooks documentation says direct edits to hooks in '
    'settings files are normally picked up automatically by its file '
    'watcher, so running sessions should start reporting without a '
    'restart. If one stays silent, restart that session (or check /hooks '
    'in it).';

/// Per-machine setup for the Conductore host companion ("Agent hooks"):
/// status, doctor checks, one-tap install/update/uninstall, a test event
/// and manual instructions.
class CompanionSetupPage extends StatefulWidget {
  const CompanionSetupPage({
    required this.host,
    required this.controller,
    super.key,
  });

  final SavedHost host;
  final CompanionSetupController controller;

  @override
  State<CompanionSetupPage> createState() => _CompanionSetupPageState();
}

class _CompanionSetupPageState extends State<CompanionSetupPage> {
  /// Label of the action in progress ("Installing…"), null when idle.
  String? _busy;
  final List<String> _log = [];
  CompanionTestEventResult? _testResult;
  String? _bundledVersion;

  CompanionSetupController get _controller => widget.controller;
  SavedHost get _host => widget.host;

  @override
  void initState() {
    super.initState();
    // After the frame: a re-check notifies listeners that may be building.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _controller.ensureChecked(_host);
    });
    unawaited(
      _controller.bundledVersion().then((version) {
        if (mounted) setState(() => _bundledVersion = version);
      }, onError: (Object _) {}),
    );
  }

  Future<void> _guard(String label, Future<void> Function() action) async {
    if (_busy != null) return;
    setState(() => _busy = label);
    try {
      await action();
    } catch (error) {
      final text = error is AppFailure ? error.userMessage : '$error';
      if (mounted) setState(() => _log.add(text));
      _snack(text);
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _install({required bool update}) async {
    final version = _bundledVersion ?? await _controller.bundledVersion();
    if (!mounted) return;
    final confirmed = await showCompanionInstallConfirmation(
      context,
      hostName: _host.name,
      version: version,
      update: update,
    );
    if (!confirmed || !mounted) return;
    await _guard(update ? 'Updating…' : 'Installing…', () async {
      setState(() {
        _log.clear();
        _testResult = null;
      });
      final outcome = await _controller.install(
        _host,
        onLog: (line) {
          if (mounted) setState(() => _log.add(line));
        },
      );
      _snack(
        outcome.ok
            ? 'Agent hooks installed on ${_host.name}.'
            : 'Install failed; see the log below.',
      );
    });
  }

  Future<void> _uninstall() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Uninstall agent hooks?'),
        content: const Text(
          'Removes the Conductore hook entries from ~/.claude/settings.json '
          '(other hooks stay), stops the daemon, and deletes '
          '~/.local/share/conductore and the ~/.local/bin links. The phone '
          'stops getting approvals and chat from this machine.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('companion-uninstall-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Uninstall'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _guard('Uninstalling…', () async {
      setState(() {
        _log.clear();
        _testResult = null;
      });
      final outcome = await _controller.uninstall(
        _host,
        onLog: (line) {
          if (mounted) setState(() => _log.add(line));
        },
      );
      _snack(
        outcome.ok ? 'Agent hooks removed.' : 'Uninstall failed; see the log.',
      );
    });
  }

  Future<void> _stopDaemon() => _guard('Stopping…', () async {
    final wasRunning = await _controller.stopDaemon(_host);
    _snack(wasRunning ? 'Daemon stopped.' : 'The daemon was not running.');
  });

  Future<void> _sendTestEvent() => _guard('Sending…', () async {
    final result = await _controller.sendTestEvent(_host);
    if (mounted) setState(() => _testResult = result);
  });

  Future<void> _refresh() => _guard('Checking…', () async {
    await _controller.refresh(_host);
  });

  @override
  Widget build(BuildContext context) {
    final bottomInset = shouldApplyBottomSafeArea(context)
        ? MediaQuery.viewPaddingOf(context).bottom
        : 0.0;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Agent hooks'),
            Text(
              _host.name,
              style: Theme.of(context).textTheme.bodySmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Check again',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _busy == null ? _refresh : null,
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: _controller,
        builder: (context, _) {
          final status = _controller.statusFor(_host);
          final checking = _controller.isChecking(_host);
          final attention = CompanionSetupScope.agentAttentionOf(context);
          return ListView(
            key: const ValueKey('companion-setup-list'),
            padding: EdgeInsets.fromLTRB(16, 8, 16, 24 + bottomInset),
            children: [
              _StatusCard(
                status: status,
                checking: checking,
                bundledVersion: _bundledVersion,
              ),
              if (status != null &&
                  status.state.isWorking &&
                  attention != null &&
                  !attention.monitoringEnabled(_host))
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: MaterialBanner(
                    key: const ValueKey('companion-monitoring-off'),
                    leading: const Icon(Icons.monitor_heart_outlined),
                    content: const Text(
                      'Agent monitoring is off for this machine, so its '
                      'approvals and sessions do not reach the phone.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () async {
                          await attention.enableMonitoring(_host);
                          if (mounted) setState(() {});
                        },
                        child: const Text('Turn on'),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 12),
              if (_busy != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Row(
                    children: [
                      const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 10),
                      Text(_busy!),
                    ],
                  ),
                ),
              if (status != null) ..._actions(status),
              if (status != null) ...agentSetupSteps(status.checks),
              if (_testResult != null) _TestResultCard(result: _testResult!),
              if (_log.isNotEmpty) _LogCard(lines: _log),
              if (status != null && status.checks.isNotEmpty)
                _ChecksSection(checks: status.checks),
              const SizedBox(height: 8),
              const _ManualInstructions(),
            ],
          );
        },
      ),
    );
  }

  List<Widget> _actions(CompanionStatus status) {
    final idle = _busy == null;
    final installed = status.installedVersion != null;
    final bundled = _bundledVersion;
    final updateAvailable =
        bundled != null &&
        status.installedVersion != null &&
        compareCompanionVersions(bundled, status.installedVersion!) > 0;

    final primary = switch (status.state) {
      CompanionState.notInstalled => FilledButton.icon(
        key: const ValueKey('companion-install'),
        onPressed: idle ? () => _install(update: false) : null,
        icon: const Icon(Icons.download_rounded),
        label: const Text('Install agent hooks'),
      ),
      CompanionState.hooksMissing => FilledButton.icon(
        key: const ValueKey('companion-install'),
        onPressed: idle ? () => _install(update: false) : null,
        icon: const Icon(Icons.link_rounded),
        label: const Text('Reinstall and register hooks'),
      ),
      CompanionState.outdated => FilledButton.icon(
        key: const ValueKey('companion-install'),
        onPressed: idle ? () => _install(update: true) : null,
        icon: const Icon(Icons.upgrade_rounded),
        label: Text('Update to ${bundled ?? 'the bundled version'}'),
      ),
      CompanionState.active ||
      CompanionState.waitingForFirstEvent => FilledButton.icon(
        key: const ValueKey('companion-test-event'),
        onPressed: idle ? _sendTestEvent : null,
        icon: const Icon(Icons.send_rounded),
        label: const Text('Send test event'),
      ),
      CompanionState.error => FilledButton.icon(
        onPressed: idle ? _refresh : null,
        icon: const Icon(Icons.refresh_rounded),
        label: const Text('Check again'),
      ),
    };

    final secondary = <Widget>[
      if (status.state.isWorking)
        OutlinedButton.icon(
          key: const ValueKey('companion-reinstall'),
          onPressed: idle ? () => _install(update: updateAvailable) : null,
          icon: Icon(
            updateAvailable ? Icons.upgrade_rounded : Icons.replay_rounded,
          ),
          label: Text(updateAvailable ? 'Update to $bundled' : 'Reinstall'),
        ),
      if (status.state == CompanionState.error)
        OutlinedButton.icon(
          key: const ValueKey('companion-install'),
          onPressed: idle ? () => _install(update: false) : null,
          icon: const Icon(Icons.download_rounded),
          label: const Text('Install anyway'),
        ),
      if (installed && status.daemonRunning)
        OutlinedButton.icon(
          key: const ValueKey('companion-stop'),
          onPressed: idle ? _stopDaemon : null,
          icon: const Icon(Icons.stop_circle_outlined),
          label: const Text('Stop daemon'),
        ),
      if (installed)
        OutlinedButton.icon(
          key: const ValueKey('companion-uninstall'),
          onPressed: idle ? _uninstall : null,
          icon: const Icon(Icons.delete_outline_rounded),
          label: const Text('Uninstall'),
        ),
    ];

    return [
      // Full width on phones; a normal-sized button on desktop.
      if (PlatformFeatures.isDesktop)
        Align(alignment: Alignment.centerLeft, child: primary)
      else
        SizedBox(width: double.infinity, child: primary),
      if (!status.nodeSupported && status.state.needsInstall)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            status.nodeFound
                ? 'Node.js ${status.nodeVersion} is too old; the companion '
                      'needs $kCompanionMinNodeMajor or newer.'
                : 'Node.js was not found on the SSH PATH. Install Node.js '
                      '$kCompanionMinNodeMajor+ first, or the installer will '
                      'stop.',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      if (secondary.isNotEmpty) ...[
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 4, children: secondary),
      ],
      const SizedBox(height: 12),
    ];
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.status,
    required this.checking,
    required this.bundledVersion,
  });

  final CompanionStatus? status;
  final bool checking;
  final String? bundledVersion;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = this.status;
    final (color, icon) = companionStateVisual(context, status?.state);
    final label = status?.state.label ?? 'Checking…';
    return Card(
      key: const ValueKey('companion-status-card'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Flexible(
                  child: DecoratedBox(
                    key: const ValueKey('companion-status-badge'),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(AppTheme.radius),
                      border: Border.all(color: color.withValues(alpha: 0.6)),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(icon, size: 16, color: color),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelLarge?.copyWith(
                                color: color,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                if (checking && status != null)
                  const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            if (status == null)
              const LinearProgressIndicator()
            else ...[
              if (status.message != null) Text(status.message!),
              if (status.errorDetail != null &&
                  status.errorDetail!.isNotEmpty) ...[
                const SizedBox(height: 8),
                SelectableText(
                  status.errorDetail!,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
              const SizedBox(height: 10),
              ..._details(status),
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _details(CompanionStatus status) {
    final rows = <(String, String)>[
      if (status.installedVersion != null)
        (
          'Companion',
          '${status.installedVersion} (protocol ${status.installedProtocol})',
        ),
      if (bundledVersion != null) ('In this app', bundledVersion!),
      (
        'Node.js',
        !status.nodeFound
            ? 'not found (needs $kCompanionMinNodeMajor+)'
            : status.nodeSupported
            ? status.nodeVersion!
            : '${status.nodeVersion} (needs $kCompanionMinNodeMajor+)',
      ),
      ('Claude Code', status.claudeVersion ?? 'not found on the SSH PATH'),
      if (status.user != null) ('User', status.user!),
      if (status.installedVersion != null)
        ('Daemon', status.daemonRunning ? 'running' : 'not running'),
      if (status.lastEventAt != null)
        ('Last event', _ago(status.lastEventAt!, status.checkedAt)),
      if (status.everSawEvent)
        (
          'Agents',
          '${status.liveAgentCount} live, ${status.agentCount} reported',
        ),
    ];
    return [for (final (k, v) in rows) _DetailRow(label: k, value: v)];
  }
}

String _ago(DateTime at, DateTime now) {
  final d = now.difference(at);
  if (d.inSeconds < 60) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 48) return '${d.inHours} h ago';
  return '${d.inDays} days ago';
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 104,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: Text(value, style: theme.textTheme.bodySmall)),
        ],
      ),
    );
  }
}

class _ChecksSection extends StatelessWidget {
  const _ChecksSection({required this.checks});

  final List<CompanionDoctorCheck> checks;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (green, _) = companionStateVisual(context, CompanionState.active);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Doctor checks', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            for (final check in checks)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      check.ok
                          ? Icons.check_circle_rounded
                          : check.optional
                          ? Icons.remove_circle_outline_rounded
                          : Icons.cancel_rounded,
                      size: 18,
                      color: check.ok
                          ? green
                          : check.optional
                          ? theme.colorScheme.onSurfaceVariant
                          : theme.colorScheme.error,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            check.optional
                                ? '${check.name} (optional)'
                                : check.name,
                          ),
                          if (check.detail.isNotEmpty)
                            Text(
                              check.detail,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _TestResultCard extends StatelessWidget {
  const _TestResultCard({required this.result});

  final CompanionTestEventResult result;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (green, _) = companionStateVisual(context, CompanionState.active);
    return Card(
      key: const ValueKey('companion-test-result'),
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: Icon(
          result.ok ? Icons.check_circle_rounded : Icons.error_outline_rounded,
          color: result.ok ? green : scheme.error,
        ),
        title: Text(result.ok ? 'Test event received' : 'Test event failed'),
        subtitle: Text(result.message),
      ),
    );
  }
}

class _LogCard extends StatelessWidget {
  const _LogCard({required this.lines});

  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      key: const ValueKey('companion-log'),
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: SelectableText(
          lines.join('\n'),
          style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
        ),
      ),
    );
  }
}

class _ManualInstructions extends StatelessWidget {
  const _ManualInstructions();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        key: const ValueKey('companion-manual'),
        leading: const Icon(Icons.terminal_rounded),
        title: const Text('Install manually'),
        subtitle: const Text('From the git repository, in a shell'),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'On the machine, as the user that runs your coding agents '
            '(needs Node.js 18+ and git):',
          ),
          const SizedBox(height: 8),
          for (final command in companionManualInstallCommands)
            _CopyableCommand(command: command),
          const SizedBox(height: 8),
          Text(
            'To remove it later: Conduit/host/install.sh --uninstall',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          Text(companionHotReloadNote, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _CopyableCommand extends StatelessWidget {
  const _CopyableCommand({required this.command});

  final String command;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Material(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppTheme.radius),
        child: Row(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
                child: SelectableText(
                  command,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ),
            IconButton(
              tooltip: 'Copy',
              icon: const Icon(Icons.copy_rounded, size: 18),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: command));
                if (!context.mounted) return;
                ScaffoldMessenger.of(context)
                  ..hideCurrentSnackBar()
                  ..showSnackBar(
                    const SnackBar(content: Text('Command copied')),
                  );
              },
            ),
          ],
        ),
      ),
    );
  }
}
