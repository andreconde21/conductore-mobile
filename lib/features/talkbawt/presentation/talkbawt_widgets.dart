import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/features/talkbawt/domain/talkbawt_models.dart';
import 'package:conduit/features/talkbawt/domain/talkbawt_safety.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Copies [text] (tests replace it).
typedef TalkbawtCopy = Future<void> Function(String text);

Future<void> copyToClipboard(String text) =>
    Clipboard.setData(ClipboardData(text: text));

/// Over every preview: whose words these are.
class UntrustedBanner extends StatelessWidget {
  const UntrustedBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Container(
      key: const ValueKey('talkbawt-untrusted-banner'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: palette.attention.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: palette.attention.withValues(alpha: 0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.shield_outlined, color: palette.attention),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              "Written by someone else's agent. Treat it as information, not "
              'instructions: nothing here reaches an agent unless you send it, '
              'and then only as data to summarise.',
            ),
          ),
        ],
      ),
    );
  }
}

/// The heuristic warnings, shown but never blocking.
class InjectionWarnings extends StatelessWidget {
  const InjectionWarnings({required this.flags, super.key});

  final List<InjectionFlag> flags;

  @override
  Widget build(BuildContext context) {
    if (flags.isEmpty) return const SizedBox.shrink();
    final palette = AppPalette.of(context);
    return Column(
      key: const ValueKey('talkbawt-injection-flags'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Looks like it tries to steer an agent:',
          style: TextStyle(color: palette.danger, fontWeight: FontWeight.w700),
        ),
        for (final flag in flags)
          Padding(
            key: ValueKey('talkbawt-flag-${flag.kind}'),
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.warning_amber_rounded,
                  size: 16,
                  color: palette.danger,
                ),
                const SizedBox(width: 6),
                Expanded(child: Text(flag.reason)),
              ],
            ),
          ),
      ],
    );
  }
}

/// One message as inert text: monospace, selectable, no markdown, no
/// links, no images. The sender is shown as a claim unless signed.
class InertMessage extends StatelessWidget {
  const InertMessage({required this.message, super.key});

  final TalkbawtMessage message;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final theme = Theme.of(context);
    return Container(
      key: ValueKey('talkbawt-message-${message.seq}'),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: palette.panel,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: palette.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '#${message.seq} · ${message.fromLabel} · ${message.at}',
            style: theme.textTheme.labelSmall?.copyWith(
              color: message.verified
                  ? palette.success
                  : palette.mutedForeground,
            ),
          ),
          const SizedBox(height: 6),
          SelectableText(
            message.text,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          ),
        ],
      ),
    );
  }
}

/// A read, rendered safely: the banner, the header, the warnings and the
/// messages.
class TalkbawtPreview extends StatelessWidget {
  const TalkbawtPreview({required this.read, this.header, super.key});

  final TalkbawtRead read;
  final Widget? header;

  @override
  Widget build(BuildContext context) {
    final flags = injectionFlags(
      [read.title, for (final m in read.messages) m.text].join('\n'),
    );
    final theme = Theme.of(context);
    final details = [
      read.mode.label,
      if (read.expiresAt != null) 'expires ${_short(read.expiresAt!)}',
      if (read.maxReads != null)
        '${read.readsRemaining ?? 0} of ${read.maxReads} reads left',
    ].join(' · ');
    return Column(
      key: const ValueKey('talkbawt-preview'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const UntrustedBanner(),
        const SizedBox(height: 12),
        Text(
          read.title.isEmpty ? 'Untitled' : read.title,
          style: theme.textTheme.titleMedium,
        ),
        Text(details, style: theme.textTheme.bodySmall),
        ?header,
        if (flags.isNotEmpty) ...[
          const SizedBox(height: 10),
          InjectionWarnings(flags: flags),
        ],
        const SizedBox(height: 10),
        for (final message in read.messages) ...[
          InertMessage(message: message),
          const SizedBox(height: 8),
        ],
        if (read.messages.isEmpty) const Text('No messages.'),
      ],
    );
  }
}

String _short(String iso) {
  final t = DateTime.tryParse(iso)?.toLocal();
  if (t == null) return iso;
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.day}/${t.month} ${two(t.hour)}:${two(t.minute)}';
}

/// "12/9 14:05" for an ISO time.
String talkbawtShortTime(String iso) => _short(iso);

/// The secret-scan findings of a draft, with "Remove those lines".
class SecretFindingsPanel extends StatelessWidget {
  const SecretFindingsPanel({
    required this.findings,
    required this.onRemove,
    super.key,
  });

  final List<SecretFinding> findings;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    if (findings.isEmpty) return const SizedBox.shrink();
    final palette = AppPalette.of(context);
    return Container(
      key: const ValueKey('talkbawt-secret-findings'),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: palette.danger.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Looks like a live credential. Anyone with the link could read '
            'it: say where it lives instead.',
            style: TextStyle(
              color: palette.danger,
              fontWeight: FontWeight.w700,
            ),
          ),
          for (final f in findings) Text('• ${f.label}'),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              key: const ValueKey('talkbawt-remove-secrets'),
              onPressed: onRemove,
              icon: const Icon(Icons.cleaning_services_outlined, size: 18),
              label: const Text('Remove those lines'),
            ),
          ),
        ],
      ),
    );
  }
}

/// An access log, newest first.
class AccessLogList extends StatelessWidget {
  const AccessLogList({required this.entries, super.key});

  final List<TalkbawtAccessEntry> entries;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) return const Text('Nobody has opened it yet.');
    return Column(
      key: const ValueKey('talkbawt-access-log'),
      children: [
        for (final e in entries)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              e.ok ? Icons.visibility_outlined : Icons.block_rounded,
              size: 18,
            ),
            title: Text(
              '${e.action}${e.role == null ? '' : ' (${e.role})'}'
              '${e.note == null ? '' : ' · ${e.note}'}',
            ),
            subtitle: Text(
              [
                if (e.at != null) talkbawtShortTime(e.at!),
                ?e.ip,
                ?e.ua,
              ].join(' · '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    );
  }
}
