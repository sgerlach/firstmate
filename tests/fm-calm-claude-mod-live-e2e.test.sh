#!/usr/bin/env bash
# Live regression for the Claude Code Calm mod (.claude/mods/firstmate-calm) in a real
# Claude Code TUI under tmux, mirroring the Pi interactive case in
# tests/fm-calm-pi-extension.test.sh. It proves, against the installed Claude Code and
# the shipped project auto-load path (.claude/skills):
#   1. Loading the mod is its activation: with no environment opt-in, and with the
#      retired CLAUDE_CODE_ENABLE_FUNCTION_HOOKS set to 0, the hooks module loads from
#      the trusted project and /calm exists; with the preference off, the stock working
#      row, tool row, run-in-background pill, and narration draw.
#   2. /calm hides those rows already on screen and persists on; the sailboat replaces
#      the working row and moves; tool rows, the pill, the narration, and a
#      record-backed operational doorbell (the carrier Firstmate types into Claude Code,
#      which strips U+2063 from submitted prompts) draw at zero height; /calm restores
#      them and persists off, and hides them again and persists on, all without a Calm
#      output row in the transcript.
#   3. `claude --continue` restores the transcript with those rows still hidden.
#   4. With Calm off, the supervision notes draw from a store bin/fm-branch-outcome.sh
#      writes: the session-start replay, new sailboat and anchor lines, and the latch
#      note, each behind the plugin's `fm:` label, without moving a store marker or
#      reaching any model request, and a resume shows each anchor once.
# Everything is isolated: a temporary CLAUDE_CONFIG_DIR, project, and FM_HOME, a private
# tmux socket, and tests/assets/fm-claude-scripted-messages-api.py as the model, so no
# credential is read, no model token is spent, and nothing under ~/.claude changes.
# With nonessential traffic off, Claude Code resolves its remote rollout switches from
# their built-in defaults, so this proves the engine's load path for a trusted project,
# not what an account's switches serve.
# shellcheck disable=SC2016 # the scripted model, not this test shell, reads the prompt text
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_CLAUDE_CALM_LIVE_E2E claude tmux python3 jq

MOD="$ROOT/.claude/mods/firstmate-calm"
OPERATIONAL_INPUT="$ROOT/bin/fm-operational-input.sh"
SCRIPTED_API="$ROOT/tests/assets/fm-claude-scripted-messages-api.py"
CLAUDE_VERSION=$(claude --version 2>/dev/null || true)
[ -n "$CLAUDE_VERSION" ] || fail "claude is installed but reports no version"
LAB=$(fm_test_tmproot fm-calm-claude-live)
PROJECT="$LAB/project"
FM_HOME_DIR="$LAB/fmhome"
CONFIG_DIR="$LAB/claude-config"
REQUESTS="$LAB/model-requests.jsonl"
SOCKET="fm-calm-claude-$$"
SESSION="fm-calm-claude-e2e"
HULL='╲▁▁▁╱'
SAIL='◿│◣'
PILL='to run in background'
NARRATION='Let me read the notes.'
# A dummy key the scripted model accepts; only its last 20 characters are recorded as approved.
API_KEY='sk-ant-api03-fm-calm-live-scripted-model-00000000'
API_PID=''

cleanup() {
  local i=0
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  [ -z "$API_PID" ] || kill "$API_PID" 2>/dev/null || true
  # Claude's debug logger may still be flushing into the lab for a moment.
  while [ "$i" -lt 20 ] && pgrep -f "debug-file '$LAB/" >/dev/null 2>&1; do
    sleep 0.25
    i=$((i + 1))
  done
  rm -rf "$LAB" 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT

mkdir -p "$PROJECT/.claude/skills" "$FM_HOME_DIR/config" "$CONFIG_DIR"
ln -s "$MOD" "$PROJECT/.claude/skills/firstmate-calm"
printf 'alpha\nbeta\ngamma\n' >"$PROJECT/notes.txt"
printf 'off\n' >"$FM_HOME_DIR/config/calm"
# A configuration that has finished onboarding, trusts only the lab project, approves the
# dummy key, and lets the scripted Bash call run without a permission prompt.
jq -n --arg project "$PROJECT" --arg key "${API_KEY: -20}" '{
  hasCompletedOnboarding: true,
  theme: "dark",
  customApiKeyResponses: {approved: [$key], rejected: []},
  projects: {($project): {hasTrustDialogAccepted: true, hasCompletedProjectOnboarding: true, allowedTools: []}}
}' >"$CONFIG_DIR/.claude.json"
printf '{"permissions":{"allow":["Bash"]}}\n' >"$CONFIG_DIR/settings.json"

