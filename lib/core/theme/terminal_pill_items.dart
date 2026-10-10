/// The buttons the floating pill toolbar can show, in the configurator's
/// catalogue order.
enum TerminalPillButton {
  ctrl('Ctrl', 'Tap arms Ctrl for the next key, long-press latches it.'),
  esc('Esc', 'Escape. Long-press sends Ctrl+C.'),
  tab('Tab', 'Tab. Long-press sends Shift+Tab.'),
  arrows('Arrows', 'Drag or tap the pad for arrow keys.'),
  herdr('Herdr', 'Pane switcher and Herdr shortcuts.'),
  reconnect('Redraw / reconnect', 'Ctrl+L. Long-press reconnects.'),
  paste('Paste', 'Paste the clipboard.'),
  chat('Chat', 'Toggle the chat composer.'),
  dictate('Dictate', 'Open the chat line and start dictating.'),
  keyboard('Keyboard', 'Show or hide the soft keyboard.'),
  tmux('Tmux', 'Tmux actions after the host prefix.'),
  touch('Touch', 'Touch mode: mouse taps and scrollback.'),
  snippets('Snippets', 'Quick prompts and saved snippets.'),
  fullscreen('Fullscreen', 'Hide the header and tabs.');

  const TerminalPillButton(this.label, this.description);

  final String label;
  final String description;
}

/// One slot on the pill: a built-in [button], or a custom key from the key
/// rows referenced by its [customKeyId].
class TerminalPillItem {
  const TerminalPillItem.button(TerminalPillButton this.button)
    : customKeyId = null;

  const TerminalPillItem.custom(String this.customKeyId) : button = null;

  final TerminalPillButton? button;
  final String? customKeyId;

  static const _customPrefix = 'custom:';

  bool get isCustom => customKeyId != null;

  /// `ctrl`, `herdr`, ... or `custom:<key id>`.
  String encode() => button?.name ?? '$_customPrefix$customKeyId';

  static TerminalPillItem? tryDecode(String raw) {
    final value = raw.trim();
    if (value.startsWith(_customPrefix)) {
      final id = value.substring(_customPrefix.length).trim();
      return id.isEmpty ? null : TerminalPillItem.custom(id);
    }
    for (final button in TerminalPillButton.values) {
      if (button.name == value) {
        return TerminalPillItem.button(button);
      }
    }
    return null;
  }

  /// Decodes a stored list, dropping unknown entries and duplicates. Null
  /// or unreadable input yields [defaultTerminalPillItems]; an explicitly
  /// empty list stays empty (the ⋯ button is always there).
  static List<TerminalPillItem> decodeList(Object? raw) {
    if (raw is! List) {
      return defaultTerminalPillItems;
    }
    final seen = <String>{};
    final items = <TerminalPillItem>[];
    for (final entry in raw) {
      if (entry is! String) {
        continue;
      }
      final item = tryDecode(entry);
      if (item != null && seen.add(item.encode())) {
        items.add(item);
      }
    }
    return items;
  }

  static List<String> encodeList(List<TerminalPillItem> items) => [
    for (final item in items) item.encode(),
  ];

  @override
  bool operator ==(Object other) =>
      other is TerminalPillItem &&
      other.button == button &&
      other.customKeyId == customKeyId;

  @override
  int get hashCode => Object.hash(button, customKeyId);

  @override
  String toString() => 'TerminalPillItem(${encode()})';
}

/// The pill out of the box: Ctrl, Esc, Tab, Herdr, Paste and Chat, then
/// the ⋯ button (CON-106). Redraw (Ctrl+L) is in the key rows behind ⋯,
/// Reconnect in the ⋮ menu, and a tap on the terminal opens the keyboard;
/// all of them can be added back from the configurator.
const defaultTerminalPillItems = [
  TerminalPillItem.button(TerminalPillButton.ctrl),
  TerminalPillItem.button(TerminalPillButton.esc),
  TerminalPillItem.button(TerminalPillButton.tab),
  TerminalPillItem.button(TerminalPillButton.herdr),
  TerminalPillItem.button(TerminalPillButton.paste),
  TerminalPillItem.button(TerminalPillButton.chat),
];

/// The default before CON-106 (Moshi's pill, with Herdr as the
/// navigator). The app saved it along with every other setting, so a
/// stored list equal to it was never chosen and gets the new default.
const legacyDefaultTerminalPillItems = [
  TerminalPillItem.button(TerminalPillButton.ctrl),
  TerminalPillItem.button(TerminalPillButton.esc),
  TerminalPillItem.button(TerminalPillButton.tab),
  TerminalPillItem.button(TerminalPillButton.herdr),
  TerminalPillItem.button(TerminalPillButton.reconnect),
  TerminalPillItem.button(TerminalPillButton.paste),
  TerminalPillItem.button(TerminalPillButton.chat),
  TerminalPillItem.button(TerminalPillButton.keyboard),
];

/// [items] as stored before CON-106: the old default becomes the new
/// one, any other list is the user's own and stays as it is. Synced and
/// backed-up lists are taken as they come: there the old default may be
/// a choice made since.
List<TerminalPillItem> migrateLegacyPillItems(List<TerminalPillItem> items) {
  if (items.length != legacyDefaultTerminalPillItems.length) {
    return items;
  }
  for (var i = 0; i < items.length; i++) {
    if (items[i] != legacyDefaultTerminalPillItems[i]) {
      return items;
    }
  }
  return defaultTerminalPillItems;
}
