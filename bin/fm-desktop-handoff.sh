#!/usr/bin/env bash
# fm-desktop-handoff.sh - hand one backlog item to Claude Desktop and take it back.
#
# Usage:
#   fm-desktop-handoff.sh start <task-id> (--prompt-file <path|-> | --prompt <text>)
#                         [--file <path>]... [--surface cowork|code] [--no-open]
#   fm-desktop-handoff.sh open <task-id>
#   fm-desktop-handoff.sh status [<task-id>]
#   fm-desktop-handoff.sh return <task-id> [--without-result]
#   fm-desktop-handoff.sh check <task-id>
#   fm-desktop-handoff.sh --help
#
# `start` refuses unless <task-id> is an open backlog item that is not In
# flight and not held, then, in this order, rolling back on any failure:
#   1. writes the hand-off folder data/<task-id>/desktop-handoff/ holding
#      PROMPT.md (the given prompt plus a hand-off section that names the folder
#      and tells the Desktop session to write RESULT.md with an Outcome, Files
#      changed or produced, and Open questions section), files/ (a copy of each
#      --file, directories included), and an empty RESULT.md;
#   2. arms the watcher check state/desktop-handoff-<task-id>.check.sh and binds
#      it with fm-check-register.sh;
#   3. holds the backlog item through fm-tasks-axi.sh with --kind external and a
#      reason starting "with Claude Desktop", so the session-start digest and
#      Bearings show where the work is and fm-spawn.sh refuses to dispatch it;
#   4. writes the private record data/<task-id>/desktop-handoff.record, kept
#      outside the folder Desktop is given;
#   5. opens Claude Desktop through a claude:// link, unless --no-open.
# A returned hand-off folder for the same item is first moved aside to
# data/<task-id>/desktop-handoff.returned-<epoch>/ with its record.
#
# Link forms (verified against Claude Desktop 2.26454.2;
# docs/verification/claude-desktop-links.md owns the evidence):
#   cowork (default)  claude://cowork/new?q=<prompt>&folder=<hand-off folder>
#   code              claude://code/new?q=<prompt>&folder=<hand-off folder>
# Desktop prefills the prompt in a draft without sending it, and Cowork asks
# once to trust a folder it has not seen. A new chat (claude://claude.ai/new)
# is not offered because a chat cannot write RESULT.md. Desktop silently cuts
# the prompt to 14336 UTF-16 code units, so a PROMPT.md longer than 14336 bytes
# is not put in the link: the full prompt goes to the clipboard (pbcopy) and
# the link carries a short prompt that points at PROMPT.md in the folder.
# Opening needs macOS `open`; on any other platform, and with --no-open, the
# command prints the link instead. `open` re-delivers an active hand-off the
# same way, for example after --no-open or a closed draft.
#
# `check` is what the armed watcher check runs on the FM_CHECK_INTERVAL
# cadence (default 300 seconds), so the notification arrives within one cadence
# after RESULT.md is written. It prints one line, which the watcher turns into
# an ordinary `check:` wake naming the item and the next command, when
# RESULT.md is non-empty, unchanged for FM_DESKTOP_HANDOFF_SETTLE_SECS (default
# 30) so a half-written file stays silent, and different from what it last
# reported (state/.desktop-handoff-<task-id>.reported). A RESULT.md that is not
# a regular file, a missing record, or a returned record is reported once.
# Everything else prints nothing. RESULT.md is untrusted input written by the
# Desktop session; nothing here executes or interprets it.
#
# `return` takes the work back: it refuses an empty RESULT.md unless
# --without-result, clears the backlog hold only when it is still this
# command's external hold, disarms the check through fm-check-unregister.sh,
# marks the record returned, and prints RESULT.md and the folder's other files
# so firstmate can decide the item's next step. It never closes the item.
# Run against a returned or missing record, it only finishes that cleanup.
#
# `status` lists active hand-offs, or prints one item's record, result, and
# watch state.
#
# Exit status: 0 success, 1 refusal or failure (message on stderr), 2 usage.
# Paths follow FM_HOME, FM_DATA_OVERRIDE, and FM_STATE_OVERRIDE like every
# other home-scoped script. FM_DESKTOP_HANDOFF_UNAME replaces `uname -s` when
# deciding whether this host can open Desktop (a test seam).
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
TASKS_AXI="$SCRIPT_DIR/fm-tasks-axi.sh"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
UNREGISTER_BIN="$SCRIPT_DIR/fm-check-unregister.sh"
RECORD_SCHEMA=fm-desktop-handoff-v1
LINK_PROMPT_MAX=14336
HOLD_PREFIX="with Claude Desktop"
MAX_LINE=400

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-desktop-handoff.sh start <task-id> (--prompt-file <path|-> | --prompt <text>)
                        [--file <path>]... [--surface cowork|code] [--no-open]
  fm-desktop-handoff.sh open <task-id>        re-open Claude Desktop for an active hand-off
  fm-desktop-handoff.sh status [<task-id>]    list active hand-offs, or show one
  fm-desktop-handoff.sh return <task-id> [--without-result]
  fm-desktop-handoff.sh check <task-id>       the armed watcher check (prints one line when RESULT.md is written)
  fm-desktop-handoff.sh --help

