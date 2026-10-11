#!/bin/bash
# A stand-in for Claude Code in a Herdr pane of the smoke machine. It
# writes a short transcript and sends the hook events Claude Code would,
# through the real conductore-hook, then blocks on one request:
#   SMOKE_AGENT=permission  Bash "npm test" waits for approval
#   SMOKE_AGENT=question    AskUserQuestion "Which database?" waits
# Whatever the phone answers is printed, and the agent goes idle.
set -u
export PATH="$HOME/.local/bin:$PATH"
export CONDUCTORE_PERMISSION_TIMEOUT=1800
kind=${SMOKE_AGENT:-permission}
case $kind in
  permission) sid=5e0c1a7e-0000-4000-8000-000000000001 ;;
  *) sid=5e0c1a7e-0000-4000-8000-000000000002 ;;
esac
cwd=$PWD
dir="$HOME/.claude/projects/$(printf %s "$cwd" | tr / -)"
transcript="$dir/$sid.jsonl"
mkdir -p "$dir"
now() { date -u +%Y-%m-%dT%H:%M:%S.000Z; }

# One transcript line: type, uuid suffix, message JSON.
line() {
  printf '{"type":"%s","uuid":"%s-%s","sessionId":"%s","cwd":"%s","timestamp":"%s","message":%s}\n' \
    "$1" "$sid" "$2" "$sid" "$cwd" "$(now)" "$3" >>"$transcript"
}

# One hook event: name, extra JSON fields (without braces). Prints the
# hook's stdout (the decision of a PermissionRequest).
hook() {
  printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","hook_event_name":"%s","permission_mode":"default"%s}' \
    "$sid" "$transcript" "$cwd" "$1" "${2:+,$2}" | conductore-hook "$1"
}

report() {
  [ -n "${HERDR_PANE_ID:-}" ] || return 0
  herdr pane report-agent --source smoke --agent claude --state "$1" "$HERDR_PANE_ID" >/dev/null 2>&1 || true
}

printf '\033[1mClaude Code\033[0m (smoke-test stand-in, %s)\n' "$kind"
hook SessionStart '"source":"startup"'
report working
if [ "$kind" = permission ]; then
  prompt='Run the shop tests'
  line user u1 "{\"role\":\"user\",\"content\":\"$prompt\"}"
  hook UserPromptSubmit "\"prompt\":\"$prompt\""
  line assistant a1 '{"role":"assistant","model":"claude-smoke","content":[{"type":"text","text":"I will run the test suite of the shop."}]}'
  line assistant a2 '{"role":"assistant","model":"claude-smoke","content":[{"type":"tool_use","id":"toolu_smoke1","name":"Bash","input":{"command":"npm test","description":"Run the tests"}}]}'
  printf '> %s\n\nBash(npm test) needs your permission.\n' "$prompt"
  report blocked
  input='{"command":"npm test","description":"Run the tests"}'
  decision=$(hook PermissionRequest "\"tool_name\":\"Bash\",\"tool_input\":$input")
else
  prompt='Set up the database for the shop'
  line user u1 "{\"role\":\"user\",\"content\":\"$prompt\"}"
  hook UserPromptSubmit "\"prompt\":\"$prompt\""
  line assistant a1 '{"role":"assistant","model":"claude-smoke","content":[{"type":"text","text":"Before I start, one question."}]}'
  input='{"questions":[{"question":"Which database?","header":"DB","multiSelect":false,"options":[{"label":"Postgres","description":"the usual"},{"label":"SQLite","description":"one file"}]}]}'
  line assistant a2 "{\"role\":\"assistant\",\"model\":\"claude-smoke\",\"content\":[{\"type\":\"tool_use\",\"id\":\"toolu_smoke2\",\"name\":\"AskUserQuestion\",\"input\":$input}]}"
  printf '> %s\n\nClaude asks: Which database? (Postgres / SQLite)\n' "$prompt"
  report blocked
  decision=$(hook PermissionRequest "\"tool_name\":\"AskUserQuestion\",\"tool_input\":$input")
fi
printf 'phone answered: %s\n' "${decision:-nothing}"
line assistant a3 '{"role":"assistant","model":"claude-smoke","content":[{"type":"text","text":"Done."}]}'
hook Stop '"stop_hook_active":false'
report idle
exec sleep infinity
