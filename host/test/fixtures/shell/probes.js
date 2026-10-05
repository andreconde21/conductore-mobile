'use strict'

// Command lines the parser must split exactly as bash does. Every segment
// is `printf '%s\0' @@ <words>`: bash prints each word NUL-terminated after
// an `@@` marker, so its real word splitting can be recorded without
// running anything else (generate-bash-words.js, in a container with no
// network). Only `;`, `&&` and newlines join segments here, so every
// segment runs.

const P = "printf '%s\\0' @@"

const ARGS = [
  'a b c',
  'a"b"\'c\'',
  '"a\\b"',
  '"a\\$b"',
  '"a\\"b"',
  '"a\\\\b"',
  '"a\\`b"',
  "'a\\b'",
  'a\\ b',
  "\\'",
  "\"'\"",
  "'\"'",
  'a#b',
  'a #b c',
  '"#" x',
  'a\\#b',
  '--opt="x y"',
  "--opt='x y'",
  "'' x",
  '"" x',
  "a''b",
  '"a"\'b\'c',
  '\\\\',
  '"\\\\"',
  'x=1 y==2',
  '{} {x} @{u}',
  'a,b',
  'a!b',
  '% ^ + : ,',
  '\'it\'\\\'\'s\'',
  'a\t\tb',
  'if then fi do done',
  '{ } ! -- -',
  '"$" a$ "a$" \'$\' $',
  '\\$HOME "\\$HOME" \'$HOME\'',
  '"a;b" a\\;b \'a|b\' a\\|b "a&b" a\\&b',
  '">" "<" \\> \\<',
  'a 2>&1',
  'a 3>&1 b',
  '*.nomatch [x].nomatch ?.nomatch',
  '"*" \'?\' \\*',
  '"(" \')\' \\( \\)',
  '"a\nb"',
  "'a\nb'",
  '"\\n" \'\\n\'',
  'é "ü" \'ñ\''
]

const JOINED = [
  `${P} a; ${P} b`,
  `${P} a;${P} b`,
  `${P} a && ${P} b`,
  `${P} a&&${P} b`,
  `${P} a\n${P} b`,
  `${P} a\n\n${P} b`,
  `${P} a &&\n${P} b`,
  `${P} a;#${P} hidden\n${P} b`,
  `${P} a # ; ${P} hidden\n${P} b`,
  `${P} "a; ${P} b"`,
  `${P} 'a && ${P} b'`,
  `${P} a\\; ${P} b`,
  `CI=1 ${P} a`,
  `FORCE_COLOR=0 NO_COLOR=1 ${P} a`
]

module.exports = [...ARGS.map(a => `${P} ${a}`), ...JOINED]