python3 "$SCRIPTED_API" "$LAB/api.port" "$REQUESTS" >"$LAB/api.log" 2>&1 &
API_PID=$!
i=0
while [ "$i" -lt 100 ] && [ ! -s "$LAB/api.port" ]; do
  sleep 0.1
  i=$((i + 1))
done
[ -s "$LAB/api.port" ] || fail "the scripted model API did not start: $(cat "$LAB/api.log" 2>/dev/null)"
API_PORT=$(cat "$LAB/api.port")

# Claude Code refuses to nest inside another Claude session, and an inherited config
# directory or API setting would leave the lab, so all of them are dropped.
unset_inherited() {
  local name
  while IFS= read -r name; do
    printf -- '-u %s ' "$name"
  done < <(env | grep -E '^(CLAUDECODE|CLAUDE_CODE_[A-Z_]+|CLAUDE_CONFIG_DIR|ANTHROPIC_[A-Z_]+)=' | cut -d= -f1 | sort -u)
}

launch() {  # <debug-log> <extra environment assignment or ''> [claude args...]
  local log=$1 extra=$2
  shift 2
  tmux -L "$SOCKET" kill-session -t "$SESSION" 2>/dev/null || true
  tmux -L "$SOCKET" new-session -d -s "$SESSION" -x 160 -y 44 -c "$PROJECT" \
    "env $(unset_inherited) $extra CLAUDE_CONFIG_DIR='$CONFIG_DIR' ANTHROPIC_BASE_URL='http://127.0.0.1:$API_PORT' ANTHROPIC_API_KEY='$API_KEY' FM_HOME='$FM_HOME_DIR' CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 DISABLE_AUTOUPDATER=1 CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --model claude-haiku-4-5 --debug-file '$log' $*; printf '\nCLAUDE_EXIT=%s\n' \"\$?\"; sleep 30"
}

screen() {
  tmux -L "$SOCKET" capture-pane -p -t "$SESSION" 2>/dev/null || true
}

send() {
  tmux -L "$SOCKET" send-keys -t "$SESSION" -l "$1"
}

enter() {
  tmux -L "$SOCKET" send-keys -t "$SESSION" Enter
}

quit_session() {
  send '/exit'
  enter
  sleep 2
}

# Whether the screen is a startup dialog rather than the session: the folder-trust
# dialog draws its own option cursor with the composer's glyph, so it is answered
# before any text is matched. The lab trusts its project, so this is a safety net.
dialog_open() {  # <screen text>
  case "$1" in
    *'trust this folder'*|*'Enter to confirm'*) return 0 ;;
  esac
  return 1
}

# The folder-trust dialog opens with its cursor on "No, exit", so Enter alone would
# end the session: move the cursor onto the trusting option first, then confirm.
answer_trust_dialog() {  # <screen text>
  local selected
  case "$1" in
    *'Yes, I trust this folder'*) : ;;
    *) return 0 ;;
  esac
  selected=$(printf '%s\n' "$1" | grep -F '❯' | head -1)
  case "$selected" in
    *'Yes, I trust this folder'*) enter ;;
    *) tmux -L "$SOCKET" send-keys -t "$SESSION" Down ;;
  esac
}

