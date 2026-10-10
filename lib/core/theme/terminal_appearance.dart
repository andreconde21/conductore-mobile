/// Bundled terminal fonts. JetBrains Mono Nerd Font is Omarchy's default
/// monospace font and the app default.
enum TerminalFontOption {
  jetBrainsMonoNerdFont,
  atkynsonNerdFont,
  systemMonospace,
}

const TerminalFontOption defaultTerminalFont =
    TerminalFontOption.jetBrainsMonoNerdFont;

enum TerminalEnterSequence { cr, lf, crlf }

/// Which input toolbar the terminal page shows above the soft keyboard.
enum TerminalToolbarStyle { floatingPill, keyRows }

extension TerminalToolbarStyleDetails on TerminalToolbarStyle {
  String get label => switch (this) {
    TerminalToolbarStyle.floatingPill => 'Floating pill',
    TerminalToolbarStyle.keyRows => 'Key rows',
  };

  String get description => switch (this) {
    TerminalToolbarStyle.floatingPill =>
      'Compact pill with Ctrl, Esc, Tab, an arrow pad and quick actions. '
          'The key rows stay one tap away behind the ⋯ button.',
    TerminalToolbarStyle.keyRows => 'Full-width rows of every configured key.',
  };
}

/// How a phone or tablet shows the multiplexer's own tabs (Herdr tabs,
/// tmux windows). A desktop always has the full strip unless this is off.
enum MultiplexerTabsMode {
  /// No extra row: the session's tab in the top row names the current
  /// multiplexer tab and opens the list; switching shows a brief overlay.
  compact,

  /// The full strip under the top row (a tablet has the room).
  strip,

  off;

  String get label => switch (this) {
    MultiplexerTabsMode.compact => 'Compact',
    MultiplexerTabsMode.strip => 'Strip',
    MultiplexerTabsMode.off => 'Off',
  };
}

const terminalFontSizeDefault = 13.5;
const terminalFontSizeMin = 4.0;
const terminalFontSizeMax = 30.0;
const terminalFontSizeStep = 0.5;
const terminalFontSizeDivisions = 52;

double clampTerminalFontSize(num size) {
  return size.clamp(terminalFontSizeMin, terminalFontSizeMax).toDouble();
}

double normalizeTerminalFontSize(double size) {
  final normalized =
      (size / terminalFontSizeStep).round() * terminalFontSizeStep;
  return clampTerminalFontSize(normalized);
}

extension TerminalFontOptionDetails on TerminalFontOption {
  String get label => switch (this) {
    TerminalFontOption.jetBrainsMonoNerdFont => 'JetBrains Mono',
    TerminalFontOption.atkynsonNerdFont => 'Atkynson',
    TerminalFontOption.systemMonospace => 'System',
  };

  String get fontFamily => switch (this) {
    TerminalFontOption.jetBrainsMonoNerdFont => 'JetBrainsMonoNerdFontMono',
    TerminalFontOption.atkynsonNerdFont => 'AtkynsonMonoNerdFontMono',
    TerminalFontOption.systemMonospace => 'monospace',
  };

  /// Whether the font carries the Nerd Font icons (powerline, nf-*).
  bool get hasNerdGlyphs => this != TerminalFontOption.systemMonospace;
}

/// The bundled font for a font family name a machine reports (Omarchy's
/// `fc-match monospace`, alacritty's `family`), or null when none matches.
/// Nerd Font naming variants (`JetBrainsMono Nerd Font`, `... NF`,
/// `... Nerd Font Mono`, `JetBrains Mono`) all match.
TerminalFontOption? terminalFontForFamily(String family) {
  final key = family.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
  if (key.startsWith('jetbrainsmono')) {
    return TerminalFontOption.jetBrainsMonoNerdFont;
  }
  if (key.startsWith('atkynsonmono') || key.startsWith('atkinsonmono')) {
    return TerminalFontOption.atkynsonNerdFont;
  }
  return null;
}