start writes data/<task-id>/desktop-handoff/ (PROMPT.md, files/, empty RESULT.md),
arms state/desktop-handoff-<task-id>.check.sh, holds the backlog item
(--kind external), and opens Claude Desktop (Cowork by default) with the prompt.
A notification arrives within one watcher cycle after RESULT.md is written.
return clears the hold and the watch and prints RESULT.md; it never closes the item.
See docs/configuration.md "Claude Desktop hand-off".
EOF
}

die() {
  printf 'fm-desktop-handoff: %s\n' "$1" >&2
  exit 1
}

die_usage() {
  printf 'fm-desktop-handoff: %s\n' "$1" >&2
  usage >&2
  exit 2
}

file_mtime() {
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

iso_from_epoch() {
  date -u -r "$1" +%Y-%m-%dT%H:%MZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%MZ 2>/dev/null || printf '%s\n' "$1"
}

set_task() {
  ID=$1
  fm_pr_task_id_valid "$ID" || die_usage "invalid task id: $ID"
  CHECK_ID="desktop-handoff-$ID"
  TASK_DIR="$DATA/$ID"
  FOLDER="$TASK_DIR/desktop-handoff"
  RECORD="$TASK_DIR/desktop-handoff.record"
  RESULT="$FOLDER/RESULT.md"
  REPORTED="$STATE/.desktop-handoff-$ID.reported"
  CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
}

surface_label() {
  case "$1" in
    code) printf 'Claude Code' ;;
    *) printf 'Cowork' ;;
  esac
}

# --- backlog ------------------------------------------------------------------

# backlog_read <id> [--missing-ok]: fill B_STATE, B_HELD, B_HOLD_KIND,
# B_HOLD_REASON, and B_TITLE. With --missing-ok an absent item returns 3 with
# B_STATE empty instead of refusing.
backlog_read() {
  local out rc=0
  B_STATE='' B_HELD='' B_HOLD_KIND='' B_HOLD_REASON='' B_TITLE=''
  out=$(FM_HOME="$FM_HOME" "$TASKS_AXI" show "$1" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    if printf '%s\n' "$out" | grep -q '^code: NOT_FOUND$'; then
      [ "${2:-}" != --missing-ok ] || return 3
      die "no backlog item $1 in this home"
    fi
    die "cannot read backlog item $1: $(printf '%s\n' "$out" | sed -n '1p')"
  fi
  B_STATE=$(backlog_field "$out" state)
  B_HELD=$(backlog_field "$out" held)
  B_HOLD_KIND=$(backlog_field "$out" hold_kind)
  B_HOLD_REASON=$(backlog_field "$out" hold_reason)
  B_TITLE=$(backlog_field "$out" title)
  [ -n "$B_STATE" ] || die "backlog item $1 has no state"
}

backlog_field() {
  local value
  value=$(printf '%s\n' "$1" | sed -n "s/^  $2: *//p" | sed -n '1p')
  case "$value" in
    \"*\") value=${value#\"}; value=${value%\"} ;;
  esac
  [ "$value" = - ] && value=
  printf '%s\n' "$value"
}

hold_is_ours() {
  [ "$B_HELD" = yes ] && [ "$B_HOLD_KIND" = external ] \
    && case "$B_HOLD_REASON" in "$HOLD_PREFIX"*) true ;; *) false ;; esac
}

