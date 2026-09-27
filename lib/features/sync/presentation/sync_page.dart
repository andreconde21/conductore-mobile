import 'dart:async';

import 'package:conduit/core/app_failure.dart';
import 'package:conduit/core/platform_features.dart';
import 'package:conduit/core/presentation/adaptive_page.dart';
import 'package:conduit/core/presentation/system_navigation_insets.dart';
import 'package:conduit/features/backup/data/app_backup_service.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/sync/data/sync_crypto.dart';
import 'package:conduit/features/sync/data/sync_setup.dart';
import 'package:conduit/features/sync/domain/local_sync_store.dart';
import 'package:conduit/features/sync/domain/sync_category.dart';
import 'package:conduit/features/sync/domain/sync_config.dart';
import 'package:conduit/features/sync/presentation/sync_controller.dart';
import 'package:conduit/features/sync/presentation/widgets/qr_code_view.dart';
import 'package:conduit/features/sync/presentation/widgets/setup_code_scanner.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Settings › Sync: set up or join, what syncs, devices, activity.
class SyncPage extends StatefulWidget {
  const SyncPage({required this.controller, super.key});

  final SyncController controller;

  @override
  State<SyncPage> createState() => _SyncPageState();
}

class _SyncPageState extends State<SyncPage> {
  String? _busy;

