'use strict'

// Risk labels for permission requests: low, medium or high, with a one-line
// reason, shown on every approval surface of the phone.
//
//   low     read-only tools and commands (Read, Grep, git status, ls),
//           test and lint runs. The only level "Approve all safe" takes.
//   medium  edits inside the repo, installs, builds, anything unknown.
//   high    recursive deletes, force pushes, `curl | sh`, sudo, writes
//           outside the repo, secrets paths, network to unknown hosts.
//           Never batchable and never answered by a trust rule: it always
//           asks.
//
// classify(toolName, toolInput, ctx) is pure: no fs, no clock. ctx carries
// { cwd, root, home } (root: the repo the agent works in, see rules.js).
// When in doubt it answers higher, never lower.

const path = require('path')
const shell = require('./shell')

const LEVELS = ['low', 'medium', 'high']
const rank = level => LEVELS.indexOf(level)

const r = (level, reason) => ({ level, reason })
// The higher of two; on a tie the one that has a reason.
const max = (a, b) => (rank(b.level) > rank(a.level) || (rank(b.level) === rank(a.level) && !a.reason) ? b : a)

// --- paths --------------------------------------------------------------------

const SECRET_PATTERNS = [
  [/(^|\/)\.env(\.(?!example$|sample$|template$|dist$|defaults?$)[^/]*)?$/, '.env file'],
  [/(^|\/)\.ssh(\/|$)/, 'SSH directory'],
  [/(^|\/)id_(rsa|dsa|ecdsa|ed25519)(\.pub)?$/, 'SSH key'],
  [/\.(pem|p12|pfx|jks|keystore|kdbx|asc|gpg)$/, 'key file'],
  [/(^|\/)[^/]*\.key$/, 'key file'],
  [/(^|\/)\.aws(\/|$)/, 'AWS credentials'],
  [/(^|\/)\.gnupg(\/|$)/, 'GnuPG keyring'],
  [/(^|\/)\.(netrc|git-credentials|npmrc|pypirc|pgpass|my\.cnf)$/, 'credentials file'],
  [/(^|\/)\.kube\/config$/, 'kubeconfig'],
  [/(^|\/)\.docker\/config\.json$/, 'Docker credentials'],
  [/(^|\/)\.config\/gh\/hosts\.yml$/, 'GitHub CLI token'],
  [/(^|\/)(credentials|secrets?)(\.[a-z]+)?$/i, 'credentials file'],
  [/(^|\/)secrets?\//i, 'secrets directory'],
  [/^\/etc\/(shadow|gshadow|sudoers)/, 'system credentials'],
  [/(^|\/)\.conductore(\/|$)/, 'Conductore approval rules']
]

function secretKind (p) {
  if (typeof p !== 'string' || !p) return null
  for (const [re, kind] of SECRET_PATTERNS) if (re.test(p)) return kind
  return null
}

// Absolute, normalized path for a tool's path argument.
function resolvePath (p, ctx) {
  if (typeof p !== 'string' || !p) return null
  let s = p
  if (s === '~' || s.startsWith('~/')) s = path.join(ctx.home || '/nonexistent-home', s.slice(1))
  if (s.startsWith('$HOME/')) s = path.join(ctx.home || '/nonexistent-home', s.slice(5))
  if (!path.isAbsolute(s)) s = path.resolve(ctx.cwd || ctx.root || '/', s)
  return path.normalize(s)
}

function inside (child, parent) {
  if (!child || !parent) return false
  const rel = path.relative(parent, child)
  return rel === '' || (rel !== '..' && !rel.startsWith('../') && !path.isAbsolute(rel))
}

const TEMP_DIRS = ['/tmp', '/var/tmp', '/dev/shm']
const HARMLESS_TARGETS = new Set(['/dev/null', '/dev/stdout', '/dev/stderr', '/dev/tty'])

// Where a write lands: 'repo', 'temp', 'outside', or 'secret'.
function writeTarget (p, ctx) {
  const abs = resolvePath(p, ctx)
  if (!abs) return { where: 'repo', abs }
  if (HARMLESS_TARGETS.has(abs)) return { where: 'none', abs }
  if (secretKind(abs) || secretKind(p)) return { where: 'secret', abs, kind: secretKind(abs) || secretKind(p) }
  if (TEMP_DIRS.some(t => inside(abs, t))) return { where: 'temp', abs }
  const root = ctx.root || ctx.cwd
  if (root && inside(abs, root) && root !== '/' && root !== ctx.home) return { where: 'repo', abs }
  return { where: 'outside', abs }
}

function short (p, ctx) {
  if (typeof p !== 'string') return ''
  const root = ctx.root || ctx.cwd
  const abs = resolvePath(p, ctx)
  if (root && abs && inside(abs, root) && abs !== root) return path.relative(root, abs)
  if (ctx.home && abs && inside(abs, ctx.home)) return '~/' + path.relative(ctx.home, abs)
  return abs || p
}

// --- hosts --------------------------------------------------------------------

// Hosts a coding agent routinely reads from. Anything else is "unknown".
const KNOWN_HOSTS = [
  'github.com', 'api.github.com', 'raw.githubusercontent.com', 'objects.githubusercontent.com', 'gist.githubusercontent.com',
  'gitlab.com', 'bitbucket.org', 'dev.azure.com',
  'registry.npmjs.org', 'www.npmjs.com', 'npmjs.com', 'registry.yarnpkg.com', 'pypi.org', 'files.pythonhosted.org',
  'crates.io', 'static.crates.io', 'docs.rs', 'pkg.go.dev', 'proxy.golang.org', 'rubygems.org', 'pub.dev', 'nuget.org',
  'docs.python.org', 'developer.mozilla.org', 'nodejs.org', 'docs.github.com', 'stackoverflow.com',
  'code.claude.com', 'docs.anthropic.com', 'docs.claude.com', 'anthropic.com', 'www.anthropic.com',
  'api.flutter.dev', 'docs.flutter.dev', 'flutter.dev', 'dart.dev', 'kotlinlang.org', 'developer.android.com',
  'developer.apple.com', 'learn.microsoft.com', 'en.wikipedia.org', 'wikipedia.org', 'mdn.io'
]

// The host a URL (or a bare host[:port][/path]) names, as a URL parser
// reads it (\ counts as /, user info is dropped); null when it is not a
// plain host name or address.
function hostOf (url) {
  if (typeof url !== 'string') return null
  const s = url.trim()
  if (/^[a-z][a-z0-9+.-]*:\/\//i.test(s)) {
    let host
    try { host = new URL(s).hostname.toLowerCase() } catch { return null }
    host = host.replace(/^\[|\]$/g, '')
    return /^[a-z0-9.-]+$/.test(host) || /^[0-9a-f:.]+$/.test(host) ? host.replace(/\.$/, '') || null : null
  }
  // curl example.com/path, curl localhost:3000
  const bare = /^([a-z0-9.-]+\.[a-z]{2,}|localhost|\d+\.\d+\.\d+\.\d+)(?::\d+)?(\/|$)/i.exec(url.trim())
  return bare ? bare[1].toLowerCase() : null
}

function isLocalHost (host) {
  return host === 'localhost' || host === '0.0.0.0' || host === '::1' || /^127\./.test(host) ||
    host.endsWith('.localhost') || host.endsWith('.local') || host.endsWith('.internal') ||
    /^10\./.test(host) || /^192\.168\./.test(host) || /^172\.(1[6-9]|2\d|3[01])\./.test(host) || /^100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\./.test(host)
}

function isKnownHost (host) {
  return KNOWN_HOSTS.some(k => host === k || host.endsWith('.' + k))
}

// --- Bash ---------------------------------------------------------------------
//
// Only commands the parser fully understood (shell.js `understood`) are
// rated by what they run; anything else is high. A command line that runs
// several statements (; && || & newline) is high too, except for leading
// `cd <dir in the repo> &&`, the way agents start a command; a pipeline is
// one statement, rated by its worst command.

const READ_ONLY = new Set([
  'ls', 'll', 'la', 'cat', 'bat', 'head', 'tail', 'less', 'more', 'wc', 'grep', 'egrep', 'fgrep', 'rg', 'ag', 'ack', 'fd', 'fdfind',
  'pwd', 'echo', 'printf', 'which', 'whereis', 'type', 'file', 'stat', 'du', 'df', 'tree', 'date', 'cal', 'whoami', 'id', 'groups',
  'uname', 'hostname', 'printenv', 'basename', 'dirname', 'realpath', 'readlink', 'sort', 'uniq', 'cut', 'tr', 'diff', 'cmp',
  'comm', 'jq', 'yq', 'column', 'nl', 'od', 'xxd', 'hexdump', 'md5sum', 'sha1sum', 'sha256sum', 'sha512sum', 'cksum', 'ps',
  'pgrep', 'free', 'uptime', 'lsof', 'ss', 'netstat', 'true', 'false', 'test', '[', 'sleep', 'seq', 'cd', 'pushd', 'popd',
  'tldr', 'man', 'nproc', 'lscpu', 'lsblk', 'vmstat', 'iostat', 'locale', 'tput', 'strings', 'rev', 'fold', 'fmt', 'expand',
  'awk', 'gawk', 'sed', 'look', 'zcat', 'zgrep', 'bzcat', 'xzcat', 'getent', 'dig', 'nslookup', 'host', 'ping', 'base64'
])

const SHELLS = new Set(['sh', 'bash', 'zsh', 'dash', 'ksh', 'fish', 'csh', 'tcsh', 'ash'])
const INTERPRETERS = new Set([...SHELLS, 'python', 'python2', 'python3', 'node', 'nodejs', 'perl', 'ruby', 'php', 'deno', 'bun', 'lua', 'Rscript', 'osascript', 'tclsh', 'pwsh', 'powershell'])
// Flags that run the code given on the command line.
const INLINE_CODE = /^(-c|-e|-E|-r|-p|--eval|--print|--command|-Command|-EncodedCommand|eval)$|^--eval=|^--print=/
const ROOT_WRAPPERS = new Set(['sudo', 'su', 'doas', 'pkexec', 'run0'])
// The shell's own state: aliases, functions, variables, traps, options.
const SHELL_STATE = new Set(['eval', 'exec', 'source', '.', 'alias', 'unalias', 'function', 'trap', 'enable', 'export', 'declare', 'typeset', 'local', 'readonly', 'unset', 'shopt', 'set', 'hash', 'ulimit', 'umask', 'bind', 'complete', 'fc', 'history', 'disown', 'let'])
// Programs that run another command (given, or read from their input).
const RUNS_OTHERS = new Set(['busybox', 'toybox', 'xargs', 'watch', 'parallel', 'script', 'flock', 'setsid', 'strace', 'ltrace', 'gdb', 'lldb', 'valgrind', 'chroot', 'unshare', 'nsenter', 'runuser', 'firejail', 'bwrap', 'proot', 'systemd-run', 'at', 'batch', 'entr', 'expect', 'screen', 'nodemon', 'concurrently', 'npm-run-all', 'dbus-launch', 'xvfb-run', 'faketime', 'catchsegv'])
const CONDUCTORE = /^conductore(-hostd|-hook|-statusline)?$/
const NETWORK = new Set(['curl', 'wget', 'http', 'https', 'xh', 'aria2c'])
const REMOTE = new Set(['ssh', 'scp', 'sftp', 'rsync', 'ftp', 'telnet', 'nc', 'ncat', 'netcat', 'socat', 'mosh'])
const DISK = new Set(['dd', 'mkfs', 'fdisk', 'sfdisk', 'parted', 'gdisk', 'wipefs', 'shred', 'mkswap', 'swapon', 'swapoff', 'mount', 'umount', 'losetup', 'cryptsetup'])
const POWER = new Set(['shutdown', 'reboot', 'halt', 'poweroff', 'init', 'telinit'])
const PKG_MANAGERS = new Set(['npm', 'pnpm', 'yarn', 'bun'])
// Programs that change files: a wildcard in their arguments is high.
const FILE_CHANGERS = new Set(['rm', 'rmdir', 'unlink', 'trash', 'trash-put', 'mv', 'cp', 'ln', 'install', 'touch', 'mkdir', 'truncate', 'chmod', 'chown', 'chgrp', 'tee', 'shred', 'rsync', 'tar', 'zip', 'unzip', 'patch', 'dd'])
// Where a program named by its path is a system one, not a script.
const SYSTEM_BIN = /^\/(usr\/(local\/)?)?s?bin\/[^/]+$|^\/opt\/homebrew\/bin\/[^/]+$/

const TEST_SCRIPTS = /^(test|tests|t|lint|lint:.*|test:.*|check|typecheck|type-check|tsc|format:check|fmt:check|analyze|vitest|jest|spec|e2e:.*|coverage)$/
const TEST_BINARIES = new Set(['jest', 'vitest', 'mocha', 'ava', 'tap', 'pytest', 'py.test', 'tox', 'nox', 'mypy', 'pyright', 'rspec', 'phpunit', 'phpstan', 'shellcheck', 'hadolint', 'golangci-lint', 'ktlint', 'swiftlint', 'eslint', 'prettier', 'stylelint', 'tsc', 'ruff', 'flake8', 'pylint', 'black', 'isort', 'rubocop', 'actionlint', 'yamllint', 'markdownlint', 'biome', 'oxlint'])
const TOOLCHAINS = new Set(['pip', 'pip3', 'pipx', 'uv', 'poetry', 'pdm', 'conda', 'mamba', 'gem', 'bundle', 'composer', 'cargo', 'go', 'dotnet', 'mvn', 'gradle', 'gradlew', 'swift', 'flutter', 'dart', 'make', 'just', 'task', 'cmake', 'mix', 'deno', 'rake', 'tox', 'nox', 'python', 'python2', 'python3', 'node', 'nodejs', 'ruby'])

// Flags that make a linter or formatter rewrite files.
const FIX_FLAGS = /^(--fix|--fix-dry-run=false|--write|-w|--in-place|-i|--apply|--unsafe-fixes)$/
// Options of test and build runners that load or run code from elsewhere,
// or move the run to another place: not "just the tests" any more.
// (Path-valued options are checked by where their path points.)
const CODE_OPTIONS = /^(--script-shell|--node-options|--userconfig|--globalconfig|--exec|-exec|-toolexec|--toolexec|-vettool|--vettool|-overlay|--overlay|-Z|--eval|-E|--import|--loader|--experimental-loader)(=|$)/

const ENV_SAFE = new Set(['CI', 'NODE_ENV', 'FORCE_COLOR', 'NO_COLOR', 'TERM', 'COLUMNS', 'LINES', 'LANG', 'LANGUAGE', 'LC_ALL', 'LC_CTYPE', 'LC_MESSAGES', 'TZ', 'DEBUG', 'RUST_BACKTRACE', 'RUST_LOG', 'PYTHONUNBUFFERED', 'PYTHONDONTWRITEBYTECODE', 'CLICOLOR', 'CLICOLOR_FORCE', 'HUSKY', 'VERBOSE', 'GIT_TERMINAL_PROMPT'])

const CONCERNS = {
  incomplete: 'has unbalanced quotes or an open here-doc',
  substitution: 'uses command substitution',
  expansion: 'uses shell variables or expansions',
  background: 'runs a command in the background (&)',
  subshell: 'uses a subshell, group or function',
  compound: 'uses shell control flow (if, for, while, case…)',
  heredoc: 'feeds a here-document',
  continuation: 'uses line continuations',
  control: 'has control or invisible characters',
  syntax: 'has a shell syntax error',
  'glob-command': 'uses a wildcard as the command',
  'glob-redirect': 'redirects to a wildcard path',
  brace: 'uses brace expansion'
}

// Why a command the parser did not fully understand is high.
function notUnderstood (parsed) {
  const concern = parsed.complete ? parsed.concerns[0] : 'incomplete'
  let reason = `Cannot check it: ${CONCERNS[concern] || 'not a plain command'}`
  if (concern === 'substitution' && parsed.substitutions.length) reason += `: ${clip(parsed.substitutions[0], 50)}`
  return r('high', reason)
}

function classifyBash (command, ctx, depth = 0) {
  if (typeof command !== 'string' || !command.trim()) return r('medium', 'Runs an empty or unreadable command')
  const parsed = shell.parse(command)
  if (!parsed.understood) return notUnderstood(parsed)
  const segs = parsed.segments
  if (!segs.length) return r('medium', 'Runs an empty or unreadable command')
  // Leading `cd <dir in the repo> &&`: the rest runs there.
  let here = ctx
  let lead = 0
  while (lead < segs.length - 1 && segs[lead + 1].sep === '&&') {
    const dir = repoCd(segs[lead], here)
    if (!dir) break
    here = { ...here, cwd: dir }
    lead++
  }
  const rest = segs.slice(lead)
  const reasons = rest.map(seg => classifySegment(seg, here, depth))
  let result = r('low', '')
  for (const one of reasons) result = max(result, one)
  if (rest.some((seg, k) => k > 0 && !seg.pipedFrom)) {
    // Several statements: never rated by their parts alone.
    if (result.level === 'high') return result
    const names = [...new Set(rest.map(commandName).filter(Boolean))]
    return r('high', `Runs several commands in sequence: ${clip(names.join(', '))}`)
  }
  // `curl … | sh` says more than "network to an unknown host".
  const piped = reasons.find(x => x.level === 'high' && x.reason.startsWith('Pipes into'))
  if (piped) return piped
  if (result.level === 'low') {
    // Low: say what it is ("Read-only: git status", "Runs tests: npm test").
    const tests = reasons.find(x => x.reason.startsWith('Runs tests'))
    if (tests) return tests
    if (reasons.length === 1) return reasons[0]
    const names = [...new Set(rest.map(commandName).filter(n => n && n !== 'cd'))]
    return r('low', `Read-only: ${clip(names.join(', '))}`)
  }
  return result
}

// The directory a plain `cd <dir>` moves to when it stays in the repo,
// else null.
function repoCd (seg, ctx) {
  if (seg.assigns || seg.redirects.length || seg.words.length !== 2 || seg.words[0] !== 'cd') return null
  if (seg.meta[1].glob || seg.meta[1].brace || seg.words[1] === '-' || seg.words[1].startsWith('-')) return null
  const dir = resolvePath(seg.words[1], ctx)
  const root = ctx.root || ctx.cwd
  if (!dir || !root || root === '/' || root === ctx.home || !inside(dir, root)) return null
  return dir
}

// "git status", "npm test", "ls": what a segment runs, for reasons.
function commandName (seg) {
  const words = shell.stripAssignments(seg.words, seg.assigns)
  const prog = base(words[0] || '')
  if (prog === 'git' || PKG_MANAGERS.has(prog) || prog === 'docker' || prog === 'gh' || prog === 'cargo' || prog === 'go' || prog === 'flutter' || prog === 'dart') {
    const sub = words.slice(1).find(w => !w.startsWith('-'))
    return sub ? `${prog} ${sub}` : prog
  }
  return prog
}

function clip (s, n = 60) {
  s = String(s).replace(/\s+/g, ' ').trim()
  return s.length > n ? s.slice(0, n - 1) + '…' : s
}

// The value a word gives a path check: `--file=x` and `@x` (curl) name x.
function pathOf (w) {
  const eq = /^--?[A-Za-z][\w-]*=(.+)$/.exec(w)
  const v = eq ? eq[1] : w
  return v.startsWith('@') ? v.slice(1) : v
}

function secretOf (w, ctx) {
  for (const v of new Set([w, pathOf(w)])) {
    const kind = secretKind(v) || (v.includes('/') || v.startsWith('~') ? secretKind(resolvePath(v, ctx)) : null)
    if (kind) return kind
  }
  return null
}

// Names a wildcard must not be able to match (see SECRET_PATTERNS).
const SECRET_NAMES = ['.env', '.env.local', '.ssh', 'id_rsa', 'id_dsa', 'id_ecdsa', 'id_ed25519', 'x.pem', 'x.key', 'x.p12', 'x.pfx', 'x.jks', 'x.keystore', 'x.kdbx', 'x.asc', 'x.gpg', '.aws', '.gnupg', '.netrc', '.git-credentials', '.npmrc', '.pypirc', '.pgpass', '.my.cnf', 'credentials', 'credentials.json', 'secret', 'secrets', 'secrets.yml', '.kube', '.docker', '.conductore', 'shadow', 'sudoers']
// Programs that read names only, never contents.
const NAMES_ONLY = new Set(['ls', 'll', 'la', 'du', 'stat', 'tree', 'file'])

function segmentRegex (seg) {
  let re = ''
  for (let i = 0; i < seg.length; i++) {
    const c = seg[i]
    if (c === '*') re += '.*'
    else if (c === '?') re += '.'
    else if (c === '[') {
      const end = seg.indexOf(']', i + 2)
      if (end === -1) { re += '\\['; continue }
      re += '[' + seg.slice(i + 1, end).replace(/^!/, '^').replace(/\\/g, '\\\\') + ']'
      i = end
    } else re += c.replace(/[.+^${}()|\\]/g, '\\$&')
  }
  try { return new RegExp(`^${re}$`, 's') } catch { return /^/ }
}

// A wildcard argument the shell expands before the program runs: high when
// it can reach outside the repo, hidden files or secrets.
function globRisk (word, prog, ctx) {
  if (FILE_CHANGERS.has(prog)) return r('high', `Uses a wildcard with a command that changes files: ${clip(word, 40)}`)
  const v = pathOf(word)
  const plain = v.replace(/[*?]|\[[^\]]*\]/g, '')
  const segs = v.split('/')
  const secretish = secretKind(plain) || segs.some((seg, k) => /[*?[]/.test(seg) && (k < segs.length - 1 || !NAMES_ONLY.has(prog)) && SECRET_NAMES.some(n => segmentRegex(seg).test(n)))
  if (secretish) return r('high', `Uses a wildcard that can match secrets: ${clip(word, 40)}`)
  if (v.split('/').some(part => part.startsWith('.') && part !== '.' && part !== '..' && /[*?[]/.test(part))) return r('high', `Uses a wildcard that can match hidden files: ${clip(word, 40)}`)
  const fixed = v.slice(0, v.search(/[*?[]/))
  const dir = resolvePath(fixed.includes('/') ? fixed.slice(0, fixed.lastIndexOf('/') + 1) || '/' : '.', ctx)
  const root = ctx.root || ctx.cwd
  if (v.includes('..') || !root || !dir || !inside(dir, root)) return r('high', `Uses a wildcard path outside the repo: ${clip(word, 40)}`)
  return null
}

// Precise option tables of the wrappers that run the rest of the line:
// flags, options taking a value (next word), options with an inline value.
const WRAPPERS = {
  env: { flags: /^(-i|--ignore-environment|-0|--null|-)$/, values: /^(-u|--unset)$/, inline: /^--unset=./, assigns: true },
  time: { flags: /^(-p|--portability)$/ },
  nice: { values: /^(-n|--adjustment)$/, inline: /^(--adjustment=-?\d+|-n-?\d+|-\d+)$/ },
  nohup: {},
  stdbuf: { values: /^-[ioe]$/, inline: /^(-[ioe][0-9]*[LKMGB]?|--(input|output|error)=[0-9]*[LKMGB]?)$/ },
  ionice: { flags: /^-t$/, values: /^-[cn]$/, inline: /^-[cn]\d+$/ },
  chronic: { flags: /^-[ev]+$/ },
  caffeinate: { flags: /^-[dimsu]+$/, values: /^-[tw]$/ },
  command: { flags: /^-p$/ },
  builtin: {},
  timeout: { flags: /^(--preserve-status|--foreground|-v|--verbose)$/, values: /^(-s|--signal|-k|--kill-after)$/, inline: /^(--signal=\w+|--kill-after=[\d.]+[smhd]?|-s\w+|-k[\d.]+[smhd]?)$/, duration: true }
}

// The words after a wrapper's options: { words } or { risk } when its
// options are not all known (then it cannot be read past).
function unwrap (prog, words) {
  const spec = WRAPPERS[prog]
  let k = 1
  while (k < words.length && words[k].startsWith('-') && words[k] !== '--') {
    const w = words[k]
    if (prog === 'command' && /^-[vV]$/.test(w)) return { risk: r('low', `Looks up a command: ${clip(words.slice(k + 1).join(' '), 40)}`) }
    if (spec.flags && spec.flags.test(w)) { k++; continue }
    if (spec.inline && spec.inline.test(w)) { k++; continue }
    if (spec.values && spec.values.test(w) && k + 1 < words.length) { k += 2; continue }
    return { risk: r('high', `Runs through ${prog} with options it cannot check: ${clip(words.join(' '), 50)}`) }
  }
  if (words[k] === '--') k++
  if (spec.duration) {
    if (!/^\d+(\.\d+)?[smhd]?$/.test(words[k] || '')) return { risk: r('high', `Runs through timeout with options it cannot check: ${clip(words.join(' '), 50)}`) }
    k++
  }
  let rest = words.slice(k)
  if (spec.assigns) {
    let a = 0
    while (a < rest.length && /^[^=]+=/.test(rest[a])) a++
    const bad = rest.slice(0, a).find(w => !ENV_SAFE.has(w.slice(0, w.indexOf('='))))
    if (bad) return { risk: r('high', `Sets ${clip(bad.slice(0, bad.indexOf('=')), 30)} for the command`) }
    rest = rest.slice(a)
    if (!rest.length) return { risk: r('low', 'Read-only: env') }
  }
  return { words: rest }
}

// One simple command: words (quotes removed) and its redirections.
function classifySegment (seg, ctx, depth) {
  let result = r('low', '')
  // VAR=value before the command: only a few harmless names.
  for (const a of seg.words.slice(0, seg.assigns)) {
    const name = a.slice(0, a.search(/\+?=/))
    if (!ENV_SAFE.has(name)) return r('high', `Sets ${name} for the command`)
  }
  let words = seg.words.slice(seg.assigns)
  const meta = seg.meta.slice(seg.assigns)
  // Redirections: where output lands.
  for (const { op, target } of seg.redirects) {
    if (op.startsWith('<') && op !== '<>') {
      if (op === '<' && secretKind(resolvePath(target, ctx) || target)) result = max(result, r('high', `Reads a secrets path: ${short(target, ctx)}`))
      continue
    }
    result = max(result, writeRisk(target, ctx, 'Writes'))
  }
  if (!words.length) return result.level === 'low' ? r('low', seg.assigns ? 'Sets a shell variable' : 'No command (redirection only)') : result
  // Any word naming a secrets path.
  for (let k = 1; k < words.length; k++) {
    const kind = secretOf(words[k], ctx)
    if (kind) { result = max(result, r('high', `Touches a secrets path (${kind}): ${short(pathOf(words[k]), ctx)}`)); break }
  }
  // Unwrap env/time/nice/timeout/…, precisely; sudo is high by itself.
  for (let guard = 0; guard < 6 && words.length; guard++) {
    const prog = base(words[0])
    if (ROOT_WRAPPERS.has(prog)) return max(result, r('high', `Runs as root (${prog})`))
    if (!WRAPPERS[prog] || (words[0].includes('/') && !SYSTEM_BIN.test(words[0]))) break
    const next = unwrap(prog, words)
    if (next.risk) return max(result, next.risk)
    words = next.words
  }
  if (!words.length) return result.level === 'low' ? r('low', 'No command (redirection only)') : result
  const offset = meta.length - words.length
  const name = base(words[0])
  const prog = programName(words[0])
  const args = words.slice(1)
  const text = clip(words.join(' '))
  // Wildcards the shell expands before the program sees them.
  for (let k = 1; k < words.length; k++) {
    const m = meta[offset + k]
    if (!m) continue
    if (m.brace) { result = max(result, r('high', `Uses brace expansion: ${clip(words[k], 40)}`)); break }
    if (m.glob) {
      const g = globRisk(words[k], name, ctx)
      if (g) { result = max(result, g); break }
    }
  }

  if (CONDUCTORE.test(name)) return r('high', `Talks to Conductore's approval service: ${text}`)
  // Piped into a shell or interpreter reading its code from stdin.
  if (seg.pipedFrom && INTERPRETERS.has(name) && readsCodeFromStdin(name, args)) {
    return r('high', `Pipes into ${name}: runs whatever the previous command prints`)
  }
  if (SHELL_STATE.has(name)) {
    if (name === 'eval') return r('high', 'Evaluates a constructed command (eval)')
    if (name === 'exec') return r('high', `Replaces the shell (exec): ${text}`)
    if (name === 'source' || name === '.') return r('high', `Runs a file in the shell itself (${name}): ${text}`)
    return r('high', `Changes the shell itself (${name}): ${text}`)
  }
  if (RUNS_OTHERS.has(name)) return r('high', `Runs other commands through ${name}: ${text}`)
  if (INTERPRETERS.has(name) && args.some(a => INLINE_CODE.test(a))) return r('high', `Runs inline ${name} code`)
  if (SHELLS.has(name)) {
    // `bash script.sh` with plain options runs a script; anything else
    // (no script, -s, odd options) is a shell reading its input.
    let k = 0
    for (;;) {
      if (/^-[euxvn]+$/.test(args[k] || '')) { k++; continue }
      if (args[k] === '-o' && args[k + 1] === 'pipefail') { k += 2; continue }
      break
    }
    const script = args[k]
    if (!script || script.startsWith('-') || script === '/dev/stdin' || /^\/dev\/fd\/|^\/proc\/self\/fd\//.test(script)) return r('high', `Starts ${name}: it runs whatever it reads`)
    return max(result, r('medium', `Runs a script: ${text}`))
  }
  if (name === 'tmux') {
    return /^(ls|list-sessions|list-windows|list-panes|has-session|-V)$/.test(args[0] || '')
      ? max(result, r('low', `Read-only: ${text}`))
      : r('high', `Controls tmux (it can type into other panes): ${text}`)
  }

  let own = classifyProgram(prog, args, ctx, text, words)
  // A runner (tests, linters, builds, installs) with options or paths that
  // bring in code from elsewhere or move the run out of the repo.
  if (own.level !== 'high' && (TEST_BINARIES.has(prog) || TOOLCHAINS.has(prog) || PKG_MANAGERS.has(prog) || prog === 'npx' || prog === 'pnpx' || prog === 'bunx' || prog === 'gradlew' || prog === 'mvnw')) {
    own = max(own, runnerRisk(prog, args, ctx, text))
  }
  return max(result, own)
}

function runnerRisk (prog, args, ctx, text) {
  const end = args.indexOf('--')
  const own = end === -1 ? args : args.slice(0, end)
  if (own.some(a => CODE_OPTIONS.test(a))) return r('high', `Runs ${prog} with options that load code or move the run: ${text}`)
  if (prog === 'make' && own.some(a => /^[A-Za-z_][A-Za-z0-9_]*\+?=/.test(a))) return r('high', `Overrides make variables: ${text}`)
  const root = ctx.root || ctx.cwd
  for (const a of args) {
    const v = pathOf(a)
    if (!(v.includes('/') || v.startsWith('~') || v.startsWith('.'))) continue
    const abs = resolvePath(v, ctx)
    if (abs && !(root && inside(abs, root))) return r('high', `Runs ${prog} with a path outside the repo: ${clip(v, 40)}`)
  }
  return r('low', '')
}

// Whether an interpreter fed by a pipe runs what it reads.
function readsCodeFromStdin (prog, args) {
  if (SHELLS.has(prog)) return true
  const operand = args.find(a => !a.startsWith('-'))
  if (args.includes('-m')) return false
  return !operand || operand === '-' || operand === '/dev/stdin' || /^\/dev\/fd\/|^\/proc\/self\/fd\//.test(operand) || args.includes('-')
}

// The program a command word names: a system one by its name, anything
// else given by path (./ls, bin/cat) is a script.
function programName (w) {
  if (!w.includes('/') || SYSTEM_BIN.test(w)) return base(w)
  if (/^(\.\/)?(gradlew|mvnw)$/.test(w)) return base(w)
  return w
}

function base (w) {
  return String(w).replace(/^.*\//, '')
}

function dropOptions (words, re) {
  let k = 0
  while (k < words.length && re.test(words[k])) k++
  return words.slice(k)
}

function writeRisk (target, ctx, verb) {
  const t = writeTarget(target, ctx)
  switch (t.where) {
    case 'none': return r('low', '')
    case 'secret': return r('high', `${verb} a secrets path (${t.kind}): ${short(target, ctx)}`)
    case 'outside': return r('high', `${verb} outside the repo: ${short(target, ctx)}`)
    case 'temp': return r('medium', `${verb} a temp file: ${short(target, ctx)}`)
    default: return r('medium', `${verb} a file in the repo: ${short(target, ctx)}`)
  }
}

// sed scripts that only print, delete or substitute (no e, w, r, W, R
// commands, no e or w flags) are read-only.
const SED_SAFE = [
  /^\s*((\d+|\$|\/(?:[^\\/]|\\.)*\/)(,(\d+|\$|\/(?:[^\\/]|\\.)*\/))?!?)?\s*[pdq=]?\s*$/,
  /^\s*((\d+|\$|\/(?:[^\\/]|\\.)*\/)(,(\d+|\$|\/(?:[^\\/]|\\.)*\/))?)?\s*s([^\\\n\w\s])(?:(?!\5)[^\\\n]|\\.)*\5(?:(?!\5)[^\\\n]|\\.)*\5[gpiI0-9]*\s*$/
]

function sedScriptsSafe (args) {
  const scripts = []
  let k = 0
  let given = false
  for (; k < args.length; k++) {
    const a = args[k]
    if (a === '-e' || a === '--expression') { scripts.push(args[++k] || ''); given = true; continue }
    if (a.startsWith('--expression=')) { scripts.push(a.slice(13)); given = true; continue }
    if (a === '-f' || a.startsWith('--file')) return false
    if (/^-[nrEsuz]+$/.test(a) || /^--(quiet|silent|regexp-extended|separate|unbuffered|null-data|posix|debug|sandbox)$/.test(a)) continue
    if (/^-i|^--in-place/.test(a) || /^-[a-zA-Z]*i/.test(a)) continue
    if (a.startsWith('-')) return false
    if (!given) { scripts.push(a); given = true }
  }
  return scripts.every(s => s.split(/[;\n]/).every(part => SED_SAFE.some(re => re.test(part))))
}

// awk programs that only print: no system(), getline, output redirection
// or pipes.
function awkSafe (args) {
  let k = 0
  while (k < args.length && args[k].startsWith('-')) {
    if (args[k] === '-F' || args[k] === '-v') { k += 2; continue }
    if (/^-F.|^-v./.test(args[k])) { k++; continue }
    return false // -f progfile, -E, -i, -l, --exec, …
  }
  const program = args[k]
  return typeof program === 'string' && !/system\s*\(|getline|@load|@include|\bclose\s*\(|fflush|ENVIRON|PROCINFO/.test(program) && !/\bprintf?\b[^;}]*?[>|]/.test(program)
}

// Non-option arguments (paths, mostly).
const operands = args => args.filter(a => !a.startsWith('-'))

// The value of an option given as `-o x`, `--output=x` or `-ox`, or null.
function optionValue (args, re) {
  for (let k = 0; k < args.length; k++) {
    if (re.test(args[k])) return args[k + 1] === undefined ? '' : args[k + 1]
    const eq = args[k].indexOf('=')
    if (eq > 0 && re.test(args[k].slice(0, eq))) return args[k].slice(eq + 1)
  }
  return null
}

// The files `sed -i` edits: its operands after the script.
function sedFiles (args) {
  const scripted = args.some(a => a === '-e' || a === '--expression' || a.startsWith('--expression=') || a === '-f')
  const ops = []
  for (let k = 0; k < args.length; k++) {
    if (args[k] === '-e' || args[k] === '--expression' || args[k] === '-f') { k++; continue }
    if (!args[k].startsWith('-')) ops.push(args[k])
  }
  return scripted ? ops : ops.slice(1)
}

function classifyProgram (prog, args, ctx, text, words) {
  if (args.length === 1 && /^(--version|-V|--help|-h|help|version)$/.test(args[0])) return r('low', `Prints ${prog} version or help`)
  if (prog === 'git') return classifyGit(args, ctx, text)
  if (PKG_MANAGERS.has(prog) || prog === 'npx' || prog === 'pnpx' || prog === 'bunx') return classifyNode(prog, args, ctx, text)
  if (DISK.has(prog) || /^mkfs\./.test(prog)) return r('high', `Low-level disk command: ${text}`)
  if (POWER.has(prog)) return r('high', `Shuts down or restarts the machine: ${text}`)
  if (prog === 'systemctl' || prog === 'service' || prog === 'launchctl') {
    return /^(status|show|list-units|list-unit-files|is-active|is-enabled|cat)$/.test(args[0] || '') ? r('low', `Read-only: ${text}`) : r('high', `Changes system services: ${text}`)
  }
  if (prog === 'crontab') return args.includes('-l') ? r('low', 'Lists crontab') : r('high', 'Changes scheduled jobs (crontab)')
  if (prog === 'rm' || prog === 'rmdir' || prog === 'unlink' || prog === 'trash' || prog === 'trash-put') return classifyRm(prog, args, ctx, text)
  if (prog === 'find') {
    if (args.includes('-delete')) return r('high', `Deletes files (find -delete): ${text}`)
    if (args.some(a => /^-(exec|execdir|ok|okdir)$/.test(a))) return r('high', `Runs a command per file (find -exec): ${text}`)
    if (args.some(a => /^-f(print|ls|printf)/.test(a))) return r('high', `Writes find output to a file: ${text}`)
    return r('low', `Read-only: ${text}`)
  }
  if (prog === 'sed') {
    if (!sedScriptsSafe(args)) return r('high', `sed script that can run commands or write files: ${text}`)
    if (args.some(a => /^-i|^--in-place/.test(a) || /^-[a-zA-Z]*i/.test(a))) return pathWrites(sedFiles(args), ctx, 'Edits', text)
  }
  if ((prog === 'awk' || prog === 'gawk') && !awkSafe(args)) return r('high', `awk that can run commands or write files: ${text}`)
  if (prog === 'tee') return pathWrites(operands(args), ctx, 'Writes', text)
  // Read-only programs with an option that writes a file.
  if (prog === 'sort' || prog === 'tree') {
    const out = optionValue(args, prog === 'sort' ? /^(-o|--output)$/ : /^-o$/)
    if (out !== null) return pathWrites([out], ctx, 'Writes', text)
  }
  if (prog === 'uniq' && operands(args).length > 1) return pathWrites(operands(args).slice(1, 2), ctx, 'Writes', text)
  if (prog === 'xxd' && args.some(a => /^-r/.test(a)) && operands(args).length > 1) return pathWrites(operands(args).slice(-1), ctx, 'Writes', text)
  if (prog === 'yq' && args.some(a => /^(-i|--inplace)$/.test(a))) return pathWrites(operands(args).slice(1), ctx, 'Edits', text)
  if (NETWORK.has(prog)) return classifyNetwork(prog, args, text, ctx)
  if (REMOTE.has(prog)) {
    const hostArg = args.find(a => !a.startsWith('-') && /[@:]/.test(a)) || operands(args)[0]
    if (prog === 'rsync' && !args.some(a => /^[^/]*:/.test(a) && !a.startsWith('-'))) return pathWrites(operands(args).slice(-1), ctx, 'Syncs to', text)
    const host = hostArg ? String(hostArg).replace(/^.*@/, '').replace(/:.*$/, '') : ''
    if (host && isLocalHost(host)) return r('medium', `Connects to a local host: ${text}`)
    return r('high', `Connects to a remote host${host ? ` (${host})` : ''}: ${text}`)
  }
  if (prog === 'chmod' || prog === 'chown' || prog === 'chgrp') {
    const recursive = args.some(a => /^-[a-zA-Z]*R/.test(a) || a === '--recursive')
    const worldWritable = args.some(a => /^[0-7]{3,4}$/.test(a) && '2367'.includes(a.slice(-1))) || args.some(a => /(^|,)[oa]*[oa]\+[rwx]*w/.test(a))
    const targets = operands(args).slice(1)
    const out = targets.map(t => writeTarget(t, ctx)).find(t => t.where === 'outside' || t.where === 'secret')
    if (out) return r('high', `Changes permissions outside the repo: ${short(out.abs, ctx)}`)
    if (worldWritable) return r('high', `Makes files world-writable: ${text}`)
    if (recursive || prog !== 'chmod') return r('medium', `Changes ownership or permissions: ${text}`)
    return r('medium', `Changes permissions: ${text}`)
  }
  if (prog === 'mv' || prog === 'cp' || prog === 'ln' || prog === 'install' || prog === 'touch' || prog === 'mkdir' || prog === 'truncate') {
    const ops = operands(args)
    // cp/mv/ln/install write to the last operand; touch/mkdir/truncate to all.
    const targets = ['touch', 'mkdir', 'truncate'].includes(prog) ? ops : prog === 'mv' ? ops : ops.slice(-1)
    const verb = { mv: 'Moves', cp: 'Copies to', ln: 'Links', install: 'Installs to', touch: 'Creates', mkdir: 'Creates', truncate: 'Truncates' }[prog]
    return pathWrites(targets, ctx, verb, text)
  }
  if (prog === 'kill' || prog === 'pkill' || prog === 'killall') {
    return args.some(a => a === '1' || a === '-1') ? r('high', `Kills every process: ${text}`) : r('medium', `Stops processes: ${text}`)
  }
  if (prog === 'docker' || prog === 'podman') return classifyDocker(args, text)
  if (prog === 'kubectl' || prog === 'helm') {
    return /^(get|describe|logs|top|version|explain|api-resources|config|diff|status|list|history|template|lint|show)$/.test(args[0] || '') && !(args[0] === 'config' && /^(set|use|delete)/.test(args[1] || ''))
      ? r('low', `Read-only: ${text}`)
      : r('high', `Changes a cluster: ${text}`)
  }
  if (prog === 'terraform' || prog === 'tofu' || prog === 'pulumi') {
    return /^(apply|destroy|import|state|taint|up|refresh)$/.test(args[0] || '') ? r('high', `Changes infrastructure: ${text}`) : r('medium', `Infrastructure tool: ${text}`)
  }
  if (prog === 'gh') return classifyGh(args, text)
  if (/^(apt|apt-get|dnf|yum|pacman|zypper|apk|brew|port|snap|flatpak)$/.test(prog)) {
    return /^(install|remove|purge|upgrade|update|add|del|uninstall|autoremove|-S|-R|-U|-Syu)$/.test(args[0] || '') ? r('medium', `System package manager: ${text}`) : r('low', `Read-only: ${text}`)
  }
  if (prog === 'pip' || prog === 'pip3' || prog === 'pipx' || prog === 'uv' || prog === 'poetry' || prog === 'pdm' || prog === 'conda' || prog === 'mamba' || prog === 'gem' || prog === 'bundle' || prog === 'composer' || prog === 'cargo' || prog === 'go' || prog === 'dotnet' || prog === 'mvn' || prog === 'gradle' || prog === 'gradlew' || prog === 'swift' || prog === 'flutter' || prog === 'dart' || prog === 'make' || prog === 'just' || prog === 'task' || prog === 'cmake' || prog === 'mix' || prog === 'deno' || prog === 'rake' || prog === 'tox' || prog === 'nox' || prog === 'python' || prog === 'python3' || prog === 'node' || prog === 'ruby') {
    return classifyToolchain(prog, args, text)
  }
  if (TEST_BINARIES.has(prog)) {
    if (args.some(a => FIX_FLAGS.test(a))) return r('medium', `Rewrites files: ${text}`)
    return ['prettier', 'black', 'isort'].includes(prog) && !args.some(a => /^--check|^--diff|^-c$|^--list-different|^-l$/.test(a))
      ? r('medium', `Formats files: ${text}`)
      : r('low', `Runs tests or checks: ${text}`)
  }
  if (READ_ONLY.has(prog)) return r('low', `Read-only: ${text}`)
  if (/^\.\/?(gradlew|mvnw)$/.test(words[0])) return classifyToolchain('gradle', args, text)
  if (words[0].startsWith('./') || words[0].startsWith('/') || words[0].startsWith('~')) return r('medium', `Runs a script: ${text}`)
  return r('medium', `Runs ${prog}: ${text}`)
}

function pathWrites (targets, ctx, verb, text) {
  if (!targets.length) return r('medium', `${verb}: ${text}`)
  let result = r('low', '')
  for (const t of targets) result = max(result, writeRisk(t, ctx, verb))
  return result.level === 'low' ? r('medium', `${verb}: ${text}`) : result
}

function classifyRm (prog, args, ctx, text) {
  const recursive = args.some(a => a === '--recursive' || /^-[a-zA-Z]*[rR]/.test(a))
  const targets = operands(args)
  const where = targets.map(t => writeTarget(t, ctx))
  const bad = where.find(t => t.where === 'secret') || where.find(t => t.where === 'outside')
  const wild = targets.some(t => t === '*' || t === '/' || t === '~' || t === '.' || t === '..' || /^\/\*?$|^~\/?\*?$|^\$HOME\/?$/.test(t))
  if (bad) return r('high', `Deletes ${bad.where === 'secret' ? 'a secrets path' : 'outside the repo'}: ${short(bad.abs, ctx)}`)
  if (recursive) return r('high', `Deletes recursively (${prog} ${args.filter(a => a.startsWith('-')).join(' ') || '-r'}): ${clip(targets.join(' '), 40)}`)
  if (wild) return r('high', `Deletes with a wildcard target: ${text}`)
  if (where.length && where.every(t => t.where === 'temp')) return r('medium', `Deletes temp files: ${text}`)
  return r('medium', `Deletes files in the repo: ${text}`)
}

// git subcommands with options that run a program or write a file of the
// caller's choice.
const GIT_RUNS = {
  clone: /^(--upload-pack|-u|--template|--config|-c)(=|$)/,
  fetch: /^--upload-pack(=|$)/,
  pull: /^--upload-pack(=|$)/,
  'ls-remote': /^(--upload-pack|-u|--exec)(=|$)/,
  archive: /^(--exec|--remote|--output|-o)(=|$)/,
  push: /^(--receive-pack|--exec)(=|$)/,
  grep: /^(-O|--open-files-in-pager)(=|$)|^-O./,
  diff: /^--output(=|$)/,
  log: /^--output(=|$)/,
  show: /^--output(=|$)/,
  'format-patch': /^(--output|-o|--output-directory)(=|$)/,
  rebase: /^(-x|--exec)(=|$)/
}
// Subcommands that change the repo but run nothing else.
const GIT_MEDIUM = new Set(['cherry-pick', 'revert', 'merge', 'am', 'apply', 'notes', 'sparse-checkout', 'maintenance', 'init', 'bundle', 'bisect', 'lfs', 'restore', 'stage', 'range-diff', 'cherry', 'fsck', 'verify-commit', 'verify-tag', 'annotate', 'format-patch', 'archive', 'request-pull', 'mktree', 'read-tree', 'write-tree', 'hash-object', 'pack-refs', 'repack', 'commit-tree', 'checkout-index', 'update-index', 'citool'])

function classifyGit (args, ctx, text) {
  // Global options: -C dir, --no-pager, --git-dir=…. -c and --config-env
  // set any config (pagers, hooks, ssh commands) for this run.
  let k = 0
  while (k < args.length && args[k].startsWith('-')) {
    const a = args[k]
    if (a === '-c' || /^--config-env(=|$)/.test(a) || /^--exec-path=/.test(a)) return r('high', `Runs git with its configuration overridden: ${text}`)
    if (a === '-C' || a === '--git-dir' || a === '--work-tree' || a === '--namespace') k++
    k++
  }
  const sub = args[k] || ''
  const rest = args.slice(k + 1)
  if (!sub) return r('low', `Prints git help: ${text}`)
  if (GIT_RUNS[sub] && rest.some(a => GIT_RUNS[sub].test(a))) return r('high', `Runs git ${sub} with an option that runs a program or writes a file: ${text}`)
  if ((sub === 'bisect' && rest[0] === 'run') || (sub === 'submodule' && rest[0] === 'foreach') || /^(difftool|mergetool|credential|daemon|instaweb|send-email|filter-repo|upload-pack|receive-pack|shell|remote-ext|-p|--paginate)$/.test(sub)) {
    return r('high', `Runs other programs through git: ${text}`)
  }
  const has = (...flags) => rest.some(a => flags.includes(a) || flags.some(f => f.endsWith('=') && a.startsWith(f)))
  switch (sub) {
    case 'status': case 'diff': case 'log': case 'show': case 'blame': case 'rev-parse': case 'ls-files': case 'ls-tree':
    case 'describe': case 'shortlog': case 'grep': case 'cat-file': case 'merge-base': case 'name-rev': case 'for-each-ref':
    case 'rev-list': case 'show-ref': case 'whatchanged': case 'count-objects': case 'check-ignore': case 'var': case 'help': case 'version':
      return r('low', `Read-only: ${text}`)
    case 'reflog':
      return /^(expire|delete)$/.test(rest[0] || '') ? r('high', `Rewrites the reflog: ${text}`) : r('low', `Read-only: ${text}`)
    case 'branch':
      if (has('-D', '--delete', '-d', '--force', '-f', '-m', '-M', '--move', '-c', '-C')) return r('medium', `Changes branches: ${text}`)
      return operands(rest).length && !has('--list', '-l', '-a', '-r', '-v', '-vv', '--contains', '--merged', '--no-merged', '--show-current') ? r('medium', `Creates a branch: ${text}`) : r('low', `Read-only: ${text}`)
    case 'tag':
      return !rest.length || has('-l', '--list', '-n') ? r('low', `Read-only: ${text}`) : has('-d', '--delete') ? r('medium', `Deletes a tag: ${text}`) : r('medium', `Creates a tag: ${text}`)
    case 'remote':
      return !rest.length || /^(-v|--verbose|show|get-url)$/.test(rest[0]) ? r('low', `Read-only: ${text}`) : r('medium', `Changes remotes: ${text}`)
    case 'stash':
      return /^(list|show)$/.test(rest[0] || '') ? r('low', `Read-only: ${text}`) : /^(drop|clear)$/.test(rest[0] || '') ? r('high', `Discards stashed changes: ${text}`) : r('medium', `Stashes changes: ${text}`)
    case 'config':
      return has('--get', '--list', '-l', '--get-all', '--get-regexp', '--show-origin') ? r('low', `Read-only: ${text}`) : has('--global', '--system') ? r('high', `Changes global git config: ${text}`) : r('medium', `Changes git config: ${text}`)
    case 'worktree':
      return /^list$/.test(rest[0] || '') ? r('low', `Read-only: ${text}`) : /^(remove|prune)$/.test(rest[0] || '') && has('--force', '-f') ? r('high', `Force-removes a worktree: ${text}`) : r('medium', `Changes worktrees: ${text}`)
    case 'push':
      if (has('--force', '-f', '--force-with-lease', '--force-with-lease=', '--force-if-includes', '--mirror', '--delete', '-d', '--prune') || rest.some(a => /^\+/.test(a) || /^:/.test(a))) {
        return r('high', `Force-pushes or deletes on the remote: ${text}`)
      }
      return r('medium', `Pushes to a remote: ${text}`)
    case 'reset':
      return has('--hard', '--merge', '--keep') ? r('high', `Discards local changes (git reset ${rest.find(a => a.startsWith('--')) || '--hard'})`) : r('medium', `Moves HEAD or unstages: ${text}`)
    case 'clean':
      return rest.some(a => /^-[a-zA-Z]*[fx]/.test(a) || a === '--force') && !rest.some(a => /^-[a-zA-Z]*n/.test(a) || a === '--dry-run') ? r('high', `Deletes untracked files (git clean): ${text}`) : r('low', `Dry run: ${text}`)
    case 'checkout': case 'restore': case 'switch':
      if (has('-f', '--force', '--discard-changes') || (sub !== 'switch' && rest.includes('.') ) || (sub === 'checkout' && rest.includes('--'))) return r('high', `Discards uncommitted changes: ${text}`)
      return r('medium', `Switches or restores files: ${text}`)
    case 'filter-branch': case 'filter-repo': case 'replace':
      return r('high', `Rewrites history: ${text}`)
    case 'commit':
      return r('medium', `Commits: ${text}`)
    case 'add': case 'rm': case 'mv':
      return sub === 'add' ? r('medium', `Stages files: ${text}`) : r('medium', `Changes tracked files: ${text}`)
    case 'rebase':
      return r('medium', `Rebases: ${text}`)
    case 'fetch': case 'pull': case 'clone': case 'ls-remote': case 'submodule':
      return r('medium', `Talks to a remote: ${text}`)
    case 'gc': case 'prune':
      return has('--prune=now', '--aggressive') || sub === 'prune' ? r('medium', `Prunes objects: ${text}`) : r('medium', `Repacks: ${text}`)
    case 'update-ref': case 'symbolic-ref':
      return rest.includes('-d') ? r('high', `Deletes a ref: ${text}`) : r('medium', `Changes refs: ${text}`)
    default:
      if (GIT_MEDIUM.has(sub)) return r('medium', `Changes the repo: ${text}`)
      return r('high', `Runs git ${clip(sub, 30) || '(nothing)'}: an alias or a command it does not know`)
  }
}

function classifyNode (prog, args, ctx, text) {
  const isRunner = prog === 'npx' || prog === 'pnpx' || prog === 'bunx' || (prog === 'pnpm' && args[0] === 'dlx') || (prog === 'yarn' && args[0] === 'dlx') || (prog === 'npm' && (args[0] === 'exec' || args[0] === 'x'))
  if (isRunner) {
    const rest = dropOptions(prog === 'npx' || prog === 'pnpx' || prog === 'bunx' ? args : args.slice(1), /^-/)
    const bin = base(rest[0] || '').replace(/@[^/]*$/, '')
    if (TEST_BINARIES.has(bin)) return classifyProgram(bin, rest.slice(1), ctx, text, rest)
    return r('medium', `Downloads and runs a package: ${text}`)
  }
  const sub = args[0] || ''
  const global = args.some(a => a === '-g' || a === '--global' || a === '--location=global')
  if (/^(install|i|ci|add|update|up|upgrade|remove|rm|uninstall|un|link|dedupe|prune|rebuild)$/.test(sub) || (prog !== 'npm' && sub === '')) {
    if (global) return r('high', `Installs globally, outside the repo: ${text}`)
    return r('medium', `Installs packages: ${text}`)
  }
  if (/^(publish|unpublish|deprecate|dist-tag|owner|access|adduser|login|logout|token)$/.test(sub)) return r('high', `Publishes or changes the registry account: ${text}`)
  if (/^(test|t|tst)$/.test(sub)) return r('low', `Runs tests: ${text}`)
  if (/^(ls|list|ll|la|outdated|view|info|show|why|explain|audit|doctor|config|get|root|prefix|bin|help|search|pack|--version|-v|version)$/.test(sub) && !(sub === 'audit' && args.includes('fix')) && !(sub === 'config' && /^(set|delete|edit)$/.test(args[1] || ''))) {
    return r('low', `Read-only: ${text}`)
  }
  const script = sub === 'run' || sub === 'run-script' ? args[1] : sub
  if (script && TEST_SCRIPTS.test(script)) return r('low', `Runs tests: ${text}`)
  return r('medium', `Runs a package script: ${text}`)
}

function classifyToolchain (prog, args, text) {
  const sub = args[0] || ''
  const tests = {
    cargo: /^(test|check|clippy|fmt|bench|doc|tree|metadata|verify-project)$/,
    go: /^(test|vet|list|version|env|doc|fmt)$/,
    flutter: /^(test|analyze|doctor|devices|--version)$/,
    dart: /^(test|analyze|format|--version|info)$/,
    dotnet: /^(test|--info|--version|--list-sdks)$/,
    mvn: /^(test|verify|validate|dependency:tree|-v)$/,
    gradle: /^(test|check|lint|tasks|dependencies|--version|help)$/,
    gradlew: /^(test|check|lint|tasks|dependencies|--version|help)$/,
    swift: /^(test|--version)$/,
    make: /^(test|tests|check|lint|typecheck|-n|--dry-run)$/,
    just: /^(test|check|lint|--list|-l)$/,
    task: /^(test|check|lint|--list)$/,
    mix: /^(test|format --check-formatted|credo)$/,
    deno: /^(test|lint|check|fmt --check|info)$/,
    rake: /^(test|spec)$/,
    tox: /./,
    nox: /./,
    bundle: /^(exec rspec|list|show|outdated|check)$/,
    uv: /^(tree|--version)$/,
    poetry: /^(show|check|--version)$/,
    pip: /^(list|show|freeze|check|--version|download)$/,
    pip3: /^(list|show|freeze|check|--version)$/,
    gem: /^(list|search|info|--version)$/,
    composer: /^(show|validate|outdated|test)$/
  }[prog]
  if (prog === 'python' || prog === 'python3') {
    if (args[0] === '-m' && /^(pytest|unittest|mypy|pyright|ruff|flake8|pylint|compileall|doctest|tox|nox)$/.test(args[1] || '')) {
      return args.some(a => FIX_FLAGS.test(a)) ? r('medium', `Rewrites files: ${text}`) : r('low', `Runs tests or checks: ${text}`)
    }
    if (args[0] === '-m' && /^(pip|venv|http\.server)$/.test(args[1] || '')) return /^(list|show|freeze|check)$/.test(args[2] || '') ? r('low', `Read-only: ${text}`) : r('medium', `Runs python -m ${args[1]}: ${text}`)
    return r('medium', `Runs a Python script: ${text}`)
  }
  if (prog === 'node' || prog === 'ruby') {
    if (args.includes('--test') || args.includes('--check')) return r('low', `Runs tests: ${text}`)
    return r('medium', `Runs a ${prog === 'node' ? 'Node' : 'Ruby'} script: ${text}`)
  }
  if (prog === 'make' && !args.length) return r('medium', 'Runs the default make target')
  const joined = args.slice(0, 2).join(' ')
  if (tests && (tests.test(sub) || tests.test(joined))) {
    if (args.some(a => FIX_FLAGS.test(a) || a === '--fix')) return r('medium', `Rewrites files: ${text}`)
    if (/^(fmt|format)$/.test(sub) && !args.some(a => /--check|--set-exit-if-changed|--output=none|-n/.test(a))) return r('medium', `Formats files: ${text}`)
    return /test|check|analyze|clippy|vet|lint|verify|spec|credo/.test(sub + ' ' + joined) ? r('low', `Runs tests or checks: ${text}`) : r('low', `Read-only: ${text}`)
  }
  if (/^(install|add|remove|uninstall|update|upgrade|sync|get|pub|lock|i)$/.test(sub)) {
    if (args.some(a => a === '--global' || a === '-g' || a === '--user' || a === '--system' || a === '--break-system-packages')) return r('high', `Installs outside the repo: ${text}`)
    return r('medium', `Installs packages: ${text}`)
  }
  if (/^(publish|release|upload|push|login|deploy)$/.test(sub)) return r('high', `Publishes or deploys: ${text}`)
  return r('medium', `Runs ${prog} ${sub}`.trim() + (text ? `: ${text}` : ''))
}

function classifyNetwork (prog, args, text, ctx) {
  // file:// URLs read local files; output options write them.
  const files = args.filter(a => /^file:/i.test(a))
  for (const f of files) {
    const p = f.replace(/^file:(\/\/[^/]*)?/i, '')
    if (secretKind(p) || secretKind(resolvePath(p, ctx))) return r('high', `Reads a secrets path through ${prog}: ${clip(p, 40)}`)
  }
  if (files.length) return r('medium', `Reads local files through ${prog}: ${text}`)
  if (args.some(a => /^(-K|--config)(=|$)/.test(a))) return r('high', `Runs ${prog} with a config file: ${text}`)
  const out = optionValue(args, prog === 'wget' ? /^(-O|--output-document|-P|--directory-prefix|-o|--output-file|-a|--append-output)$/ : /^(-o|--output|-D|--dump-header|-c|--cookie-jar|--trace|--trace-ascii|--stderr|--output-dir)$/)
  if (out !== null && out !== '-' && writeTarget(out, ctx).where !== 'repo' && writeTarget(out, ctx).where !== 'none') return writeRisk(out, ctx, 'Downloads to')
  const urls = args.filter(a => !a.startsWith('-') && hostOf(a))
  const sends = args.some(a => /^(-d|--data.*|-F|--form.*|-T|--upload-file|--post-data|--post-file|--body-data|--body-file|--json)$/.test(a) || /^-[a-zA-Z]*[dFT]$/.test(a)) ||
    args.some((a, i) => (a === '-X' || a === '--request' || a === '--method') && /^(POST|PUT|PATCH|DELETE)$/i.test(args[i + 1] || ''))
  const hosts = urls.map(hostOf)
  if (!hosts.length) return r('medium', `Network request: ${text}`)
  const unknown = hosts.find(h => !isLocalHost(h) && !isKnownHost(h))
  if (unknown) return r('high', `Network to an unknown host (${unknown}): ${text}`)
  if (hosts.every(isLocalHost)) return sends ? r('medium', `Sends data to a local server: ${text}`) : r('low', `Local request: ${text}`)
  return sends ? r('high', `Sends data over the network: ${text}`) : r('medium', `Downloads from ${hosts.find(h => !isLocalHost(h))}: ${text}`)
}

function classifyDocker (args, text) {
  const sub = args[0] || ''
  if (/^(ps|images|logs|inspect|version|info|stats|top|port|diff|history|events|search)$/.test(sub)) return r('low', `Read-only: ${text}`)
  if (sub === 'compose' || sub === 'container' || sub === 'image' || sub === 'volume' || sub === 'network' || sub === 'system' || sub === 'buildx') {
    const s2 = args[1] || ''
    if (/^(ps|ls|logs|config|images|inspect|top|version|df|port)$/.test(s2)) return r('low', `Read-only: ${text}`)
    if (/^(rm|prune|down|kill|rmi)$/.test(s2)) return r('high', `Removes containers, images or volumes: ${text}`)
    return r('medium', `Runs containers: ${text}`)
  }
  if (/^(rm|rmi|kill|prune)$/.test(sub)) return r('high', `Removes containers or images: ${text}`)
  if (sub === 'push' || sub === 'login') return r('high', `Pushes to a registry: ${text}`)
  if (sub === 'run' && args.some(a => a === '--privileged' || /^-v\/:|^--volume=\/:|^\/:\//.test(a) || a === '--pid=host' || a === '--net=host' || a === '--network=host')) {
    return r('high', `Runs a privileged container: ${text}`)
  }
  return r('medium', `Runs containers: ${text}`)
}

function classifyGh (args, text) {
  const [a, b] = args
  if (/^(view|list|status|diff|checks|search|browse)$/.test(b || '') || /^(status|search|browse|--version)$/.test(a || '') || (a === 'api' && !args.some(x => /^(-X|--method)$/.test(x)) && !args.some(x => /^(-f|-F|--field|--raw-field|--input)$/.test(x)))) {
    return r('low', `Read-only: ${text}`)
  }
  if (a === 'auth' || a === 'secret' || a === 'ssh-key' || a === 'gpg-key' || (a === 'release' && /^(create|delete|upload|edit)$/.test(b || '')) || (a === 'repo' && /^(delete|archive|rename|edit)$/.test(b || '')) || (a === 'pr' && b === 'merge')) {
    return r('high', `Changes GitHub: ${text}`)
  }
  return r('medium', `Uses GitHub: ${text}`)
}

// --- tools --------------------------------------------------------------------

const READ_TOOLS = new Set(['Read', 'Grep', 'Glob', 'LS', 'NotebookRead'])
const EDIT_TOOLS = new Set(['Edit', 'Write', 'MultiEdit', 'NotebookEdit'])
const SAFE_TOOLS = {
  TodoWrite: 'Updates the to-do list',
  TodoRead: 'Reads the to-do list',
  WebSearch: 'Searches the web',
  BashOutput: 'Reads a background command\'s output',
  TaskOutput: 'Reads a task\'s output',
  Task: 'Starts a subagent (its tools ask separately)',
  Agent: 'Starts a subagent (its tools ask separately)',
  ListMcpResourcesTool: 'Lists MCP resources',
  ReadMcpResourceTool: 'Reads an MCP resource'
}

function toolPath (input) {
  if (!input || typeof input !== 'object') return null
  for (const k of ['file_path', 'notebook_path', 'path']) if (typeof input[k] === 'string' && input[k]) return input[k]
  return null
}

// Every path an edit touches: its file, and all files of a patch (Codex's
// apply_patch carries `files`).
function toolPaths (input) {
  const first = toolPath(input)
  const all = first ? [first] : []
  if (input && Array.isArray(input.files)) for (const f of input.files) if (typeof f === 'string' && f && !all.includes(f)) all.push(f)
  return all
}

// The directory a shell call says it runs in (Gemini's dir_path, Codex's
// workdir), when it gives one.
function commandDir (input) {
  for (const k of ['cwd', 'workdir', 'dir_path', 'directory']) if (typeof input[k] === 'string' && input[k]) return input[k]
  return null
}

// ctx.realpath (when given) resolves symlinks; a path whose real target
// differs is judged by both.
function realOf (p, ctx) {
  if (typeof ctx.realpath !== 'function') return null
  const abs = resolvePath(p, ctx)
  let real = null
  try { real = abs ? ctx.realpath(abs) : null } catch {}
  return real && real !== abs ? real : null
}

function classifyEdit (tool, p, ctx) {
  const t = writeTarget(p, ctx)
  const rel = short(p, ctx)
  if (t.where === 'secret') return r('high', `Writes a secrets path (${t.kind}): ${rel}`)
  if (t.where === 'outside') return r('high', `Writes outside the repo: ${rel}`)
  if (/(^|\/)\.git\//.test(t.abs || '')) return r('high', `Writes inside .git: ${rel}`)
  if (/(^|\/)\.claude\/settings(\.local)?\.json$/.test(t.abs || '')) return r('high', `Changes Claude Code permissions: ${rel}`)
  if (/(^|\/)\.(github\/workflows|gitlab-ci\.yml|husky)\b|(^|\/)\.git-hooks?\//.test(t.abs || '')) return r('medium', `Edits CI or git hooks: ${rel}`)
  if (t.where === 'temp') return r('medium', `Writes a temp file: ${rel}`)
  return r('medium', `${tool === 'Write' ? 'Writes' : 'Edits'} ${rel}`)
}

function classify (toolName, toolInput, ctx = {}) {
  const input = toolInput && typeof toolInput === 'object' ? toolInput : {}
  const tool = typeof toolName === 'string' ? toolName : ''
  if (input._truncated) return r('high', 'Tool input too large to check')
  if (tool === 'PowerShell') return r('high', 'PowerShell commands are not checked: review it')
  if (tool === 'Bash') {
    const dir = commandDir(input)
    if (dir !== null) {
      const abs = resolvePath(dir, ctx)
      const root = ctx.root || ctx.cwd
      if (!abs || !root || !inside(abs, root)) return r('high', `Runs in a directory outside the repo: ${short(dir, ctx)}`)
      return classifyBash(input.command, { ...ctx, cwd: abs })
    }
    return classifyBash(input.command, ctx)
  }
  if (READ_TOOLS.has(tool)) {
    const p = toolPath(input)
    const abs = p ? resolvePath(p, ctx) : null
    const real = p ? realOf(p, ctx) : null
    const kind = secretKind(abs) || secretKind(p) || secretKind(real) || (typeof input.pattern === 'string' && tool === 'Glob' ? secretKind(input.pattern.replace(/\*+/g, '')) : null)
    if (kind) return r('high', `Reads a secrets path (${kind}): ${short(p || input.pattern, ctx)}${real && secretKind(real) ? ' (through a link)' : ''}`)
    const verb = { Read: 'Reads', NotebookRead: 'Reads', Grep: 'Searches', Glob: 'Lists files', LS: 'Lists' }[tool]
    const what = p ? short(p, ctx) : typeof input.pattern === 'string' ? clip(input.pattern, 50) : ''
    return r('low', `${verb}${what ? ` ${what}` : ''}${tool === 'Grep' && typeof input.pattern === 'string' && p ? ` for ${clip(input.pattern, 30)}` : ''}`)
  }
  if (EDIT_TOOLS.has(tool)) {
    const all = toolPaths(input)
    if (!all.length) return r('medium', `${tool} without a path`)
    let result = r('low', '')
    for (const p of all) {
      result = max(result, classifyEdit(tool, p, ctx))
      const real = realOf(p, ctx)
      if (real) {
        const through = classifyEdit(tool, real, ctx)
        if (rank(through.level) > rank(result.level)) result = r(through.level, `${through.reason} (through a link)`)
      }
    }
    return result
  }
  if (tool === 'WebFetch') {
    const host = hostOf(input.url)
    if (!host) return r('medium', 'Fetches a URL')
    if (isLocalHost(host)) return r('low', `Fetches a local page: ${host}`)
    if (isKnownHost(host)) return r('low', `Fetches ${host}`)
    return r('medium', `Fetches an unknown site: ${host}`)
  }
  if (SAFE_TOOLS[tool]) return r('low', SAFE_TOOLS[tool])
  if (tool === 'ExitPlanMode') return r('medium', 'Approves the plan; edits follow')
  if (tool === 'KillShell' || tool === 'KillBash' || tool === 'TaskStop') return r('medium', 'Stops a background command')
  if (tool.startsWith('mcp__')) return r('medium', `MCP tool ${tool.split('__').slice(1).join(' › ')}`)
  return r('medium', `${tool || 'Unknown tool'}: effects unknown`)
}

// Only low risk goes into "Approve all safe". Plans and questions never do.
function batchable (toolName, risk) {
  return !!risk && risk.level === 'low' && typeof toolName === 'string' && !!toolName && toolName !== 'ExitPlanMode' && toolName !== 'AskUserQuestion'
}

module.exports = { classify, classifyBash, batchable, secretKind, resolvePath, inside, hostOf, isLocalHost, isKnownHost, LEVELS, rank }
