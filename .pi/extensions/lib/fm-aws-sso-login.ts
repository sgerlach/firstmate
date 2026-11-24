// The Pi single-bang AWS SSO login notice: recognition, output withholding,
// the live widget and the notice to Firstmate. ../fm-aws-sso-login.ts supplies
// Pi's shell backend, the operational-input encoder and the away-posture check;
// docs/configuration.md "Pi single-bang AWS SSO login notice" owns the operator
// contract. Only type imports come from Pi, so tests run this without a Pi install.
import { homedir } from "node:os";
import { resolve } from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

export type AwsSsoSelector =
  | { kind: "profile"; name: string }
  | { kind: "sso-session"; name: string }
  | { kind: "none" };

// The whole command exactly as Pi passes it after the single "!" prefix. Only
// the bare login and one named selector match. Any other flag, a second
// selector, an environment prefix, a path-qualified `aws`, quoting, expansion,
// redirection, a pipeline or a newline leaves the command unrecognized, and
// an unrecognized command runs exactly as it does without this extension.
const SELECTOR_NAME = "[A-Za-z0-9_][A-Za-z0-9._@+-]{0,63}";
const GAP = "[ \\t]+";
const LOGIN_COMMAND = new RegExp(
  `^aws${GAP}sso${GAP}login(?:${GAP}(--profile|--sso-session)(?:=|${GAP})(${SELECTOR_NAME}))?$`,
);

export function recognizeAwsSsoLogin(command: unknown): AwsSsoSelector | undefined {
  if (typeof command !== "string") return undefined;
  const match = LOGIN_COMMAND.exec(command);
  if (!match) return undefined;
  const [, flag, name] = match;
  if (flag === undefined || name === undefined) return { kind: "none" };
  return flag === "--profile" ? { kind: "profile", name } : { kind: "sso-session", name };
}

// The selector as the user typed it. "none" never names a profile: the AWS
// CLI resolves its own default, and this module does not guess which one.
export function describeAwsSsoSelector(selector: AwsSsoSelector): string {
  switch (selector.kind) {
    case "profile":
      return `profile "${selector.name}"`;
    case "sso-session":
      return `SSO session "${selector.name}"`;
    case "none":
      return "no --profile or --sso-session selector";
  }
}

// The body of the aws-sso-login operational input Firstmate receives after a
// recognized login exits 0. It carries the selector and nothing from the output.
export function awsSsoLoginNoticeBody(selector: AwsSsoSelector): string {
  return [
    `AWS SSO login notice: a user-entered single-bang \`aws sso login\` in this Pi session exited 0 (${describeAwsSsoSelector(selector)}).`,
    "Pi kept its raw output, browser URL and login code out of model context.",
    "Exit 0 is not proof that any dependency works, and this notice grants no new authority.",
    "If work was blocked on AWS SSO, re-verify that specific dependency with its own check before you treat it as fixed.",
  ].join("\n");
}

// The only text Pi records, and so the only text the model sees, as the output
// of a recognized login.
export const WITHHELD_OUTPUT_LINE =
  "Firstmate withheld this AWS SSO login output from model context; it shows live above the editor.";

export const LIVE_HEADER = "AWS SSO login output (live, kept out of model context):";

export function failedLoginHeader(exitCode: number | null): string {
  const result = exitCode === null ? "ended without an exit code" : `exited ${exitCode}`;
  return `AWS SSO login ${result}. Its output stays here, out of model context, until the next input:`;
}

// Pi draws at most ten lines of a string widget and keeps the first ten, so
// the header plus this many output lines keeps the newest output visible.
export const LIVE_TAIL_LINES = 9;
const MAX_KEPT_LINES = 200;
const MAX_LINE_CHARS = 2000;
const MAX_PARTIAL_CHARS = MAX_LINE_CHARS * 4;
const ANSI_SEQUENCE = /\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1b]*(?:\x07|\x1b\\)|[@-Z\\-_])/g;
const CONTROL_CHARACTERS = /[\x00-\x08\x0b-\x1f\x7f-\x9f]/g;

