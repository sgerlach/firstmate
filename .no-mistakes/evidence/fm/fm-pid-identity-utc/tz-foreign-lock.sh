#!/usr/bin/env bash
# A dead daemon's lock whose pid now names a foreign live process must not be
# credited from any zone: fm-afk-start sees no live daemon, the turn-end check
# does not credit it, and the foreign process survives the return.
set -u; W=$1; cd "$W"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); bin/fm-lab-home.sh create "$LAB" >/dev/null
mkdir -p "$LAB/state"; date +%s > "$LAB/state/.afk"
bash -c 'exec -a "bash bin/fm-supervise-daemon.sh" sleep 300' & DEAD=$!; sleep 0.3
REC=$(TZ=America/Los_Angeles bash -c '. bin/fm-pid-identity-lib.sh; fm_pid_identity "$1"' _ "$DEAD")
kill $DEAD; wait $DEAD 2>/dev/null
sleep 300 & FOREIGN=$!; sleep 0.3
mkdir -p "$LAB/state/.supervise-daemon.lock"; echo "$FOREIGN" > "$LAB/state/.supervise-daemon.lock/pid"; printf '%s\n' "$REC" > "$LAB/state/.supervise-daemon.lock/pid-identity"
echo "recorded daemon identity (LA): $REC"
echo "lock pid now names foreign process: $(ps -p $FOREIGN -o pid=,command=)"
E=(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_STATE_OVERRIDE -u FM_ROOT_OVERRIDE TZ=Asia/Tokyo FM_HOME="$LAB")
"${E[@]}" bash -c '. bin/fm-afk-start.sh; set +e; daemon_lock_held_by_live_daemon && echo "daemon_lock_held_by_live_daemon (Tokyo)=yes" || echo "daemon_lock_held_by_live_daemon (Tokyo)=no"'
"${E[@]}" bash -c '. bin/fm-wake-lib.sh; fm_afk_daemon_owns_supervision "$1" && echo "fm_afk_daemon_owns_supervision (Tokyo)=yes" || echo "fm_afk_daemon_owns_supervision (Tokyo)=no"' _ "$LAB/state"
printf 'none\t-\tnative\n' > "$LAB/state/.afk-daemon-terminal"
"${E[@]}" bin/fm-afk-launch.sh stop 2>&1 | sed 's/^/stop: /'
sleep 1; echo "foreign process alive after return=$(kill -0 $FOREIGN 2>/dev/null && echo yes || echo no)"
kill $FOREIGN 2>/dev/null; wait $FOREIGN 2>/dev/null; rm -rf "$LAB"; echo "lab removed"
