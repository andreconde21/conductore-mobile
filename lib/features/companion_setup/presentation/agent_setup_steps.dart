import 'dart:async';

import 'package:conduit/features/companion_setup/domain/companion_status.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Codex's documentation of hooks and their trust (`/hooks`).
final codexHooksDocs = Uri.parse('https://developers.openai.com/codex/hooks');

/// The doctor check that says whether Codex trusts our hooks
/// (host/lib/adapters/codex.js `doctor`).
const codexTrustCheck = 'codex hooks trusted';

/// The manual steps other agents need once, from the companion's doctor
/// checks: today Codex's hook trust. Empty when none applies.
List<Widget> agentSetupSteps(List<CompanionDoctorCheck> checks) => [
  for (final check in checks)
    if (check.name == codexTrustCheck) CodexTrustCard(trusted: check.ok),
];

/// Explains Codex's hook trust: Codex runs a new or changed hook only
/// after the user trusted it, and Conductore never does that for them.
class CodexTrustCard extends StatelessWidget {
  const CodexTrustCard({required this.trusted, super.key});

  final bool trusted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = trusted
        ? theme.colorScheme.primary
        : theme.colorScheme.tertiary;
    return Card(
      key: const ValueKey('codex-trust-card'),
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  trusted ? Icons.verified_user_outlined : Icons.gpp_maybe,
                  size: 20,
                  color: color,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    trusted
                        ? 'Codex trusts the Conductore hooks'
                        : 'Codex: trust the Conductore hooks',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              trusted
                  ? 'Codex sessions on this machine report to the phone. '
                        'If Codex asks to review the hooks again (after an '
                        'update of the companion), trust them again.'
                  : 'Codex runs new hooks only after you trust them, and '
                        'Conductore never does that for you. Until then, '
                        'Codex sessions do not reach the phone.',
            ),
            if (!trusted) ...[
              const SizedBox(height: 8),
              const Text(
                '1. Start Codex on this machine.\n'
                '2. When it says "Hooks need review", choose '
                '"Trust all and continue".\n'
                'Or, in a running Codex, type /hooks and press t.',
                key: ValueKey('codex-trust-steps'),
              ),
            ],
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const ValueKey('codex-trust-docs'),
                onPressed: () => unawaited(
                  launchUrl(
                    codexHooksDocs,
                    mode: LaunchMode.externalApplication,
                  ),
                ),
                icon: const Icon(Icons.open_in_new_rounded, size: 18),
                label: const Text('Codex hooks documentation'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
