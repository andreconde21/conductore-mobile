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
  [/^\/etc\/(shadow|gshadow|sudoers)/, 'system credentials']
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
  return rel === '' || (!rel.startsWith('..') && !path.isAbsolute(rel))
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

function hostOf (url) {
  if (typeof url !== 'string') return null
  const m = /^[a-z][a-z0-9+.-]*:\/\/(?:[^@/]*@)?(\[[^\]]+\]|[^/:?#]+)/i.exec(url.trim())
  if (m) return m[1].toLowerCase().replace(/^\[|\]$/g, '')
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

const READ_ONLY = new Set([
  'ls', 'll', 'la', 'cat', 'bat', 'head', 'tail', 'less', 'more', 'wc', 'grep', 'egrep', 'fgrep', 'rg', 'ag', 'ack', 'fd', 'fdfind',
  'pwd', 'echo', 'printf', 'which', 'whereis', 'type', 'file', 'stat', 'du', 'df', 'tree', 'date', 'cal', 'whoami', 'id', 'groups',
  'uname', 'hostname', 'printenv', 'basename', 'dirname', 'realpath', 'readlink', 'sort', 'uniq', 'cut', 'tr', 'diff', 'cmp',
  'comm', 'jq', 'yq', 'column', 'nl', 'od', 'xxd', 'hexdump', 'md5sum', 'sha1sum', 'sha256sum', 'sha512sum', 'cksum', 'ps',
  'pgrep', 'free', 'uptime', 'lsof', 'ss', 'netstat', 'true', 'false', 'test', '[', 'sleep', 'seq', 'cd', 'pushd', 'popd',
  'tldr', 'man', 'nproc', 'lscpu', 'lsblk', 'vmstat', 'iostat', 'locale', 'tput', 'strings', 'rev', 'fold', 'fmt', 'expand',
  'awk', 'gawk', 'sed', 'look', 'zcat', 'zgrep', 'bzcat', 'xzcat', 'getent', 'dig', 'nslookup', 'host', 'ping', 'git-lfs'
])

const SHELLS = new Set(['sh', 'bash', 'zsh', 'dash', 'ksh', 'fish'])
const INTERPRETERS = new Set([...SHELLS, 'python', 'python3', 'node', 'perl', 'ruby', 'php', 'deno', 'bun'])
const WRAPPERS = new Set(['env', 'time', 'nice', 'nohup', 'command', 'builtin', 'stdbuf', 'ionice', 'chronic', 'caffeinate'])
const ROOT_WRAPPERS = new Set(['sudo', 'su', 'doas', 'pkexec', 'run0'])
const NETWORK = new Set(['curl', 'wget', 'http', 'https', 'xh', 'aria2c'])
const REMOTE = new Set(['ssh', 'scp', 'sftp', 'rsync', 'ftp', 'telnet', 'nc', 'ncat', 'netcat', 'socat', 'mosh'])
const DISK = new Set(['dd', 'mkfs', 'fdisk', 'sfdisk', 'parted', 'gdisk', 'wipefs', 'shred', 'mkswap', 'swapon', 'swapoff', 'mount', 'umount', 'losetup', 'cryptsetup'])
const POWER = new Set(['shutdown', 'reboot', 'halt', 'poweroff', 'init', 'telinit'])
const PKG_MANAGERS = new Set(['npm', 'pnpm', 'yarn', 'bun'])

const TEST_SCRIPTS = /^(test|tests|t|lint|lint:.*|test:.*|check|typecheck|type-check|tsc|format:check|fmt:check|analyze|vitest|jest|spec|e2e:.*|coverage)$/
const TEST_BINARIES = new Set(['jest', 'vitest', 'mocha', 'ava', 'tap', 'pytest', 'py.test', 'tox', 'nox', 'mypy', 'pyright', 'rspec', 'phpunit', 'phpstan', 'shellcheck', 'hadolint', 'golangci-lint', 'ktlint', 'swiftlint', 'eslint', 'prettier', 'stylelint', 'tsc', 'ruff', 'flake8', 'pylint', 'black', 'isort', 'rubocop', 'actionlint', 'yamllint', 'markdownlint', 'biome', 'oxlint'])

// Flags that make a linter or formatter rewrite files.
const FIX_FLAGS = /^(--fix|--fix-dry-run=false|--write|-w|--in-place|-i|--apply|--unsafe-fixes)$/

function classifyBash (command, ctx, depth = 0) {
  if (typeof command !== 'string' || !command.trim()) return r('medium', 'Runs an empty or unreadable command')
  const parsed = shell.parse(command)
  let result = r('low', '')
  const reasons = []
  for (const seg of parsed.segments) {
    const one = classifySegment(seg, ctx, depth, parsed.segments)
    reasons.push(one)
    result = max(result, one)
  }
  for (const inner of parsed.substitutions) {
    const sub = depth < 3 ? classifyBash(inner, ctx, depth + 1) : r('medium', 'Nested command substitution')
    result = max(result, sub.level === 'low' ? r('medium', `Runs a command substitution: ${clip(inner)}`) : sub)
  }
  if (!parsed.complete) result = max(result, r('medium', 'Command has unbalanced quotes or an open heredoc'))
  // `curl … | sh` says more than "network to an unknown host".
  const piped = reasons.find(x => x.level === 'high' && x.reason.startsWith('Pipes into'))
  if (piped) return piped
  if (!parsed.segments.length && !parsed.substitutions.length) return r('medium', 'Runs an empty or unreadable command')
  if (result.level === 'low') {
    // Low: say what it is ("Read-only: git status", "Runs tests: npm test").
    const tests = reasons.find(x => x.reason.startsWith('Runs tests'))
    if (tests) return tests
    if (reasons.length === 1) return reasons[0]
    const names = [...new Set(parsed.segments.map(commandName).filter(n => n && n !== 'cd'))]
    return r('low', `Read-only: ${clip(names.join(', '))}`)
  }
  return result
}

// "git status", "npm test", "ls": what a segment runs, for reasons.
function commandName (seg) {
  const words = shell.stripAssignments(seg.words)
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

// One simple command: words (quotes removed) and its redirections.
function classifySegment (seg, ctx, depth, all) {
  let words = shell.stripAssignments(seg.words)
  let result = r('low', '')
  // Redirections: where output lands.
  for (const { op, target } of seg.redirects) {
    if (op.startsWith('<') && op !== '<>') {
      if (op === '<' && secretKind(resolvePath(target, ctx) || target)) result = max(result, r('high', `Reads a secrets path: ${short(target, ctx)}`))
      continue
    }
    result = max(result, writeRisk(target, ctx, 'Writes'))
  }
  // Any word naming a secrets path.
  for (const w of words.slice(1)) {
    const kind = secretKind(w) || (w.includes('/') || w.startsWith('~') ? secretKind(resolvePath(w, ctx)) : null)
    if (kind) { result = max(result, r('high', `Touches a secrets path (${kind}): ${short(w, ctx)}`)); break }
  }
  // Unwrap env/time/nice/timeout/xargs; sudo is high by itself.
  for (let guard = 0; guard < 6 && words.length; guard++) {
    const prog = base(words[0])
    if (ROOT_WRAPPERS.has(prog)) return max(result, r('high', `Runs as root (${prog})`))
    if (WRAPPERS.has(prog)) { words = shell.stripAssignments(dropOptions(words.slice(1), prog === 'env' ? /^-[iu0]|^--/ : /^-/)); continue }
    if (prog === 'timeout') { words = dropOptions(words.slice(1), /^-/).slice(1); continue }
    if (prog === 'xargs') { words = dropXargsOptions(words.slice(1)); if (!words.length) words = ['echo']; continue }
    if (prog === 'exec') { words = words.slice(1); continue }
    break
  }
  if (!words.length) return result.level === 'low' ? r('low', 'No command (redirection only)') : result
  const prog = base(words[0])
  const args = words.slice(1)
  const text = clip(words.join(' '))

  // Piped into a shell or interpreter reading stdin: `curl … | sh`.
  if (seg.pipedFrom && INTERPRETERS.has(prog) && !args.some(a => !a.startsWith('-') || a === '-c' || a === '-e')) {
    return r('high', `Pipes into ${prog}: runs whatever the previous command prints`)
  }
  if (SHELLS.has(prog) || prog === 'eval' || prog === 'source' || prog === '.') {
    const ci = args.indexOf('-c')
    if (ci !== -1 && typeof args[ci + 1] === 'string' && depth < 3) {
      const inner = classifyBash(args[ci + 1], ctx, depth + 1)
      return max(result, inner)
    }
    if (prog === 'eval') return r('high', 'Evaluates a constructed command (eval)')
    if (!args.length) return max(result, r('medium', `Starts ${prog}`))
    return max(result, r('medium', `Runs a script: ${text}`))
  }
  if (INTERPRETERS.has(prog) && (args.includes('-c') || args.includes('-e') || args.includes('--eval'))) {
    return max(result, r('medium', `Runs inline ${prog} code`))
  }

  const own = classifyProgram(prog, args, ctx, text, words)
  return max(result, own)
}

function base (w) {
  return String(w).replace(/^.*\//, '')
}

function dropOptions (words, re) {
  let k = 0
  while (k < words.length && re.test(words[k])) k++
  return words.slice(k)
}

function dropXargsOptions (words) {
  let k = 0
  while (k < words.length && words[k].startsWith('-')) {
    if (/^-(n|I|L|P|d|s|E|a)$/.test(words[k])) k++
    k++
  }
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

// Non-option arguments (paths, mostly).
const operands = args => args.filter(a => !a.startsWith('-'))

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
    if (args.some(a => /^-(exec|execdir|ok|okdir)$/.test(a))) return r('medium', `Runs a command per file (find -exec): ${text}`)
    if (args.some(a => /^-f(print|ls|printf)/.test(a))) return r('medium', `Writes find output to a file: ${text}`)
    return r('low', `Read-only: ${text}`)
  }
  if (prog === 'sed' && args.some(a => /^-i|^--in-place/.test(a) || /^-[a-zA-Z]*i/.test(a))) return pathWrites(operands(args).slice(1), ctx, 'Edits', text)
  if ((prog === 'awk' || prog === 'gawk') && args.some(a => /system\s*\(|[^=!<>]>\s*"|\|\s*"/.test(a))) return r('medium', `awk that runs commands or writes files: ${text}`)
  if (prog === 'tee') return pathWrites(operands(args), ctx, 'Writes', text)
  if (NETWORK.has(prog)) return classifyNetwork(prog, args, text)
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

function classifyGit (args, ctx, text) {
  // Skip global options: -C dir, -c k=v, --no-pager, --git-dir=...
  let k = 0
  while (k < args.length && args[k].startsWith('-')) {
    if (args[k] === '-C' || args[k] === '-c') k++
    k++
  }
  const sub = args[k] || ''
  const rest = args.slice(k + 1)
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
      return r('medium', `Changes the repo: ${text}`)
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

function classifyNetwork (prog, args, text) {
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

function classify (toolName, toolInput, ctx = {}) {
  const input = toolInput && typeof toolInput === 'object' ? toolInput : {}
  const tool = typeof toolName === 'string' ? toolName : ''
  if (input._truncated) return r('medium', 'Tool input too large to check')
  if (tool === 'Bash' || tool === 'PowerShell') return classifyBash(input.command, ctx)
  if (READ_TOOLS.has(tool)) {
    const p = toolPath(input)
    const abs = p ? resolvePath(p, ctx) : null
    const kind = secretKind(abs) || secretKind(p) || (typeof input.pattern === 'string' && tool === 'Glob' ? secretKind(input.pattern.replace(/\*+/g, '')) : null)
    if (kind) return r('high', `Reads a secrets path (${kind}): ${short(p || input.pattern, ctx)}`)
    const verb = { Read: 'Reads', NotebookRead: 'Reads', Grep: 'Searches', Glob: 'Lists files', LS: 'Lists' }[tool]
    const what = p ? short(p, ctx) : typeof input.pattern === 'string' ? clip(input.pattern, 50) : ''
    return r('low', `${verb}${what ? ` ${what}` : ''}${tool === 'Grep' && typeof input.pattern === 'string' && p ? ` for ${clip(input.pattern, 30)}` : ''}`)
  }
  if (EDIT_TOOLS.has(tool)) {
    const p = toolPath(input)
    if (!p) return r('medium', `${tool} without a path`)
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

// Only low risk goes into "Approve all safe". Plans never do.
function batchable (toolName, risk) {
  return !!risk && risk.level === 'low' && toolName !== 'ExitPlanMode' && toolName !== 'AskUserQuestion'
}

module.exports = { classify, classifyBash, batchable, secretKind, resolvePath, inside, hostOf, isLocalHost, isKnownHost, LEVELS, rank }
