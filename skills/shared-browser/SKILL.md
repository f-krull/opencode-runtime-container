---
name: shared-browser
description: |
  Drives this project's Chromium (headless by default; `browser.sh login` exposes the same profile headful for human handoffs) through `browser-cli` over CDP.
  MUST be used whenever the user says "open the browser", "test the page", "take a screenshot", "do the login flow", "check the dev site", or asks to navigate, debug, automate, or inspect any web page or cookie-gated URL.
  ALWAYS use it for OIDC/Dataporten/2FA login handoffs and when delegating snapshot-heavy page work to the `browser` subagent.
license: MIT
compatibility: opencode
metadata:
  author: fkrull
  version: 3.0.0
  category: dev-environment
  tags: [browser, playwright, cdp, login, screenshots, testing]
---

## What I do
- Drive this project's Chromium via the `browser-cli` command: navigate, click, type, inspect DOM/console, take screenshots
- Manage its lifecycle via `browser.sh` (start/stop/status/login/headless/list/stop-all)
- Perform human-in-the-loop login handoffs (OIDC, Dataporten, 2FA) by temporarily showing the same profile headful
- Delegate snapshot-heavy or long-running page work to the `browser` subagent to protect the main context

## When to use me (Triggers)
- "open the browser", "open the dev site", "go to localhost:3046"
- "test the login flow", "do the OIDC login", "check the redirect"
- "take a screenshot of ...", "debug the page", "why is this page failing"
- "click through the pages", "verify the cookies", "check what the page shows"
- Any task mentioning `browser.sh`, `browser-cli`, CDP, or `browser-profile`

## When NOT to use me
- Static content or API checks where `curl`/`webfetch` suffices
- Writing frontend code (only use me if an actual browser check is requested)
- Cloud browsers or other people's remote browsers
- General web research where a plain fetch delivers the answer

## Instructions (Step-by-step)

### 0. Know the setup
- **One browser per project.** Each project gets its own container, Chromium profile (keyed by the sha256 of the project path, under `browser-profile/`), CDP endpoint and CLI tab state. Different projects can run in parallel; only serialize work within the same project.
- **Headless by default.** Agent work never maps a window on the human's desktop, so it cannot steal focus.
- **Human handoff:** `browser.sh login` restarts the same profile headful on the host display; `browser.sh headless` hides it again. Chromium's session restore keeps open tabs and session cookies across these switches; always use `browser.sh` to stop/switch so it closes via CDP and flushes state.
- Paths:
  - `TOOLING="${OPENCODE_TOOLING_DIR:-/home/fkrull/workspace/opencode}"`
  - `CLI="${TOOLING}/browser-cli/browser-cli.mjs"` (executable)
  - Lifecycle: `"${TOOLING}/browser.sh" {start,stop,restart,status,login,headless,list,stop-all,build}`
- CDP endpoint is written to `browser-profile/<project-key>/.cdp-endpoint`; `browser-cli` finds it automatically from the current project.
- Screenshots are files: inspect them with the read tool (vision) and give the path to the human.

### 1. Ensure the browser is running
`browser.sh status`; if not running → `browser.sh start` (headless). The CLI prints the same hint when it cannot connect.

### 2. Command surface

```
browser-cli.mjs goto <url> [--capture]      # --capture prints load errors/warnings
browser-cli.mjs wait --text "..."           # blocking; also --selector, --url-prefix, --url-regex
browser-cli.mjs scroll [--by N] | --to top|bottom|<selector>
browser-cli.mjs status
browser-cli.mjs snapshot [--selector S]     # accessibility tree (default: body)
browser-cli.mjs text [--selector S]
browser-cli.mjs eval "<js-expression>"      # print JSON; use an async IIFE for statements
browser-cli.mjs cookies [--name N] [--json] [--full]
browser-cli.mjs click <selector>            # also dblclick, hover, check, uncheck
browser-cli.mjs fill <selector> <value>     # also select, press
browser-cli.mjs tabs list|new|select|close
browser-cli.mjs shot <path> [--selector S] [--full] [--jpeg]
```

Selectors: CSS, `text=...`, `role=button[name="Login"]`; other Playwright engines pass through.

Lifecycle commands:

```
browser.sh start       # headless; leaves an already-running mode alone
browser.sh login       # relaunch same profile headful on BROWSER_DISPLAY
browser.sh headless    # relaunch same profile without a window
browser.sh stop        # saves open tabs, then stops
browser.sh status      # project/instance/mode/endpoint
browser.sh list        # all project instances
browser.sh stop-all    # stop every project instance
```

### 3. Choose the execution mode
- **Default — delegate to the `browser` subagent**: any page interaction (navigation, clicking, filling, recon, verification, screenshots) goes through the task tool with `subagent_type: browser`, using the prompt template in `./references/protocols.md`. The subagent's separate context keeps snapshots, DOM dumps, console logs, and multi-step noise out of the main session.
- **Direct CLI in the main context is an exception**, allowed only for:
  - lifecycle/status checks (`browser.sh status`, `browser-cli.mjs status`),
  - the interactive login handoff (step 4), because it keeps you in sync with the human,
  - a single quick fact when the subagent is unavailable.
- When a delegated task pauses with `WAITING_FOR_HUMAN_LOGIN`, relay it to the human, perform the headful switch (step 4), and after login resume the SAME subagent session via its returned `task_id`.
- Serialize browser work **within one project**. Different projects have independent instances and may run concurrently.