backlog_hold() {
  local reason out
  reason="$HOLD_PREFIX $(surface_label "$SURFACE") since $(iso_from_epoch "$STARTED"); result goes to data/$ID/desktop-handoff/RESULT.md; take it back with bin/fm-desktop-handoff.sh return $ID"
  out=$(FM_HOME="$FM_HOME" "$TASKS_AXI" hold "$ID" --reason "$reason" --kind external 2>&1) || {
    printf 'fm-desktop-handoff: could not hold backlog item %s: %s\n' "$ID" "$(printf '%s\n' "$out" | sed -n '1p')" >&2
    return 1
  }
}

backlog_unhold() {
  local out
  out=$(FM_HOME="$FM_HOME" "$TASKS_AXI" unhold "$ID" 2>&1) || {
    printf 'fm-desktop-handoff: could not clear the hold on %s: %s\n' "$ID" "$(printf '%s\n' "$out" | sed -n '1p')" >&2
    return 1
  }
}

# --- record -------------------------------------------------------------------

record_read() {
  local line first=1
  R_STATE='' R_SURFACE='' R_STARTED='' R_LINK='' R_OPENED='' R_RETURNED=''
  [ -f "$RECORD" ] && [ ! -L "$RECORD" ] || return 1
  while IFS= read -r line; do
    if [ "$first" = 1 ]; then
      first=0
      [ "$line" = "$RECORD_SCHEMA" ] || return 1
      continue
    fi
    case "$line" in
      state=*) R_STATE=${line#state=} ;;
      surface=*) R_SURFACE=${line#surface=} ;;
      started=*) R_STARTED=${line#started=} ;;
      link=*) R_LINK=${line#link=} ;;
      opened=*) R_OPENED=${line#opened=} ;;
      returned=*) R_RETURNED=${line#returned=} ;;
    esac
  done < "$RECORD"
  [ -n "$R_STATE" ]
}

record_write() {  # <state> <surface> <started> <link> <opened> <returned>
  local tmp
  tmp=$(umask 077; mktemp "$TASK_DIR/.desktop-handoff-record.XXXXXX") || return 1
  if ! printf '%s\n' "$RECORD_SCHEMA" "task=$ID" "state=$1" "surface=$2" \
      "started=$3" "link=$4" "opened=$5" "returned=$6" > "$tmp" \
    || ! mv -f -- "$tmp" "$RECORD"; then
    rm -f -- "$tmp"
    return 1
  fi
}

# --- watcher check ------------------------------------------------------------

# The home is embedded already resolved, because the watcher runs the shim from
# its own working directory.
shim_content() {
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-desktop-handoff.sh - Claude Desktop hand-off result watch.' \
    '# The watcher validates these bytes, then runs the trusted check.' \
    "export FM_HOME=$(printf '%q' "$HOME_ABS")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-desktop-handoff.sh") check $(printf '%q' "$ID")"
}

# Write the shim through a private temporary file and a rename, refusing a
# symlink or foreign-device file at the destination, then bind its bytes.
check_arm() {
  local device tmp
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || { printf 'fm-desktop-handoff: state directory is unavailable\n' >&2; return 1; }
  device=$(fm_pr_file_device "$STATE") || return 1
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" || {
    printf 'fm-desktop-handoff: refusing to write %s\n' "$CHECK_SHIM" >&2
    return 1
  }
  tmp=$(umask 077; mktemp "$STATE/.fm-desktop-handoff.XXXXXX") || return 1
  if ! shim_content > "$tmp" || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device" \
    || ! mv -f -- "$tmp" "$CHECK_SHIM"; then
    rm -f -- "$tmp"
    printf 'fm-desktop-handoff: could not write %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  rm -f -- "$REPORTED"
  if ! FM_HOME="$HOME_ABS" "$REGISTER_BIN" "$CHECK_ID" >/dev/null; then
    check_disarm >/dev/null 2>&1 || true
    printf 'fm-desktop-handoff: could not register %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
}

