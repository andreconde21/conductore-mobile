/// Detects interactive choice prompts on the visible terminal screen so they
/// can be answered with buttons instead of typed keys.
///
/// Recognized layouts:
///
/// * Claude Code selection menus, numbered and arrow-driven, where the
///   highlighted option carries a `❯` pointer:
///
///   ```
///   Do you want to proceed?
///   ❯ 1. Yes
///     2. Yes, and don't ask again for git status commands in /srv/app
///     3. No, and tell Claude what to do differently (esc)
///   ```
///
/// * Arrow-driven select lists without numbers (`❯ Option`), when a question
///   or a key-hint footer confirms they are interactive.
/// * Plain numbered prompts read from stdin (`bash select`, installers):
///   `1) foo  2) bar  #? ` or `Enter choice [1-3]: `.
/// * Yes/no questions on the input line: `[y/n]`, `(Y/n)`, `(yes/no)`.
///
/// Detection is deliberately conservative. A numbered list on its own is not
/// a menu: it also needs a question above it, a selection pointer, a key-hint
/// footer, or an input line below asking for the choice. Everything must sit
/// near the bottom of the screen, where an interactive prompt would be.
library;

/// How the terminal application expects the answer to be delivered.
enum PromptMenuInput {
  /// A single digit selects immediately (Claude Code menus).
  digit,

  /// The digit is typed and confirmed with Enter (`read`, `bash select`).
  digitEnter,

  /// The highlight is moved with arrow keys and confirmed with Enter.
  arrows,

  /// The answer word (`y`, `yes`, ...) is typed and confirmed with Enter.
  word,
}

/// A keystroke the strip sends to the terminal. Kept free of package types so
/// the detector stays a pure function over text.
sealed class PromptMenuKeystroke {
  const PromptMenuKeystroke();
}

class PromptMenuText extends PromptMenuKeystroke {
  const PromptMenuText(this.text);

  final String text;

  @override
  bool operator ==(Object other) =>
      other is PromptMenuText && other.text == text;

  @override
  int get hashCode => text.hashCode;

  @override
  String toString() => 'PromptMenuText($text)';
}

enum PromptMenuKey implements PromptMenuKeystroke {
  enter,
  arrowUp,
  arrowDown,
  escape,
}

class PromptMenuOption {
  const PromptMenuOption({
    required this.index,
    required this.label,
    required this.text,
    this.selected = false,
  });

  /// Zero-based position in the menu.
  final int index;

  /// Short button caption: the option's first line without the `(esc)` hint.
  final String label;

  /// Full option text including description lines.
  final String text;

  /// Whether the menu currently highlights this option.
  final bool selected;

  @override
  bool operator ==(Object other) =>
      other is PromptMenuOption &&
      other.index == index &&
      other.label == label &&
      other.text == text &&
      other.selected == selected;

  @override
  int get hashCode => Object.hash(index, label, text, selected);

  @override
  String toString() =>
      'PromptMenuOption(#$index, "$label"${selected ? ', selected' : ''})';
}

class PromptMenu {
  const PromptMenu({
    required this.options,
    required this.input,
    this.question,
    this.hasEscape = false,
    this.answers = const [],
  });

  final List<PromptMenuOption> options;
  final PromptMenuInput input;

  /// The question or instruction line above the choices, when one was found.
  final String? question;

  /// Whether the prompt advertises Esc as a way out.
  final bool hasEscape;

  /// For [PromptMenuInput.word] menus, the word to type for each option.
  final List<String> answers;

  int? get selectedIndex {
    for (final option in options) {
      if (option.selected) {
        return option.index;
      }
    }
    return null;
  }

