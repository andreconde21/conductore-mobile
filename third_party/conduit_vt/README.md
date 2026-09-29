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

The diff against the origin commit is the git history of this directory
after the commit that added the pristine copy.