# Wait until the screen shows <text> (a fixed string), answering the folder-trust
# dialog on the way; the wait is iteration-counted so it stretches under load.
wait_screen() {  # <text> <what> [iterations]
  local text=$1 what=$2 limit=${3:-400} i=0 shot
  while [ "$i" -lt "$limit" ]; do
    shot=$(screen)
    case "$shot" in
      *'CLAUDE_EXIT='*)
        printf '%s\n' "$shot" >&2
        fail "Claude Code $CLAUDE_VERSION exited while waiting for $what"
        ;;
    esac
    if dialog_open "$shot"; then
      answer_trust_dialog "$shot"
    else
      case "$shot" in
        *"$text"*) return 0 ;;
      esac
    fi
    sleep 0.25
    i=$((i + 1))
  done
  printf '%s\n' "$(screen)" >&2
  fail "Claude Code $CLAUDE_VERSION never showed $what"
}

wait_idle() {  # wait for the composer prompt with no dialog over it
  wait_screen '❯' 'the composer prompt'
  # A settled composer, not a dialog cursor: give a late dialog one more chance.
  sleep 1
  if dialog_open "$(screen)"; then
    wait_screen '❯' 'the composer prompt after the startup dialog'
  fi
}

# Claude Code 2.1.280 and later log `hooks module fm@<source> loaded`; 2.1.272 had no source suffix.
MODULE_LOADED='hooks module fm(@[^ ]+)? loaded'

wait_module_loaded() {  # <debug-log> <how it was launched>
  local log=$1 how=$2 i=0
  while [ "$i" -lt 100 ] && ! grep -Eq "$MODULE_LOADED" "$log"; do
    sleep 0.1
    i=$((i + 1))
  done
  grep -Eq "$MODULE_LOADED" "$log" \
    || fail "Claude Code $CLAUDE_VERSION did not load the Calm hooks module from the project's .claude/skills path $how"
  if grep -E 'hooks module fm(@[^ ]+)? not loaded' "$log" >&2; then
    fail "Claude Code $CLAUDE_VERSION reported the Calm hooks module not loaded $how"
  fi
  # The engine logs one benign notice for every options-less hooks module ("options
  # requested but its manifest declares no userConfig"); anything else is a real problem.
  if grep -E '\[(WARN|ERROR)\].*(plugin fm[:@ ]|\[fm\]|module fm@)' "$log" | grep -v 'declares no userConfig' >&2; then
    fail "Claude Code $CLAUDE_VERSION loaded the Calm mod with a warning or error $how"
  fi
}

# Type a slash command prefix without submitting and report whether the typeahead
# lists the mod's command; then clear the composer.
command_listed() {  # <command>
  local listed=0 i=0 shot
  send "/$1"
  while [ "$i" -lt 40 ]; do
    shot=$(screen)
    case "$shot" in
      *"Toggle Firstmate's Calm"*) listed=1; break ;;
    esac
    sleep 0.1
    i=$((i + 1))
  done
  tmux -L "$SOCKET" send-keys -t "$SESSION" C-u
  sleep 0.3
  return $((1 - listed))
}

hull_column() {  # <screen text>
  printf '%s\n' "$1" | awk -v hull="$HULL" 'index($0, hull) { print index($0, hull); exit }'
}

# The scripted model answers this prompt with a narrated `sleep 8; cat notes.txt` Bash
# call and then a reply naming words that live only in notes.txt, so the settled turn is
# told apart from the echoed prompt by "gamma" on screen with no working row left.
PROMPT='Read notes.txt with the Bash tool, then reply with one short sentence naming the three words.'

# The stock working row on this build: `✢ Contemplating… (4s · ↓ 23 tokens)`.
working_row_shown() {  # <screen text>
  case "$1" in
    *'… ('*) return 0 ;;
  esac
  return 1
}

# Wait until the turn has settled: the answer is on screen and no working row or
# boat remains.
wait_settled() {  # <what> [iterations]
  local what=$1 limit=${2:-600} i=0 shot
  while [ "$i" -lt "$limit" ]; do
    shot=$(screen)
    case "$shot" in
      *'CLAUDE_EXIT='*)
        printf '%s\n' "$shot" >&2
        fail "Claude Code $CLAUDE_VERSION exited while waiting for $what"
        ;;
      *'gamma'*)
        if ! working_row_shown "$shot"; then
          case "$shot" in
            *"$HULL"*) ;;
            *) return 0 ;;
          esac
        fi
        ;;
    esac
    sleep 0.25
    i=$((i + 1))
  done
  printf '%s\n' "$(screen)" >&2
  fail "Claude Code $CLAUDE_VERSION never settled $what"
}

