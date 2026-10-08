#!/usr/bin/env bash
# Behavior tests for bin/fm-desktop-handoff.sh, the Claude Desktop hand-off.
#
# Every case runs the real command against a scratch home with its own
# markdown backlog, through the real bin/fm-tasks-axi.sh, check registration,
# and watcher. Claude Desktop is never opened: FM_DESKTOP_HANDOFF_UNAME selects
# the macOS path and fake `open` and `pbcopy` commands on PATH record what the
# command handed to them.
#
# Covered contracts:
#   * start writes the folder (PROMPT.md naming RESULT.md and its three
#     sections, files/ copies, an empty RESULT.md), arms a registered watcher
#     check, holds the backlog item as external, and opens the Cowork or Code
#     link with the prompt and the folder;
#   * a prompt over the link limit goes to the clipboard and the link carries a
#     pointer to PROMPT.md instead;
#   * start refuses work it must not take: a missing, In-flight, or otherwise
#     held item, a second active hand-off, a chat surface, and bad inputs;
#   * the check stays silent until RESULT.md is written and settled, reports
#     once, and reports again only when the result changes, and the real
#     watcher turns that line into a durable check wake naming the item;
#   * return refuses an empty result, clears only its own hold, disarms the
#     check, prints the result, and finishes cleanup without a record or item;
#   * a later start archives the returned hand-off.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CMD="$ROOT/bin/fm-desktop-handoff.sh"
WRAPPER="$ROOT/bin/fm-tasks-axi.sh"
WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-desktop-handoff)
FAKEBIN="$TMP_ROOT/fakebin"

unset FM_HOME FM_ROOT_OVERRIDE FM_DATA_OVERRIDE FM_STATE_OVERRIDE \
  FM_DESKTOP_HANDOFF_SETTLE_SECS FM_DESKTOP_HANDOFF_UNAME

mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/open" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$FM_TEST_DESKTOP_LOG/open.log"
SH
cat > "$FAKEBIN/pbcopy" <<'SH'
#!/usr/bin/env bash
cat > "$FM_TEST_DESKTOP_LOG/clipboard.txt"
SH
chmod +x "$FAKEBIN/open" "$FAKEBIN/pbcopy"

# make_home <name> <item-id>...: a scratch home whose backlog holds each id queued.
make_home() {
  local home="$TMP_ROOT/$1" id
  shift
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/log"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  for id in "$@"; do
    FM_HOME="$home" "$WRAPPER" add "$id" "title of $id" --kind ship --repo demo >/dev/null \
      || fail "could not add backlog item $id"
  done
  printf '%s\n' "$home"
}

# handoff <home> <args...>: run the command on the macOS path with fakes.
handoff() {
  local home=$1
  shift
  env FM_HOME="$home" FM_TEST_DESKTOP_LOG="$home/log" FM_DESKTOP_HANDOFF_UNAME=Darwin \
    PATH="$FAKEBIN:$PATH" "$CMD" "$@"
}

show_field() {  # <home> <id> <field>
  FM_HOME="$1" "$WRAPPER" show "$2" | sed -n "s/^  $3: *//p" | sed -n '1p'
}

age_result() {  # <home> <id>: make RESULT.md older than the settle window
  touch -t 202001010000 "$1/data/$2/desktop-handoff/RESULT.md"
}

test_help_and_usage() {
  local out rc=0
  out=$("$CMD" --help 2>&1) || rc=$?
  expect_code 0 "$rc" "--help"
  assert_contains "$out" "start <task-id>" "--help names start"
  assert_contains "$out" "return <task-id>" "--help names return"
  rc=0
  "$CMD" bogus >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "an unknown command is a usage error"
  pass "help prints the commands and an unknown command exits 2"
}