  SyncController get _sync => widget.controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshDevices());
  }

  Future<void> _refreshDevices() async {
    if (!_sync.enabled) return;
    try {
      await _sync.refreshDevices();
    } catch (_) {
      // The list stays as it was; the status card shows sync errors.
    }
  }

  Future<void> _guard(String label, Future<void> Function() action) async {
    if (_busy != null) return;
    setState(() => _busy = label);
    try {
      await action();
    } catch (error) {
      _snack(describeSyncError(error));
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

  @override
  Widget build(BuildContext context) {
    final bottomInset = shouldApplyBottomSafeArea(context)
        ? MediaQuery.viewPaddingOf(context).bottom
        : 0.0;
    return Scaffold(
      appBar: AppBar(title: const Text('Sync')),
      body: ListenableBuilder(
        listenable: _sync.changes,
        builder: (context, _) {
          final children = _sync.enabled ? _enabledChildren() : _offChildren();
          return ListView(
            key: const ValueKey('sync-page-list'),
            padding: EdgeInsets.fromLTRB(16, 8, 16, 24 + bottomInset),
            children: [
              if (_busy != null) ...[
                LinearProgressIndicator(semanticsLabel: _busy),
                const SizedBox(height: 8),
              ],
              ...children,
            ],
          );
        },
      ),
    );
  }

  // Off.

  List<Widget> _offChildren() {
    final theme = Theme.of(context);
    return [
      const _Explainer(),
      const SizedBox(height: 16),
      FilledButton.icon(
        key: const ValueKey('sync-set-up'),
        icon: const Icon(Icons.dns_rounded),
        label: const Text('Set up sync with one of my machines'),
        onPressed: _busy != null || _sync.machines.isEmpty ? null : _setUp,
      ),
      if (_sync.machines.isEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            'Save a machine first, or join with a setup code.',
            style: theme.textTheme.bodySmall,
          ),
        ),
      const SizedBox(height: 10),
      OutlinedButton.icon(
        key: const ValueKey('sync-join'),
        icon: const Icon(Icons.qr_code_scanner_rounded),
        label: const Text('Join with a setup code'),
        onPressed: _busy != null ? null : _join,
      ),
      if (_sync.activity.isNotEmpty) ...[
        const SizedBox(height: 24),
        const _SectionTitle('Sync activity'),
        for (final entry in _sync.activity.take(5)) _ActivityTile(entry: entry),
      ],
    ];
  }

  Future<void> _setUp() async {
    final done = await pushAdaptivePage<bool>(
      context,
      desktopMaxWidth: 640,
      builder: (_) => _SetUpPage(controller: _sync),
    );
    if (done == true) {
      _snack('Sync is on.');
      unawaited(_refreshDevices());
    }
  }

  Future<void> _join() async {
    final done = await pushAdaptivePage<bool>(
      context,
      desktopMaxWidth: 640,
      builder: (_) => _JoinPage(controller: _sync),
    );
    if (done == true) {
      _snack('This device joined sync.');
      unawaited(_refreshDevices());
    }
  }

  // On.

  List<Widget> _enabledChildren() {
    final config = _sync.config!;
    return [
      _StatusCard(
        controller: _sync,
        onSyncNow: _busy != null
            ? null
            : () => _guard('Syncing…', () async {
                await _sync.syncNow();
                await _refreshDevices();
              }),
      ),
      const SizedBox(height: 8),
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.smartphone_rounded),
        title: const Text('This device'),
        subtitle: Text(config.deviceName),
        trailing: const Icon(Icons.edit_rounded),
        onTap: _rename,
      ),
      const SizedBox(height: 8),
      const _SectionTitle('What to sync'),
      for (final category in SyncCategory.values)
        SwitchListTile(
          key: ValueKey('sync-category-${category.name}'),
          contentPadding: EdgeInsets.zero,
          title: Text(category.label),
          subtitle: Text(category.description),
          value: config.categories.contains(category),
          onChanged: _busy != null ? null : (on) => _setCategory(category, on),
        ),
      const SizedBox(height: 16),
      _SectionTitle(
        'Devices',
        trailing: IconButton(
          tooltip: 'Refresh devices',
          icon: const Icon(Icons.refresh_rounded),
          onPressed: _busy != null
              ? null
              : () => _guard('Reading devices…', _sync.refreshDevices),
        ),
      ),
      if (_sync.devices.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Text('Tap refresh to read the device list from the hub.'),
        ),
      for (final device in _sync.devices)
        _DeviceTile(
          device: device,
          onRemove: device.isThisDevice || _busy != null
              ? null
              : () => _removeDevice(device),
        ),
      const SizedBox(height: 8),
      FilledButton.tonalIcon(
        key: const ValueKey('sync-add-device'),
        icon: const Icon(Icons.qr_code_2_rounded),
        label: const Text('Add a device'),
        onPressed: _busy != null ? null : _addDevice,
      ),
      const SizedBox(height: 24),
      const _SectionTitle('Sync activity'),
      if (_sync.activity.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Text('Nothing yet.'),
        ),
      for (final entry in _sync.activity)
        _ActivityTile(
          entry: entry,
          onKeepMine: entry.canRestore && _busy == null
              ? () => _guard('Restoring…', () => _sync.keepMine(entry))
              : null,
        ),
      const SizedBox(height: 24),
      OutlinedButton.icon(
        key: const ValueKey('sync-turn-off'),
        icon: const Icon(Icons.sync_disabled_rounded),
        label: const Text('Turn off sync'),
        onPressed: _busy != null ? null : _turnOff,
      ),
    ];
  }

  Future<void> _rename() async {
    final name = await _askText(
      title: 'Device name',
      initial: _sync.config?.deviceName ?? '',
      label: 'Shown in the device list of your other devices',
    );
    if (name == null) return;
    await _sync.setDeviceName(name);
  }

  Future<void> _setCategory(SyncCategory category, bool on) async {
    if (category == SyncCategory.credentials && on) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          icon: const Icon(Icons.warning_amber_rounded),
          title: const Text('Sync SSH keys and passwords?'),
          content: const Text(
            'Private keys, their passphrases, saved passwords and hidden '
            'snippets will be copied to every device in this sync group. '
            'They are encrypted with your sync passphrase before they '
            'leave this device, but anyone with that passphrase and access '
            'to the hub can read them.\n\n'
            'Hardware-key stubs never sync, and each device keeps its own '
            'login to the hub. A separate key per device is safer: you can '
            'revoke one lost device without replacing keys everywhere.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: const ValueKey('sync-credentials-confirm'),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Sync them'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    await _sync.setCategory(category, on);
  }

  Future<void> _removeDevice(SyncDeviceView device) async {
    final hub = _sync.hubHost;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove "${device.name}"?'),
        content: Text(
          device.publicKey != null
              ? 'Its SSH key is removed from ${hub?.name ?? 'the hub'}\'s '
                    'authorized_keys, so it can no longer reach the hub. '
                    'Data already on that device stays there.'
              : 'It is dropped from the device list and stops syncing the '
                    'next time it connects. Data already on that device '
                    'stays there.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _guard('Removing…', () => _sync.removeDevice(device));
  }

  Future<void> _addDevice() async {
    await pushAdaptivePage<void>(
      context,
      desktopMaxWidth: 640,
      builder: (_) => _AddDevicePage(controller: _sync),
    );
    unawaited(_refreshDevices());
  }

  Future<void> _turnOff() async {
    var deleteHubData = false;
    final hubName = _sync.hubHost?.name ?? 'the hub';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Turn off sync?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Everything already on this device stays. It stops '
                'sending and receiving changes.',
              ),
              const SizedBox(height: 8),
              CheckboxListTile(
                key: const ValueKey('sync-delete-hub-data'),
                contentPadding: EdgeInsets.zero,
                value: deleteHubData,
                onChanged: (value) =>
                    setState(() => deleteHubData = value ?? false),
                title: Text('Also delete the sync data on $hubName'),
                subtitle: const Text('Other devices then stop syncing too.'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: const ValueKey('sync-turn-off-confirm'),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Turn off'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) return;
    await _guard(
      'Turning off…',
      () => _sync.turnOff(deleteHubData: deleteHubData),
    );
  }

  Future<String?> _askText({
    required String title,
    required String initial,
    required String label,
  }) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(helperText: label),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    ).whenComplete(controller.dispose);
  }
}