# Count the turns whose answer is on screen: one "gamma" reply per notes turn.
replies_shown() {  # <screen text>
  printf '%s\n' "$1" | grep -c 'alpha, beta, and gamma' || true
}

# --- 1. Loading is the activation: no opt-in, the retired opt-in off, Calm off ------
DEBUG_LOG_RETIRED="$LAB/debug-retired-off.log"
launch "$DEBUG_LOG_RETIRED" 'CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=0'
wait_idle
wait_module_loaded "$DEBUG_LOG_RETIRED" 'with CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=0'
command_listed calm || fail "Claude Code $CLAUDE_VERSION does not list /calm with CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=0"
quit_session

DEBUG_LOG_PLAIN="$LAB/debug-plain.log"
launch "$DEBUG_LOG_PLAIN" ''
wait_idle
wait_module_loaded "$DEBUG_LOG_PLAIN" 'with no environment opt-in'
command_listed calm || fail "Claude Code $CLAUDE_VERSION does not list /calm with no environment opt-in"
send "$PROMPT"
enter
# Sample every frame until the turn settles: the boat must never appear, and the stock
# working row and the run-in-background pill must both have been seen, or the Calm-on
# cases below could not tell hiding apart from absence.
saw_working=0
saw_pill=0
i=0
while [ "$i" -lt 600 ]; do
  off_frame=$(screen)
  case "$off_frame" in
    *"$HULL"*|*"$SAIL"*)
      printf '%s\n' "$off_frame" >&2
      fail "the working ship appeared although Calm is off"
      ;;
    *'CLAUDE_EXIT='*)
      printf '%s\n' "$off_frame" >&2
      fail "Claude Code $CLAUDE_VERSION exited during the Calm-off turn"
      ;;
  esac
  case "$off_frame" in
    *"$PILL"*) saw_pill=1 ;;
  esac
  if working_row_shown "$off_frame"; then
    saw_working=1
  elif [ "$saw_working" -eq 1 ]; then
    case "$off_frame" in
      *'gamma'*) break ;;
    esac
  fi
  sleep 0.1
  i=$((i + 1))
done
[ "$saw_working" -eq 1 ] || fail "Claude Code $CLAUDE_VERSION showed no stock working row during the Calm-off turn, so the Calm-on cases cannot be judged"
[ "$saw_pill" -eq 1 ] || fail "Claude Code $CLAUDE_VERSION showed no run-in-background pill during the Calm-off turn, so hiding it cannot be judged"
wait_settled 'the turn with Calm off'
off_settled=$(screen)
case "$off_settled" in
  *'shell command'*) : ;;
  *)
    printf '%s\n' "$off_settled" >&2
    fail "the stock tool row did not draw with Calm off"
    ;;
esac
case "$off_settled" in
  *"$NARRATION"*) : ;;
  *)
    printf '%s\n' "$off_settled" >&2
    fail "the mid-turn narration did not draw with Calm off"
    ;;
esac
quit_session
pass "Claude Code $CLAUDE_VERSION loads the Calm mod from .claude/skills with no environment opt-in and with CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=0, lists /calm, and with Calm off draws the stock working row, tool row, run-in-background pill, and narration"

# --- 2. /calm on: retroactive hiding, the boat, the doorbell, the toggles ---------
DEBUG_LOG_ON="$LAB/debug-on.log"
launch "$DEBUG_LOG_ON" '' --continue
wait_screen 'gamma' 'the Calm-off transcript resumed'
wait_module_loaded "$DEBUG_LOG_ON" 'on resume'
send '/calm'
enter
i=0
while [ "$i" -lt 200 ]; do
  hidden=$(screen)
  case "$hidden" in
    *'shell command'*|*"$NARRATION"*) ;;
    *) break ;;
  esac
  sleep 0.1
  i=$((i + 1))