extension TerminalEnterSequenceDetails on TerminalEnterSequence {
  String get label => switch (this) {
    TerminalEnterSequence.cr => 'CR',
    TerminalEnterSequence.lf => 'LF',
    TerminalEnterSequence.crlf => 'CRLF',
  };

  String get description => switch (this) {
    TerminalEnterSequence.cr => 'Carriage return',
    TerminalEnterSequence.lf => 'Line feed',
    TerminalEnterSequence.crlf => 'Carriage return + line feed',
  };

  String get value => switch (this) {
    TerminalEnterSequence.cr => '\r',
    TerminalEnterSequence.lf => '\n',
    TerminalEnterSequence.crlf => '\r\n',
  };
}

enum TerminalKeyboardAction {
  escape,
  control,
  alt,
  tab,
  fullscreen,
  arrowUp,
  arrowDown,
  arrowLeft,
  arrowRight,
  home,
  end,
  pageUp,
  pageDown,
  controlC,
  controlD,
  controlZ,
  controlL,
  colon,
  slash,
  pipe,
  dash,
  paste,
  functionKeys,
  tmuxPrefix,
  tmuxScrollback,
  tmuxMenu,
  herdrMenu,
  snippets,
  compose,
  touchMode,
}

enum TerminalKeyboardItemKind { builtIn, customText, customControl }

class TerminalKeyboardItem {
  const TerminalKeyboardItem({
    required this.id,
    required this.kind,
    required this.label,
    this.action,
    this.text,
    this.controlKey,
    this.submit = false,
  });

  const TerminalKeyboardItem.builtIn(TerminalKeyboardAction this.action)
    : id = '',
      kind = TerminalKeyboardItemKind.builtIn,
      label = '',
      text = null,
      controlKey = null,
      submit = false;

  final String id;
  final TerminalKeyboardItemKind kind;
  final String label;
  final TerminalKeyboardAction? action;
  final String? text;
  final String? controlKey;
  final bool submit;

  String get stableId {
    final action = this.action;
    if (kind == TerminalKeyboardItemKind.builtIn && action != null) {
      return 'builtIn:${action.name}';
    }
    return id;
  }

  String get displayLabel {
    final action = this.action;
    if (kind == TerminalKeyboardItemKind.builtIn && action != null) {
      return action.label;
    }
    return label;
  }

  @override
  bool operator ==(Object other) {
    return other is TerminalKeyboardItem &&
        other.id == id &&
        other.kind == kind &&
        other.label == label &&
        other.action == action &&
        other.text == text &&
        other.controlKey == controlKey &&
        other.submit == submit;
  }

  @override
  int get hashCode =>
      Object.hash(id, kind, label, action, text, controlKey, submit);
}

const defaultTerminalKeyboardActions = [
  TerminalKeyboardAction.escape,
  TerminalKeyboardAction.control,
  TerminalKeyboardAction.alt,
  TerminalKeyboardAction.tab,
  TerminalKeyboardAction.compose,
  TerminalKeyboardAction.arrowUp,
  TerminalKeyboardAction.arrowDown,
  TerminalKeyboardAction.arrowLeft,
  TerminalKeyboardAction.arrowRight,
  TerminalKeyboardAction.slash,
  TerminalKeyboardAction.dash,
  TerminalKeyboardAction.pipe,
  TerminalKeyboardAction.paste,
  TerminalKeyboardAction.controlC,
  TerminalKeyboardAction.controlD,
  TerminalKeyboardAction.controlZ,
  TerminalKeyboardAction.controlL,
  TerminalKeyboardAction.home,
  TerminalKeyboardAction.end,
  TerminalKeyboardAction.pageUp,
  TerminalKeyboardAction.pageDown,
  TerminalKeyboardAction.functionKeys,
  TerminalKeyboardAction.tmuxPrefix,
  TerminalKeyboardAction.tmuxScrollback,
  TerminalKeyboardAction.tmuxMenu,
  TerminalKeyboardAction.herdrMenu,
  TerminalKeyboardAction.snippets,
  TerminalKeyboardAction.touchMode,
  TerminalKeyboardAction.fullscreen,
];