test_start_writes_folder_holds_and_opens() {
  local home folder out link
  home=$(make_home start item-a1)
  printf 'source body\n' > "$TMP_ROOT/notes.md"
  mkdir -p "$TMP_ROOT/assets" && printf 'x\n' > "$TMP_ROOT/assets/a.txt"
  out=$(handoff "$home" start item-a1 --prompt "Draft the copy." \
    --file "$TMP_ROOT/notes.md" --file "$TMP_ROOT/assets") || fail "start failed: $out"
  folder="$home/data/item-a1/desktop-handoff"
  assert_contains "$out" "opened Cowork with the full prompt" "start reports the full-prompt open"
  assert_present "$folder/files/notes.md" "start copies a source file"
  assert_present "$folder/files/assets/a.txt" "start copies a source directory"
  [ -f "$folder/RESULT.md" ] && [ ! -s "$folder/RESULT.md" ] || fail "start must leave an empty RESULT.md"
  assert_grep "Draft the copy." "$folder/PROMPT.md" "PROMPT.md keeps the given prompt"
  assert_grep "$folder/RESULT.md" "$folder/PROMPT.md" "PROMPT.md names where RESULT.md is"
  assert_grep "## Outcome" "$folder/PROMPT.md" "PROMPT.md asks for the outcome"
  assert_grep "## Files changed or produced" "$folder/PROMPT.md" "PROMPT.md asks for the files"
  assert_grep "## Open questions" "$folder/PROMPT.md" "PROMPT.md asks for open questions"
  assert_grep "- \`notes.md\`" "$folder/PROMPT.md" "PROMPT.md lists the source files"
  assert_equals yes "$(show_field "$home" item-a1 held)" "start holds the backlog item"
  assert_equals external "$(show_field "$home" item-a1 hold_kind)" "the hold is external"
  assert_contains "$(show_field "$home" item-a1 hold_reason)" "with Claude Desktop Cowork" "the hold reason names Desktop"
  out=$(handoff "$home" status item-a1)
  assert_contains "$out" "state=active surface=cowork" "status shows the active hand-off"
  assert_contains "$out" "result=waiting watch=armed" "status shows the armed watch"
  link=$(sed -n '1p' "$home/log/open.log")
  assert_contains "$link" "claude://cowork/new?q=Draft%20the%20copy." "the link carries the prompt"
  assert_contains "$link" "&folder=$(printf '%s' "$folder" | jq -sRr @uri)" "the link attaches the folder"
  pass "start writes the folder, arms the watch, holds the item, and opens Cowork"
}

test_code_surface_and_no_open() {
  local home out
  home=$(make_home code item-c1 item-c2)
  handoff "$home" start item-c1 --prompt "Fix it." --surface code >/dev/null || fail "code start failed"
  assert_contains "$(sed -n '1p' "$home/log/open.log")" "claude://code/new?q=Fix%20it." "the code surface opens a Code session"
  out=$(handoff "$home" start item-c2 --prompt "Later." --no-open) || fail "--no-open start failed"
  assert_contains "$out" "not opened (--no-open)" "--no-open says Desktop was not opened"
  assert_contains "$out" "claude://cowork/new?q=Later." "--no-open prints the link"
  assert_equals 1 "$(wc -l < "$home/log/open.log" | tr -d ' ')" "--no-open never calls open"
  out=$(env FM_HOME="$home" FM_TEST_DESKTOP_LOG="$home/log" FM_DESKTOP_HANDOFF_UNAME=Linux \
    PATH="$FAKEBIN:$PATH" "$CMD" open item-c2) || fail "open on a non-macOS host failed"
  assert_contains "$out" "this host is not macOS" "a non-macOS host prints the link instead"
  handoff "$home" open item-c2 >/dev/null || fail "open failed"
  assert_equals 2 "$(wc -l < "$home/log/open.log" | tr -d ' ')" "open re-delivers the link"
  pass "the code surface, --no-open, and open re-delivery behave as documented"
}

