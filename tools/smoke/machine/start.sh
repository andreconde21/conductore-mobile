#!/bin/bash
# Entry point of the smoke machine: a Herdr server with two workspaces
# that share the label "shop", one fake agent in each (a waiting
# permission, a waiting question), then sshd in the foreground.
set -eu
su smoke -s /bin/bash -c '
  set -eu
  export PATH="$HOME/.local/bin:$PATH"
  mkdir -p ~/projects/shop ~/work/shop ~/.config/herdr
  # No first-run tour over the phone terminal, no update checks.
  printf "onboarding = false\n\n[update]\nversion_check = false\nmanifest_check = false\n" \
    >~/.config/herdr/config.toml
  setsid herdr server >/tmp/herdr-server.log 2>&1 </dev/null &
  for _ in $(seq 50); do herdr workspace list >/dev/null 2>&1 && break; sleep 0.2; done
  herdr workspace create --label shop --cwd "$HOME/projects/shop" \
    --env SMOKE_AGENT=permission >/dev/null
  herdr workspace create --label shop --cwd "$HOME/work/shop" \
    --env SMOKE_AGENT=question --no-focus >/dev/null
  for pane in $(herdr pane list | node -e "
    let s = \"\"; process.stdin.on(\"data\", d => s += d).on(\"end\", () => {
      const doc = JSON.parse(s); const r = doc.result || doc
      for (const p of r.panes || r) console.log(p.pane_id)
    })"); do
    herdr pane run "$pane" fake-claude.sh >/dev/null
  done
'
echo "smoke machine ready"
exec /usr/sbin/sshd -D -e
