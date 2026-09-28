import 'dart:io';

import 'package:conduit/features/quick_actions/data/project_files.dart';
import 'package:conduit/features/quick_actions/domain/quick_action.dart';
import 'package:conduit/features/quick_actions/domain/quick_action_plan.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// A `.code-workspace` as Conductore Lite writes it (its WorkspaceCommand:
/// id, label, command, cwd, terminalName), with VS Code's comments and a
/// trailing comma, plus one action using our extensions.
const _liteWorkspace = '''
{
  // VS Code keeps comments in workspace files.
  "folders": [{ "path": "src" }],
  "settings": {},
  "repository": "https://outsmartis.visualstudio.com/Conductore-Lite",
  "commands": [
    {
      "id": "dev",
      "label": "Dev server",
      "command": "npm run dev",
      "terminalName": "dev"
    },
    {
      "id": "test",
      "label": "Tests",
      "command": "npm test -- --watch",
      "cwd": "src"
    },
    /* ours */
    {
      "id": "review",
      "label": "Ask for a review",
      "command": "Review the last commit, http://x.test//y",
      "kind": "prompt",
      "icon": "smart_toy",
      "keybinding": "ctrl+alt+r",
      "confirm": true,
      "onWorktreeCreate": true,
    },
    { "label": "no command" },
  ],
}
''';