/// A user-facing sentence for sync errors.
String describeSyncError(Object error) {
  if (error is AppFailure) return error.userMessage;
  if (error is SyncSetupException) return error.message;
  if (error is SyncCryptoException) return error.message;
  if (error is LocalSyncUnavailable) return error.message;
  if (error is StateError) return error.message;
  return '$error';
}

class _Explainer extends StatelessWidget {
  const _Explainer();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Sync through your own machine',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            const Text(
              'Keep saved machines, snippets, settings and the session list '
              'the same on your phone, tablet and desktop. One of your '
              'saved machines is the hub: the app stores one encrypted file '
              'in ~/.conductore/sync there, over the SSH connection it '
              'already uses. No cloud service, no new port, nothing to '
              'install.',
            ),
            const SizedBox(height: 8),
            Text(
              'Everything is encrypted on this device with your sync '
              'passphrase before it is uploaded, so the hub cannot read it. '
              'SSH keys and passwords only sync if you turn that on.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text, {this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            text,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
        ?trailing,
      ],
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.controller, required this.onSyncNow});

  final SyncController controller;
  final VoidCallback? onSyncNow;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final config = controller.config!;
    final hub = controller.hubHost;
    final error = controller.error;
    final (icon, line) = switch (controller.status) {
      SyncStatus.syncing => (Icons.sync_rounded, 'Syncing…'),
      SyncStatus.error => (Icons.sync_problem_rounded, error ?? 'Sync failed.'),
      _ => (
        Icons.cloud_done_rounded,
        config.lastSyncAt == null
            ? 'Not synced yet.'
            : 'Last synced ${describeSyncTime(config.lastSyncAt!)}.',
      ),
    };
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  icon,
                  color: controller.status == SyncStatus.error
                      ? theme.colorScheme.error
                      : theme.colorScheme.primary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Hub: ${hub?.name ?? 'missing machine'}',
                        style: theme.textTheme.titleMedium,
                      ),
                      if (hub != null)
                        Text(hub.endpoint, style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(line, key: const ValueKey('sync-status-line')),
            const SizedBox(height: 10),
            FilledButton.icon(
              key: const ValueKey('sync-now'),
              icon: const Icon(Icons.sync_rounded),
              label: const Text('Sync now'),
              onPressed: controller.syncing ? null : onSyncNow,
            ),
          ],
        ),
      ),
    );
  }
}

/// "just now", "5 min ago", "yesterday 14:03"…
String describeSyncTime(DateTime time, {DateTime? now}) {
  final current = now ?? DateTime.now();
  final local = time.toLocal();
  final age = current.difference(local);
  if (age.inSeconds < 60) return 'just now';
  if (age.inMinutes < 60) return '${age.inMinutes} min ago';
  final hh = local.hour.toString().padLeft(2, '0');
  final mm = local.minute.toString().padLeft(2, '0');
  if (age.inHours < 24 && local.day == current.day) return 'today $hh:$mm';
  return '${local.year}-${local.month.toString().padLeft(2, '0')}-'
      '${local.day.toString().padLeft(2, '0')} $hh:$mm';
}

