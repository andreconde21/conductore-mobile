'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('fs')
const path = require('path')
const { tempDir, cleanup } = require('./helpers/cleanup')
const ports = require('../lib/ports')

const SS = [
  'LISTEN 0      511        127.0.0.1:5173       0.0.0.0:*    users:(("node",pid=4242,fd=23))',
  'LISTEN 0      128          0.0.0.0:22         0.0.0.0:*',
  'LISTEN 0      4096   127.0.0.53%lo:53         0.0.0.0:*',
  'LISTEN 0      511             [::1]:5173         [::]:*    users:(("node",pid=4242,fd=24))',
  'LISTEN 0      4096               *:8080             *:*    users:(("docker-proxy",pid=900,fd=4))',
  'LISTEN 0      511          0.0.0.0:3000       0.0.0.0:*',
  'LISTEN 0      10         127.0.0.1:41234      0.0.0.0:*    users:(("node",pid=5000,fd=30))',
  '0      511        127.0.0.1:8000       0.0.0.0:*    users:(("python3",pid=6000,fd=3))'
].join('\n')

const PROC = {
  4242: { cwd: '/home/u/app', cmdline: 'node\0/home/u/app/node_modules/.bin/vite\0--port\u00005173\0', uid: 1000 },
  5000: { cwd: '/home/u', cmdline: 'node\0/home/u/.vscode-server/bin/x/out/server.js\0', uid: 1000 },
  6000: { cwd: '/home/u/site', cmdline: 'python3\0-m\0http.server\u00008000\0', uid: 1000 },
  900: { cwd: '/', cmdline: '/usr/bin/docker-proxy\0-proto\0tcp\0', uid: 0 }
}

const scanOpts = (ssText = SS, proc = PROC) => ({
  runCmd: async cmd => (cmd === 'ss' ? ssText : null),
  readFile: p => {
    const m = /^\/proc\/(\d+)\/(cmdline|status)$/.exec(p)
    if (!m || !proc[m[1]]) throw new Error('ENOENT')
    return m[2] === 'cmdline' ? proc[m[1]].cmdline : `Name:\tx\nUid:\t${proc[m[1]].uid}\t${proc[m[1]].uid}\n`
  },
  readlink: p => {
    const m = /^\/proc\/(\d+)\/cwd$/.exec(p)
    if (!m || !proc[m[1]]) throw new Error('ENOENT')
    return proc[m[1]].cwd
  }
})

const tmpFile = () => path.join(tempDir('cports-'), 'ports.json')

test('parseSs reads address, port and owner; IPv6 brackets are stripped', () => {
  const rows = ports.parseSs(SS)
  assert.deepEqual(rows[0], { port: 5173, address: '127.0.0.1', process: 'node', pid: 4242 })
  assert.deepEqual(rows[3], { port: 5173, address: '::1', process: 'node', pid: 4242 })
  assert.equal(rows[1].pid, null)
  // A build without the State column still parses.
  assert.equal(rows[7].port, 8000)
})

test('parseLsof reads -F records', () => {
  const rows = ports.parseLsof('p123\ncnode\nn127.0.0.1:5173\nn[::1]:5173\np7\ncpython3\nn*:8000\n')
  assert.deepEqual(rows, [
    { port: 5173, address: '127.0.0.1', process: 'node', pid: 123 },
    { port: 5173, address: '::1', process: 'node', pid: 123 },
    { port: 8000, address: '*', process: 'python3', pid: 7 }
  ])
})

test('parseProcNetTcp keeps LISTEN sockets of the given uid', () => {
  const text = [
    '  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode',
    '   0: 0100007F:1435 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 1',
    '   1: 00000000:0016 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 2',
    '   2: 0100007F:1435 0100007F:9C40 01 00000000:00000000 00:00000000 00000000  1000        0 3'
  ].join('\n')
  assert.deepEqual(ports.parseProcNetTcp(text, 1000), [{ port: 5173, address: '127.0.0.1', process: null, pid: null }])
})

test('labelFor names common dev servers from the command line', () => {
  assert.equal(ports.labelFor('node /x/node_modules/.bin/vite', 'node'), 'vite')
  assert.equal(ports.labelFor('next-server (v14.2.3)', 'node'), 'next')
  assert.equal(ports.labelFor('node /x/node_modules/react-scripts/scripts/start.js', 'node'), 'create-react-app')
  assert.equal(ports.labelFor('python3 manage.py runserver', 'python3'), 'django')
  assert.equal(ports.labelFor('/usr/bin/syncthing serve --no-browser', 'syncthing'), 'syncthing')
  assert.equal(ports.labelFor(null, 'ruby'), 'ruby')
})

