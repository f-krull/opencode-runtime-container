---
name: shared-browser
description: |
  Drives the shared Chromium (native window for the human + `browser-cli` over CDP for agents) used for web development and testing.
  MUST be used whenever the user says "open the browser", "test the page", "take a screenshot", "do the login flow", "check the dev site", or asks to navigate, debug, automate, or inspect any web page or cookie-gated URL.
  ALWAYS use it for OIDC/Dataporten/2FA login handoffs and when delegating snapshot-heavy page work to the `browser` subagent.
license: MIT
compatibility: opencode
metadata:
  author: fkrull
  version: 2.2.0
  category: dev-environment
  tags: [browser, playwright, cdp, login, screenshots, testing]
---

## What I do
- Drive the shared Chromium via the `browser-cli` command: navigate, click, type, inspect DOM/console, take screenshots
- Manage its lifecycle via `browser.sh` (start/stop/status/restart/build)
- Perform human-in-the-loop login handoffs (OIDC, Dataporten, 2FA)
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
- Shared browser = detached podman container `dev-browser`; Chromium runs with a native window on the host display (`:0`). The human sees and uses the exact same window.
- Agent control: `/home/fkrull/workspace/opencode-podman/browser-cli/browser-cli.mjs` (executable). Connects to CDP at `http://127.0.0.1:9222` (override with `BROWSER_CDP_ENDPOINT`).
- Lifecycle: `/home/fkrull/workspace/opencode-podman/browser.sh {start,stop,restart,status,build}`.
- Persistent profile: `opencode-podman/browser-profile/` — logins survive restarts. Exactly one Chromium per profile.
- Screenshots are files: inspect them with the read tool (vision) and give the path to the human.

### 1. Ensure the browser is running
`browser.sh status`; if not running → `browser.sh start`. The CLI prints the same hint when it cannot connect.

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

### 3. Choose the execution mode
- **Default — delegate to the `browser` subagent**: any page interaction (navigation, clicking, filling, recon, verification, screenshots) goes through the task tool with `subagent_type: browser`, using the prompt template in `./references/protocols.md`. The subagent's separate context keeps snapshots, DOM dumps, console logs, and multi-step noise out of the main session.
- **Direct CLI in the main context is an exception**, allowed only for:
  - lifecycle/status checks (`browser.sh status`, `browser-cli.mjs status`),
  - the interactive login handoff (step 4), because it keeps you in sync with the human,
  - a single quick fact when the subagent is unavailable.
- When a delegated task pauses with `WAITING_FOR_HUMAN_LOGIN`, relay it to the human, and after they confirm, resume the SAME subagent session via its returned `task_id`.
- NEVER run more than one browser driver at a time (main agent or subagents). Serialize all browser work.

### 4. Login handoff (CRITICAL)
When credentials or 2FA are needed:
1. `browser-cli.mjs goto <login-url>`, then `snapshot` to confirm the provider page loaded.
2. STOP acting and tell the human: "Please complete the login in the shared browser window."
3. Wait with one blocking call (works for the human's pace):
   `browser-cli.mjs wait --url-prefix <post-login-url> --timeout 300000`
4. Verify success via URL **and** expected cookie (e.g. `cookies --name tsd_id_token`).
5. Only then resume the task. Full checklist: `./references/protocols.md`.

### 5. Verify with evidence, not vibes
- Prefer: `eval` (URL, title, cookies, DOM state), `snapshot`, `text`, `goto --capture` for console errors.
- Screenshots: save to a file (e.g. `.browser/<name>.png`) for the human, and inspect it with the read tool (vision) — useful for layout, dialogs, and rendering issues. Use `--selector` or `--jpeg` for cheaper images.
- Keep reports short: what was checked, result, artifacts.

### 6. Leave clean state
- Report final URL + title. Do not close the window or stop the browser unless asked.

## Rules & Constraints (CRITICAL)
- You MUST NEVER type credentials, OTP/2FA codes, or attempt CAPTCHAs — ALWAYS hand off to the human.
- You MUST NEVER close the browser, stop the container, clear cookies/storage/profile, or restart the browser while the human may be using it — ask first.
- You MUST NEVER start a second Chromium against `browser-profile/` (SingletonLock), and NEVER run parallel browser subagents.
- You MUST keep the CDP endpoint unexposed; never forward or publish `9222` beyond localhost.
- You MUST serialize with the human: if they are interacting with the window, wait until they confirm before acting.
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
Agent (direct): `goto http://localhost:3046/login` → snapshot shows the Dataporten page → "Please complete the login in the shared browser window." → `wait --url-prefix http://localhost:3046/internal --timeout 300000` → `cookies --name tsd_id_token` confirms → delegate the authenticated checks to the `browser` subagent.

## Error Handling & Edge Cases
- **CLI cannot connect** → `browser.sh status`; if the container is gone: `browser.sh start`; still failing: `podman logs dev-browser`.
- **SingletonLock / profile lock error** → another instance is running; check `browser.sh status`. Never delete the lock while a Chromium is alive.
- **No window on the human's screen** → wrong display or no desktop session; check `ls /tmp/.X11-unix` and `BROWSER_DISPLAY` (restart via browser.sh with override).
- **`wait` times out (exit 1)** → check the current state (`status`, `snapshot`); increase `--timeout` for human-paced steps; never fake success.
- **favicon 404 / localStorage warnings** → normal noise; ignore.
- **Login redirect loops / "unregistered redirect_uri"** → dev-service or OIDC config issue, not a browser problem; check nginx `:3046` and auth `:3047`.
- **Human logged in elsewhere** → cookies live in their personal browser, not the shared one; ask them to use the shared window.

## References & Resources
- `./references/protocols.md` — subagent prompt template, report format, login-handoff checklist
- Tooling repo: `/home/fkrull/workspace/opencode-podman/` (`browser.sh`, `browser-cli/`, `browser/Dockerfile`, AGENTS.md → "Shared Browser")
- CLI help: `browser-cli.mjs help`
