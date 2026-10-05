#!/usr/bin/env node
'use strict'

// Records how a real bash splits the probes (probes.js) into commands and
// words: bash-words.json, read by test/shell-safety.test.js.
//
//   node test/fixtures/shell/generate-bash-words.js
//
// Runs bash in a throwaway container with no network, a read-only root, an
// empty working directory and no mounts. Every probe is only printf
// segments (checked before anything runs); the probes reach bash as data
// on stdin, never through a shell string.

const fs = require('fs')
const path = require('path')
const { execFileSync } = require('child_process')
const shell = require('../../../lib/shell')
const probes = require('./probes')

const IMAGE = process.env.BASH_IMAGE || 'ubuntu:24.04'

for (const p of probes) {
  const parsed = shell.parse(p)
  if (!parsed.understood || !parsed.segments.every(s => s.words[s.assigns] === 'printf' && s.words[s.assigns + 1] === '%s\\0' && s.words[s.assigns + 2] === '@@')) {
    throw new Error(`not a printf-only probe: ${JSON.stringify(p)}`)
  }
}

const loop = 'while IFS= read -r -d "" p; do bash -c "$p"; printf "%s\\0" "@@END"; done'
const out = execFileSync('docker', ['run', '--rm', '-i', '--network', 'none', '--read-only', '--tmpfs', '/w', '-w', '/w', '-e', 'HOME=/h', IMAGE, 'bash', '-c', loop], {
  input: probes.map(p => p + '\0').join(''),
  maxBuffer: 1 << 24
}).toString('utf8')

const records = out.split('@@END\0').slice(0, probes.length)
const version = execFileSync('docker', ['run', '--rm', '--network', 'none', IMAGE, 'bash', '-c', 'echo "$BASH_VERSION"']).toString().trim()
const result = probes.map((command, k) => {
  const words = records[k].split('\0').slice(0, -1)
  const segments = []
  for (const w of words) {
    if (w === '@@') segments.push([])
    else segments[segments.length - 1].push(w)
  }
  return { command, segments }
})
fs.writeFileSync(path.join(__dirname, 'bash-words.json'), JSON.stringify({ bash: version, image: IMAGE, probes: result }, null, 1) + '\n')
console.log(`recorded ${result.length} probes with bash ${version}`)
