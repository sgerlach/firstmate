#!/usr/bin/env bash
# Executes the Pi single-bang AWS SSO login notice against fake Pi, shell and
# encoder objects: recognition, output withholding, the live widget, the notice
# and its delivery options, and the paths that must stay untouched. The real
# operational-input encoder runs once; the entrypoint's worker gate runs against
# the installed Pi package when it is present. No model, tmux or live home.
# tests/fm-pi-aws-sso-login-live-e2e.test.sh proves the same contract in a real
# interactive Pi.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# One Node process shares the imports; only completed assertions emit results.
if ! results=$(
  NODE_NO_WARNINGS=1 FM_SSO_TEST_ROOT="$ROOT" node --input-type=module-typescript <<'TS'
import assert from "node:assert/strict";
import { resolve } from "node:path";

const root = process.env.FM_SSO_TEST_ROOT as string;
const lib = await import(`${root}/.pi/extensions/lib/fm-aws-sso-login.ts`);
const { runCommandAsync } = await import(`${root}/.pi/extensions/lib/fm-async-exec.ts`);
const operational = await import(`${root}/.pi/extensions/lib/fm-operational-input.ts`);
const {
  recognizeAwsSsoLogin, describeAwsSsoSelector, awsSsoLoginNoticeBody, WITHHELD_OUTPUT_LINE,
  LIVE_HEADER, failedLoginHeader, LIVE_TAIL_LINES, displayLine, LiveOutput, liveWidgetLines,
  withheldLoginOperations, expandShellPath, registerAwsSsoLoginNotice, WIDGET_KEY, NOTICE_TYPE,
} = lib;

async function check(name: string, body: () => void | Promise<void>): Promise<void> {
  try {
    await body();
  } catch (error) {
    console.error(`Assertion failed: ${name}`);
    throw error;
  }
  console.log(`pass\t${name}`);
}

const tick = () => new Promise<void>((resolve) => setTimeout(resolve, 0));
const RAW = "open https://device.sso.example/?code=RAW-URL-CANARY\nRAW-CODE-CANARY\n";

function fakeLocal(result: { exitCode: number | null } | Error, chunks: string[] = [RAW]) {
  const calls: any[] = [];
  return {
    calls,
    async exec(command: string, cwd: string, options: any) {
      calls.push({ command, cwd, options });
      for (const chunk of chunks) options.onData(Buffer.from(chunk));
      if (result instanceof Error) throw result;
      return result;
    },
  };
}

function piHarness({ mode = "tui", shellPath = undefined as unknown, away = false, encode = undefined as any, local = fakeLocal({ exitCode: 0 }) as any } = {}) {
  const handlers = new Map<string, any>();
  const sends: any[] = [], widgets: any[] = [], notices: any[] = [], shells: any[] = [];
  const ctx: any = {
    mode,
    ui: {
      setWidget(key: string, lines: unknown) { widgets.push({ key, lines }); },
      notify(text: string, level: string) { notices.push({ text, level }); },
    },
  };
  const pi: any = {
    on(name: string, fn: any) { handlers.set(name, fn); },
    getSettings() { return { shellPath }; },
    sendMessage(message: any, options: any) { sends.push({ message, options }); },
  };
  registerAwsSsoLoginNotice(pi, {
    createLocalShell(path: string | undefined) { shells.push(path); return local; },
    encodeNotice: encode ?? (async (body: string) => `ENCODED:${body}`),
    awayPostureActive: () => away,
  });
  const bang = (command: string, excludeFromContext = false) =>
    handlers.get("user_bash")({ type: "user_bash", command, excludeFromContext, cwd: "/fixture" }, ctx);
  async function run(command: string, options: any = {}) {
    const handled = bang(command);
    const piData: Buffer[] = [];
    const result = await handled.operations.exec(`prefix\n${command}`, "/fixture", {
      onData: (data: Buffer) => piData.push(data), ...options,
    });
    return { result, piText: Buffer.concat(piData).toString("utf8") };
  }
  return { handlers, sends, widgets, notices, shells, ctx, bang, run, local };
}

await check("recognizes the bare login and one profile or SSO session selector", () => {
  assert.deepEqual(recognizeAwsSsoLogin("aws sso login"), { kind: "none" });
  assert.deepEqual(recognizeAwsSsoLogin("aws sso login --profile dev"), { kind: "profile", name: "dev" });
  assert.deepEqual(recognizeAwsSsoLogin("aws sso login --profile=dev"), { kind: "profile", name: "dev" });
  assert.deepEqual(recognizeAwsSsoLogin("aws sso login --sso-session corp"), { kind: "sso-session", name: "corp" });
  assert.deepEqual(recognizeAwsSsoLogin("aws sso login --sso-session=corp"), { kind: "sso-session", name: "corp" });
  assert.deepEqual(recognizeAwsSsoLogin("aws\tsso  login\t--profile  my_team.prod-1@x+y"), { kind: "profile", name: "my_team.prod-1@x+y" });
  assert.deepEqual(recognizeAwsSsoLogin(`aws sso login --profile ${"p".repeat(64)}`), { kind: "profile", name: "p".repeat(64) });
});

await check("leaves every other flag, selector shape and shell syntax unrecognized", () => {
  const rejected = [
    "", "aws", "aws sso", "aws sso logout", "aws sso login --profile", "aws sso login --profile=",
    "aws sso login --profile= dev", "aws sso login --profile ''", "aws sso login --profile \"dev\"",
    "aws sso login --profile 'dev'", "aws sso login --profile $AWS_PROFILE", "aws sso login --profile `id`",
    "aws sso login --profile $(id)", "aws sso login --profile dev --sso-session corp",
    "aws sso login --no-browser", "aws sso login --use-device-code", "aws sso login --profile dev --no-browser",
    "aws sso login --region us-east-1", "aws sso login --profile=dev extra", "aws sso login --profile -x",
    "aws sso login --profile .", `aws sso login --profile ${"p".repeat(65)}`, "aws sso login --profile dev#x",
    "aws sso login --profile dev*", "aws sso login --profile ~dev", "AWS_PROFILE=dev aws sso login",
    "env aws sso login", "sudo aws sso login", "/usr/local/bin/aws sso login", "./aws sso login",
    "AWS sso login", "aws sso login; echo done", "aws sso login && true", "aws sso login || true",
    "aws sso login | cat", "aws sso login > out", "aws sso login 2>&1", "aws sso login &",
    "aws sso login\n", "aws sso login\necho done", "aws sso login --profile dev\necho", " aws sso login",
    "aws sso login ", "(aws sso login)", "{ aws sso login; }", "aws sso login --profile dev\\",
  ];
  for (const command of rejected) assert.equal(recognizeAwsSsoLogin(command), undefined, JSON.stringify(command));
  assert.equal(recognizeAwsSsoLogin(undefined), undefined);
  assert.equal(recognizeAwsSsoLogin(42), undefined);
});

await check("the notice carries only the typed selector and denies proof and authority", () => {
  assert.equal(describeAwsSsoSelector({ kind: "profile", name: "dev" }), 'profile "dev"');
  assert.equal(describeAwsSsoSelector({ kind: "sso-session", name: "corp" }), 'SSO session "corp"');
  assert.equal(describeAwsSsoSelector({ kind: "none" }), "no --profile or --sso-session selector");
  const named = awsSsoLoginNoticeBody({ kind: "profile", name: "dev" });
  assert.match(named, /exited 0 \(profile "dev"\)/);
  assert.match(named, /not proof that any dependency works/);
  assert.match(named, /grants no new authority/);
  assert.match(named, /re-verify that specific dependency with its own check/);
  assert.doesNotMatch(named, /https?:/);
  const bare = awsSsoLoginNoticeBody({ kind: "none" });
  assert.match(bare, /no --profile or --sso-session selector/);
  assert.doesNotMatch(bare, /default profile/);
});

await check("display lines drop escape sequences and control bytes and keep carriage-return overwrites", () => {
  assert.equal(displayLine("a\x1b[31mred\x1b[0m"), "ared");
  assert.equal(displayLine("\x1b]8;;https://x\x07link\x1b]8;;\x1b\\"), "link");
  assert.equal(displayLine("progress 1\rprogress 2"), "progress 2");
  assert.equal(displayLine("line\r\r"), "line");
  assert.equal(displayLine("bell\x07 nul\x00 c1\x9b del\x7f"), "bell nul c1 del");
  assert.equal(displayLine("a\tb"), "a  b");
  assert.equal(displayLine("x".repeat(5000)).length, 2000);
});

await check("live output keeps the newest non-blank lines across split chunks and stays bounded", () => {
  const live = new LiveOutput();
  const bytes = Buffer.from("first\r\n\nsé", "utf8");
  live.push(bytes.subarray(0, bytes.length - 1));
  live.push(bytes.subarray(bytes.length - 1));
  live.push(Buffer.from("cond\n"));
  assert.deepEqual(live.tail(9), ["first", "sécond"]);
  for (let i = 0; i < 500; i++) live.push(Buffer.from(`line ${i}\n`));
  assert.deepEqual(live.tail(3), ["line 497", "line 498", "line 499"]);
  live.push(Buffer.from("y".repeat(100_000)));
  assert.equal(live.tail(1)[0].length, 2000);
  const lines = liveWidgetLines(LIVE_HEADER, live);
  assert.equal(lines.length, 1 + LIVE_TAIL_LINES);
  assert.equal(lines[0], LIVE_HEADER);
});

await check("withheld operations give Pi only the fixed line and pass the result through", async () => {
  const local = fakeLocal({ exitCode: 0 });
  const lives: string[][] = [], outcomes: any[] = [];
  const ops = withheldLoginOperations(local, {
    onLive: (live: any) => lives.push(live.tail(9)),
    onOutcome: (outcome: any, live: any) => outcomes.push({ outcome, tail: live.tail(9) }),
  });
  const controller = new AbortController();
  const piData: Buffer[] = [];
  const result = await ops.exec("prefix\naws sso login", "/fixture", {
    onData: (data: Buffer) => piData.push(data), signal: controller.signal, timeout: 7, env: { A: "1" },
  });
  assert.deepEqual(result, { exitCode: 0 });
  assert.equal(Buffer.concat(piData).toString("utf8"), WITHHELD_OUTPUT_LINE);
  assert.equal(local.calls.length, 1);
  assert.equal(local.calls[0].command, "prefix\naws sso login");
  assert.equal(local.calls[0].cwd, "/fixture");
  assert.equal(local.calls[0].options.signal, controller.signal);
  assert.equal(local.calls[0].options.timeout, 7);
  assert.deepEqual(local.calls[0].options.env, { A: "1" });
  assert.deepEqual(lives.at(-1), ["open https://device.sso.example/?code=RAW-URL-CANARY", "RAW-CODE-CANARY"]);
  assert.deepEqual(outcomes.map((o) => o.outcome), [{ kind: "succeeded" }]);
});

await check("withheld operations classify failure, cancellation and errors and keep Pi's view", async () => {
  async function outcomeOf(local: any, signal?: AbortSignal) {
    const outcomes: any[] = [];
    const ops = withheldLoginOperations(local, { onLive() {}, onOutcome: (o: any) => outcomes.push(o) });
    let thrown: unknown;
    try {
      await ops.exec("aws sso login", "/fixture", { onData() {}, signal });
    } catch (error) {
      thrown = error;
    }
    return { outcomes, thrown };
  }
  assert.deepEqual((await outcomeOf(fakeLocal({ exitCode: 2 }))).outcomes, [{ kind: "failed", exitCode: 2 }]);
  assert.deepEqual((await outcomeOf(fakeLocal({ exitCode: null }))).outcomes, [{ kind: "failed", exitCode: null }]);
  const aborted = new AbortController();
  aborted.abort();
  const abortError = new Error("aborted");
  const cancelled = await outcomeOf(fakeLocal(abortError), aborted.signal);
  assert.deepEqual(cancelled.outcomes, [{ kind: "cancelled" }]);
  assert.equal(cancelled.thrown, abortError);
  assert.deepEqual((await outcomeOf(fakeLocal({ exitCode: 0 }), aborted.signal)).outcomes, [{ kind: "failed", exitCode: 0 }]);
  const broken = await outcomeOf(fakeLocal(new Error("Custom shell path not found: /x")));
  assert.deepEqual(broken.outcomes, [{ kind: "errored", message: "Custom shell path not found: /x" }]);
  assert.match(String(broken.thrown), /Custom shell path not found/);
  const ops = withheldLoginOperations(fakeLocal({ exitCode: 0 }), {
    onLive() { throw new Error("widget gone"); },
    onOutcome() { throw new Error("notice gone"); },
  });
  assert.deepEqual(await ops.exec("aws sso login", "/fixture", { onData() {} }), { exitCode: 0 });
});

await check("shellPath expands a leading tilde the way Pi does and keeps other values", () => {
  assert.equal(expandShellPath(undefined, "/home/u"), undefined);
  assert.equal(expandShellPath("", "/home/u"), undefined);
  assert.equal(expandShellPath(7, "/home/u"), undefined);
  assert.equal(expandShellPath("~", "/home/u"), "/home/u");
  assert.equal(expandShellPath("~/bin/bash", "/home/u", "darwin"), resolve("/home/u", "bin/bash"));
  assert.equal(expandShellPath("~\\bin\\bash", "/home/u", "darwin"), "~\\bin\\bash");
  assert.equal(expandShellPath("~\\bin\\bash", "/home/u", "win32"), resolve("/home/u", "bin\\bash"));
  assert.equal(expandShellPath("/bin/bash", "/home/u"), "/bin/bash");
});

await check("double bang, other modes and unrecognized commands return no result and touch nothing", () => {
  const h = piHarness();
  assert.equal(h.bang("aws sso login --profile dev", true), undefined);
  assert.equal(h.bang("echo hi"), undefined);
  assert.equal(h.bang("aws sso login --profile dev && true"), undefined);
  for (const mode of ["rpc", "json", "print"]) {
    const other = piHarness({ mode });
    assert.equal(other.bang("aws sso login --profile dev"), undefined);
    assert.deepEqual(other.shells, []);
  }
  assert.deepEqual(h.shells, []);
  assert.deepEqual(h.sends, []);
  assert.deepEqual(h.notices, []);
  assert.deepEqual([...h.handlers.keys()].sort(), ["input", "session_shutdown", "user_bash"]);
});

await check("a successful login shows live output, clears it and notifies after Pi's own record", async () => {
  const h = piHarness({ shellPath: "/bin/bash" });
  const { result, piText } = await h.run("aws sso login --profile dev");
  assert.deepEqual(result, { exitCode: 0 });
  assert.equal(piText, WITHHELD_OUTPUT_LINE);
  assert.deepEqual(h.shells, ["/bin/bash"]);
  assert.ok(h.widgets.some((w) => w.key === WIDGET_KEY && Array.isArray(w.lines) && w.lines[0] === LIVE_HEADER
    && w.lines.includes("RAW-CODE-CANARY")));
  assert.deepEqual(h.widgets.at(-1), { key: WIDGET_KEY, lines: undefined });
  assert.equal(h.sends.length, 0, "the notice must wait for the command's own record");
  await tick();
  await tick();
  assert.equal(h.sends.length, 1);
  const [{ message, options }] = h.sends;
  assert.deepEqual(options, { triggerTurn: true, deliverAs: "followUp" });
  assert.equal(message.customType, NOTICE_TYPE);
  assert.equal(message.display, false);
  assert.deepEqual(message.details, { selector: { kind: "profile", name: "dev" } });
  assert.equal(message.content, `ENCODED:${awsSsoLoginNoticeBody({ kind: "profile", name: "dev" })}`);
  assert.doesNotMatch(JSON.stringify(h.sends), /RAW-(URL|CODE)-CANARY/);
  assert.deepEqual(h.notices, [{ text: 'Firstmate was notified that AWS SSO login exited 0 (profile "dev").', level: "info" }]);
});

await check("a parked main receives the notice on its next prompt without a new turn", async () => {
  const h = piHarness({ away: true });
  await h.run("aws sso login --sso-session corp");
  await tick();
  await tick();
  assert.equal(h.sends.length, 1);
  assert.deepEqual(h.sends[0].options, { deliverAs: "nextTurn" });
  assert.deepEqual(h.sends[0].message.details, { selector: { kind: "sso-session", name: "corp" } });
  assert.deepEqual(h.notices, [{
    text: 'AWS SSO login exited 0 (SSO session "corp"). Firstmate gets the notice with the next prompt.',
    level: "info",
  }]);
});

await check("a failed login sends nothing and keeps its output only until the next interactive input", async () => {
  const h = piHarness({ local: fakeLocal({ exitCode: 2 }, [RAW, "Error: RAW-FAILURE-CANARY\n"]) });
  const { piText } = await h.run("aws sso login");
  assert.equal(piText, WITHHELD_OUTPUT_LINE);
  await tick();
  await tick();
  assert.deepEqual(h.sends, []);
  assert.deepEqual(h.notices, []);
  const kept = h.widgets.at(-1);
  assert.equal(kept.lines[0], failedLoginHeader(2));
  assert.equal(kept.lines.at(-1), "Error: RAW-FAILURE-CANARY");
  h.handlers.get("input")({ type: "input", text: "notice", source: "extension" }, h.ctx);
  assert.equal(h.widgets.at(-1), kept, "extension input must not hide the failure output");
  assert.equal(h.bang("aws sso login", true), undefined);
  assert.equal(h.widgets.at(-1), kept, "a double-bang command must not touch the failure output");
  h.handlers.get("input")({ type: "input", text: "hello", source: "interactive" }, h.ctx);
  assert.deepEqual(h.widgets.at(-1), { key: WIDGET_KEY, lines: undefined });
});

await check("the next single-bang command and session shutdown clear kept failure output", async () => {
  const h = piHarness({ local: fakeLocal({ exitCode: 1 }) });
  await h.run("aws sso login");
  assert.equal(h.bang("echo next"), undefined);
  assert.deepEqual(h.widgets.at(-1), { key: WIDGET_KEY, lines: undefined });
  await h.run("aws sso login");
  h.handlers.get("session_shutdown")({ type: "session_shutdown", reason: "quit" }, h.ctx);
  assert.deepEqual(h.widgets.at(-1), { key: WIDGET_KEY, lines: undefined });
});

await check("a cancelled or errored login clears the widget and sends nothing", async () => {
  const controller = new AbortController();
  controller.abort();
  const cancelled = piHarness({ local: fakeLocal(new Error("aborted")) });
  await assert.rejects(cancelled.run("aws sso login", { signal: controller.signal }), /aborted/);
  const errored = piHarness({ local: fakeLocal(new Error("spawn failed")) });
  await assert.rejects(errored.run("aws sso login"), /spawn failed/);
  await tick();
  await tick();
  for (const h of [cancelled, errored]) {
    assert.deepEqual(h.sends, []);
    assert.deepEqual(h.widgets.at(-1), { key: WIDGET_KEY, lines: undefined });
  }
});

await check("an encoder failure tells the user instead of sending an untyped notice", async () => {
  const h = piHarness({ encode: async () => { throw new Error("encoder unavailable"); } });
  await h.run("aws sso login --profile dev");
  await tick();
  await tick();
  assert.deepEqual(h.sends, []);
  assert.equal(h.notices.length, 1);
  assert.equal(h.notices[0].level, "warning");
  assert.match(h.notices[0].text, /could not be notified: encoder unavailable/);
});

await check("a shell backend that cannot start blocks the recognized command", () => {
  const handlers = new Map<string, any>();
  registerAwsSsoLoginNotice({
    on: (name: string, fn: any) => handlers.set(name, fn),
    getSettings: () => ({ shellPath: "/missing/bash" }),
    sendMessage() {},
  } as any, {
    createLocalShell() { throw new Error("Custom shell path not found: /missing/bash"); },
    encodeNotice: async (body: string) => body,
    awayPostureActive: () => false,
  });
  assert.throws(
    () => handlers.get("user_bash")({ type: "user_bash", command: "aws sso login", excludeFromContext: false, cwd: "/" }, { mode: "tui", ui: { setWidget() {}, notify() {} } }),
    /Custom shell path not found/,
  );
});

await check("the real encoder types the notice as an aws-sso-login operational input", async () => {
  const body = awsSsoLoginNoticeBody({ kind: "profile", name: "dev" });
  const encoded = await operational.encodeFirstmateOperationalInputWith(runCommandAsync, "aws-sso-login", body);
  assert.equal(encoded, `⁣FIRSTMATE_OP: v1 aws-sso-login: ${body}`);
  assert.equal(operational.classifyFirstmateCurrentOperationalText(encoded)?.trim(), "aws-sso-login");
});
TS
); then
  printf '%s\n' "$results" >&2
  fail 'AWS SSO login notice assertions failed'
