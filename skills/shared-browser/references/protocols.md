# Protocols

`CLI` below means `"${OPENCODE_TOOLING_DIR:-/home/fkrull/workspace/opencode}/browser-cli/browser-cli.mjs"`.
`BROWSER` means `"${OPENCODE_TOOLING_DIR:-/home/fkrull/workspace/opencode}/browser.sh"`.
Each project has its own browser instance; run these from the project root.

## Subagent prompt template

When delegating browser work to the `browser` subagent, use this prompt shape:

```
Task: <one sentence — what must be achieved>
Start URL: <url>
Success condition: <exact observable condition — text, URL, cookie, element>
Steps hint: <optional — sequence if it matters>
Report: <what facts to extract, beyond the standard report format>
Constraints: Use the shared-browser skill's CLI (`CLI`). Do not type credentials;
if login is needed, stop and report WAITING_FOR_HUMAN_LOGIN. Do not close the
browser or clear cookies. Do not run `browser.sh login` yourself.
```

Example (recon):

```
Task: Verify that both protected pages load for the logged-in user.
Start URL: http://localhost:3046/internal/page1.html
Success condition: page contains the string "Page 1"
Steps hint: also open /internal/page2.html afterwards
Report: for each page — URL, title, first heading, console errors from load
Constraints: Use the shared-browser skill's CLI. Do not type credentials; if a
login page appears, report WAITING_FOR_HUMAN_LOGIN. Do not close the browser or
clear cookies. Do not run `browser.sh login` yourself.
```

## Subagent report format

The subagent MUST answer in at most 15 lines:

```
- Status: DONE | WAITING_FOR_HUMAN_LOGIN | FAILED
- URL: <final URL>
- Title: <page title>
- Findings: <bullets answering the task>
- Evidence: <key text/cookies/console errors, or "none">
- Next: <one line, only if a follow-up action is needed>
```

## Login handoff checklist

The browser is headless by default, so the human cannot see it until you expose it.

1. `CLI goto <login-url>` (e.g. `http://localhost:3046/login`).
2. `CLI snapshot --max-chars 1500` — confirm the provider page (Dataporten/Feide) loaded; capture the URL.
3. `BROWSER login` — relaunch the same profile headful; it reopens the saved tabs.
4. `CLI status` — confirm `mode: headful` before involving the human.
5. Stop and announce clearly: **"Please complete the login in the browser window."**
6. Wait with one blocking call:
   - `CLI wait --url-prefix <post-login-url> --timeout 300000`
   - or `CLI wait --text "<post-login marker>" --timeout 300000`
7. Verify authentication landed:
   - final URL is the expected page, and
   - expected cookie is present: `CLI cookies --name tsd_id_token` (or `eval "document.cookie"`).
8. `BROWSER headless` — hide the window again (same profile and tabs).
9. Resume the task; in the final report state the verified URL and cookie.

Edge cases:

- `BROWSER login` fails because no X display is available → the browser stays usable headless; report that the human handoff is impossible instead of pretending.
- Human takes longer than expected → keep waiting with a larger `--timeout`; never bypass the login.
- 2FA/CAPTCHA forms → strictly human territory; just wait.
- Provider fails to redirect back → check dev services (nginx `:3046`, auth `:3047`) before blaming the browser.
- Unexpected logged-out redirect mid-flow → re-run the handoff instead of guessing.

## Session state notes

- One browser instance per project: separate profile, tabs, cookies and CDP endpoint. Different projects are isolated and may run concurrently.
- Cookies and localStorage persist in `browser-profile/<project-key>/` across headless/headful switches, browser restarts and opencode sessions.
- Open tabs and session cookies are restored on `browser.sh start` and after headless/headful switches (Chromium session restore). Always use `browser.sh stop|restart|login|headless`; raw `podman stop` may not flush recent cookies. The CDP endpoint changes, so never cache it.
- Cookie expiry (e.g. short-lived OIDC tokens) can silently log the session out; when in doubt, re-check `CLI cookies --name <name>` before authenticated actions.
- `SameSite=Strict` cookies on `localhost:3046` are only sent for same-site flows; this is expected.
- Tab selection persists in `browser-cli/.state-<project-key>.json`; `tabs list` shows the active tab with `*`.
