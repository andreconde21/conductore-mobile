import 'package:conduit/core/presentation/multiplexer_icon.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
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

    test('tmux creates detached in the folder, then types claude', () {
      final script = scriptOf(
        NewWorkspaceCommands.tmuxCreate(
          name: 'my app',
          folder: '/srv/a b',
          startClaude: true,
        ),
      );
      expect(script, contains("dir='/srv/a b'\n"));
      expect(
        script,
        contains("tmux new-session -d -s 'my app' -c \"\$dir\"\n"),
      );
      expect(script, endsWith("tmux send-keys -t '=my app:' claude Enter"));
    });

    test('Claude starts in the new pane', () {
      expect(
        NewWorkspaceCommands.herdrStartClaude('w2:p1'),
        contains('exec herdr pane run w2:p1 claude'),
      );
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

    test('a Herdr workspace, then Claude in its pane; opens by id', () async {
      final runner = ScriptedAgentCommandRunner([
        const AgentCommandResult(stdout: _created, stderr: '', exitCode: 0),
        ok,
      ]);
      final target = await WorkspaceCreator(runner).create(
        const NewWorkspaceRequest(
          kind: MultiplexerKind.herdr,
          name: '',
          folder: '~/my proj',
          startClaude: true,
        ),
      );
      expect(
        target,
        const ConnectTarget.herdr(workspaceId: 'w2', label: 'my proj'),
      );
      expect(runner.commands, hasLength(2));
      // Named after the folder when no name was given.
      expect(scriptOf(runner.commands.first), contains("--label 'my proj'"));
      expect(runner.commands.last, contains('pane run w2:p1 claude'));
      // "Phone may move Herdr focus" is off by default.
      expect(scriptOf(runner.commands.first), endsWith('--no-focus'));
    });

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
}