class _DeviceTile extends StatelessWidget {
  const _DeviceTile({required this.device, required this.onRemove});

  final SyncDeviceView device;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final details = [
      if (device.isThisDevice) 'This device',
      if (device.platform.isNotEmpty) device.platform,
      if (device.pairedOnly)
        'Key added, not synced yet'
      else if (device.lastSeen != null)
        'Last sync ${describeSyncTime(device.lastSeen!)}',
    ];
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        device.isThisDevice
            ? Icons.smartphone_rounded
            : Icons.devices_other_rounded,
      ),
      title: Text(device.name),
      subtitle: Text(details.join(' · ')),
      trailing: onRemove == null
          ? null
          : IconButton(
              tooltip: 'Remove ${device.name}',
              icon: const Icon(Icons.person_remove_rounded),
              onPressed: onRemove,
            ),
    );
  }
}

class _ActivityTile extends StatelessWidget {
  const _ActivityTile({required this.entry, this.onKeepMine});

  final SyncActivityEntry entry;
  final VoidCallback? onKeepMine;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final icon = switch (entry.kind) {
      SyncActivityKind.synced => Icons.sync_rounded,
      SyncActivityKind.conflict => Icons.call_split_rounded,
      SyncActivityKind.error => Icons.error_outline_rounded,
      SyncActivityKind.info => Icons.info_outline_rounded,
    };
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: Icon(
        icon,
        color: entry.kind == SyncActivityKind.error
            ? theme.colorScheme.error
            : null,
      ),
      title: Text(entry.message),
      subtitle: Text(describeSyncTime(entry.at)),
      trailing: onKeepMine == null
          ? null
          : TextButton(onPressed: onKeepMine, child: const Text('Keep mine')),
    );
  }
}

/// Picks the hub and the passphrase, then creates or joins the hub's data.
class _SetUpPage extends StatefulWidget {
  const _SetUpPage({required this.controller});

  final SyncController controller;

  @override
  State<_SetUpPage> createState() => _SetUpPageState();
}

class _SetUpPageState extends State<_SetUpPage> {
  final _name = TextEditingController();
  final _passphrase = TextEditingController();
  final _confirm = TextEditingController();
  SavedHost? _hub;