const legacyDefaultTerminalKeyboardActions = [
  TerminalKeyboardAction.escape,
  TerminalKeyboardAction.control,
  TerminalKeyboardAction.alt,
  TerminalKeyboardAction.tab,
  TerminalKeyboardAction.fullscreen,
  TerminalKeyboardAction.arrowUp,
  TerminalKeyboardAction.arrowDown,
  TerminalKeyboardAction.arrowLeft,
  TerminalKeyboardAction.arrowRight,
  TerminalKeyboardAction.home,
  TerminalKeyboardAction.end,
  TerminalKeyboardAction.pageUp,
  TerminalKeyboardAction.pageDown,
  TerminalKeyboardAction.controlC,
  TerminalKeyboardAction.controlD,
  TerminalKeyboardAction.controlZ,
  TerminalKeyboardAction.controlL,
  TerminalKeyboardAction.colon,
  TerminalKeyboardAction.slash,
  TerminalKeyboardAction.pipe,
  TerminalKeyboardAction.dash,
  TerminalKeyboardAction.paste,
  TerminalKeyboardAction.functionKeys,
];

const preTrackingTerminalKeyboardActionNames = <String>{
  'escape',
  'control',
  'alt',
  'tab',
  'fullscreen',
  'arrowUp',
  'arrowDown',
  'arrowLeft',
  'arrowRight',
  'home',
  'end',
  'pageUp',
  'pageDown',
  'controlC',
  'controlD',
  'controlZ',
  'controlL',
  'colon',
  'slash',
  'pipe',
  'dash',
  'paste',
  'functionKeys',
  'tmuxPrefix',
  'tmuxScrollback',
  'tmuxMenu',
  'compose',
};

const tmuxTerminalKeyboardActions = [
  TerminalKeyboardAction.tmuxPrefix,
  TerminalKeyboardAction.tmuxScrollback,
  TerminalKeyboardAction.tmuxMenu,
];

/// The key rows out of the box. Chat follows Tab, as on the pill; the
/// colon key made room for it (CON-106).
const defaultTerminalKeyboardItems = [
  TerminalKeyboardItem.builtIn(TerminalKeyboardAction.escape),
  TerminalKeyboardItem.builtIn(TerminalKeyboardAction.control),
  TerminalKeyboardItem.builtIn(TerminalKeyboardAction.alt),
  TerminalKeyboardItem.builtIn(TerminalKeyboardAction.tab),
  TerminalKeyboardItem.builtIn(TerminalKeyboardAction.compose),
  TerminalKeyboardItem.builtIn(TerminalKeyboardAction.arrowUp),
  TerminalKeyboardItem.builtIn(TerminalKeyboardAction.arrowDown),
  TerminalKeyboardItem.builtIn(TerminalKeyboardAction.arrowLeft),
  TerminalKeyboardItem.builtIn(TerminalKeyboardAction.arrowRight),
  TerminalKeyboardItem.builtIn(TerminalKeyboardAction.slash),
  TerminalKeyboardItem.builtIn(TerminalKeyboardAction.dash),
  TerminalKeyboardItem.builtIn(TerminalKeyboardAction.pipe),
  TerminalKeyboardItem.builtIn(TerminalKeyboardAction.paste),
  TerminalKeyboardItem.builtIn(TerminalKeyboardAction.controlC),
  TerminalKeyboardItem.builtIn(TerminalKeyboardAction.controlD),
  TerminalKeyboardItem.builtIn(TerminalKeyboardAction.controlZ),
  TerminalKeyboardItem.builtIn(TerminalKeyboardAction.controlL),
  TerminalKeyboardItem.builtIn(TerminalKeyboardAction.home),
  TerminalKeyboardItem.builtIn(TerminalKeyboardAction.end),
  TerminalKeyboardItem.builtIn(TerminalKeyboardAction.pageUp),
  TerminalKeyboardItem.builtIn(TerminalKeyboardAction.pageDown),
  TerminalKeyboardItem.builtIn(TerminalKeyboardAction.functionKeys),
  TerminalKeyboardItem.builtIn(TerminalKeyboardAction.tmuxPrefix),
  TerminalKeyboardItem.builtIn(TerminalKeyboardAction.tmuxScrollback),
  TerminalKeyboardItem.builtIn(TerminalKeyboardAction.tmuxMenu),
  TerminalKeyboardItem.builtIn(TerminalKeyboardAction.herdrMenu),
  TerminalKeyboardItem.builtIn(TerminalKeyboardAction.snippets),
  TerminalKeyboardItem.builtIn(TerminalKeyboardAction.touchMode),
  TerminalKeyboardItem.builtIn(TerminalKeyboardAction.fullscreen),
];

