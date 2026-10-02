#!/usr/bin/env bash
# Live proof: a real supervise daemon started under one host zone must stay
# recognized (lock kept, no second daemon) when away-mode is re-entered from
# another zone, and the return from that zone must stop it.
# Usage: tz-daemon-lab.sh <code-root> <label> [<code-root-after-upgrade>]
set -u
CODE=$1 LABEL=$2 CODE2=${3:-$1}
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
/Users/scottgerlach/.no-mistakes/worktrees/bb13fd9166b2/01M3YY6GC6546F3EQ8WESW66D2/bin/fm-lab-home.sh create "$LAB" >/dev/null
mkdir -p "$LAB/tmux"
t() { TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab "$@"; }
clean_env=(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u FM_PROC_ROOT_OVERRIDE)
echo "=== [$LABEL] daemon code=$CODE, later code=$CODE2 lab=$LAB"
t new-session -d -s captain -c "$CODE" bash
t new-session -d -s daemon -c "$CODE" "${clean_env[*]} TZ=America/Los_Angeles FM_HOME=$LAB FM_SUPERVISOR_TARGET=captain:0.0 FM_SUPERVISOR_BACKEND=tmux bin/fm-afk-start.sh > $LAB/daemon1.log 2>&1; echo exit=\$? >> $LAB/daemon1.log; sleep 600"
for _ in $(seq 1 50); do [ -s "$LAB/state/.supervise-daemon.lock/pid-identity" ] && break; sleep 0.2; done
echo "--- step 1: daemon started with host TZ=America/Los_Angeles"
sed 's/^/  daemon1.log: /' "$LAB/daemon1.log"
D1=$(cat "$LAB/state/.supervise-daemon.lock/pid" 2>/dev/null)
echo "  lock pid=$D1"
echo "  lock pid-identity=$(cat "$LAB/state/.supervise-daemon.lock/pid-identity" 2>/dev/null)"
echo "  daemon process: $(ps -p "$D1" -o pid=,command= 2>/dev/null)"
echo "--- step 2: laptop travels; re-enter away mode with host TZ=Asia/Tokyo"
( cd "$CODE2" && "${clean_env[@]}" TZ=Asia/Tokyo FM_HOME="$LAB" FM_SUPERVISOR_TARGET=captain:0.0 FM_SUPERVISOR_BACKEND=tmux perl -e 'alarm shift; exec @ARGV' 8 bin/fm-afk-start.sh ) > "$LAB/entry2.log" 2>&1; echo "exit=$?" >> "$LAB/entry2.log"
sed 's/^/  entry2.log: /' "$LAB/entry2.log" | head -8
echo "  lock pid after re-entry=$(cat "$LAB/state/.supervise-daemon.lock/pid" 2>/dev/null || echo '<lock gone>')"
echo "  first daemon $D1 alive=$(kill -0 "$D1" 2>/dev/null && echo yes || echo no)"
echo "  supervise daemons running in this lab: $(pgrep -f "fm-supervise-daemon.sh" | while read -r p; do ps -E -p "$p" -o command= 2>/dev/null | grep -q "FM_HOME=$LAB" && echo "$p"; done | tr '\n' ' ')"
echo "--- step 3: fm_afk_daemon_owns_supervision from host TZ=Pacific/Auckland"
( cd "$CODE2" && "${clean_env[@]}" TZ=Pacific/Auckland FM_HOME="$LAB" bash -c '. bin/fm-wake-lib.sh; fm_afk_daemon_owns_supervision "$1" && echo "  owns_supervision=yes" || echo "  owns_supervision=no"' _ "$LAB/state" )
echo "--- step 4: captain returns; fm-afk-launch.sh stop with host TZ=Europe/London"
printf 'none\t-\tnative\n' > "$LAB/state/.afk-daemon-terminal"
( cd "$CODE2" && "${clean_env[@]}" TZ=Europe/London FM_HOME="$LAB" bin/fm-afk-launch.sh stop ) > "$LAB/stop.log" 2>&1; echo "exit=$?" >> "$LAB/stop.log"
sed 's/^/  stop.log: /' "$LAB/stop.log" | head -8
for _ in $(seq 1 30); do kill -0 "$D1" 2>/dev/null || break; sleep 0.2; done
echo "  first daemon $D1 alive after return=$(kill -0 "$D1" 2>/dev/null && echo yes || echo no)"
echo "  state/.afk present after return=$([ -e "$LAB/state/.afk" ] && echo yes || echo no)"
t kill-server 2>/dev/null
pkill -f "FM_HOME=$LAB" 2>/dev/null
for p in $(pgrep -f fm-supervise-daemon.sh); do ps -E -p "$p" -o command= 2>/dev/null | grep -q "FM_HOME=$LAB" && kill "$p"; done
rm -rf "$LAB"
echo "=== [$LABEL] lab removed"
