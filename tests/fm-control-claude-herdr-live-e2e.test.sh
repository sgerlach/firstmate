#!/usr/bin/env bash
# Live Claude-on-Herdr lifecycle control guard (live-harness-optin family).
#
# bin/fm-control.sh exit and relaunch stop a Claude worker by typing /exit
# through the Herdr submit core, whose pre-Enter payload proof must read the
# composer while Claude Code renders its slash-command popup below it. A stub
# can only restate that layout, so this guard drives the real control plane,
# and through it the real bin/fm-spawn.sh relaunch path, against real Claude
# Code in an isolated Herdr lab:
#   - relaunch launches a worker into an agent-free pane,
#   - relaunch --model stops that live idle worker and brings it back on the
#     requested model, proven from the process argv,
#   - exit stops the replacement and keeps the endpoint.
# It fails naming the harness and version rather than degrading quietly.
#
# Run explicitly with FM_CONTROL_CLAUDE_HERDR_LIVE=1 after a Herdr or Claude
# upgrade, and before trusting a refreshed docs/verification/runtime-backends.md
# "Claude lifecycle control" entry. Each relaunch submits a one-line brief;
# FM_CONTROL_CLAUDE_HERDR_MODEL picks the switched-to model (default sonnet).
# The relaunch registers the lab worktree's workspace trust in the operator's
# own Claude store, exactly as every real spawn does, because the real Claude
# needs the operator's own login.
# Every Herdr call, including adapter and spawn calls, is routed through
# bin/fm-herdr-lab.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
MODEL=${FM_CONTROL_CLAUDE_HERDR_MODEL:-sonnet}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

fm_live_gate opt-in FM_CONTROL_CLAUDE_HERDR_LIVE herdr jq claude git

[ -x "$LAB_HELPER" ] || fail "FM_CONTROL_CLAUDE_HERDR_LIVE=1 but the Herdr lab helper is not executable at $LAB_HELPER"

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

ORIGINAL_PATH=$PATH
SESSION=$("$LAB_HELPER" name claude-control-live)
ID="clctl$$x$RANDOM"
TMP_ROOT=$(fm_test_tmproot fm-control-claude-herdr-live) || fail "could not create a temp root"
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
CHECKED=0

cleanup() {
  local rc=$? d
  trap - EXIT
  if ! PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION"; then
    rc=1
  fi
  # The relaunch stages its launch file and task temp root outside TMP_ROOT,
  # keyed by this run's unique task id.
  for d in "/tmp/fm-$ID" "/tmp/fm-$ID+"*; do
    [ ! -e "$d" ] || rm -rf "$d"
  done
  fm_test_remove_tree "$TMP_ROOT"
  fm_test_cleanup
  exit "$rc"
}
trap cleanup EXIT

# Every adapter call carries a trailing --session; the wrapper strips it and
# re-enters through the lab helper, refusing any other session. The adapter's
# client version check is the one call without a session, and the helper
# scopes that read-only status to the lab too.
cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -u
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "$SESSION" ] || { echo "wrapper refused foreign session" >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
elif [ "\${1:-}" != status ]; then
  echo "wrapper requires trailing --session $SESSION" >&2
  exit 98
fi
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"

"$LAB_HELPER" provision "$SESSION" || fail "could not provision the isolated Herdr lab"
export PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_SESSION="$SESSION"

lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }
VERSION=$(PATH="$ORIGINAL_PATH" claude --version 2>/dev/null | head -1 || printf 'version-unknown')
HERDR_VER=$(PATH="$ORIGINAL_PATH" herdr --version 2>/dev/null | head -1 || printf 'herdr-unknown')
WHO="Claude Code ($VERSION) on $HERDR_VER"

H="$TMP_ROOT/home"
PROJ="$TMP_ROOT/proj"
WT="$TMP_ROOT/wt"
HEAD1="FMCTLLAUNCH$$"
TAIL1="R$RANDOM"
HEAD2="FMCTLSWITCH$$"
TAIL2="R$RANDOM"
mkdir -p "$H/state" "$H/data/$ID" "$H/config" "$H/projects" "$PROJ"
touch "$H/state/.last-watcher-beat"
cat > "$H/data/$ID/brief.md" <<EOF
# Task
## Captain's intent
Runtime verification only: reply with one word made of $HEAD1 immediately followed by $TAIL1, with no space and nothing else, then stop. Run no other tools and write no files.

## Firstmate spec
Do nothing else.
EOF
git -C "$PROJ" init -q
printf '# lab\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name='Firstmate Live Guard' -c user.email='live-guard@example.invalid' commit -qm initial
git -C "$PROJ" worktree add --quiet -b "$ID" "$WT"
PROJ=$(cd "$PROJ" && pwd -P)
WT=$(cd "$WT" && pwd -P)
export FM_HOME="$H"

# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "could not load the Herdr adapter"
CONTAINER_RAW=$(fm_backend_herdr_container_ensure "$WT") || fail "could not create the lab workspace"
CONTAINER=${CONTAINER_RAW%%$'\t'*}
TASK_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "fm-$ID" "$WT" "${CONTAINER_RAW#*$'\t'}") \
  || fail "could not create the lab task pane"
