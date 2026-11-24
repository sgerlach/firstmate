// Firstmate notice for Pi's interactive single-bang AWS SSO login.
//
// A recognized `!aws sso login` runs through Pi's own local shell backend, but
// Pi records only a fixed withheld-output line, so the raw output, browser URL
// and login code never reach model context, compaction or branch summaries.
// The raw output is shown live in a widget above the editor and is never
// written to the session. After exit 0, Firstmate receives an aws-sso-login
// operational input that carries only the typed selector. A failed, cancelled
// or errored login sends nothing. `!!`, unrecognized commands, non-interactive
// modes, task workers and model tool calls are untouched.
// lib/fm-aws-sso-login.ts owns the behavior; docs/configuration.md "Pi
// single-bang AWS SSO login notice" owns the operator contract.
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createLocalBashOperations, type ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { runCommandAsync } from "./lib/fm-async-exec.ts";
import { registerAwsSsoLoginNotice } from "./lib/fm-aws-sso-login.ts";
import { afkPostureRecordPresent } from "./lib/fm-branch-dispatch.ts";
import { encodeFirstmateOperationalInputWith } from "./lib/fm-operational-input.ts";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const state = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;

export default function (pi: ExtensionAPI): void {
  // A task worker is not Firstmate; its single-bang commands keep stock Pi behavior.
  if (process.env.FM_TASK_ID || process.env.FM_TASK_INBOX) return;
  registerAwsSsoLoginNotice(pi, {
    createLocalShell: (shellPath) => createLocalBashOperations({ shellPath }),
    encodeNotice: (body) => encodeFirstmateOperationalInputWith(runCommandAsync, "aws-sso-login", body),
    awayPostureActive: () => afkPostureRecordPresent(state),
  });
}