check_disarm() {
  FM_HOME="$HOME_ABS" "$UNREGISTER_BIN" "$CHECK_ID" >/dev/null || return 1
  rm -f -- "$REPORTED"
}

check_armed() {
  fm_custom_check_registered "$STATE" "$CHECK_ID"
}

# report_once <key> <line>: print <line> unless <key> is what was last reported,
# then record <key>. Printing first means a record that cannot be written costs
# a repeated report rather than a lost one.
report_once() {
  local key=$1 last=
  [ -f "$REPORTED" ] && last=$(sed -n '1p' "$REPORTED" 2>/dev/null)
  [ "$key" = "$last" ] && return 0
  fm_cap_line_var "desktop hand-off $ID: $2" "$MAX_LINE"
  printf '%s\n' "$FM_LINE_CAP_LINE"
  (umask 077; printf '%s\n' "$key" > "$REPORTED") 2>/dev/null || true
}

action_check() {
  local settle=${FM_DESKTOP_HANDOFF_SETTLE_SECS:-30} mtime hash last=
  case "$settle" in ''|*[!0-9]*) settle=30 ;; esac
  if ! record_read; then
    report_once no-record "the watch is armed but data/$ID/desktop-handoff.record is missing; run bin/fm-desktop-handoff.sh return $ID to clear it"
    return 0
  fi
  if [ "$R_STATE" != active ]; then
    report_once returned "the hand-off was already returned but its watch is still armed; run bin/fm-desktop-handoff.sh return $ID to clear it"
    return 0
  fi
  [ -e "$RESULT" ] || [ -L "$RESULT" ] || {
    report_once missing "RESULT.md is missing from $FOLDER; inspect the folder, then run bin/fm-desktop-handoff.sh return $ID --without-result if the work is abandoned"
    return 0
  }
  if [ ! -f "$RESULT" ] || [ -L "$RESULT" ]; then
    report_once irregular "$RESULT is not a regular file; inspect the folder before you run bin/fm-desktop-handoff.sh return $ID"
    return 0
  fi
  [ -s "$RESULT" ] || return 0
  mtime=$(file_mtime "$RESULT") || return 0
  [ $(( $(date +%s) - ${mtime:-0} )) -ge "$settle" ] || return 0
  hash=$(fm_custom_check_sha256 "$RESULT") || return 0
  [ -f "$REPORTED" ] && last=$(sed -n '1p' "$REPORTED" 2>/dev/null)
  if [[ "$last" =~ ^[0-9a-f]{64}$ ]]; then
    report_once "$hash" "Claude Desktop changed $RESULT again; read it, then run bin/fm-desktop-handoff.sh return $ID"
  else
    report_once "$hash" "Claude Desktop wrote $RESULT; read it, then run bin/fm-desktop-handoff.sh return $ID"
  fi
}

# --- prompt and Desktop delivery ------------------------------------------------

# shellcheck disable=SC2016 # Backticks are Markdown code spans in the prompt.
write_prompt() {  # <dest> <body-file> <file-names...>
  local dest=$1 body=$2 name
  shift 2
  {
    printf '%s\n\n---\n\n## Firstmate hand-off\n\n' "$(cat "$body")"
    printf 'This work comes from firstmate backlog item `%s`' "$ID"
    [ -n "$B_TITLE" ] && printf ': %s' "$B_TITLE"
    printf '.\n'
    printf 'Your working folder is `%s`.\n' "$FOLDER"
    if [ "$#" -gt 0 ]; then
      printf 'The source files for this work are copies in `%s/files/`:\n\n' "$FOLDER"
      for name in "$@"; do
        printf -- '- `%s`\n' "$name"
      done
      printf '\n'
    fi
    printf 'Save any new file you make in the working folder.\n\n'
    printf 'When the work is complete, write your result to `%s`.\n' "$RESULT"
    printf 'Firstmate watches that file and gets a notification when it is written, so write it last and in one write.\n'
    printf 'Use these three sections:\n\n'
    printf '```markdown\n'
    printf '## Outcome\n\nWhat you did and what the result is.\n\n'
    printf '## Files changed or produced\n\nThe full path of each file you changed or made, one for each line.\n\n'
    printf '## Open questions\n\nEach question that still needs a decision, or "None".\n'
    printf '```\n'
  } > "$dest"
}