  /// Keystrokes that pick [option].
  List<PromptMenuKeystroke> keystrokesFor(PromptMenuOption option) {
    switch (input) {
      case PromptMenuInput.digit:
        return [PromptMenuText('${option.index + 1}')];
      case PromptMenuInput.digitEnter:
        return [PromptMenuText('${option.index + 1}'), PromptMenuKey.enter];
      case PromptMenuInput.word:
        return [PromptMenuText(answers[option.index]), PromptMenuKey.enter];
      case PromptMenuInput.arrows:
        final from = selectedIndex ?? 0;
        final delta = option.index - from;
        return [
          for (var i = 0; i < delta.abs(); i++)
            delta > 0 ? PromptMenuKey.arrowDown : PromptMenuKey.arrowUp,
          PromptMenuKey.enter,
        ];
    }
  }

  @override
  bool operator ==(Object other) =>
      other is PromptMenu &&
      other.input == input &&
      other.question == question &&
      other.hasEscape == hasEscape &&
      _listEquals(other.options, options) &&
      _listEquals(other.answers, answers);

  @override
  int get hashCode =>
      Object.hash(input, question, hasEscape, Object.hashAll(options));

  @override
  String toString() =>
      'PromptMenu($input, question: $question, options: $options, '
      'esc: $hasEscape)';
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) {
    return false;
  }
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}

/// Looks for a choice prompt in [rows], the visible screen top to bottom.
///
/// [cursorRow] is the row holding the cursor, or null when unknown; the last
/// non-blank row stands in for it.
PromptMenu? detectPromptMenu(List<String> rows, {int? cursorRow}) {
  final screen = _Screen(rows, cursorRow);
  if (screen.lastContentRow < 0) {
    return null;
  }
  return _detectNumberedMenu(screen) ??
      _detectPointerList(screen) ??
      _detectYesNo(screen);
}

const _maxRowsAboveBottom = 16;
const _maxOptions = 12;
const _maxContinuationRows = 3;
const _questionLookback = 5;
const _footerLookahead = 4;
const _labelMaxLength = 48;

/// Pointer glyphs used by Ink, inquirer, and friends for the highlighted row.
const _pointers = '❯›▸▶●◉';

final _numberedOption = RegExp(
  '^(?<pointer>[$_pointers>])?[ \\t]*(?<number>\\d{1,2})[.)][ \\t]+(?<text>\\S.*)\$',
);
final _pointerOption = RegExp(
  '^(?<pointer>[$_pointers])[ \\t]+(?<text>\\S.*)\$',
);
final _questionMark = RegExp(r'\?\s*$');
final _questionWords = RegExp(
  r'\b(select|choose|pick|which|make a selection|your choice|'
  r'enter (a |the |your )?(number|choice|selection|option))\b.*[:?]\s*$',
  caseSensitive: false,
);
final _inputLineWords = RegExp(
  r'(^#\?|\b(choice|choose|selection|select|option|number|enter|answer|pick)\b'
  r'[^:?>]*[:?>])\s*\S*$',
  caseSensitive: false,
);
final _inputLineRange = RegExp(
  r'[\[(]\s*\d+\s*[-/,]\s*\d+\s*[\])]\s*:?\s*\S*$',
);
final _footerHint = RegExp(
  r'(enter to (select|confirm|approve|continue|submit)|esc to |↑/↓|↑↓|'
  r'arrow keys|to navigate)',
  caseSensitive: false,
);
final _escapeHint = RegExp(r'\b(esc|escape)\b', caseSensitive: false);
final _escapeSuffix = RegExp(r'\s*\((esc|escape)\)\s*$', caseSensitive: false);
final _yesNo = RegExp(
  r'[\[(]\s*(?<yes>y|yes)\s*/\s*(?<no>n|no)(\s*/\s*\[?fingerprint\]?)?\s*[\])]'
  r'\s*[:?]?\s*$',
  caseSensitive: false,
);
final _whitespace = RegExp(r'\s+');
const _boxEdges = '│┃║';
final _boxRule = RegExp(r'^[─━═╭╮╰╯┌┐└┘├┤┬┴┼┏┓┗┛╔╗╚╝╠╣\s]+$');