test_long_prompt_uses_clipboard_pointer() {
  local home out link body
  home=$(make_home long item-l1)
  body="$TMP_ROOT/long-prompt.md"
  : > "$body"
  while [ "$(wc -c < "$body")" -le 15000 ]; do
    printf 'filler line for the link limit test\n' >> "$body"
  done
  out=$(handoff "$home" start item-l1 --prompt-file "$body") || fail "long start failed: $out"
  assert_contains "$out" "copied the full prompt to the clipboard" "a long prompt goes to the clipboard"
  cmp -s "$home/log/clipboard.txt" "$home/data/item-l1/desktop-handoff/PROMPT.md" \
    || fail "the clipboard must hold the full PROMPT.md"
  link=$(sed -n '1p' "$home/log/open.log")
  assert_contains "$link" "PROMPT.md" "the pointer link names PROMPT.md"
  assert_not_contains "$link" "filler%20line" "the pointer link leaves the long prompt out"
  pass "a prompt over the link limit is copied to the clipboard with a pointer link"
}

test_start_refusals() {
  local home rc out
  home=$(make_home refuse item-r1 item-r2 item-r3)
  printf 'a\n' > "$TMP_ROOT/dup-a.md"
  mkdir -p "$TMP_ROOT/dup" && printf 'b\n' > "$TMP_ROOT/dup/dup-a.md"
  for args in "missing-item --prompt x" "item-r1" "item-r1 --prompt x --surface chat" \
    "item-r1 --prompt x --file $TMP_ROOT/nope.md" \
    "item-r1 --prompt x --file $TMP_ROOT/dup-a.md --file $TMP_ROOT/dup/dup-a.md" \
    "item-r1 --prompt  "; do
    rc=0
    # shellcheck disable=SC2086 # Each case is a word list on purpose.
    handoff "$home" start $args >/dev/null 2>&1 || rc=$?
    [ "$rc" -ne 0 ] || fail "start must refuse: $args"
  done
  rc=0
  handoff "$home" start item-r1 --prompt "   " >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "an empty prompt is refused"
  FM_HOME="$home" "$WRAPPER" start item-r2 >/dev/null || fail "could not start item-r2"
  out=$(handoff "$home" start item-r2 --prompt x 2>&1) && fail "an In-flight item must be refused"
  assert_contains "$out" "In flight" "the refusal names the In-flight state"
  FM_HOME="$home" "$WRAPPER" hold item-r3 --reason "captain decision pending" --kind captain >/dev/null \
    || fail "could not hold item-r3"
  out=$(handoff "$home" start item-r3 --prompt x 2>&1) && fail "a held item must be refused"
  assert_contains "$out" "captain" "the refusal names the existing hold"
  handoff "$home" start item-r1 --prompt x --no-open >/dev/null || fail "a valid start failed"
  out=$(handoff "$home" start item-r1 --prompt x 2>&1) && fail "a second active hand-off must be refused"
  assert_contains "$out" "already with Claude Desktop" "the refusal names the active hand-off"
  [ ! -e "$home/data/missing-item" ] || fail "a refused start must leave no folder"
  [ ! -e "$home/state/desktop-handoff-item-r2.check.sh" ] || fail "a refused start must arm no check"
  pass "start refuses missing, In-flight, held, and already handed-off items and bad inputs"
}

test_check_reports_once_and_watcher_wakes() {
  local home shim out result
  home=$(make_home check item-k1)
  handoff "$home" start item-k1 --prompt x --no-open >/dev/null || fail "start failed"
  shim="$home/state/desktop-handoff-item-k1.check.sh"
  result="$home/data/item-k1/desktop-handoff/RESULT.md"
  out=$(bash "$shim")
  assert_equals "" "$out" "an empty RESULT.md is silent"
  printf '## Outcome\n\nDone.\n' > "$result"
  out=$(bash "$shim")
  assert_equals "" "$out" "a RESULT.md inside the settle window is silent"
  age_result "$home" item-k1
  fm_test_track_watcher_state "$home/state"
  perl -e 'alarm 60; exec @ARGV' env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_CHECK_INTERVAL=0 \
    FM_POLL=0.02 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 PATH="$PATH" "$WATCH" > "$home/watch.out" 2> "$home/watch.err" \
    || fail "the watcher did not finish its cycle: $(cat "$home/watch.err")"
  assert_grep "check: $shim: desktop hand-off item-k1: Claude Desktop wrote $result" "$home/watch.out" \
    "the watcher wakes with the item and the result path"
  assert_grep "bin/fm-desktop-handoff.sh return item-k1" "$home/watch.out" "the wake names the return command"
  assert_grep "$shim" "$home/state/.wake-queue" "the wake is queued durably under the check"
  out=$(bash "$shim")
  assert_equals "" "$out" "an unchanged result is reported once"
  printf '## Outcome\n\nDone twice.\n' > "$result"
  age_result "$home" item-k1
  out=$(bash "$shim")
  assert_contains "$out" "changed $result again" "a changed result is reported again"
  pass "the check reports a settled result once, again on change, and the watcher queues the wake"
}

