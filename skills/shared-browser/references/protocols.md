# Protocols

`CLI` below means `/home/fkrull/workspace/opencode-podman/browser-cli/browser-cli.mjs`.

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
browser or clear cookies.
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
clear cookies.
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

1. `CLI goto <login-url>` (e.g. `http://localhost:3046/login`).
2. `CLI snapshot --max-chars 1500` — confirm the provider page (Dataporten/Feide) loaded; capture the URL.
3. Stop and announce clearly: **"Please complete the login in the shared browser window."**
4. Wait with one blocking call:
   - `CLI wait --url-prefix <post-login-url> --timeout 300000`
   - or `CLI wait --text "<post-login marker>" --timeout 300000`
5. Verify authentication landed:
   - final URL is the expected page, and
   - expected cookie is present: `CLI cookies --name tsd_id_token` (or `eval "document.cookie"`).
6. Resume the task; in the final report state the verified URL and cookie.

Edge cases:

- Human takes longer than expected → keep waiting with a larger `--timeout`; never bypass the login.
- 2FA/CAPTCHA forms → strictly human territory; just wait.
- Provider fails to redirect back → check dev services (nginx `:3046`, auth `:3047`) before blaming the browser.
- Unexpected logged-out redirect mid-flow → re-run the handoff instead of guessing.

## Session state notes

- Cookies and localStorage persist in `opencode-podman/browser-profile/` across browser restarts and opencode sessions.
- Cookie expiry (e.g. short-lived OIDC tokens) can silently log the session out; when in doubt, re-check `CLI cookies --name <name>` before authenticated actions.
- `SameSite=Strict` cookies on `localhost:3046` are only sent for same-site flows; this is expected.
- Tab selection persists in `browser-cli/.state.json`; `tabs list` shows the active tab with `*`.
