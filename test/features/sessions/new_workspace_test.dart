import 'package:conduit/core/presentation/multiplexer_icon.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/agent_attention/domain/agent_kinds.dart';
import 'package:conduit/features/sessions/data/workspace_creator.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:conduit/features/sessions/domain/new_workspace.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

/// The script a [posixShellCommand] runs, decoded from its octal escapes.
String scriptOf(String command) {
  const head = 'sh -c \'eval "\$(printf "';
  const tail = '")"\'';
  expect(command, startsWith(head));
  expect(command, endsWith(tail));
  final body = command.substring(head.length, command.length - tail.length);
  return body.replaceAllMapped(
    RegExp(r'\\([0-7]{3})'),
    (match) => String.fromCharCode(int.parse(match[1]!, radix: 8)),
  );
}

/// `herdr workspace create` as Herdr 0.9.3 answers it (captured in a
/// container).
const _created =
    '{"id":"cli:workspace:create","result":{"root_pane":{"agent_status":'
    '"unknown","cwd":"/home/a/my proj","focused":true,"pane_id":"w2:p1",'
    '"tab_id":"w2:t1","workspace_id":"w2"},"tab":{"label":"1","tab_id":'
    '"w2:t1","workspace_id":"w2"},"type":"workspace_created","workspace":'
    '{"active_tab_id":"w2:t1","agent_status":"unknown","focused":true,'
    '"label":"my proj","number":2,"pane_count":1,"tab_count":1,'
    '"workspace_id":"w2"}}}';

const _notRunning =
    '{"id":"cli:workspace:create","error":{"code":"server_not_running",'
    '"message":"no herdr server is running at /home/a/.config/herdr/'
    'herdr.sock; run `herdr` to start or attach it"}}';