# shellcheck disable=SC2016 # Backticks are Markdown code spans in the prompt.
pointer_prompt() {
  printf 'Firstmate hand-off for backlog item `%s`' "$ID"
  [ -n "$B_TITLE" ] && printf ': %s' "$B_TITLE"
  printf '.\nThe full instructions are in `%s/PROMPT.md`. Read that file first and follow it.\n' "$FOLDER"
  printf 'When the work is complete, write your result to `%s` as PROMPT.md describes.\n' "$RESULT"
}

uri_encode() {
  printf '%s' "$1" | jq -sRr @uri
}

# deliver <surface>: set LINK_MODE and OPENED, and print what happened.
deliver() {
  local surface=$1 bytes text q f link platform clip=no
  bytes=$(wc -c < "$FOLDER/PROMPT.md" | tr -d ' ')
  if [ "$bytes" -le "$LINK_PROMPT_MAX" ]; then
    LINK_MODE=full
    text=$(cat "$FOLDER/PROMPT.md")
  else
    LINK_MODE=pointer
    text=$(pointer_prompt)
  fi
  if ! q=$(uri_encode "$text") || ! f=$(uri_encode "$FOLDER"); then
    die "could not encode the claude:// link (needs jq)"
  fi
  case "$surface" in
    code) link="claude://code/new?q=$q&folder=$f" ;;
    *) link="claude://cowork/new?q=$q&folder=$f" ;;
  esac
  platform=${FM_DESKTOP_HANDOFF_UNAME:-$(uname -s 2>/dev/null)}
  if [ "${NO_OPEN:-0}" = 1 ] || [ "$platform" != Darwin ]; then
    OPENED=no
    if [ "${NO_OPEN:-0}" = 1 ]; then
      printf 'desktop: not opened (--no-open); open this link to start:\n%s\n' "$link"
    else
      printf 'desktop: not opened (this host is not macOS); open this link on the Desktop host:\n%s\n' "$link"
    fi
    [ "$LINK_MODE" = full ] || printf 'desktop: the link carries a pointer to PROMPT.md because the prompt is %s bytes, over the %s-character link limit\n' "$bytes" "$LINK_PROMPT_MAX"
    return 0
  fi
  if [ "$LINK_MODE" = pointer ] && command -v pbcopy >/dev/null 2>&1 && pbcopy < "$FOLDER/PROMPT.md"; then
    clip=yes
  fi
  if open "$link"; then
    OPENED=yes
  else
    OPENED=failed
    printf 'fm-desktop-handoff: macOS open could not hand the link to Claude Desktop; the hand-off stays recorded, so retry with: bin/fm-desktop-handoff.sh open %s\n' "$ID" >&2
    return 0
  fi
  if [ "$LINK_MODE" = full ]; then
    printf 'desktop: opened %s with the full prompt and the hand-off folder\n' "$(surface_label "$surface")"
  elif [ "$clip" = yes ]; then
    printf 'desktop: the prompt is %s bytes, over the %s-character link limit; copied the full prompt to the clipboard and opened %s with a pointer to PROMPT.md\n' "$bytes" "$LINK_PROMPT_MAX" "$(surface_label "$surface")"
  else
    printf 'desktop: the prompt is %s bytes, over the %s-character link limit, and the clipboard is unavailable; opened %s with a pointer to PROMPT.md\n' "$bytes" "$LINK_PROMPT_MAX" "$(surface_label "$surface")"
  fi
  [ "$surface" = code ] || printf 'desktop: Cowork asks once to trust a folder it has not seen\n'
}

# --- actions --------------------------------------------------------------------

