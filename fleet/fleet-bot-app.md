# fleet-bot (GitHub App)

One organisation-owned GitHub App that replaces the personal access token `FLEET_DRIFT_TOKEN` and carries the fleet self-healing workflows (D-55):

| Workflow | What it does with the App | Token it asks for |
|---|---|---|
| `fleet-reaper.yml` (every 6 h) | cancels runs that are queued, in progress or waiting for more than 24 h in every fleet repo | Actions write, Metadata read; all installed repos |
| `fleet-register.yml` (nightly) | lists the organisation's repos; opens or updates the PR `bot/fleet-register` with stub entries for repos missing from `fleet/repos.json` | token 1: Metadata read, all installed repos; token 2: Contents write + Pull requests write, `security-pipeline` only |
| `fleet-drift.yml` (weekly) | reads org Actions settings, repo settings and rulesets | Administration read (repo) + Administration read (org) + Metadata read |

All three are **inert until the variable `FLEET_BOT_APP_ID` exists** (job-level `if: vars.FLEET_BOT_APP_ID != ''`; `fleet-drift` falls back to the PAT until then). Tokens are minted per run by `actions/create-github-app-token` (GitHub-owned, SHA-pinned), live one hour and are narrowed with `permission-*` inputs to what the single step needs.

## Permissions (all others: no access)

| Scope | Permission | Level | Why |
|---|---|---|---|
| Repository | Metadata | Read | mandatory for every App; lists org repos (`fleet-register`) |
| Repository | Actions | Write | `POST .../actions/runs/{id}/cancel` and `/force-cancel` (`fleet-reaper`); listing runs needs only read |
| Repository | Contents | Write | create the branch and commit `fleet/repos.json` via the contents API (`fleet-register`); minted only for `security-pipeline` |
| Repository | Pull requests | Write | open and edit the PR `bot/fleet-register` (`fleet-register`); minted only for `security-pipeline` |
| Repository | Administration | Read | `fleet-drift` reads `security_and_analysis` and repo Actions permissions (replaces the PAT) |
| Organization | Administration | Read | `fleet-drift` reads `orgs/{org}/actions/permissions*` (replaces the PAT) |
| Organization | Members, Secrets, Workflows, Packages, everything else | none | not needed |

Not requested on purpose: **Workflows** (the bot never writes `.github/workflows`; GitHub would reject such a commit), **Checks/Statuses**, **Issues**, webhooks (inactive, no events).

Install on **All repositories** of the organisation. That is required for the point of `fleet-register` (it must see a new repo before it is listed) and means new repos are covered by the reaper without a click. Consequence to accept (G-S11): an installation-wide App can mint a Contents/Pull requests write token for every repo; the workflows only ask for it on `security-pipeline`, the private key is a secret of that one repository (not available to fork PRs, org policy requires approval for outside contributors), and `main` there is protected by the ruleset (PR, checks, signatures). Nothing the bot writes reaches `main` without the owner merging it.

## Why no ruleset exclusion is needed

The ruleset `signed commits on every branch` (D-51) requires verified signatures. Commits created through the REST contents API with a GitHub App installation token are signed by GitHub and show as "verified" (the same path the toolbox pin job uses since D-49; GitHub docs, "About commit signature verification", bot-signed commits). `fleet/register.sh` checks `commit.verification.verified` after each commit and stops if it is not true, so it can never open a PR the ruleset would reject. The branch `bot/fleet-register` is only ever extended, never force-pushed (a leftover branch without an open PR is deleted and recreated; deletion is allowed), so `no force-push on branches` needs no exclusion either. Contrast: `git commit` + `git push` from a runner would be unsigned and would need a bypass or an exclusion.

## One-time setup

1. Save the file below as `fleet-bot-manifest.html`, open it in the browser you are logged in with, click the button, confirm the name. GitHub creates the App under the organisation and redirects to the `redirect_url` with `?code=<code>` (valid one hour).

   ```html
   <!doctype html><meta charset="utf-8">
   <form method="post" action="https://github.com/organizations/Pascal-Organisation/settings/apps/new?state=fleet-bot">
     <input type="hidden" name="manifest" id="m"><button>Create fleet-bot</button>
   </form>
   <script>
   document.getElementById("m").value = JSON.stringify({
     name: "fleet-bot",
     url: "https://github.com/Pascal-Organisation/security-pipeline",
     redirect_url: "https://github.com/Pascal-Organisation/security-pipeline",
     hook_attributes: { url: "https://example.invalid/unused", active: false },
     public: false,
     default_events: [],
     default_permissions: {
       metadata: "read",
       actions: "write",
       contents: "write",
       pull_requests: "write",
       administration: "read",
       organization_administration: "read"
     }
   });
   </script>
   ```

2. Exchange the code for the App id and private key (no authentication needed; the code works once) and store them, in one go. Replace `<code>`; the key never touches a file:

   ```bash
   resp="$(gh api -X POST /app-manifests/<code>/conversions)"
   gh variable set FLEET_BOT_APP_ID -R Pascal-Organisation/security-pipeline --body "$(jq -r .id <<<"$resp")"
   jq -r .pem <<<"$resp" | gh secret set FLEET_BOT_APP_KEY -R Pascal-Organisation/security-pipeline
   unset resp
   ```

   (The response also holds a webhook secret and client secret; both are unused, discarded with `unset resp`.)
3. Install the App: github.com/apps/fleet-bot/installations/new, organisation `Pascal-Organisation`, **All repositories**. If a prompt asks to accept the permission set, accept: it matches the table above.
4. Optional, the PAT is no longer needed once the App works: run `fleet-drift` by hand (`gh workflow run fleet-drift -R Pascal-Organisation/security-pipeline`), then `gh secret delete FLEET_DRIFT_TOKEN -R Pascal-Organisation/security-pipeline` and revoke the token in the account settings.
5. Dry runs before the first live run:
   `gh workflow run fleet-reaper -R Pascal-Organisation/security-pipeline -f dry_run=true` and `gh workflow run fleet-register -R Pascal-Organisation/security-pipeline -f dry_run=true`; the step summary shows what would happen.

## Operating notes

- Reaper age: `FLEET_REAPER_MAX_AGE_HOURS` (repository variable) or the `max_age_hours` input; default 24. A normal cancel is tried first; if the API refuses (a run that never got a runner) or the run is alive 3 minutes later, `force-cancel` follows. A run that survives both is listed as `STILL ALIVE` and fails the job (ntfy via `NTFY_URL`, as in `fleet-drift`).
- A repo that must stay out of the fleet: add its name to `unmanaged_repos` in `fleet/repos.json`. Archived repos and forks are never proposed.
- Stub entries carry `"todo": true` and a `note`; `fleet-drift.sh` and `self-check.yml` read only known keys and ignore them. Defaults: `ci-only`, ring `stable`, gate `Security / security-gate`, visibility as found.
- Key rotation: generate a new private key in the App settings, `gh secret set FLEET_BOT_APP_KEY`, delete the old key. If the key leaks: delete it in the App settings first; the tokens it minted expire within the hour.