  /// Null until the hub was checked; then whether it holds sync data.
  bool? _hubHasData;
  bool _busy = false;
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _passphrase.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    final hub = _hub;
    if (hub == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final hasData = await widget.controller.hubHasSyncData(hub);
      if (mounted) setState(() => _hubHasData = hasData);
    } catch (error) {
      if (mounted) setState(() => _error = describeSyncError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit() async {
    final hub = _hub;
    if (hub == null) return;
    final passphrase = _passphrase.text;
    if (_hubHasData == false) {
      final problem = AppBackupPasswordPolicy.validate(passphrase);
      if (problem != null) {
        setState(() => _error = problem);
        return;
      }
      if (passphrase != _confirm.text) {
        setState(() => _error = 'The passphrases do not match.');
        return;
      }
    } else if (passphrase.isEmpty) {
      setState(() => _error = 'Enter the sync passphrase.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.controller.setUp(
        hub: hub,
        passphrase: passphrase,
        deviceName: _name.text,
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted) setState(() => _error = describeSyncError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final machines = widget.controller.machines;
    return Scaffold(
      appBar: AppBar(title: const Text('Set up sync')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          DropdownButtonFormField<SavedHost>(
            key: const ValueKey('sync-hub-picker'),
            initialValue: _hub,
            decoration: const InputDecoration(
              labelText: 'Hub machine',
              helperText:
                  'A machine you can reach from every device. Its sync '
                  'data lives in ~/.conductore/sync.',
              helperMaxLines: 3,
            ),
            items: [
              for (final host in machines)
                DropdownMenuItem(value: host, child: Text(host.name)),
            ],
            onChanged: _busy
                ? null
                : (host) => setState(() {
                    _hub = host;
                    _hubHasData = null;
                    _error = null;
                  }),
          ),
          if (_hub?.authMethod == SshAuthMethod.hardwareKey)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'This machine logs in with a hardware key, so every sync '
                'will ask for it. A machine with a key or password login '
                'works better as a hub.',
                style: theme.textTheme.bodySmall,
              ),
            ),
          const SizedBox(height: 16),
          TextField(
            controller: _name,
            decoration: InputDecoration(
              labelText: 'This device\'s name',
              hintText: widget.controller.defaultDeviceName,
            ),
            onSubmitted: _desktop
                ? (_) {
                    if (_hubHasData == null && _hub != null && !_busy) {
                      _check();
                    }
                  }
                : null,
          ),
          const SizedBox(height: 16),
          if (_hubHasData == null)
            FilledButton(
              key: const ValueKey('sync-check-hub'),
              onPressed: _hub == null || _busy ? null : _check,
              child: const Text('Continue'),
            )
          else ...[
            Text(
              _hubHasData!
                  ? '${_hub!.name} already holds sync data. Enter its '
                        'passphrase to join it.'
                  : 'Choose a sync passphrase. You type it once on each '
                        'device you set up by hand; lose it and the synced '
                        'data cannot be read.',
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('sync-passphrase'),
              controller: _passphrase,
              obscureText: _obscure,
              autofocus: true,
              textInputAction: !_desktop
                  ? null
                  : _hubHasData == false
                  ? TextInputAction.next
                  : TextInputAction.done,
              onSubmitted: _desktop && _hubHasData == true
                  ? (_) {
                      if (!_busy) _submit();
                    }
                  : null,
              decoration: InputDecoration(
                labelText: 'Sync passphrase',
                suffixIcon: IconButton(
                  tooltip: _obscure ? 'Show passphrase' : 'Hide passphrase',
                  onPressed: () => setState(() => _obscure = !_obscure),
                  icon: Icon(
                    _obscure
                        ? Icons.visibility_rounded
                        : Icons.visibility_off_rounded,
                  ),
                ),
              ),
            ),
            if (_hubHasData == false) ...[
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('sync-passphrase-confirm'),
                controller: _confirm,
                obscureText: _obscure,
                onSubmitted: _desktop
                    ? (_) {
                        if (!_busy) _submit();
                      }
                    : null,
                decoration: const InputDecoration(
                  labelText: 'Confirm passphrase',
                  helperText:
                      'At least 12 characters and three of lowercase, '
                      'uppercase, numbers and symbols.',
                  helperMaxLines: 2,
                ),
              ),
            ],
            const SizedBox(height: 16),
            FilledButton(
              key: const ValueKey('sync-set-up-confirm'),
              onPressed: _busy ? null : _submit,
              child: Text(_hubHasData! ? 'Join and sync' : 'Turn on sync'),
            ),
          ],
          if (_busy) ...[
            const SizedBox(height: 16),
            const LinearProgressIndicator(),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
          ],
        ],
      ),
    );
  }
}

/// Joins with a setup code: scanned (phones) or pasted, plus six words.
class _JoinPage extends StatefulWidget {
  const _JoinPage({required this.controller});

  final SyncController controller;

  @override
  State<_JoinPage> createState() => _JoinPageState();
}

class _JoinPageState extends State<_JoinPage> {
  final _code = TextEditingController();
  final _words = TextEditingController();
  final _name = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    _words.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    final value = await scanSetupCode(context);
    if (value != null && mounted) setState(() => _code.text = value);
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.controller.join(
        setupCode: _code.text,
        words: _words.text,
        deviceName: _name.text.trim().isEmpty ? null : _name.text,
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted) setState(() => _error = describeSyncError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Join sync')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'On a device that already syncs, open Settings › Sync › Add a '
            'device. It shows a QR code (or a code to copy) and six words.',
          ),
          const SizedBox(height: 16),
          if (setupCodeScanningAvailable) ...[
            FilledButton.icon(
              key: const ValueKey('sync-scan'),
              icon: const Icon(Icons.qr_code_scanner_rounded),
              label: const Text('Scan the QR code'),
              onPressed: _busy ? null : _scan,
            ),
            const SizedBox(height: 12),
          ],
          TextField(
            key: const ValueKey('sync-setup-code'),
            controller: _code,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: 'Setup code',
              hintText: 'conductore-sync:1:…',
              helperText: 'Paste the code copied on the other device.',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('sync-setup-words'),
            controller: _words,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: _desktop ? TextInputAction.next : null,
            decoration: const InputDecoration(
              labelText: 'The six words',
              helperText: 'Type them as shown, separated by spaces.',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _name,
            onSubmitted: _desktop
                ? (_) {
                    if (!_busy) _submit();
                  }
                : null,
            decoration: const InputDecoration(
              labelText: 'This device\'s name (optional)',
              helperText: 'Leave empty for the name given on the other device.',
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            key: const ValueKey('sync-join-confirm'),
            onPressed: _busy ? null : _submit,
            child: const Text('Join'),
          ),
          if (_busy) ...[
            const SizedBox(height: 16),
            const LinearProgressIndicator(),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
          ],
        ],
      ),
    );
  }
}