fi
while IFS=$'\t' read -r result name; do
  case "$result" in
    pass) pass "$name" ;;
    *) fail "unexpected AWS SSO login notice result: $result $name" ;;
  esac
done <<< "$results"

# The entrypoint imports Pi's own shell backend, so its worker gate needs the
# installed Pi package. Copies keep the worktree free of a node_modules link.
PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-"$(npm root -g 2>/dev/null)/@earendil-works/pi-coding-agent"}
if [ ! -d "$PI_PACKAGE_DIR" ]; then
  echo "skip: installed @earendil-works/pi-coding-agent package not found; entrypoint worker gate not run"
  exit 0
fi
TMP_ROOT=$(fm_test_tmproot fm-pi-aws-sso-login)
mkdir -p "$TMP_ROOT/.pi/extensions/lib" "$TMP_ROOT/node_modules/@earendil-works"
cp "$ROOT/.pi/extensions/fm-aws-sso-login.ts" "$TMP_ROOT/.pi/extensions/"
for lib in fm-aws-sso-login.ts fm-async-exec.ts fm-branch-dispatch.ts fm-operational-input.ts; do
  cp "$ROOT/.pi/extensions/lib/$lib" "$TMP_ROOT/.pi/extensions/lib/"
done
ln -s "$PI_PACKAGE_DIR" "$TMP_ROOT/node_modules/@earendil-works/pi-coding-agent"
gate=$(NODE_NO_WARNINGS=1 FM_SSO_FIXTURE="$TMP_ROOT" node --input-type=module-typescript <<'TS'
const { default: register } = await import(`${process.env.FM_SSO_FIXTURE}/.pi/extensions/fm-aws-sso-login.ts`);
const count = (env: Record<string, string>) => {
  const saved = { FM_TASK_ID: process.env.FM_TASK_ID, FM_TASK_INBOX: process.env.FM_TASK_INBOX };
  delete process.env.FM_TASK_ID;
  delete process.env.FM_TASK_INBOX;
  Object.assign(process.env, env);
  const names: string[] = [];
  register({ on: (name: string) => names.push(name) } as any);
  for (const [key, value] of Object.entries(saved)) {
    if (value === undefined) delete process.env[key];
    else process.env[key] = value;
  }
  return names.sort().join(",");
};
console.log([count({}), count({ FM_TASK_ID: "t1" }), count({ FM_TASK_INBOX: "/inbox" })].join("|"));
TS
) || fail "the AWS SSO login entrypoint could not load against the installed Pi package"
[ "$gate" = "input,session_shutdown,user_bash||" ] \
  || fail "the entrypoint must register for Firstmate sessions and stay inert in task workers, got: $gate"
pass "the entrypoint registers in a Firstmate session and stays inert in task workers"