/// The default key rows before CON-106 (no Chat key, a colon key). Saved
/// with every other setting, so a stored row equal to it was never chosen
/// and gets [defaultTerminalKeyboardRows].
const preChatDefaultTerminalKeyboardItems = [
  TerminalKeyboardItem.builtIn(TerminalKeyboardAction.escape),
  TerminalKeyboardItem.builtIn(TerminalKeyboardAction.control),
  TerminalKeyboardItem.builtIn(TerminalKeyboardAction.alt),
  TerminalKeyboardItem.builtIn(TerminalKeyboardAction.tab),
  TerminalKeyboardItem.builtIn(TerminalKeyboardAction.arrowUp),
  TerminalKeyboardItem.builtIn(TerminalKeyboardAction.arrowDown),
  TerminalKeyboardItem.builtIn(TerminalKeyboardAction.arrowLeft),
  TerminalKeyboardItem.builtIn(TerminalKeyboardAction.arrowRight),
  TerminalKeyboardItem.builtIn(TerminalKeyboardAction.slash),
  TerminalKeyboardItem.builtIn(TerminalKeyboardAction.dash),
  TerminalKeyboardItem.builtIn(TerminalKeyboardAction.pipe),
  TerminalKeyboardItem.builtIn(TerminalKeyboardAction.paste),
  TerminalKeyboardItem.builtIn(TerminalKeyboardAction.controlC),
  TerminalKeyboardItem.builtIn(TerminalKeyboardAction.controlD),
  TerminalKeyboardItem.builtIn(TerminalKeyboardAction.controlZ),
  TerminalKeyboardItem.builtIn(TerminalKeyboardAction.controlL),
  TerminalKeyboardItem.builtIn(TerminalKeyboardAction.colon),
  TerminalKeyboardItem.builtIn(TerminalKeyboardAction.home),
  TerminalKeyboardItem.builtIn(TerminalKeyboardAction.end),
  TerminalKeyboardItem.builtIn(TerminalKeyboardAction.pageUp),
  TerminalKeyboardItem.builtIn(TerminalKeyboardAction.pageDown),
  TerminalKeyboardItem.builtIn(TerminalKeyboardAction.functionKeys),
  TerminalKeyboardItem.builtIn(TerminalKeyboardAction.tmuxPrefix),
  TerminalKeyboardItem.builtIn(TerminalKeyboardAction.tmuxScrollback),
  TerminalKeyboardItem.builtIn(TerminalKeyboardAction.tmuxMenu),
  TerminalKeyboardItem.builtIn(TerminalKeyboardAction.herdrMenu),
  TerminalKeyboardItem.builtIn(TerminalKeyboardAction.snippets),
  TerminalKeyboardItem.builtIn(TerminalKeyboardAction.touchMode),
  TerminalKeyboardItem.builtIn(TerminalKeyboardAction.fullscreen),
];

const tmuxTerminalKeyboardItems = [
  TerminalKeyboardItem.builtIn(TerminalKeyboardAction.tmuxPrefix),
  TerminalKeyboardItem.builtIn(TerminalKeyboardAction.tmuxScrollback),
  TerminalKeyboardItem.builtIn(TerminalKeyboardAction.tmuxMenu),
];

const terminalKeyboardRowHeightDefault = 50.0;
const terminalKeyboardRowHeightMin = 40.0;
const terminalKeyboardRowHeightMax = 80.0;