read -r TAB_ID PANE_ID <<<"$TASK_IDS"
[ -n "$TAB_ID" ] && [ -n "$PANE_ID" ] || fail "the lab task pane has no tab or pane id"
TARGET="$SESSION:$PANE_ID"
{
  echo "window=$TARGET"
  echo "endpoint_task_id=$ID"
  echo "worktree=$WT"
  echo "project=$PROJ"
  echo "harness=claude"
  echo "kind=scout"
  echo "model=default"
  echo "effort=default"
  echo "backend=herdr"
  echo "herdr_session=$SESSION"
  echo "herdr_workspace_id=${CONTAINER#*:}"
  echo "herdr_tab_id=$TAB_ID"
  echo "herdr_pane_id=$PANE_ID"
} > "$H/state/$ID.meta"

control() {  # <args...>
  env FM_HOME="$H" FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-control.sh" "$ID" "$@" 2>&1
}

claude_argv() {  # the pane's foreground Claude command line, or empty
  lab pane process-info --pane "$PANE_ID" 2>/dev/null | jq -r '
    [.result.process_info.foreground_processes[]? | select((.argv // [])[0] == "claude")
      | (.argv | join(" "))] | first // empty' 2>/dev/null
}

# wait_reply <head> <tail>: the worker's reply joins two halves its
# instructions name apart, so a launch that renders those instructions cannot
# satisfy the wait. The turn must then be over on both independent signals -
# Herdr's native agent state and the rendered busy footer - for two samples in
# a row, so a lifecycle verb always meets an idle worker. A folder-trust,
# external-imports, or bypass-permissions dialog is never answered here.
wait_reply() {  # <head> <tail>
  local token="$1$2" i=0 screen quiet=0 status
  while [ "$i" -lt 240 ]; do
    screen=$(lab pane read "$PANE_ID" --source recent --lines 400 2>/dev/null || true)
    case "$screen" in
      *'trust this folder'*|*'external CLAUDE.md'*|*'Bypass Permissions mode'*)
        fail "$WHO: the lab worker is parked on a Claude dialog that must not be answered: $(printf '%s\n' "$screen" | tail -12)" ;;
    esac
    quiet=$((quiet + 1))
    if ! printf '%s\n' "$screen" | grep -F -q "$token"; then
      quiet=0
    else
      status=$(lab agent get "$PANE_ID" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
      case "$status" in idle|done) ;; *) quiet=0 ;; esac
      [ "$(fm_backend_herdr_rendered_busy_state "$TARGET")" = idle ] || quiet=0
    fi
    [ "$quiet" -lt 2 ] || return 0
    i=$((i + 1))
    sleep 1
  done
  fail "$WHO: the lab worker never finished replying $token: $(printf '%s\n' "$screen" | tail -12)"
}

# 1. A relaunch into the agent-free pane launches the worker on its recorded profile.
out=$(control relaunch --note "Runtime verification relaunch; follow the brief.") \
  || fail "$WHO: relaunch into an agent-free pane failed: $out"
case "$out" in
  "relaunched $ID harness=claude from=claude model=default "*) ;;
  *) fail "$WHO: relaunch into an agent-free pane reported: $out" ;;
esac
wait_reply "$HEAD1" "$TAIL1"
argv=$(claude_argv)
[ -n "$argv" ] || fail "$WHO: no Claude process runs in the pane after the relaunch"
case " $argv " in
  *' --model '*) fail "$WHO: a relaunch on the default profile passed a model: $argv" ;;
esac
CHECKED=1
pass "live control: $WHO relaunches a worker into an agent-free pane"

# 2. Relaunch --model must stop the live idle worker (its /exit behind the
# command popup) and bring it back on the requested model.
out=$(control relaunch --model "$MODEL" --note "Runtime verification model switch: reply with one word made of $HEAD2 immediately followed by $TAIL2, with no space and nothing else, then stop.") \
  || fail "$WHO: relaunch --model $MODEL could not replace a live idle worker: $out"
case "$out" in
  "relaunched $ID harness=claude from=claude model=$MODEL "*) ;;
  *) fail "$WHO: relaunch --model $MODEL reported: $out" ;;
esac
[ "$(sed -n 's/^model=//p' "$H/state/$ID.meta")" = "$MODEL" ] \
  || fail "$WHO: the task record does not name model $MODEL after the relaunch"
wait_reply "$HEAD2" "$TAIL2"
argv=$(claude_argv)
case " $argv " in
  *" --model $MODEL "*) ;;
  *) fail "$WHO: the replacement Claude does not run with --model $MODEL: ${argv:-no Claude process}" ;;
esac
pass "live control: $WHO relaunch --model $MODEL stops the live idle worker and runs the replacement on that model"

# 3. Exit stops the replacement and keeps the endpoint and local copy.
out=$(control exit) || fail "$WHO: exit of a live idle worker failed: $out"
case "$out" in
  "stopped $ID harness=claude backend=herdr endpoint=$TARGET "*) ;;
  *) fail "$WHO: exit of a live idle worker reported: $out" ;;
esac
! lab agent get "$PANE_ID" >/dev/null 2>&1 || fail "$WHO: exit reported stopped but Herdr still registers the agent"
[ -z "$(claude_argv)" ] || fail "$WHO: exit reported stopped but a Claude process still runs in the pane"
lab pane get "$PANE_ID" >/dev/null 2>&1 || fail "$WHO: exit removed the task's endpoint"
[ -d "$WT" ] || fail "$WHO: exit removed the task's local copy"
pass "live control: $WHO exit stops the worker and keeps its endpoint and local copy"

[ "$CHECKED" -gt 0 ] || fail "FM_CONTROL_CLAUDE_HERDR_LIVE=1 checked no harness"
