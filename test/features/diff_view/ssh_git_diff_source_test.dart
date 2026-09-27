import 'package:conduit/core/app_failure.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/diff_view/data/ssh_git_diff_source.dart';
import 'package:conduit/features/diff_view/domain/git_diff_source.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

const _ok = AgentCommandResult(stdout: '', stderr: '', exitCode: 0);

const _sampleDiff = '''
diff --git a/x b/x
--- a/x
+++ b/x
@@ -1 +1 @@
-a
+b
''';

void main() {
  final host = buildHost('h');

  test('shell quoting escapes single quotes', () {
    expect(shellQuote("it's"), r"'it'\''s'");
  });

  test('working directory detection prefers the host tmux session', () {
    final tmuxHost = host.copyWith(
      startTmuxOnConnect: true,
      tmuxSessionName: 'main',
      tmuxStartDirectory: '/srv/app',
    );
    final command = SshGitDiffSource.detectWorkingDirectoryCommand(tmuxHost);
    expect(command, startsWith('sh -c '));
    expect(command, contains('tmux display-message -p -t "main"'));
    expect(command, contains('#{pane_current_path}'));
    expect(command, contains('"/srv/app"'));
    expect(command, contains(r'p=$HOME'));

    final awkward = host.copyWith(tmuxStartDirectory: r'/a b/$x"y');
    expect(
      SshGitDiffSource.detectWorkingDirectoryCommand(awkward),
      contains(r'"/a b/\$x\"y"'),
    );

    final plain = SshGitDiffSource.detectWorkingDirectoryCommand(host);
    expect(plain, isNot(contains(' -t ')));
    expect(plain, contains('tmux display-message -p'));
  });

  test('detectWorkingDirectory trims the output', () async {
    final runner = ScriptedAgentCommandRunner([
      const AgentCommandResult(stdout: '/home/u/app\n', stderr: ''),
    ]);
    final source = SshGitDiffSource(runner, host);
    expect(await source.detectWorkingDirectory(), '/home/u/app');
  });

  test('load runs root, both diffs and status, in that order', () async {
    final runner = ScriptedAgentCommandRunner([
      const AgentCommandResult(
        stdout: '/home/u/app\n',
        stderr: '',
        exitCode: 0,
      ),
      const AgentCommandResult(stdout: _sampleDiff, stderr: '', exitCode: 0),
      _ok,
      const AgentCommandResult(
        stdout: '# branch.head main\n1 .M N... 100644 100644 100644 a b x\n',
        stderr: '',
        exitCode: 0,
      ),
    ]);
    final source = SshGitDiffSource(runner, host);
    final snapshot = await source.load('/home/u/app/sub');
    expect(runner.commands, [
      "git -C '/home/u/app/sub' rev-parse --show-toplevel",
      "git -C '/home/u/app/sub' diff --no-color | head -c ${gitDiffMaxBytes + 1}",
      "git -C '/home/u/app/sub' diff --no-color --staged | head -c ${gitDiffMaxBytes + 1}",
      "git -C '/home/u/app/sub' status --porcelain=v2 --branch",
    ]);
    expect(snapshot.repositoryRoot, '/home/u/app');
    expect(snapshot.path, '/home/u/app/sub');
    expect(snapshot.unstaged.files.single.displayPath, 'x');
    expect(snapshot.staged.isEmpty, isTrue);
    expect(snapshot.status?.branch, 'main');
    expect(snapshot.unstagedTruncated, isFalse);
  });

  test('a non-git directory yields a snapshot without a root', () async {
    final runner = ScriptedAgentCommandRunner([
      const AgentCommandResult(
        stdout: '',
        stderr:
            'fatal: not a git repository (or any of the parent directories)',
        exitCode: 128,
      ),
    ]);
    final snapshot = await SshGitDiffSource(runner, host).load('/tmp');
    expect(snapshot.isGitRepository, isFalse);
    expect(runner.commands, hasLength(1));
  });

  test('missing git and missing directories are explained', () async {
    final noGit = ScriptedAgentCommandRunner([
      const AgentCommandResult(
        stdout: '',
        stderr: 'sh: git: not found',
        exitCode: 127,
      ),
    ]);
    await expectLater(
      SshGitDiffSource(noGit, host).load('/tmp'),
      throwsA(
        isA<AppFailure>().having(
          (failure) => failure.message,
          'message',
          contains('Git is not installed'),
        ),
      ),
    );
    final noDir = ScriptedAgentCommandRunner([
      const AgentCommandResult(
        stdout: '',
        stderr: "fatal: cannot change to '/nope': No such file or directory",
        exitCode: 128,
      ),
    ]);
    await expectLater(
      SshGitDiffSource(noDir, host).load('/nope'),
      throwsA(
        isA<AppFailure>().having(
          (failure) => failure.message,
          'message',
          'No such directory: /nope',
        ),
      ),
    );
  });

  test('an empty path is rejected before any command runs', () async {
    final runner = ScriptedAgentCommandRunner([_ok]);
    await expectLater(
      SshGitDiffSource(runner, host).load('  '),
      throwsA(isA<AppFailure>()),
    );
    expect(runner.commands, isEmpty);
  });

  test('oversized diffs are flagged and cut at a line boundary', () async {
    final filler = '+${'x' * 99}\n';
    final buffer = StringBuffer(
      'diff --git a/big b/big\n--- a/big\n+++ b/big\n@@ -0,0 +1,99999 @@\n',
    );
    while (buffer.length <= gitDiffMaxBytes) {
      buffer.write(filler);
    }
    // Simulate `head -c` cutting mid-line at the cap + 1.
    final cut = buffer.toString().substring(0, gitDiffMaxBytes + 1);
    final runner = ScriptedAgentCommandRunner([
      const AgentCommandResult(stdout: '/r\n', stderr: '', exitCode: 0),
      AgentCommandResult(stdout: cut, stderr: '', exitCode: 0),
      _ok,
      _ok,
    ]);
    final snapshot = await SshGitDiffSource(runner, host).load('/r');
    expect(snapshot.unstagedTruncated, isTrue);
    expect(snapshot.stagedTruncated, isFalse);
    final lines = snapshot.unstaged.files.single.hunks.single.lines;
    expect(lines.every((line) => line.text.length == 99), isTrue);
  });

  test('a fatal diff error surfaces despite the head pipe', () async {
    final runner = ScriptedAgentCommandRunner([
      const AgentCommandResult(stdout: '/r\n', stderr: '', exitCode: 0),
      const AgentCommandResult(
        stdout: '',
        stderr: 'fatal: bad revision',
        exitCode: 0,
      ),
    ]);
    await expectLater(
      SshGitDiffSource(runner, host).load('/r'),
      throwsA(isA<AppFailure>()),
    );
  });

  test('close closes the runner', () async {
    final runner = ScriptedAgentCommandRunner([_ok]);
    await SshGitDiffSource(runner, host).close();
    expect(runner.closeCount, 1);
  });
}