double clampTerminalKeyboardRowHeight(double height) {
  return height.clamp(
    terminalKeyboardRowHeightMin,
    terminalKeyboardRowHeightMax,
  );
}

class TerminalKeyboardRow {
  const TerminalKeyboardRow({
    required this.items,
    this.height = terminalKeyboardRowHeightDefault,
  });

  final List<TerminalKeyboardItem> items;
  final double height;

  TerminalKeyboardRow copyWith({
    List<TerminalKeyboardItem>? items,
    double? height,
  }) {
    return TerminalKeyboardRow(
      items: items ?? this.items,
      height: height ?? this.height,
    );
  }

  @override
  bool operator ==(Object other) {
    if (other is! TerminalKeyboardRow ||
        other.height != height ||
        other.items.length != items.length) {
      return false;
    }
    for (var index = 0; index < items.length; index += 1) {
      if (other.items[index] != items[index]) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(height, Object.hashAll(items));
}

const defaultTerminalKeyboardRows = [
  TerminalKeyboardRow(items: defaultTerminalKeyboardItems),
];

const terminalKeyboardControlKeys = [
  'A',
  'B',
  'C',
  'D',
  'E',
  'F',
  'G',
  'H',
  'I',
  'J',
  'K',
  'L',
  'M',
  'N',
  'O',
  'P',
  'Q',
  'R',
  'S',
  'T',
  'U',
  'V',
  'W',
  'X',
  'Y',
  'Z',
];

extension TerminalKeyboardActionDetails on TerminalKeyboardAction {
  String get label => switch (this) {
    TerminalKeyboardAction.escape => 'Esc',
    TerminalKeyboardAction.control => 'Ctrl',
    TerminalKeyboardAction.alt => 'Alt',
    TerminalKeyboardAction.tab => 'Tab',
    TerminalKeyboardAction.fullscreen => 'Full',
    TerminalKeyboardAction.arrowUp => 'Up',
    TerminalKeyboardAction.arrowDown => 'Down',
    TerminalKeyboardAction.arrowLeft => 'Left',
    TerminalKeyboardAction.arrowRight => 'Right',
    TerminalKeyboardAction.home => 'Home',
    TerminalKeyboardAction.end => 'End',
    TerminalKeyboardAction.pageUp => 'PgUp',
    TerminalKeyboardAction.pageDown => 'PgDn',
    TerminalKeyboardAction.controlC => '^C',
    TerminalKeyboardAction.controlD => '^D',
    TerminalKeyboardAction.controlZ => '^Z',
    TerminalKeyboardAction.controlL => '^L',
    TerminalKeyboardAction.colon => ':',
    TerminalKeyboardAction.slash => '/',
    TerminalKeyboardAction.pipe => '|',
    TerminalKeyboardAction.dash => '-',
    TerminalKeyboardAction.paste => 'Paste',
    TerminalKeyboardAction.functionKeys => 'Fn',
    TerminalKeyboardAction.tmuxPrefix => 'Tmux',
    TerminalKeyboardAction.tmuxScrollback => 'Scroll',
    TerminalKeyboardAction.tmuxMenu => 'Tmux+',
    TerminalKeyboardAction.herdrMenu => 'Herdr',
    TerminalKeyboardAction.snippets => 'Snip',
    TerminalKeyboardAction.touchMode => 'Touch',
    TerminalKeyboardAction.compose => 'Chat',
  };
}

/// [rows] as stored before CON-106: the old default (one row of
/// [preChatDefaultTerminalKeyboardItems] at the default height) becomes
/// [defaultTerminalKeyboardRows]; rows the user changed stay as they are.
List<TerminalKeyboardRow> migratePreChatKeyboardRows(
  List<TerminalKeyboardRow> rows,
) {
  const legacy = TerminalKeyboardRow(
    items: preChatDefaultTerminalKeyboardItems,
  );
  return rows.length == 1 && rows.single == legacy
      ? defaultTerminalKeyboardRows
      : rows;
}
