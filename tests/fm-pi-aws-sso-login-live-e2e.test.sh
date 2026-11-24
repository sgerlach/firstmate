#!/usr/bin/env bash
# Default-on live guard for the Pi single-bang AWS SSO login notice. The
# guarantee rests on what a real interactive Pi records for a `!` command, so
# only a running Pi can prove it: a recognized login must keep its raw output,
# browser URL and login code out of every model request and the session file,
# show that output live to the user, and notify Firstmate only after exit 0,
# while `!!`, ordinary commands, ambiguous shell forms and model tool calls stay
# exactly as stock Pi handles them.
#
# No model turn reaches any provider: a local faux provider records each request
# it receives. A fake `aws` prints canary URL, code, stderr and result lines.
# Scratch FM_HOME, project, Pi agent directory, session directory, TMPDIR and a
# private tmux socket; nothing global is touched. tests/fm-pi-aws-sso-login.test.sh
# pins the same logic without Pi.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_PI_AWS_SSO_LOGIN_LIVE pi tmux node

PI_VERSION=$(pi --version 2>/dev/null || printf 'unknown')
SOCKET="fm-pi-aws-sso-login-$$"
SESSION=aws-sso-login
TMP_ROOT=$(fm_test_tmproot fm-pi-aws-sso-login-live)
PROJECT="$TMP_ROOT/project"
PROBE="$TMP_ROOT/requests"
CONTROL="$TMP_ROOT/aws-control"
RELEASE="$TMP_ROOT/aws-release"
mkdir -p "$PROJECT" "$PROBE" "$TMP_ROOT/bin" "$TMP_ROOT/agent" "$TMP_ROOT/sessions" \
  "$TMP_ROOT/home/state" "$TMP_ROOT/tmp"