/// Adds a device: confirm the key install, then show the QR code, the
/// copyable code and the six words.
class _AddDevicePage extends StatefulWidget {
  const _AddDevicePage({required this.controller});

  final SyncController controller;

  @override
  State<_AddDevicePage> createState() => _AddDevicePageState();
}

class _AddDevicePageState extends State<_AddDevicePage> {
  final _name = TextEditingController(text: 'New device');
  SyncPairingOffer? _offer;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final hub = widget.controller.hubHost;
    if (hub == null) return;
    final name = _name.text.trim().isEmpty ? 'New device' : _name.text.trim();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add a login key to the hub?'),
        content: Text(
          'This adds a new SSH key for "$name" to '
          '${hub.username}@${hub.host}:~/.ssh/authorized_keys, marked '
          '"conductore-device". The new device replaces it with its own '
          'key when it joins. You can remove it from the device list at '
          'any time.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('sync-add-device-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Add key'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final offer = await widget.controller.addDevice(name);
      if (mounted) setState(() => _offer = offer);
    } catch (error) {
      if (mounted) setState(() => _error = describeSyncError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancel() async {
    final offer = _offer;
    if (offer == null) {
      Navigator.of(context).pop();
      return;
    }
    setState(() => _busy = true);
    try {
      await widget.controller.cancelPairing(offer);
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = describeSyncError(error);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final offer = _offer;
    return Scaffold(
      appBar: AppBar(title: const Text('Add a device')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (offer == null) ...[
            const Text(
              'The new device gets a login key for the hub and the sync key. '
              'It needs both the QR code (or the copied code) and the six '
              'words shown next, so a photo of the QR code alone is not '
              'enough.',
            ),
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('sync-new-device-name'),
              controller: _name,
              decoration: const InputDecoration(labelText: 'New device name'),
              onSubmitted: _desktop
                  ? (_) {
                      if (!_busy) _create();
                    }
                  : null,
            ),
            const SizedBox(height: 16),
            FilledButton(
              key: const ValueKey('sync-create-pairing'),
              onPressed: _busy ? null : _create,
              child: const Text('Create setup code'),
            ),
          ] else ...[
            Text(
              'On "${offer.deviceName}": Settings › Sync › Join with a setup '
              'code. Scan this code (or paste it on a desktop), then type '
              'the six words.',
            ),
            const SizedBox(height: 16),
            Center(child: QrCodeView(data: offer.setupCode)),
            const SizedBox(height: 16),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final (index, word) in offer.words.indexed)
                  Chip(
                    label: Text(
                      '${index + 1}. $word',
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              key: const ValueKey('sync-copy-setup-code'),
              icon: const Icon(Icons.copy_rounded),
              label: const Text('Copy setup code'),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: offer.setupCode));
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Copied. The code alone does not unlock anything '
                      'without the six words.',
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 8),
            FilledButton(
              key: const ValueKey('sync-pairing-done'),
              onPressed: _busy ? null : () => Navigator.of(context).pop(),
              child: const Text('Done'),
            ),
            const SizedBox(height: 8),
            TextButton(
              key: const ValueKey('sync-pairing-cancel'),
              onPressed: _busy ? null : _cancel,
              child: const Text('Cancel and remove the key'),
            ),
          ],
          if (_busy) ...[
            const SizedBox(height: 16),
            const LinearProgressIndicator(),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
          ],
        ],
      ),
    );
  }
}

/// Desktop forms submit on Enter; phones keep their keyboards' behaviour.
bool get _desktop => PlatformFeatures.isDesktop;