void main() {
  group('the .code-workspace commands', () {
    test("reads Lite's exact format and our extensions", () {
      final actions = parseCodeWorkspaceCommands(_liteWorkspace);
      expect(actions.map((a) => a.id), ['dev', 'test', 'review']);
      final dev = actions[0];
      expect(dev.label, 'Dev server');
      expect(dev.command, 'npm run dev');
      expect(dev.terminalName, 'dev');
      expect(dev.kind, QuickActionKind.shell);
      expect(actions[1].cwd, 'src');
      final review = actions[2];
      expect(review.kind, QuickActionKind.prompt);
      // A "//" inside a string is not a comment.
      expect(review.command, contains('http://x.test//y'));
      expect(review.icon, 'smart_toy');
      expect(review.keybinding, 'ctrl+alt+r');
      expect(review.confirm, isTrue);
      expect(review.onWorktreeCreate, isTrue);
    });

    test('Lite-only actions write back with only Lite\'s fields', () {
      final dev = parseCodeWorkspaceCommands(_liteWorkspace).first;
      expect(dev.toJson(), {
        'id': 'dev',
        'label': 'Dev server',
        'command': 'npm run dev',
        'terminalName': 'dev',
      });
    });

    test('unreadable or missing commands give none', () {
      expect(parseCodeWorkspaceCommands(''), isEmpty);
      expect(parseCodeWorkspaceCommands('{"folders": []}'), isEmpty);
      expect(parseCodeWorkspaceCommands('not json'), isEmpty);
      expect(parseCodeWorkspaceCommands('{"commands": "x"}'), isEmpty);
    });

    test('adding an action keeps every other key of the file', () {
      final actions = [
        ...parseCodeWorkspaceCommands(_liteWorkspace),
        const QuickAction(
          id: 'deploy',
          label: 'Deploy',
          command: 'make deploy',
        ),
      ];
      final updated = updateCodeWorkspaceCommands(_liteWorkspace, actions);
      final again = decodeJsonc(updated)! as Map;
      expect(again['repository'], contains('Conductore-Lite'));
      expect(again['folders'], [
        {'path': 'src'},
      ]);
      expect(parseCodeWorkspaceCommands(updated), actions);
      // A new file starts from nothing.
      final fresh = updateCodeWorkspaceCommands('', [actions.last]);
      expect(parseCodeWorkspaceCommands(fresh), [actions.last]);
      expect(
        () => updateCodeWorkspaceCommands('[1]', actions),
        throwsFormatException,
      );
    });

    test('ids stay unique; personal actions filter by project', () {
      expect(QuickAction.newId('Dev server', ['dev-server']), 'dev-server-2');
      const personal = QuickAction(
        id: 'x',
        label: 'x',
        command: 'x',
        project: 'VisitTomar',
      );
      expect(personal.appliesTo('visittomar'), isTrue);
      expect(personal.appliesTo('api'), isFalse);
      expect(personal.copyWith(project: '').appliesTo('api'), isTrue);
      expect(QuickAction.decodeList(QuickAction.encodeList([personal])), [
        personal,
      ]);
    });
  });

  group('running an action', () {
    test('shell runs in the repo, relative cwd under it', () {
      final actions = parseCodeWorkspaceCommands(_liteWorkspace);
      final dev = planQuickAction(actions[0], root: '/srv/app');
      expect(dev, isA<RunInTerminalPlan>());
      dev as RunInTerminalPlan;
      expect(dev.directory, '/srv/app');
      expect(dev.terminalName, 'dev');
      expect(dev.command, 'npm run dev');
      final tests =
          planQuickAction(actions[1], root: '/srv/app/') as RunInTerminalPlan;
      expect(tests.directory, '/srv/app/src');
      // No known repo: an absolute cwd still works, a relative one not.
      expect(resolveActionDirectory('/tmp', null), '/tmp');
      expect(resolveActionDirectory('src', null), isNull);
    });

    test('prompt goes to the agent, url to the browser', () {
      final prompt = planQuickAction(
        const QuickAction(
          id: 'p',
          label: 'p',
          command: ' Fix the tests ',
          kind: QuickActionKind.prompt,
        ),
      );
      expect((prompt as SendPromptPlan).text, 'Fix the tests');
      final url = planQuickAction(
        const QuickAction(
          id: 'u',
          label: 'u',
          command: 'visittomar.pt/admin',
          kind: QuickActionKind.url,
        ),
      );
      expect(
        (url as OpenUrlPlan).uri.toString(),
        'https://visittomar.pt/admin',
      );
      final bad = planQuickAction(
        const QuickAction(
          id: 'b',
          label: 'b',
          command: '::',
          kind: QuickActionKind.url,
        ),
      );
      expect(bad, isA<InvalidPlan>());
    });

    test('keybindings parse, match and refuse bare typing keys', () {
      final keys = QuickActionKeys.parse('ctrl+alt+r')!;
      expect(keys.key, LogicalKeyboardKey.keyR);
      expect(keys.safe, isTrue);
      expect(
        keys.matches(
          const KeyDownEvent(
            physicalKey: PhysicalKeyboardKey.keyR,
            logicalKey: LogicalKeyboardKey.keyR,
            timeStamp: Duration.zero,
          ),
          pressed: {
            LogicalKeyboardKey.controlLeft,
            LogicalKeyboardKey.altLeft,
            LogicalKeyboardKey.keyR,
          },
        ),
        isTrue,
      );
      expect(
        keys.matches(
          const KeyDownEvent(
            physicalKey: PhysicalKeyboardKey.keyR,
            logicalKey: LogicalKeyboardKey.keyR,
            timeStamp: Duration.zero,
          ),
          pressed: {LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.keyR},
        ),
        isFalse,
      );
      expect(QuickActionKeys.parse('f5')!.safe, isTrue);
      expect(QuickActionKeys.parse('b')!.safe, isFalse);
      expect(QuickActionKeys.parse('ctrl+nope'), isNull);
      expect(QuickActionKeys.parse('ctrl+shift+b')!.label, 'Ctrl+Shift+B');
    });
  });

  group('reading and writing the repo', () {
    late Directory repo;

    setUp(() {
      repo = Directory.systemTemp.createTempSync('desktopx-repo');
      Directory('${repo.path}/public').createSync();
      File('${repo.path}/public/favicon.png').writeAsBytesSync([1, 2, 3, 4]);
      File('${repo.path}/app.code-workspace').writeAsStringSync(_liteWorkspace);
      Directory('${repo.path}/src').createSync();
    });

    tearDown(() => repo.deleteSync(recursive: true));

    Future<String> sh(String script) async {
      final result = await Process.run('sh', ['-c', script]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      return result.stdout as String;
    }

    test(
      'finds the icon and the workspace file from a subfolder',
      () async {
        final files = ProjectFilesCommands.parse(
          await sh(ProjectFilesCommands.read('${repo.path}/src')),
        );
        // Not a git repo: the folder asked about is the root.
        expect(files!.root, '${repo.path}/src');
        final top = ProjectFilesCommands.parse(
          await sh(ProjectFilesCommands.read(repo.path)),
        )!;
        expect(top.icon, [1, 2, 3, 4]);
        expect(top.iconPath, 'public/favicon.png');
        expect(top.workspaceFile, 'app.code-workspace');
        expect(top.actions.length, 3);
      },
      testOn: 'linux || mac-os',
    );

    test('writes the file back, keeping a backup', () async {
      final updated = updateCodeWorkspaceCommands(_liteWorkspace, const [
        QuickAction(id: 'it\'s', label: "It's", command: r'echo "$HOME"'),
      ]);
      await sh(
        ProjectFilesCommands.write(repo.path, 'app.code-workspace', updated),
      );
      final written = File(
        '${repo.path}/app.code-workspace',
      ).readAsStringSync();
      expect(written, updated);
      expect(
        parseCodeWorkspaceCommands(written).single.command,
        r'echo "$HOME"',
      );
      expect(File('${repo.path}/app.code-workspace.bak').existsSync(), isTrue);
    }, testOn: 'linux || mac-os');

    test('a missing folder prints nothing to parse', () {
      expect(ProjectFilesCommands.parse(''), isNull);
      expect(
        ProjectFilesCommands.parse('ROOT\t/r\nICON\tx.png\t!!!\n')!.icon,
        isNull,
      );
    });
  });
}
