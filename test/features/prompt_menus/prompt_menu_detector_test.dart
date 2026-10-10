import 'package:conduit/features/prompt_menus/domain/prompt_menu_detector.dart';
import 'package:flutter_test/flutter_test.dart';

/// Splits a fixture into screen rows. Fixtures are written as the terminal
/// shows them; a trailing newline does not add a row.
List<String> screen(String text) {
  final rows = text.split('\n');
  if (rows.isNotEmpty && rows.last.isEmpty) {
    rows.removeLast();
  }
  return rows;
}

/// Pads the screen to [height] rows so a fixture can sit at the top with a
/// blank region below, the way a fresh terminal looks.
List<String> padded(String text, {int height = 40}) {
  final rows = screen(text);
  return [...rows, for (var i = rows.length; i < height; i++) ''];
}

/// Pushes the fixture to the bottom of a [height]-row screen, the way a
/// scrolled terminal shows a prompt.
List<String> bottomed(String text, {int height = 40}) {
  final rows = screen(text);
  return [for (var i = rows.length; i < height; i++) '', ...rows];
}

List<String> labels(PromptMenu? menu) => [
  for (final option in menu!.options) option.label,
];

void main() {
  group('Claude Code permission prompts', () {
    // Claude Code 2.1.x, Bash tool. The dialog replaces the input box; the
    // cursor is parked on the last row.
    const bashPrompt = '''
⏺ I'll check the working tree first.

 Bash command

   git status
   Show working tree status

 Do you want to proceed?
 ❯ 1. Yes
   2. Yes, and don't ask again for git status commands in /root/Projects/app
   3. No, and tell Claude what to do differently (esc)
''';

    test('detects the Bash permission prompt with the pointer on Yes', () {
      final rows = padded(bashPrompt);
      final menu = detectPromptMenu(rows, cursorRow: 10);

      expect(menu, isNotNull);
      expect(menu!.input, PromptMenuInput.digit);
      expect(menu.question, 'Do you want to proceed?');
      expect(menu.selectedIndex, 0);
      expect(menu.hasEscape, isTrue);
      expect(labels(menu), [
        'Yes',
        "Yes, and don't ask again for git status…",
        'No, and tell Claude what to do differently',
      ]);
      expect(
        menu.options[1].text,
        "Yes, and don't ask again for git status commands in "
        '/root/Projects/app',
      );
      expect(menu.options[2].text, contains('(esc)'));
    });

    test('a digit alone answers a Claude Code menu', () {
      final menu = detectPromptMenu(padded(bashPrompt), cursorRow: 10)!;

      expect(menu.keystrokesFor(menu.options[0]), [const PromptMenuText('1')]);
      expect(menu.keystrokesFor(menu.options[2]), [const PromptMenuText('3')]);
    });

    test('works when the pointer has moved to another option', () {
      const moved = '''
 Do you want to proceed?
   1. Yes
   2. Yes, and don't ask again for git status commands in /root/Projects/app
 ❯ 3. No, and tell Claude what to do differently (esc)
''';
      final menu = detectPromptMenu(bottomed(moved), cursorRow: 39);

      expect(menu, isNotNull);
      expect(menu!.selectedIndex, 2);
      expect(menu.options[0].selected, isFalse);
    });

    test('detects the boxed layout used by older Claude Code releases', () {
      const boxed = '''
╭──────────────────────────────────────────────────────────────────────────╮
│ Bash command                                                             │
│                                                                          │
│   ls -la                                                                 │
│   List files                                                             │
│                                                                          │
│ Do you want to proceed?                                                  │
│ ❯ 1. Yes                                                                 │
│   2. Yes, and don't ask again for ls commands in /root/Projects/app      │
│   3. No, and tell Claude what to do differently (esc)                    │
╰──────────────────────────────────────────────────────────────────────────╯
''';
      final menu = detectPromptMenu(bottomed(boxed), cursorRow: 39);

      expect(menu, isNotNull);
      expect(menu!.input, PromptMenuInput.digit);
      expect(menu.question, 'Do you want to proceed?');
      expect(labels(menu), [
        'Yes',
        "Yes, and don't ask again for ls commands in…",
        'No, and tell Claude what to do differently',
      ]);
      expect(menu.hasEscape, isTrue);
    });

    test('detects the Edit file prompt', () {
      const edit = '''
 Edit file

 lib/main.dart

   12 -  final x = 1;
   12 +  final x = 2;

 Do you want to make this edit to main.dart?
 ❯ 1. Yes
   2. Yes, allow all edits during this session (shift+tab)
   3. No, and tell Claude what to do differently (esc)
''';
      final menu = detectPromptMenu(bottomed(edit), cursorRow: 39);

      expect(menu, isNotNull);
      expect(menu!.question, 'Do you want to make this edit to main.dart?');
      expect(labels(menu), [
        'Yes',
        'Yes, allow all edits during this session…',
        'No, and tell Claude what to do differently',
      ]);
    });

    test('detects the plan approval prompt', () {
      const plan = '''
 Claude has written up a plan and is ready to execute. Would you like to proceed?

 ❯ 1. Yes, and auto-accept edits
   2. Yes, and manually approve edits
   3. No, keep planning
''';
      final menu = detectPromptMenu(bottomed(plan), cursorRow: 39);

      expect(menu, isNotNull);
      expect(menu!.input, PromptMenuInput.digit);
      expect(labels(menu), [
        'Yes, and auto-accept edits',
        'Yes, and manually approve edits',
        'No, keep planning',
      ]);
      expect(menu.hasEscape, isFalse);
    });

    test('detects the trust dialog', () {
      const trust = '''
 Do you trust the files in this folder?

 /root/Projects/app

 Claude Code may read files in this folder. Reading untrusted files may lead
 Claude Code to behave in unexpected ways.

 With your permission Claude Code may execute files in this folder. Executing
 untrusted code is unsafe.

 https://docs.claude.com/s/claude-code-security

 ❯ 1. Yes, proceed
   2. No, exit

 Enter to confirm · Esc to exit
''';
      final menu = detectPromptMenu(bottomed(trust), cursorRow: 39);

      expect(menu, isNotNull);
      expect(menu!.question, isNull);
      expect(labels(menu), ['Yes, proceed', 'No, exit']);
      expect(menu.hasEscape, isTrue);
    });
  });

  group('Claude Code AskUserQuestion', () {
    const askUser = '''
 ────────────────────────────────────────────────────────────────────────────
 Which database should the service use?

 ❯ 1. PostgreSQL
      Managed, already provisioned on the dev host
   2. SQLite
      Zero-ops single file next to the binary
   3. Type something.
 ────────────────────────────────────────────────────────────────────────────
 Enter to select · ↑/↓ to navigate · Esc to cancel
''';

    test('keeps description lines with their option', () {
      final menu = detectPromptMenu(bottomed(askUser), cursorRow: 39);

      expect(menu, isNotNull);
      expect(menu!.input, PromptMenuInput.digit);
      expect(menu.question, 'Which database should the service use?');
      expect(labels(menu), ['PostgreSQL', 'SQLite', 'Type something.']);
      expect(
        menu.options[0].text,
        'PostgreSQL Managed, already provisioned on the dev host',
      );
      expect(
        menu.options[1].text,
        'SQLite Zero-ops single file next to the binary',
      );
      expect(menu.hasEscape, isTrue);
    });

    test('handles a tabbed multi-question header', () {
      const multi = '''
 ────────────────────────────────────────────────────────────────────────────
  Database  │  Auth
 ────────────────────────────────────────────────────────────────────────────
 Which auth provider?

   1. Keycloak
 ❯ 2. Auth0
   3. Type something.

 ←/→ to switch · ↑/↓ to navigate · Enter to select · Esc to close
''';
      final menu = detectPromptMenu(bottomed(multi), cursorRow: 39);

      expect(menu, isNotNull);
      expect(menu!.question, 'Which auth provider?');
      expect(menu.selectedIndex, 1);
      expect(labels(menu), ['Keycloak', 'Auth0', 'Type something.']);
    });
  });

  group('arrow-driven select lists', () {
    const modelPicker = '''
 Select model
 Switch between Claude models. Applies to this session and future sessions.

 ❯ Default (recommended)   Opus 4.1 · \$15/\$75 per Mtok
   Sonnet                  Sonnet 4.5 · \$3/\$15 per Mtok
   Haiku                   Haiku 4.5 · \$1/\$5 per Mtok

 ↑/↓ to navigate · Enter to select · Esc to cancel
''';

    test('navigates with arrows relative to the highlighted row', () {
      final menu = detectPromptMenu(bottomed(modelPicker), cursorRow: 39);

      expect(menu, isNotNull);
      expect(menu!.input, PromptMenuInput.arrows);
      expect(menu.selectedIndex, 0);
      expect(labels(menu), [
        'Default (recommended) Opus 4.1 · \$15/\$75 per…',
        'Sonnet Sonnet 4.5 · \$3/\$15 per Mtok',
        'Haiku Haiku 4.5 · \$1/\$5 per Mtok',
      ]);
      expect(menu.keystrokesFor(menu.options[0]), [PromptMenuKey.enter]);
      expect(menu.keystrokesFor(menu.options[2]), [
        PromptMenuKey.arrowDown,
        PromptMenuKey.arrowDown,
        PromptMenuKey.enter,
      ]);
      expect(menu.hasEscape, isTrue);
    });

    test('moves up when the highlight is below the target', () {
      const lower = '''
 Select model
   Default (recommended)
   Sonnet
 ❯ Haiku
 ↑/↓ to navigate · Enter to select · Esc to cancel
''';
      final menu = detectPromptMenu(bottomed(lower), cursorRow: 39)!;

      expect(menu.selectedIndex, 2);
      expect(menu.keystrokesFor(menu.options[0]), [
        PromptMenuKey.arrowUp,
        PromptMenuKey.arrowUp,
        PromptMenuKey.enter,
      ]);
    });

    test('ignores a pointer list without a question or key hints', () {
      // A starship-style shell prompt uses ❯ too; its output must not turn
      // into a menu just because a couple of lines happen to be indented.
      const shell = '''
❯ git status
  On branch main
  nothing to commit, working tree clean
❯
''';
      expect(detectPromptMenu(padded(shell), cursorRow: 3), isNull);
    });

    test('ignores shell history lines that use the pointer glyph', () {
      const history = '''
Which files changed?
❯ git diff --stat
 lib/a.dart | 2 +-
 1 file changed, 1 insertion(+), 1 deletion(-)
❯
''';
      expect(detectPromptMenu(padded(history), cursorRow: 4), isNull);
    });
  });

  group('typed numbered prompts', () {
    test('bash select with the #? input line', () {
      const select = '''
\$ ./deploy.sh
1) dev
2) staging
3) prod
4) quit
#?
''';
      final rows = padded(select);
      final menu = detectPromptMenu(rows, cursorRow: 5);

      expect(menu, isNotNull);
      expect(menu!.input, PromptMenuInput.digitEnter);
      expect(labels(menu), ['dev', 'staging', 'prod', 'quit']);
      expect(menu.keystrokesFor(menu.options[1]), [
        const PromptMenuText('2'),
        PromptMenuKey.enter,
      ]);
      expect(menu.hasEscape, isFalse);
    });

    test('installer asking for a choice in a range', () {
      const installer = '''
Available targets:
  1. Development server
  2. Production server
  3. Cancel
Enter choice [1-3]:
''';
      final menu = detectPromptMenu(padded(installer), cursorRow: 4);

      expect(menu, isNotNull);
      expect(menu!.input, PromptMenuInput.digitEnter);
      expect(labels(menu), [
        'Development server',
        'Production server',
        'Cancel',
      ]);
    });

    test('question above a plain numbered list', () {
      const question = '''
Select the interface to configure:
1. eth0
2. wlan0
3. lo
>
''';
      final menu = detectPromptMenu(padded(question), cursorRow: 4);

      expect(menu, isNotNull);
      expect(menu!.input, PromptMenuInput.digitEnter);
      expect(menu.question, 'Select the interface to configure:');
    });

    test('a numbered list needs a question, pointer, hint, or input line', () {
      const bare = '''
\$ cat TODO.md
1. Write the detector
2. Wire the strip
3. Ship it
\$
''';
      expect(detectPromptMenu(padded(bare), cursorRow: 4), isNull);
    });

    test('markdown steps under a heading are not a menu', () {
      const readme = '''
\$ cat README.md
## Steps:
1. Install dependencies
2. Run the build
3. Deploy
user@host:~/app\$
''';
      expect(detectPromptMenu(padded(readme), cursorRow: 5), isNull);
    });

    test('a numbered list in a Claude reply above the input box is not '
        'a menu', () {
      const reply = '''
⏺ Here is what I changed:

  1. Added the detector under lib/features/prompt_menus/domain
  2. Wired the strip above the keyboard bar
  3. Covered both with tests

 ────────────────────────────────────────────────────────────────────────────
 >
 ────────────────────────────────────────────────────────────────────────────
  ? for shortcuts
''';
      expect(detectPromptMenu(padded(reply), cursorRow: 7), isNull);
    });

    test('ignores non-sequential or single-item lists', () {
      const gap = '''
Choose one:
1. alpha
3. gamma
>
''';
      expect(detectPromptMenu(padded(gap), cursorRow: 3), isNull);

      const single = '''
Choose one:
1. alpha
>
''';
      expect(detectPromptMenu(padded(single), cursorRow: 2), isNull);
    });

    test('ignores line-number style output', () {
      const grep = '''
Which line?
1: import foo
2: import bar
3: void main() {}
\$
''';
      expect(detectPromptMenu(padded(grep), cursorRow: 4), isNull);
    });

    test('ignores a menu that scrolled far above the bottom', () {
      final rows = [
        ...screen('''
Do you want to proceed?
❯ 1. Yes
  2. No
'''),
        for (var i = 0; i < 30; i++) 'log line $i',
      ];
      expect(detectPromptMenu(rows, cursorRow: rows.length - 1), isNull);
    });

    test('stops at a blank gap inside the list', () {
      const gapped = '''
Pick a target:
1. dev

2. prod

3. quit


Enter choice [1-3]:
''';
      final menu = detectPromptMenu(padded(gapped), cursorRow: 8);

      expect(menu, isNotNull);
      expect(labels(menu), ['dev', 'prod', 'quit']);
    });
  });

  group('yes/no prompts', () {
    test('apt style [Y/n] with Yes as the default', () {
      const apt = '''
The following NEW packages will be installed:
  ripgrep
Need to get 1,534 kB of archives.
Do you want to continue? [Y/n]
''';
      final menu = detectPromptMenu(padded(apt), cursorRow: 3);

      expect(menu, isNotNull);
      expect(menu!.input, PromptMenuInput.word);
      expect(menu.question, 'Do you want to continue?');
      expect(labels(menu), ['Yes', 'No']);
      expect(menu.selectedIndex, 0);
      expect(menu.keystrokesFor(menu.options[0]), [
        const PromptMenuText('y'),
        PromptMenuKey.enter,
      ]);
      expect(menu.keystrokesFor(menu.options[1]), [
        const PromptMenuText('n'),
        PromptMenuKey.enter,
      ]);
    });

    test('(y/N) marks No as the default', () {
      const overwrite = 'Overwrite config.yaml? (y/N) ';
      final menu = detectPromptMenu(padded(overwrite), cursorRow: 0);

      expect(menu, isNotNull);
      expect(menu!.selectedIndex, 1);
    });

    test('ssh host key prompt types the whole word', () {
      const ssh = '''
The authenticity of host 'example.com (203.0.113.4)' can't be established.
ED25519 key fingerprint is SHA256:abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG.
This key is not known by any other names.
Are you sure you want to continue connecting (yes/no/[fingerprint])?
''';
      final menu = detectPromptMenu(padded(ssh), cursorRow: 3);

      expect(menu, isNotNull);
      expect(menu!.keystrokesFor(menu.options[0]), [
        const PromptMenuText('yes'),
        PromptMenuKey.enter,
      ]);
      expect(menu.keystrokesFor(menu.options[1]), [
        const PromptMenuText('no'),
        PromptMenuKey.enter,
      ]);
    });

    test('only the input line counts, not an earlier prompt', () {
      const past = '''
Do you want to continue? [Y/n] y
Setting up ripgrep (14.1.0) ...
\$
''';
      expect(detectPromptMenu(padded(past), cursorRow: 2), isNull);
    });

    test('a typed answer removes the prompt', () {
      const typed = 'Do you want to continue? [Y/n] y';
      expect(detectPromptMenu(padded(typed), cursorRow: 0), isNull);
    });
  });

  group('edge cases', () {
    test('an empty screen has no menu', () {
      expect(detectPromptMenu(const []), isNull);
      expect(detectPromptMenu(padded('')), isNull);
    });

    test('falls back to the last content row without a cursor', () {
      const select = '''
1) dev
2) prod
#?
''';
      final menu = detectPromptMenu(padded(select));

      expect(menu, isNotNull);
      expect(labels(menu), ['dev', 'prod']);
    });

    test('caps the number of options', () {
      final rows = [
        'Choose:',
        for (var i = 1; i <= 14; i++) '$i. item $i',
        'Choice: ',
      ];
      final menu = detectPromptMenu(rows, cursorRow: rows.length - 1);

      expect(menu, isNotNull);
      expect(menu!.options.length, 12);
    });

    test('a pointer row indented to the sibling column does not crash', () {
      // GlitchTip #430: the walk up from the lower pointer stopped on a row
      // indented to its text column that is itself a deeper pointer row, and
      // _findPointerBlock force-unwrapped the mismatch.
      const nested = '''
Which one?
    ❯ nested
  ❯ outer
    sibling
↑/↓ to navigate · Enter to select
''';
      final menu = detectPromptMenu(padded(nested), cursorRow: 4);

      expect(menu, isNotNull);
      expect(labels(menu), ['outer', 'sibling']);
      expect(menu!.selectedIndex, 0);
    });

    test('menus compare by content so an unchanged screen is a no-op', () {
      const prompt = '''
Do you want to proceed?
❯ 1. Yes
  2. No
''';
      final a = detectPromptMenu(bottomed(prompt), cursorRow: 39);
      final b = detectPromptMenu(bottomed(prompt), cursorRow: 39);

      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });
  });
}
