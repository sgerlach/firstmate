# Verification: Claude Desktop claude:// links

Active empirical evidence for the link forms that `bin/fm-desktop-handoff.sh` uses to open Claude Desktop.
The script's header owns the operating contract, and [configuration.md](../configuration.md#claude-desktop-hand-off-binfm-desktop-handoffsh) owns the operator description; this record owns how the link facts were established and what is still unproven.

## Subject

| Field | Value |
|---|---|
| App | `/Applications/Claude.app`, `CFBundleShortVersionString` `2.26454.2`, bundle id `com.anthropic.claudefordesktop` |
| Verified | 2026-10-08 |
| Platform | macOS arm64 (Darwin 25.5.0) |

## Bundle evidence

The app registers the scheme in its `Info.plist`:

```
$ plutil -p /Applications/Claude.app/Contents/Info.plist
  "CFBundleURLTypes" => [
    0 => {
      "CFBundleURLName" => "Claude"
      "CFBundleURLSchemes" => [
        0 => "claude"
      ]
    }
```

The JavaScript in `Contents/Resources/app.asar` was extracted read-only into a scratch directory.
The link handler is the function the app logs as `claudeURLHandler`, reached from `app.on("open-url")` in `.vite/build/index.chunk-D86SM5R2.js`.
These excerpts are the routes the hand-off depends on:

```
case Uu.Cowork:{ ... if(a.pathname!=="/new")return N.warn("claudeURLHandler: unrecognized cowork path",...);
  let e=a.searchParams.get("q")?.slice(0,tj),o=r?.argvCapped?[]:a.searchParams.getAll("folder"), ...
  ... u=l?`/task/new?${l}`:"/task/new"; ... mR(u,t,i),!0}
case Uu.Code:{ ... if(a.pathname!=="/new")return N.warn("claudeURLHandler: unrecognized code path",...);
  let s=(a.searchParams.get("q")??a.searchParams.get("prompt"))?.slice(0,tj),c=a.searchParams.getAll("folder"), ...
function hwn(e,t){let n=new URL("/new",wO());return e&&n.searchParams.set("q",e.slice(0,tj)), ...
tj=14336
```

The facts that follow from the bundle:

- `claude://cowork/new?q=<prompt>&folder=<absolute path>` opens a new Cowork task with the prompt and the folder.
- `claude://code/new?q=<prompt>&folder=<path>` opens a new Code session in the folder; `prompt=` is an alias for `q=`.
- `claude://claude.ai/new?q=<prompt>` opens a new chat with the prompt.
- Each form cuts the prompt to 14336 UTF-16 code units without a warning, so the script compares the prompt's byte count, which is never smaller, against that limit.
- `argvCapped`, which drops `folder` and `file`, is set only for a link passed in the process arguments at launch; macOS delivers links through `open-url`, where it is never set.
- The enterprise setting `authentication.disableDeepLinks` drops all three forms.

## Live link tests

Each test ran `open '<link>'` with a short prompt such as `firstmate link test - do not act` and then read the new lines of `~/Library/Logs/Claude/main.log`.
The screen was locked, so the visible window was not observed; the log was the observation channel.

| Link | Link length | `open` exit | New log lines |
|---|---|---|---|
| `claude://cowork/firstmate-link-test-invalid` (control) | 43 | 0 | `[warn] claudeURLHandler: unrecognized cowork path { pathname: '/firstmate-link-test-invalid' }` |
| `claude://cowork/new?q=...&folder=...` (two-line prompt) | 181 | 0 | no warning; `setDraftSessionFolders: setting 0 folders for draft session`; `LocalAgentModeSessions.isFolderTrusted: <folder> -> false` |
| `claude://code/new?q=...&folder=...` | 163 | 0 | no warning; `[CCD] LocalSessions.setFocusedSession: sessionId=null` |
| `claude://claude.ai/new?q=...` | 74 | 0 | no warning; `[CCD] LocalSessions.setFocusedSession: sessionId=null` |
| `claude://cowork/new?q=...&folder=...` (15008-byte prompt) | 22214 | 0 | no warning; the same draft-session and folder-trust lines as the short Cowork link |

The control proves that the handler logs a rejected link, so the absence of a warning means the handler accepted the other four.
The Cowork lines show a draft session that was not submitted, and a trust check on the attached folder that an unseen folder fails, so the user trusts it once.
`open` delivered a 22214-character link intact.

## Not yet proven

- The visible composer with the prefilled prompt and the folder-trust prompt were not seen, because the screen was locked during the tests.
- The tests covered a running app only; a link that starts the app goes through the same `open-url` path in the bundle, but was not run.

## Refresh

After a Claude Desktop update, repeat the bundle search and the control plus Cowork link tests above, and update this record with the new version and output.