### 4. Login handoff (CRITICAL)
When credentials or 2FA are needed:
1. `browser-cli.mjs goto <login-url>`, then `snapshot` to confirm the provider page loaded.
2. Show the browser: `browser.sh login`. This relaunches the same profile headful and reopens the saved tabs; confirm with `browser-cli.mjs status` (mode must be `headful`).
3. STOP acting and tell the human: "Please complete the login in the browser window."
4. Wait with one blocking call (works for the human's pace):
   `browser-cli.mjs wait --url-prefix <post-login-url> --timeout 300000`
5. Verify success via URL **and** expected cookie (e.g. `cookies --name tsd_id_token`).
6. Hide it again: `browser.sh headless` (same profile/tabs), then continue.
7. Only then resume the task. Full checklist: `./references/protocols.md`.

Never start the headful window and then keep driving the page while the human is supposed to interact. If `browser.sh login` fails because no X display is available, report that instead of pretending the handoff happened.

### 5. Verify with evidence, not vibes
- Prefer: `eval` (URL, title, cookies, DOM state), `snapshot`, `text`, `goto --capture` for console errors.
- Screenshots: save to a file (e.g. `.browser/<name>.png`) for the human, and inspect it with the read tool (vision) — useful for layout, dialogs, and rendering issues. Use `--selector` or `--jpeg` for cheaper images.
- Keep reports short: what was checked, result, artifacts.

### 6. Leave clean state
- Report final URL, mode and title. Do not close the window or stop the browser unless asked.
- Leave the browser in headless mode after a login handoff unless the human says they still need the window.

## Rules & Constraints (CRITICAL)
- You MUST NEVER type credentials, OTP/2FA codes, or attempt CAPTCHAs — ALWAYS hand off to the human.
- You MUST NEVER close the browser, stop the container, clear cookies/storage/profile, or restart the browser while the human may be using it — ask first.
- You MUST NEVER start a second Chromium against the same project profile (SingletonLock), and NEVER run parallel browser drivers for the same project.
- Different projects may run browser work in parallel; their profiles, tabs and CDP endpoints are isolated.
- You MUST keep every CDP endpoint unexposed; never forward or publish it beyond localhost.
- You MUST use `browser.sh login` only for human handoffs and switch back with `browser.sh headless` afterwards.
- You MUST stop/restart via `browser.sh stop|restart|login|headless`; raw `podman stop` can lose recently set cookies/session state.
- You MUST serialize with the human: if they are interacting with the headful window, wait until they confirm before acting.
- You MUST delegate page interactions (navigation, clicks, forms, recon, screenshots) to the `browser` subagent by default; direct `browser-cli` runs in the main context are limited to status/lifecycle checks, the login handoff, or when the subagent is unavailable.
- You MUST verify post-login state (URL + expected cookie) before continuing any authenticated flow.
- You MUST prefer blocking `wait` over sleep loops when waiting for the human or the page.
- Cookie banners: ALWAYS accept them ("Godta", "Godta alle", "Accept all", "OK") so they never block testing — we always accept cookies in this environment. Do it without asking.

## Examples

### Example 1: lifecycle check (allowed direct)
User: "Is the browser up?"
Agent: `browser.sh status` (plus `browser-cli.mjs status` for page info). No page interaction → no delegation needed.

### Example 2: delegate recon
User: "Click through all internal pages and report what's on them."
Agent: task tool with `subagent_type: browser`, prompt built from `./references/protocols.md` → concise report; full snapshots never enter the main context.

### Example 3: login handoff (the allowed direct exception)
Agent (direct): `goto http://localhost:3046/login` → snapshot shows the Dataporten page → `browser.sh login` → "Please complete the login in the browser window." → `wait --url-prefix http://localhost:3046/internal --timeout 300000` → `cookies --name tsd_id_token` confirms → `browser.sh headless` → delegate the authenticated checks to the `browser` subagent.

### Example 4: two projects at once
Two OpenCode sessions in different directories each run `browser.sh start`; they get separate containers/profiles/endpoints. Work can proceed concurrently without tabs or cookies colliding.

## Error Handling & Edge Cases
- **CLI cannot connect / no endpoint** → `browser.sh status`; if not running: `browser.sh start`; still failing: `podman logs dev-browser-<key>`.
- **The CDP endpoint changes after a mode switch or restart** → expected; `browser-cli` reads the per-project endpoint file on every invocation. Do not cache the URL.
- **SingletonLock / profile lock error** → another Chromium is using this project's profile; check `browser.sh status` and `browser.sh list`. Never delete the lock while a Chromium is alive.
- **No window during normal work** → correct: the default mode is headless. Use `browser.sh login` for a human handoff.
- **`login` fails: X display unavailable** → headless mode still works; fix `BROWSER_DISPLAY`/desktop session before retrying. Do not claim the human can see the page.
- **`wait` times out (exit 1)** → check the current state (`status`, `snapshot`); increase `--timeout` for human-paced steps; never fake success.
- **favicon 404 / localStorage warnings** → normal noise; ignore.
- **Login redirect loops / "unregistered redirect_uri"** → dev-service or OIDC config issue, not a browser problem; check nginx `:3046` and auth `:3047`.
- **Provider rejects headless / needs client certificate** → do that flow in `browser.sh login` (headful) and report the limitation; do not keep retrying headless.
- **Human logged in elsewhere** → cookies live in their personal browser, not this project's profile; ask them to use the headful handoff.

## References & Resources
- `./references/protocols.md` — subagent prompt template, report format, login-handoff checklist
- Tooling repo: `${OPENCODE_TOOLING_DIR:-/home/fkrull/workspace/opencode}/` (`browser.sh`, `browser-cli/`, `browser/Dockerfile`, AGENTS.md → "Shared Browser")
- CLI help: `browser-cli.mjs help`
