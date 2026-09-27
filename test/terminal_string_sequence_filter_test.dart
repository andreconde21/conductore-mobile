import 'package:conduit/features/terminal/domain/terminal_string_sequence_filter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const esc = '\x1b';

  group('TerminalStringSequenceFilter', () {
    test('passes normal text and CSI/OSC sequences through untouched', () {
      final filter = TerminalStringSequenceFilter();
      const input = 'hello $esc[31mred$esc[0m $esc]0;title\x07 done';
      expect(filter.process(input), input);
    });

    test('output without ESC passes through as the same string', () {
      final filter = TerminalStringSequenceFilter();
      const plain = 'build ok\r\nnext line ✓\r\n';
      expect(identical(filter.process(plain), plain), isTrue);
      // Also right after a stripped sequence ended.
      expect(filter.process('a${esc}P+q$esc\\b'), 'ab');
      expect(identical(filter.process(plain), plain), isTrue);
    });

    test('strips the vim XTGETTCAP DCS probe (+q4D73) entirely', () {
      final filter = TerminalStringSequenceFilter();
      const input =
          'before$esc'
          'P+q4D73$esc\\after';
      expect(filter.process(input), 'beforeafter');
    });

    test('strips DCS terminated by the 8-bit ST', () {
      final filter = TerminalStringSequenceFilter();
      expect(filter.process('a${esc}P+q4D73\x9cb'), 'ab');
    });

    test('strips SOS, PM and APC sequences too', () {
      final filter = TerminalStringSequenceFilter();
      expect(filter.process('x${esc}Xsos$esc\\y'), 'xy');
      expect(filter.process('x$esc^pm$esc\\y'), 'xy');
      expect(filter.process('x${esc}_apc$esc\\y'), 'xy');
    });

    test('handles a sequence split across chunks', () {
      final filter = TerminalStringSequenceFilter();
      final out = StringBuffer()
        ..write(filter.process('start$esc'))
        ..write(filter.process('P+q4D'))
        ..write(filter.process('73$esc'))
        ..write(filter.process('\\end'));
      expect(out.toString(), 'startend');
    });

    test('a stray ESC P does not swallow the output after it', () {
      final filter = TerminalStringSequenceFilter();
      // `cat` of a binary: ESC P, then a prompt with colours.
      expect(
        filter.process('junk ${esc}P more\r\n$esc[32muser\$ $esc[0m'),
        'junk $esc[32muser\$ $esc[0m',
      );
      expect(filter.process('still here'), 'still here');
    });

    test('CAN and SUB cancel a string sequence', () {
      final filter = TerminalStringSequenceFilter();
      expect(filter.process('a${esc}Pjunk\x18b'), 'ab');
      expect(filter.process('a${esc}_junk\x1ab'), 'ab');
    });

    test('ESC followed by another introducer starts a new string', () {
      final filter = TerminalStringSequenceFilter();
      expect(filter.process('a${esc}Pone${esc}Ptwo$esc\\b'), 'ab');
    });

    test('a doubled ESC (tmux passthrough) stays inside the string', () {
      final filter = TerminalStringSequenceFilter();
      expect(
        filter.process('a${esc}Ptmux;$esc$esc]52;c;aGk=\x07$esc\\b'),
        'ab',
      );
    });

    test('stops dropping after the length cap', () {
      final filter = TerminalStringSequenceFilter();
      final long = 'x' * TerminalStringSequenceFilter.maxStrippedLength;
      expect(filter.process('${esc}P$long'), '');
      expect(filter.process('shown'), 'shown');
    });

    test('leaves a lone escape sequence (not a string sequence) intact', () {
      final filter = TerminalStringSequenceFilter();
      expect(filter.process('${esc}c'), '${esc}c');
    });
  });
}