done
case "$hidden" in
  *'shell command'*|*"$NARRATION"*)
    printf '%s\n' "$hidden" >&2
    fail "/calm on did not hide the tool row and narration already on screen"
    ;;
esac
case "$hidden" in
  *'gamma'*) : ;;
  *) fail "Calm on hid the genuine reply already on screen" ;;
esac
[ "$(cat "$FM_HOME_DIR/config/calm")" = on ] || fail "/calm did not persist on"

send "$PROMPT"
enter
wait_screen "$HULL" 'the working ship during a real turn' 200
boat_one=$(screen)
case "$boat_one" in
  *"$SAIL"*) : ;;
  *)
    printf '%s\n' "$boat_one" >&2
    fail "the working ship lost its sail"
    ;;
esac
column_one=$(hull_column "$boat_one")
moved=0
i=0
while [ "$i" -lt 600 ]; do
  on_frame=$(screen)
  case "$on_frame" in
    *"$PILL"*|*'shell command'*|*'sleep 8; cat notes.txt'*)
      printf '%s\n' "$on_frame" >&2
      fail "a tool row or the run-in-background pill drew while Calm was on"
      ;;
  esac
  if working_row_shown "$on_frame"; then
    printf '%s\n' "$on_frame" >&2
    fail "the stock working row drew while Calm was on"
  fi
  column=$(hull_column "$on_frame")
  [ -n "$column" ] && [ "$column" != "$column_one" ] && moved=1
  [ "$(replies_shown "$on_frame")" -ge 2 ] && [ -z "$column" ] && break
  sleep 0.1
  i=$((i + 1))
done
[ "$moved" -eq 1 ] || fail "the working ship never moved (hull stayed at column $column_one)"
wait_settled 'the turn with Calm on'
on_settled=$(screen)
case "$on_settled" in
  *"$HULL"*|*"$SAIL"*) fail "the working ship stayed on screen after the turn settled" ;;
  *'shell command'*|*"$NARRATION"*|*"$PILL"*)
    printf '%s\n' "$on_settled" >&2
    fail "a tool row, the pill, or the narration drew while Calm was on"
    ;;
esac

# Claude Code strips U+2063 from submitted prompts, so Firstmate types a plain doorbell
# naming a record that holds the envelope; that doorbell row draws at zero height while
# the answer stays visible.
DOORBELL_TEXT='Firstmate operational input waiting'
operational=$(printf 'signal: %s/state/probe.status changed. Reply with exactly OPERATIONAL_PROCESSED and nothing else.' "$LAB" \
  | FM_HOME="$FM_HOME_DIR" "$OPERATIONAL_INPUT" record watcher) \
  || fail "could not publish the operational probe record"
case "$operational" in
  *"$DOORBELL_TEXT"*) : ;;
  *) fail "the operational probe is not a record-backed doorbell: $operational" ;;
esac
send "$operational"
sleep 1
enter
# A long line typed in one burst can leave Claude Code's first Enter inside its paste
# handling; like Firstmate's own submit primitive, retry Enter only, never retype.
i=0
while [ "$i" -lt 4 ]; do
  sleep 2
  case "$(screen)" in
    *"❯ : $DOORBELL_TEXT"*) enter ;;
    *) break ;;
  esac
  i=$((i + 1))
done
wait_screen 'OPERATIONAL_PROCESSED' 'the operational answer' 600
sleep 1
operational_screen=$(screen)
case "$operational_screen" in
  *"$DOORBELL_TEXT"*|*'invisible character'*)
    printf '%s\n' "$operational_screen" >&2
    fail "the operational doorbell row drew while Calm was on"
    ;;
esac

# /calm off: rows restore, the preference persists off, no Calm output row.
send '/calm'
enter
wait_screen 'shell command' 'the restored tool row after /calm off' 200
[ "$(cat "$FM_HOME_DIR/config/calm")" = off ] || fail "/calm did not persist off"
restored=$(screen)
case "$restored" in
  *"$DOORBELL_TEXT"*) : ;;
  *)
    printf '%s\n' "$restored" >&2
    fail "/calm off did not restore the operational user row"
    ;;
