'use strict'

// tmux location lookup (CON-071): tmux 3.3+ prints the format's tabs as `_`
// when it thinks the client is not UTF-8 (LANG unset or C, as under systemd
// or in a minimal container), which broke `send` and the location. The
// lines below are what tmux 3.3a and 3.4 printed in Docker for FORMAT, with
// and without `-u`. A fake tmux on PATH checks the daemon passes `-u`.

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('fs')
const path = require('path')
const { tempDir, cleanup } = require('./helpers/cleanup')
const context = require('../lib/context')

test.after(cleanup)

const TABS = '%0\t10\t0\tmy_sess\tw name\t/home/me/my_proj\n'
const MANGLED = '%0_10_0_my_sess_w name_/home/me/my_proj\n'

test('the format leads with the fixed-shape fields', () => {
  assert.match(context.FORMAT, /^#\{pane_id\}\t#\{pane_pid\}\t#\{window_index\}\t/)
})

test('parses the tab-separated line (UTF-8 client or -u)', () => {
  assert.deepEqual(context.parseTmuxContext(TABS, '/tmp/tmux-0/default'), {
    session: 'my_sess', window: 0, paneId: '%0', currentPath: '/home/me/my_proj', windowName: 'w name', socket: '/tmp/tmux-0/default', panePid: 10
  })
})

test('a tab in the path stays in the path', () => {
  assert.equal(context.parseTmuxContext('%3\t7\t2\ts\tw\t/a\tb\n').currentPath, '/a\tb')
})

test('a tab-mangled line still yields the pane, its process and window', () => {
  assert.deepEqual(context.parseTmuxContext(MANGLED, null), {
    session: null, window: 0, paneId: '%0', currentPath: null, windowName: null, socket: null, panePid: 10
  })
})

test('garbage is no context', () => {
  assert.equal(context.parseTmuxContext('no server running on /tmp/x\n'), null)
  assert.equal(context.parseTmuxContext(''), null)
})

test('tmuxContext passes -u, so tabs survive a C locale', async t => {
  const dir = tempDir('conductore-context-')
  // Behaves like tmux 3.3+ in a C locale: tabs become `_` unless -u.
  fs.writeFileSync(path.join(dir, 'tabs.out'), TABS)
  fs.writeFileSync(path.join(dir, 'mangled.out'), MANGLED)
  fs.writeFileSync(path.join(dir, 'tmux'), `#!/bin/sh
echo "$@" > "${dir}/args"
case " $* " in
  *" -u "*) cat "${dir}/tabs.out" ;;
  *) cat "${dir}/mangled.out" ;;
esac
`, { mode: 0o755 })
  const oldPath = process.env.PATH
  process.env.PATH = `${dir}:${oldPath}`
  t.after(() => { process.env.PATH = oldPath; context._reset() })
  context._reset()
  const value = await context.tmuxContext({ tmux: '/tmp/fake-sock,123,0', tmux_pane: '%0' })
  assert.match(fs.readFileSync(path.join(dir, 'args'), 'utf8'), /^-u -S \/tmp\/fake-sock display-message -p -t %0 /)
  assert.equal(value.paneId, '%0')
  assert.equal(value.panePid, 10)
  assert.equal(value.session, 'my_sess')
  assert.equal(value.windowName, 'w name')
})