class _Screen {
  _Screen(List<String> rows, int? cursorRow)
    : rows = [for (final row in rows) _stripBox(row)],
      lastContentRow = _lastContentRow(rows) {
    this.cursorRow =
        cursorRow != null && cursorRow >= 0 && cursorRow < rows.length
        ? cursorRow
        : lastContentRow;
  }

  final List<String> rows;
  final int lastContentRow;
  late final int cursorRow;

  String trimmed(int row) => rows[row].trim();

  bool isBlank(int row) => trimmed(row).isEmpty;

  int indentOf(int row) => rows[row].length - rows[row].trimLeft().length;

  static String _stripBox(String row) {
    // Ink boxes wrap the prompt in │ ... │. Drop the edges but keep the
    // inner indentation, which tells option lines from descriptions.
    var text = row.trimRight();
    final inner = text.trimLeft();
    if (inner.isEmpty || _boxRule.hasMatch(inner)) {
      return '';
    }
    if (_boxEdges.contains(inner[0])) {
      text = inner.substring(1);
    }
    // A row that is only a box edge (a lone │, e.g. a pane border) is
    // empty once the edge is gone.
    if (text.isEmpty) {
      return '';
    }
    if (_boxEdges.contains(text[text.length - 1])) {
      text = text.substring(0, text.length - 1).trimRight();
    }
    return text;
  }

  static int _lastContentRow(List<String> rows) {
    for (var row = rows.length - 1; row >= 0; row--) {
      final text = _stripBox(rows[row]);
      if (text.trim().isNotEmpty) {
        return row;
      }
    }
    return -1;
  }
}

class _OptionLine {
  const _OptionLine({
    required this.row,
    required this.text,
    required this.textColumn,
    required this.pointed,
    required this.chevron,
  });

  final int row;
  final String text;

  /// Column where the option text starts; description rows indent past it.
  final int textColumn;

  /// Highlighted with a proper pointer glyph.
  final bool pointed;

  /// Highlighted with a plain `>`, which also opens quotes and prompts, so it
  /// only counts alongside stronger evidence.
  final bool chevron;
}

class _Block {
  _Block(this.lines, this.descriptions);

  final List<_OptionLine> lines;

  /// Description rows keyed by option position.
  final Map<int, List<String>> descriptions;

  int get first => lines.first.row;
  int get last {
    final tail = descriptions[lines.length - 1];
    return lines.last.row + (tail?.length ?? 0);
  }

  bool get pointed => lines.any((line) => line.pointed);
  bool get chevron => lines.any((line) => line.chevron);
}

PromptMenu? _detectNumberedMenu(_Screen screen) {
  final block = _findNumberedBlock(screen);
  if (block == null) {
    return null;
  }
  final question = _questionAbove(screen, block.first);
  final footer = _footerBelow(screen, block.last);
  final inputLine = _inputLineBelow(screen, block.last);
  final marked = block.pointed || (block.chevron && question != null);
  if (!marked && question == null && footer == null && inputLine == null) {
    return null;
  }
  final input = marked ? PromptMenuInput.digit : PromptMenuInput.digitEnter;
  return PromptMenu(
    options: _optionsFrom(block),
    input: input,
    question: question,
    hasEscape: _mentionsEscape(screen, block, footer),
  );
}

PromptMenu? _detectPointerList(_Screen screen) {
  final block = _findPointerBlock(screen);
  if (block == null) {
    return null;
  }
  final question = _questionAbove(screen, block.first);
  final footer = _footerBelow(screen, block.last);
  if (question == null && footer == null) {
    return null;
  }
  return PromptMenu(
    options: _optionsFrom(block),
    input: PromptMenuInput.arrows,
    question: question,
    hasEscape: _mentionsEscape(screen, block, footer),
  );
}

