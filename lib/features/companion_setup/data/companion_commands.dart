import 'package:conduit/features/agent_attention/data/remote_tool_command.dart';

/// Shell commands the Agent hooks screen runs over the SSH exec channel.
///
/// Everything goes through `sh -c` with the usual user-local directories on
/// PATH (see [remoteToolCommand]): the companion links itself into
/// `~/.local/bin`, which a non-interactive SSH shell rarely has.
abstract final class CompanionCommands {
  static const hostd = 'conductore-hostd';
  static const hook = 'conductore-hook';

  /// Session id of the synthetic agent "Send test event" creates.
  static const testSessionId = 'conductore-test';

  static String hostdCommand(String args) => remoteToolCommand(hostd, args);

  static final version = hostdCommand('version');
  static final doctor = hostdCommand('doctor');
  static final status = hostdCommand('status');
  static final stop = hostdCommand('stop');
  static final node = remoteToolCommand('node', '--version');
  static final claude = remoteToolCommand('claude', '--version');

  /// Runs [script] under `sh` with the extended PATH exported.
  static String script(String script) {
    final inner =
        'PATH="${remoteToolExtraPathDirs.join(':')}:\$PATH"; export PATH; '
        '$script';
    return 'sh -c ${shellQuoteArgument(inner)}';
  }

  /// `mkdir -p` for the upload directories.
  static String makeDirectories(Iterable<String> paths) =>
      script('mkdir -p ${paths.map(shellQuoteArgument).join(' ')}');

  /// Unpacks the uploaded companion archive in [directory], checks every
  /// unpacked file against [checksumLines] (`<sha256>  <path>`) when
  /// `sha256sum` or `shasum` exists, then runs its `install.sh` (optionally
  /// with `--uninstall`).
  ///
  /// Exits 127 with a readable message when the host has no `tar`, and 1
  /// when unpacking or a checksum fails, so install.sh never runs on a
  /// partial or corrupted upload.
  static String unpackAndInstall(
    String directory, {
    required String archive,
    required List<String> checksumLines,
    bool uninstall = false,
  }) {
    final sums = checksumLines.map(shellQuoteArgument).join(' ');
    return script(
      [
        'cd ${shellQuoteArgument(directory)} || exit 1',
        'if ! command -v tar >/dev/null 2>&1; then '
            'echo "tar not found on PATH: the companion is uploaded as '
            '$archive, install tar and gzip and try again" >&2; '
            'exit 127; fi',
        'tar -xzf ${shellQuoteArgument(archive)} || { '
            'echo "could not unpack $archive (is gzip installed?)" >&2; '
            'exit 1; }',
        'if command -v sha256sum >/dev/null 2>&1; then sum="sha256sum -c"; '
            'elif command -v shasum >/dev/null 2>&1; then '
            'sum="shasum -a 256 -c"; else sum=""; fi',
        'if [ -n "\$sum" ]; then '
            'out=\$(printf "%s\\n" $sums | \$sum 2>&1) || { '
            'printf "%s\\n" "\$out" >&2; '
            'echo "checksum mismatch after unpacking $archive, '
            'not installing" >&2; exit 1; }; '
            'else echo "sha256sum and shasum not found, '
            'skipped the checksum check" >&2; fi',
        'exec sh install.sh${uninstall ? ' --uninstall' : ''}',
      ].join('\n'),
    );
  }

  /// Feeds the hook client a Notification and then a SessionEnd for
  /// [testSessionId], exactly as Claude Code would (JSON on stdin, event
  /// name as the only argument; see host/bin/conductore-hook). The hook only
  /// spools the event; the `status` that follows applies it, starting the
  /// daemon if needed. The SessionEnd makes
  /// the daemon prune the test agent an hour later instead of keeping it.
  static final sendTestEvent = script(
    'printf "%s\\n" '
    '"{\\"session_id\\":\\"$testSessionId\\",'
    '\\"hook_event_name\\":\\"Notification\\",'
    '\\"message\\":\\"Test from Conductore\\",'
    '\\"cwd\\":\\"\$HOME\\"}" | $hook Notification && '
    'printf "%s\\n" '
    '"{\\"session_id\\":\\"$testSessionId\\",'
    '\\"hook_event_name\\":\\"SessionEnd\\",'
    '\\"reason\\":\\"other\\",'
    '\\"cwd\\":\\"\$HOME\\"}" | $hook SessionEnd',
  );
}