void main() {
  group('NewWorkspaceCommands', () {
    test('herdr creates in the folder, labelled, unfocused, every user word '
        'quoted', () {
      final script = scriptOf(
        NewWorkspaceCommands.herdrCreate(
          label: r"it's $(touch /tmp/x)",
          folder: '~/my proj',
        ),
      );
      expect(script, contains('dir="\$HOME"/\'my proj\'\n'));
      expect(
        script,
        contains("if [ ! -d \"\$dir\" ]; then printf 'No such folder: %s\\n'"),
      );
      expect(
        script,
        endsWith(
          'exec herdr workspace create --cwd "\$dir" '
          "--label 'it'\\''s \$(touch /tmp/x)' --no-focus",
        ),
      );
    });

    test('herdr without a folder or name leaves both to Herdr', () {
      final script = scriptOf(NewWorkspaceCommands.herdrCreate(label: ''));
      expect(script, isNot(contains('dir=')));
      expect(script, endsWith('exec herdr workspace create --no-focus'));
    });

    test('herdr focuses it only when the phone may move Herdr focus', () {
      expect(
        scriptOf(NewWorkspaceCommands.herdrCreate(label: 'a', focus: true)),
        endsWith('exec herdr workspace create --label a --focus'),
      );
      expect(
        scriptOf(NewWorkspaceCommands.herdrCreate(label: 'a')),
        endsWith('exec herdr workspace create --label a --no-focus'),
      );
    });

    test('tmux creates detached in the folder, then types the agent', () {
      final script = scriptOf(
        NewWorkspaceCommands.tmuxCreate(
          name: 'my app',
          folder: '/srv/a b',
          agentCommand: 'claude',
        ),
      );
      expect(script, contains("dir='/srv/a b'\n"));
      expect(
        script,
        contains("tmux new-session -d -s 'my app' -c \"\$dir\"\n"),
      );
      expect(script, endsWith("tmux send-keys -t '=my app:' claude Enter"));
    });

    test('the chosen agent starts in the new pane', () {
      expect(
        NewWorkspaceCommands.herdrStartAgent('w2:p1', 'claude'),
        contains('exec herdr pane run w2:p1 claude'),
      );
      expect(
        NewWorkspaceCommands.herdrStartAgent('w2:p1', 'cursor-agent'),
        contains('exec herdr pane run w2:p1 cursor-agent'),
      );
    });

    test('agent detection asks command -v for each, quietly', () {
      final script = scriptOf(
        NewWorkspaceCommands.detectAgents(['claude', 'cursor-agent']),
      );
      expect(script, contains('PATH="\$HOME/.local/bin:'));
      expect(
        script,
        contains(
          'for c in claude cursor-agent; do command -v "\$c" >/dev/null '
          "2>&1 && printf '%s\\n' \"\$c\"; done; exit 0",
        ),
      );
      expect(NewWorkspaceCommands.parseInstalledAgents('claude\n\ncodex \n'), {
        'claude',
        'codex',
      });
    });

    test('names and folders', () {
      expect(NewWorkspaceCommands.tmuxName(' api.v2:x '), 'api_v2_x');
      expect(NewWorkspaceCommands.folderName('~/Projects/app/'), 'app');
      expect(NewWorkspaceCommands.folderName('~'), '');
      expect(NewWorkspaceCommands.folderWord('~'), r'"$HOME"');
      expect(NewWorkspaceCommands.folderWord('/tmp'), "'/tmp'");
    });

    test('reads the created workspace, and Herdr errors in words', () {
      expect(NewWorkspaceCommands.parseHerdrCreated(_created), (
        workspaceId: 'w2',
        label: 'my proj',
        paneId: 'w2:p1',
      ));
      expect(NewWorkspaceCommands.parseHerdrCreated(_notRunning), isNull);
      expect(NewWorkspaceCommands.parseHerdrCreated('garbage'), isNull);
      expect(
        NewWorkspaceCommands.herdrError(_notRunning),
        startsWith('Herdr is not running on this machine.'),
      );
    });
  });

  group('WorkspaceCreator', () {
    const ok = AgentCommandResult(stdout: '', stderr: '', exitCode: 0);

    test(
      'a Herdr workspace, then the agent in its pane; opens by id',
      () async {
        final runner = ScriptedAgentCommandRunner([
          const AgentCommandResult(stdout: _created, stderr: '', exitCode: 0),
          ok,
        ]);
        final target = await WorkspaceCreator(runner).create(
          const NewWorkspaceRequest(
            kind: MultiplexerKind.herdr,
            name: '',
            folder: '~/my proj',
            agent: KnownAgentKind('codex', 'Codex', 'codex'),
          ),
        );
        expect(
          target,
          const ConnectTarget.herdr(workspaceId: 'w2', label: 'my proj'),
        );
        expect(runner.commands, hasLength(2));
        // Named after the folder when no name was given.
        expect(scriptOf(runner.commands.first), contains("--label 'my proj'"));
        expect(runner.commands.last, contains('pane run w2:p1 codex'));
        // "Phone may move Herdr focus" is off by default.
        expect(scriptOf(runner.commands.first), endsWith('--no-focus'));
      },
    );

    test('with the setting on, the new workspace is focused', () async {
      final runner = ScriptedAgentCommandRunner([
        const AgentCommandResult(stdout: _created, stderr: '', exitCode: 0),
      ]);
      await WorkspaceCreator(runner, mayMoveHerdrFocus: true).create(
        const NewWorkspaceRequest(kind: MultiplexerKind.herdr, name: 'api'),
      );
      expect(scriptOf(runner.commands.single), endsWith('--label api --focus'));
    });

    test('Herdr not running reads as such', () async {
      final runner = ScriptedAgentCommandRunner([
        const AgentCommandResult(stdout: _notRunning, stderr: '', exitCode: 1),
      ]);
      await expectLater(
        WorkspaceCreator(runner).create(
          const NewWorkspaceRequest(kind: MultiplexerKind.herdr, name: 'x'),
        ),
        throwsA(
          isA<NewWorkspaceFailure>().having(
            (failure) => failure.message,
            'message',
            startsWith('Herdr is not running'),
          ),
        ),
      );
    });

    test('a missing folder is said, nothing is created', () async {
      final runner = ScriptedAgentCommandRunner([
        const AgentCommandResult(
          stdout: '',
          stderr: 'No such folder: /nope',
          exitCode: NewWorkspaceCommands.missingFolderExit,
        ),
      ]);
      await expectLater(
        WorkspaceCreator(runner).create(
          const NewWorkspaceRequest(
            kind: MultiplexerKind.tmux,
            name: 'x',
            folder: '/nope',
          ),
        ),
        throwsA(
          isA<NewWorkspaceFailure>().having(
            (failure) => failure.message,
            'message',
            'No such folder: /nope',
          ),
        ),
      );
      expect(runner.commands, hasLength(1));
    });

    test(
      'tmux with only a name attaches-or-creates without a command',
      () async {
        final runner = ScriptedAgentCommandRunner([ok]);
        final target = await WorkspaceCreator(runner).create(
          const NewWorkspaceRequest(kind: MultiplexerKind.tmux, name: 'a.b'),
        );
        expect(target, const ConnectTarget.tmux('a_b'));
        expect(runner.commands, isEmpty);
      },
    );

    test('tmux in a folder; an existing name is refused', () async {
      final runner = ScriptedAgentCommandRunner([
        ok,
        const AgentCommandResult(
          stdout: '',
          stderr: 'duplicate session: api',
          exitCode: 1,
        ),
      ]);
      final creator = WorkspaceCreator(runner);
      const request = NewWorkspaceRequest(
        kind: MultiplexerKind.tmux,
        name: 'api',
        folder: '/srv/api',
      );
      expect(await creator.create(request), const ConnectTarget.tmux('api'));
      expect(scriptOf(runner.commands.single), contains('new-session -d'));
      await expectLater(
        creator.create(request),
        throwsA(
          isA<NewWorkspaceFailure>().having(
            (failure) => failure.message,
            'message',
            'A tmux session named "api" already exists.',
          ),
        ),
      );
    });
  });
  group('installed agents (CON-071)', () {
    setUp(WorkspaceCreator.clearDetectedAgents);

    test('only the candidates found, in their order; asked once per '
        'machine while fresh', () async {
      var now = DateTime(2026, 10, 4, 12);
      final runner = ScriptedAgentCommandRunner([
        const AgentCommandResult(
          stdout: 'cursor-agent\nclaude\n',
          stderr: '',
          exitCode: 0,
        ),
        const AgentCommandResult(stdout: 'gemini\n', stderr: '', exitCode: 0),
      ]);
      final creator = WorkspaceCreator(runner, clock: () => now);
      final candidates = agentLaunchCandidates();
      final found = await creator.installedAgents('h', candidates);
      expect([for (final a in found) a.kind], ['claude', 'cursor']);
      expect(runner.commands.single, contains('command -v'));

      await creator.installedAgents('h', candidates);
      expect(runner.commands, hasLength(1));

      now = now.add(WorkspaceCreator.detectionTtl);
      final later = await creator.installedAgents('h', candidates);
      expect([for (final a in later) a.kind], ['gemini']);
      expect(runner.commands, hasLength(2));
    });

    test('a machine that cannot be asked is a failure', () async {
      final runner = ScriptedAgentCommandRunner([
        const AgentCommandResult(stdout: '', stderr: 'boom', exitCode: 2),
      ]);
      await expectLater(
        WorkspaceCreator(runner).installedAgents('h', agentLaunchCandidates()),
        throwsA(isA<NewWorkspaceFailure>()),
      );
    });

    test('candidates come from data: the known agents, plus any kind the '
        'companion reports with a launch command', () {
      final catalog = AgentKindCatalog.fromJson({
        'codex': {'label': 'Codex CLI'},
        'aider': {'label': 'Aider', 'launch': 'aider'},
        'odd': {'label': 'Odd', 'launch': 'touch x; y'},
        'nolaunch': {'label': 'No launch'},
      });
      final candidates = agentLaunchCandidates(catalog);
      expect(
        [for (final c in candidates) (c.kind, c.label, c.command)],
        [
          ('claude', 'Claude Code', 'claude'),
          ('codex', 'Codex CLI', 'codex'),
          ('opencode', 'OpenCode', 'opencode'),
          ('gemini', 'Gemini CLI', 'gemini'),
          ('cursor', 'Cursor', 'cursor-agent'),
          ('aider', 'Aider', 'aider'),
        ],
      );
    });
  });
}