esac
case "$restored" in
  *"$NARRATION"*) : ;;
  *)
    printf '%s\n' "$restored" >&2
    fail "/calm off did not restore the narration"
    ;;
esac
# The toggle answers with a transient notice, never a transcript row: the notice must
# leave the screen once it expires.
case "$restored" in
  *'Calm off'*) : ;;
  *)
    printf '%s\n' "$restored" >&2
    fail "/calm off showed no Calm off notice"
    ;;
esac
i=0
while [ "$i" -lt 60 ]; do
  restored=$(screen)
  case "$restored" in
    *'fm: Calm'*|*'Calm off'*) ;;
    *) break ;;
  esac
  sleep 0.25
  i=$((i + 1))
done
case "$restored" in
  *'fm: Calm'*|*'Calm off'*)
    printf '%s\n' "$restored" >&2
    fail "/calm left a Calm row in the transcript after its notice should have expired"
    ;;
esac

# /calm on: rows hide again, the preference persists on.
send '/calm'
enter
i=0
while [ "$i" -lt 200 ]; do
  hidden_again=$(screen)
  case "$hidden_again" in
    *'shell command'*|*"$NARRATION"*|*"$DOORBELL_TEXT"*) ;;
    *) break ;;
  esac
  sleep 0.1
  i=$((i + 1))
done
case "$hidden_again" in
  *'shell command'*|*"$NARRATION"*|*"$DOORBELL_TEXT"*)
    printf '%s\n' "$hidden_again" >&2
    fail "/calm on did not hide the rows again"
    ;;
esac
[ "$(cat "$FM_HOME_DIR/config/calm")" = on ] || fail "/calm did not persist on"
case "$hidden_again" in
  *'gamma'*) : ;;
  *) fail "Calm on hid a genuine assistant reply" ;;
esac
case "$hidden_again" in
  *'OPERATIONAL_PROCESSED'*) : ;;
  *) fail "Calm on hid the genuine answer to the doorbell" ;;
esac
quit_session
pass "Claude Code $CLAUDE_VERSION with Calm on: /calm hides the rows already on screen, the sailboat replaces and moves in the working row, tool rows, the run-in-background pill, the narration, and the record-backed operational doorbell draw at zero height, and /calm restores and re-hides them while persisting the shared preference"

# --- 3. Resume: the restored transcript keeps the hidden rows hidden ---------------
DEBUG_LOG_RESUME="$LAB/debug-resume.log"
launch "$DEBUG_LOG_RESUME" '' --continue
wait_screen 'gamma' 'the resumed transcript' 400
sleep 1
resumed=$(screen)
case "$resumed" in
  *'shell command'*|*"$NARRATION"*|*"$DOORBELL_TEXT"*)
    printf '%s\n' "$resumed" >&2
    fail "the resumed transcript drew a row Calm hides"
    ;;
esac
[ "$(cat "$FM_HOME_DIR/config/calm")" = on ] || fail "resume changed the persisted choice"
quit_session
pass "Claude Code $CLAUDE_VERSION resumes the transcript with Calm's hidden rows still hidden and the preference intact"

