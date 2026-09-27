import 'package:conduit/features/terminal/domain/host_key_prompt.dart';
import 'package:flutter/material.dart';

/// Asks whether to trust a host key.
///
/// A first key is trusted with one tap. A changed key (only ever asked
/// about from a connection the user opened, see
/// [withInteractiveHostKeyCheck]) needs two deliberate steps: "Review
/// replacement" on the warning, then ticking that the new fingerprint was
/// checked with the server before "Replace key" enables. Rejecting is the
/// prominent choice at every step.
Future<HostKeyDecision?> showHostKeyPromptDialog({
  required BuildContext context,
  required HostKeyPromptRequest request,
}) {
  return showDialog<HostKeyDecision>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _HostKeyPromptDialog(request: request),
  );
}

class _HostKeyPromptDialog extends StatefulWidget {
  const _HostKeyPromptDialog({required this.request});

  final HostKeyPromptRequest request;

  @override
  State<_HostKeyPromptDialog> createState() => _HostKeyPromptDialogState();
}

class _HostKeyPromptDialogState extends State<_HostKeyPromptDialog> {
  /// Mismatch only: the second step, confirming the replacement.
  bool _confirming = false;
  bool _checked = false;

  @override
  Widget build(BuildContext context) {
    final request = widget.request;
    final isMismatch = request.kind == HostKeyPromptKind.mismatch;
    final colorScheme = Theme.of(context).colorScheme;
    final endpoint = '${request.host}:${request.port}';
    void reject() => Navigator.of(context).pop(HostKeyDecision.reject);

    if (isMismatch && _confirming) {
      return AlertDialog(
        icon: Icon(Icons.gpp_maybe_outlined, color: colorScheme.error),
        title: const Text('Replace the trusted key?'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Every connection to $endpoint (terminals, agent status, '
                'files, sync) will trust the new key from now on. Only do '
                'this if the server was reinstalled or its keys were '
                'changed on purpose.',
              ),
              const SizedBox(height: 12),
              _PromptField(
                label: 'New fingerprint',
                value: request.sha256Fingerprint ?? request.fingerprint,
              ),
              CheckboxListTile(
                key: const ValueKey('host-key-confirm-checked'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _checked,
                onChanged: (value) => setState(() => _checked = value ?? false),
                title: const Text(
                  'I checked this fingerprint on the server '
                  '(ssh-keygen -lf /etc/ssh/ssh_host_*_key.pub)',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            style: TextButton.styleFrom(foregroundColor: colorScheme.error),
            onPressed: _checked
                ? () => Navigator.of(context).pop(HostKeyDecision.trust)
                : null,
            child: const Text('Replace key'),
          ),
          FilledButton(onPressed: reject, child: const Text('Keep old key')),
        ],
      );
    }

    return AlertDialog(
      icon: Icon(
        isMismatch ? Icons.warning_amber_rounded : Icons.shield_outlined,
        color: isMismatch ? colorScheme.error : colorScheme.primary,
      ),
      title: Text(isMismatch ? 'Host key changed' : 'Trust this host?'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isMismatch)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  'The server at $endpoint is presenting a different key '
                  'than the one you trusted. Someone may be intercepting '
                  'this connection (for example on public Wi-Fi). Do not '
                  'continue unless you know the server was rekeyed or '
                  'reinstalled.',
                  style: TextStyle(color: colorScheme.error),
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  'Conductore has not connected to $endpoint before. Check '
                  'that the fingerprint matches the one the server reports '
                  '(ssh-keygen -lf /etc/ssh/ssh_host_*_key.pub).',
                ),
              ),
            _PromptField(label: 'Host', value: endpoint),
            _PromptField(label: 'Algorithm', value: request.type),
            ..._fingerprintFields(
              sha256: request.sha256Fingerprint,
              md5: request.fingerprint,
            ),
            if (isMismatch && request.existing != null) ...[
              const Divider(height: 24),
              Text(
                'Previously trusted:',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              const SizedBox(height: 6),
              _PromptField(label: 'Algorithm', value: request.existing!.type),
              ..._fingerprintFields(
                sha256: request.existing!.sha256Fingerprint,
                md5: request.existing!.fingerprint,
              ),
            ],
          ],
        ),
      ),
      actions: isMismatch
          ? [
              TextButton(
                style: TextButton.styleFrom(foregroundColor: colorScheme.error),
                onPressed: () => setState(() => _confirming = true),
                child: const Text('Review replacement…'),
              ),
              FilledButton(onPressed: reject, child: const Text('Reject')),
            ]
          : [
              TextButton(onPressed: reject, child: const Text('Reject')),
              FilledButton(
                onPressed: () =>
                    Navigator.of(context).pop(HostKeyDecision.trust),
                child: const Text('Trust'),
              ),
            ],
    );
  }

  /// SHA256 first (what OpenSSH prints), MD5 second.
  static List<Widget> _fingerprintFields({
    required String? sha256,
    required String md5,
  }) => [
    if (sha256 != null) _PromptField(label: 'Fingerprint', value: sha256),
    _PromptField(
      label: sha256 == null ? 'Fingerprint' : 'MD5 fingerprint',
      value: md5,
      secondary: sha256 != null,
    ),
  ];
}

class _PromptField extends StatelessWidget {
  const _PromptField({
    required this.label,
    required this.value,
    this.secondary = false,
  });

  final String label;
  final String value;
  final bool secondary;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: colorScheme.onSurfaceVariant,
              letterSpacing: 0.3,
            ),
          ),
          SelectableText(
            value,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: secondary ? 11 : 12.5,
              color: secondary ? colorScheme.onSurfaceVariant : null,
            ),
          ),
        ],
      ),
    );
  }
}
