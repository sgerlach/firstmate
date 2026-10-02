#!/usr/bin/env bash
# Adversarial checks of fm_pid_identity_matches on real macOS processes across
# real host zones, and parity of the Node mirror (bin/fm-pid-identity.mjs).
set -u
W=$1; cd "$W"
m() { local tz=$1; shift; TZ=$tz FM_HOME=/nonexistent bash -c '. bin/fm-pid-identity-lib.sh; fm_pid_identity_matches "$1" "$2"; echo $?' _ "$@"; }
legacy() { COLUMNS=10000 LC_ALL=C TZ="$2" ps -p "$1" -o lstart= -o command= | sed 's/^[[:space:]]*//'; }
utc() { COLUMNS=10000 LC_ALL=C TZ=UTC0 ps -p "$1" -o lstart= -o command= | sed 's/^[[:space:]]*//'; }
shift_rec() { local s; s=$(TZ=UTC0 LC_ALL=C date -j -f '%a %b %e %H:%M:%S %Y' "${1:0:24}" +%s); TZ=UTC0 LC_ALL=C date -r $((s+$2)) "+%a %b %e %H:%M:%S %Y${1:24}"; }
node_says() { node --input-type=module -e 'import {legacyIdentityMatches} from "./bin/fm-pid-identity.mjs"; console.log(legacyIdentityMatches(process.argv[1], process.argv[2]) ? 0 : 1)' "$1" "$2"; }
sleep 400 & A=$!; sleep 0.3; sleep 401 & B=$!; sleep 0.3
keyed_A=$(TZ=America/Los_Angeles bash -c '. bin/fm-pid-identity-lib.sh; fm_pid_identity "$1"' _ "$A")
leg_A=$(legacy "$A" America/Los_Angeles)
echo "process A pid=$A  keyed(LA)=$keyed_A"
echo "process A legacy(LA)=$leg_A"
printf '%-72s %s\n' "CASE (expected status: 0 match, 1 mismatch, 2 unreadable)" "STATUS"
printf '%-72s %s\n' "keyed A recorded in LA, checked in Tokyo (expect 0)" "$(m Asia/Tokyo "$A" "$keyed_A")"
printf '%-72s %s\n' "keyed A checked in Kathmandu +05:45 (expect 0)" "$(m Asia/Kathmandu "$A" "$keyed_A")"
printf '%-72s %s\n' "legacy A recorded in LA, checked in Tokyo (expect 0)" "$(m Asia/Tokyo "$A" "$leg_A")"
printf '%-72s %s\n' "legacy A recorded in Chatham +13:45, checked in LA (expect 0)" "$(m America/Los_Angeles "$A" "$(legacy "$A" Pacific/Chatham)")"
printf '%-72s %s\n' "ADVERSARIAL: A's keyed record against live foreign pid B (expect 1)" "$(m Asia/Tokyo "$B" "$keyed_A")"
printf '%-72s %s\n' "ADVERSARIAL: A's legacy record against live foreign pid B (expect 1)" "$(m Asia/Tokyo "$B" "$leg_A")"
printf '%-72s %s\n' "ADVERSARIAL: legacy A shifted 37 min (not a zone offset) (expect 1)" "$(m Asia/Tokyo "$A" "$(shift_rec "$leg_A" 2220)")"
printf '%-72s %s\n' "ADVERSARIAL: legacy A shifted 22 h, UTC+15 (beyond any zone) (expect 1)" "$(m Asia/Tokyo "$A" "$(shift_rec "$leg_A" 79200)")"
printf '%-72s %s\n' "ADVERSARIAL: keyed A shifted 1 h (keyed must be exact) (expect 1)" "$(m Asia/Tokyo "$A" "lstart-utc=$(shift_rec "${keyed_A#lstart-utc=}" 3600)")"
printf '%-72s %s\n' "ADVERSARIAL: empty record against live A (expect 1)" "$(m Asia/Tokyo "$A" "")"
echo "--- Node mirror parity on the same records (shell verdict vs node verdict)"
U=$(utc "$A")
for rec in "$leg_A" "$(legacy "$A" Pacific/Chatham)" "$(shift_rec "$leg_A" 2220)" "$(shift_rec "$leg_A" 79200)" "$(legacy "$B" America/Los_Angeles)"; do
  sh=$(bash -c '. bin/fm-pid-identity-lib.sh; fm_pid_identity_legacy_matches "$1" "$2"; echo $?' _ "$rec" "$U")
  printf '  shell=%s node=%s  record=%s\n' "$sh" "$(node_says "$rec" "$U")" "${rec:0:40}..."
done
kill "$A"; wait "$A" 2>/dev/null
printf '%-72s %s\n' "ADVERSARIAL: keyed A after A exited (dead pid) (expect 2)" "$(m Asia/Tokyo "$A" "$keyed_A")"
printf '%-72s %s\n' "ADVERSARIAL: legacy A after A exited (dead pid) (expect 2)" "$(m Asia/Tokyo "$A" "$leg_A")"
kill "$B"; wait "$B" 2>/dev/null
