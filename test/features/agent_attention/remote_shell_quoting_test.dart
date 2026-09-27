import 'dart:io';

import 'package:conduit/features/agent_attention/data/remote_tool_command.dart';
import 'package:conduit/features/diff_view/data/ssh_git_diff_source.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:conduit/features/terminal/domain/recent_directories.dart';
import 'package:flutter_test/flutter_test.dart';

/// Values a remote path, name or id may carry, including the ones that
/// broke out of plain POSIX quoting under fish (review M1).
const _hostile = [
  r"x\';echo INJECTED;#",
  "';echo INJECTED;'",
  r'ends in backslash\',
  r'\\',
  r'a\\b',
  r'x\\',
  r'printf \t%s\n',
  r"\'",
  r'$(echo INJECTED)',
  '`echo INJECTED`',
  r'$HOME',
  '%s %d %%',
  'two\nlines',
  "it's",
  '"double"',
  '!event',
  'ação 🚀',
  '*',
  '',
];

/// Shells found on PATH to run the commands under, as a login shell would
/// (`$SHELL -c <command>`); fish and zsh run when installed.
final _shells = [
  for (final shell in ['sh', 'dash', 'bash', 'zsh', 'fish'])
    if (_which(shell) != null) shell,
];

String? _which(String name) {
  if (Platform.isWindows) return null;
  final result = Process.runSync('sh', ['-c', 'command -v $name']);
  final path = (result.stdout as String).trim();
  return result.exitCode == 0 && path.isNotEmpty ? path : null;
}

Future<String> _run(String shell, String command, {String? stdin}) async {
  final process = await Process.start(shell, ['-c', command]);
  if (stdin != null) process.stdin.write(stdin);
  await process.stdin.close();
  final out = await process.stdout
      .transform(const SystemEncoding().decoder)
      .join();
  await process.exitCode;
  return out;
}

void main() {
  group('shellQuoteArgument', () {
    test('keeps plainly safe values bare and POSIX quoting otherwise', () {
      expect(shellQuoteArgument('w1:p2'), 'w1:p2');
      expect(shellQuoteArgument("it's"), r"'it'\''s'");
      expect(shellQuoteArgument(''), "''");
    });

    test('never leaves a backslash or quote inside single quotes', () {
      expect(shellQuoteArgument(r"x\';y"), r"'x'\\''\'';y'");
      expect(shellQuoteArgument(r'a\'), r"'a'\\''");
    });

    test('a lone backslash keeps the plain POSIX form', () {
      // fish reads `\t` inside single quotes literally too.
      expect(shellQuoteArgument(r"printf '\t'"), r"'printf '\''\t'\'''");
    });

    test('the other quoters share it', () {
      const value = r"x\';echo INJECTED;#";
      final quoted = shellQuoteArgument(value);
      expect(shellQuote(value), quoted);
      expect(ConnectTarget.shellQuote(value), quoted);
      expect(quoteDirectory(value), quoted);
      expect(cdCommand(value), 'cd $quoted');
      expect(shellQuote('plain'), "'plain'");
    });
  });

  group('posixShellCommand', () {
    test('leaves no quote, backslash pair or expansion to the login shell', () {
      final command = posixShellCommand(
        "printf %s 'a'\\''b' \"\$HOME\" `id` \\\\ !x\n",
      );
      final body = command.substring("sh -c '".length, command.length - 1);
      expect(command, startsWith("sh -c 'eval \"\$(printf \""));
      expect(body, isNot(contains("'")));
      expect(body, isNot(contains(r'\\')));
      expect(body.replaceAll(r'"$(printf "', ''), isNot(contains(r'$')));
      expect(body, isNot(contains('`')));
      expect(body, isNot(contains('!')));
      expect(body, isNot(contains('\n')));
    });
  });

  group('under real shells', () {
    for (final shell in _shells) {
      group(shell, () {
        for (final value in _hostile) {
          final label = value.replaceAll('\n', r'\n');

          test('a quoted argument reads back as [$label]', () async {
            expect(
              await _run(shell, 'printf %s ${shellQuoteArgument(value)}'),
              value,
            );
          });

          test('remoteToolCommand reads back [$label]', () async {
            final command = remoteToolCommand(
              'printf',
              '%s ${shellQuoteArgument(value)}',
            );
            expect(await _run(shell, command), value);
          });

          test('posixShellCommand runs [$label] exactly', () async {
            final script = 'printf %s ${shellQuoteArgument(value)}';
            expect(await _run(shell, posixShellCommand(script)), value);
            // The SSH runner wraps remoteToolCommand's output again.
            final nested = posixShellCommand(
              remoteToolCommand('printf', '%s ${shellQuoteArgument(value)}'),
            );
            expect(await _run(shell, nested), value);
          });
        }

        test('posixShellCommand keeps stdin connected', () async {
          expect(
            await _run(shell, posixShellCommand('cat'), stdin: 'from stdin'),
            'from stdin',
          );
        });

        test('git -C on a hostile path runs no injected command', () async {
          final dir = await Directory.systemTemp.createTemp('quote');
          addTearDown(() => dir.delete(recursive: true));
          final hostile = Directory('${dir.path}/x\\\';echo INJECTED;#');
          await hostile.create();
          final out = await _run(
            shell,
            posixShellCommand('cd ${shellQuote(hostile.path)} && pwd'),
          );
          expect(out, isNot(contains('INJECTED\n')));
          expect(out.trim(), hostile.path);
        });
      });
    }
  });
}