PromptMenu? _detectYesNo(_Screen screen) {
  for (final row in {screen.cursorRow, screen.lastContentRow}) {
    if (row < 0) {
      continue;
    }
    final text = screen.trimmed(row);
    final match = _yesNo.firstMatch(text);
    if (match == null) {
      continue;
    }
    final yes = match.namedGroup('yes')!;
    final no = match.namedGroup('no')!;
    final question = text.substring(0, match.start).trim();
    return PromptMenu(
      options: [
        PromptMenuOption(
          index: 0,
          label: 'Yes',
          text: yes,
          selected: yes == yes.toUpperCase(),
        ),
        PromptMenuOption(
          index: 1,
          label: 'No',
          text: no,
          selected: no == no.toUpperCase(),
        ),
      ],
      input: PromptMenuInput.word,
      question: question.isEmpty ? null : question,
      answers: [yes.toLowerCase(), no.toLowerCase()],
    );
  }
  return null;
}

/// Finds the numbered block closest to the bottom of the screen: options
/// 1..n on consecutive rows, each allowed a few more-indented description
/// rows, with at most one blank row between options.
_Block? _findNumberedBlock(_Screen screen) {
  final floor = screen.lastContentRow - _maxRowsAboveBottom;
  _Block? best;
  for (var row = 0; row <= screen.lastContentRow; row++) {
    final line = _numberedLineAt(screen, row, expected: 1);
    if (line == null) {
      continue;
    }
    final block = _extendBlock(
      screen,
      line,
      next: (row, expected) => _numberedLineAt(screen, row, expected: expected),
    );
    if (block != null && block.last >= floor) {
      best = block;
    }
    if (block != null) {
      row = block.last;
    }
  }
  return best;
}

_Block? _findPointerBlock(_Screen screen) {
  final floor = screen.lastContentRow - _maxRowsAboveBottom;
  _Block? best;
  for (var row = 0; row <= screen.lastContentRow; row++) {
    final pointed = _pointerLineAt(screen, row, column: null);
    if (pointed == null) {
      continue;
    }
    // The highlight can sit anywhere in the list: siblings above it are
    // plain rows indented to the same column.
    final column = pointed.textColumn;
    var start = row;
    while (start > 0 &&
        !screen.isBlank(start - 1) &&
        screen.indentOf(start - 1) >= column) {
      start--;
    }
    // Start at the first row that is an option at this column. A deeper
    // pointer row indented to the column is not one; [row] itself always is.
    var first = _pointerLineAt(screen, start, column: column);
    while (first == null) {
      start++;
      first = _pointerLineAt(screen, start, column: column);
    }
    final block = _extendBlock(
      screen,
      first,
      next: (row, _) => _pointerLineAt(screen, row, column: column),
    );
    // A single highlighted row is only a pointer when there is exactly one.
    if (block != null &&
        block.last >= floor &&
        block.lines.where((line) => line.pointed).length == 1) {
      best = block;
    }
    if (block != null) {
      row = block.last;
    }
  }
  return best;
}

_Block? _extendBlock(
  _Screen screen,
  _OptionLine first, {
  required _OptionLine? Function(int row, int expected) next,
}) {
  final lines = [first];
  final descriptions = <int, List<String>>{};
  var row = first.row + 1;
  var blankPending = false;
  while (row <= screen.lastContentRow && lines.length < _maxOptions) {
    if (screen.isBlank(row)) {
      if (blankPending) {
        break;
      }
      blankPending = true;
      row++;
      continue;
    }
    final option = next(row, lines.length + 1);
    if (option != null) {
      lines.add(option);
      blankPending = false;
      row++;
      continue;
    }
    if (blankPending) {
      break;
    }
    final current = lines.last;
    final description = descriptions.putIfAbsent(lines.length - 1, () => []);
    if (screen.indentOf(row) >= current.textColumn &&
        description.length < _maxContinuationRows) {
      description.add(screen.trimmed(row));
      row++;
      continue;
    }
    break;
  }
  if (lines.length < 2) {
    return null;
  }
  return _Block(lines, descriptions);
}