// One output line as a terminal would leave it: a carriage return overwrites
// the line, and escape sequences and control characters never reach the TUI.
export function displayLine(raw: string): string {
  const withoutLineEnd = raw.replace(/\r+$/, "");
  const visible = withoutLineEnd.slice(withoutLineEnd.lastIndexOf("\r") + 1);
  return visible
    .replace(ANSI_SEQUENCE, "")
    .replace(CONTROL_CHARACTERS, "")
    .replace(/\t/g, "  ")
    .slice(0, MAX_LINE_CHARS);
}

// The raw login output, held only in memory for the live widget and bounded.
export class LiveOutput {
  private readonly decoder = new TextDecoder();
  private lines: readonly string[] = [];
  private partial = "";

  push(chunk: Uint8Array): void {
    const parts = (this.partial + this.decoder.decode(chunk, { stream: true })).split("\n");
    const rest = parts[parts.length - 1] ?? "";
    this.partial = rest.length > MAX_PARTIAL_CHARS ? rest.slice(-MAX_PARTIAL_CHARS) : rest;
    this.lines = [...this.lines, ...parts.slice(0, -1).map(displayLine)].slice(-MAX_KEPT_LINES);
  }

  tail(count: number): string[] {
    const current = this.partial ? [displayLine(this.partial)] : [];
    return [...this.lines, ...current].filter((line) => line.trim() !== "").slice(-count);
  }
}

export function liveWidgetLines(header: string, live: LiveOutput): string[] {
  return [header, ...live.tail(LIVE_TAIL_LINES)];
}

// The structural subset of Pi's BashOperations this module needs.
export interface ShellOperations {
  exec(
    command: string,
    cwd: string,
    options: {
      onData: (data: Buffer) => void;
      signal?: AbortSignal;
      timeout?: number;
      env?: NodeJS.ProcessEnv;
    },
  ): Promise<{ exitCode: number | null }>;
}

export type AwsSsoLoginOutcome =
  | { kind: "succeeded" }
  | { kind: "failed"; exitCode: number | null }
  | { kind: "cancelled" }
  | { kind: "errored"; message: string };

export interface WithheldLoginHooks {
  onLive(live: LiveOutput): void;
  onOutcome(outcome: AwsSsoLoginOutcome, live: LiveOutput): void;
}

function callHook(hook: () => void): void {
  try {
    hook();
  } catch {
    // A display or notice failure must not change the command's own result.
  }
}

// Runs the login through `local` and gives Pi only WITHHELD_OUTPUT_LINE. The
// raw output goes to the live widget hooks; Pi's result, exit code and
// cancellation stay exactly those of `local`.
export function withheldLoginOperations(local: ShellOperations, hooks: WithheldLoginHooks): ShellOperations {
  return {
    async exec(command, cwd, options) {
      const live = new LiveOutput();
      options.onData(Buffer.from(WITHHELD_OUTPUT_LINE));
      const onData = (data: Buffer): void => {
        live.push(data);
        callHook(() => hooks.onLive(live));
      };
      try {
        const result = await local.exec(command, cwd, { ...options, onData });
        const outcome: AwsSsoLoginOutcome =
          result.exitCode === 0 && !options.signal?.aborted
            ? { kind: "succeeded" }
            : { kind: "failed", exitCode: result.exitCode };
        callHook(() => hooks.onOutcome(outcome, live));
        return result;
      } catch (error) {
        const outcome: AwsSsoLoginOutcome = options.signal?.aborted
          ? { kind: "cancelled" }
          : { kind: "errored", message: error instanceof Error ? error.message : String(error) };
        callHook(() => hooks.onOutcome(outcome, live));
        throw error;
      }
    },
  };
}

// Pi expands a leading "~" in its shellPath setting before it starts a
// single-bang command, and pi.getSettings() returns the setting unexpanded.
export function expandShellPath(
  value: unknown,
  home: string = homedir(),
  platform: NodeJS.Platform = process.platform,
): string | undefined {
  if (typeof value !== "string" || value === "") return undefined;
  if (value === "~") return home;
  if (value.startsWith("~/") || (platform === "win32" && value.startsWith("~\\"))) {
    return resolve(home, value.slice(2));
  }
  return value;
}

