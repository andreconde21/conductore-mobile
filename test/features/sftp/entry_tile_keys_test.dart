import 'package:conduit/features/sftp/domain/sftp_entry.dart';
import 'package:conduit/features/sftp/presentation/widgets/entry_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<List<EntryAction>> pumpFocusedTile(WidgetTester tester) async {
    final actions = <EntryAction>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EntryTile(
            entry: const SftpEntry(
              name: 'notes.txt',
              path: '/notes.txt',
              kind: SftpEntryKind.file,
            ),
            onTap: () {},
            onAction: actions.add,
          ),
        ),
      ),
    );
    Focus.of(tester.element(find.text('notes.txt'))).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pump();
    return actions;
  }

  testWidgets(
    'desktop: F2 renames and Delete deletes the focused row',
    (tester) async {
      final actions = await pumpFocusedTile(tester);
      expect(actions, [EntryAction.rename, EntryAction.delete]);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.linux,
      TargetPlatform.windows,
      TargetPlatform.macOS,
    }),
  );

  testWidgets('phones bind no row keys', (tester) async {
    final actions = await pumpFocusedTile(tester);
    expect(actions, isEmpty);
  });
}
