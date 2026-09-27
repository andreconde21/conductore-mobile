import 'package:conduit/features/diff_view/domain/git_status.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses branch headers and ahead/behind counts', () {
    final status = GitStatus.parse('''
# branch.oid 1234
# branch.head feat/diff-preview
# branch.upstream origin/feat/diff-preview
# branch.ab +3 -1
''');
    expect(status.branch, 'feat/diff-preview');
    expect(status.upstream, 'origin/feat/diff-preview');
    expect(status.ahead, 3);
    expect(status.behind, 1);
    expect(status.detached, isFalse);
    expect(status.isClean, isTrue);
  });

  test('reports a detached head', () {
    final status = GitStatus.parse(
      '# branch.oid abc\n# branch.head (detached)\n',
    );
    expect(status.branch, isNull);
    expect(status.detached, isTrue);
  });

  test('parses ordinary, renamed, unmerged and untracked entries', () {
    final status = GitStatus.parse('''
# branch.head main
1 .M N... 100644 100644 100644 abc def lib/app.dart
1 M. N... 100644 100644 100644 abc def lib/staged.dart
1 MM N... 100644 100644 100644 abc def lib/both with space.dart
2 R. N... 100644 100644 100644 abc def R100 docs/b.md\tdocs/a.md
u UU N... 100644 100644 100644 100644 abc def ghi conflict.txt
? notes.txt
! build/
''');
    expect(status.entries, hasLength(7));
    expect(status.entries[0].path, 'lib/app.dart');
    expect(status.entries[0].isUnstaged, isTrue);
    expect(status.entries[0].isStaged, isFalse);
    expect(status.entries[1].isStaged, isTrue);
    expect(status.entries[1].isUnstaged, isFalse);
    expect(status.entries[2].path, 'lib/both with space.dart');
    expect(status.entries[2].isStaged, isTrue);
    expect(status.entries[2].isUnstaged, isTrue);
    expect(status.entries[3].kind, GitStatusEntryKind.renamed);
    expect(status.entries[3].path, 'docs/b.md');
    expect(status.entries[3].originalPath, 'docs/a.md');
    expect(status.entries[4].kind, GitStatusEntryKind.unmerged);
    expect(status.entries[4].path, 'conflict.txt');
    expect(status.entries[5].kind, GitStatusEntryKind.untracked);
    expect(status.entries[5].path, 'notes.txt');
    expect(status.entries[6].kind, GitStatusEntryKind.ignored);
    expect(status.stagedCount, 3);
    expect(status.unstagedCount, 2);
    expect(status.untrackedCount, 1);
    expect(status.conflictedCount, 1);
  });

  test('ignores malformed lines', () {
    final status = GitStatus.parse('1 M.\nbogus\n');
    expect(status.entries, isEmpty);
  });
}