test('ports: own dev servers only, with label, cwd and seq', async () => {
  const file = tmpFile()
  const res = await ports.ports({ file, now: 1000, uid: 1000, selfPid: 1, scanOpts: scanOpts() })
  assert.equal(res.source, 'ss')
  assert.equal(res.cached, false)
  // 22/53 are system, 8080 is docker-proxy, 3000 belongs to another user,
  // 41234 is an ephemeral port of something that is not a dev server.
  assert.deepEqual(res.ports.map(p => [p.port, p.label, p.cwd]), [
    [5173, 'vite', '/home/u/app'],
    [8000, 'python http.server', '/home/u/site']
  ])
  assert.equal(res.seq, 2)
  assert.equal(res.ports[0].url, 'http://localhost:5173/')
})

test('ports --since reports only ports that appeared later; a restart is new again', async () => {
  const file = tmpFile()
  const first = await ports.ports({ file, now: 1000, uid: 1000, selfPid: 1, scanOpts: scanOpts() })
  // Nothing changed: nothing new.
  let res = await ports.ports({ file, since: first.seq, now: 5000, uid: 1000, selfPid: 1, scanOpts: scanOpts() })
  assert.deepEqual(res.ports, [])
  // A new server on 4321.
  const withAstro = SS + '\nLISTEN 0 511 127.0.0.1:4321 0.0.0.0:* users:(("node",pid=7000,fd=20))'
  const proc = { ...PROC, 7000: { cwd: '/home/u/blog', cmdline: 'node\0/home/u/blog/node_modules/.bin/astro\0dev\0', uid: 1000 } }
  res = await ports.ports({ file, since: first.seq, now: 9000, uid: 1000, selfPid: 1, scanOpts: scanOpts(withAstro, proc) })
  assert.deepEqual(res.ports.map(p => [p.port, p.label]), [[4321, 'astro']])
  const afterAstro = res.seq
  // Vite restarts under a new pid: new again; astro is not.
  const restarted = withAstro.replace(/pid=4242/g, 'pid=4243')
  const proc2 = { ...proc, 4243: PROC[4242] }
  res = await ports.ports({ file, since: afterAstro, now: 13000, uid: 1000, selfPid: 1, scanOpts: scanOpts(restarted, proc2) })
  assert.deepEqual(res.ports.map(p => p.port), [5173])
})

test('ports serves a fresh result from the file without running ss', async () => {
  const file = tmpFile()
  await ports.ports({ file, now: 1000, uid: 1000, selfPid: 1, scanOpts: scanOpts() })
  let calls = 0
  const res = await ports.ports({ file, now: 1500, uid: 1000, selfPid: 1, scanOpts: { ...scanOpts(), runCmd: async () => { calls++; return '' } } })
  assert.equal(calls, 0)
  assert.equal(res.cached, true)
  assert.equal(res.ports.length, 2)
})

test('ports: root sees other processes but not root-owned 80/443', async () => {
  const file = tmpFile()
  const text = [
    'LISTEN 0 511 0.0.0.0:443 0.0.0.0:* users:(("traefik",pid=10,fd=3))',
    'LISTEN 0 511 0.0.0.0:3000 0.0.0.0:* users:(("node",pid=11,fd=3))'
  ].join('\n')
  const proc = {
    10: { cwd: '/', cmdline: 'traefik', uid: 0 },
    11: { cwd: '/root/app', cmdline: 'node\0server.js', uid: 0 }
  }
  const res = await ports.ports({ file, now: 1000, uid: 0, selfPid: 1, scanOpts: scanOpts(text, proc) })
  assert.deepEqual(res.ports.map(p => p.port), [3000])
})

test('ports falls back to /proc/net/tcp when neither ss nor lsof runs', async () => {
  const file = tmpFile()
  const tcp = 'header\n   0: 0100007F:1435 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 1\n'
  const res = await ports.ports({
    file,
    now: 1000,
    uid: 1000,
    selfPid: 1,
    scanOpts: { runCmd: async () => null, readFile: p => (p === '/proc/net/tcp' ? tcp : ''), readlink: () => { throw new Error('x') } }
  })
  assert.equal(res.source, 'proc')
  assert.deepEqual(res.ports.map(p => p.port), [5173])
})

test('cli: ports rejects a bad --since', async () => {
  const { main } = require('../lib/cli')
  const writes = []
  const orig = process.stdout.write
  process.stdout.write = chunk => { writes.push(String(chunk)); return true }
  try {
    assert.equal(await main(['ports', '--since', 'x']), 1)
  } finally {
    process.stdout.write = orig
  }
  assert.match(writes.join(''), /--since must be a non-negative number/)
})

test.after(() => cleanup())
