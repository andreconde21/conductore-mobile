import 'package:conduit/features/command_palette/domain/palette_entry.dart';
import 'package:flutter_test/flutter_test.dart';

PaletteEntry _entry(
  String id,
  String title, {
  PaletteKind kind = PaletteKind.command,
  List<String> keywords = const [],
  String subtitle = '',
  bool urgent = false,
}) => PaletteEntry(
  id: id,
  title: title,
  kind: kind,
  subtitle: subtitle,
  keywords: keywords,
  urgent: urgent,
  run: () async {},
);

void main() {
  final entries = [
    _entry(
      'session:api',
      'api',
      kind: PaletteKind.session,
      subtitle: 'omarchy',
    ),
    _entry('agent:vtm', 'visittomar', kind: PaletteKind.agent, urgent: true),
    _entry('command:new-session', 'New session', keywords: ['connect']),
    _entry(
      'settings:appearance',
      'Settings: Appearance',
      kind: PaletteKind.settings,
    ),
    _entry('layout:grid2x2', 'Layout: 2 × 2', kind: PaletteKind.layout),
    _entry('theme:everforest', 'Theme: Everforest'),
    _entry('command:shortcuts', 'Keyboard shortcuts', keywords: ['keys']),
  ];

  List<String> ids(List<PaletteEntry> list) => [for (final e in list) e.id];

  test('the prefix picks the scope', () {
    expect(parsePaletteQuery('> theme'), (
      scope: PaletteScope.commands,
      text: 'theme',
    ));
    expect(parsePaletteQuery('@vtm').scope, PaletteScope.agents);
    expect(parsePaletteQuery('#api').scope, PaletteScope.places);
    expect(parsePaletteQuery(' api ').scope, PaletteScope.all);
    expect(parsePaletteQuery(' api ').text, 'api');
  });

  test('> lists commands, layouts and settings only', () {
    expect(ids(rankPalette(entries, '>')), [
      'command:new-session',
      'settings:appearance',
      'layout:grid2x2',
      'theme:everforest',
      'command:shortcuts',
    ]);
    expect(ids(rankPalette(entries, '@')), ['agent:vtm']);
    expect(ids(rankPalette(entries, '#')), ['session:api']);
  });

  test('empty query: waiting agents, then recents, then the rest', () {
    final ranked = rankPalette(
      entries,
      '',
      recents: ['command:shortcuts', 'theme:everforest'],
    );
    expect(ids(ranked).take(4), [
      'agent:vtm',
      'command:shortcuts',
      'theme:everforest',
      'session:api',
    ]);
    expect(ranked.length, entries.length);
  });

  test('fuzzy search ranks title matches first, keywords count', () {
    expect(ids(rankPalette(entries, 'ever')).first, 'theme:everforest');
    expect(ids(rankPalette(entries, 'connect')), ['command:new-session']);
    // Letters in order: "kbs" finds Keyboard shortcuts.
    expect(ids(rankPalette(entries, 'kbd sh')).first, 'command:shortcuts');
    // The phrase as typed beats its words spread over another title.
    final phrase = [
      _entry('command:sidebar', 'Sidebar: group by project'),
      _entry('layout:sideBySide', 'Layout: Two side by side'),
    ];
    expect(ids(rankPalette(phrase, 'side by side')).first, 'layout:sideBySide');
    // A word that matches nothing drops the row.
    expect(rankPalette(entries, 'zzzq'), isEmpty);
  });

  test('a recently run entry wins a tie', () {
    final twins = [_entry('a', 'Open logs'), _entry('b', 'Open logs')];
    expect(ids(rankPalette(twins, 'logs')), ['a', 'b']);
    expect(ids(rankPalette(twins, 'logs', recents: ['b'])), ['b', 'a']);
  });

  test('recents keep the newest first, without repeats, capped', () {
    var recents = <String>[];
    for (var i = 0; i < 25; i += 1) {
      recents = notePaletteRecent(recents, 'c$i');
    }
    expect(recents.length, 20);
    expect(recents.first, 'c24');
    recents = notePaletteRecent(recents, 'c10');
    expect(recents.first, 'c10');
    expect(recents.where((id) => id == 'c10').length, 1);
  });
}