_OptionLine? _numberedLineAt(_Screen screen, int row, {required int expected}) {
  final text = screen.rows[row];
  final indent = screen.indentOf(row);
  final match = _numberedOption.firstMatch(text.substring(indent));
  if (match == null || int.parse(match.namedGroup('number')!) != expected) {
    return null;
  }
  final pointer = match.namedGroup('pointer');
  final optionText = match.namedGroup('text')!;
  return _OptionLine(
    row: row,
    text: optionText,
    textColumn:
        indent + match.start + (match.group(0)!.length - optionText.length),
    pointed: pointer != null && pointer != '>',
    chevron: pointer == '>',
  );
}

/// Matches a pointer row, or a row indented to [column] as an unhighlighted
/// sibling of one.
_OptionLine? _pointerLineAt(_Screen screen, int row, {required int? column}) {
  final text = screen.rows[row];
  final indent = screen.indentOf(row);
  final match = _pointerOption.firstMatch(text.substring(indent));
  if (match != null) {
    final optionText = match.namedGroup('text')!;
    final textColumn = indent + match.group(0)!.length - optionText.length;
    if (column != null && textColumn != column) {
      return null;
    }
    return _OptionLine(
      row: row,
      text: optionText,
      textColumn: textColumn,
      pointed: true,
      chevron: false,
    );
  }
  if (column == null || indent != column) {
    return null;
  }
  return _OptionLine(
    row: row,
    text: text.substring(indent),
    textColumn: column,
    pointed: false,
    chevron: false,
  );
}

List<PromptMenuOption> _optionsFrom(_Block block) {
  return [
    for (var i = 0; i < block.lines.length; i++)
      PromptMenuOption(
        index: i,
        label: _labelFor(block.lines[i].text),
        text: [
          block.lines[i].text,
          ...?block.descriptions[i],
        ].join(' ').replaceAll(_whitespace, ' ').trim(),
        selected: block.lines[i].pointed || block.lines[i].chevron,
      ),
  ];
}

String _labelFor(String text) {
  final label = text
      .replaceAll(_escapeSuffix, '')
      .replaceAll(_whitespace, ' ')
      .trim();
  if (label.length <= _labelMaxLength) {
    return label;
  }
  var cut = label.lastIndexOf(' ', _labelMaxLength - 1);
  if (cut < _labelMaxLength ~/ 2) {
    cut = _labelMaxLength - 1;
  }
  return '${label.substring(0, cut).trimRight()}…';
}

String? _questionAbove(_Screen screen, int firstRow) {
  var looked = 0;
  for (var row = firstRow - 1; row >= 0 && looked < _questionLookback; row--) {
    if (screen.isBlank(row)) {
      continue;
    }
    looked++;
    final text = screen.trimmed(row);
    if (_questionMark.hasMatch(text) || _questionWords.hasMatch(text)) {
      return text;
    }
  }
  return null;
}

String? _footerBelow(_Screen screen, int lastRow) {
  final end = (lastRow + _footerLookahead).clamp(0, screen.rows.length - 1);
  for (var row = lastRow + 1; row <= end; row++) {
    final text = screen.trimmed(row);
    if (_footerHint.hasMatch(text)) {
      return text;
    }
  }
  return null;
}

/// The input line that collects a typed choice: the cursor row just below
/// the options, asking for a number.
String? _inputLineBelow(_Screen screen, int lastRow) {
  final row = screen.cursorRow;
  if (row <= lastRow || row > lastRow + _footerLookahead) {
    return null;
  }
  final text = screen.trimmed(row);
  if (_inputLineWords.hasMatch(text) || _inputLineRange.hasMatch(text)) {
    return text;
  }
  return null;
}

bool _mentionsEscape(_Screen screen, _Block block, String? footer) {
  if (footer != null && _escapeHint.hasMatch(footer)) {
    return true;
  }
  for (final line in block.lines) {
    if (_escapeHint.hasMatch(line.text)) {
      return true;
    }
  }
  for (final description in block.descriptions.values) {
    if (description.any(_escapeHint.hasMatch)) {
      return true;
    }
  }
  return false;
}