# --- 4. Supervision notes: shown with Calm off, from the store the host writes ----
STATE_DIR="$FM_HOME_DIR/state"
DEBUG_LOG_NOTES="$LAB/debug-notes.log"
mkdir -p "$STATE_DIR"
outcome() {
  FM_HOME="$FM_HOME_DIR" bash "$ROOT/bin/fm-branch-outcome.sh" "$@" >/dev/null \
    || fail "bin/fm-branch-outcome.sh $1 failed in the lab home"
}
outcome append --task fm-live-a --verdict captain --summary 'LIVE_PROCESSED_CAPTAIN acknowledged earlier'
outcome append --task fm-live-b --verdict captain --summary 'LIVE_REPLAY_CAPTAIN still open'
outcome mark-read --through 2
outcome mark-processed --through 1
printf 'key=live-key\nerrors=0\ncooldown=0\nretry_after=0\n' >"$STATE_DIR/.supervision-host-health"
printf 'off\n' >"$FM_HOME_DIR/config/calm"
launch "$DEBUG_LOG_NOTES" ''
wait_idle
wait_screen 'fm: ⚓ [seq 2] fm-live-b: LIVE_REPLAY_CAPTAIN still open' 'the session-start replay of an unprocessed captain outcome' 200
outcome append --task fm-live-c --verdict routine --summary 'LIVE_ROUTINE_NOTE worker healthy'
outcome append --task fm-live-d --verdict routine --summary 'LIVE_SILENT_NOTE no change' --silent true
outcome append --task fm-live-e --verdict captain --summary 'LIVE_NEW_CAPTAIN PR ready for review'
wait_screen 'fm: ⛵ fm-live-c: LIVE_ROUTINE_NOTE worker healthy' 'the routine sailboat note' 200
wait_screen 'fm: ⚓ [seq 5] fm-live-e: LIVE_NEW_CAPTAIN PR ready for review' 'the new captain anchor line' 200
printf 'key=live-key\nerrors=2\ncooldown=300\nretry_after=0\n' >"$STATE_DIR/.supervision-host-health"
wait_screen 'fm: ⛵ Supervision session paused after repeated engine errors' 'the latch-trip note' 200
notes_screen=$(screen)
case "$notes_screen" in
  *'LIVE_PROCESSED_CAPTAIN'*|*'LIVE_SILENT_NOTE'*)
    printf '%s\n' "$notes_screen" >&2
    fail "a processed captain outcome or a silent routine outcome drew a supervision note"
    ;;
  *'firstmate-calm:'*)
    printf '%s\n' "$notes_screen" >&2
    fail "a supervision note drew behind the old firstmate-calm label"
    ;;
esac
[ "$(cat "$STATE_DIR/.branch-outcomes-cursor")" = 2 ] || fail "the supervision notes moved the store's read cursor"
[ "$(cat "$STATE_DIR/.branch-outcomes-processed")" = 1 ] || fail "the supervision notes moved the processed marker"
[ "$(cat "$FM_HOME_DIR/config/calm")" = off ] || fail "the supervision notes changed the Calm preference"
# The notes never reach the model: a real turn taken while they are on screen sends
# requests, and none of them, nor any earlier one, carries a note.
requests_before=$(($(wc -l <"$REQUESTS")))
send "$PROMPT"
enter
wait_settled 'the turn taken while supervision notes are on screen'
[ "$(($(wc -l <"$REQUESTS")))" -gt "$requests_before" ] || fail "the turn taken beside the supervision notes sent no model request, so their absence proves nothing"
if grep -q 'LIVE_' "$REQUESTS"; then
  fail "a model request carried a supervision note, so the notes reached the model: $REQUESTS"
fi
quit_session
# Claude Code keeps each note in the session as a display-only entry and restores it on
# resume, so the resumed session replays only what it has not shown.
outcome append --task fm-live-f --verdict captain --summary 'LIVE_WHILE_CLOSED captain outcome'
launch "$DEBUG_LOG_NOTES" '' --continue
wait_screen 'fm: ⚓ [seq 6] fm-live-f: LIVE_WHILE_CLOSED captain outcome' 'the replay of an outcome recorded while the session was closed' 400
sleep 4
resumed_notes=$(screen)
[ "$(printf '%s\n' "$resumed_notes" | grep -c 'LIVE_REPLAY_CAPTAIN')" = 1 ] || {
  printf '%s\n' "$resumed_notes" >&2
  fail "the resumed session did not show the earlier anchor exactly once"
}
quit_session
pass "Claude Code $CLAUDE_VERSION with Calm off shows the supervision notes: the session-start anchor for an unprocessed captain outcome, a sailboat for a new routine outcome, an anchor for a new captain outcome, and the latch-trip note, each behind the fm: label, skipping processed and silent outcomes, moving no store marker, reaching no model request, and on resume showing each anchor once"