cleanup() {
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT

LIVE_HEADER='AWS SSO login output (live, kept out of model context):'
CANARIES='CANARY-URL-7Q4Z CANARYCODE-ABCD-EFGH CANARY-STDERR-91X canary-start-url CANARY-FAILURE-55K'

cat >"$TMP_ROOT/bin/aws" <<'SH'
#!/bin/sh
# Line 1 of the control file is the exit code. Line 2 "hold" waits for the
# release file (bounded at 60 seconds) before the result line.
exit_code=$(sed -n 1p "$SSO_FAKE_AWS_CONTROL")
wait_mode=$(sed -n 2p "$SSO_FAKE_AWS_CONTROL")
echo "Attempting to automatically open the SSO authorization page in your default browser."
echo "If the browser does not open, open the following URL:"
echo ""
echo "https://device.sso.us-east-1.amazonaws.com/?user_code=CANARY-URL-7Q4Z"
echo ""
echo "Then enter the code:"
echo ""
echo "CANARYCODE-ABCD-EFGH"
echo "CANARY-STDERR-91X token detail" >&2
if [ "$wait_mode" = hold ]; then
  i=0
  while [ ! -e "$SSO_FAKE_AWS_RELEASE" ] && [ "$i" -lt 600 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  rm -f "$SSO_FAKE_AWS_RELEASE"
fi
if [ "$exit_code" = 0 ]; then
  echo "Successfully logged into Start URL: https://canary-start-url.awsapps.com/start"
else
  echo "Error when retrieving token from sso: CANARY-FAILURE-55K" >&2
fi
exit "$exit_code"
SH
chmod +x "$TMP_ROOT/bin/aws"

cat >"$PROJECT/request-probe.ts" <<'TS'
import { writeFileSync } from "node:fs";
import { createFauxCore, fauxAssistantMessage, fauxText, fauxToolCall } from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const dir = process.env.SSO_PROBE_DIR as string;
let calls = 0;

export default function (pi: ExtensionAPI): void {
  const faux = createFauxCore({
    api: "aws-sso-login-probe-api",
    provider: "aws-sso-login-probe",
    models: [{
      id: "deterministic",
      name: "AWS SSO login notice probe",
      reasoning: false,
      input: ["text"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: 65536,
      maxTokens: 256,
    }],
    tokenSize: { min: 1, max: 1 },
  });
  const respond = (context: { messages: Array<{ role: string }> }) => {
    calls += 1;
    writeFileSync(`${dir}/request-${calls}.json`, JSON.stringify(context));
    faux.appendResponses([respond]);
    const last = context.messages[context.messages.length - 1];
    if (last?.role === "user" && JSON.stringify(last).includes("RUN_TOOL_LOGIN")) {
      return fauxAssistantMessage(
        [fauxToolCall("bash", { command: "aws sso login --profile dev" }, { id: `probe_tool_${calls}` })],
        { stopReason: "toolUse" },
      );
    }
    return fauxAssistantMessage([fauxText(`PROBE_REPLY_${calls}`)]);
  };
  faux.setResponses([respond]);
  pi.registerProvider("aws-sso-login-probe", {
    baseUrl: "http://127.0.0.1/unused",
    apiKey: "test-only",
    api: faux.api,
    models: faux.models,
    streamSimple: faux.streamSimple,
  });
}
TS

printf '0\nnow\n' >"$CONTROL"
tmux -L "$SOCKET" new-session -d -s "$SESSION" -x 200 -y 50 \
  "cd '$PROJECT' && env -u FM_TASK_ID -u FM_TASK_INBOX FM_HOME='$TMP_ROOT/home' FM_STATE_OVERRIDE='$TMP_ROOT/home/state' TMPDIR='$TMP_ROOT/tmp' PATH='$TMP_ROOT/bin:$PATH' PI_CODING_AGENT_DIR='$TMP_ROOT/agent' PI_OFFLINE=1 PI_SKIP_VERSION_CHECK=1 PI_TELEMETRY=0 SSO_PROBE_DIR='$PROBE' SSO_FAKE_AWS_CONTROL='$CONTROL' SSO_FAKE_AWS_RELEASE='$RELEASE' pi --approve --no-context-files --no-skills --no-prompt-templates --no-extensions -e ./request-probe.ts -e '$ROOT/.pi/extensions/fm-aws-sso-login.ts' --model aws-sso-login-probe/deterministic --session-dir '$TMP_ROOT/sessions'; sleep 60"

pane() { tmux -L "$SOCKET" capture-pane -p -J -t "$SESSION" -S -200 2>/dev/null; }
screen() { tmux -L "$SOCKET" capture-pane -p -J -t "$SESSION" 2>/dev/null; }
die() { fail "Pi $PI_VERSION: $1"$'\n'"$(screen)"; }
wait_screen() {  # <fixed text> <what>
  local i=0
  until screen | grep -Fq -- "$1"; do
    i=$((i + 1))
    [ "$i" -lt 300 ] || die "timed out waiting for $2"
    sleep 0.1
  done
}
wait_screen_gone() {  # <fixed text> <what>
  local i=0
  while screen | grep -Fq -- "$1"; do
    i=$((i + 1))
    [ "$i" -lt 300 ] || die "timed out waiting for $2"
    sleep 0.1
  done
}
request() { printf '%s/request-%s.json' "$PROBE" "$1"; }
wait_request() {  # <n> <what>
  local i=0
  until [ -s "$(request "$1")" ]; do
    i=$((i + 1))
    [ "$i" -lt 300 ] || die "timed out waiting for model request $1 ($2)"
    sleep 0.1
  done
}
request_count() { find "$PROBE" -name 'request-*.json' | wc -l | tr -d ' '; }
type_line() {
  tmux -L "$SOCKET" send-keys -t "$SESSION" -l "$1"
  tmux -L "$SOCKET" send-keys -t "$SESSION" Enter
}
lacks_canaries() {  # <file> <where>
  local canary
  for canary in $CANARIES; do
    ! grep -Fq -- "$canary" "$1" || die "$2 contains the raw login output marker $canary"
  done
}
envelopes() { grep -o 'FIRSTMATE_OP: v1 aws-sso-login: ' "$1" | wc -l | tr -d ' '; }
session_file() { find "$TMP_ROOT/sessions" -name '*.jsonl' | head -1; }
# The text of the one user message whose bash record starts with <prefix>.
bash_record() {  # <request file> <prefix>
  node -e '
const context = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
const texts = context.messages.filter((m) => m.role === "user")
  .map((m) => (typeof m.content === "string" ? m.content : m.content.map((c) => c.text ?? "").join("")))
  .filter((t) => t.startsWith(process.argv[2]));
if (texts.length !== 1) process.exit(1);
process.stdout.write(texts[0]);
' "$1" "$2"
}

wait_screen 'deterministic' 'the Pi composer'

# 1. A profile login: live output on screen while it runs, then one notice.
printf '0\nhold\n' >"$CONTROL"
type_line '!aws sso login --profile dev'
wait_screen "$LIVE_HEADER" 'the live login widget'
wait_screen 'CANARYCODE-ABCD-EFGH' 'the login code in the live widget'
touch "$RELEASE"
wait_request 1 'the notice turn after a successful profile login'
R1=$(request 1)
lacks_canaries "$R1" 'the notice turn request'
wait_screen 'Firstmate was notified that AWS SSO login exited 0 (profile "dev").' 'the notice confirmation'
wait_screen_gone 'CANARYCODE-ABCD-EFGH' 'the live widget to clear after success'
[ "$(envelopes "$R1")" = 1 ] || die 'the first request must carry exactly one aws-sso-login notice'
grep -Fq 'exited 0 (profile \"dev\")' "$R1" || die 'the notice must name the typed profile'
# shellcheck disable=SC2016 # Literal backticks: Pi's record quotes the command in Markdown.
record=$(bash_record "$R1" 'Ran `aws sso login --profile dev`') \
  || die 'the request must carry the login command record exactly once'
# shellcheck disable=SC2016 # Literal backticks: Pi's record quotes the command in Markdown.
expected_record=$(printf 'Ran `aws sso login --profile dev`\n```\n%s\n```' \
  'Firstmate withheld this AWS SSO login output from model context; it shows live above the editor.')
[ "$record" = "$expected_record" ] \
  || die "the login record must hold only the withheld-output line, got: $record"
node -e '
const lines = require("node:fs").readFileSync(process.argv[1], "utf8").trim().split("\n").map((l) => JSON.parse(l));
const bash = lines.findIndex((e) => e.type === "message" && e.message?.role === "bashExecution");
const notice = lines.findIndex((e) => e.type === "custom_message" && e.customType === "fm-aws-sso-login");
process.exit(bash >= 0 && notice > bash ? 0 : 1);
' "$(session_file)" || die 'the session must record the command before the notice'
pass "Pi $PI_VERSION: a profile login shows its output live, withholds it from the model and notifies after its own record"

# 2. An SSO session selector in the --flag=value form.
printf '0\nnow\n' >"$CONTROL"
type_line '!aws sso login --sso-session=corp'
wait_request 2 'the notice turn after an SSO session login'
lacks_canaries "$(request 2)" 'the SSO session notice request'
grep -Fq 'exited 0 (SSO session \"corp\")' "$(request 2)" || die 'the notice must name the typed SSO session'

# 3. No selector: the notice names none and infers no profile.
type_line '!aws sso login'
wait_request 3 'the notice turn after a bare login'
lacks_canaries "$(request 3)" 'the bare login notice request'
grep -Fq 'exited 0 (no --profile or --sso-session selector)' "$(request 3)" \
  || die 'a bare login notice must say no selector was given'
pass "Pi $PI_VERSION: SSO session and bare logins notify with only the typed selector"

# 4. A failed login: its output stays on screen, out of the model, and no notice.
printf '2\nnow\n' >"$CONTROL"
type_line '!aws sso login --profile dev'
wait_screen 'AWS SSO login exited 2.' 'the kept failure output'
wait_screen 'CANARY-FAILURE-55K' 'the failure detail on screen'
sleep 1.5
[ "$(request_count)" = 3 ] || die 'a failed login must not notify Firstmate'
type_line 'PROBE_AFTER_FAILURE'
wait_request 4 'the prompt after a failed login'
wait_screen_gone 'CANARY-FAILURE-55K' 'the failure output to clear at the next input'
lacks_canaries "$(request 4)" 'the request after a failed login'
[ "$(envelopes "$(request 4)")" = 3 ] || die 'a failed login must add no notice'
grep -Fq 'Command exited with code 2' "$(request 4)" || die 'the failed login record must keep its exit code'
pass "Pi $PI_VERSION: a failed login keeps its output on screen only, and Firstmate gets no notice"

# 5. Escape cancels a running login: no notice, widget cleared.
printf '0\nhold\n' >"$CONTROL"
type_line '!aws sso login --profile dev'
wait_screen "$LIVE_HEADER" 'the live widget of the login to cancel'
tmux -L "$SOCKET" send-keys -t "$SESSION" Escape
wait_screen_gone "$LIVE_HEADER" 'the live widget to clear after Escape'
sleep 1.5
[ "$(request_count)" = 4 ] || die 'a cancelled login must not notify Firstmate'
type_line 'PROBE_AFTER_CANCEL'
wait_request 5 'the prompt after a cancelled login'
lacks_canaries "$(request 5)" 'the request after a cancelled login'
[ "$(envelopes "$(request 5)")" = 3 ] || die 'a cancelled login must add no notice'
grep -Fq '(command cancelled)' "$(request 5)" || die 'the cancelled login record must say it was cancelled'
lacks_canaries "$(session_file)" 'the session file'
if grep -rlF -e CANARY -e canary-start-url "$TMP_ROOT/tmp" >/dev/null 2>&1; then
  die 'a Pi output file holds raw login output'
fi
pass "Pi $PI_VERSION: Escape cancels a login without a notice, and no session or output file holds its raw output"

# 6. Double bang stays stock Pi: output on screen, excluded from context, no notice.
printf '0\nnow\n' >"$CONTROL"
type_line '!!aws sso login --profile dev'
wait_screen 'canary-start-url' 'the double-bang output in the transcript'
sleep 1.5
[ "$(request_count)" = 5 ] || die 'a double-bang login must not notify Firstmate'
! screen | grep -Fq "$LIVE_HEADER" || die 'a double-bang login must not use the live widget'
type_line 'PROBE_AFTER_DOUBLE_BANG'
wait_request 6 'the prompt after a double-bang login'
lacks_canaries "$(request 6)" 'the request after a double-bang login'
[ "$(envelopes "$(request 6)")" = 3 ] || die 'a double-bang login must add no notice'
pass "Pi $PI_VERSION: a double-bang login stays stock: shown, excluded from context, and silent"

# 7. Positive control: an ordinary single-bang command still reaches the model.
type_line "!printf 'CANARY-%s\\n' ORDINARY-3J"
wait_screen 'CANARY-ORDINARY-3J' 'the ordinary command output'
type_line 'PROBE_AFTER_ORDINARY'
wait_request 7 'the prompt after an ordinary command'
grep -Fq 'CANARY-ORDINARY-3J' "$(request 7)" || die 'an ordinary single-bang command must reach the model unchanged'

# 8. A model tool call that runs the same login is not intercepted.
type_line 'RUN_TOOL_LOGIN'
wait_request 9 'the request after the model bash tool call'
grep -Fq 'CANARYCODE-ABCD-EFGH' "$(request 9)" || die 'a model bash tool call must keep its stock output'
[ "$(envelopes "$(request 9)")" = 3 ] || die 'a model bash tool call must add no notice'

# 9. An ambiguous shell form is unrecognized and runs as stock single-bang Pi.
type_line "!aws sso login --profile dev && printf 'AMBIGUOUS-%s\\n' DONE-8P"
wait_screen 'AMBIGUOUS-DONE-8P' 'the ambiguous form output'
type_line 'PROBE_AFTER_AMBIGUOUS'
wait_request 10 'the prompt after the ambiguous form'
record=$(bash_record "$(request 10)" 'Ran `aws sso login --profile dev && printf') \
  || die 'the ambiguous form must be recorded as an ordinary command'
case "$record" in
  *CANARYCODE-ABCD-EFGH*) ;;
  *) die "the ambiguous form must keep its stock output, got: $record" ;;
esac
[ "$(envelopes "$(request 10)")" = 3 ] || die 'an ambiguous form must add no notice'
pass "Pi $PI_VERSION: ordinary commands, model tool calls and ambiguous shell forms stay stock"
