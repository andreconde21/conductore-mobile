# conduit_vt (vendored)

A copy of the `conduit_vt` package (MIT, see `LICENSE`) taken from
<https://github.com/gwitko/conduit_vt> at commit
`b486b894ea12b18b2ad76339ccd8c6ae3c12416f`, which itself is a fork of
<https://github.com/TerminalStudio/xterm.dart>. Only `lib/`, `LICENSE`,
`CHANGELOG.md`, `analysis_options.yaml` and `pubspec.yaml` were copied; the
upstream tests, examples and media stay upstream.

It is vendored because we cannot push to that fork, and making the desktop
terminal feel native (CON-059) needs changes inside the renderer, which the
package keeps private.

## Local patch

The desktop terminal renderer (CON-059). The exact diff against the origin
commit is the git history of this directory after the commit that added the
pristine copy.

- `TerminalPainter` places the cell grid on whole device pixels (the
  `devicePixelRatio` the view passes down): cell width and height, line tops
  and glyph origins, so text stays sharp at 1x, 2x and fractional scales.
- `RenderTerminal` shifts its paint origin onto the window's pixel grid and
  keeps recorded pictures of lines (`LinePictureCache`): a line is drawn
  directly the first time and recorded when it is painted again unchanged,
  so scrolling and repaints replay it instead of drawing every cell.
- A recorded line merges backgrounds into one rectangle per colour run and
  draws printable ASCII of one style as one paragraph per run, letter-spaced
  onto the grid (`debugDisableGlyphRuns` turns this off for comparisons).
- `TerminalStyle` has value equality, so an equal style from a rebuild keeps
  the caches; the text input caret rect is sent once per frame, when it moved.

Keyboard (CON-094): when the soft keyboard grows (each frame of its
slide-in) the view goes back to the terminal's bottom, focused or not, and
so does focus arriving while the keyboard is already up; a keyboard sliding
out no longer counts as a show, so scrollback being read stays put.