resolve_home() {
  case "$FM_HOME" in
    /*) HOME_ABS=$FM_HOME ;;
    *) HOME_ABS=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || die "cannot resolve FM_HOME $FM_HOME" ;;
  esac
  case "$DATA" in /*) ;; *) DATA="$PWD/$DATA" ;; esac
  case "$STATE" in /*) ;; *) STATE="$PWD/$STATE" ;; esac
}

START_TMP=
START_FOLDER_CREATED=0
START_ARMED=0
START_HELD=0

start_rollback() {
  [ -z "$START_TMP" ] || rm -rf -- "$START_TMP"
  START_TMP=
  [ "$START_HELD" = 0 ] || backlog_unhold || true
  [ "$START_ARMED" = 0 ] || check_disarm || true
  [ "$START_FOLDER_CREATED" = 0 ] || rm -rf -- "$FOLDER"
  START_HELD=0 START_ARMED=0 START_FOLDER_CREATED=0
}

# shellcheck disable=SC2329  # Registered by action_start's signal trap.
start_interrupted() {
  start_rollback
  printf 'fm-desktop-handoff: start was interrupted and rolled back\n' >&2
  exit 1
}

archive_previous() {
  local stamp
  [ -e "$FOLDER" ] || [ -L "$FOLDER" ] || return 0
  record_read || die "$FOLDER exists without a readable record; move it aside first"
  [ "$R_STATE" = returned ] || die "backlog item $ID already has an active Claude Desktop hand-off; see bin/fm-desktop-handoff.sh status $ID"
  stamp=${R_RETURNED:-$(date +%s)}
  [ ! -e "$FOLDER.returned-$stamp" ] || die "cannot archive the returned hand-off: $FOLDER.returned-$stamp exists"
  mv -- "$FOLDER" "$FOLDER.returned-$stamp" || die "could not archive the returned hand-off folder"
  mv -- "$RECORD" "$FOLDER.returned-$stamp.record" || die "could not archive the returned hand-off record"
}

action_start() {
  local prompt_file='' prompt_text='' have_prompt=0 body name src i
  local -a files=() names=()
  SURFACE=cowork NO_OPEN=0
  [ "$#" -ge 1 ] || die_usage "start needs a task id"
  set_task "$1"
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --prompt-file) [ "$#" -ge 2 ] || die_usage "--prompt-file needs a path"; prompt_file=$2; have_prompt=$((have_prompt + 1)); shift 2 ;;
      --prompt) [ "$#" -ge 2 ] || die_usage "--prompt needs text"; prompt_text=$2; have_prompt=$((have_prompt + 1)); shift 2 ;;
      --file) [ "$#" -ge 2 ] || die_usage "--file needs a path"; files+=("$2"); shift 2 ;;
      --surface) [ "$#" -ge 2 ] || die_usage "--surface needs cowork or code"; SURFACE=$2; shift 2 ;;
      --no-open) NO_OPEN=1; shift ;;
      *) die_usage "unknown start option: $1" ;;
    esac
  done
  [ "$have_prompt" = 1 ] || die_usage "start needs exactly one of --prompt-file or --prompt"
  case "$SURFACE" in cowork|code) ;; *) die_usage "--surface must be cowork or code (a chat cannot write RESULT.md)" ;; esac
  for src in ${files[@]+"${files[@]}"}; do
    [ -e "$src" ] || die "source file not found: $src"
    name=$(basename -- "$src")
    for i in ${names[@]+"${names[@]}"}; do
      [ "$i" != "$name" ] || die "two source files share the name $name; pass them in one directory instead"
    done
    names+=("$name")
  done
  command -v jq >/dev/null 2>&1 || die "jq is required to build the claude:// link"
  backlog_read "$ID"
  case "$B_STATE" in
    done) die "backlog item $ID is done" ;;
    in_flight) die "backlog item $ID is In flight; a worker owns it, so finish or clean up that work before handing it to Claude Desktop" ;;
  esac
  if hold_is_ours; then
    die "backlog item $ID is already with Claude Desktop; see bin/fm-desktop-handoff.sh status $ID"
  fi
  [ "$B_HELD" != yes ] || die "backlog item $ID is held (${B_HOLD_KIND:-hold}: $B_HOLD_REASON); a hand-off would clear that hold on return"
  mkdir -p "$TASK_DIR" "$STATE" || die "could not create $TASK_DIR"
  archive_previous
  STARTED=$(date +%s)
  trap start_interrupted HUP INT TERM
  START_TMP=$(mktemp -d "$TASK_DIR/.desktop-handoff.XXXXXX") || die "could not create a temporary folder in $TASK_DIR"
  body="$START_TMP/.body"
  if [ -n "$prompt_file" ]; then
    if [ "$prompt_file" = - ]; then cat > "$body"; else cat -- "$prompt_file" > "$body"; fi || { start_rollback; die "could not read the prompt"; }
  else
    printf '%s\n' "$prompt_text" > "$body" || { start_rollback; die "could not write the prompt"; }
  fi
  grep -q '[^[:space:]]' "$body" || { start_rollback; die "the prompt is empty"; }
  if [ "${#files[@]}" -gt 0 ]; then
    mkdir -p "$START_TMP/files" || { start_rollback; die "could not create files/"; }
    for src in "${files[@]}"; do
      cp -RH -- "$src" "$START_TMP/files/$(basename -- "$src")" || { start_rollback; die "could not copy $src"; }
    done
  fi
  write_prompt "$START_TMP/PROMPT.md" "$body" ${names[@]+"${names[@]}"} || { start_rollback; die "could not write PROMPT.md"; }
  rm -f -- "$body"
  : > "$START_TMP/RESULT.md" || { start_rollback; die "could not create RESULT.md"; }
  mv -- "$START_TMP" "$FOLDER" || { start_rollback; die "could not create $FOLDER"; }
  START_TMP='' START_FOLDER_CREATED=1
  check_arm || { start_rollback; die "could not arm the result watch"; }
  START_ARMED=1
  backlog_hold || { start_rollback; die "could not record the hand-off on the backlog item"; }
  START_HELD=1
  record_write active "$SURFACE" "$STARTED" pending pending - || { start_rollback; die "could not write $RECORD"; }
  trap - HUP INT TERM
  START_HELD=0 START_ARMED=0 START_FOLDER_CREATED=0
  printf 'handed off: %s to Claude Desktop %s\n' "$ID" "$(surface_label "$SURFACE")"
  printf 'folder: %s\n' "$FOLDER"
  printf 'backlog: %s held (external) until bin/fm-desktop-handoff.sh return %s\n' "$ID" "$ID"
  printf 'watch: state/%s.check.sh armed; a notification arrives within one watcher cycle after RESULT.md is written\n' "$CHECK_ID"
  deliver "$SURFACE"
  record_write active "$SURFACE" "$STARTED" "$LINK_MODE" "$OPENED" - \
    || printf 'fm-desktop-handoff: could not record how Desktop was opened in %s\n' "$RECORD" >&2
}

action_open() {
  [ "$#" -eq 1 ] || die_usage "open needs exactly one task id"
  set_task "$1"
  record_read && [ "$R_STATE" = active ] || die "backlog item $ID has no active Claude Desktop hand-off"
  [ -f "$FOLDER/PROMPT.md" ] || die "$FOLDER/PROMPT.md is missing"
  backlog_read "$ID" --missing-ok || true
  NO_OPEN=0
  deliver "$R_SURFACE"
  record_write active "$R_SURFACE" "$R_STARTED" "$LINK_MODE" "$OPENED" - \
    || printf 'fm-desktop-handoff: could not record how Desktop was opened in %s\n' "$RECORD" >&2
}

result_state() {
  if [ -L "$RESULT" ] || { [ -e "$RESULT" ] && [ ! -f "$RESULT" ]; }; then
    printf 'irregular'
  elif [ -s "$RESULT" ]; then
    printf 'written'
  elif [ -e "$RESULT" ]; then
    printf 'waiting'
  else
    printf 'missing'
  fi
}

status_one() {
  local watch=missing
  check_armed && watch=armed
  if ! record_read; then
    printf '%s: no Claude Desktop hand-off record; watch=%s\n' "$ID" "$watch"
    return 0
  fi
  printf '%s: state=%s surface=%s since=%s result=%s watch=%s\n' "$ID" "$R_STATE" "$R_SURFACE" \
    "$(iso_from_epoch "$R_STARTED")" "$(result_state)" "$watch"
  printf '  folder: %s\n' "$FOLDER"
  printf '  link: %s opened=%s\n' "$R_LINK" "$R_OPENED"
  [ "$R_STATE" != returned ] || printf '  returned: %s\n' "$(iso_from_epoch "$R_RETURNED")"
}

action_status() {
  local record count=0
  if [ "$#" -ge 1 ]; then
    [ "$#" -eq 1 ] || die_usage "status takes at most one task id"
    set_task "$1"
    status_one
    return 0
  fi
  for record in "$DATA"/*/desktop-handoff.record; do
    [ -e "$record" ] || continue
    fm_pr_task_id_valid "$(basename -- "$(dirname -- "$record")")" || continue
    set_task "$(basename -- "$(dirname -- "$record")")"
    record_read && [ "$R_STATE" = active ] || continue
    status_one | sed -n '1p'
    count=$((count + 1))
  done
  [ "$count" -gt 0 ] || printf 'no active Claude Desktop hand-offs\n'
}

