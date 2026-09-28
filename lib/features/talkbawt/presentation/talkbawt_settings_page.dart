import 'dart:async';

import 'package:conduit/features/talkbawt/domain/talkbawt_link.dart';
import 'package:conduit/features/talkbawt/domain/talkbawt_settings.dart';
import 'package:conduit/features/talkbawt/presentation/talkbawt_controller.dart';
import 'package:flutter/material.dart';

/// Settings › Agents › Talkbawt › Server and relay: the server URL (https
/// only; http for localhost or the tailnet), the default "from" label and
/// the relay setting. Pops true once a server was saved.
class TalkbawtSettingsPage extends StatefulWidget {
  const TalkbawtSettingsPage({required this.controller, super.key});

  final TalkbawtController controller;

  @override
  State<TalkbawtSettingsPage> createState() => _TalkbawtSettingsPageState();
}

class _TalkbawtSettingsPageState extends State<TalkbawtSettingsPage> {
  late final _server = TextEditingController(
    text: widget.controller.settings.server,
  );
  late final _from = TextEditingController(
    text: widget.controller.settings.from,
  );
  String? _error;
  bool _saved = false;

  @override
  void dispose() {
    _server.dispose();
    _from.dispose();
    super.dispose();
  }

  Future<void> _saveServer([String? value]) async {
    final raw = value ?? _server.text;
    try {
      await widget.controller.setServer(raw);
      _server.text = widget.controller.settings.server;
      setState(() {
        _error = null;
        _saved = true;
      });
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text('Server: ${widget.controller.settings.server}'),
          ),
        );
      }
    } on TalkbawtAddressError catch (error) {
      setState(() => _error = error.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return PopScope<Object?>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_saved);
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Talkbawt server and relay')),
        body: ListenableBuilder(
          listenable: controller,
          builder: (context, _) => ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text('Server', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 6),
              TextField(
                key: const ValueKey('talkbawt-server-field'),
                controller: _server,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: InputDecoration(
                  hintText: defaultTalkbawtServer,
                  errorText: _error,
                  helperText:
                      'https:// only; plain http:// for localhost or a '
                      'tailnet address. Links live on this server until they '
                      'expire.',
                  helperMaxLines: 3,
                ),
                onSubmitted: (v) => unawaited(_saveServer(v)),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    key: const ValueKey('talkbawt-server-default'),
                    onPressed: () =>
                        unawaited(_saveServer(defaultTalkbawtServer)),
                    child: const Text('Use the default'),
                  ),
                  FilledButton(
                    key: const ValueKey('talkbawt-server-save'),
                    onPressed: () => unawaited(_saveServer()),
                    child: const Text('Save'),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'Run your own on one of your machines: '
                '"conductore-hostd talkbawt serve --detach" starts the '
                "companion's bundled server on 127.0.0.1 (Node 22.5 or newer); "
                'add --host with the machine\'s tailnet address to reach it '
                'from your other machines, and enter that address here.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const Divider(height: 32),
              Text(
                'Send to another machine\'s agent',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              RadioGroup<TalkbawtRelayMode>(
                groupValue: controller.settings.relay,
                onChanged: (mode) {
                  if (mode != null) unawaited(controller.setRelayMode(mode));
                },
                child: Column(
                  children: [
                    for (final mode in TalkbawtRelayMode.values)
                      RadioListTile<TalkbawtRelayMode>(
                        key: ValueKey('talkbawt-relay-${mode.name}'),
                        contentPadding: EdgeInsets.zero,
                        value: mode,
                        title: Text(mode.label),
                        subtitle: Text(mode.description),
                      ),
                  ],
                ),
              ),
              const Divider(height: 32),
              TextField(
                key: const ValueKey('talkbawt-from-field'),
                controller: _from,
                decoration: const InputDecoration(
                  labelText: 'From',
                  hintText: '<agent> via Conductore',
                  helperText:
                      'How your handoffs are signed. The other side sees it '
                      'as unverified.',
                ),
                onSubmitted: (v) => unawaited(controller.setFrom(v)),
                onTapOutside: (_) {
                  if (_from.text.trim() != controller.settings.from) {
                    unawaited(controller.setFrom(_from.text));
                  }
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