test_return_contract() {
  local home out rc=0
  local -a archived
  home=$(make_home return item-t1 item-t2)
  handoff "$home" start item-t1 --prompt x --no-open >/dev/null || fail "start failed"
  out=$(handoff "$home" return item-t1 2>&1) || rc=$?
  expect_code 1 "$rc" "return refuses an empty RESULT.md"
  assert_contains "$out" "--without-result" "the refusal names --without-result"
  printf '## Outcome\n\nShipped.\n' > "$home/data/item-t1/desktop-handoff/RESULT.md"
  printf 'deck\n' > "$home/data/item-t1/desktop-handoff/deck.md"
  out=$(handoff "$home" return item-t1) || fail "return failed: $out"
  assert_contains "$out" "hold cleared" "return clears its own hold"
  assert_contains "$out" "Shipped." "return prints RESULT.md"
  assert_contains "$out" "  deck.md" "return lists the files the session made"
  assert_equals no "$(show_field "$home" item-t1 held)" "the item is no longer held"
  assert_equals queued "$(show_field "$home" item-t1 state)" "return never closes the item"
  assert_absent "$home/state/desktop-handoff-item-t1.check.sh" "return removes the check"
  assert_absent "$home/state/desktop-handoff-item-t1.check-trust" "return removes the trust binding"
  assert_contains "$(handoff "$home" status)" "no active Claude Desktop hand-offs" "status lists nothing active"
  out=$(handoff "$home" start item-t1 --prompt again --no-open) || fail "a second start failed: $out"
  archived=("$home/data/item-t1"/desktop-handoff.returned-*/)
  [ -d "${archived[0]}" ] || fail "a second start must archive the returned folder"
  assert_present "${archived[0]}RESULT.md" "the archive keeps the returned RESULT.md"
  FM_HOME="$home" "$WRAPPER" hold item-t1 --reason "parked by hand" --kind parked >/dev/null \
    || fail "could not replace the hold"
  out=$(handoff "$home" return item-t1 --without-result) || fail "return --without-result failed: $out"
  assert_contains "$out" "held for something else" "return leaves a foreign hold alone"
  assert_equals parked "$(show_field "$home" item-t1 hold_kind)" "the foreign hold stays"
  handoff "$home" start item-t2 --prompt x --no-open >/dev/null || fail "start item-t2 failed"
  FM_HOME="$home" "$WRAPPER" rm item-t2 >/dev/null 2>&1 || fail "could not remove item-t2"
  rm -f "$home/data/item-t2/desktop-handoff.record"
  out=$(bash "$home/state/desktop-handoff-item-t2.check.sh")
  assert_contains "$out" "desktop-handoff.record is missing" "the check reports a missing record"
  out=$(handoff "$home" return item-t2) || fail "cleanup return failed: $out"
  assert_contains "$out" "cleanup only" "return finishes cleanup without a record or item"
  assert_absent "$home/state/desktop-handoff-item-t2.check.sh" "cleanup return removes the check"
  pass "return refuses an empty result, clears only its own hold, and cleans up"
}

if ! command -v tasks-axi >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  echo "skip: tasks-axi or jq not found; desktop hand-off cases not run"
  exit 0
fi

test_help_and_usage
test_start_writes_folder_holds_and_opens
test_code_surface_and_no_open
test_long_prompt_uses_clipboard_pointer
test_start_refusals
test_check_reports_once_and_watcher_wakes
test_return_contract