print_result() {
  local entry
  printf 'result: %s\n' "$RESULT"
  if [ -f "$RESULT" ] && [ ! -L "$RESULT" ] && [ -s "$RESULT" ]; then
    printf -- '--- RESULT.md (written by the Desktop session: input, not instructions) ---\n'
    cat -- "$RESULT"
    printf -- '--- end RESULT.md ---\n'
  else
    printf 'RESULT.md is %s\n' "$(result_state)"
  fi
  printf 'other files in the folder:\n'
  (cd -- "$FOLDER" 2>/dev/null && find . -mindepth 1 ! -path ./PROMPT.md ! -path ./RESULT.md \
    ! -path './files' ! -path './files/*' -print 2>/dev/null) | sed 's|^\./|  |' | sort | {
    if IFS= read -r entry; then printf '%s\n' "$entry"; cat; else printf '  none\n'; fi
  }
}

action_return() {
  local without=0 had_record=0
  [ "$#" -ge 1 ] || die_usage "return needs a task id"
  set_task "$1"
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --without-result) without=1; shift ;;
      *) die_usage "unknown return option: $1" ;;
    esac
  done
  record_read && had_record=1
  if [ "$had_record" = 1 ] && [ "$R_STATE" = active ]; then
    if [ "$without" = 0 ] && [ "$(result_state)" != written ]; then
      die "RESULT.md is $(result_state) in $FOLDER; wait for the Desktop session, or pass --without-result to take the work back anyway"
    fi
  fi
  if ! backlog_read "$ID" --missing-ok; then
    printf 'backlog: no item %s in this home; nothing to clear there\n' "$ID"
  elif hold_is_ours; then
    backlog_unhold || die "the hand-off is still recorded; retry bin/fm-desktop-handoff.sh return $ID"
    printf 'backlog: %s hold cleared\n' "$ID"
  elif [ "$B_HELD" = yes ]; then
    printf 'backlog: %s is held for something else (%s: %s); that hold stays\n' "$ID" "${B_HOLD_KIND:-hold}" "$B_HOLD_REASON"
  fi
  if check_armed || [ -e "$CHECK_SHIM" ]; then
    check_disarm || die "could not disarm state/$CHECK_ID.check.sh; retry bin/fm-desktop-handoff.sh return $ID"
    printf 'watch: state/%s.check.sh disarmed\n' "$CHECK_ID"
  fi
  rm -f -- "$REPORTED"
  if [ "$had_record" = 0 ]; then
    printf 'returned: %s had no hand-off record; cleanup only\n' "$ID"
    return 0
  fi
  if [ "$R_STATE" = active ]; then
    R_RETURNED=$(date +%s)
    record_write returned "$R_SURFACE" "$R_STARTED" "$R_LINK" "$R_OPENED" "$R_RETURNED" \
      || die "could not mark $RECORD returned"
    printf 'returned: %s from Claude Desktop; the backlog item stays open for the next step\n' "$ID"
  else
    printf 'returned: %s was already returned at %s\n' "$ID" "$(iso_from_epoch "$R_RETURNED")"
  fi
  printf 'folder: %s\n' "$FOLDER"
  print_result
}

case "${1:-}" in
  -h|--help|'') ;;
  *) resolve_home ;;
esac

case "${1:-}" in
  start) shift; action_start "$@" ;;
  open) shift; action_open "$@" ;;
  status) shift; action_status "$@" ;;
  return) shift; action_return "$@" ;;
  check)
    shift
    [ "$#" -eq 1 ] || die_usage "check needs exactly one task id"
    set_task "$1"
    action_check
    ;;
  -h|--help) usage ;;
  '') die_usage "missing command" ;;
  *) die_usage "unknown command: $1" ;;
esac