export const WIDGET_KEY = "fm-aws-sso-login";
export const NOTICE_TYPE = "fm-aws-sso-login";

export interface AwsSsoLoginNoticeDeps {
  // Pi's own local shell backend for the given shellPath setting.
  createLocalShell(shellPath: string | undefined): ShellOperations;
  // The aws-sso-login operational input that carries `body`.
  encodeNotice(body: string): Promise<string>;
  // True while the away-posture record parks main.
  awayPostureActive(): boolean;
}

export function registerAwsSsoLoginNotice(pi: ExtensionAPI, deps: AwsSsoLoginNoticeDeps): void {
  let widgetContext: ExtensionContext | undefined;

  function showWidget(ctx: ExtensionContext, header: string, color: "muted" | "warning", live: LiveOutput): void {
    let styledHeader = header;
    try {
      styledHeader = ctx.ui.theme.fg(color, header);
    } catch {
      // Without a theme the header stays plain text.
    }
    widgetContext = ctx;
    ctx.ui.setWidget(WIDGET_KEY, liveWidgetLines(styledHeader, live));
  }

  function clearWidget(): void {
    const ctx = widgetContext;
    widgetContext = undefined;
    try {
      ctx?.ui.setWidget(WIDGET_KEY, undefined);
    } catch {
      // A replaced session already dropped its widgets.
    }
  }

  async function notifyFirstmate(ctx: ExtensionContext, selector: AwsSsoSelector): Promise<void> {
    const described = describeAwsSsoSelector(selector);
    try {
      const content = await deps.encodeNotice(awsSsoLoginNoticeBody(selector));
      const message = { customType: NOTICE_TYPE, content, display: false, details: { selector } };
      // A parked main opens no turn; the notice rides the next prompt instead.
      if (deps.awayPostureActive()) {
        pi.sendMessage(message, { deliverAs: "nextTurn" });
        ctx.ui.notify(`AWS SSO login exited 0 (${described}). Firstmate gets the notice with the next prompt.`, "info");
      } else {
        pi.sendMessage(message, { triggerTurn: true, deliverAs: "followUp" });
        ctx.ui.notify(`Firstmate was notified that AWS SSO login exited 0 (${described}).`, "info");
      }
    } catch (error) {
      const reason = error instanceof Error ? error.message : String(error);
      callHook(() =>
        ctx.ui.notify(
          `AWS SSO login exited 0 (${described}), but Firstmate could not be notified: ${reason}. Tell Firstmate directly.`,
          "warning",
        ),
      );
    }
  }

  function finishLogin(
    ctx: ExtensionContext,
    selector: AwsSsoSelector,
    outcome: AwsSsoLoginOutcome,
    live: LiveOutput,
  ): void {
    if (outcome.kind === "failed") {
      showWidget(ctx, failedLoginHeader(outcome.exitCode), "warning", live);
      return;
    }
    clearWidget();
    // Pi appends the command's own record after exec resolves; deliver after it.
    if (outcome.kind === "succeeded") setTimeout(() => void notifyFirstmate(ctx, selector), 0);
  }

  pi.on("user_bash", (event, ctx) => {
    if (event.excludeFromContext) return undefined;
    if (ctx.mode !== "tui") return undefined;
    clearWidget();
    const selector = recognizeAwsSsoLogin(event.command);
    if (!selector) return undefined;
    // From here a throw blocks the command rather than letting its raw output
    // reach model context through Pi's default single-bang path.
    const local = deps.createLocalShell(expandShellPath(pi.getSettings().shellPath));
    return {
      operations: withheldLoginOperations(local, {
        onLive: (live) => showWidget(ctx, LIVE_HEADER, "muted", live),
        onOutcome: (outcome, live) => finishLogin(ctx, selector, outcome, live),
      }),
    };
  });

  pi.on("input", (event) => {
    if (event.source === "interactive") clearWidget();
  });

  pi.on("session_shutdown", () => clearWidget());
}
